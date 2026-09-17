#!/usr/bin/env python3
"""
collect_training_data.py — v6: 三特征（加 L_right 区分光的左右）
=======================================================================

MMD Toon Shader 自适应参数训练数据采集脚本。

v6 相对 v5 的根本改动
---------------------
v5 只有两个特征 (LdotV, L_up)，在「相机固定、正对角色正面」的机位下**无法区分
光的左右**：正左前方和正右前方两盏灯，这两个数完全相同 —— 左右分量只差一个
正负号，被开方丢掉了。v6 补上第三个特征 L_right = dot(L, 相机右方)，符号恢复。

v5 相对 v4 的改动（保留）
-------------------------
1. 放弃「单参考风格统计量 + Nelder-Mead 优化」的欠定方案。
   旧方案里 ShadowLocation 与 ShadowSmooth 在 shadow/trans/lit 占比上强耦合，
   导致 ShadowLocation 学不到信号（R²≈0.13）。
2. 改为「多参考点锚点 + 反距离加权(IDW)插值」：
   - ANCHORS 为不同光照方向定义理想 (ShadowSmooth, ShadowLocation, ExposureScale)
   - ideal_params() 对任意 (LdotV, L_up, L_right) 插值出理想参数

⚠ 锚点参数是审美初值，需按实际渲染效果逐锚点校准。

输入特征 (3)
-----------
    LdotV    ∈ [-1, 1]   dot(L, V_cam)  —— 光的前后分量（正 = 光在相机同侧）
    L_up     ∈ [-1, 1]   光向量的世界 Z 分量（光源高度）
    L_right  ∈ [-1, 1]   dot(L, 相机右方) —— 光的左右分量（★ 唯一的左右信息）

    ⚠ V_cam 是「每帧一个常量」（物体中心指向相机），**不是**逐像素视线向量。
      这与 shader 端 GetWorldCameraOrigin - GetObjectWorldPosition 严格一致。

      若改用逐像素 V，会导致两个后果：
        (a) AI 参数在屏幕上漂移（中心与边缘不同）；
        (b) 特征不再能确定光向，同一组特征对应差别很大的光照。

    ⚠ 本项目设计为「相机不动、正对角色正面，光源动」，所以 V_cam 是常量
      V_CAM（见下方配置区），不采样、不逐帧读取。

    L_right 的绝对值其实可由前两个开方推出（三者平方和为 1），
    补这一维取回的**只是符号** —— 而那正是区分左右所需的全部信息。

输出参数 (3)
-----------
    ShadowSmooth, ShadowLocation, ExposureScale

用法：
    python collect_training_data.py --samples 500 --output training_data.csv
    python collect_training_data.py --samples 5 --dry-run
"""

import os
os.environ.setdefault("OMP_NUM_THREADS", "1")
os.environ.setdefault("MKL_NUM_THREADS", "1")
os.environ.setdefault("OPENBLAS_NUM_THREADS", "1")
os.environ.setdefault("NUMEXPR_NUM_THREADS", "1")

import argparse
import csv
import io
import sys
import time
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import numpy as np
from math import lgamma as _lgamma

# 控制台可能是 GBK（Windows 默认），直接把 UTF-8 文本写进去会 UnicodeEncodeError。
# 与 fit_mlp.py 同一处理：包一层始终按 UTF-8 输出。
#
# 必须先查 encoding 再决定要不要包。fit_mlp.py 会 import 本模块（idw_baseline），
# 那时它已经包过一层 W1；若这里无条件再包 W2 = TextIOWrapper(W1.buffer)，W1 就
# 失去引用，GC 时 __del__ 会把它和 W2 共用的同一个底层 buffer 关掉 ——
# 之后所有 print 都报 "I/O operation on closed file"。
if hasattr(sys.stdout, "buffer") and \
        (getattr(sys.stdout, "encoding", "") or "").lower().replace("-", "") != "utf8":
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")


# ===========================================================================
# 1. 配置
# ===========================================================================

PARAM_NAMES = [
    "ShadowSmooth", "ShadowLocation", "ExposureScale",
]
FEATURE_NAMES = ["LdotV", "L_up", "L_right"]

# Bounds：训练时允许的参数搜索范围（对齐 Full 版默认值 1.0 / 0.0 / 1.0）
#
# ⚠ 这不是「参数的物理极限」，是给 IDW 输出兜底的搜索范围。
#   ideal_params 是凸组合（权重非负且和为 1），输出必然落在锚点的 [min, max] 之内。
#   ⇒ 只要锚点全在界内，resolve_params 里那次 clip 就是**空操作**。
#   ⇒ 反过来说：**锚点一旦越界，clip 就会静默削顶** —— 训练数据里该参数的 max
#     恰好等于边界值，表面看毫无异常，但美术给的峰值和它附近的整段梯度已经没了。
#   所以 main() 会先跑 validate_param_bounds() 逐行核对，锚点越界即中止。
#   要放宽就明确地改这里，并在下面写清楚依据。
PARAM_BOUNDS = [
    (0.00, 3.00),   # ShadowSmooth    — 分母；<1 阴影收窄变陡，>1 阴影扩散柔化
    (-0.50, 2.20),  # ShadowLocation  — 偏移；>0 阴影前移变多，<0 阴影后移变少
    (0.20, 2.20),   # ExposureScale   — 背光需大幅提亮（覆盖底光0.20极值）
]
# ShadowLocation 上界 2026-09-12 由 1.60 放宽到 2.20：
#   旧注释的理由是「覆盖底光 1.50 极值」。均匀 24° 重采样后锚点峰值涨到 1.98
#   （正面-65度 frame=140），1.60 把峰值削掉约 19%。新上界在实测峰值之上留了
#   ~11% 余量 —— 不是为了放开到 2.20 有意义，而是让下一次导出的小幅上探不会
#   又撞到 rails。真正的护栏是 validate_param_bounds()，不是这个数字。

N_NORMALS = 2048  # 球面法线采样数（shader 仿真用，采样管线已不再需要）

