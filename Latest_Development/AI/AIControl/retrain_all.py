#!/usr/bin/env python3
"""
retrain_all.py — 一键重训：改完 anchors.csv 后运行本脚本即可。

流程：
  1. 运行 collect_training_data.py 生成 training_data.csv
  2. 训练 MLP（特征数 → hidden → 3，特征数由表头列名反推）
  3. 生成 ai_mlp.hlsl（前置独立节点版）
  4. 同步内嵌权重到**全部** HLSL_TARGETS（AUTO-MLP-BEGIN/END 标记之间）
     —— 不透明版 + 透明版两份。只写一份会让另一份静默停在旧权重。

评估口径与 fit_mlp.py 一致：切 20% 留出集，R² 一律报留出集指标，
并打印 IDW 闭式基线（= 标签生成器）作对照。

用法：
    python retrain_all.py                  # 500 样本，256 隐藏
    python retrain_all.py --samples 1000   # 自定义样本数
"""
import argparse
import io
import subprocess
import sys
from pathlib import Path

import numpy as np

from fit_mlp import (load_data, split_columns, build_hlsl, train_and_eval,
                     idw_baseline, MAX_ITER, HIDDEN_DEFAULT, DEGENERATE_R2)
from sklearn.metrics import r2_score

# 本脚本要打印 ⚠ / ≈，GBK 控制台会 UnicodeEncodeError。
# fit_mlp 在 import 时已装好 UTF-8 包装，但它可能被换掉，这里按需补一份；
# 先查 encoding 再决定，避免把 sys.stdout 套两层导致输出交错。
if hasattr(sys.stdout, "buffer") and \
        (getattr(sys.stdout, "encoding", "") or "").lower().replace("-", "") != "utf8":
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

SCRIPT_DIR = Path(__file__).resolve().parent

# 权重要写进**每一份**嵌了同一个 MLP 的 HLSL。
# 曾经只写不透明版：透明版（Alpha）带着旧权重继续跑，不报任何错，
# 于是同一个角色身上不透明槽位和透明槽位用的是两套预测参数 —— 只有肉眼对比才看得出来。
HLSL_TARGETS = [
    SCRIPT_DIR.parent / "MMDToonShader_SM5_SingleFunc_Full_AI.hlsl",
    SCRIPT_DIR.parent / "MMDToonShader_SM5_SingleFunc_Full_Alpha_AI.hlsl",
]

BEGIN = "// ==== AUTO-MLP-BEGIN ===="
END = "// ==== AUTO-MLP-END ===="


def build_inline_hlsl(model, input_names, output_names, y_mins, y_maxs, r2_scores, y_means):
    """
    生成内嵌到 Full_AI.hlsl 的权重片段（变量名 AI_*，输入 <特征名>_AI）。

    输入变量名由 input_names 推导（LdotV → LdotV_AI），与 shader 中
    Custom Node 的输入引脚名一一对应。旧版写成 `"LdotV_AI" if j == 0 else
    "L_up_AI"`，是二选一的三目；特征扩到 3 维后 j == 2 会静默套用 L_up_AI，
    生成的权重看着正常、结果全错。
    """
    W1 = model.coefs_[0]
    b1 = model.intercepts_[0]
    W2 = model.coefs_[1]
    b2 = model.intercepts_[1]
    n_in = W1.shape[0]
    n_hid = W1.shape[1]
    # 输入列数必须与实际输入名对得上，否则下面下标 j 会越界/错位
    assert len(input_names) == n_in, \
        f"输入列数 {len(input_names)} 与网络权重 {n_in} 不一致"

    var_names = {
        "ShadowSmooth": "AI_ShadowSmooth",
        "ShadowLocation": "AI_ShadowLocation",
        "ExposureScale": "AI_ExposureScale",
    }

    lines = []
    # 隐藏层 h_0 .. h_{n-1}
    for i in range(n_hid):
        terms = []
        for j in range(n_in):
            w = W1[j, i]
            if abs(w) > 1e-6:
                terms.append(f"{w:+.6f} * {input_names[j]}_AI")
        expr = " ".join(terms) + f" {b1[i]:+.6f}"
        lines.append(f"float h_{i} = max(0.0, {expr});")

    lines.append("")

    # 输出层：AI_ShadowSmooth / AI_ShadowLocation / AI_ExposureScale
    for name in output_names:
        idx = output_names.index(name)
        var = var_names[name]
        r2 = r2_scores[idx]
        if r2 < DEGENERATE_R2:
            lines.append(f"float {var} = {y_means[idx]:.6g};  // 常数（留出R² {r2:+.3f}）")
        else:
            terms = []
            for j in range(n_hid):
                w = W2[j, idx]
                if abs(w) > 1e-6:
                    terms.append(f"{w:+.6f} * h_{j}")
            expr = " ".join(terms) + f" {b2[idx]:+.6f}"
            span = y_maxs[idx] - y_mins[idx]
            vmin = y_mins[idx] - 0.02 * span
            vmax = y_maxs[idx] + 0.02 * span
            lines.append(f"float {var} = clamp({expr}, {vmin:.4g}, {vmax:.4g});")

    return "\n".join(lines)


