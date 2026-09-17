// MMD Toon Shader - UE5 Custom Node 完整整合版（配件增强版）
// ================================================================
// 本文件是 MMDToonShader_SM5_SingleFunc_Full.hlsl 的配件增强版：
// 在完整整合版基础上，新增各向异性高光功能，
// 适用于需要区分不同材质配件（金属/皮革/丝袜/布料等）的角色渲染。
//
// 新增功能（相对 Full 版本）：
//   8. Kajiya-Kay 各向异性高光 —— 丝袜/皮革/布料等材质的拉长光带
//
// 参数复用（无需新增参数或贴图）：
//   MatcapScale → 各向异性锐利度（值越大光带越窄越锐利）
//   MatcapColor → 各向异性强度（颜色越亮强度越高）
//
// 使用方式：
//   金属配件：MatcapScale=1.0（普通 Matcap 效果）
//   丝袜/皮革：MatcapScale=2.0~4.0（各向异性拉长光带）
//   不同材质实例可独立设置参数，无需额外贴图
//
// 整合自示例材质的功能（保留自 Full 版本）：
//   1. 曲线阴影映射（UseCurve 开关，默认开启）
//   2. ShadowSmooth / ShadowLocation —— 阴影平滑度与位置
//   3. 双 Matcap —— 高光 Matcap + 粗糙 Matcap
//   4. HM 贴图（R=高光蒙版，G=AO）
//   5. AO 独立控制（AO_Power_ShadowMask / AO_Shadow_Strengh）
//   6. SSS 次表面散射（SSSTex）
//   7. Tonemap 色调映射（UseTonemap 开关，ACES 正向，默认关闭）
//
// 保留自 SingleFunc 的功能：
//   色调三模式（Overlay/乘法/SoftLight）、饱和度、HSV 统一调色、
//   三层色带（Ramp 关闭时的回退）、Rim 三参数、
//   法线贴图双守卫、UseToonShading 总开关。
//
// ================================================================
// 关于 Tonemap 色调映射（独立 Custom 节点）
// ================================================================
// 示例材质用 include "/Engine/Private/TonemapCommon.ush" 的 hack 调用
// FilmToneMapInverse，但该 hack 在 UE 5.8 已失效。
// 本版改用 HLSL 手写 ACES Filmic 正向色调映射（HDR→LDR，压缩高光防过曝），
// 独立 Custom 节点（ToneMap 节点）：
//   Output Type: CMOT Float3
//   输入引脚：col (Float3)、UseTonemap (Float1)
//   Code 字段粘贴：
//     if (UseTonemap > 0.5)
//     {
//         const float A = 2.51;
//         const float B = 0.03;
//         const float C = 2.43;
//         const float D = 0.59;
//         const float E = 0.14;
//         return saturate((col * (A * col + B)) / (col * (C * col + D) + E));
//     }
//     return col;
//   接线：主节点（本文件）输出 → ToneMap 节点的 col；ToneMap 输出 → Emissive。
//   UseTonemap 用标量参数控制（默认 0=关闭，直通输出）。
//   与 ExposureScale 配合：ExposureScale 提亮 → Tonemap 压缩高光，两者叠加不过曝。
// ================================================================
// 贴图传入方式：使用 TextureObjectParameter 节点
// ================================================================
//
// ================================================================
// UE5 Custom Node 输入配置 (Inputs 面板按顺序添加):
// ================================================================
// 名称               类型              连接来源
// ----------------------------------------------------------------
// UV                 Float2            TexCoord 节点
// WorldNormal        Float3            VertexNormalWS 节点
// WorldTangent       Float3            VertexTangentWS 节点
// CameraVector       Float3            CameraDirectionVector 节点
// LightDirection     Float3            SkyAtmosphereLightDirection 节点（联动场景太阳）
// BaseColorTex       Texture2D         TextureObjectParameter（基础色贴图）
// CurveAtlasTexture  Texture2D         TextureObjectParameter（曲线图集 CurveLinearColorAtlas，阴影映射，可实时调曲线）
// ToonTexture        Texture2D         TextureObjectParameter（Ramp 渐变贴图，横向左暗右亮，曲线关闭时的回退）
// MatcapTexture      Texture2D         TextureObjectParameter（高光 Matcap 球面贴图）
// RoughMatcapTexture Texture2D         TextureObjectParameter（粗糙 Matcap 球面贴图，新增）
// NormalMapTex       Texture2D         TextureObjectParameter（切线空间法线贴图，BC5）
// HMTexture          Texture2D         TextureObjectParameter（HM 贴图：R=高光蒙版，G=AO，新增）
// SSSTex             Texture2D         TextureObjectParameter（次表面散射贴图，新增）
// BaseTint           Float3            色调颜色  默认 (1,1,1)
// TintIntensity      Float1            色调强度  默认 0.0
// TintMode           Float1            色调模式  默认 0.0（0=Overlay,1=乘法,2=SoftLight）
// Saturation         Float1            饱和度  默认 1.0
// UseToonTexture     Float1            Toon 贴图开关  默认 1.0
// LitColor           Float3            亮部基础色  默认 (1,1,1)（UseToonTexture=0 时生效）
// UseToonShading     Float1            Toon 总开关  默认 1.0
// UseCurve           Float1            曲线阴影开关  默认 1.0（1=采样曲线图集，0=用 UseRampTex 的贴图/色带）
// UseRampTex         Float1            Ramp 阴影开关  默认 1.0（UseCurve=0 时：1=Ramp 贴图，0=三层色带）
// ShadowSmooth       Float1            阴影平滑度  默认 1.0（Ramp 方式，分母）
// ShadowLocation     Float1            阴影位置  默认 0.0（Ramp 方式，偏移）
// ShadowThreshold    Float1            深阴影起点 T1  默认 0.5（色带方式）
// ShadowEnd          Float1            亮区起点 T3  默认 0.75（色带方式）
// MidSplit           Float1            中间层分配比  默认 0.60（色带方式）
// ShadowSharpness    Float1            阴影锋利度  默认 0.8（色带方式）
// ShadowColor        Float3            第一层阴影色  默认 (0.2,0.2,0.4)
// Shadow2Color       Float3            第二层阴影色  默认 (0.5,0.5,0.6)
// Shadow3Color       Float3            第三层阴影色  默认 (0.8,0.8,0.85)
// ShadowHueShift     Float1            阴影色相偏移  默认 0.0
// ShadowSaturation   Float1            阴影饱和度  默认 1.0
// ShadowBrightness   Float1            阴影亮度  默认 1.0
// UseHM              Float1            HM 贴图开关  默认 0.0（1=启用 R 高光蒙版 + G AO）
// UseAO              Float1            AO 开关  默认 1.0（1=启用 AO 遮蔽）
// AO_Power_ShadowMask Float1           AO 强度  默认 1.0
// AO_Shadow_Strengh  Float1            AO 阴影混合强度  默认 0.0
// UseSSS             Float1            SSS 开关  默认 0.0（1=启用次表面散射）
// SSSColor           Float3            SSS 颜色+强度  默认 (1,1,1)
// RimWidth           Float1            Rim 条带宽度  默认 0.35
// RimGradient        Float1            Rim 边缘渐变  默认 0.15
// RimColor           Float3            Rim 颜色+强度  默认 (1,1,1)
// MatcapColor        Float3            高光 Matcap 颜色+强度  默认 (1,1,1)
// RoughMatcapColor   Float3            粗糙 Matcap 颜色+强度  默认 (1,1,1)
// RoughColor         Float3            粗糙 Matcap 混合色  默认 (1,1,1)
// MatcapScale        Float1            Matcap UV 缩放  默认 1.0
// MatcapOffset       Float1            Matcap UV 偏移  默认 0.0
// NormalMapIntensity Float1            法线贴图强度  默认 1.0
// ExposureScale      Float1            整体曝光矫正  默认 1.0（部位明暗不统一时可调，>1 提亮 <1 压暗）
// ----------------------------------------------------------------
// Output Type: CMOT Float3  →  Emissive Color（或接 Tonemap 节点 C 的 col）
// ================================================================