# ---------------------------------------------------------------------------
# 相机常量 —— 本项目的设计是「相机不动、正对角色正面」，故 V_cam 是常量。
# ---------------------------------------------------------------------------
# ⚠ V_CAM 必须与 UE_MMDAnchorRecorder 导出时打印的 V_cam 完全一致！
#   导出器会把解析出的 V_cam（含 Z 分量）打进日志和完成提示，导出一次抄过来即可。
#
# 当前值取自 seqV6 导出日志（关卡「测试场地」）：
#   V_cam = (0.0000, 0.9247, 0.3807)  来源：关卡相机 Actor 'CineCameraActor_0' 的当前位置
#   即 camera(-330, 420, 140) - origin(-330, 80, 0) = (0, 340, 140) 归一化。
#
# ⚠ Z 分量是**正常且必要的**，不是配置错误：角色原点在脚底（包围盒 Z 从 0 起），
#   要拍到全身相机必然高于原点。但它有个必须记住的副作用 ——
#   (V_cam, Z_up, Right) 三个基向量**不再正交**（V_cam·Z = 0.38），于是
#       LdotV² + L_up² + L_right²  不再恒等于 1
#   （均匀采样下实测 mean≈1、std≈0.20、范围 0.62~1.38；均值仍为 1 是因为
#     均匀球面下 E[(L·u)²]=1/3，三个分量各占 1/3）。
#
#   反过来说：只有 V_cam **恰好水平**时平方和才退化成常量 1。
#   所以「平方和恒为 1」是 V_CAM 配错的信号，不是正确性证据 ——
#   main() 里有一处专门的一致性检查盯着这件事。
#
# ⚠ 本常量只是**默认值与校验基准**：真正的权威是锚点表里逐行记录的 V_cam
#   （见文件末尾 resolve_vcam_from_anchors）。两者不一致时脚本会中止并要求你
#   把这个常量改过来 —— 不自动改用表里的值，是因为「相机动过」和「导出时选错了
#   参考原点」这两种情况从这里看不出区别，必须由人判断。
V_CAM = np.array([0.0, 0.9247, 0.3807], dtype=float)
V_CAM = V_CAM / np.linalg.norm(V_CAM)

_Z_UP = np.array([0.0, 0.0, 1.0])
RIGHT = np.array([1.0, 0.0, 0.0])   # 占位；下面由 set_vcam 按 V_cam 重算


def set_vcam(v):
    """切换 V_cam 并同步重算 RIGHT。

    二者必须同源：特征 (LdotV, L_up, L_right) 里最后一个分量依赖 RIGHT，
    分开改会让同一组锚点与采样点落在两个自相矛盾的空间里。
    """
    global V_CAM, RIGHT
    v = np.asarray(v, dtype=float)
    n = float(np.linalg.norm(v))
    if n < 1e-6:
        raise ValueError("V_cam 不能是零向量（相机与参考原点重合）")
    V_CAM = v / n
    raw = np.cross(_Z_UP, V_CAM)
    rn = float(np.linalg.norm(raw))
    RIGHT = raw / rn if rn > 1e-4 else np.array([1.0, 0.0, 0.0])


# 相机右方 Right = normalize(cross(Z_up, V_cam))，与 shader 端同一式。
# V_cam 恰好垂直时叉积退化为零向量，此时任取一个水平轴（与 shader 端的兜底一致）。
set_vcam(V_CAM)


def features(L: np.ndarray):
    """由光向 L 前向算出三个特征，顺序与 FEATURE_NAMES 一致。"""
    return (float(np.dot(L, V_CAM)),
            float(L[2]),
            float(np.dot(L, RIGHT)))


# ---------------------------------------------------------------------------
# 仿真常量 —— 必须与主 HLSL 文件默认值精确对齐
# ---------------------------------------------------------------------------
# Base Color / Shadow Color（固定值，仿真中不调）
_BASE_COLOR    = np.array([0.85, 0.80, 0.75])
_SHADOW_COLOR  = np.array([0.20, 0.20, 0.40])

# Rim Light（对齐 Full.hlsl L288-299，RimIntensity 固定 1.0 不预测）
_RIM_WIDTH    = 0.35
_RIM_GRADIENT = 0.15
_RIM_COLOR    = np.array([1.0, 1.0, 1.0])

# ---------------------------------------------------------------------------
# 多参考点锚点表 —— 从独立配置文件 anchors.csv 加载
# ---------------------------------------------------------------------------
# anchors.csv 每行 = LdotV, L_up, L_right, ShadowSmooth, ShadowLocation,
#                   ExposureScale, VcamX, VcamY, VcamZ, note
# 通过反距离加权(IDW)插值，为任意光照方向给出理想参数。
#
# 直接编辑 anchors.csv 即可调整锚点，改完重跑本脚本 + fit_mlp.py 重新训练。
# 尤其 ShadowLocation 一列：>0 阴影前移变多，<0 阴影后移变少。
#
# VcamX/Y/Z 是**生成该行时 UE 导出器实际用的 V_cam**，逐行落盘。这不是冗余：
# 锚点的三个特征是在某个具体 V_cam 下算出来的，与本脚本 features() 用的 V_cam
# 必须是同一个，否则 IDW 会在错误的空间里找邻居 —— 而这件事**不会报任何错**，
# 训练指标一切正常，上机才发现全错。逐行（而非全表一个值）是因为一个文件里
# 可能混着不同批次：真踩过一次，25 个锚点里有 15 个是用错误的参考原点导出的。
ANCHORS_PATH = Path(__file__).resolve().parent / "anchors.csv"

N_FEATURES = len(FEATURE_NAMES)

# V_cam 出处列（在参数列之后、note 之前）。note 必须留在最后一列。
VCAM_COLUMNS = ["VcamX", "VcamY", "VcamZ"]
# 表头前 9 列的期望值。note 是第 10 列，单独处理。
HEADER_EXPECT = FEATURE_NAMES + PARAM_NAMES + VCAM_COLUMNS


