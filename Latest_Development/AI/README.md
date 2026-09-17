# MMD Toon Shader — AI 驱动版

> 对应文件：`MMDToonShader_SM5_SingleFunc_Full_AI.hlsl`（不透明）  
> 半透明变体：`MMDToonShader_SM5_SingleFunc_Full_Alpha_AI.hlsl`（共享同一套 MLP 权重）  
> 基线：配件增强版 `MMDToonShader_SM5_SingleFunc_Full_Accessories.hlsl` + v2 渲染改进  
> UE 材质：不透明 `M_MMDToon_Full_AI` / 半透明 `M_MMDToon_Full_Alpha_AI`

---

## 1. 这是什么

AI 版在配件增强版的完整 Toon 渲染能力基础上，**内嵌了一个 MLP 神经网络**（3→64→3），
根据场景光照方向实时预测 3 个关键渲染参数，取代逐镜头手工校准。

**一句话总结**：美术在校准间把最优参数教给网络，运行时每帧、每像素自动适配——
转视角、换场景、打光变化都不需要手动干预。

`UseAI` 开关默认关闭（`0`），此时行为与配件增强版完全一致，可随时切回手动模式。

### 与配件增强版的差异

| 维度 | 配件增强版 | AI 版 |
|------|-----------|------|
| ShadowSmooth / ShadowLocation / ExposureScale | 手动固定值 | **AI 实时预测**（UseAI=1 时） |
| 其余全部功能 | 有 | **完全一致** |

---

## 2. 目录结构

```
Latest_Development/AI/
├── MMDToonShader_SM5_SingleFunc_Full_AI.hlsl           # 主文件（不透明，内嵌 MLP 权重）
├── MMDToonShader_SM5_SingleFunc_Full_Alpha_AI.hlsl     # 半透明变体（共用同一套权重）
├── AIControl/                                           # 训练管线
│   ├── anchors.csv                    # ★ 唯一需要手改的输入：光照→参数锚点
│   ├── offset_anchors.py              # 扣每条拍摄的系统性偏置
│   ├── merge_anchors.py               # 合并同光向重复锚点（可选）
│   ├── collect_training_data.py       # 训练数据采集（球面均匀采样 + 光滑标签）
│   ├── fit_mlp.py                     # MLP 训练 + HLSL 代码生成
│   ├── retrain_all.py                 # ★ 一键重训入口
│   ├── ai_mlp.hlsl                    # 生成物（勿手改）：独立前置节点版
│   ├── training_data.csv              # 生成物：训练样本
│   └── _exp/                          # 诊断脚本（不参与训练）
├── UE_MMDAnchorRecorder/              # UE 编辑器插件：录制锚点
├── Archive/                           # 历史归档（多项式回归时代）
└── README.md                          # 本文件
```

---

## 3. 核心特性

### 3.1 AI 自适应打光

输入三个光照几何特征，预测三个参数：

| 预测参数 | 语义 | 预测值范围 |
|---------|------|-----------|
| `ShadowSmooth` | 阴影过渡柔化程度（>1 扩散柔化，<1 收窄变陡） | [0.138, 1.280] |
| `ShadowLocation` | 阴影位置偏移（>0 前移变多，<0 后移变少） | [-0.289, 0.713] |
| `ExposureScale` | 整体曝光矫正（背光自动提亮防死黑） | [0.560, 1.298] |

预测值在「曲线阴影」（UseCurve=1）与「Ramp 回退」（UseRampTex=1）两条路径都生效。
色带分支（过时方案）不受 AI 影响；Rim 是确定性几何函数，天生自适应，无需 AI 预测。

### 3.2 完整 Toon 渲染

保留配件增强版全部能力：

