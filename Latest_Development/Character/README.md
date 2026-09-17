# MMD Toon Shader — 角色版（含最新 Full_Alpha）

> 本目录是所有角色着色器版本的所在。**最新版为 `Full_Alpha.hlsl`**——
> 功能最全的不透明+半透明整合版本。

---

## 目录

1. 文件清单
2. 版本演进
3. 快速开始（UE 接入）
4. 贴图说明
5. 参数说明
6. 功能概述
7. 与 AI 版的差异
8. 注意事项
9. 相关文档

---

## 1. 文件清单

| 文件 | 说明 |
|------|------|
| `MMDToonShader_SM5_SingleFunc.hlsl` | 早期主文件：三层 Toon / Rim / Specular / Matcap（历史基线） |
| `MMDToonShader_SM5_SingleFunc_Hair.hlsl` | 头发边缘半透明专属版（Translucent，RGB→Emissive，A→Opacity） |
| `MMDToonShader_SM5_SingleFunc_Alpha.hlsl` | 早期 Alpha 输出版（Translucent / Masked） |
| `MMDToonShader_SM5_SingleFunc_Full.hlsl` | 整合版基线：SingleFunc + 示例材质新功能 |
| `MMDToonShader_SM5_SingleFunc_Full_Accessories.hlsl` | 配件增强版：+Kajiya-Kay 各向异性高光 |
| `MMDToonShader_SM5_SingleFunc_Full_Test.hlsl` | 试验版：+SpecGate / HairMapMode / MatcapSharpen / RimEnvMode |
| **`MMDToonShader_SM5_SingleFunc_Full_Alpha.hlsl`** | **最新版**：Test 全部特性 + AlphaChannelMode（4 种取 Alpha 方式） |

---

## 2. 版本演进

```
SingleFunc（三层色带，历史基线）
    ↓  整合示例材质 M_Redner_Master1
    ↓  保留色调三模式 / 饱和度 / HSV 统一调色
Full（整合版基线）
    ↓  +各向异性高光 → Full_Accessories（配件版，另见 AI 目录）
    ↓  +v2 改进（SpecGate / HairMapMode / MatcapSharpen / RimEnvMode）
Full_Test（试验版，当前工作目录迭代基线）
    ↓  +AlphaChannelMode（4 种 Alpha 取样方式）
    ↓  +AlphaScale / AlphaCutoff
Full_Alpha ← 本文件（功能最全）
```

---

## 3. 快速开始（UE 接入）

### 3.1 材质结构

| 节点 | 功能 | Output Type | 输入数量 |
|------|------|-------------|---------|
| **主节点** | 完整 Toon 渲染 | CMOT Float4 | 57 |
| **ToneMap 节点** | ACES 色调映射（可选） | CMOT Float3 | 2（col + UseTonemap） |

接线：主节点 → ToneMap.col → ToneMap 输出 → **Emissive Color（RGB）+ Opacity / Opacity Mask（A）**

### 3.2 设置步骤

1. 创建材质，**Shading Model** 设为 **Unlit**
2. **Blend Mode** 设为 **Translucent**（半透明）或 **Masked**（镂空/裁剪）
3. 添加 Custom 节点，将 `Full_Alpha.hlsl` 全部内容粘贴到 **Code** 字段
4. 在 **Inputs** 中按文件头部注释添加 57 个输入引脚
5. `LightDirection` 连接 `SkyAtmosphereLightDirection`（自动跟随场景太阳）
6. 用 `TextureObjectParameter` 传入贴图（不能用 `TextureSampleParameter2D`）
7. 主节点输出 → ToneMap 节点 → **Emissive Color**
8. 若需要 Alpha/Opacity，将主节点的 **A** 输出连接到 **Opacity** 或 **Opacity Mask**

### 3.3 不透明 vs 半透明用法

- **不透明**：Blend Mode = Opaque，Alpha 通道不使用
- **半透明**：Blend Mode = Translucent，Alpha 接 Opacity
- **镂空**：Blend Mode = Masked，Alpha 接 Opacity Mask，`AlphaCutoff` 控制裁剪阈值

---

## 4. 贴图说明（9 张）

均使用 **TextureObjectParameter** 节点传入。