def _parse_anchors(path=None):
    """从 CSV 加载锚点表。

    返回 dict：
      data        (N, 6) 数组 [LdotV, L_up, L_right, SS, SL, EX]
      vcam        (N, 3) 数组，每行生成时用的 V_cam；缺列的行是 NaN
      notes       N 个字符串，note 列原文
      missing_vcam 没有 V_cam 的行号（1 起、含表头，便于对着编辑器找）
      linenos     N 个文件行号（同上，1 起），报错时用来直接指到那一行
    """
    p = Path(path) if path else ANCHORS_PATH
    if not p.exists():
        # 锚点表是导出产物，不是手写的。文件不存在通常意味着「删了旧的、还没重新导出」。
        raise ValueError(
            f"找不到锚点表：{p}\n"
            f"  锚点表由 UE 的 UE_MMDAnchorRecorder 导出生成。请先在关卡里**只选中角色\n"
            f"  Actor**，用 ExportAnchorsFromSequence 依次导出各个 Level Sequence ——\n"
            f"  第一个序列导出时导出器会自动建表并写入表头。")
    with p.open("r", encoding="utf-8-sig") as f:
        rows = list(csv.reader(f))
    if len(rows) < 2:
        raise ValueError(f"锚点文件为空或缺少表头：{p}")

    # 先按**表头**判定格式。不能只看数据行长度：v5 表是 6 列
    # (LdotV, L_up, SS, SL, EX, note)，v6 需要 6 个数据列，两者列数相同，
    # 「列数不足」的检查根本拦不住 —— 会一路走到 float("seq frame=0") 才炸，
    # 报出来的是一句毫无线索的转换错误。
    # utf-8-sig 只剥掉**一个** BOM。历史 anchors.csv 带双重 BOM，剩下的那个会粘在
    # 第一个列名上（"﻿LdotV"），让严格列名比对误杀一份数据其实完全正确的表。
    # ﻿ 不是 Python 的空白字符（' ﻿'.isspace() 为 False），strip() 去不掉，必须显式剥。
    header = [c.strip().lstrip(chr(0xFEFF)).strip() for c in rows[0]]
    if header[:len(HEADER_EXPECT)] != HEADER_EXPECT:
        # 特征与参数列都对，只是缺 V_cam 三列 —— 这是本次加列之前导出的表。
        # 单独报，因为它的补救办法是「重新导出一遍」，而不是「换个格式」。
        if header[:6] == FEATURE_NAMES + PARAM_NAMES:
            raise ValueError(
                f"锚点表缺少 V_cam 出处列：{p}\n"
                f"  表头应为：{', '.join(HEADER_EXPECT)},note\n"
                f"  实际表头：{', '.join(header)}\n"
                f"  没有这三列就无法判断每行的特征是在哪个 V_cam 下算出来的。而 V_cam 取错\n"
                f"  （例如导出时选中的是灯而不是角色）**不会报任何错**：训练指标正常，上机全错。\n"
                f"  旧表无法就地升级 —— 请在 UE 里选中角色 Actor，用\n"
                f"  UE_MMDAnchorRecorder 的 ExportAnchorsFromSequence 按当前版本重新导出。\n"
                f"  确实要用没有出处信息的旧表（如早先的实验变体），加 --allow-legacy-anchors。")
        raise ValueError(
            f"锚点表格式不是 v6：{p}\n"
            f"  表头应为：{', '.join(HEADER_EXPECT)},note\n"
            f"  实际表头：{', '.join(header)}\n"
            f"  v5 及更早的表只有 (LdotV, L_up) 两个特征、没有 L_right。加上 "
            f"L_right 是因为：相机固定正对角色正面时 (LdotV, L_up) 只能把光向确定到一个圆，\n"
            f"  左前光与右前光会落到同一组特征上。旧表无法就地升级 —— 请在 UE 里用\n"
            f"  UE_MMDAnchorRecorder 的 ExportAnchorsFromSequence 按当前版本重新导出。")

    need = len(HEADER_EXPECT)
    data, vcam, notes, missing_vcam, linenos = [], [], [], [], []
    for lineno, row in enumerate(rows[1:], start=2):
        if not row or not row[0].strip() or row[0].strip().startswith("#"):
            continue
        if len(row) < need:
            raise ValueError(
                f"锚点表第 {lineno} 行只有 {len(row)} 列，需要至少 {need} 列"
                f"（{', '.join(HEADER_EXPECT)}[,note]）：{row[:3]}\n  文件：{p}")
        data.append([float(x) for x in row[:6]])

        raw = [x.strip() for x in row[6:9]]
        if all(r == "" for r in raw):
            # 旧行被导出器补了空列，或手工加的行。留 NaN 标记「出处未知」。
            missing_vcam.append(lineno)
            vcam.append([float("nan")] * 3)
        elif any(r == "" for r in raw):
            raise ValueError(
                f"锚点表第 {lineno} 行的 V_cam 三列只填了一部分：{raw}\n"
                f"  要么三个都填，要么都留空（表示出处未知）。\n  文件：{p}")
        else:
            try:
                vcam.append([float(x) for x in raw])
            except ValueError:
                raise ValueError(
                    f"锚点表第 {lineno} 行的 V_cam 列无法解析成数字：{raw}\n  文件：{p}")

        notes.append(row[9] if len(row) > 9 else "")
        linenos.append(lineno)

    if not data:
        raise ValueError(f"锚点文件中没有有效数据行：{p}")
    return {"data": np.array(data), "vcam": np.array(vcam),
            "notes": notes, "missing_vcam": missing_vcam,
            "linenos": linenos}


def load_anchors(path=None):
    """兼容旧调用：只返回 (N, 6) 数据数组。需要 V_cam 出处请用 _parse_anchors。"""
    return _parse_anchors(path)["data"]


