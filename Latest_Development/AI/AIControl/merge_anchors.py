#!/usr/bin/env python3
"""
merge_anchors.py — 把「同一个光向被重复录了好几次」的锚点合并成一个。

为什么需要它
------------
anchors.csv 是 5 条甩拍各 15 帧的汇总。5 条拍摄的光扫**不是同一条轨迹**，
但会在若干帧上几乎重合。那些重合帧本应是同一条采样，实际却是 5 次独立录制，
各自带着自己的噪声。实测（2026-09-12）：

  · 特征逐字节相同的行已经没有了（均匀 24° 重采样后为 0 对），
    所以「同姿态录两遍」这种直接对照不再可得；
  · 改成按**角距配对**后，跨拍摄的标签分歧是同拍摄内的 1.6~2.4×
    （12-20° 档，样本最多）；总体 |ΔShadowSmooth| 中位 0.380 vs 0.080（约 8° 处，4.75×）；
  · 后果：任何插值器都必须在相距 3~8° 却互相矛盾的标签之间折中，
    折中必然得到陡峭起伏的响应面。光扫时阴影边界抖 0.5°/帧 以上的帧占 14.1%
    且 MLP 的抖动量只有其监督目标（IDW）的
    0.47~0.79×（P95/P99）—— 网络是在给标签做低通，不是噪声源。

⇒ 治本的做法是让同一个光向只保留**一个**标签，而不是换个网络去拟合这堆矛盾。

合并规则
--------
1. 在**特征空间**里做单链聚类：两点夹角 ≤ merge_deg 即连边，连通分量即一簇。
   用特征空间而不是世界光向空间，是因为 IDW 的距离就在这个空间里量。
   （本表的 V_cam 逐行相同，所以两者是一个固定的线性映射关系。）
2. 每簇的位置 = 成员特征向量的**均值**（线性映射下等价于光向的均值）。
3. 每簇的标签 = 成员各列的**中位数**（不是均值：5 条拍摄里若有一条明显跑偏，
   中位数不会被拖走）。
4. **一簇一票**，不按成员数加权。合并后每个不同的光向只投一次；
   原先「某方向录了 5 次所以拉力 5 倍」是录制排期的副作用，不是「这个方向更重要」。

本脚本**不改 anchors.csv**（那是原始录制，是实验数据），只产出合并后的新表；
由 `retrain_all.py --merge-deg` 走 `--anchors` 通路接进管线。

用法：
    python merge_anchors.py                          # 默认 4°，只报告不写文件
    python merge_anchors.py --merge-deg 3.5 --write  # 写 anchors_merged.csv
"""
import argparse
import csv
import io
import json
import sys
from pathlib import Path

import numpy as np

# 本脚本要打印 ° / ± / ⇒，GBK 控制台会 UnicodeEncodeError。
# 先查 encoding 再决定要不要包 —— 无条件包会把 sys.stdout 套两层，
# 内层失去引用被 GC 时关掉共用的 buffer（与 fit_mlp.py 同一处坑，三处判据须一致）。
if hasattr(sys.stdout, "buffer") and \
        (getattr(sys.stdout, "encoding", "") or "").lower().replace("-", "") != "utf8":
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

sys.path.insert(0, str(Path(__file__).resolve().parent))
from collect_training_data import (          # noqa: E402
    _parse_anchors, FEATURE_NAMES, PARAM_NAMES, VCAM_COLUMNS, V_CAM, RIGHT,
)

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_IN = SCRIPT_DIR / "anchors.csv"
DEFAULT_OUT = SCRIPT_DIR / "anchors_merged.csv"


def feature_matrix_to_light(F):
    """把 (LdotV, L_up, L_right) 还原成世界光向，只为把角度讲成人话。

    三个特征是 L 在一组基上的投影：f = (L·V, L·ez, L·Right) = M @ L，
    M 的行就是 (V_cam, (0,0,1), Right)。M 可逆时 L = M⁻¹ f。
    V_cam 被改成退化值（例如竖直）时 M 会奇异 —— 那种配置下光向本来就没法
    从特征反推，返回 None，报告退回只用特征空间角。
    """
    M = np.stack([np.asarray(V_CAM, float),
                  np.array([0.0, 0.0, 1.0]),
                  np.asarray(RIGHT, float)])
    try:
        Minv = np.linalg.inv(M)
    except np.linalg.LinAlgError:
        return None
    if not np.all(np.isfinite(Minv)):
        return None
    L = F @ Minv.T
    n = np.linalg.norm(L, axis=1, keepdims=True)
    if np.any(n < 1e-9):
        return None
    return L / n


def pair_angle_deg(A, B):
    """两组向量的夹角（按对应行配对），度。"""
    a = A / np.maximum(np.linalg.norm(A, axis=1, keepdims=True), 1e-12)
    b = B / np.maximum(np.linalg.norm(B, axis=1, keepdims=True), 1e-12)
    return np.degrees(np.arccos(np.clip(np.sum(a * b, axis=1), -1.0, 1.0)))


