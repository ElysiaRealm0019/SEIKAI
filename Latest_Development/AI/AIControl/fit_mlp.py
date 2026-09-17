#!/usr/bin/env python3
"""
fit_mlp.py — 神经网络(MLP)拟合训练数据 + 生成 HLSL 代码

评估口径（v5）
--------------
切 20% 留出集后再训练，报告里 R2(train) 与 R2(holdout) 并列：

  · 代码注释、退化判据（R² < 0.20 退化为常数）一律用 **留出 R²**。
    旧版 fit 完直接 predict(X)，是训练集内样本指标，随容量虚高，
    既不能判断泛化，写进论文也会被审稿人问。

  · 同时打印 **IDW 闭式基线**（= 标签生成器 collect_training_data.ideal_params）。
    ⚠ 2026-09-12 起**三列的标签都是纯 ideal_params + clip**（EX 的死黑兜底已删），
    所以三列的基线都必然 R²≈1.0。⇒ **每一列的 R² 都只反映「MLP 以有限保真度
    复刻自己的标签生成器」，不反映「学到了着色规律」。**
    基线因此从「找真信号」变成了「验管线」：哪一列基线掉出 1.0，
    就说明该列标签又被某条合成规则改写了，而 R² 的读法跟着变。
"""
import argparse
import csv
import io
import sys
from datetime import datetime
from pathlib import Path
import numpy as np

# 本脚本要打印 ⚠ / ≈ / ² ，GBK 控制台会 UnicodeEncodeError，故包一层按 UTF-8 输出。
#
# ⚠ 必须先查 encoding 再决定要不要包，不能无条件包。
#   若 sys.stdout 已经是本模块（或别的模块）包过的 TextIOWrapper，再包一次就是
#   W2 = TextIOWrapper(W1.buffer)：W1 随即失去唯一引用被 GC，其 __del__ 会关掉
#   W1 与 W2 共用的同一个底层 buffer —— 之后所有 print 都报
#   "ValueError: I/O operation on closed file"。
#   实测可复现：先 import collect_training_data（它装了 UTF-8 包装）再 import 本模块，
#   或自己先包一层再 import 本模块，都会踩到。
#   collect_training_data.py 与 retrain_all.py 都带同样的判据，三处必须一致。
if hasattr(sys.stdout, "buffer") and \
        (getattr(sys.stdout, "encoding", "") or "").lower().replace("-", "") != "utf8":
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

try:
    from sklearn.neural_network import MLPRegressor
    from sklearn.metrics import r2_score
    from sklearn.model_selection import train_test_split
except ImportError:
    sys.exit("需要 scikit-learn：pip install scikit-learn")

def load_data(csv_path: Path):
    with csv_path.open(encoding="utf-8-sig") as f:
        rows = list(csv.reader(f))
    header = rows[0]
    data = np.array([[float(x) for x in r] for r in rows[1:]])
    return header, data

# 输出列（= 材质参数）名。特征列数由它反推，不硬编码。
PARAM_NAMES = ["ShadowSmooth", "ShadowLocation", "ExposureScale"]


def split_columns(header):
    """
    按**列名**把表头切成 (input_names, output_names)。

    旧版两处都写死 n_inputs = 2。特征从 (LdotV, L_up) 扩到 (LdotV, L_up, L_right)
    时，那个 2 会把 L_right 静默当成输出列，训出一个 2→H→4 的网络而没有任何报错。
    列名反推则扩维时自动跟上，列名对不上时直接报错。
    """
    missing = [p for p in PARAM_NAMES if p not in header]
    if missing:
        raise SystemExit(
            f"训练数据缺少输出列 {missing}。\n"
            f"实际表头：{header}\n"
            f"（特征列 + {PARAM_NAMES} 共 {len(PARAM_NAMES)} 个输出列）")
    n_inputs = header.index(PARAM_NAMES[0])
    if n_inputs < 1:
        raise SystemExit(f"表头里第一个输出列之前没有特征列：{header}")
    return header[:n_inputs], header[n_inputs:]

# ---------------------------------------------------------------------------
# 训练 / 评估常量
# ---------------------------------------------------------------------------
# 隐藏层宽度。64 在训练集内只能到 R²≈0.957（可达上限 0.995），误差集中在锚点
# 影响半径内那不到 1% 的域；256 把它提到 0.994。代价是 shader 里的乘加数
# 320 → 1280（隐藏层 2H + 输出层 3H），换来留出 R² +0.01/+0.04/+0.01。
#
# ⚠ 2026-09-12：那段「256 更好」的结论只对了 R²，忽略了**逐帧平滑**。
# 容量扫描（同一份 IDW 标签，只改 H，_exp 无此脚本）实测边界抖 >0.5°/帧 的帧占比：
#   H=16 → 1.3%、24 → 5.0%、64 → 12.7%、256 → 14.2%。
# 原因：容量越高，网络越能把 IDW 目标里「相近光向下互相矛盾的锚点」形成的脊
# 也拟合进去 —— 那正是闪烁。R² 是在给这些矛盾打分，指标越高反而越糟。
# 因此默认容量回到 64：配合光滑标签（collect_training_data.py --smooth-order）时
# 抖动 0.14%，且 shader 侧乘加数只有 256 版的 1/4。
HIDDEN_DEFAULT = 64