// ---------- Base Colour ----------
float3 ResultColor = Texture2DSample(BaseColorTex, BaseColorTexSampler, UV).rgb;

// ---------- Base Color 色调（多模式，保留 SingleFunc） ----------
float3 TintedColor;
float TintModeVal = round(clamp(TintMode, 0.0, 2.0));

if (TintModeVal < 0.5)
{
    float3 overlay;
    overlay.r = (ResultColor.r < 0.5) ? (2.0 * ResultColor.r * BaseTint.r)
                                      : (1.0 - 2.0 * (1.0 - ResultColor.r) * (1.0 - BaseTint.r));
    overlay.g = (ResultColor.g < 0.5) ? (2.0 * ResultColor.g * BaseTint.g)
                                      : (1.0 - 2.0 * (1.0 - ResultColor.g) * (1.0 - BaseTint.g));
    overlay.b = (ResultColor.b < 0.5) ? (2.0 * ResultColor.b * BaseTint.b)
                                      : (1.0 - 2.0 * (1.0 - ResultColor.b) * (1.0 - BaseTint.b));
    TintedColor = overlay;
}
else if (TintModeVal < 1.5)
{
    TintedColor = ResultColor * BaseTint;
}
else
{
    float3 softlight;
    float3 softlightA = ResultColor - (1.0 - 2.0 * BaseTint) * ResultColor * (1.0 - ResultColor);
    float3 softlightB = ResultColor + (2.0 * BaseTint - 1.0) * (sqrt(ResultColor) - ResultColor);
    softlight = select(BaseTint <= 0.5, softlightA, softlightB);
    TintedColor = softlight;
}

