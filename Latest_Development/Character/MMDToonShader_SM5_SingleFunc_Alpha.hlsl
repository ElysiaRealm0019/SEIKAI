// MMD Toon Shader - UE5 Custom Node 直接粘贴版本 (Alpha 支持版)
// 适用于 Translucent 或 Masked 材质模式
// R G B 输出连接至 Emissive Color 引脚
// A 输出连接至 Opacity 或 Opacity Mask 引脚
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
// TintIntensity      Float1            色调混合强度  默认 0.0（0=不改变, 1=完全应用色调）
// TintMode           Float1            色调模式  默认 0.0（0=Overlay混合, 1=乘法, 2=色相偏移）
// ShadowThreshold    Float1            阴影位置  默认 0.5（0~1，越大阴影越多）
// ShadowSharpness    Float1            阴影锋利度 默认 0.8（0~1，越大边缘越硬）
// ShadowColor        Float3            阴影颜色  默认（0.2, 0.2, 0.4）
// RimIntensity       Float1            Rim Light 强度  默认 1.0
// RimPower           Float1            Rim Light 范围  默认 3.0
// RimColor           Float3            Rim Light 颜色  默认（1.0, 1.0, 1.0）
// SpecularStrength   Float1            高光整体强度  默认 0.5（0=完全关闭, 1=全强度）
// SpecularThreshold  Float1            高光可见阈值  默认 0.3（NdotL 低于此值的区域完全无高光）
// SpecularColor      Float3            高光颜色  默认（1.0, 1.0, 1.0）白色
// MatcapInfluence    Float1            Matcap 强度  默认 1.0
// ----------------------------------------------------------------
// Output Type: CMOT Float4  →  返回值包含 RGB 颜色和 Alpha 透明度
// ================================================================

// ---------- Base Colour ----------
float4 BaseSample = Texture2DSample(BaseColorTex, BaseColorTexSampler, UV);
float3 ResultColor = BaseSample.rgb;
float FinalAlpha = BaseSample.a;

// ---------- Base Color 色调（多模式） ----------
// TintIntensity = 0：不改变颜色；= 1：完全应用色调效果
// TintMode = 0：Overlay 混合（保留明暗细节，同时偏移色调）
// TintMode = 1：乘法混合（传统方式，可能丢失暗部细节）
// TintMode = 2：Soft-Light 混合（柔和改色，最适合微调）
// BaseTint 默认为白色（1,1,1）时不产生任何色偏
float3 TintedColor;
float TintModeVal = round(clamp(TintMode, 0.0, 2.0));

if (TintModeVal < 0.5)
{
    // Mode 0: Overlay 混合 — 暗部加深、亮部提亮，色调自然融合
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
    // Mode 1: 乘法混合 — 简单色调叠加
    TintedColor = ResultColor * BaseTint;
}
else
{
    // Mode 2: Soft-Light 混合 — 最柔和，适合微调色温
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

// ---------- Rim Light ----------
float NdotV       = abs(dot(N, V));
float Fresnel     = 1.0 - NdotV;
float LightFresnel = dot(L, V) * 0.5 + 0.5;
float RimFresnel  = pow(max(0.0001, Fresnel), RimPower) * RimIntensity;
float Rim         = RimFresnel * (0.6 + LightFresnel * 0.4);
ResultColor += RimColor * Rim;

// ---------- 高光贴图（Blinn-Phong，anti-plastic） ----------
// 重写高光计算，消除塑料感：
// 1. SpecularThreshold：NdotL 低于阈值的区域完全无高光（硬截断）
// 2. 二次方 NdotL 衰减：让高光只集中在强受光面，侧面/低角度不出现
// 3. ShadowMask 遮蔽：阴影过渡区不产生高光
// 4. SpecularStrength：全局强度乘数（默认 0.5，比旧版 1.0 更保守）
float4 SpecInfo    = Texture2DSample(SpecularTexture, SpecularTextureSampler, UV);
float SpecPower    = max(1.0, SpecInfo.r * 64.0);
float SpecIntensity = SpecInfo.g;
float3 H           = normalize(L + V);
float NdotH        = saturate(dot(N, H));

// 硬截断：NdotL < SpecularThreshold → 完全无高光
float SpecLightMask = smoothstep(SpecularThreshold, SpecularThreshold + 0.05, saturate(NdotL));
// 二次方衰减：让高光集中在正面受光区
float SpecFalloff   = SpecLightMask * SpecLightMask;

float Spec = pow(NdotH, SpecPower) * SpecIntensity
           * ShadowMask * SpecFalloff;
ResultColor += Spec * SpecularStrength * SpecularColor;

// ---------- Matcap 球面贴图 ----------
// 使用视角空间法线 XY 作为 UV，随视角变化自动更新高光位置
// UE5 世界空间 Z 轴朝上
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

// Unlit 输出：加法项保留 HDR，可驱动 Bloom 后处理
// 将 Alpha 通道一起打包为 float4 输出
return float4(ResultColor, FinalAlpha);