# lbfgs 而非 adam：adam 的定步长 0.001 在平坦谷底会被 tol 判停（实测第 210 次
# 就停机、预算 5000），训练集 R² 被压到 0.90/0.87/0.83，纯属优化器假象 ——
# 换 lbfgs 后同一容量直接到 0.9798/0.9821/0.9865。调大学习率反而更差。
# 注：lbfgs 对 tol 不敏感（实测 tol=1e-4 与 1e-9 的 n_iter 完全相同），故不再暴露。
SOLVER         = "lbfgs"
MAX_ITER       = 5000
TEST_SIZE      = 0.2     # 留出集比例
SEED           = 42
DEGENERATE_R2  = 0.20    # 低于此值则退化为常数（判据用留出 R²，不用训练集 R²）


def idw_baseline(X: np.ndarray):
    """
    IDW 闭式基线 —— 直接取标签生成器 collect_training_data.ideal_params。

    存在的意义是把「R² 到底在衡量什么」摆到台面上：自 2026-09-12 删掉 EX 的死黑
    兜底后，**三列的标签都是纯 ideal_params + clip**，故基线必然三列都 R²≈1.0，
    说明 MLP 只是在以有限保真度复刻自己的标签生成器。

    ⚠ 于是基线的角色变了：它不再是「找出哪列有真信号」，而是**管线的哨兵** ——
    哪一列的基线掉出 1.0，就说明该列的标签又被某条合成规则改写了，
    R² 的读法必须跟着改。基线 ≈1.0 是「标签生成器没背着人动手脚」的证据。

    拿不到 anchors.csv / 无法导入时为 None，评估照常进行 —— 但**不静默**：
    会把原因打出来。基线是判断「R² 到底在衡量什么」的唯一参照，它缺席时
    R² 就只剩「MLP 复刻自己标签生成器的保真度」这一种读法，容易被误当成
    「学到了着色规律」。说不出原因的 n/a 比没有基线更危险。
    """
    try:
        from collect_training_data import ideal_params
        return np.array([ideal_params(*row) for row in X])
    except Exception as e:            # noqa: BLE001 — 任何原因都要报出来
        lines = str(e).strip().splitlines() or [repr(e)]
        print(f"  ⚠ IDW 基线不可用（{type(e).__name__}）：{lines[0]}")
        for extra in lines[1:]:
            print(f"     {extra}")
        print("     基线缺席时，下面 SS/SL 的 R² 只说明 MLP 复刻标签生成器的保真度，")
        print("     不说明学到了着色规律。")
        return None


def train_and_eval(X, y, hidden=HIDDEN_DEFAULT, test_size=TEST_SIZE, seed=SEED):
    """
    训练 MLP + 留出法评估，返回 dict。

    旧版在**训练集**上算 R²（fit 完直接 predict(X)），那个数会随模型容量虚高，
    不能用来判断泛化、写进论文也会被审稿人问。这里先切留出集再训练，
    训练集 R² 仅作对照输出，判据一律用留出 R²。
    """
    X_tr, X_te, y_tr, y_te = train_test_split(
        X, y, test_size=test_size, random_state=seed)
    model = MLPRegressor(
        hidden_layer_sizes=(hidden,),
        activation='relu',
        solver=SOLVER,
        max_iter=MAX_ITER,
        random_state=seed,
    )
    model.fit(X_tr, y_tr)
    return {
        "model":       model,
        "y_train":     y_tr,
        "y_pred":      model.predict(X_tr),
        "y_test":      y_te,
        "y_pred_test": model.predict(X_te),
        "n_iter":      model.n_iter_,
    }