ResultColor = lerp(ResultColor, TintedColor, TintIntensity);

// ---------- 饱和度调节 ----------
float Luminance = dot(ResultColor, float3(0.2126, 0.7152, 0.0722));
ResultColor = lerp(float3(Luminance, Luminance, Luminance), ResultColor, Saturation);

// ---------- 方向向量 ----------
float3 N = normalize(WorldNormal);
float3 V = normalize(-CameraVector);   // pixel → camera
float3 L = normalize(LightDirection);  // pixel → light

// ---------- 基础光照衰减 ----------
float NdotL     = dot(N, L);
float LightAtten = NdotL * 0.5 + 0.5;  // [-1,1] → [0,1]

// ---------- Toon 风格化总开关 ----------
if (UseToonShading < 0.5)
{
    ResultColor *= LightAtten;
    return ResultColor;
}

// ---------- 法线贴图（切线空间凹凸细节，保留双守卫） ----------
float2 RawXY     = Texture2DSample(NormalMapTex, NormalMapTexSampler, UV).rg * 2.0 - 1.0;
float TangentLen = length(WorldTangent);

float3 BumpNormal;
if (TangentLen < 1e-4 || dot(RawXY, RawXY) > 1.0)
{
    BumpNormal = N;
}
else
{
    float3 T = WorldTangent / TangentLen;
    T = normalize(T - N * dot(N, T));
    float3 B = cross(N, T);
    float2 NormalXY = RawXY * NormalMapIntensity;
    float NormalZ   = sqrt(saturate(1.0 - dot(NormalXY, NormalXY)));
    BumpNormal = normalize(NormalXY.x * T + NormalXY.y * B + NormalZ * N);
}

// ---------- HM 贴图（R=高光蒙版，G=AO，整合自示例材质） ----------
float HM_HighLightMask = 1.0;
float HM_AO = 1.0;
if (UseHM > 0.5)
{
    float3 HM = Texture2DSample(HMTexture, HMTextureSampler, UV).rgb;
    HM_HighLightMask = HM.r;   // 高光蒙版（控制 Matcap 高光范围）
    HM_AO = HM.g;              // AO（环境光遮蔽）
}

// ---------- Toon 阴影 ----------
float ShadowMask;
float3 FinalToon;

// HSV 统一调色（Ramp 与色带两种方式共用）
float HueRad     = radians(ShadowHueShift);
float HueCos     = cos(HueRad);
float HueSin     = sin(HueRad);
float HueOneThird = (1.0 - HueCos) / 3.0;
float HueRoot    = sqrt(1.0 / 3.0) * HueSin;

float3x3 ShadowHueMatrix = float3x3(
    HueCos + HueOneThird,  HueOneThird - HueRoot, HueOneThird + HueRoot,
    HueOneThird + HueRoot, HueCos + HueOneThird,  HueOneThird - HueRoot,
    HueOneThird - HueRoot, HueOneThird + HueRoot, HueCos + HueOneThird
);

float3 ShadowColorHue  = mul(ShadowHueMatrix, ShadowColor);
float3 Shadow2ColorHue = mul(ShadowHueMatrix, Shadow2Color);
float3 Shadow3ColorHue = mul(ShadowHueMatrix, Shadow3Color);

