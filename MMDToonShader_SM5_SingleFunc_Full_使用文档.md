# MMD Toon Shader 完整整合版 — 详细说明文档

> 对应文件：`MMDToonShader_SM5_SingleFunc_Full.hlsl`
> 基线版本：`MMDToonShader_SM5_SingleFunc.hlsl`（三层色带版）
> 衍生版本：`Full_Accessories`（+各向异性高光）、`Full_AI`（+MLP 预测）、`Full_Alpha`（+透明度）
> UE 材质：`/Game/着色器/M_MMDToon_Full`

---

## 目录

1. [版本定位与演进](#1-版本定位与演进)
2. [渲染管线总览](#2-渲染管线总览)
3. [材质结构与接线](#3-材质结构与接线)
4. [贴图说明（7 张）](#4-贴图说明7-张)
5. [参数说明（按分组）](#5-参数说明按分组)
6. [渲染管线深度解析](#6-渲染管线深度解析)
   - 6.1 基础底色与色调混合
   - 6.2 饱和度调节
   - 6.3 方向向量与基础光照
   - 6.4 Toon 总开关
   - 6.5 法线贴图（双守卫）
   - 6.6 HM 贴图（高光蒙版 + AO）
   - 6.7 Toon 阴影系统（三条路径）
   - 6.8 AO 环境光遮蔽
   - 6.9 Rim Light 边缘光
   - 6.10 双 Matcap 球面贴图
   - 6.11 SSS 次表面散射
   - 6.12 曝光矫正
   - 6.13 Tonemap 色调映射（独立节点）
7. [关键设计决策](#7-关键设计决策)
8. [使用步骤](#8-使用步骤)
9. [版本对比与迁移](#9-版本对比与迁移)
10. [注意事项与已知限制](#10-注意事项与已知限制)
11. [文件清单](#11-文件清单)

---

## 1. 版本定位与演进

### 1.1 演进路线

```
SingleFunc（三层色带版）
    ↓  整合示例材质 M_Redner_Master1 的功能
    ↓  保留 SingleFunc 的色调/饱和度/HSV 增强
Full（本版本）
    ↓  +各向异性高光（Kajiya-Kay）
Full_Accessories（配件增强版）
    ↓  +MLP 神经网络预测参数
Full_AI（AI 驱动版）
```

### 1.2 本版本的定位

本版本以示例材质 `M_Redner_Master1` 为基准，把前一项目删改掉的功能整合回 `MMDToonShader_SM5_SingleFunc.hlsl`，同时保留 SingleFunc 的色调三模式/饱和度/HSV 统一调色等增强能力。

**核心变化**（相对 SingleFunc）：

| 维度 | SingleFunc | 完整版（本版本） |
|------|-----------|-----------------|
| 阴影映射 | 三层离散色带（唯一方式） | **曲线为主 + Ramp 贴图 + 色带回退**（三条路径） |
| Matcap | 单 Matcap | **双 Matcap**（高光 + 粗糙） |
| Matcap 万向节死锁 | 无处理 | **双参考系 smoothstep 混合**（C1 连续） |
| HM 贴图 / AO | 无 | **整合**（R=高光蒙版，G=AO） |
| SSS 次表面散射 | 无 | **整合**（皮肤边缘透光） |
| Tonemap 逆运算 | 无 | **整合**（HLSL ACES Filmic） |
| 阴影平滑/位置 | 无 | **ShadowSmooth / ShadowLocation** |
| Specular 参数高光 | 有（Blinn-Phong） | **删除**（双 Matcap 替代） |
| 头发高光（UV 定位） | 有 | **删除**（高光 Matcap 替代） |

**设计哲学**：用更少的参数实现更丰富的效果。双 Matcap 一张贴图替代了 Specular 参数高光 + 头发 UV 定位高光两个子系统，HM 贴图一张图替代了独立的高光蒙版和 AO 两张图。

---

## 2. 渲染管线总览

### 2.1 数据流图

```
输入纹理 ─► BaseColor 采样
                │
                ▼
        色调混合（3 模式: Overlay/Multiply/SoftLight）
                │
                ▼
        饱和度调节（Rec.709 亮度 → lerp）
                │
                ├─── UseToonShading=0 ──► ×LightAtten ──► 直接返回
                │
                ▼
        法线贴图（双守卫 → BumpNormal）
                │
                ▼
        HM 贴图（R=高光蒙版，G=AO）
                │
                ▼
        Toon 阴影（三路径：曲线/Ramp/色带）──► FinalToon + ShadowMask
                │                                    │
                ├── AO 遮蔽（HM.G × ShadowMask）     │
                │                                    │
                ├────────────────────────────────────┘
                ▼
        ResultColor × FinalToon
                │
                ├── Rim Light（Fresnel × NdotL × ShadowMask）──► +
                │
                ├── 高光 Matcap（× HM.R × ShadowMask）──► +
                │
                ├── 粗糙 Matcap（× RoughColor × ShadowMask）──► +
                │
                ├── SSS（可选）──► +
                │
                ▼
        ExposureScale 曝光矫正
                │
                ▼
        输出 Float3 ──► [可选: ToneMap 节点] ──► Emissive Color
```

### 2.2 ShadowMask 的核心作用

所有加法项（Rim、Matcap）都乘了 `ShadowMask`。这不是性能优化，而是**风格一致性保障**——卡通渲染的审美核心是"明暗边界分明"。如果阴影区域的 Matcap 高光或 Rim 还能亮起来，视觉上立刻不像赛璐璐了。

### 2.3 为什么选 Unlit 材质

卡通渲染的本质需求（离散色带、独立阴影色、HDR 高光溢出驱动 Bloom）与 PBR 光照管线的设计目标（物理正确、能量守恒）根本冲突。在 Lit 材质上做 Toon 意味着要跟 Base Pass 的 PBR 计算结果"打架"。Unlit + 完全重写光线交互，没有任何"引擎覆盖你的意图"的黑盒行为。

---

## 3. 材质结构与接线

### 3.1 Custom 节点配置

UE 材质 `M_MMDToon_Full` 包含**两个 Custom 节点**：

| 节点 | 功能 | Output Type | 输入数量 |
|------|------|-------------|---------|
| **主节点** | 完整 Toon 处理 | CMOT Float3 | 47 |
| **ToneMap 节点** | ACES 色调映射 | CMOT Float3 | 2（col、UseTonemap） |

### 3.2 接线方式

```
主节点输出 ──► ToneMap 节点的 col 引脚
ToneMap 节点输出 ──► Emissive Color
```

### 3.3 光源联动

`LightDirection` 连接 `SkyAtmosphereLightDirection` 节点，自动读取场景 Directional Light 方向。无需蓝图传参。

---

## 4. 贴图说明（7 张）

均使用 **TextureObjectParameter** 传入（不能用 TextureSampleParameter2D）。

> **为什么必须用 TextureObjectParameter？**
> TextureSampleParameter2D 的输出是已经采样好的颜色值（UV 被引擎固化）。本 Shader 需要在 HLSL 内部基于相机向量实时重新计算 UV 坐标（Matcap 映射），所以必须获得底层的 `Texture2D.Sample()` 调用权限。

| 参数名 | 用途 | 格式/要求 | 分组 |
|--------|------|----------|------|
| `BaseColorTex` | 基础色贴图 | sRGB，必须 | Textures |
| `CurveAtlasTexture` | 曲线图集（阴影映射） | **LinearColor**，CurveLinearColorAtlas | Textures |
| `ToonTexture` | Ramp 渐变贴图（横向左暗右亮） | sRGB，曲线关闭时的回退 | Textures |
| `MatcapTexture` | 高光 Matcap 球面贴图 | sRGB | Textures |
| `RoughMatcapTexture` | 粗糙 Matcap 球面贴图 | sRGB | Textures |
| `NormalMapTex` | 切线空间法线贴图（BC5 压缩） | Normalmap，可选 | Textures |
| `HMTexture` | HM 贴图（R=高光蒙版，G=AO） | LinearColor，UseHM=1 时生效 | Textures |
| `SSSTex` | 次表面散射贴图 | sRGB，UseSSS=1 时生效 | Textures |

### 4.1 曲线图集的制作方法

1. 在 UE 内容浏览器创建 `CurveLinearColor` 资产（如 `CB_Ramp1`）
2. 创建 `CurveLinearColorAtlas` 资产（如 `CA_Render1`），将曲线分配到图集中
3. 图集的 samplerType 必须设为 **LinearColor**（HDR 线性格式）
4. 曲线可实时调整——在曲线编辑器里拖控制点，图集纹理自动重新烘焙，Shader 无需改动

---

## 5. 参数说明（按分组）

### 5.1 Tint（色调，保留自 SingleFunc）

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `BaseTint` | Float3 | (1,1,1) | 色调颜色 |
| `TintIntensity` | Float1 | 0.0 | 色调强度（0=不改变，1=完全应用） |
| `TintMode` | Float1 | 0.0 | 色调模式：0=Overlay，1=乘法，2=SoftLight |
| `Saturation` | Float1 | 1.0 | 饱和度（0=灰度，1=原始，>1=过饱和） |

### 5.2 Toon（总开关）

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `UseToonTexture` | Float1 | 1.0 | 1=采样 ToonTexture，0=用 LitColor 纯色 |
| `LitColor` | Float3 | (1,1,1) | UseToonTexture=0 时的亮部基础色 |
| `UseToonShading` | Float1 | 1.0 | Toon 总开关（0=跳过全部风格化，仅基础光照） |

### 5.3 Shadow（阴影，三条路径）

**路径选择逻辑**：
```
UseCurve=1（默认）──► 曲线阴影映射
UseCurve=0
  ├─ UseRampTex=1 ──► Ramp 贴图映射
  └─ UseRampTex=0 ──► 三层色带（回退）
```

| 参数 | 类型 | 默认值 | 生效路径 | 说明 |
|------|------|--------|---------|------|
| `UseCurve` | Float1 | 1.0 | — | **1=曲线图集（默认），0=回退** |
| `UseRampTex` | Float1 | 1.0 | UseCurve=0 | 1=Ramp 贴图，0=三层色带 |
| `ShadowSmooth` | Float1 | 1.0 | 曲线/Ramp | 阴影平滑度（越大过渡越柔化） |
| `ShadowLocation` | Float1 | 0.0 | 曲线/Ramp | 阴影位置偏移（>0 阴影前移变多） |
| `ShadowThreshold` | Float1 | 0.5 | 色带 | 深阴影起点 T1 |
| `ShadowEnd` | Float1 | 0.75 | 色带 | 亮区起点 T3 |
| `MidSplit` | Float1 | 0.60 | 色带 | 中间层分配比 |
| `ShadowSharpness` | Float1 | 0.8 | 色带 | 阴影锋利度 |
| `ShadowColor` | Float3 | (0.2,0.2,0.4) | 全部 | 第一层阴影色（最暗） |
| `Shadow2Color` | Float3 | (0.5,0.5,0.6) | 全部 | 第二层阴影色 |
| `Shadow3Color` | Float3 | (0.8,0.8,0.85) | 色带 | 第三层阴影色 |
| `ShadowHueShift` | Float1 | 0.0 | 全部 | 阴影色相偏移（度） |
| `ShadowSaturation` | Float1 | 1.0 | 全部 | 阴影饱和度 |
| `ShadowBrightness` | Float1 | 1.0 | 全部 | 阴影亮度 |

### 5.4 AO（环境光遮蔽，依赖 HM 贴图）

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `UseHM` | Float1 | 0.0 | 1=启用 HM 贴图（R=高光蒙版 + G=AO） |
| `UseAO` | Float1 | 1.0 | 1=启用 AO 遮蔽 |
| `AO_Power_ShadowMask` | Float1 | 1.0 | AO 强度（pow 指数） |
| `AO_Shadow_Strengh` | Float1 | 0.0 | AO 与 ShadowMask 的混合强度 |

> **依赖关系**：AO 数据来自 HM 贴图的 G 通道。`UseAO=1` 但 `UseHM=0` 时，HM_AO 恒为 1.0，AO 无效果。

### 5.5 SSS（次表面散射）

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `UseSSS` | Float1 | 0.0 | 1=启用次表面散射 |
| `SSSColor` | Float3 | (1,1,1) | SSS 颜色 × 强度 |

### 5.6 Rim（边缘光）

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `RimWidth` | Float1 | 0.35 | 条带宽度（越大 Rim 越宽） |
| `RimGradient` | Float1 | 0.15 | 边缘渐变（越大过渡越柔和） |
| `RimColor` | Float3 | (1,1,1) | Rim 颜色 × 强度 |

### 5.7 Matcap（双 Matcap）

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `MatcapColor` | Float3 | (1,1,1) | 高光 Matcap 颜色 × 强度 |
| `RoughMatcapColor` | Float3 | (1,1,1) | 粗糙 Matcap 颜色 × 强度 |
| `RoughColor` | Float3 | (1,1,1) | 粗糙 Matcap 混合色 |
| `MatcapScale` | Float1 | 1.0 | Matcap UV 缩放 |
| `MatcapOffset` | Float1 | 0.0 | Matcap UV 偏移 |

### 5.8 Normal（法线）

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `NormalMapIntensity` | Float1 | 1.0 | 法线贴图强度 |

### 5.9 Exposure（曝光）

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `ExposureScale` | Float1 | 1.0 | 整体曝光矫正（>1 提亮，<1 压暗） |

### 5.10 Tonemap（独立节点）

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `UseTonemap` | Float1 | 0.0 | 1=启用 ACES 色调映射（默认关闭） |

---

## 6. 渲染管线深度解析

### 6.1 基础底色与色调混合

```hlsl
float3 ResultColor = Texture2DSample(BaseColorTex, BaseColorTexSampler, UV).rgb;
```

获取 Base Color 后，进入色调混合系统。三种模式（`TintMode`）：

| 模式 | 算法 | 特点 |
|------|------|------|
| **Overlay（0）** | 暗部: `2×Base×Tint`，亮部: `1−2×(1−Base)×(1−Tint)` | 保留明暗层次，色调自然融合 |
| **Multiply（1）** | `Base × Tint` | 传统正片叠底，暗部可能过暗 |
| **SoftLight（2）** | 暗部: `Base−(1−2Tint)×Base×(1−Base)`，亮部: `Base+(2Tint−1)×(sqrt(Base)−Base)` | 最柔和，适合皮肤色温微调 |

> **为什么用 `round()` 硬分档而不是连续插值？** 三种模式各自有不同的数学形式，让"Overlay"和"Multiply"之间做插值没有物理意义的中间态。这是离散选择，不是连续谱。`round()` 让浮点输入自然落到最近的整数档位，写 0.6 就当 Mode 1——比要求精确整数更容错。

最终用 `TintIntensity` 混合：
```hlsl
ResultColor = lerp(ResultColor, TintedColor, TintIntensity);
```

### 6.2 饱和度调节

```hlsl
float Luminance = dot(ResultColor, float3(0.2126, 0.7152, 0.0722));
ResultColor = lerp(float3(Luminance, Luminance, Luminance), ResultColor, Saturation);
```

使用 **Rec.709 亮度系数**（人眼对绿光最敏感）计算灰度值，然后在灰度和原始颜色之间插值。`Saturation=0` 输出灰度，`=1` 保持原始，`>1` 过饱和。

### 6.3 方向向量与基础光照

```hlsl
float3 N = normalize(WorldNormal);
float3 V = normalize(-CameraVector);   // pixel → camera
float3 L = normalize(LightDirection);  // pixel → light

float NdotL     = dot(N, L);
float LightAtten = NdotL * 0.5 + 0.5;  // [-1,1] → [0,1]
```

`LightAtten` 是经典的 **Half Lambert** 映射，将 `[-1, 1]` 的 NdotL 值域映射到 `[0, 1]`。这避免了纯 Lambert 在背光面完全死黑的问题，为后续 Toon 阴影提供更宽的动态范围。

### 6.4 Toon 总开关

```hlsl
if (UseToonShading < 0.5)
{
    ResultColor *= LightAtten;
    return ResultColor;
}
```

`UseToonShading=0` 时跳过所有风格化处理，仅做基础光照衰减，直接返回。这是一个快速对比开关，方便美术检查风格化前后的差异。

### 6.5 法线贴图（双守卫）

```hlsl
float2 RawXY = Texture2DSample(NormalMapTex, NormalMapTexSampler, UV).rg * 2.0 - 1.0;
float TangentLen = length(WorldTangent);

float3 BumpNormal;
if (TangentLen < 1e-4 || dot(RawXY, RawXY) > 1.0)
{
    BumpNormal = N;  // 守卫命中 → 退回几何法线
}
else
{
    float3 T = WorldTangent / TangentLen;
    T = normalize(T - N * dot(N, T));  // Gram-Schmidt 正交化
    float3 B = cross(N, T);
    float2 NormalXY = RawXY * NormalMapIntensity;
    float NormalZ   = sqrt(saturate(1.0 - dot(NormalXY, NormalXY)));
    BumpNormal = normalize(NormalXY.x * T + NormalXY.y * B + NormalZ * N);
}
```

**两道守卫**：

| 守卫 | 条件 | 保护目标 |
|------|------|---------|
| 切线无效 NaN 守卫 | `TangentLen < 1e-4` | 防止除零产生 NaN（退化三角形/无切线数据） |
| BC5 蓝通道守卫 | `dot(RawXY, RawXY) > 1.0` | 防止 RG 值超出单位圆时 Z 重建为虚数 |

**只读 RG、重建 Z 的原因**：UE 的 NormalMap 压缩使用 BC5 格式，只存 RG 两个通道。Custom 节点采样 BC5 纹理时蓝通道返回值不可靠，所以只读 XY，Z 用 `sqrt(1 - x² - y²)` 重建。

**Gram-Schmidt 正交化的原因**：GPU 管线里从 VS 传到 PS 的 T 和 N 并不保证正交——美术模型的顶点法线和切线本身就可能不严格正交，三角形内插值后更可能偏离。非正交的 TBN 基会导致法线方向系统性地偏移。

**BumpNormal 只用于 Matcap，不用于 Toon 阴影/Rim**：
- Toon 阴影用几何法线 N：如果用 BumpNormal，布料皱褶处的 NdotL 会产生微小波动，smoothstep 输出的阴影 Mask 出现细碎斑块，看起来像画面 bug
- Rim 用几何法线 N：如果用 BumpNormal，轮廓边缘的 Fresnel 会因法线波动出现锯齿
- Matcap 用 BumpNormal：高光斑被法线切碎，看起来像"材质有表面细节"——这正是法线贴图的本职工作

### 6.6 HM 贴图（高光蒙版 + AO）

```hlsl
float HM_HighLightMask = 1.0;
float HM_AO = 1.0;
if (UseHM > 0.5)
{
    float3 HM = Texture2DSample(HMTexture, HMTextureSampler, UV).rgb;
    HM_HighLightMask = HM.r;   // 高光蒙版（控制 Matcap 高光范围）
    HM_AO = HM.g;              // AO（环境光遮蔽）
}
```

用一张贴图同时控制两个效果，节省纹理槽位：
- **R 通道（高光蒙版）**：黑色 = 无高光，白色 = 完整高光。用于精确控制哪些区域显示 Matcap 高光（如只在金属扣件上显示高光）
- **G 通道（AO）**：黑色 = 完全遮蔽，白色 = 无遮蔽。用于模拟模型自身的环境光遮蔽

### 6.7 Toon 阴影系统（三条路径）

这是整个 Shader 塑造立体感的核心。三条路径通过 `UseCurve` 和 `UseRampTex` 开关选择。

#### 6.7.1 HSV 统一调色（三条路径共用的预处理）

在进入具体路径之前，先对三套阴影色做 HSV 调整：

```hlsl
float HueRad = radians(ShadowHueShift);
float HueCos = cos(HueRad);
float HueSin = sin(HueRad);
float HueOneThird = (1.0 - HueCos) / 3.0;
float HueRoot = sqrt(1.0 / 3.0) * HueSin;

float3x3 ShadowHueMatrix = float3x3(
    HueCos + HueOneThird,  HueOneThird - HueRoot, HueOneThird + HueRoot,
    HueOneThird + HueRoot, HueCos + HueOneThird,  HueOneThird - HueRoot,
    HueOneThird - HueRoot, HueOneThird + HueRoot, HueCos + HueOneThird
);
```

**为什么不走 RGB→HSV→调→RGB 的转换管线？**

HSV 的 Hue 本质是绕 `(1,1,1)` 灰轴的旋转。绕任意单位向量的旋转有解析 3×3 矩阵——直接乘就行，不需要转出 RGB。这比来回 HSV 转换少 9 条 ALU 指令，且避免了 HSV 空间 0°=360° 的色相环绕边界条件。

矩阵的推导来自 **Rodriguez 旋转公式**。边界验证：`HueShift=0°` 时 `cos0=1, sin0=0`，矩阵 = 单位矩阵，颜色不变。

饱和度调整：向 Rec.709 亮度做 lerp（`lerp(灰度, 色相旋转后颜色, ShadowSaturation)`）。
明度调整：直接乘 `ShadowBrightness` 标量。

三层颜色用同一个矩阵，只需要算一次矩阵系数。

#### 6.7.2 路径 A：曲线阴影映射（UseCurve=1，默认）

```hlsl
float rampU = saturate(NdotL / max(0.001, ShadowSmooth) - ShadowLocation);
float3 RampLit = Texture2DSample(CurveAtlasTexture, CurveAtlasTextureSampler, float2(rampU, 0.5)).rgb;

FinalToon = lerp(ShadowColorAdj, RampLit, saturate(rampU * 2.0));
ShadowMask = saturate(rampU);
```

**核心公式**：`rampU = saturate(NdotL / ShadowSmooth - ShadowLocation)`

- `ShadowSmooth`：分母越大，rampU 变化越平缓，阴影过渡越柔化。`ShadowSmooth=2.0` 时整个阴影区域被拉宽
- `ShadowLocation`：整体偏移，正值让阴影前移（更多区域进入阴影），负值让阴影后移

用 rampU 采样 `CurveAtlasTexture`（CurveLinearColorAtlas 曲线图集）。**曲线可实时调整**——在曲线编辑器里拖控制点，图集纹理自动重新烘焙，Shader 无需改动。这比传统 Ramp 贴图的工作流灵活得多。

暗部 tint：rampU 低（暗）时偏向 `ShadowColorAdj`，高（亮）时保持曲线采样结果。`rampU * 2.0` 作为混合因子，让暗部在前半段就完成阴影色着色。

#### 6.7.3 路径 B：Ramp 贴图映射（UseCurve=0, UseRampTex=1）

```hlsl
float rampU = saturate(NdotL / max(0.001, ShadowSmooth) - ShadowLocation);
float3 RampLit = (UseToonTexture > 0.5)
    ? Texture2DSample(ToonTexture, ToonTextureSampler, float2(rampU, 0.5)).rgb
    : LitColor;

FinalToon = lerp(ShadowColorAdj, RampLit, saturate(rampU * 2.0));
ShadowMask = saturate(rampU);
```

与路径 A 几乎一致，只是采样目标从曲线图集改为 Ramp 贴图（`ToonTexture`）。`UseToonTexture=0` 时用 `LitColor` 纯色替代贴图采样。

#### 6.7.4 路径 C：三层色带（UseCurve=0, UseRampTex=0）

这是 SingleFunc 的原始方式，作为最终回退。

```hlsl
float EdgeHalfWidth = lerp(0.05, 0.002, saturate(ShadowSharpness));

float T1 = ShadowThreshold;
float T3 = max(T1 + 0.05, ShadowEnd);
float BandTotal = T3 - T1;
float Shadow2Width = saturate(MidSplit) * BandTotal;
float Shadow3Width = (1.0 - saturate(MidSplit)) * BandTotal;
float T2 = T1 + Shadow2Width;

float Layer1Mask = smoothstep(T1 - EdgeHalfWidth, T1 + EdgeHalfWidth, LightAtten);
float Layer2Mask = smoothstep(T2 - EdgeHalfWidth, T2 + EdgeHalfWidth, LightAtten);
float Layer3Mask = smoothstep(T3 - EdgeHalfWidth, T3 + EdgeHalfWidth, LightAtten);
```

**色带结构**：

```
深阴影区         过渡带 (BandTotal)          亮区
[0 ...... T1]  [T1 ... T2 ... T3]  [T3 ...... 1.0]
ShadowColor    Shadow2  Shadow3    ToonTexture/LitColor
                ├─ W2 ─┤├─ W3 ─┤
                     ↑
              W2/(W2+W3) = MidSplit
```

**合成顺序**：从亮到暗逐层覆盖（`ToonSample → lerp(Shadow3) → lerp(Shadow2) → lerp(Shadow1)`），确保最暗的 ShadowColor 始终"胜出"。

**防崩溃设计**：`T3 = max(T1 + 0.05, ShadowEnd)` 强制保证 T3 > T1，防止外部输入错误导致色带宽度为负。

**抗锯齿**：`smoothstep` 的 Hermite 曲线（`3t² − 2t³`）保证 C1 连续，消除阴影边缘的硬切换闪烁。

### 6.8 AO 环境光遮蔽

```hlsl
if (UseAO > 0.5)
{
    float AO = saturate(pow(HM_AO, max(0.001, AO_Power_ShadowMask)));
    ShadowMask = lerp(ShadowMask, ShadowMask * AO, saturate(AO_Shadow_Strengh));
}
```

AO 来自 HM 贴图的 G 通道，通过 `pow` 控制强度曲线。`AO_Shadow_Strengh` 控制 AO 与原始 ShadowMask 的混合程度——0 时 AO 不影响阴影，1 时完全用 AO 调制阴影。

### 6.9 Rim Light 边缘光

```hlsl
float NdotV   = abs(dot(N, V));
float Fresnel = 1.0 - NdotV;

float RimThreshold = 1.0 - saturate(RimWidth);
float RimEdgeHalfWidth = lerp(0.002, 0.3, saturate(RimGradient));

float RimMask = smoothstep(RimThreshold - RimEdgeHalfWidth, RimThreshold + RimEdgeHalfWidth, Fresnel);

float RimLightMask = saturate(NdotL);
float Rim = RimMask * RimLightMask * ShadowMask;
ResultColor += RimColor * Rim;
```

**三参数解耦设计**：

| 参数 | 控制什么 | 数学位置 |
|------|---------|---------|
| `RimWidth` | 条带宽窄 | `RimThreshold = 1 - Width`，平移 Fresnel 的判定阈值 |
| `RimGradient` | 边缘软硬 | `RimEdgeHalfWidth`，smoothstep 的过渡半宽 |
| `RimColor` | 颜色 × 强度 | 最终乘法系数 |

**光源遮罩**：`RimLightMask = saturate(NdotL)` 保证只有朝向光源的半边轮廓亮，背光面自然消失。这比旧版用 `dot(L,V)*0.5+0.5` 的均匀光晕更接近真实边缘光的物理行为。

**ShadowMask 遮蔽**：Rim 也乘了 ShadowMask，确保阴影区域不出现 Rim 光——风格一致性保障。

### 6.10 双 Matcap 球面贴图

#### 6.10.1 自适应防死锁球面映射

这是整个 Shader 中数学含量最高的部分。

**问题**：Matcap 映射需要一个"上方向"来构建相机平面的正交参考系。通常用世界 Z 轴 `(0,0,1)`。但当相机俯视/仰视时 `CamDir ≈ (0,0,±1)`，与参考轴平行 → `cross((0,0,1), CamDir) → (0,0,0)` → 参考基退化 → UV 坐标崩溃为 (0,0) → 高光瞬间跳变。

**解法：无缝双参考系插值算法**

```hlsl
float3 RefUpA = float3(0.0, 0.0, 1.0);  // 主参考系（Z 轴）
float3 RefUpB = float3(0.0, 1.0, 0.0);  // 备用参考系（Y 轴）

float AlignA = abs(dot(CamDir, RefUpA));
float BlendFactor = smoothstep(0.85, 0.99, AlignA);

float3 RightA = normalize(cross(RefUpA, CamDir));
float3 RightB = normalize(cross(RefUpB, CamDir));

float3 CamRight = normalize(lerp(RightA, RightB, BlendFactor));
float3 CamUp    = normalize(cross(CamDir, CamRight));
```

**关键设计点——为什么混 Right 而不是直接混 Up**：

`cross(Up, CamDir) = Right`，`cross(CamDir, Right) = Up`（正交基关系）。如果直接混 Up：`lerp(Z, Y, blend)` → 当 `CamDir ≈ Up_mix` 时仍然退化。把混合放到 Right 端：RightA 和 RightB 分别是两组参考轴与 CamDir 的叉积，它们在各自的有效范围内不会退化，混出来的中间 Right 也不会正好平行 CamDir。

这类似于四元数球面线性插值（slerp）在欧拉角框架下的简化实现——本质都是避免"中间插值经过退化点"。

**BlendFactor 区间 [0.85, 0.99]**：起点 0.85 → 相机离 Z 轴约 31.8° 时开始混合，外观上混合在过渡完成前不可见；终点 0.99 → 离 Z 轴约 8.1° 时完成混合，此时 RightA 还没有明显退化。

#### 6.10.2 Matcap UV 计算

```hlsl
float2 MatcapUV;
MatcapUV.x = dot(BumpNormal, CamRight) * 0.5 + 0.5;
MatcapUV.y = dot(BumpNormal, CamUp)    * 0.5 + 0.5;

MatcapUV = MatcapUV * MatcapScale + MatcapOffset;
```

用 BumpNormal（不是几何法线 N）与相机平面的正交基做点乘，映射到 `[0, 1]` 的 UV 坐标。`MatcapScale` 和 `MatcapOffset` 提供缩放和偏移控制。

#### 6.10.3 双 Matcap 采样

```hlsl
// 高光 Matcap（× HM.R 高光蒙版 × ShadowMask）
float3 MatcapSample = Texture2DSample(MatcapTexture, MatcapTextureSampler, MatcapUV).rgb;
ResultColor += MatcapSample * MatcapColor * HM_HighLightMask * ShadowMask;

// 粗糙 Matcap（× RoughColor × ShadowMask）
float3 RoughMatcapSample = Texture2DSample(RoughMatcapTexture, RoughMatcapTextureSampler, MatcapUV).rgb;
ResultColor += RoughMatcapSample * RoughMatcapColor * RoughColor * ShadowMask;
```

**双 Matcap 的设计意图**：
- **高光 Matcap**：× HM.R 高光蒙版，控制光滑区域的高光范围（如金属扣件、珠宝）
- **粗糙 Matcap**：× RoughColor 混合色，控制哑光/粗糙区域的质感（如布料、皮肤）

两张 Matcap 共用同一个 UV 坐标（同一个相机视角），但各自独立控制颜色和强度，解决了单一 Matcap 无法区分光滑/哑光区域的问题。

### 6.11 SSS 次表面散射

```hlsl
if (UseSSS > 0.5)
{
    float3 SSS = Texture2DSample(SSSTex, SSSTexSampler, UV).rgb;
    ResultColor += SSS * SSSColor;
}
```

SSS 贴图在美术软件中预烘焙好边缘透光区域（通常是皮肤的耳朵、鼻翼、手指等薄处），`SSSColor` 控制透光颜色和强度。这是简化版的次表面散射——不依赖屏幕空间的光线追踪，纯美术控制。

### 6.12 曝光矫正

```hlsl
ResultColor *= ExposureScale;
```

`ExposureScale` 是最终的全局亮度乘数。`>1` 提亮（适用于暗部细节不足），`<1` 压暗（适用于高光过曝）。与 Tonemap 配合使用时：ExposureScale 提亮 → Tonemap 压缩高光，两者叠加不过曝。

### 6.13 Tonemap 色调映射（独立节点）

这是一个**独立的 Custom 节点**，不在主节点内部。

**为什么独立？** 示例材质用 `include "/Engine/Private/TonemapCommon.ush"` 的 hack 调用 `FilmToneMapInverse`，但该 hack 在 UE 5.8 已失效（`undeclared identifier`）。本版改为 HLSL 手写 ACES Filmic 正向色调映射。

**ACES Filmic 色调映射公式**（Narkowicz 近似）：

```
f(x) = x * (2.51x + 0.03) / (x * (2.43x + 0.59) + 0.14)
```

**ToneMap 节点代码**：

```hlsl
if (UseTonemap > 0.5)
{
    const float A = 2.51;
    const float B = 0.03;
    const float C = 2.43;
    const float D = 0.59;
    const float E = 0.14;
    return saturate((col * (A * col + B)) / (col * (C * col + D) + E));
}
return col;
```

**作用**：HDR → LDR 色调映射，压缩高光防过曝。`UseTonemap` 默认关闭（直通输出），按需开启。

---

## 7. 关键设计决策

### 7.1 取舍决策速查

| 决策 | 选择 | 舍弃 |
|------|------|------|
| 阴影法线 | 几何法线 N（平滑） | 法线贴图细节带来的阴影质感（会碎） |
| 高光法线 | BumpNormal（有细节） | — |
| 阴影映射 | 曲线为主 + Ramp/色带回退 | 单一固定 Ramp（不够灵活） |
| Rim 光源遮罩 | `saturate(NdotL)` 含法线 | 无 N 的均匀光晕 |
| Matcap 参考轴 | 两组轴 smoothstep 混合 | 单参考轴（有极点 bug） |
| 阴影色调整 | HSV 数学等价（RGB 空间） | 标准 HSV 转换（多指令） |
| 高光方式 | 双 Matcap | Blinn-Phong 参数高光 + 头发 UV 高光 |
| HM 贴图 | 一张图（R=高光, G=AO） | 两张独立贴图 |

### 7.2 参数分层

```
适合动画（连续量，平滑插值）:
  ExposureScale, RimColor, MatcapColor, RoughMatcapColor,
  ShadowHueShift, ShadowSaturation, ShadowBrightness,
  ShadowSmooth, ShadowLocation

一次性设置（形状/色板）:
  ShadowThreshold, ShadowEnd, MidSplit, ShadowSharpness,
  RimWidth, RimGradient, 各种 Color（Shadow1/2/3）

离散开关（不要做动画）:
  UseToonShading, UseCurve, UseRampTex, UseHM, UseAO, UseSSS,
  UseTonemap, TintMode (round() 硬分档)
```

---

## 8. 使用步骤

### 8.1 基础设置

1. 在 UE 中创建 Unlit 材质，按第 3 节配置两个 Custom 节点
2. 在 Inputs 面板按顺序添加 47 个输入引脚（名称、类型、连接来源见 Shader 文件头部注释）
3. 创建 TextureObjectParameter 节点连接贴图引脚
4. 主节点输出 → ToneMap 节点的 col → ToneMap 输出 → Emissive Color

### 8.2 阴影配置

1. **默认 `UseCurve=1`**（曲线阴影），用 `ShadowSmooth` 和 `ShadowLocation` 调整阴影形状
2. 需要 Ramp 贴图方式时：`UseCurve=0`，`UseRampTex=1`，指定 `ToonTexture`
3. 需要离散色带时：`UseCurve=0`，`UseRampTex=0`，用 `ShadowThreshold/End/MidSplit/Sharpness` 调整

### 8.3 高级功能

4. 需要 AO/高光蒙版时：`UseHM=1`，指定 `HMTexture`
5. 需要次表面散射时：`UseSSS=1`，指定 `SSSTex`
6. 需要电影感 HDR 效果时：`UseTonemap=1`

---

## 9. 版本对比与迁移

### 9.1 版本功能对比

| 功能 | SingleFunc | Full（本版本） | Full_Accessories | Full_AI |
|------|-----------|---------------|-----------------|---------|
| 色调三模式 | ✅ | ✅ | ✅ | ✅ |
| 饱和度 | ✅ | ✅ | ✅ | ✅ |
| HSV 阴影调色 | ✅ | ✅ | ✅ | ✅ |
| 三层色带 | ✅（唯一） | ✅（回退） | ✅（回退） | ✅（回退） |
| Ramp 贴图 | ❌ | ✅ | ✅ | ✅ |
| 曲线阴影映射 | ❌ | ✅ | ✅ | ✅ |
| 双 Matcap | ❌ | ✅ | ✅ | ✅ |
| HM 贴图 / AO | ❌ | ✅ | ✅ | ✅ |
| SSS | ❌ | ✅ | ✅ | ✅ |
| Tonemap | ❌ | ✅ | ✅ | ✅ |
| 各向异性高光 | ❌ | ❌ | ✅ | ✅ |
| AI 参数预测 | ❌ | ❌ | ❌ | ✅ |
| Specular 参数高光 | ✅ | ❌ | ❌ | ❌ |
| 头发 UV 高光 | ✅ | ❌ | ❌ | ❌ |

### 9.2 SingleFunc → Full 迁移对照

| SingleFunc 参数 | Full 处理 |
|----------------|-----------|
| `SpecPower` / `SpecularThreshold` / `SpecularSoftness` / `SpecularColor` | 删除，高光由双 Matcap + HM 承担 |
| `ExposureScale` | 保留（非删除，与 Tonemap 互补） |
| `HairHighlightTexture` / `UseHairHighlightTexture` / `HairHighlightColor` | 删除，头发高光由高光 Matcap 承担 |
| `MatcapTexture`（单） | `MatcapTexture`（高光）+ `RoughMatcapTexture`（粗糙） |
| `ShadowThreshold` / `End` / `MidSplit` / `Sharpness`（主） | 保留为色带回退，曲线为主 |
| 其余（色调/饱和度/HSV/Rim/法线/总开关） | 全部保留 |

---

## 10. 注意事项与已知限制

### 10.1 贴图规范

1. **贴图必须用 TextureObjectParameter**，不能用 TextureSampleParameter2D
2. **CurveAtlasTexture 的 samplerType 必须设为 LinearColor**（HDR 线性格式）
3. **NormalMapTex 使用 BC5 压缩**，蓝通道不可靠，Shader 只读 RG 重建 Z

### 10.2 依赖关系

4. **AO 依赖 HM 贴图**：`UseAO=1` 但 `UseHM=0` 时 AO 无效果（HM_AO 恒 1）
5. **色带参数仅在 UseRampTex=0 时生效**：曲线/Ramp 方式下 ShadowThreshold/End/MidSplit/Sharpness 不参与计算

### 10.3 光源与渲染

6. **LightDirection 用 SkyAtmosphereLightDirection**：自动跟随场景太阳，若阴影反相需检查光源方向约定
7. **UseTonemap 默认关闭**：Tonemap 逆运算会把颜色映射到 HDR，可能让画面变亮，按需开启
8. **法线贴图不用于 Toon 阴影和 Rim**：这是有意设计，不是 bug。用 BumpNormal 会产生细碎阴影斑块

### 10.4 已知限制

9. **法线贴图镜像 UV 处理**：对称模型的镜像 UV 会导致凹凸方向在镜像侧反转，标准解决方案是靠美术手动翻转 G 通道
10. **无 LOD 系统**：远距离可以考虑跳过法线贴图（BumpNormal=N）、关闭 Matcap，但当前未实现

---

## 11. 文件清单

| 文件 | 说明 |
|------|------|
| `MMDToonShader_SM5_SingleFunc_Full.hlsl` | 主 shader 文件（本版本） |
| `MMDToonShader_SM5_SingleFunc_Full_Accessories.hlsl` | 配件增强版（+各向异性高光） |
| `MMDToonShader_SM5_SingleFunc_Full_Alpha.hlsl` | Alpha 支持版（+透明度） |
| `MMDToonShader_SM5_SingleFunc_Full_AI.hlsl` | AI 驱动版（+MLP 预测） |
| `MMDToonShader_SM5_SingleFunc.hlsl` | 基线版本（三层色带版） |
| `MMDToonShader_SM5_SingleFunc_Hair.hlsl` | 头发边缘半透明专属版 |
| `MMDToonShader_SM5_SingleFunc_Alpha.hlsl` | SingleFunc Alpha 版 |