| 参数名 | 用途 | 格式 | 说明 |
|--------|------|------|------|
| `BaseColorTex` | 基础色贴图 | sRGB | 必须 |
| `CurveAtlasTexture` | 曲线图集 | **LinearColor** | CurveLinearColorAtlas，曲线阴影时必须，可实时调曲线 |
| `ToonTexture` | Ramp 渐变贴图 | sRGB | 横向左暗右亮，UseCurve=0 时的回退 |
| `MatcapTexture` | 高光 Matcap 球面贴图 | sRGB | |
| `RoughMatcapTexture` | 粗糙 Matcap 球面贴图 | sRGB | |
| `NormalMapTex` | 切线空间法线贴图 | Normalmap | BC5 压缩，可选 |
| `HMTexture` | HM 贴图 | LinearColor | R=高光蒙版，G=AO；UseHM=1 时生效 |
| `SSSTex` | 次表面散射贴图 | sRGB | UseSSS=1 时生效 |
| `AlphaTex` | 透明度贴图 | sRGB | AlphaChannelMode=0 或 3 时采样 |

> 曲线图集制作：在 UE 创建 `CurveLinearColor` → 创建 `CurveLinearColorAtlas` → 分配曲线 →
> samplerType 设为 **LinearColor**。曲线拖动时图集纹理自动重新烘焙，Shader 无需改动。

---

## 5. 参数说明

### 5.1 色调

| 参数 | 类型 | 默认 | 说明 |
|------|------|------|------|
| `BaseTint` | Float3 | (1,1,1) | 色调颜色 |
| `TintIntensity` | Float1 | 0.0 | 强度（0=关，1=全） |
| `TintMode` | Float1 | 0.0 | 0=Overlay，1=乘法，2=SoftLight |
| `Saturation` | Float1 | 1.0 | 饱和度（0=灰度，1=不变，>1=过饱和） |

### 5.2 Toon 阴影

**路径选择**：`UseCurve=1`（默认）→ 曲线 / `UseCurve=0, UseRampTex=1` → Ramp / `UseCurve=0, UseRampTex=0` → 三层色带

| 参数 | 类型 | 默认 | 说明 |
|------|------|------|------|
| `UseToonTexture` | Float1 | 1.0 | 1=采样 ToonTexture，0=用 LitColor |
| `LitColor` | Float3 | (1,1,1) | UseToonTexture=0 时亮部色 |
| `UseToonShading` | Float1 | 1.0 | Toon 总开关（0=跳过全部风格化） |
| `UseCurve` | Float1 | 1.0 | 1=曲线图集（默认），0=回退 |
| `UseRampTex` | Float1 | 1.0 | UseCurve=0 时：1=Ramp 贴图，0=三层色带 |
| `ShadowSmooth` | Float1 | 1.0 | 曲线/Ramp 方式，阴影平滑度 |
| `ShadowLocation` | Float1 | 0.0 | 曲线/Ramp 方式，阴影位置偏移 |
| `ShadowThreshold` | Float1 | 0.5 | 色带方式 T1 深阴影起点 |
| `ShadowEnd` | Float1 | 0.75 | 色带方式 T3 亮区起点 |
| `MidSplit` | Float1 | 0.60 | 色带方式中间层分配比 |
| `ShadowSharpness` | Float1 | 0.8 | 色带方式锋利度 |
| `ShadowColor` | Float3 | (0.2,0.2,0.4) | 第一层阴影色（最暗） |
| `Shadow2Color` | Float3 | (0.5,0.5,0.6) | 第二层阴影色 |
| `Shadow3Color` | Float3 | (0.8,0.8,0.85) | 第三层阴影色 |
| `ShadowHueShift` | Float1 | 0.0 | 阴影色相偏移（度） |
| `ShadowSaturation` | Float1 | 1.0 | 阴影饱和度 |
| `ShadowBrightness` | Float1 | 1.0 | 阴影亮度（HSV V 分量缩放） |

### 5.3 HM / AO / SSS