float ShadowColorLum  = dot(ShadowColorHue,  float3(0.2126, 0.7152, 0.0722));
float Shadow2ColorLum = dot(Shadow2ColorHue, float3(0.2126, 0.7152, 0.0722));
float Shadow3ColorLum = dot(Shadow3ColorHue, float3(0.2126, 0.7152, 0.0722));

float3 ShadowColorAdj  = lerp(ShadowColorLum.xxx,  ShadowColorHue,  ShadowSaturation) * ShadowBrightness;
float3 Shadow2ColorAdj = lerp(Shadow2ColorLum.xxx, Shadow2ColorHue, ShadowSaturation) * ShadowBrightness;
float3 Shadow3ColorAdj = lerp(Shadow3ColorLum.xxx, Shadow3ColorHue, ShadowSaturation) * ShadowBrightness;

if (UseCurve > 0.5)
{
    // ---- 曲线映射（采样曲线图集，曲线可实时调整）----
    // rampU = saturate(NdotL / ShadowSmooth - ShadowLocation)
    // ShadowSmooth 越大过渡越平滑；ShadowLocation 越大阴影越多
    float rampU = saturate(NdotL / max(0.001, ShadowSmooth) - ShadowLocation);
    float3 RampLit = Texture2DSample(CurveAtlasTexture, CurveAtlasTextureSampler, float2(rampU, 0.5)).rgb;

    // 阴影色作为暗部 tint：rampU 低（暗）时偏向 ShadowColorAdj，高（亮）时保持 RampLit
    FinalToon = lerp(ShadowColorAdj, RampLit, saturate(rampU * 2.0));

    // 阴影遮罩：rampU 直接作为明暗，供后续高光/Rim/AO 遮蔽
    ShadowMask = saturate(rampU);
}
else if (UseRampTex > 0.5)
{
    // ---- Ramp 贴图映射（回退）----
    float rampU = saturate(NdotL / max(0.001, ShadowSmooth) - ShadowLocation);
    float3 RampLit = (UseToonTexture > 0.5)
        ? Texture2DSample(ToonTexture, ToonTextureSampler, float2(rampU, 0.5)).rgb
        : LitColor;

    FinalToon = lerp(ShadowColorAdj, RampLit, saturate(rampU * 2.0));
    ShadowMask = saturate(rampU);
}
else
{
    // ---- 三层色带（SingleFunc 回退方式）----
    float EdgeHalfWidth = lerp(0.05, 0.002, saturate(ShadowSharpness));

    float T1 = ShadowThreshold;
    float T3 = max(T1 + 0.05, ShadowEnd);
    float BandTotal   = T3 - T1;
    float Shadow2Width = saturate(MidSplit) * BandTotal;
    float Shadow3Width = (1.0 - saturate(MidSplit)) * BandTotal;
    float T2 = T1 + Shadow2Width;

    float Layer1Mask = smoothstep(T1 - EdgeHalfWidth, T1 + EdgeHalfWidth, LightAtten);
    float Layer2Mask = smoothstep(T2 - EdgeHalfWidth, T2 + EdgeHalfWidth, LightAtten);
    float Layer3Mask = smoothstep(T3 - EdgeHalfWidth, T3 + EdgeHalfWidth, LightAtten);

    ShadowMask = Layer1Mask;

    float3 ToonSample = (UseToonTexture > 0.5)
        ? Texture2DSample(ToonTexture, ToonTextureSampler, float2(LightAtten, 0.5)).rgb
        : LitColor;

    float BandGuard  = EdgeHalfWidth * 2.0 + 0.001;
    float Band3Fade  = smoothstep(0.0, BandGuard, Shadow3Width);
    float Band2Fade  = smoothstep(0.0, BandGuard, Shadow2Width);

    FinalToon = ToonSample;
    FinalToon = lerp(FinalToon, lerp(Shadow3ColorAdj, FinalToon, Layer3Mask), Band3Fade);
    FinalToon = lerp(FinalToon, lerp(Shadow2ColorAdj, FinalToon, Layer2Mask), Band2Fade);
    FinalToon = lerp(ShadowColorAdj, FinalToon, Layer1Mask);
}

// ---------- AO 遮蔽（整合自示例材质） ----------
if (UseAO > 0.5)
{
    float AO = saturate(pow(HM_AO, max(0.001, AO_Power_ShadowMask)));
    ShadowMask = lerp(ShadowMask, ShadowMask * AO, saturate(AO_Shadow_Strengh));
}

ResultColor *= saturate(FinalToon);

