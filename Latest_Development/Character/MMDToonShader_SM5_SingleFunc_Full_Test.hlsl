// MMD Toon Shader - Full Test（工作目录迭代版）
// ================================================================
// 以 MMDToonShader_SM5_SingleFunc_Full.hlsl 为基础，用于对照参考图迭代。
// 主要改动（v2）：
//   - 高光门控与阴影柔度解耦：原 ShaderMask 同时控制阴影柔度与 Rim/Matcap，
//     导致"阴影一柔化、头发高光就消失"。现改为：
//         LightMask = saturate(NdotL)
//         SpecGate  = 0.3 + 0.7 * LightMask
//     Rim / 双 Matcap 使用 LightMask / SpecGate，不再受 ShadowSmooth 影响。
// 其余逻辑与 Full 版一致，输入/输出/参数完全兼容。
// ================================================================

// ---------- Base Colour ----------
float3 ResultColor = Texture2DSample(BaseColorTex, BaseColorTexSampler, UV).rgb;

// ---------- Base Color 色调（多模式） ----------
float3 TintedColor;
float TintModeVal = round(clamp(TintMode, 0.0, 2.0));

if (TintModeVal < 0.5)
{
    float3 overlay;
    overlay.r = (ResultColor.r < 0.5) ? (2.0 * ResultColor.r * BaseTint.r) : (1.0 - 2.0 * (1.0 - ResultColor.r) * (1.0 - BaseTint.r));
    overlay.g = (ResultColor.g < 0.5) ? (2.0 * ResultColor.g * BaseTint.g) : (1.0 - 2.0 * (1.0 - ResultColor.g) * (1.0 - BaseTint.g));
    overlay.b = (ResultColor.b < 0.5) ? (2.0 * ResultColor.b * BaseTint.b) : (1.0 - 2.0 * (1.0 - ResultColor.b) * (1.0 - BaseTint.b));
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
float3 V = normalize(-CameraVector);
float3 L = normalize(LightDirection);

// ---------- 基础光照衰减 ----------
float NdotL = dot(N, L);
float LightAtten = NdotL * 0.5 + 0.5;

// ---------- Toon 风格化总开关 ----------
if (UseToonShading < 0.5)
{
    ResultColor *= LightAtten;
    return ResultColor;
}

// ---------- 法线贴图 ----------
float2 RawXY = Texture2DSample(NormalMapTex, NormalMapTexSampler, UV).rg * 2.0 - 1.0;
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
    float NormalZ = sqrt(saturate(1.0 - dot(NormalXY, NormalXY)));
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
    // （该掩码用于限制 Matcap 覆盖范围、避免背面高光生硬截断）
    HM_HighLightMask = HM.r;
    HM_AO = HM.g;
    // 模式1：把 HM 当作"发丝高光调制"因子。
    // Hair_HM 是彩色发丝流向图，绝不能直接相加（否则绿蓝区域会变成大面积白条），
    // 因此这里只生成 0..1 的发丝因子，用于"调制已有 Matcap 高光"，不新增独立亮色。
    float HM_Lum = dot(HM, float3(0.299, 0.587, 0.114));
    float HM_Strand = smoothstep(0.40, 0.95, HM_Lum);
    HairMapMask = HM_Strand * HairMapW;
}

// ---------- Toon 阴影 ----------
float ShadowMask;
float3 FinalToon;

float HueRad = radians(ShadowHueShift);
float HueCos = cos(HueRad);
float HueSin = sin(HueRad);
float HueOneThird = (1.0 - HueCos) / 3.0;
float HueRoot = sqrt(1.0 / 3.0) * HueSin;

float3x3 ShadowHueMatrix = float3x3(
    HueCos + HueOneThird, HueOneThird - HueRoot, HueOneThird + HueRoot,
    HueOneThird + HueRoot, HueCos + HueOneThird, HueOneThird - HueRoot,
    HueOneThird - HueRoot, HueOneThird + HueRoot, HueCos + HueOneThird
);

float3 ShadowColorHue = mul(ShadowHueMatrix, ShadowColor);
float3 Shadow2ColorHue = mul(ShadowHueMatrix, Shadow2Color);
float3 Shadow3ColorHue = mul(ShadowHueMatrix, Shadow3Color);

float ShadowColorLum = dot(ShadowColorHue, float3(0.2126, 0.7152, 0.0722));
float Shadow2ColorLum = dot(Shadow2ColorHue, float3(0.2126, 0.7152, 0.0722));
float Shadow3ColorLum = dot(Shadow3ColorHue, float3(0.2126, 0.7152, 0.0722));

float3 ShadowColorAdj = lerp(ShadowColorLum.xxx, ShadowColorHue, ShadowSaturation) * ShadowBrightness;
float3 Shadow2ColorAdj = lerp(Shadow2ColorLum.xxx, Shadow2ColorHue, ShadowSaturation) * ShadowBrightness;
float3 Shadow3ColorAdj = lerp(Shadow3ColorLum.xxx, Shadow3ColorHue, ShadowSaturation) * ShadowBrightness;

