# MMD Toon Shader — 源码树索引

> 最后整理：2026年9月17日
> **本目录（`Latest_Development/`）是全部源码与文档所在。** 仓库根目录另有
> `README.md`（项目简介）、`MMDToonShader_SM5_SingleFunc_Full_使用文档.md`（整合版详细说明）
> 和 `MMD_Bone_Name_Dict_EN.csv`（MMD 骨骼名日英对照表）。

---

## 目录结构

### 1. Character（角色版着色器）
| 文件 | 说明 |
|---|---|
| `MMDToonShader_SM5_SingleFunc.hlsl` | 早期主文件，三层 Toon 阴影 / Rim / Specular / Matcap（历史基线） |
| `MMDToonShader_SM5_SingleFunc_Hair.hlsl` | 头发边缘半透明专属版 |
| `MMDToonShader_SM5_SingleFunc_Alpha.hlsl` | 早期 Alpha 输出版 |
| `MMDToonShader_SM5_SingleFunc_Full.hlsl` | **整合版基线**：SingleFunc 全部 39 参数 + 示例材质 15 项新特性 |
| `MMDToonShader_SM5_SingleFunc_Full_Accessories.hlsl` | 配件版（各向异性高光增强） |
| `MMDToonShader_SM5_SingleFunc_Full_Test.hlsl` | 试验版：+ `HairMapMode` / `RimEnvMode` / `MatcapSharpen` / `SpecGate` |
| `MMDToonShader_SM5_SingleFunc_Full_Alpha.hlsl` | **功能最全**：Test 的全部特性 + `AlphaChannelMode`（4 种取 Alpha 方式） |

### 2. AI（AI 辅助系统）
| 文件 | 说明 |
|---|---|
| `MMDToonShader_SM5_SingleFunc_Full_AI.hlsl` | 整合版 + 内嵌 MLP 权重（位于 `AI/` 下，因为 `retrain_all.py` 要求它在 `AIControl/` 上一层） |
| `MMDToonShader_SM5_SingleFunc_Full_Alpha_AI.hlsl` | 半透明变体，与上面共用同一套 MLP 权重 |
| `AIControl/anchors.csv` | **唯一需要手改的输入**：`(LdotV, L_up, L_right) → (ShadowSmooth, ShadowLocation, ExposureScale)` 锚点（v6） |
| `AIControl/offset_anchors.py` | 扣掉每条拍摄的系统性偏置（`--take-offset` 时自动跑） |
| `AIControl/merge_anchors.py` | 合并同一光向的重复锚点（可选） |
| `AIControl/collect_training_data.py` | v6 数据采集：多参考点锚点 + 反距离加权(IDW)；`--smooth-order 3` 改用 3 阶球谐光滑场 |
| `AIControl/fit_mlp.py` | MLP 训练 + HLSL 代码生成（默认 64 隐藏层，lbfgs） |
| `AIControl/retrain_all.py` | **一键重训入口**：偏置/光滑 → 生成数据 → 训练 → 写 `ai_mlp.hlsl` → 同步两份 `Full_*_AI.hlsl` |
| `AIControl/ai_mlp.hlsl` | 生成物（勿手改）：3 → 64 ReLU → 3，供 UE Custom Node 使用 |
| `AIControl/training_data.csv` | 生成物：500 条训练样本 |
| `UE_MMDAnchorRecorder/` | UE 编辑器插件，用于录制锚点 |

**重训流程**：改 `AIControl/anchors.csv` → `cd AI/AIControl && python retrain_all.py --take-offset --smooth-order 3`
> `ai_mlp.hlsl` 和两份 `Full_*_AI.hlsl` 的 `AUTO-MLP-BEGIN/END` 区间都是生成物，手改会被覆盖。
> 闪烁修复（光滑标签 + 降容量至 64）见 `Documentation/MMDToonShader_Full_AI_使用文档.md` 9.5。

### 3. Architecture（建筑版）
- `MMDToonShader_SM5_SingleFunc_Architecture.hlsl`：建筑/场景表面专属（Unlit）
- `MMDToonShader_SM5_Architecture_Lit.hlsl`：建筑 Lit 版，可接收动态阴影

### 4. Outline（描边方案）
- `MMDToonShader_SM5_Outline_Stable.hlsl`：抗抖动描边（**推荐**）
- `MMDToonShader_SM5_OutlineHull.hlsl`：Inverted Hull 方案
- `MMDToonShader_SM5_Outline.hlsl`：早期八方向阈值判边版

### 5. Effects / Debug
- `Effects/RaindropHelpers.ush`、`Effects/RaindropMaterial.hlsl`：雨滴效果
- `Debug/MMDToonShader_SM5_Debug_NormalBugs.hlsl`：法线贴图 Bug 复现工具

### 6. Documentation（技术文档）
- `MMDToonShader_SM5_SingleFunc_使用文档.md`：SingleFunc 主文件完整参数手册、材质图连接与故障排查
- `ShaderPrinciples.md`：Shader 原理深度解析
- `MMDToonShader_Logic.md`：Shader 逻辑说明
- `Evolution_From_Polynomial_To_MLP.md`：从多项式回归到 MLP 的技术演进
- `Training_Data_Generation_Logic.md`：训练数据生成逻辑
- `Why_AI_Rendering_Logic.md`：AI 渲染逻辑解析
- `MMDToonShader_Full_AI_使用文档.md`：AI 驱动版使用文档
- `Performance_Test_Plan.md`：性能与兼容性测试计划（设备分档 / 测量方法 / 通过判据）

### 7. 其他
- `VERSION_COMPARISON.md`：SingleFunc / 示例材质 / Full 版三版本功能矩阵对比
- `PARAMETER_OPTIMIZATION.md`、`OLD_VERSION_ANALYSIS.md`：参数优化与旧版分析

---

## 已知问题

1. **AI 版落后渲染版一代**：`AI/MMDToonShader_SM5_SingleFunc_Full_AI.hlsl` 停留在 Sep 9，
   尚未包含 `Full_Test` / `Full_Alpha` 在 Sep 11 加入的 `SpecGate`、`RimEnvMode`、
   `MatcapSharpen`、`HairMapMode` 四项改进。合并需单独一轮并重新在 UE 中验证。