// ---------- Rim Light ----------
float NdotV   = abs(dot(N, V));
float Fresnel = 1.0 - NdotV;

float RimThreshold = 1.0 - saturate(RimWidth);
float RimEdgeHalfWidth = lerp(0.002, 0.3, saturate(RimGradient));

float RimMask = smoothstep(RimThreshold - RimEdgeHalfWidth, RimThreshold + RimEdgeHalfWidth, Fresnel);

float RimLightMask = saturate(NdotL);
float Rim = RimMask * RimLightMask * ShadowMask;
ResultColor += RimColor * Rim;

// ---------- 双 Matcap 球面贴图（整合自示例材质） ----------
float3 CamDir   = normalize(CameraVector);

float3 RefUpA   = float3(0.0, 0.0, 1.0);
float3 RefUpB   = float3(0.0, 1.0, 0.0);

float AlignA    = abs(dot(CamDir, RefUpA));
float BlendFactor = smoothstep(0.85, 0.99, AlignA);

float3 RightA   = normalize(cross(RefUpA, CamDir));
float3 RightB   = normalize(cross(RefUpB, CamDir));

float3 CamRight = normalize(lerp(RightA, RightB, BlendFactor));
float3 CamUp    = normalize(cross(CamDir, CamRight));

float2 MatcapUV;
MatcapUV.x = dot(BumpNormal, CamRight) * 0.5 + 0.5;
MatcapUV.y = dot(BumpNormal, CamUp)    * 0.5 + 0.5;

// Matcap UV 缩放偏移（示例材质的 MatcaoScale_Offset）
MatcapUV = MatcapUV * MatcapScale + MatcapOffset;

// 高光 Matcap（× HM.R 高光蒙版）
float3 MatcapSample = Texture2DSample(MatcapTexture, MatcapTextureSampler, MatcapUV).rgb;

// 粗糙 Matcap（× RoughColor 混合色）
float3 RoughMatcapSample = Texture2DSample(RoughMatcapTexture, RoughMatcapTextureSampler, MatcapUV).rgb;
ResultColor += RoughMatcapSample * RoughMatcapColor * RoughColor * ShadowMask;

// ---------- 各向异性高光（配件增强版，无需新增参数或贴图） ----------
// Kajiya-Kay 各向异性高光：用切线 T 代替法线 N 参与计算
// H 越垂直于发丝（TdotH 越接近 0）越亮，高光沿发流方向铺开成带状
//
// 参数复用：
//   MatcapScale → 各向异性锐利度（值越大光带越窄越锐利）
//     默认 1.0 = 普通 Matcap 效果
//     2.0~4.0 = 各向异性拉长光带（丝袜/皮革/布料）
//   MatcapColor → 各向异性强度（颜色越亮强度越高）
//
// 使用方式：为不同配件创建独立材质实例
//   金属配件材质实例：MatcapScale=1.0（普通高光）
//   丝袜材质实例：MatcapScale=3.0（各向异性光带）
//   皮革材质实例：MatcapScale=2.0（中等各向异性）
float3 H = normalize(V + L);
float AnisoShape = 1.0;

if (TangentLen > 1e-4)
{
    // 发丝方向 = 模型切线
    float3 HairT = WorldTangent / TangentLen;
    float  TdotH = dot(HairT, H);
    float  SinTH = sqrt(saturate(1.0 - TdotH * TdotH));  // H 与发丝夹角的正弦

    // 各向异性形状：用 MatcapScale 作为锐利度控制
    // MatcapScale=1.0 时 pow(SinTH, 16) ≈ 普通高光
    // MatcapScale 越大，指数越大，光带越窄越锐利
    AnisoShape = pow(SinTH, max(1.0, MatcapScale * 16.0));
}

// 高光 Matcap（× HM.R 高光蒙版 × 各向异性形状）
// MatcapScale=1.0 时 AnisoShape≈1，效果接近普通 Matcap
// MatcapScale>1.0 时 AnisoShape<1，产生各向异性拉长效果
ResultColor += MatcapSample * MatcapColor * HM_HighLightMask * ShadowMask * AnisoShape;

// ---------- SSS 次表面散射（整合自示例材质） ----------
if (UseSSS > 0.5)
{
    float3 SSS = Texture2DSample(SSSTex, SSSTexSampler, UV).rgb;
    ResultColor += SSS * SSSColor;
}

// ---------- 曝光矫正 ----------
ResultColor *= ExposureScale;

return ResultColor;