def build_hlsl(model, input_names, output_names, y_mins, y_maxs, r2_scores, y_means):
    W1 = model.coefs_[0]
    b1 = model.intercepts_[0]
    W2 = model.coefs_[1]
    b2 = model.intercepts_[1]

    n_in = W1.shape[0]
    n_hid = W1.shape[1]
    n = len(output_names)

    out = []
    out.append("// ============================================================================")
    out.append(f"// MMD Toon Shader — AI Neural Network Control (Generated by fit_mlp.py)")
    out.append(f"// MLP Architecture: {n_in} -> {n_hid} (ReLU) -> Linear")
    out.append(f"// 下列 R² 均为留出集（{TEST_SIZE:.0%} holdout）指标，非训练集内样本。")
    out.append("// ============================================================================")
    out.append("// 相比多项式回归，神经网络能更平滑地处理极端光照角度（如光源0度侧对时，")
    out.append("// 避免了多项式预测过大导致阴影蔓延到受光面的问题），推断代价也非常低。")
    out.append("")
    in_desc = " / ".join(input_names)
    out.append("// ===== 用法：单前置 Custom Node（推荐，无 .ush 依赖）=====")
    out.append("//   找下方代码，贴到 Custom Node 的 Code 字段。")
    out.append(f"//   Inputs:  {in_desc}  (各 Float1)")
    out.append(f"//   Output:  Float{n}  ({', '.join(output_names)})")
    out.append(f"//   用 ComponentMask 拆开 {n} 个标量，喂给主材质 Custom Node。")
    out.append("")
    out.append("// =========================================================")
    out.append(f"// Custom Node: MMDToonAI")
    out.append(f"// Inputs:  {in_desc}  (各 Float1)")
    out.append(f"// Output:  Float{n}  ({', '.join(output_names)})")
    out.append("// --- begin -----------------------------------------------")

    for i in range(n_hid):
        terms = []
        for j in range(n_in):
            weight = W1[j, i]
            if abs(weight) > 1e-6:
                terms.append(f"{weight:+.6f} * {input_names[j]}")
        bias = b1[i]
        expr = " ".join(terms) + f" {bias:+.6f}"
        out.append(f"float h_{i} = max(0.0, {expr});")

    out.append("")

    for p in output_names:
        idx = output_names.index(p)
        r2 = r2_scores[idx]
        if r2 < DEGENERATE_R2:
            out.append(f"float out_{p} = {y_means[idx]:.6g};  // 常数（留出R² {r2:+.3f}）")
        else:
            terms = []
            for j in range(n_hid):
                weight = W2[j, idx]
                if abs(weight) > 1e-6:
                    terms.append(f"{weight:+.6f} * h_{j}")
            bias = b2[idx]
            expr = " ".join(terms) + f" {bias:+.6f}"

            span = y_maxs[idx] - y_mins[idx]
            vmin = y_mins[idx] - 0.02 * span
            vmax = y_maxs[idx] + 0.02 * span
            out.append(f"// {p}: 留出R²={r2:+.3f}")
            out.append(f"float out_{p} = clamp({expr}, {vmin:.4g}, {vmax:.4g});")

    out.append("")
    out.append(f"return float{n}({', '.join(['out_' + n for n in output_names])});")
    out.append("// --- end -------------------------------------------------")
    out.append("")

    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", type=Path, default=Path("training_data.csv"))
    ap.add_argument("--output", type=Path, default=Path("ai_mlp.hlsl"))
    ap.add_argument("--hidden", type=int, default=HIDDEN_DEFAULT, help="隐藏层神经元数量")
    ap.add_argument("--test-size", type=float, default=TEST_SIZE, help="留出集比例（默认 0.2）")
    args = ap.parse_args()

    if not args.input.exists():
        sys.exit(f"找不到输入文件：{args.input}")

    header, data = load_data(args.input)
    input_names, output_names = split_columns(header)
    n_inputs = len(input_names)

    X = data[:, :n_inputs]
    y = data[:, n_inputs:]

    print(f"训练数据维度: {X.shape}, 隐藏层: {args.hidden}, "
          f"留出集: {args.test_size:.0%}")

    res = train_and_eval(X, y, hidden=args.hidden, test_size=args.test_size)
    model = res["model"]

    it = res["n_iter"]
    print(f"训练迭代: {it} / {MAX_ITER}"
          + ("   ⚠ 触顶未收敛，请调大 MAX_ITER" if it >= MAX_ITER else ""))

    base = idw_baseline(X)

    print("-" * 76)
    print(f"{'Parameter':<18}{'R2(train)':>12}{'R2(holdout)':>13}"
          f"{'RMSE(hold)':>13}{'IDW base':>12}")
    print("-" * 76)
    r2_scores = []
    y_means = []
    for i, name in enumerate(output_names):
        r2_tr = r2_score(res["y_train"][:, i], res["y_pred"][:, i])
        r2_te = r2_score(res["y_test"][:, i], res["y_pred_test"][:, i])
        rmse = float(np.sqrt(np.mean((res["y_test"][:, i] - res["y_pred_test"][:, i])**2)))
        b = f"{r2_score(y[:, i], base[:, i]):>12.4f}" if base is not None else f"{'n/a':>12}"
        r2_scores.append(r2_te)          # ← 用留出 R² 决定退化与代码注释
        y_means.append(float(np.mean(y[:, i])))
        print(f"{name:<18}{r2_tr:>12.4f}{r2_te:>13.4f}{rmse:>13.4f}{b}")

    y_mins = np.min(y, axis=0)
    y_maxs = np.max(y, axis=0)

    hlsl_code = build_hlsl(model, input_names, output_names, y_mins, y_maxs, r2_scores, y_means)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(hlsl_code, encoding='utf-8')
    print(f"\nHLSL 代码已保存至 {args.output}")

if __name__ == "__main__":
    main()
