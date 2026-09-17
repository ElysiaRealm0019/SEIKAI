// MMD Toon Shader - UE5 Custom Node 完整整合版（Alpha 支持版）
// ================================================================
// 本文件是 MMDToonShader_SM5_SingleFunc_Full.hlsl 的 Alpha 支持版本：
// 完整整合了示例材质 M_Redner_Master1 的功能，同时支持 Alpha 透明度。
//
// 适用场景：需要透明度的部位（如头发、薄纱、半透明装饰等）
// 材质设置：Blend Mode = Translucent 或 Masked
//
// 输出类型：CMOT Float4（RGB + Alpha）
//   - RGB：完整的 Toon 渲染颜色
//   - Alpha：从 Alpha 贴图采样的透明度
//
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
// CurveAtlasTexture  Texture2D         TextureObjectParameter（曲线图集 CurveLinearColorAtlas）
// ToonTexture        Texture2D         TextureObjectParameter（Ramp 渐变贴图）
// MatcapTexture      Texture2D         TextureObjectParameter（高光 Matcap 球面贴图）
// RoughMatcapTexture Texture2D         TextureObjectParameter（粗糙 Matcap 球面贴图）
// NormalMapTex       Texture2D         TextureObjectParameter（切线空间法线贴图，BC5）
// HMTexture          Texture2D         TextureObjectParameter（HM 贴图：R=高光蒙版，G=AO）
// SSSTex             Texture2D         TextureObjectParameter（次表面散射贴图）
// AlphaTex           Texture2D         TextureObjectParameter（透明度贴图，Alpha 通道）
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
// ExposureScale      Float1            整体曝光矫正  默认 1.0
// HairMapMode        Float1            HM 解读模式  默认 0.0（0=高光掩码/AO；1=发丝高光图调制）
// MatcapSharpen      Float1            Matcap 高光锐化/收窄  默认 0.0（0=与旧版逐字一致）
// RimEnvMode         Float1            环境边缘光模式  默认 0.0（0=仅受光侧；1=全轮廓环境边光）
// AlphaScale         Float1            透明度校准  默认 1.0（不同槽位可赋予不同透明度，>1 更透明 <1 更不透明）
// AlphaChannelMode   Float1            Alpha 通道来源  默认 0.0（0=AlphaTex.R；1=BaseColor.A；2=BaseColor 亮度；3=AlphaTex.A）
// AlphaCutoff        Float1            Alpha 裁剪阈值  默认 0.5（Masked 模式下生效）
// ----------------------------------------------------------------
// Output Type: CMOT Float4  →  Emissive Color（RGB）+ Opacity/Opacity Mask（A）
// ================================================================

// ---------- Alpha 透明度处理 ----------
// AlphaChannelMode = 0：旧行为，从 AlphaTex 的 R 通道取样（薄纱等独立灰度透明贴图）
// AlphaChannelMode = 1：直接取 BaseColor 贴图的 A 通道（眼高光/眼白/星点等自带 A 的贴图）
// AlphaChannelMode = 2：取 BaseColor 贴图 RGB 的亮度（_Hi 类高光图，导入后 A 通道丢失时用）
// AlphaChannelMode = 3：取 AlphaTex 的 A 通道
float Alpha;
if (AlphaChannelMode > 2.5)
{
    Alpha = Texture2DSample(AlphaTex, AlphaTexSampler, UV).a;
}
else if (AlphaChannelMode > 1.5)
{
    float3 AlphaRGB = Texture2DSample(BaseColorTex, BaseColorTexSampler, UV).rgb;
    Alpha = dot(AlphaRGB, float3(0.299, 0.587, 0.114));
}
else if (AlphaChannelMode > 0.5)
{
    Alpha = Texture2DSample(BaseColorTex, BaseColorTexSampler, UV).a;
}
else
{
    Alpha = Texture2DSample(AlphaTex, AlphaTexSampler, UV).r;
}
Alpha = saturate(Alpha * AlphaScale);  // 透明度校准（不同槽位可赋予不同透明度）

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
    return float4(ResultColor, Alpha);
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