- 曲线阴影映射（CurveLinearColorAtlas，可实时调曲线）/ Ramp 贴图 / 三层色带回退
- 双 Matcap（高光 + 粗糙），自适应防死锁球面映射
- HM 贴图（R=高光蒙版，G=AO）+ 独立 AO 控制
- SSS 次表面散射
- Rim Light 三参数（Width / Gradient / Color）+ 环境天穹模式
- Kajiya-Kay 各向异性高光（丝袜/皮革/布料的拉长光带）
- HSV 统一阴影调色、色调三模式、饱和度
- 法线贴图双守卫（切线无效 + BC5 蓝通道）
- UseToonShading 总开关
- HairMapMode / MatcapSharpen / RimEnvMode 三项 v2 改进
- Tonemap 色调映射（独立 Custom 节点，可选）

### 3.3 零运行时依赖

训练后 MLP 权重矩阵固化为纯 HLSL 常量代码，内嵌在 shader 文件的
`// ==== AUTO-MLP-BEGIN ====` 与 `// ==== AUTO-MLP-END ====` 标记之间。
运行时推理 = 64 次 ReLU + 3 次线性组合 = 几十条 GPU 指令，
零 CPU 负担，不需要 ONNX / PyTorch 运行时。

---

## 4. 快速开始（UE 接入）

### 4.1 材质结构

两个 Custom 节点：

| 节点 | 功能 | Output Type |
|------|------|-------------|
| **主节点** | Toon + AI 推理 | CMOT Float3（不透明）/ CMOT Float4（半透明） |
| **ToneMap 节点** | ACES 色调映射（可选） | CMOT Float3 |

接线：主节点输出 → ToneMap 节点的 `col` → ToneMap 输出 → Emissive Color

### 4.2 设置步骤

1. 创建 **Unlit** 材质，`LightDirection` 连接 `SkyAtmosphereLightDirection`（自动联动场景太阳）
2. 将 `Full_AI.hlsl`（或 `Full_Alpha_AI.hlsl`）粘贴到主节点 Code 字段
3. 按文件头部注释添加所有输入引脚（名称区分大小写）
4. 用 `TextureObjectParameter` 连接贴图（不能用 `TextureSampleParameter2D`）
5. **`UseAI` 默认 `0`**（手动模式）；调好后设 `1` 启用 AI

### 4.3 贴图输入

| 参数名 | 用途 | 格式 |
|--------|------|------|
| `BaseColorTex` | 基础色贴图 | sRGB，必须 |
| `CurveAtlasTexture` | 曲线图集 | **LinearColor**（CurveLinearColorAtlas），曲线阴影时必须 |
| `ToonTexture` | Ramp 渐变贴图 | sRGB，曲线关闭时的回退 |
| `MatcapTexture` | 高光 Matcap 球面贴图 | sRGB |
| `RoughMatcapTexture` | 粗糙 Matcap 球面贴图 | sRGB |
| `NormalMapTex` | 切线空间法线贴图 | Normalmap（BC5），可选 |
| `HMTexture` | HM 贴图（R=高光蒙版，G=AO） | LinearColor，UseHM=1 时生效 |
| `SSSTex` | 次表面散射贴图 | sRGB，UseSSS=1 时生效 |

> 半透明变体额外需要 `AlphaTex`（TextureObjectParameter）。

---

## 5. AI 是怎么工作的

### 5.1 输入特征

| 特征 | 计算 | 物理意义 |
|------|------|---------|
| `LdotV` | `dot(LightDirection, V_cam)` | 光的前后分量（>0 顺光，<0 逆光） |
| `L_up` | `LightDirection.z` | 光源高度（>0 顶光，<0 底光） |
| `L_right` | `dot(LightDirection, Right)` | 光源左右分量（区分左/右前光） |

`V_cam = normalize(GetWorldCameraOrigin − GetObjectWorldPosition)`，
是**每帧一个常量**（物体中心→相机），不是逐像素视线向量。
本式、UE 导出器、`collect_training_data.py` 三处定义必须严格一致。

### 5.2 网络结构

```
输入层 (3)  →  隐藏层 (64, ReLU)  →  输出层 (3, Linear)
  LdotV                                     ShadowSmooth
  L_up                                      ShadowLocation
  L_right                                   ExposureScale
```