| 参数 | 类型 | 默认 | 说明 |
|------|------|------|------|
| `UseHM` | Float1 | 0.0 | 1=启用 HM 贴图 |
| `UseAO` | Float1 | 1.0 | 1=启用 AO |
| `AO_Power_ShadowMask` | Float1 | 1.0 | AO 强度 |
| `AO_Shadow_Strengh` | Float1 | 0.0 | AO 阴影混合强度 |
| `UseSSS` | Float1 | 0.0 | 1=启用 SSS |
| `SSSColor` | Float3 | (1,1,1) | SSS 颜色+强度 |

> **AO 依赖 HM 贴图**：`UseAO=1` 但 `UseHM=0` 时，AO 无效果。

### 5.4 Rim 边缘光

| 参数 | 类型 | 默认 | 说明 |
|------|------|------|------|
| `RimWidth` | Float1 | 0.35 | 条带宽度（0~1，越大越宽） |
| `RimGradient` | Float1 | 0.15 | 边缘渐变（越大过渡越柔和） |
| `RimColor` | Float3 | (1,1,1) | 颜色+强度 |
| `RimEnvMode` | Float1 | 0.0 | 0=仅受光侧（旧），1=环境天穹全轮廓边缘光 |

### 5.5 Matcap 双球面贴图

| 参数 | 类型 | 默认 | 说明 |
|------|------|------|------|
| `MatcapColor` | Float3 | (1,1,1) | 高光 Matcap 颜色+强度 |
| `RoughMatcapColor` | Float3 | (1,1,1) | 粗糙 Matcap 颜色+强度 |
| `RoughColor` | Float3 | (1,1,1) | 粗糙 Matcap 混合色 |
| `MatcapScale` | Float1 | 1.0 | Matcap UV 缩放 |
| `MatcapOffset` | Float1 | 0.0 | Matcap UV 偏移 |
| `HairMapMode` | Float1 | 0.0 | 0=HM 通用解读，1=UV 空间发丝高光图调制 |
| `MatcapSharpen` | Float1 | 0.0 | 高光锐化/收窄（0=与旧版一致） |

### 5.6 法线 / 曝光

| 参数 | 类型 | 默认 | 说明 |
|------|------|------|------|
| `NormalMapIntensity` | Float1 | 1.0 | 法线贴图强度 |
| `ExposureScale` | Float1 | 1.0 | 整体曝光矫正 |

### 5.7 Alpha 透明度

| 参数 | 类型 | 默认 | 说明 |
|------|------|------|------|
| `AlphaChannelMode` | Float1 | 0.0 | 0=AlphaTex.R（旧，薄纱灰度贴图）；1=BaseColor.A；2=BaseColor 亮度（高光图 A 丢失时）；3=AlphaTex.A |
| `AlphaScale` | Float1 | 1.0 | 透明度校准（不同槽位可赋予不同透明度，>1 更透明，<1 更不透明） |
| `AlphaCutoff` | Float1 | 0.5 | Masked 裁剪阈值 |

---

## 6. 功能概述

### 6.1 渲染管线

```
基础色贴图 → 色调混合（三模式） → 饱和度 → 法线贴图 → HM 贴图
→ Toon 阴影（曲线/Ramp/色带） → AO 遮蔽 → × FinalToon
→ SpecGate 高光闸门 → Rim Light → 双 Matcap → SSS → × ExposureScale
→ [可选 ToneMap] → 输出 Float4（RGB + Alpha）
```

### 6.2 关键特性

- **v2 高光闸门**：`SpecGate = smoothstep(0.0, 0.35, saturate(NdotL))`，
  Rim/双 Matcap 不再直连 ShadowMask，解决了"阴影一柔化头发高光就消失"的问题
- **双 Matcap 防死锁**：两组参考系 smoothstep 混合，消除俯仰时高光跳变
- **HSV 统一调色**：3 阶 Rodrigues 旋转矩阵 + Rec.709 饱和度，三层阴影共用一组参数
- **法线双守卫**：切线无效 NaN 守卫 + BC5 蓝通道守卫，任一命中退回几何法线
- **法线只影响 Matcap**：不影响 Toon 阴影/Rim，保持"大平面色块"观感
- **ShadowMask 遮蔽**：所有加法项（Rim/Matcap）乘 ShadowMask，保证阴影区域不漏光
- **Tonemap 独立节点**：HLSL 手写 ACES Filmic，不依赖 UE 引擎 include hack