// ---------- HM 贴图 / HairMap 适配模式 ----------
// HairMapMode = 0：HM 按 R=高光蒙版 / G=AO 解读（通用）
// HairMapMode = 1：HM 作为 UV 空间发丝高光图解读
//   适配 T_..._Hair_HM / Bangs_HM 这类彩色发丝图（通道不是简单掩码），
//   取 RGB 最大值作为发丝高光强度，在 UV 上形成沿发丝流的高光。
float HM_HighLightMask = 1.0;
float HM_AO = 1.0;
float HairMapMask = 0.0;
float HairMapW = saturate(HairMapMode);
if (UseHM > 0.5)
{
    float3 HM = Texture2DSample(HMTexture, HMTextureSampler, UV).rgb;
    // 旧逻辑保持不变：HM.r=高光掩码、HM.g=AO
    HM_HighLightMask = HM.r;
    HM_AO = HM.g;
    // 模式1：把 HM 当作"发丝高光调制"因子（乘法调制已有 Matcap，不新增独立亮色）
    float HM_Lum = dot(HM, float3(0.299, 0.587, 0.114));
    float HM_Strand = smoothstep(0.40, 0.95, HM_Lum);
    HairMapMask = HM_Strand * HairMapW;
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
    float rampU = saturate(NdotL / max(0.001, ShadowSmooth) - ShadowLocation);
    float3 RampLit = Texture2DSample(CurveAtlasTexture, CurveAtlasTextureSampler, float2(rampU, 0.5)).rgb;

    FinalToon = lerp(ShadowColorAdj, RampLit, saturate(rampU * 2.0));
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

// ---------- 高光通用闸门（与阴影柔度解耦） ----------
float LightMask = saturate(NdotL);
float SpecGate = smoothstep(0.0, 0.35, LightMask);

// ---------- Rim Light ----------
float NdotV   = abs(dot(N, V));
float Fresnel = 1.0 - NdotV;

float RimThreshold = 1.0 - saturate(RimWidth);
float RimEdgeHalfWidth = lerp(0.002, 0.3, saturate(RimGradient));

float RimMask = smoothstep(RimThreshold - RimEdgeHalfWidth, RimThreshold + RimEdgeHalfWidth, Fresnel);

// RimEnvMode=0：旧行为（仅受光侧，随 LightMask）；=1：环境天穹边缘光（全轮廓、背光侧更亮）
float RimKey = RimMask * LightMask;
float RimEnv = RimMask * (0.35 + 0.65 * (1.0 - LightMask));
float Rim = lerp(RimKey, RimEnv, saturate(RimEnvMode));
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

// Matcap UV 缩放偏移
MatcapUV = MatcapUV * MatcapScale + MatcapOffset;

// 高光 Matcap（× HM.R 高光蒙版）
float3 MatcapSample = Texture2DSample(MatcapTexture, MatcapTextureSampler, MatcapUV).rgb;
// 高光锐化/收窄（MatcapSharpen=0 时与旧版逐字一致：压掉灰色光晕、只留亮核并提对比）
float MSharp = saturate(MatcapSharpen);
float3 MatcapAdj = saturate((MatcapSample - 0.05 * MSharp) / max(0.001, 1.0 - 0.05 * MSharp));
MatcapAdj = pow(MatcapAdj, 1.0 + 3.0 * MSharp);
ResultColor += MatcapAdj * MatcapColor * HM_HighLightMask * SpecGate * (1.0 + HairMapMask * 1.5);

// 粗糙 Matcap（× RoughColor 混合色）
float3 RoughMatcapSample = Texture2DSample(RoughMatcapTexture, RoughMatcapTextureSampler, MatcapUV).rgb;
ResultColor += RoughMatcapSample * RoughMatcapColor * RoughColor * SpecGate;

// ---------- SSS 次表面散射（整合自示例材质） ----------
if (UseSSS > 0.5)
{
    float3 SSS = Texture2DSample(SSSTex, SSSTexSampler, UV).rgb;
    ResultColor += SSS * SSSColor;
}

// ---------- 曝光矫正 ----------
ResultColor *= ExposureScale;

// ---------- 输出：RGB + Alpha ----------
return float4(ResultColor, Alpha);