def read_mlp_block(path):
    """取出一份 HLSL 里 AUTO-MLP-BEGIN/END 之间的片段，行尾归一成 LF。"""
    with Path(path).open("r", encoding="utf-8", newline="") as f:
        text = f.read()
    if text.count(BEGIN) != 1 or text.count(END) != 1:
        raise RuntimeError(
            f"{path} 里 {BEGIN} 出现 {text.count(BEGIN)} 次、"
            f"{END} 出现 {text.count(END)} 次，各须恰好 1 次。")
    start = text.index(BEGIN) + len(BEGIN)
    end = text.index(END)
    return text[start:end].replace("\r\n", "\n").strip("\n")


def sync_mlp_block(path, inline_code):
    """把内嵌片段写入 path 的 AUTO-MLP-BEGIN/END 标记之间，返回是否真的改了内容。

    ⚠ 必须用 newline="" 读写。默认的通用换行会把 CRLF 读成 LF、写回时又原样写 LF，
      于是一次重训就把整个 shader 的行尾从 CRLF 全改成 LF —— 不透明版 510 行全是 CRLF，
      改完之后真实改动（几十行）会淹没在整文件重写的 diff 里，看不出到底改了什么。
      行尾本身不影响编译，但让代码评审失效。两份目标文件行尾不同（不透明 CRLF、
      透明 LF），所以 eol 必须**逐文件**探测，不能从某一份推。
    """
    path = Path(path)
    if not path.exists():
        raise FileNotFoundError(f"找不到 HLSL 目标：{path}")
    with path.open("r", encoding="utf-8", newline="") as f:
        text = f.read()

    n_begin = text.count(BEGIN)
    n_end = text.count(END)
    if n_begin != 1 or n_end != 1:
        # 标记不唯一时 index() 可能取到错的 END（例如 END 出现在 BEGIN 之前），
        # 会把标记之间的内容替换掉一大块而看不出来。宁可拒绝。
        raise RuntimeError(
            f"{path.name} 里 {BEGIN} 出现 {n_begin} 次、{END} 出现 {n_end} 次，"
            f"各须恰好 1 次，否则替换范围无法确定。")

    eol = "\r\n" if "\r\n" in text else "\n"
    start = text.index(BEGIN)
    end = text.index(END) + len(END)
    # inline_code 由 "\n".join 生成，统一成文件自身的行尾，避免标记内混入 LF
    body = inline_code.replace("\r\n", "\n").replace("\n", eol)
    new_block = f"{BEGIN}{eol}{body}{eol}{END}"
    new_text = text[:start] + new_block + text[end:]
    if new_text == text:
        return False

    with path.open("w", encoding="utf-8", newline="") as f:
        f.write(new_text)
    return True