### 6.3 Alpha 四种模式

| AlphaChannelMode | 取样来源 | 典型场景 |
|------------------|---------|---------|
| 0（默认） | AlphaTex.R | 薄纱等独立灰度透明贴图 |
| 1 | BaseColor.A | 眼高光/眼白/星点等自带 A 的贴图 |
| 2 | BaseColor RGB 亮度 | `_Hi` 类高光图（导入后 A 通道丢失） |
| 3 | AlphaTex.A | AlphaTex 使用 RGBA 格式 |

---

## 7. 与 AI 版的差异

本目录 `Full_Alpha.hlsl` 与 AI 目录 `Full_Alpha_AI.hlsl` 的区别：

| 特性 | Full_Alpha（本目录） | Full_Alpha_AI（AI 目录） |
|------|---------------------|---------------------------|
| MLP AI 自适应 | ✗ | ✓（UseAI 开关） |
| 各向异性高光 | ✗ | ✗（两者均不含） |
| ShadowSmooth / ShadowLocation / ExposureScale | 手动 | AI=1 时被预测值覆盖 |
| 其余渲染功能 | 完全一致 | 完全一致 |

> 不透明 AI 版（`Full_AI`）额外含有各向异性高光（Kajiya-Kay）。

### 版本完整矩阵

| 特性 | Full | Full_Accessories | Full_Test | Full_Alpha | Full_AI | Full_Alpha_AI |
|------|------|-----------------|-----------|------------|---------|---------------|
| 色调三模式 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| HSV 阴影调色 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| 曲线/Ramp/色带 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| 双 Matcap | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| HM / AO | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| SSS | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| SpecGate | ✗ | ✗ | ✓ | ✓ | ✓ | ✓ |
| HairMapMode | ✗ | ✗ | ✓ | ✓ | ✓ | ✓ |
| MatcapSharpen | ✗ | ✗ | ✓ | ✓ | ✓ | ✓ |
| RimEnvMode | ✗ | ✗ | ✓ | ✓ | ✓ | ✓ |
| 各向异性高光 | ✗ | ✓ | ✗ | ✗ | ✓ | ✗ |
| Alpha | ✗ | ✗ | ✗ | ✓ | ✗ | ✓ |
| AI 预测 | ✗ | ✗ | ✗ | ✗ | ✓ | ✓ |

---

## 8. 注意事项

1. **贴图必须用 TextureObjectParameter**，不能用 TextureSampleParameter2D
2. **CurveAtlasTexture 的 samplerType 必须设为 LinearColor**（HDR 线性格式）
3. **AO 依赖 HM 贴图**：UseAO=1 但 UseHM=0 时 AO 无效果
4. **AlphaScale 不同槽位可以赋不同值**：同一材质实例内各材质槽的透明度可独立控制
5. **LightDirection 用 SkyAtmosphereLightDirection**：若阴影反相需检查方向约定（从表面指向光源）
6. **法线贴图不影响 Toon/Rim**：这是有意设计，不是 bug。用 BumpNormal 会产生细碎阴影斑块
7. **MatcapScale 仅用于 UV 缩放**：不像 AI 版的 Accessories 变体那样复用为各向异性锐利度
8. **ShadowColor 不要设为纯黑**：`(0,0,0)` 会让后续所有亮度调整无效（`0×k=0`），用极小非零值代替
9. **TintMode / UseToonTexture / UseToonShading 是离散开关**：两档之间无过渡态，不要做动画关键帧

---

## 9. 相关文档

| 文档 | 路径 | 内容 |
|------|------|------|
| 整合版详细文档 | `../../MMDToonShader_SM5_SingleFunc_Full_使用文档.md` | Full 渲染管线深度解析 |
| 版本对比 | `../VERSION_COMPARISON.md` | 三版本功能矩阵对比 |
| 参数优化 | `../PARAMETER_OPTIMIZATION.md` | 参数调优分析 |
| Shader 原理 | `../Documentation/ShaderPrinciples.md` | 渲染原理深度分析 |
| AI 版 README | `../AI/README.md` | AI 驱动版使用指南 |
| AI 使用文档 | `../Documentation/MMDToonShader_Full_AI_使用文档.md` | AI 版完整说明 |