def max_pair_angle_deg(P):
    """一组向量的直径（两两夹角的最大值），度。"""
    if len(P) < 2:
        return 0.0
    u = P / np.maximum(np.linalg.norm(P, axis=1, keepdims=True), 1e-12)
    G = np.clip(u @ u.T, -1.0, 1.0)
    return float(np.degrees(np.arccos(G.min())))


def cluster_single_linkage(F, merge_deg):
    """特征空间单链聚类，返回每点的簇 id。

    单链（并查集）而不是贪心球覆盖：后者依赖遍历顺序，「谁先被选中」会改变结果，
    同样的输入换个行序就得到不同的簇 —— 不可复现的预处理比不预处理更糟。
    代价是可能链式串大：A-B 4°、B-C 4° 会把相距 8° 的 A、C 并进一簇。
    这个风险由 check_spans() 在事后显式查，并要求 --allow-wide-clusters 才放行，
    不靠聚类算法本身「应该不会」。
    """
    n = len(F)
    unit = F / np.maximum(np.linalg.norm(F, axis=1, keepdims=True), 1e-12)
    cos_thr = np.cos(np.radians(merge_deg))

    parent = list(range(n))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    # 只取上三角的连边；G >= cos_thr 含自身（点积为 1），用 triu(k=1) 排掉
    ii, jj = np.where(np.triu(unit @ unit.T >= cos_thr, 1))
    for a, b in zip(ii.tolist(), jj.tolist()):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[rb] = ra

    raw = np.array([find(i) for i in range(n)])
    # 重编号，按簇大小降序，让报告与输出稳定（不受行序影响）
    _, inv, cnt = np.unique(raw, return_inverse=True, return_counts=True)
    order = np.argsort(-cnt, kind="stable")
    remap = np.empty(len(order), dtype=int)
    remap[order] = np.arange(len(order))
    return remap[inv]


def merge(F, Y, labels, n_clusters):
    """按簇求位置均值与标签中位数，返回 (Fm, Ym, sizes)。"""
    Fm = np.zeros((n_clusters, F.shape[1]))
    Ym = np.zeros((n_clusters, Y.shape[1]))
    sizes = np.zeros(n_clusters, dtype=int)
    for c in range(n_clusters):
        m = labels == c
        sizes[c] = int(m.sum())
        Fm[c] = F[m].mean(axis=0)
        Ym[c] = np.median(Y[m], axis=0)
    return Fm, Ym, sizes