训练框架：scikit-learn MLPRegressor，优化器 L-BFGS，500 条训练样本。
留出 R²（20% holdout）：ShadowSmooth ≈ 0.999，ShadowLocation ≈ 0.998，ExposureScale ≈ 0.998。

### 5.3 推理方式

**线下训练，线上常量固化**。训练完成后将权重展开为 HLSL 代码，
固化在 `// ==== AUTO-MLP-BEGIN ====` 和 `// ==== AUTO-MLP-END ====` 之间。

`UseAI=1` 时用预测值覆盖 ShadowSmooth/ShadowLocation/ExposureScale；
`UseAI=0` 时全部走手动参数。

### 5.4 闪烁修复

早期 IDW 精确穿点会因锚点矛盾产生逐帧抖动（>0.5°/帧 占 14.2%）。

修复方案：
1. 先 `offset_anchors.py` 扣掉每条拍摄的系统性偏置
2. 再用 **3 阶球谐最小二乘** 拟合全局光滑场当标签（`--smooth-order 3`）
3. `HIDDEN_DEFAULT` 从 256 降至 **64**

结果：>0.5°/帧 = **0.00%**，P95 = 0.18°，P99 = 0.31°。

> 详细原理见 `Documentation/Why_AI_Rendering_Logic.md` 和
> `Documentation/Evolution_From_Polynomial_To_MLP.md`。

---

## 6. 参数速查

### 6.1 AI 控制

| 参数 | 类型 | 默认 | 说明 |
|------|------|------|------|
| `UseAI` | Float1 | 0.0 | 1=MLP 预测，0=手动 |

### 6.2 阴影（3 条路径）

| 参数 | 类型 | 默认 | 说明 |
|------|------|------|------|
| `UseCurve` | Float1 | 1.0 | 1=曲线图集（默认），0=回退 |
| `UseRampTex` | Float1 | 1.0 | UseCurve=0 时：1=Ramp，0=色带 |
| `ShadowSmooth` | Float1 | 1.0 | AI=1 时被覆盖 |
| `ShadowLocation` | Float1 | 0.0 | AI=1 时被覆盖 |
| `ShadowColor` | Float3 | (0.2,0.2,0.4) | 第一层阴影色（最暗） |
| `Shadow2Color` | Float3 | (0.5,0.5,0.6) | 第二层阴影色 |
| `Shadow3Color` | Float3 | (0.8,0.8,0.85) | 第三层阴影色 |
| `ShadowHueShift` | Float1 | 0.0 | 阴影色相偏移 |
| `ShadowSaturation` | Float1 | 1.0 | 阴影饱和度 |
| `ShadowBrightness` | Float1 | 1.0 | 阴影亮度 |
| `ShadowThreshold` | Float1 | 0.5 | 色带方式 T1 |
| `ShadowEnd` | Float1 | 0.75 | 色带方式 T3 |
| `MidSplit` | Float1 | 0.60 | 色带方式中间层分配 |
| `ShadowSharpness` | Float1 | 0.8 | 色带方式锋利度 |

### 6.3 色调 / 饱和度 / 曝光

| 参数 | 类型 | 默认 | 说明 |
|------|------|------|------|
| `BaseTint` | Float3 | (1,1,1) | 色调颜色 |
| `TintIntensity` | Float1 | 0.0 | 色调强度（0=关，1=全） |
| `TintMode` | Float1 | 0.0 | 0=Overlay，1=乘法，2=SoftLight |
| `Saturation` | Float1 | 1.0 | 饱和度 |
| `ExposureScale` | Float1 | 1.0 | AI=1 时被覆盖 |

### 6.4 HM / AO / SSS