def resolve_vcam_from_anchors(prov, path=None, allow_legacy=False):
    """用锚点表逐行记录的 V_cam 校验本脚本的 V_CAM，返回最终采用的 V_cam。

    这是整条管线里唯一一处「配错也照样跑通」的地方 —— 所以宁可中止也不将就。
    校验三件事：
      1. 每行都有出处（缺列 = 加这三列之前导出的旧表）；
      2. 所有行的出处置信一致（不一致 = 文件里混了不同批次的导出）；
      3. 与配置区的 V_CAM 常量一致（不一致 = 相机/参考原点动过，或常量没跟上）。
    """
    p = Path(path) if path else ANCHORS_PATH
    missing = prov["missing_vcam"]

    if missing:
        where = f"第 {missing[0]} 行起，共 {len(missing)} 行" if missing else ""
        if not allow_legacy:
            raise SystemExit(
                f"\n锚点表缺少 V_cam 出处：{p}（{where}）\n"
                f"  没有它就无法判断这些行的特征是在哪个 V_cam 下算出来的，而 V_cam 取错\n"
                f"  （例如导出时选中的是灯而不是角色）**不会报任何错** —— 训练指标正常，上机全错。\n"
                f"  请重新导出：在 UE 里**选中角色 Actor**，再用 UE_MMDAnchorRecorder 的\n"
                f"  ExportAnchorsFromSequence 逐个序列导出。\n"
                f"  确实要用没有出处信息的旧表（如早先的实验变体），加 --allow-legacy-anchors。")
        print(f"  ⚠ --allow-legacy-anchors：{where}没有 V_cam 出处，按配置区的 V_CAM 常量处理。")
        print( "     这份表无法校验 V_cam —— 若训练结果上机后不对，先怀疑这里。")
        return V_CAM

    # 所有行都有出处：按值与 note 归类
    groups = {}
    for v, note in zip(prov["vcam"], prov["notes"]):
        groups.setdefault(tuple(np.round(v, 4)), []).append(note)

    if len(groups) > 1:
        shown = []
        for key, ns in groups.items():
            example = next((n for n in ns if n), "(无 note)")
            shown.append(f"    V_cam=({key[0]:+.4f}, {key[1]:+.4f}, {key[2]:+.4f})"
                         f"  {len(ns)} 行   例：{example}")
        raise SystemExit(
            f"\n锚点表里混了 {len(groups)} 个不同的 V_cam：{p}\n"
            + "\n".join(shown) + "\n"
            f"  同一张表里的锚点必须出自同一个特征空间，否则 IDW 会在两个空间之间找邻居，\n"
            f"  插值出来的标签没有意义。多半是某次导出选错了参考原点（例如选中了灯）。\n"
            f"  处置：在 UE 里选中角色 Actor，把上面每个序列重新导出，然后重跑本脚本。")

    file_vcam = np.array(next(iter(groups)))

    if not np.allclose(file_vcam, V_CAM, atol=1e-3):
        cos = float(np.clip(np.dot(file_vcam, V_CAM), -1.0, 1.0))
        raise SystemExit(
            f"\n锚点表的 V_cam 与本脚本不一致：{p}\n"
            f"  锚点表（UE 导出时用的）：({file_vcam[0]:+.4f}, {file_vcam[1]:+.4f}, {file_vcam[2]:+.4f})\n"
            f"  本脚本（配置区 V_CAM）： ({V_CAM[0]:+.4f}, {V_CAM[1]:+.4f}, {V_CAM[2]:+.4f})\n"
            f"  两者夹角 {np.degrees(np.arccos(cos)):.2f}° —— 特征空间对不上，IDW 会找错邻居，\n"
            f"  而且不会报任何错：训练指标一切正常，上机才发现全错。\n\n"
            f"  若确认相机与参考原点就是锚点表里那个（V_cam 由 UE 按真实场景几何算出，\n"
            f"  它才是权威），把配置区改成：\n"
            f"      V_CAM = np.array([{file_vcam[0]:.4f}, {file_vcam[1]:.4f}, {file_vcam[2]:.4f}], dtype=float)\n"
            f"  若是刚动过相机或角色位置，则反过来：重新导出锚点表。")

    return file_vcam


def validate_param_bounds(prov, path=None):
    """核对锚点的三个参数是否全落在 PARAM_BOUNDS 内，越界即中止。

    为什么必须硬失败、而不是打条 warning 就算了：resolve_params 会先把 IDW 结果
    clip 到 PARAM_BOUNDS。锚点越界时那次 clip 不是空操作，而是**静默削顶** ——
    训练数据里该参数的 max 恰好等于边界值，loss / R² 一切正常，只有主动去比对
    「标签最大值」和「边界值」是不是同一个数，才看得出来。

    2026-09-12 就是这么漏掉的：正面-65度 的 SL 到了 1.79 / 1.98，而上界还是 1.60，
    峰值被削约 19%，直到手工比对锚点量程才发现。所以这个检查补上。
    """
    p = Path(path) if path else ANCHORS_PATH
    data = prov["data"]
    notes = prov["notes"]
    linenos = prov.get("linenos") or [None] * len(notes)

    print(f"参数声明量程 vs 锚点实际量程（{p.name}，{len(data)} 行）：")
    violations = []
    for pi, name in enumerate(PARAM_NAMES):
        lo, hi = PARAM_BOUNDS[pi]
        col = data[:, N_FEATURES + pi]
        amin, amax = float(col.min()), float(col.max())
        # 容差 1e-9：CSV 里写 -0.50 与边界 -0.50 相等，是「贴着 rails」不是越界。
        under = np.where(col < lo - 1e-9)[0]
        over = np.where(col > hi + 1e-9)[0]
        mark = "   ✗ 越界" if (len(under) or len(over)) else ""
        print(f"  {name:<15} 锚点 [{amin:+.4f}, {amax:+.4f}]"
              f"   声明 [{lo:+.2f}, {hi:+.2f}]{mark}")
        violations += [(name, int(i), "下界", float(col[i]), lo) for i in under]
        violations += [(name, int(i), "上界", float(col[i]), hi) for i in over]

    if not violations:
        return

    shown = []
    for name, i, kind, val, bound in violations:
        note = notes[i] or "(无 note)"
        where = f"文件第 {linenos[i]} 行" if linenos[i] else "行号未知"
        shown.append(f"    {name} 越{kind}：{val:+.4f} > 边界 {bound:+.2f}"
                     f"   （{where}：{note}）")
    raise SystemExit(
        f"\n锚点参数越出 PARAM_BOUNDS：{p}  共 {len(violations)} 处\n"
        + "\n".join(shown) + "\n\n"
        f"  为什么这必须中止：resolve_params 会先把 IDW 结果 clip 到 PARAM_BOUNDS，\n"
        f"  锚点越界时那次 clip 不是空操作，而是**静默削顶** —— 训练数据里该参数的\n"
        f"  max 恰好等于边界值，loss / R² 全部正常，但美术给的峰值连同它附近的整段\n"
        f"  梯度已经没了。上机表现是「那个方向不够亮/不够暗」，且没有任何日志提示。\n\n"
        f"  两种处置，二选一（不要为了消掉报错而随手把边界调大）：\n"
        f"    1) 认为锚点是对的 → 放宽 collect_training_data.py 里 PARAM_BOUNDS 的\n"
        f"       对应项，并写清依据：哪次导出、峰值多少、留了多少余量。\n"
        f"    2) 认为锚点不对（例如美术误触滑块）→ 在 UE 里核对那几帧并重新导出，\n"
        f"       不要改边界去迁就。\n")