def sync_all_targets(inline_code):
    """写全部目标，然后**校验各份的 AI 块逐字相同**。

    两份 shader 共用同一个 MLP，块内不一致 = 同一个角色身上不透明槽位与透明槽位
    用两套预测参数。这里当场比对，而不是等上机肉眼发现；行尾差异归一后再比。
    """
    changed = {}
    for path in HLSL_TARGETS:
        changed[path.name] = sync_mlp_block(path, inline_code)
        mark = "已更新" if changed[path.name] else "无变化"
        print(f"  {mark}  {path.name}")

    blocks = {p.name: read_mlp_block(p) for p in HLSL_TARGETS}
    names = list(blocks)
    ref = blocks[names[0]]
    for n in names[1:]:
        if blocks[n] != ref:
            raise RuntimeError(
                f"同步后 {names[0]} 与 {n} 的 AI 块仍不一致："
                f"{len(ref)} vs {len(blocks[n])} 字符。两份必须共用同一套权重。")
    print(f"  校验通过：{len(names)} 份 AI 块逐字相同（{len(ref)} 字符）")


def main():
    ap = argparse.ArgumentParser(description="一键重训 MLP 并同步到 HLSL")
    ap.add_argument("--samples", type=int, default=500, help="训练样本数（默认 500）")
    ap.add_argument("--hidden", type=int, default=HIDDEN_DEFAULT,
                    help=f"隐藏层神经元数（默认 {HIDDEN_DEFAULT}）")
    ap.add_argument("--take-offset", action="store_true",
                    help="先扣掉每条拍摄的系统性偏置（默认关）。会改掉美术逐条拍摄给的"
                         "绝对值，只在确认那些差异是录制噪声而非有意选择时用。")
    # ⚠ help 里的 % 要写 %%：argparse 会拿 help 当格式串去 % 展开，
    #   裸 % 直接 ValueError: badly formed help string（在 --help 之前就炸）。
    ap.add_argument("--allow-large-shifts", action="store_true",
                    help="允许 --take-offset 的位移超过量程 25%%")
    ap.add_argument("--merge-deg", type=float, default=0.0,
                    help="再按此角半径合并同一光向的重复锚点（0 = 不合并，默认）。")
    ap.add_argument("--allow-wide-clusters", action="store_true",
                    help="合并时允许跨度超限的簇（单链链式串大时会发生，自担风险）")
    ap.add_argument("--smooth-order", type=int, default=0,
                    help="光滑标签：低阶球谐阶数（0 = 关闭用 IDW；推荐 3）。"
                         "不再精确穿过锚点，换取逐帧平滑，通常配合 --take-offset")
    ap.add_argument("--smooth-ridge", type=float, default=1e-6,
                    help="光滑拟合的 ridge 正则（默认 1e-6）")
    args = ap.parse_args()

    # 顺序不可换：偏置是**拍摄级**属性，而合并会把不同拍摄的成员压进同一行、
    # note 变成复合串，之后就认不出某行原本属于哪条拍摄了。所以先扣偏置再合并。
    anchors_arg = None
    cur = SCRIPT_DIR / "anchors.csv"
    if args.take_offset:
        print(f"== 0/4 扣每条拍摄的系统性偏置（{cur.name}）==")
        out = "anchors_offset.csv" if args.merge_deg > 0 else "anchors_prepared.csv"
        cmd = [sys.executable, "offset_anchors.py",
               "--input", cur.name, "--output", out, "--write"]
        if args.allow_large_shifts:
            cmd.append("--allow-large-shifts")
        subprocess.run(cmd, cwd=SCRIPT_DIR, check=True)
        cur = SCRIPT_DIR / out
        print()

    if args.merge_deg > 0:
        print(f"== 0/4 合并同光向锚点（merge_deg={args.merge_deg}°，输入 {cur.name}）==")
        cmd = [sys.executable, "merge_anchors.py",
               "--input", cur.name, "--merge-deg", str(args.merge_deg),
               "--output", "anchors_prepared.csv", "--write"]
        if args.allow_wide_clusters:
            cmd.append("--allow-wide-clusters")
        subprocess.run(cmd, cwd=SCRIPT_DIR, check=True)
        cur = SCRIPT_DIR / "anchors_prepared.csv"
        print()

    if cur.name != "anchors.csv":
        anchors_arg = cur.name

    # 1. 生成训练数据
    print(f"== 1/3 生成训练数据（{args.samples} 样本）==")
    cmd = [sys.executable, "collect_training_data.py",
           "--samples", str(args.samples),
           "--output", "training_data.csv"]
    if anchors_arg:
        cmd += ["--anchors", anchors_arg]
    if args.smooth_order > 0:
        cmd += ["--smooth-order", str(args.smooth_order),
                "--smooth-ridge", str(args.smooth_ridge)]
    subprocess.run(cmd, cwd=SCRIPT_DIR, check=True)

    # 2. 训练 MLP
    print("\n== 2/3 训练 MLP ==")
    csv_path = SCRIPT_DIR / "training_data.csv"
    header, data = load_data(csv_path)
    input_names, output_names = split_columns(header)
    n_inputs = len(input_names)
    X = data[:, :n_inputs]
    y = data[:, n_inputs:]

    # 与 fit_mlp.py 共用同一实现——同一组超参抄两遍就会漂移，tol=1e-5 那个坑
    # 就是因为两处各写了一遍而存在了这么久。
    res = train_and_eval(X, y, hidden=args.hidden)
    model = res["model"]
    print(f"  训练迭代 {res['n_iter']} / {MAX_ITER}"
          + ("   ⚠ 触顶未收敛，请调大 MAX_ITER" if res["n_iter"] >= MAX_ITER else ""))

    # 基线必须在**换过表的进程内**算。子进程用 --anchors 换了表，父进程这份
    # ideal_params 还读着默认 anchors.csv —— 不换的话基线 R² 会掉出 1.0，
    # 而那正是哨兵要报的异常，会被误读成「标签被改写了」。
    if anchors_arg:
        import collect_training_data
        collect_training_data.set_anchors_from_path(
            SCRIPT_DIR / anchors_arg, smooth_order=args.smooth_order,
            smooth_ridge=args.smooth_ridge)
        print(f"  （基线与训练数据同用 {anchors_arg}"
              + (f"，光滑阶数 {args.smooth_order}" if args.smooth_order > 0 else "")
              + "）")

    base = idw_baseline(X)
    if base is not None:
        print("  （IDW 基线 = 标签生成器本身；三列标签都由它产生，故三列必然 ≈1.0。"
              "哪列基线掉出来，就说明那列标签又被合成规则改写了）")

    r2_scores = []
    y_means = []
    for i, name in enumerate(output_names):
        # 留出 R²——同时决定是否退化为常数
        r2 = r2_score(res["y_test"][:, i], res["y_pred_test"][:, i])
        rmse = float(np.sqrt(np.mean(
            (res["y_test"][:, i] - res["y_pred_test"][:, i]) ** 2)))
        r2_scores.append(r2)
        y_means.append(float(np.mean(y[:, i])))
        b = f"  IDW基线 R²={r2_score(y[:, i], base[:, i]):+.4f}" if base is not None else ""
        print(f"  {name:<18} 留出R²={r2:+.4f}  RMSE={rmse:.4f}{b}")

    y_mins = np.min(y, axis=0)
    y_maxs = np.max(y, axis=0)

    # 3. 生成 + 同步
    print("\n== 3/3 生成并同步 HLSL ==")
    ai_hlsl = build_hlsl(model, input_names, output_names, y_mins, y_maxs, r2_scores, y_means)
    (SCRIPT_DIR / "ai_mlp.hlsl").write_text(ai_hlsl, encoding="utf-8")
    print("  已生成 ai_mlp.hlsl")

    inline_code = build_inline_hlsl(model, input_names, output_names,
                                    y_mins, y_maxs, r2_scores, y_means)
    sync_all_targets(inline_code)

    print("\n完成。改 anchors.csv 后重复运行本脚本即可。")


if __name__ == "__main__":
    main()