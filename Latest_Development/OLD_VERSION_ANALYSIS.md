# 旧版本功能分析报告

## 头发版本 (MMDToonShader_SM5_SingleFunc_Hair.hlsl)

### 基本信息
- **文件大小**：7488 字节
- **修改时间**：2026/5/8 4:52:13
- **适用材质**：Translucent 模式
- **输出类型**：Float4（RGB → Emissive Color，A → Opacity）

### 核心功能
1. **基础渲染**：采样 BaseColorTex，支持贴图 Alpha 通道
2. **色调混合**：三种模式（Overlay/乘法/Soft-Light）
3. **Toon 阴影**：单层阴影，使用 smoothstep + pow 实现
4. **Rim Light**：基于 Fresnel + 光源方向遮蔽
5. **高光贴图**：使用独立 SpecularTexture（R=范围，G=强度）
6. **Matcap 球面贴图**：视角空间法线 XY 作为 UV
7. **头发边缘半透明**：基于 Fresnel 的边缘透明效果

### 独特参数
| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `HairEdgeWidth` | Float1 | 0.2 | 边缘半透明宽度（0~1） |
| `HairEdgeOpacity` | Float1 | 0.0 | 边缘最外侧透明度（0=完全透明） |

### 实现原理
```hlsl
// 边缘检测：Fresnel 接近 1.0 时为最边缘
float EdgeThreshold = 1.0 - saturate(HairEdgeWidth);
float HairEdgeMask = smoothstep(EdgeThreshold, 1.0, Fresnel);

// 透明度混合：边缘乘以 HairEdgeOpacity，中心保持原样
float FinalAlpha = lerp(BaseAlpha, BaseAlpha * saturate(HairEdgeOpacity), HairEdgeMask);
```

### 缺失功能（与主文件对比）
- ❌ 三层 Toon 阴影（只有单层）
- ❌ HSV 批量调色（ShadowHueShift/ShadowSaturation/ShadowBrightness）
- ❌ 法线贴图支持（无 BumpNormal）
- ❌ 头发高光贴图（使用独立 SpecularTexture，非参数驱动）
- ❌ 饱和度调节（Saturation 参数）
- ❌ UseToonTexture/UseToonShading 开关
- ❌ ShadowEnd/MidSplit 参数（阴影位置控制）
- ❌ RimWidth/RimGradient（使用旧版 RimPower）
- ❌ SpecularSoftness（高光截断过渡）
- ❌ NormalMapIntensity
- ❌ ExposureScale

---

## 透明版本 (MMDToonShader_SM5_SingleFunc_Alpha.hlsl)

### 基本信息
- **文件大小**：8104 字节
- **修改时间**：2026/5/8 4:52:13
- **适用材质**：Translucent 或 Masked 模式
- **输出类型**：Float4（RGB → Emissive Color，A → Opacity/Opacity Mask）

### 核心功能
1. **基础渲染**：采样 BaseColorTex，保留 Alpha 通道
2. **色调混合**：三种模式（Overlay/乘法/Soft-Light）
3. **Toon 阴影**：单层阴影，使用 smoothstep + pow 实现
4. **Rim Light**：基于 Fresnel + 光源方向遮蔽
5. **高光贴图**：使用独立 SpecularTexture（R=范围，G=强度）
6. **Matcap 球面贴图**：视角空间法线 XY 作为 UV
7. **透明度处理**：直接使用贴图 Alpha 通道

### 特点
- 无额外透明度控制参数
- 适用于需要简单透明效果的材质
- 与头发版功能基本相同，但无头发边缘半透明控制

### 缺失功能（与主文件对比）
- ❌ 三层 Toon 阴影（只有单层）
- ❌ HSV 批量调色
- ❌ 法线贴图支持
- ❌ 头发高光贴图（使用独立 SpecularTexture）
- ❌ 饱和度调节
- ❌ UseToonTexture/UseToonShading 开关
- ❌ ShadowEnd/MidSplit 参数
- ❌ RimWidth/RimGradient（使用旧版 RimPower）
- ❌ SpecularSoftness
- ❌ NormalMapIntensity
- ❌ ExposureScale
- ❌ 头发边缘半透明控制（HairEdgeWidth/HairEdgeOpacity）

---

## 旧版本 vs 主文件功能对比

| 功能 | 头发版 | 透明版 | 主文件 |
|------|--------|--------|--------|
| Toon 阴影层数 | 1 层 | 1 层 | 最多 3 层 |
| 阴影位置控制 | ShadowThreshold | ShadowThreshold | ShadowThreshold + ShadowEnd |
| 阴影 HSV 调色 | ❌ | ❌ | ✓ |
| 法线贴图 | ❌ | ❌ | ✓ |
| 高光实现 | 贴图驱动 | 贴图驱动 | 参数驱动 |
| 头发高光 | ❌ | ❌ | ✓（贴图/程序化） |
| Rim Light | RimPower（单一参数） | RimPower | RimWidth + RimGradient（解耦） |
| 饱和度调节 | ❌ | ❌ | ✓ |
| 曝光控制 | ❌ | ❌ | ✓ |
| 透明度控制 | HairEdgeWidth/Opacity | Alpha 通道 | ❌（Opaque 材质） |
| 材质模式 | Translucent | Translucent/Masked | Opaque |

## 升级建议

### 头发版升级方案
1. **保留核心功能**：头发边缘半透明（HairEdgeWidth/HairEdgeOpacity）
2. **从主文件移植**：
   - 三层 Toon 阴影系统
   - HSV 批量调色
   - 法线贴图支持
   - 参数驱动高光（移除 SpecularTexture）
   - 头发高光贴图/程序化
   - RimWidth/RimGradient（替代 RimPower）
   - 饱和度调节
   - ExposureScale
3. **输出类型**：保持 Float4（RGB + Alpha）

### 透明版升级方案
1. **保留核心功能**：Alpha 通道透明度
2. **从主文件移植**：同上（除头发边缘半透明）
3. **输出类型**：保持 Float4（RGB + Alpha）

### 共同升级点
- UseToonTexture/UseToonShading 开关
- ShadowEnd/MidSplit 参数
- SpecularSoftness
- NormalMapIntensity
- 更新默认值以匹配主文件