def set_anchors_from_path(path, smooth_order=0, smooth_ridge=1e-6):
    """进程内换锚点表，并做与 main() 相同的那套校验（V_cam 出处、参数边界）。

    存在的理由：`collect_training_data.py` 作为**子进程**跑时用 --anchors 换表，
    而 `fit_mlp.idw_baseline` 是在**父进程内** import 本模块调 ideal_params 的，
    后者读的是模块级 ANCHORS。两处各设一遍必然会漂移，于是漂移的表现是
    「IDW 基线 R² 掉出 1.0」—— 而那正好是管线哨兵要报的异常，会被误读成
    「标签被某条合成规则改写了」。收成一个入口，就不存在两处不一致这回事。

    smooth_order > 0 时同时按新表重建光滑场 —— 基线必须与训练的标签口径一致，
    否则哨兵会对着 IDW 目标报「R² 掉出 1.0」，而训练实际用的是光滑场。

    默认锚点表本来就加载失败（ANCHORS is None）时也照样工作：本函数是显式换表，
    不依赖导入期的那次尝试。
    """
    global ANCHORS, ANCHOR_PROV, _ANCHORS_ERR
    prov = _parse_anchors(path)
    set_vcam(resolve_vcam_from_anchors(prov, path, False))
    validate_param_bounds(prov, path)
    ANCHOR_PROV = prov
    ANCHORS = prov["data"]
    _ANCHORS_ERR = None
    set_smooth_mode(smooth_order, smooth_ridge)
    return ANCHORS


# 默认锚点表在导入时就尝试加载。若它还是 v5 及更早的格式（没有 L_right），
# 不在这里直接崩 —— 留到 main() 里报错，这样 --anchors 指向别的文件时仍然可用。
try:
    ANCHOR_PROV = _parse_anchors()
    ANCHORS = ANCHOR_PROV["data"]
    _ANCHORS_ERR = None
except Exception as _e:            # noqa: BLE001 — 任何原因都推迟到 main 报
    ANCHOR_PROV = None
    ANCHORS = None
    _ANCHORS_ERR = str(_e)

_IDW_POWER = 2.0  # 反距离加权幂次

# 这里曾有「死黑兜底」：simulate_shader 跑一遍，可见法线平均亮度 < 0.20 就把 EX 顶上去。
# 2026-09-12 已删除。UE 实拍标定的结论（别再把它加回来）：
#
#   取最深的逆光锚点 `正面-65度-均匀24度 frame=30`（SS 1.00 / SL 0.50 / EX 0.40），
#   simulate_shader 预测可见平均亮度 mean_lu = 0.0722 < 0.20 ⇒ 兜底触发，EX 被乘 2.77×
#   顶到 1.108。但同一帧的 UE 实拍画面是一个**清晰可辨的正常逆光剪影**，实测角色区域
#   平均亮度 ≈ 77/255；而 0.0722 按 sRGB 编码正是 76/255 —— 仿真的绝对亮度是准的。
#
#   ⇒ 错的是阈值的量纲：线性 0.20 编码后是 123/255，**一半亮度**，不叫「死黑」；
#     真正的死黑在 0.01~0.02（sRGB 30~40/255）。而且这帧比 500 条样本里触发样本的
#     最小值 0.0851 还暗，比训练集里最极端的样本更极端，仍然不需要兜底。
#
#   它改写了 27%（135/500）样本的 EX，几乎全聚在逆光区，作用是抬地板而非重塑曲面。
#   ⇒ 那 27% 的合成监督不是在保护画面，而是在教 MLP 放弃美术有意为之的剪影。
#   标定依据为当时的逐帧亮度采样与 UE 实测对照。


# ---------------------------------------------------------------------------
# 光滑标签模式（可选）—— 低阶球谐最小二乘，替代「精确穿过每个锚点」的 IDW
# ---------------------------------------------------------------------------
# 动机（2026-09-12）：锚点表是 5 条甩拍各自手工校的，相近光向下互相矛盾
#   （合并 4° 内实测簇内 ShadowSmooth 分歧最大 0.64；同方向跨拍摄分歧是同拍摄内的
#   1.6~2.4×）。IDW 精确穿过每个锚点 ⇒ 目标场在矛盾锚点之间带脊，光扫时阴影边界
#   逐帧跳 0.5° 以上的帧占 14%。MLP 无论容量多大都
#   只是把这堆矛盾以有限保真度复刻下来。
#
# 低阶球谐最小二乘是全局光滑的（C∞），不会出现高阶多项式的龙格震荡；代价是
#   **不再精确复现每个锚点**（残差中位约 0.15）。要保留美术关键帧就别开这个模式。
#   阶数必须低（3 阶实测 0.58% >0.5°/帧；4 阶以上开始震荡，抖动反而飙升）。
#
# 开关走 CLI：--smooth-order 3（0 = 关闭，用 IDW）。开了这个模式后采样强制单进程，
# 因为子进程只带 ANCHORS、带不过系数，重算一遍也不贵。
_SMOOTH_FIELD = None      # callable((N,3) features) -> (N,3) params，None = 用 IDW
_SMOOTH_ORDER = 0
_SMOOTH_RIDGE = 1e-6


def _light_from_features(F: np.ndarray) -> np.ndarray:
    """把 (N,3) 特征还原成世界光向 L = M⁻¹F，M 的三行是 (V_cam, ez, Right)。

    V_cam 恰好竖直时 M 奇异 —— 那种配置下光向本来就无法从特征反推，直接抛错。
    """
    M = np.stack([V_CAM, _Z_UP, RIGHT])
    L = np.linalg.solve(M, np.atleast_2d(F).T).T
    n = np.linalg.norm(L, axis=1, keepdims=True)
    return L / np.maximum(n, 1e-12)


def _sh_basis(L: np.ndarray, Lmax: int) -> np.ndarray:
    """实球谐基（含 Condon-Shortley 相位），列数 (Lmax+1)²。"""
    x, y, z = L[:, 0], L[:, 1], L[:, 2]
    phi = np.arctan2(y, x)
    cols = [np.ones(len(L)) * 0.28209479177387814]   # Y_0^0 = 1/(2√π)
    for l in range(1, Lmax + 1):
        for m in range(-l, l + 1):
            am = abs(m)
            norm = np.sqrt((2 * l + 1) / (4 * np.pi) *
                           np.exp(_lgamma(l - am + 1) - _lgamma(l + am + 1)))
            p = _assoc_legendre(l, am, np.clip(z, -1.0, 1.0))
            if m < 0:
                cols.append(norm * np.sqrt(2.0) * p * np.sin(am * phi))
            elif m == 0:
                cols.append(norm * p)
            else:
                cols.append(norm * np.sqrt(2.0) * p * np.cos(am * phi))
    return np.stack(cols, axis=1)


