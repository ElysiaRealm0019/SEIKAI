// MMD Toon Shader - UE5 Custom Node (头发边缘半透明专属版)
// 适用于 Translucent 材质模式
// R G B 输出连接至 Emissive Color 引脚
// A 输出连接至 Opacity 引脚
//
// ================================================================
// 贴图传入方式：使用 TextureObjectParameter 节点
// ================================================================
// TextureObjectParameter 将贴图对象传入 Custom 节点，UV 在 Shader 内计算。
// 不可使用 TextureSampleParameter2D（其输出为颜色值，无法自定义 UV）。
//
// ================================================================
// UE5 Custom Node 输入配置 (Inputs 面板按顺序添加):
// ================================================================
// 名称               类型              连接来源
// ----------------------------------------------------------------
// UV                 Float2            TexCoord 节点
// WorldNormal        Float3            VertexNormalWS 节点
// CameraVector       Float3            CameraDirectionVector 节点
// LightDirection     Float3            从场景指向光源的方向（见 Documentation/MMDToonShader_SM5_SingleFunc_使用文档.md）
// BaseColorTex       Texture2D         TextureObjectParameter（Base Colour 贴图）
// ToonTexture        Texture2D         TextureObjectParameter（Toon 渐变贴图）
// SpecularTexture    Texture2D         TextureObjectParameter（高光贴图：R=高光范围, G=高光强度）
// MatcapTexture      Texture2D         TextureObjectParameter（Matcap 球面贴图）
// BaseTint           Float3            色调颜色  默认（1.0, 1.0, 1.0）无色偏
// TintIntensity      Float1            色调混合强度  默认 0.0
// TintMode           Float1            色调模式  默认 0.0
// ShadowThreshold    Float1            阴影位置  默认 0.5
// ShadowSharpness    Float1            阴影锋利度 默认 0.8
// ShadowColor        Float3            阴影颜色  默认（0.2, 0.2, 0.4）
// RimIntensity       Float1            Rim Light 强度  默认 1.0
// RimPower           Float1            Rim Light 范围  默认 3.0
// RimColor           Float3            Rim Light 颜色  默认（1.0, 1.0, 1.0）
// SpecularStrength   Float1            高光整体强度  默认 0.5
// SpecularThreshold  Float1            高光可见阈值  默认 0.3
// SpecularColor      Float3            高光颜色  默认（1.0, 1.0, 1.0）
// MatcapInfluence    Float1            Matcap 强度  默认 1.0
// ---- 新增头发边缘半透明控制参数 ------------------------------------
// HairEdgeWidth      Float1            边缘半透明宽度 默认 0.2（0~1，越大透明范围越宽）
// HairEdgeOpacity    Float1            边缘最外侧透明度 默认 0.0（0=完全透明, 1=完全不透明）
// ----------------------------------------------------------------
// Output Type: CMOT Float4  →  返回值包含 RGB 颜色和 Alpha 透明度
// ================================================================

// ---------- Base Colour ----------
float4 BaseSample = Texture2DSample(BaseColorTex, BaseColorTexSampler, UV);
float3 ResultColor = BaseSample.rgb;
float BaseAlpha = BaseSample.a;

// ---------- Base Color 色调（多模式） ----------
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
    softlight = (BaseTint <= 0.5)
        ? ResultColor - (1.0 - 2.0 * BaseTint) * ResultColor * (1.0 - ResultColor)
        : ResultColor + (2.0 * BaseTint - 1.0) * (sqrt(ResultColor) - ResultColor);
    TintedColor = softlight;
}

ResultColor = lerp(ResultColor, TintedColor, TintIntensity);

// ---------- 方向向量 ----------
float3 N = normalize(WorldNormal);
float3 V = normalize(-CameraVector);   // pixel → camera
float3 L = normalize(LightDirection);  // pixel → light

// ---------- 基础光照衰减 ----------
float NdotL     = dot(N, L);
float LightAtten = NdotL * 0.5 + 0.5;  // [-1,1] → [0,1]

// ---------- Toon 阴影 ----------
float ShadowMask = smoothstep(ShadowThreshold - 0.01, ShadowThreshold + 0.01, LightAtten);
ShadowMask = pow(max(0.0001, ShadowMask), lerp(1.0, 20.0, ShadowSharpness));

float3 ToonSample = Texture2DSample(ToonTexture, ToonTextureSampler, float2(LightAtten, 0.5)).rgb;
float3 FinalToon  = lerp(ShadowColor, ToonSample, ShadowMask);
ResultColor *= saturate(FinalToon);

// ---------- Rim Light & Fresnel ----------
float NdotV       = abs(dot(N, V));
float Fresnel     = 1.0 - NdotV;
float LightFresnel = dot(L, V) * 0.5 + 0.5;
float RimFresnel  = pow(max(0.0001, Fresnel), RimPower) * RimIntensity;
float Rim         = RimFresnel * (0.6 + LightFresnel * 0.4);
ResultColor += RimColor * Rim;

// ---------- 高光贴图（Blinn-Phong，anti-plastic） ----------
float4 SpecInfo    = Texture2DSample(SpecularTexture, SpecularTextureSampler, UV);
float SpecPower    = max(1.0, SpecInfo.r * 64.0);
float SpecIntensity = SpecInfo.g;
float3 H           = normalize(L + V);
float NdotH        = saturate(dot(N, H));

float SpecLightMask = smoothstep(SpecularThreshold, SpecularThreshold + 0.05, saturate(NdotL));
float SpecFalloff   = SpecLightMask * SpecLightMask;

float Spec = pow(NdotH, SpecPower) * SpecIntensity
           * ShadowMask * SpecFalloff;
ResultColor += Spec * SpecularStrength * SpecularColor;

// ---------- Matcap 球面贴图 ----------
float3 CamDir   = normalize(CameraVector);
float3 WorldUp  = float3(0.0, 0.0, 1.0);
float3 CamRight = abs(dot(CamDir, WorldUp)) < 0.99
    ? normalize(cross(WorldUp, CamDir))
    : normalize(cross(float3(0.0, 1.0, 0.0), CamDir));
float3 CamUp    = normalize(cross(CamDir, CamRight));

float2 MatcapUV;
MatcapUV.x = dot(N, CamRight) * 0.5 + 0.5;
MatcapUV.y = dot(N, CamUp)    * 0.5 + 0.5;

float3 MatcapSample = Texture2DSample(MatcapTexture, MatcapTextureSampler, MatcapUV).rgb;
float Facing        = pow(max(0.0, saturate(dot(N, L))), 0.5);
float MatcapMask    = saturate(Facing + 0.2);
ResultColor += MatcapSample * MatcapMask * MatcapInfluence;

// ---------- 头发边缘半透明处理 ----------
// 使用 Fresnel 效应来检测边缘。
// 当 Fresnel 接近 1.0 时为最边缘。
// HairEdgeWidth 控制边缘过度范围，值为 0~1。0 时无边缘透明效果，1 时从视角中心就开始渐变。
float EdgeThreshold = 1.0 - saturate(HairEdgeWidth);
float HairEdgeMask = smoothstep(EdgeThreshold, 1.0, Fresnel);

// 最外侧的 Alpha 乘以 HairEdgeOpacity，中心部分的 Alpha 保持原样。
float FinalAlpha = lerp(BaseAlpha, BaseAlpha * saturate(HairEdgeOpacity), HairEdgeMask);

// Unlit 输出：包含 RGB 与计算好的 Alpha
return float4(ResultColor, FinalAlpha);