| 参数 | 类型 | 默认 | 说明 |
|------|------|------|------|
| `UseHM` | Float1 | 0.0 | 1=启用 HM 贴图 |
| `UseAO` | Float1 | 1.0 | 1=启用 AO |
| `AO_Power_ShadowMask` | Float1 | 1.0 | AO 强度 |
| `AO_Shadow_Strengh` | Float1 | 0.0 | AO 阴影混合 |
| `UseSSS` | Float1 | 0.0 | 1=启用 SSS |
| `SSSColor` | Float3 | (1,1,1) | SSS 颜色+强度 |

### 6.5 Rim / Matcap / 高光

| 参数 | 类型 | 默认 | 说明 |
|------|------|------|------|
| `RimWidth` | Float1 | 0.35 | 条带宽度 |
| `RimGradient` | Float1 | 0.15 | 边缘渐变 |
| `RimColor` | Float3 | (1,1,1) | 颜色+强度 |
| `RimEnvMode` | Float1 | 0.0 | 0=仅受光侧，1=环境天穹全轮廓 |
| `MatcapColor` | Float3 | (1,1,1) | 高光 Matcap 颜色 / 各向异性强度 |
| `RoughMatcapColor` | Float3 | (1,1,1) | 粗糙 Matcap 颜色 |
| `RoughColor` | Float3 | (1,1,1) | 粗糙 Matcap 混合色 |
| `MatcapScale` | Float1 | 1.0 | Matcap UV 缩放 / 各向异性锐利度 |
| `MatcapOffset` | Float1 | 0.0 | Matcap UV 偏移 |
| `HairMapMode` | Float1 | 0.0 | 0=HM 通用解读，1=UV 空间发丝高光图 |
| `MatcapSharpen` | Float1 | 0.0 | Matcap 高光锐化（0=与旧版一致） |

### 6.6 其他

| 参数 | 类型 | 默认 | 说明 |
|------|------|------|------|
| `UseToonTexture` | Float1 | 1.0 | 1=采样 ToonTexture，0=用 LitColor |
| `LitColor` | Float3 | (1,1,1) | UseToonTexture=0 时亮部色 |
| `UseToonShading` | Float1 | 1.0 | Toon 总开关 |
| `NormalMapIntensity` | Float1 | 1.0 | 法线贴图强度 |

### 6.7 各向异性高光（不透明版 Full_AI）

参数复用，无需额外贴图：

| 金属配件 | 丝袜/皮革 | 说明 |
|---------|-----------|------|
| `MatcapScale=1.0`（普通高光） | `MatcapScale=3.0`（各向异性光带） | 值越大光带越窄越锐利 |
| `MatcapColor=(1,1,1)` | `MatcapColor=(1,1,1)` | 越亮强度越高 |

> 半透明版 `Full_Alpha_AI` **不含各向异性高光**。

---

## 7. 训练管线

### 7.1 调整风格

1. 在 UE 中编辑 `anchors.csv`（每行一个光照方向下的理想参数）
2. 运行重训：

```bash
cd Latest_Development/AI/AIControl

# 推荐：扣拍摄偏置 + 3 阶光滑标签
python retrain_all.py --take-offset --smooth-order 3

# 自定义（采样数/隐藏层）
python retrain_all.py --take-offset --smooth-order 3 --samples 1000 --hidden 32
```

3. 重训后 `Full_AI.hlsl` 与 `Full_Alpha_AI.hlsl` 中 `AUTO-MLP-BEGIN/END` 权重代码
   自动替换并校验两份逐字相同

### 7.2 锚点表格式

```csv
LdotV,L_up,L_right,ShadowSmooth,ShadowLocation,ExposureScale,VcamX,VcamY,VcamZ,note
-0.00,-0.00,1.00,0.30,-0.33,0.50,0.0000,0.9247,0.3807,正面-0度 frame=0
```

- **VcamX/Y/Z**：该行生成时的 `V_cam`，脚本启动时逐行校验
- **note**：必须是最后一列，格式 `"<序列名> frame=<帧号>"`
- 同一序列的行会被替换（可反复微调不重复）

### 7.3 锚点录制（UE 插件）

