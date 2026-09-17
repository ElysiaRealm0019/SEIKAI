# 三版本对比报告

对比对象：
1. `MMDToonShader_SM5_SingleFunc.hlsl`（删改版，当前基线）
2. `M_Redner_Master1`（示例材质，UE 材质图节点）
3. `MMDToonShader_SM5_SingleFunc_Full.hlsl`（整合版，本次新建）

---

## 一、功能矩阵

| 功能 | SingleFunc | 示例材质 | Full 版 | 说明 |
|------|-----------|---------|---------|------|
| 基础色贴图 | BaseColorTex | T_BaseColor | BaseColorTex | ✅ 三版本一致 |
| 色调混合 | 三模式(Overlay/乘法/SoftLight) | 简单 | 三模式 | ✅ 保留 SingleFunc |
| 饱和度 | ✓ | - | ✓ | 保留 SingleFunc |
| 阴影映射 | 三层离散色带 | Ramp 贴图/曲线 | **Ramp 为主 + 色带回退** | ✅ 以示例为准 |
| 阴影位置控制 | ShadowThreshold/End | ShadowLocation/ShadowSmooth | 两者都保留 | ✅ 整合 |
| 法线贴图 | 双守卫+Z重建 | T_Normal | 双守卫+Z重建 | ✅ 保留 SingleFunc 修复 |
| Matcap | 单 | **双(高光+粗糙)** | **双** | ✅ 以示例为准 |
| HM 贴图(R=高光,G=AO) | - | ✓ | ✓ | ✅ 新增整合 |
| AO 遮蔽 | - | ✓ | ✓ | ✅ 新增整合 |
| SSS 次表面散射 | - | ✓ | ✓ | ✅ 新增整合 |
| Tonemap 逆运算 | - | FilmToneMapInverse | 两个辅助节点 | ✅ 新增整合 |
| Rim | RimWidth/RimGradient | RimSmooth/RimOffset | RimWidth/RimGradient | 保留 SingleFunc(更清晰) |
| Specular | 参数驱动 | Matcap 为主 | 参数驱动+HM蒙版 | ✅ 保留+增强 |
| 头发高光 | 贴图/各向异性 | - | 贴图/各向异性 | 保留 SingleFunc 特色 |
| HSV 统一调色 | ✓ | - | ✓ | 保留，前置到 Ramp/色带共用 |
| 曝光 | ✓ | - | ✓ | 保留 |
| UseToonShading 总开关 | ✓ | - | ✓ | 保留 |

---

## 二、参数完整性验证

### SingleFunc 参数（39 输入）→ Full 版保留情况

**方向（5）**：UV、WorldNormal、WorldTangent、CameraVector、LightDirection → ✅ 全部保留
（LightDirection 连接改为 SkyAtmosphereLightDirection 联动，与示例一致）

**贴图（5）**：BaseColorTex、ToonTexture、MatcapTexture、HairHighlightTexture、NormalMapTex → ✅ 全部保留

**标量（20）**：
TintIntensity、TintMode、Saturation、UseToonTexture、UseToonShading、
ShadowThreshold、ShadowEnd、MidSplit、ShadowSharpness、
ShadowHueShift、ShadowSaturation、ShadowBrightness、
RimWidth、RimGradient、SpecPower、SpecularThreshold、SpecularSoftness、
UseHairHighlightTexture、NormalMapIntensity、ExposureScale
→ ✅ 全部保留

**向量（9）**：
BaseTint、LitColor、ShadowColor、Shadow2Color、Shadow3Color、
RimColor、SpecularColor、MatcapColor、HairHighlightColor
→ ✅ 全部保留

### Full 版新增参数（整合示例材质，15 个）

| 类别 | 参数 | 对应示例材质 |
|------|------|-------------|
| 贴图 | RoughMatcapTexture | RoughMatcap |
| 贴图 | HMTexture | T_HM |
| 贴图 | SSSTex | SSSTex |
| 标量 | UseRampTex | UseRampTex |
| 标量 | ShadowSmooth | ShadowSmooth |
| 标量 | ShadowLocation | ShadowLocation |
| 标量 | UseHM | UseHMTex |
| 标量 | UseAO | (AO_Power 相关) |
| 标量 | AO_Power_ShadowMask | AO_Power_ShadowMask |
| 标量 | AO_Shadow_Strengh | AO_Shadow_Strengh |
| 标量 | UseSSS | UseSSSColor |
| 向量 | RoughMatcapColor | (RoughMatcap 颜色) |
| 向量 | RoughColor | RoughColor |
| 向量 | SSSColor | (SSS 颜色) |
| 向量 | MatcapScaleOffset | MatcaoScale_Offset |

### Full 版总计：54 输入 = 39（保留）+ 15（新增）

---

## 三、逻辑正确性验证

| 检查项 | 结果 | 说明 |
|--------|------|------|
| HSV 调色前置 | ✅ | 已从色带分支提取到 Ramp/色带共用，两方式颜色一致 |
| UseToonTexture 检查 | ✅ | Ramp 和色带两种方式都检查，避免悬空贴图 |
| HM 蒙版作用域 | ✅ | HM.R 乘 Specular 和高光 Matcap，HM.G 做 AO（与示例一致） |
| AO 混合 | ✅ | `lerp(ShadowMask, ShadowMask*AO, AO_Shadow_Strengh)` 默认关闭 |
| 双 Matcap | ✅ | 高光(×HM.R) + 粗糙(×RoughColor) 加法混合 |
| 法线双守卫 | ✅ | 保留 NaN 和 BC5 两道守卫 |
| 色带回退 | ✅ | UseRampTex=0 完整回退三层色带 |
| Ramp 采样坐标 | ✅ | `saturate(NdotL/ShadowSmooth - ShadowLocation)` 与示例一致 |
| Matcap UV 缩放偏移 | ✅ | MatcapScaleOffset 缩放+偏移 |
| 总开关 | ✅ | UseToonShading=0 提前 return，跳过全部处理 |

---

## 四、需要注意的点

1. **Tonemap 需要两个额外 Custom 节点**：主文件只能做线性颜色，FilmToneMapInverse 依赖 include hack，已在文件头部给出 Dummy 和 ToneMap 两个节点的完整代码和接线说明。

2. **Ramp 方式的暗部 tint**：Ramp 方式下 `FinalToon = lerp(ShadowColor, RampLit, saturate(rampU*2))`，ShadowColor 只影响最暗区域（rampU<0.5），中亮部由 Ramp 贴图决定。

3. **AO 依赖 HM 贴图**：UseAO=1 时，AO 数据来自 HM 贴图的 G 通道。若未启用 UseHM（HM_AO 默认 1），AO 恒为 1 无效果。需同时启用 UseHM 或单独提供 AO 数据。

4. **示例材质的两层阴影色 vs 三层的映射**：示例的 ShadowColor/ShadowColor_2 对应 Full 版的 ShadowColor/Shadow2Color，Full 版额外保留 Shadow3Color（色带回退用）。

---

## 结论

**对比通过，无功能遗漏。** Full 版：
- ✅ 完整保留 SingleFunc 全部 39 个参数和功能
- ✅ 完整整合示例材质全部 7 项新功能（Ramp、双 Matcap、HM、AO、SSS、Tonemap、光源联动）
- ✅ 逻辑正确，两版本共有功能优先采用示例材质方式（阴影映射、双 Matcap）
- ✅ 已修正 Ramp 方式 UseToonTexture 遗漏、HSV 调色作用域两个一致性问题