if (UseCurve > 0.5)
{
    float rampU = saturate(NdotL / max(0.001, ShadowSmooth) - ShadowLocation);
    float3 RampLit = Texture2DSample(CurveAtlasTexture, CurveAtlasTextureSampler, float2(rampU, 0.5)).rgb;
    FinalToon = lerp(ShadowColorAdj, RampLit, saturate(rampU * 2.0));
    ShadowMask = saturate(rampU);
}
else if (UseRampTex > 0.5)
{
    float rampU = saturate(NdotL / max(0.001, ShadowSmooth) - ShadowLocation);
    float3 RampLit = (UseToonTexture > 0.5) ? Texture2DSample(ToonTexture, ToonTextureSampler, float2(rampU, 0.5)).rgb : LitColor;
    FinalToon = lerp(ShadowColorAdj, RampLit, saturate(rampU * 2.0));
    ShadowMask = saturate(rampU);
}
else
{
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
    ShadowMask = Layer1Mask;
    float3 ToonSample = (UseToonTexture > 0.5) ? Texture2DSample(ToonTexture, ToonTextureSampler, float2(LightAtten, 0.5)).rgb : LitColor;
    float BandGuard = EdgeHalfWidth * 2.0 + 0.001;
    float Band3Fade = smoothstep(0.0, BandGuard, Shadow3Width);
    float Band2Fade = smoothstep(0.0, BandGuard, Shadow2Width);
    FinalToon = ToonSample;
    FinalToon = lerp(FinalToon, lerp(Shadow3ColorAdj, FinalToon, Layer3Mask), Band3Fade);
    FinalToon = lerp(FinalToon, lerp(Shadow2ColorAdj, FinalToon, Layer2Mask), Band2Fade);
    FinalToon = lerp(ShadowColorAdj, FinalToon, Layer1Mask);
}

// ---------- AO 遮蔽 ----------
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
float NdotV = abs(dot(N, V));
float Fresnel = 1.0 - NdotV;
float RimThreshold = 1.0 - saturate(RimWidth);
float RimEdgeHalfWidth = lerp(0.002, 0.3, saturate(RimGradient));
float RimMask = smoothstep(RimThreshold - RimEdgeHalfWidth, RimThreshold + RimEdgeHalfWidth, Fresnel);
// RimEnvMode=0：旧行为（仅受光侧，随 LightMask）；=1：环境天穹边缘光（全轮廓、背光侧更亮）
float RimKey = RimMask * LightMask;
float RimEnv = RimMask * (0.35 + 0.65 * (1.0 - LightMask));
float Rim = lerp(RimKey, RimEnv, saturate(RimEnvMode));
ResultColor += RimColor * Rim;

// ---------- 双 Matcap ----------
float3 CamDir = normalize(CameraVector);
float3 RefUpA = float3(0.0, 0.0, 1.0);
float3 RefUpB = float3(0.0, 1.0, 0.0);
float AlignA = abs(dot(CamDir, RefUpA));
float BlendFactor = smoothstep(0.85, 0.99, AlignA);
float3 RightA = normalize(cross(RefUpA, CamDir));
float3 RightB = normalize(cross(RefUpB, CamDir));
float3 CamRight = normalize(lerp(RightA, RightB, BlendFactor));
float3 CamUp = normalize(cross(CamDir, CamRight));
float2 MatcapUV;
MatcapUV.x = dot(BumpNormal, CamRight) * 0.5 + 0.5;
MatcapUV.y = dot(BumpNormal, CamUp) * 0.5 + 0.5;
MatcapUV = MatcapUV * MatcapScale + MatcapOffset;
float3 MatcapSample = Texture2DSample(MatcapTexture, MatcapTextureSampler, MatcapUV).rgb;
// 高光锐化/收窄（MatcapSharpen=0 时与旧版逐字一致：压掉灰色光晕、只留亮核并提对比）
float MSharp = saturate(MatcapSharpen);
float3 MatcapAdj = saturate((MatcapSample - 0.05 * MSharp) / max(0.001, 1.0 - 0.05 * MSharp));
MatcapAdj = pow(MatcapAdj, 1.0 + 3.0 * MSharp);
ResultColor += MatcapAdj * MatcapColor * HM_HighLightMask * SpecGate * (1.0 + HairMapMask * 1.5);
float3 RoughMatcapSample = Texture2DSample(RoughMatcapTexture, RoughMatcapTextureSampler, MatcapUV).rgb;
ResultColor += RoughMatcapSample * RoughMatcapColor * RoughColor * SpecGate;

// ---------- UV 空间发丝高光 ----------
// 已在 Matcap 行内通过 HairMapMask 调制（乘法），此处不再单独相加，避免白条。

// ---------- SSS 次表面散射 ----------
if (UseSSS > 0.5)
{
    float3 SSS = Texture2DSample(SSSTex, SSSTexSampler, UV).rgb;
    ResultColor += SSS * SSSColor;
}

// ---------- 曝光矫正 ----------
ResultColor *= ExposureScale;

return ResultColor;