def _assoc_legendre(l: int, m: int, x: np.ndarray) -> np.ndarray:
    """关联勒让德 P_l^m(x)，标准递推（m 已取绝对值）。"""
    pmm = np.ones_like(x)
    if m > 0:
        somx2 = np.sqrt(np.maximum(0.0, 1.0 - x * x))
        fact = 1.0
        for i in range(1, m + 1):
            pmm = pmm * (-fact) * somx2
            fact += 2.0
    if l == m:
        return pmm
    pmmp1 = x * (2 * m + 1) * pmm
    if l == m + 1:
        return pmmp1
    pll = np.zeros_like(x)
    for ll in range(m + 2, l + 1):
        pll = ((2 * ll - 1) * x * pmmp1 - (ll + m - 1) * pmm) / (ll - m)
        pmm = pmmp1
        pmmp1 = pll
    return pll


def build_smooth_field(anchors: np.ndarray, order: int = 3,
                       ridge: float = 1e-6):
    """在锚点上做低阶球谐最小二乘，返回 callable: 特征(N,3) -> 参数(N,3)。"""
    F = np.asarray(anchors)[:, :N_FEATURES]
    Y = np.asarray(anchors)[:, N_FEATURES:]
    B = _sh_basis(_light_from_features(F), order)
    coef = np.linalg.solve(B.T @ B + ridge * np.eye(B.shape[1]), B.T @ Y)

    def field(Fq):
        return _sh_basis(_light_from_features(np.atleast_2d(Fq)), order) @ coef
    return field


def set_smooth_mode(order: int, ridge: float = 1e-6):
    """按当前 ANCHORS 重算光滑场。order<=0 关闭，退回 IDW。"""
    global _SMOOTH_FIELD, _SMOOTH_ORDER, _SMOOTH_RIDGE
    _SMOOTH_ORDER, _SMOOTH_RIDGE = int(order), float(ridge)
    if _SMOOTH_ORDER <= 0:
        _SMOOTH_FIELD = None
        return
    if ANCHORS is None:
        raise RuntimeError(f"锚点表未加载，无法建立光滑场：{_ANCHORS_ERR}")
    _SMOOTH_FIELD = build_smooth_field(ANCHORS, _SMOOTH_ORDER, _SMOOTH_RIDGE)


def ideal_params(LdotV: float, L_up: float, L_right: float) -> np.ndarray:
    """返回理想 (ShadowSmooth, ShadowLocation, ExposureScale)。

    v6 起在三维特征空间里插值。默认 IDW；开启 --smooth-order 后改为低阶球谐
    最小二乘（全局光滑，不再精确穿过锚点）。
    """
    if ANCHORS is None:
        raise RuntimeError(f"锚点表未加载：{_ANCHORS_ERR}")
    if _SMOOTH_FIELD is not None:
        return _SMOOTH_FIELD(np.array([[LdotV, L_up, L_right]], dtype=float))[0]
    pos = np.array([LdotV, L_up, L_right], dtype=float)
    d = np.linalg.norm(ANCHORS[:, :N_FEATURES] - pos, axis=1)
    d = np.maximum(d, 1e-6)
    w = 1.0 / (d ** _IDW_POWER)
    w /= w.sum()
    return (ANCHORS[:, N_FEATURES:] * w[:, None]).sum(axis=0)


# ===========================================================================
# 2. 工具函数
# ===========================================================================

def fibonacci_sphere(n: int) -> np.ndarray:
    """n 个均匀分布在单位球面上的方向向量 (n, 3)"""
    i = np.arange(n, dtype=float) + 0.5
    phi = np.arccos(1.0 - 2.0 * i / n)
    theta = np.pi * (1.0 + 5.0 ** 0.5) * i
    return np.stack([
        np.cos(theta) * np.sin(phi),
        np.sin(theta) * np.sin(phi),
        np.cos(phi),
    ], axis=1)