def main():
    ap = argparse.ArgumentParser(
        description="合并同一光向下的重复锚点（标签取中位数）",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--input", type=Path, default=DEFAULT_IN)
    ap.add_argument("--output", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--merge-deg", type=float, default=4.0,
                    help="特征空间夹角小于此值的锚点并为一簇（默认 4.0）")
    ap.add_argument("--max-span-deg", type=float, default=None,
                    help="一簇内最大跨度的上限（默认 2×merge-deg）；超限中止，"
                         "除非加 --allow-wide-clusters")
    ap.add_argument("--allow-wide-clusters", action="store_true",
                    help="允许跨度超限的簇（单链链式串大时会发生，自担风险）")
    ap.add_argument("--write", action="store_true",
                    help="写出合并表（默认只报告，不落盘）")
    args = ap.parse_args()

    if args.merge_deg <= 0:
        sys.exit("--merge-deg 必须 > 0；不想合并就别跑本脚本。")
    max_span = args.max_span_deg if args.max_span_deg is not None else 2.0 * args.merge_deg

    prov = _parse_anchors(args.input)
    F_all = prov["data"][:, :len(FEATURE_NAMES)]
    Y_all = prov["data"][:, len(FEATURE_NAMES):]
    notes = prov["notes"]
    vcam = prov["vcam"]

    # 合并的前提是 V_cam 逐行一致；不一致时特征空间本身就不是同一个，
    # 「夹角」也就没有意义。_parse_anchors 已把缺列标成 NaN 并留给 main 报，
    # 这里作为独立脚本必须自己拦一次。
    if prov["missing_vcam"]:
        sys.exit(f"{args.input} 有 {len(prov['missing_vcam'])} 行缺 V_cam 出处，无法合并。")
    uniq_vcam = np.unique(np.round(vcam, 6), axis=0)
    if len(uniq_vcam) > 1:
        sys.exit(f"{args.input} 的 V_cam 出处分歧成 {len(uniq_vcam)} 组，"
                 f"不能在同一个特征空间里谈夹角。请先分批导出。")

    labels = cluster_single_linkage(F_all, args.merge_deg)
    n_clusters = int(labels.max()) + 1
    Fm, Ym, sizes = merge(F_all, Y_all, labels, n_clusters)

    members_of = [np.where(labels == c)[0] for c in range(n_clusters)]
    spans = np.array([max_pair_angle_deg(F_all[m]) for m in members_of])
    L_all = feature_matrix_to_light(F_all)
    spans_world = (np.array([max_pair_angle_deg(L_all[m]) for m in members_of])
                   if L_all is not None else np.zeros(n_clusters))

    print(f"{args.input.name}：{len(F_all)} 个锚点 → {n_clusters} 簇"
          f"（merge_deg={args.merge_deg}°）")
    n_multi = int((sizes > 1).sum())
    print(f"  被合并的簇 {n_multi} 个，涉及 {int(sizes[sizes > 1].sum())} 个锚点；"
          f"落单的 {int((sizes == 1).sum())} 个原样保留\n")

    print("被合并的簇（按跨度降序）——「标签分歧」= 合并前各列 max-min，")
    print("即这一步到底平均掉了多少噪声；它和该簇的角跨度对比，能看出分歧是")
    print("「同一个光向的录制噪声」还是「本来就是两个不同的光向」。\n")
    hdr = (f"{'#':>3}{'n':>3}{'跨度(特征)':>12}{'跨度(世界)':>12}"
           + "".join(f"{'Δ' + p[:9]:>11}" for p in PARAM_NAMES) + "   成员")
    print(hdr)
    print("-" * len(hdr))

    report = []
    for c in np.argsort(-spans):
        m = members_of[c]
        dY = Y_all[m].max(axis=0) - Y_all[m].min(axis=0)
        report.append({
            "cluster": int(c),
            "size": int(sizes[c]),
            "span_feature_deg": float(spans[c]),
            "span_world_deg": float(spans_world[c]),
            "label_spread": {p: float(v) for p, v in zip(PARAM_NAMES, dY)},
            "label_merged": {p: float(v) for p, v in zip(PARAM_NAMES, Ym[c])},
            "members": [notes[i] for i in m],
        })
        if sizes[c] == 1:
            continue
        flag = "  <<< 跨度超限" if spans[c] > max_span else ""
        print(f"{c:>3}{sizes[c]:>3}{spans[c]:>12.2f}{spans_world[c]:>12.2f}"
              + "".join(f"{v:>11.3f}" for v in dY) + "   "
              + " | ".join(notes[i] for i in m)[:40] + flag)

    over = [e for e in report if e["size"] > 1 and e["span_feature_deg"] > max_span]
    if over:
        worst = max(over, key=lambda e: e["span_feature_deg"])
        msg = (f"\n{len(over)} 个簇的跨度超过上限 {max_span:.2f}°"
               f"（最大 {worst['span_feature_deg']:.2f}°，{worst['size']} 个成员）：\n"
               + "\n".join(f"    {e['span_feature_deg']:6.2f}°  n={e['size']}  "
                           + " | ".join(e["members"])[:70] for e in over[:10]) + "\n\n"
               f"  超限意味着这些锚点可能**不是**同一个光向，而是单链聚类链式串大的结果：\n"
               f"  A-B 在 {args.merge_deg}° 内、B-C 也在，于是相距更远的 A、C 被并进一簇。\n"
               f"  把它们的中位数当同一个光向的标签，等于替两个不同光向做了主张。\n\n"
               f"  三选一（不要为了消掉报错而随手调大上限）：\n"
               f"    1) 调小 --merge-deg，让这些簇拆开；\n"
               f"    2) 确认它们确是同一光向（看上面的成员 note），"
               f"加 --allow-wide-clusters；\n"
               f"    3) 回去补录，让同光向的锚点真正重合。\n")
        if not args.allow_wide_clusters:
            sys.exit(msg)
        print(msg)

    n_eff = int(sizes.sum())
    print(f"\n合并后 {n_clusters} 个锚点（原 {n_eff} 个）。"
          f"一簇一票，不按成员数加权。")

    if not args.write:
        print("\n（未写文件；加 --write 才落盘）")
        return

    vc = uniq_vcam[0]
    lines = [FEATURE_NAMES + PARAM_NAMES + VCAM_COLUMNS + ["note"]]
    for c in range(n_clusters):
        m = members_of[c]
        members = "; ".join(notes[i] for i in m)
        note = (f"[merge r={args.merge_deg} n={sizes[c]} "
                f"span={spans[c]:.2f}deg] {members}")
        row = ([f"{v:.6g}" for v in Fm[c]]
               + [f"{v:.6g}" for v in Ym[c]]
               + [f"{v:.4f}" for v in vc]
               + [note])
        lines.append(row)

    with args.output.open("w", encoding="utf-8", newline="\n") as f:
        csv.writer(f).writerows(lines)
    print(f"\n已写出 {args.output}（{n_clusters} 行）")

    # 出处落盘：合并参数 + 每簇的成员与分歧量。
    # 「出处信息必须生成时落盘，不能事后反推」—— 事后从合并表里已经看不出
    # 哪些行被合过、分歧有多大，所以这些必须在生成时一起写下来。
    rep_path = args.output.with_suffix(".report.json")
    rep_path.write_text(json.dumps({
        "source": str(args.input),
        "merge_deg": args.merge_deg,
        "max_span_deg": max_span,
        "allow_wide_clusters": bool(args.allow_wide_clusters),
        "n_in": int(len(F_all)),
        "n_out": int(n_clusters),
        "clusters": report,
    }, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"已写出 {rep_path}（合并参数与每簇出处）")


if __name__ == "__main__":
    main()