`UE_MMDAnchorRecorder/` 插件通过 `ExportAnchorsFromSequence` 从 Level Sequence 批量导出。

要求：选中项里**恰好一个**承载 Toon 材质的 Actor，否则中止并说明原因。

### 7.4 诊断脚本

| 脚本 | 用途 |
|------|------|
| `_exp/diag_sweep_flicker.py` | 沿光扫轨迹的逐帧抖动（>0.5°/帧 占比） |
| `_exp/diag_mlp_smoothness.py` | MLP 方向导数、安全区 |
| `_exp/diag_camera_sensitivity.py` | 相机每转 1° 的参数跳变 |

---

## 8. 版本关系

```
Full（整合示例材质）
  → Full_Accessories（+各向异性高光）
      → Full_AI（+MLP 预测，不透明）← 本版本
      → Full_Alpha_AI（+MLP 预测 + Alpha，半透明）← 本版本变体

Full（整合示例材质）
  → Full_Test（v2 渲染改进）
      → Full_Alpha（+AlphaChannelMode，最新非AI）← 本目录不含
```

### AI 版 vs 非AI 最新版（Full_Alpha）对比

| 特性 | Full_AI (不透明 AI) | Full_Alpha_AI (半透明 AI) | Full_Alpha (非AI 最新) |
|------|---------------------|---------------------------|------------------------|
| MLP AI 预测 | ✓ | ✓ | ✗ |
| Alpha 透明度 | ✗ | ✓ | ✓ |
| 各向异性高光 (Kajiya-Kay) | ✓ | ✗ | ✗ |
| v2 四项改进 | ✓ | ✓ | ✓ |
| 曲线/Ramp/色带阴影 | ✓ | ✓ | ✓ |
| 双 Matcap + HM/AO/SSS | ✓ | ✓ | ✓ |

---

## 9. 注意事项

1. **贴图必须用 TextureObjectParameter**，不能用 TextureSampleParameter2D
2. **UseAI 默认关闭**：开箱即用为手动模式
3. **AI 不覆盖色带分支**：色带为过时方案，AI 仅对曲线/Ramp 路径生效
4. **AO 依赖 HM 贴图**：`UseAO=1` 但 `UseHM=0` 时 AO 无效果
5. **LightDirection 用 SkyAtmosphereLightDirection**：自动跟随场景太阳
6. **法线贴图双守卫**：切线无效 NaN 守卫 + BC5 蓝通道守卫，任一命中退回几何法线
7. **不透明版与半透明版必须共用同一套权重**：`retrain_all.py` 会同步并校验逐字相同
8. **重训后确认 AUTO-MLP 标记完整**：两份 `Full_*_AI.hlsl` 都要推送到 UE
9. **闪烁排查**：先看 `_exp/diag_sweep_flicker.py` 的 >0.5°/帧 占比；若仍抖多半是相机运动

---

## 10. 相关文档

| 文档 | 路径 | 内容 |
|------|------|------|
| AI 使用文档 | `Documentation/MMDToonShader_Full_AI_使用文档.md` | 完整参数说明 + 训练管线详解 |
| Shader 原理 | `Documentation/ShaderPrinciples.md` | 渲染管线深度解析 |
| 逻辑说明 | `Documentation/MMDToonShader_Logic.md` | 代码逻辑逐段分析 |
| 技术演进 | `Documentation/Evolution_From_Polynomial_To_MLP.md` | 多项式回归 → MLP 的演进 |
| 训练数据逻辑 | `Documentation/Training_Data_Generation_Logic.md` | 数据采集原理 |
| AI 渲染逻辑 | `Documentation/Why_AI_Rendering_Logic.md` | AI 在渲染中的工作原理 |
| 性能测试计划 | `Documentation/Performance_Test_Plan.md` | 设备分档 / 测量方法 / 通过判据 |
| 根目录整合版文档 | `../../MMDToonShader_SM5_SingleFunc_Full_使用文档.md` | 基础版 Full 渲染管线详解 |