def smoothstep(e0: float, e1: float, x: np.ndarray) -> np.ndarray:
    t = np.clip((x - e0) / (e1 - e0 + 1e-9), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


# ===========================================================================
# 3. Shader 仿真（精确对齐 Full 版曲线阴影主路径）
# ===========================================================================
# ⚠ 采样管线**不再调用** simulate_shader（死黑兜底删除后没有调用点了）。
#   留着是因为它的绝对亮度已被 UE 实拍标定过（预测 76/255 vs 实测 ≈77/255），
#   是逐参数调 shader 时唯一能在 Python 侧预判画面亮度的工具。

def simulate_shader(normals: np.ndarray, L: np.ndarray, V: np.ndarray,
                    params: np.ndarray):
    """
    在 normals (M, 3) 上仿真 Full 版曲线阴影主路径，返回 (Color, rampU)。

    对齐 Full.hlsl：
      UseCurve=1 分支（L222-235）：rampU = saturate(NdotL/SS - SL)；
        FinalToon = lerp(ShadowColorAdj, RampLit, saturate(rampU*2))；
        ShadowMask = saturate(rampU)
      曲线图集 RampLit 以线性灰阶近似（中性假设，不随光照变化）。
      Rim（L288-299）：RimMask×saturate(NdotL)×ShadowMask，RimIntensity=1.0。
      曝光（L339）：Color *= ExposureScale。

    未覆盖（对目标参数影响可忽略）：Matcap 双高光 / AO(HM.g) / SSS /
      法线贴图 / 色调 / 饱和度 / HSV 调色。色带分支为过时方案不仿真。

    输入 params 顺序 (ShadowSmooth, ShadowLocation, ExposureScale)
    """
    SS, SL, EX = params

    NdotL = normals @ L
    rampU = np.clip(NdotL / max(0.001, SS) - SL, 0.0, 1.0)  # saturate

    # 曲线图集近似：线性灰阶
    RampLit = rampU  # float3 三通道相同
    # FinalToon = lerp(ShadowColor, RampLit, saturate(rampU*2))
    ToonMix = np.clip(rampU * 2.0, 0.0, 1.0)
    FinalToon = _SHADOW_COLOR * (1.0 - ToonMix[:, None]) + RampLit[:, None] * ToonMix[:, None]

    Color = _BASE_COLOR * FinalToon
    ShadowMask = rampU

    # ── Rim Light（对齐 Full.hlsl L288-299，RimIntensity 固定 1.0）──
    NdotV = np.abs(normals @ V)
    Fresnel = 1.0 - NdotV

    RimThreshold = 1.0 - np.clip(_RIM_WIDTH, 0.0, 1.0)                  # = 0.65
    RimEdgeHW = 0.002 + (0.3 - 0.002) * np.clip(_RIM_GRADIENT, 0.0, 1.0)  # ≈ 0.0467
    RimMask = smoothstep(RimThreshold - RimEdgeHW,
                         RimThreshold + RimEdgeHW, Fresnel)
    RimLightMask = np.clip(NdotL, 0.0, 1.0)   # saturate(NdotL)，无 0.6 保底
    Rim = RimMask * RimLightMask * ShadowMask * 1.0
    Color = Color + Rim[:, None] * _RIM_COLOR

    # ── 曝光 ──
    Color = Color * EX

    return Color, rampU


# ===========================================================================
# 4. 多参考点解析（纯锚点插值）
# ===========================================================================

def resolve_params(L: np.ndarray):
    """
    多参考点解析：锚点给出理想 (SS, SL, EX)，clip 到 PARAM_BOUNDS。

    默认用 3D IDW；开启 --smooth-order 后改用低阶球谐最小二乘光滑场
    （由 set_smooth_mode 建立）。

    L 由采样给出，三个特征由 features(L) 前向计算 —— v6 起 V_cam 是常量，
    不再采样相机方向。

    **三个输出都是纯标签场的值，没有任何合成规则改写。** 这里曾对 EX 做「死黑兜底」
    （因此也曾需要一份法线球来跑 simulate_shader），2026-09-12 已删除。
    理由见本文件上方 _IDW_POWER 下面的长注释 ——
    简言之：仿真的绝对亮度经 UE 实拍标定是准的，错的是 0.20 这个阈值的量纲
    （= 一半亮度，不叫死黑）。删掉后本函数不再需要法线球。

    返回 (LdotV, L_up, L_right, params)。
    """
    LdotV, L_up, L_right = features(L)

    bounds_arr = np.array(PARAM_BOUNDS)
    p = ideal_params(LdotV, L_up, L_right)
    p = np.clip(p, bounds_arr[:, 0], bounds_arr[:, 1])

    return LdotV, L_up, L_right, p


# ---------------------------------------------------------------------------
# Worker：用于 ProcessPoolExecutor
# ---------------------------------------------------------------------------

def _init_worker(anchors: np.ndarray):
    """
    子进程初始化。

    Windows 走 spawn，每个 worker 会重新 import 本模块 —— 模块级的 ANCHORS
    来自**默认** anchors.csv，父进程 --anchors 的覆盖带不过来。不显式传的话，
    `--anchors 变体.csv` 只在父进程生效，子进程仍按默认表算标签（默认表还是
    v5 格式时则直接抛「锚点表未加载」）。
    """
    global ANCHORS, _ANCHORS_ERR
    ANCHORS = anchors
    _ANCHORS_ERR = None


def _optimize_one(task):
    idx, L = task
    LdotV, L_up, L_right, params = resolve_params(L)
    return idx, LdotV, L_up, L_right, params.tolist()


# ===========================================================================
# 6. 光照空间采样
# ===========================================================================

def sample_light(rng: np.random.Generator) -> np.ndarray:
    """球面均匀采样光向 L（单位向量，指向光源）。

    相机不动、光在动，所以这里只采光。全向均匀覆盖保证 shader 在任意光向下
    都有锚点约束；若只想覆盖实际用到的仰角，可在这里收紧。
    """
    u   = rng.uniform(-1.0, 1.0)
    phi = rng.uniform(0.0, 2.0 * np.pi)
    s   = np.sqrt(1.0 - u * u)
    return np.array([s * np.cos(phi), s * np.sin(phi), u])


# ===========================================================================
# 7. 主流程
# ===========================================================================

def main():
    ap = argparse.ArgumentParser(
        description="MMD Toon Shader 自适应参数训练数据采集 (v6: 三特征)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--samples", type=int, default=500, help="样本数 (默认 500)")
    ap.add_argument("--output",  type=Path, default=Path("training_data.csv"),
                    help="输出 CSV 路径")
    ap.add_argument("--seed",    type=int, default=42, help="随机种子")
    ap.add_argument("--workers", type=int, default=0,
                    help="并行 worker 数（默认 0 = CPU 核数 - 1；设 1 退化为单进程）")
    ap.add_argument("--anchors", type=Path, default=None,
                    help="锚点表路径（默认 AIControl/anchors.csv；可指向实验变体）")
    ap.add_argument("--dry-run", action="store_true", help="只打印前 5 条样本，不写文件")
    ap.add_argument("--allow-legacy-anchors", action="store_true",
                    help="允许锚点表没有 V_cam 出处列（无法校验特征空间，自担风险）")
    ap.add_argument("--smooth-order", type=int, default=0,
                    help="光滑标签模式：低阶球谐阶数（0 = 关闭用 IDW；推荐 3）。"
                         "开启后不再精确穿过锚点，换取逐帧平滑")
    ap.add_argument("--smooth-ridge", type=float, default=1e-6,
                    help="光滑拟合的 ridge 正则（默认 1e-6）")
    args = ap.parse_args()

    global ANCHORS, ANCHOR_PROV, _ANCHORS_ERR
    if args.anchors is not None:
        ANCHOR_PROV = _parse_anchors(args.anchors)
        ANCHORS = ANCHOR_PROV["data"]
        _ANCHORS_ERR = None

    if ANCHORS is None:
        sys.exit(_ANCHORS_ERR)

    # 先把 V_cam 校准到锚点表记录的那个，再谈别的 ——
    # features() / RIGHT 都依赖它，校晚了采样点就已经落在错误空间里了。
    set_vcam(resolve_vcam_from_anchors(ANCHOR_PROV, args.anchors, args.allow_legacy_anchors))

    # V_cam 对了还不够：锚点自己也得在声明的参数范围内，否则后面的 clip 会静默削顶。
    validate_param_bounds(ANCHOR_PROV, args.anchors)

    # 光滑场建立在 ANCHORS 之上，必须在换表 + 校 V_cam 之后。
    set_smooth_mode(args.smooth_order, args.smooth_ridge)

    if args.workers == 0:
        n_workers = max(1, (os.cpu_count() or 2) - 1)
    else:
        n_workers = max(1, args.workers)
    if args.dry_run or args.samples < 50:
        n_workers = 1
    # 光滑场是父进程内的系数，子进程重新导入模块只会拿到 IDW —— 直接单进程。
    if _SMOOTH_FIELD is not None and n_workers != 1:
        print("  （光滑标签模式：强制单进程，系数不进子进程）")
        n_workers = 1

    rng = np.random.default_rng(args.seed)

    print(f"相机常量 V_cam = ({V_CAM[0]:+.3f}, {V_CAM[1]:+.3f}, {V_CAM[2]:+.3f})"
          f"   右方 Right = ({RIGHT[0]:+.3f}, {RIGHT[1]:+.3f}, {RIGHT[2]:+.3f})")
    print(f"  ✓ 已与锚点表逐行记录的 V_cam 出处核对一致（{len(ANCHORS)} 行）\n")

    # 打印锚点表（多参考点方案）
    print(f"多参考点锚点表（{len(ANCHORS)} 个锚点）：")
    for a in ANCHORS:
        feat = "  ".join(f"{n}={v:+.2f}" for n, v in zip(FEATURE_NAMES, a[:N_FEATURES]))
        par  = "  ".join(f"{n}={v:+.2f}" for n, v in zip(["SS", "SL", "EX"], a[N_FEATURES:]))
        print(f"  {feat}  ->  {par}")

    # 注：这里曾有一处「锚点特征平方和应为 1」的一致性检查，已删除。
    # V_cam 带 Z 分量时 (V_cam, Z_up, Right) 非正交，平方和本来就不是常量，
    # 该检查只有在「V_CAM 被配成水平、而锚点不是」这一个特例下才触发 ——
    # 实测挡不住真正踩到的情形（V_CAM 非水平、导出器用了另一个非水平的 V_cam）。
    # 现在改为上面 resolve_vcam_from_anchors() 的逐行出处比对：直接比 V_cam 本身，
    # 不再依赖任何间接几何推论。特征平方和的统计仍会打印在末尾的覆盖报告里，
    # 用作「基向量是否非正交」的旁证，不再承担校验职责。
    print()

    # 2. 采样光向 + 解析（采样空间与可行域完全一致，无拒绝）
    target = 5 if args.dry_run else args.samples
    t0 = time.time()
    rows = []

    def _report():
        if not args.dry_run:
            elapsed = time.time() - t0
            eta = elapsed / len(rows) * (target - len(rows)) if rows else 0.0
            print(f"  [{len(rows):>4}/{target}]  耗时 {elapsed:5.1f}s  剩余约 {eta:5.1f}s")

    if n_workers == 1:
        # ---- 单进程路径 ----
        for _ in range(target):
            L = sample_light(rng)
            LdotV, L_up, L_right, params = resolve_params(L)
            rows.append([LdotV, L_up, L_right, *params.tolist()])
            if len(rows) % 50 == 0:
                _report()
    else:
        # ---- 多进程路径 ----
        print(f"使用 {n_workers} 个 worker 进程")
        tasks = [(k, sample_light(rng)) for k in range(target)]

        chunk = max(8, len(tasks) // (n_workers * 4))
        with ProcessPoolExecutor(max_workers=n_workers,
                                 initializer=_init_worker,
                                 initargs=(ANCHORS,)) as ex:
            for idx, LdotV, L_up, L_right, params in ex.map(_optimize_one, tasks,
                                                            chunksize=chunk):
                rows.append([LdotV, L_up, L_right, *params])
                if len(rows) % 50 == 0:
                    _report()

    # 3. 输出
    if args.dry_run:
        print("\n[dry-run] 前几条样本（" + ", ".join(FEATURE_NAMES + PARAM_NAMES) + "）：")
        for r in rows:
            print("  ", [round(x, 4) for x in r])
        return

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(FEATURE_NAMES + PARAM_NAMES)
        w.writerows(rows)

    arr = np.array(rows)
    print(f"\n写入 {len(rows)} 条样本 → {args.output}  (总耗时 {time.time()-t0:.1f}s)")
    if _SMOOTH_FIELD is not None:
        print(f"  （三个输出都是锚点的 {_SMOOTH_ORDER} 阶球谐最小二乘光滑场，"
              f"ridge={_SMOOTH_RIDGE:g}，不再精确穿过锚点）")
    else:
        print("  （三个输出都是纯锚点 IDW，无任何合成规则改写）")
    print("\n输出参数统计 (mean ± std)：")
    for i, name in enumerate(PARAM_NAMES):
        col = arr[:, N_FEATURES + i]
        print(f"  {name:<18s}  {col.mean():.3f} ± {col.std():.3f}   "
              f"[{col.min():.3f}, {col.max():.3f}]")

    # 4. 特征覆盖报告
    print("\n光照角度覆盖：")
    for i, name in enumerate(FEATURE_NAMES):
        col = arr[:, i]
        print(f"  {name:<8s} [{col.min():+.3f}, {col.max():+.3f}]   均值 {col.mean():+.3f}")
    ldv, lup, lrt = arr[:, 0], arr[:, 1], arr[:, 2]
    print(f"  背光占比 (LdotV<0)      = {(ldv < 0).mean()*100:.1f}%")
    print(f"  左侧光占比 (L_right<0)  = {(lrt < 0).mean()*100:.1f}%")
    # V_cam 带 Z 分量时三个基向量非正交，平方和不再是常量：
    # 均值仍为 1（均匀球面 E[(L·u)²]=1/3，三分量各 1/3），但 std > 0、范围超出 [0,1]。
    # 若这里反而打印出 std≈0 且恒等于 1，说明 V_CAM 被配成了水平 —— 与导出器不一致。
    s = ldv**2 + lup**2 + lrt**2
    print(f"  特征平方和              = {s.mean():.4f} ± {s.std():.4f}   "
          f"[{s.min():.4f}, {s.max():.4f}]")


if __name__ == "__main__":
    main()
