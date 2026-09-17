#!/usr/bin/env python3
"""
offset_anchors.py — 扣掉每条拍摄的**系统性偏置**（默认不启用，需显式 --write 落盘）。

要解决的问题
------------
shader 的 UseAI 路径上，三个参数**只是光向的函数** —— 同样的光向就该得到同样的值，
不管这一帧是哪条拍摄录的。但实测：

  · 跨拍摄的标签分歧是同拍摄内的 1.6~2.4×（配对同角距，12-20° 档）；
  · 每条拍摄相对「其余四条拍摄建成的场」的残差，**中位数不为零**：
    `正面-0度` 的 SS 中位 −0.378、`正面-65度` 的 SL 中位 +0.541；
  · 沿光扫轨迹，光会路过**别的拍摄**的锚点，IDW 场被拽向那些锚点的标签，
    于是出现鼓包 —— 这就是逐帧看到的阴影边界抖动；
  · 扣掉每拍摄的中位偏置后：跨拍摄 |ΔSS| 中位 0.310→0.180，
    逐帧抖动 >0.5°/帧 的帧占比 13.96%→10.50%，而 u 极差 0.570→0.647 **上升**
    （没有把场抹平）。这是目前唯一一个「降抖动但不毁量程」的改动。

**为什么默认关闭**
------------------
扣偏置等于把美术逐条拍摄给的值，替换成「跨拍摄共识」。若那些差异本来就是有意的
艺术选择（例如逆光那条特意压出剪影），这么做会把画面变平 —— 这个仓库正是为同类
事烧过一次：EX 的死黑兜底当年就是「教 MLP 放弃美术有意为之的剪影」，
collect_training_data.py 里那段注释明确写着别再犯。

所以本脚本只在显式调用时工作，且**默认只报告不落盘**（加 --write 才写），
每次都会把每拍摄的位移量打出来供人核对。

顺序约束
--------
必须在 merge_anchors.py **之前**跑。偏置是拍摄级的，而合并会把不同拍摄的成员压进
同一行、note 变成复合串，之后就再也认不出某行原本属于哪条拍摄了。

用法：
    python offset_anchors.py --input anchors.csv                    # 只报告
    python offset_anchors.py --input anchors.csv --output anchors_offset.csv --write
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
# 内层失去引用被 GC 时关掉共用的 buffer（与 fit_mlp.py 同一处坑，判据须一致）。
if hasattr(sys.stdout, "buffer") and \
        (getattr(sys.stdout, "encoding", "") or "").lower().replace("-", "") != "utf8":
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

sys.path.insert(0, str(Path(__file__).resolve().parent))
from collect_training_data import (          # noqa: E402
    _parse_anchors, FEATURE_NAMES, PARAM_NAMES, VCAM_COLUMNS, PARAM_BOUNDS,
)

SCRIPT_DIR = Path(__file__).resolve().parent
_IDW_POWER = 2.0


def take_of_note(note):
    """从 note 里取拍摄名。`<拍摄> frame=<n>` 是导出器写死的格式。"""
    take, sep, _ = note.rpartition(" frame=")
    return take.strip() if sep else note.strip()


def idw(F, Y, Q, power=_IDW_POWER):
    """用 (F, Y) 当锚点表，对 Q 求 IDW。"""
    d = np.linalg.norm(F[None, :, :] - Q[:, None, :], axis=2)
    w = 1.0 / np.maximum(d, 1e-6) ** power
    w /= w.sum(axis=1, keepdims=True)
    return w @ Y


def disagreement(F, Y, takes, max_deg=20.0):
    """配对同角距下，同拍摄 vs 跨拍摄的 |Δ| 中位数（每列一个）。"""
    unit = F / np.maximum(np.linalg.norm(F, axis=1, keepdims=True), 1e-12)
    ang = np.degrees(np.arccos(np.clip(unit @ unit.T, -1.0, 1.0)))
    same, cross = [], []
    for i in range(len(F)):
        for j in range(i + 1, len(F)):
            a = ang[i, j]
            if a < 1e-6 or a > max_deg:
                continue
            (same if takes[i] == takes[j] else cross).append(np.abs(Y[i] - Y[j]))
    if not same or not cross:
        return None
    return (np.median(np.stack(same), axis=0), np.median(np.stack(cross), axis=0),
            len(same), len(cross))


def main():
    ap = argparse.ArgumentParser(
        description="扣掉每条拍摄的系统性偏置（默认只报告，--write 才落盘）",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--input", type=Path, default=SCRIPT_DIR / "anchors.csv")
    ap.add_argument("--output", type=Path, default=SCRIPT_DIR / "anchors_offset.csv")
    ap.add_argument("--iters", type=int, default=2,
                    help="迭代轮数（每轮用留一拍摄的场重估位移，默认 2）")
    ap.add_argument("--max-shift-frac", type=float, default=0.25,
                    help="任一列位移超过该列锚点量程的这个比例就中止（默认 0.25）")
    ap.add_argument("--allow-large-shifts", action="store_true",
                    help="允许超限的位移（意味着那条拍摄可能不是偏置而是另一种意图）")
    ap.add_argument("--write", action="store_true", help="写出结果表（默认只报告）")
    args = ap.parse_args()

    prov = _parse_anchors(args.input)
    F = prov["data"][:, :len(FEATURE_NAMES)]
    Y = prov["data"][:, len(FEATURE_NAMES):].copy()
    notes = prov["notes"]
    takes = np.array([take_of_note(n) for n in notes])
    uniq = sorted(set(takes.tolist()))

    if len(uniq) < 2:
        sys.exit(f"{args.input} 只有 {len(uniq)} 条拍摄，无从估计拍摄间偏置"
                 f"（至少需要 2 条才能互相当参照）。")
    if prov["missing_vcam"]:
        sys.exit(f"{args.input} 有 {len(prov['missing_vcam'])} 行缺 V_cam 出处，无法比对。")

    print(f"{args.input.name}：{len(F)} 个锚点，{len(uniq)} 条拍摄")
    print(f"  迭代 {args.iters} 轮；位移上限 = 各列量程的 {args.max_shift_frac:.0%}\n")

    before = disagreement(F, Y, takes)
    Y0 = Y.copy()
    shifts_hist = []

    for it in range(args.iters):
        cur = {}
        for t in uniq:
            m = takes == t
            # 留一拍摄：用其余拍摄建场，避免自己预测自己（那会把残差压成 0）
            pred = idw(F[~m], Y[~m], F[m])
            cur[t] = np.median(Y[m] - pred, axis=0)
        for t in uniq:
            Y[takes == t] -= cur[t]
        shifts_hist.append(cur)

        print(f"-- 第 {it + 1} 轮位移 --")
        print(f"   {'拍摄':<22}" + "".join(f"{n[:10]:>13}" for n in PARAM_NAMES))
        for t in uniq:
            print(f"   {t:<22}" + "".join(f"{v:>13.4f}" for v in cur[t]))

        # 上一轮的位移已经扣掉了，本轮若仍在动，说明模型没收敛到常数偏置
        mag = np.abs(np.stack([cur[t] for t in uniq]))
        print(f"   本轮 |位移| 最大 {mag.max():.4f}   "
              f"（下一轮应显著变小；不收敛说明偏置随光向变化，扣常数不够）\n")

    Ycorr = Y
    # 扣偏置后可能有锚点被推出声明量程（实测 ShadowSmooth 会到 -0.058）。
    # 必须显式夹回并报告，而不是让后续 validate_param_bounds 硬中止：
    #   · ShadowSmooth 的物理下限就是 0（shader 里 max(0.001, SS)），负值无意义；
    #   · 夹回量极小（<0.06）、只影响 2/75 行，且发生在「去噪」这一步，属于清理而非削顶。
    # 静默夹是错的，所以逐列打印被夹的行数。
    lo = np.array([b[0] for b in PARAM_BOUNDS])
    hi = np.array([b[1] for b in PARAM_BOUNDS])
    n_clip = int((Ycorr < lo - 1e-9).sum() + (Ycorr > hi + 1e-9).sum())
    for i, n in enumerate(PARAM_NAMES):
        c = int((Ycorr[:, i] < lo[i] - 1e-9).sum() + (Ycorr[:, i] > hi[i] + 1e-9).sum())
        if c:
            print(f"  ⚠ 扣偏置后 {n} 有 {c} 行越出 [{lo[i]:+.2f}, {hi[i]:+.2f}]，已夹回")
    Ycorr = np.clip(Ycorr, lo, hi)
    if n_clip:
        print(f"  （共夹回 {n_clip} 个值；这是去噪的下限清理，不是静默削顶）")
    after = disagreement(F, Ycorr, takes)

    # ---- 位移安全阀 ----
    span = np.array(PARAM_BOUNDS, dtype=float)
    rng = span[:, 1] - span[:, 0]
    worst = np.abs(np.stack([shifts_hist[0][t] for t in uniq])) / rng
    if worst.max() > args.max_shift_frac:
        ti, pi = np.unravel_index(np.argmax(worst), worst.shape)
        msg = (f"\n{uniq[ti]} 的 {PARAM_NAMES[pi]} 位移 {shifts_hist[0][uniq[ti]][pi]:+.4f}"
               f" 占该列量程 {worst[ti, pi]:.1%}，超过上限 {args.max_shift_frac:.0%}。\n\n"
               f"  大位移的两种读法，必须人来分辨：\n"
               f"    1) 这条拍摄确实带一个系统性偏置 → 扣掉是对的，加 --allow-large-shifts；\n"
               f"    2) 这条拍摄是**另一种有意的打光意图**（例如逆光时特意压出剪影），\n"
               f"       那不是噪声，扣掉就是让 MLP 放弃美术的选择。\n"
               f"  先看上面各轮位移表，再去 UE 里对一遍那条拍摄的画面再决定。\n"
               f"  （本仓库为同类事烧过一次：EX 死黑兜底当年做的正是这件事。）\n")
        if not args.allow_large_shifts:
            sys.exit(msg)
        print(msg)

    # ---- 效果 ----
    print("=" * 78)
    print("扣偏置前后：配对同角距（≤20°）下的 |Δ| 中位数")
    print("=" * 78)
    if before and after:
        s0, c0, ns, nc = before
        s1, c1, _, _ = after
        print(f"  配对数：同拍摄 {ns}，跨拍摄 {nc}\n")
        print(f"{'参数':<18}{'同拍摄 前':>11}{'后':>10}{'跨拍摄 前':>12}{'后':>10}"
              f"{'跨/同 前':>11}{'后':>9}")
        for i, n in enumerate(PARAM_NAMES):
            print(f"{n:<18}{s0[i]:>11.4f}{s1[i]:>10.4f}{c0[i]:>12.4f}{c1[i]:>10.4f}"
                  f"{c0[i]/max(s0[i],1e-9):>11.2f}{c1[i]/max(s1[i],1e-9):>9.2f}")
        print("\n  同拍摄一列**不应变化**（偏置是拍摄内的常数，扣它不动拍摄内的相对结构）——")
        print("  若它变了，说明这个实现动的不只是偏置，要查。")
        print("  跨/同 的比值越接近 1，标签越像「只是光向的函数」。")

    if not args.write:
        print("\n（未写文件；加 --write 才落盘）")
        return

    vc = prov["vcam"][0]
    lines = [FEATURE_NAMES + PARAM_NAMES + VCAM_COLUMNS + ["note"]]
    for i, note in enumerate(notes):
        row = ([f"{v:.6g}" for v in F[i]]
               + [f"{v:.6g}" for v in Ycorr[i]]
               + [f"{v:.4f}" for v in vc]
               + [f"[offset -{shifts_hist[0][takes[i]][0]:+.3f}/"
                  f"{shifts_hist[0][takes[i]][1]:+.3f}/"
                  f"{shifts_hist[0][takes[i]][2]:+.3f}] {note}"])
        lines.append(row)

    with args.output.open("w", encoding="utf-8", newline="\n") as f:
        csv.writer(f).writerows(lines)
    print(f"\n已写出 {args.output}（{len(F)} 行）")

    # 出处落盘：位移与判据必须生成时写下，事后从表里反推不出来
    rep = args.output.with_suffix(".report.json")
    rep.write_text(json.dumps({
        "source": str(args.input),
        "iters": args.iters,
        "max_shift_frac": args.max_shift_frac,
        "allow_large_shifts": bool(args.allow_large_shifts),
        "shift_frac_of_range": {t: {p: float(v) for p, v in zip(PARAM_NAMES, row)}
                                for t, row in zip(uniq, worst)},
        "shifts_by_iteration": [
            {t: {p: float(v) for p, v in zip(PARAM_NAMES, h[t])} for t in uniq}
            for h in shifts_hist],
        "disagreement_before": {"same": before[0].tolist(), "cross": before[1].tolist()}
        if before else None,
        "disagreement_after": {"same": after[0].tolist(), "cross": after[1].tolist()}
        if after else None,
    }, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"已写出 {rep}（位移与判据）")


if __name__ == "__main__":
    main()
