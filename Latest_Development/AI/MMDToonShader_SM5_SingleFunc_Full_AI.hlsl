// MMD Toon Shader - UE5 Custom Node 完整整合版（配件增强版 · AI 驱动版）
// ================================================================
// 本文件是 MMDToonShader_SM5_SingleFunc_Full_Accessories.hlsl 的 AI 集成变体：
// 在配件增强版基础上，内嵌 MLP（2→24→3）按 LdotV / L_up 实时预测
// ShadowSmooth / ShadowLocation / ExposureScale。
// 其余贴图、光照、配件逻辑与配件增强版完全一致；UseAI 开关可随时切回手动模式。
//
// MLP 权重来源：Latest_Development/AI/AIControl/ai_mlp.hlsl（fit_mlp.py 生成）
// 预测语义：
//   ShadowSmooth   — 顶光/极端角自动柔化阴影过渡（>1 阴影扩散柔化，<1 收窄变陡）
//   ShadowLocation — 侧光微调阴影位置/深度，保持风格不漂
//   ExposureScale  — 背光自动提亮防死黑（背光 NdotL<0 时阴影参数救不了，只有曝光有效）
//
// 三个预测参数在「曲线阴影」（UseCurve=1 默认）与「Ramp 回退」（UseRampTex=1）
// 两条路径都生效，覆盖 Full 版 99% 使用场景。色带分支为过时方案，AI 不对其生效；
// Rim 为 NdotV/NdotL 的确定性几何函数，天生自适应，无需 AI 预测。
//
// 新增功能（相对 Full 版本）：
//   8. Kajiya-Kay 各向异性高光 —— 丝袜/皮革/布料等材质的拉长光带
//
// v2 同步（2026-09-12，来源 Character/MMDToonShader_SM5_SingleFunc_Full_Test.hlsl）：
//   9.  高光门控与阴影柔度解耦：LightMask = saturate(NdotL)、
//       SpecGate = smoothstep(0.0, 0.35, LightMask)，Rim / 双 Matcap 不再直连 ShadowMask。
//       （旧版 ShadowMask 同时控制阴影柔度与 Rim/Matcap，"阴影一柔化、头发高光就消失"）
//   10. HairMapMode   —— HM 贴图按 UV 空间发丝高光图解读（彩色发丝图不再被当掩码）
//   11. MatcapSharpen —— Matcap 高光锐化/收窄（0 时与旧版逐字一致）
//   12. RimEnvMode    —— 0=仅受光侧（旧行为），1=环境天穹全轮廓边缘光
//   新增输入引脚：HairMapMode / MatcapSharpen / RimEnvMode
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
// HairMapMode        Float1            HM 解读模式  默认 0.0（0=通用 R 高光/G AO，1=UV 空间发丝高光图）
// MatcapSharpen      Float1            Matcap 锐化  默认 0.0（0=与旧版逐字一致，越大亮核越窄越锐）
// RimEnvMode         Float1            Rim 模式  默认 0.0（0=仅受光侧，1=环境天穹全轮廓边缘光）
// UseAI              Float1            AI 自适应开关  默认 0.0（1=MLP 预测覆盖 ShadowSmooth/
//                                       ShadowLocation/ExposureScale，0=全部手动，与配件增强版行为一致）
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

// ---------- HM 贴图 / HairMap 适配模式（R=高光蒙版，G=AO，整合自示例材质） ----------
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

// ---------- AI 自适应参数推理（MLP: 3→256→3） ----------
// 权重由 fit_mlp.py 生成（ai_mlp.hlsl），特征为 (LdotV, L_up, L_right)：
//   LdotV   = dot(L, V_cam)  光源相对相机的朝向（>0 顺光，<0 逆光）
//   L_up    = L.z            光源高度（>0 顶光，<0 底光）
//   L_right = dot(L, Right)  光源在角色**左右**哪一侧（v6 新增）
// UseAI=1 时用预测值覆盖 3 个手动参数；UseAI=0 时全部走手动参数，与配件增强版完全一致。
// 三个预测参数在「曲线阴影」（UseCurve=1 默认）与「Ramp 回退」（UseRampTex=1）两条路径都生效。
// 色带分支为过时方案，AI 不对其生效；Rim 为确定性几何函数，无需 AI 预测。
//
// 为什么需要 L_right：相机固定正对角色正面时，V_cam ≈ 常量，LdotV 与 L_up 只能把
// 光向确定到一个**圆**（L 的切向分量大小可由 √(1-LdotV²-L_up²) 算出，但符号未知）。
// 于是「左前光」与「右前光」映射到同一组特征、取到同一组参数，而这两者的正确打光
// 本来就不同。加上 L_right 后特征与光向一一对应。
//
// ⚠ V_cam 必须取「每帧常量」（物体中心 → 相机），**不能**用上面第 171 行的逐像素 V：
//     · 逐像素 V 会让 AI 参数在屏幕上漂移（画面中心与画面边缘取到不同参数）；
//     · 逐像素 V 会让特征无法确定光向 —— 同一组特征对应差别很大的光照。
//   本式与 UE_MMDAnchorRecorder 的 RecordAnchor（CameraLocation - ActorLocation）、
//   collect_training_data.py 的 V_CAM / RIGHT 三处定义严格一致，改一处必须同改三处。
float3 V_cam = normalize(LWCToFloat(GetWorldCameraOrigin(Parameters))
                       - LWCToFloat(GetObjectWorldPosition(Parameters)));
float LdotV_AI = dot(L, V_cam);
float L_up_AI  = L.z;

// 角色右方 = cross(Up, V_cam)。相机正对角色正面时退化为常量；相机与 Up 平行
// （垂直俯视/仰视）时叉积为零向量，此时回退到 +X —— 与 Python 侧 RIGHT 的兜底一致，
// 否则 normalize(0) 会产生 NaN 并污染整条推理链。
float3 RgtRaw = cross(float3(0.0, 0.0, 1.0), V_cam);
float  RgtLen = length(RgtRaw);
float3 Rgt    = RgtLen > 1e-4 ? RgtRaw / RgtLen : float3(1.0, 0.0, 0.0);
float L_right_AI = dot(L, Rgt);

// ==== AUTO-MLP-BEGIN ====
float h_0 = max(0.0, -0.082134 * LdotV_AI -0.030013 * L_up_AI -0.167309 * L_right_AI +0.416502);
float h_1 = max(0.0, +0.578182 * LdotV_AI -0.138482 * L_up_AI +0.194324 * L_right_AI +0.186476);
float h_2 = max(0.0, +0.126318 * LdotV_AI -0.372500 * L_up_AI +0.191502 * L_right_AI -0.146802);
float h_3 = max(0.0, +0.201979 * LdotV_AI +0.179226 * L_up_AI -0.222436 * L_right_AI -0.140751);
float h_4 = max(0.0, -0.279699 * LdotV_AI -0.275967 * L_up_AI -0.424263 * L_right_AI +0.435678);
float h_5 = max(0.0, -0.190478 * LdotV_AI +0.387789 * L_up_AI -0.259900 * L_right_AI +0.224533);
float h_6 = max(0.0, -0.238867 * LdotV_AI +0.312166 * L_up_AI +0.156422 * L_right_AI +0.209010);
float h_7 = max(0.0, +0.455336 * LdotV_AI -0.346904 * L_up_AI -0.120165 * L_right_AI +0.203209);
float h_8 = max(0.0, -0.221373 * LdotV_AI -0.202395 * L_up_AI +0.119338 * L_right_AI -0.060785);
float h_9 = max(0.0, +0.094949 * LdotV_AI +0.154440 * L_up_AI +0.103050 * L_right_AI -0.292945);
float h_10 = max(0.0, -0.227817 * LdotV_AI +0.117579 * L_up_AI -0.052212 * L_right_AI -0.283099);
float h_11 = max(0.0, +0.312593 * LdotV_AI +0.270309 * L_up_AI +0.339734 * L_right_AI -0.312123);
float h_12 = max(0.0, -0.020185 * LdotV_AI +0.179554 * L_up_AI +0.419586 * L_right_AI -0.170548);
float h_13 = max(0.0, -0.235812 * LdotV_AI -0.531198 * L_up_AI -0.416336 * L_right_AI -0.358071);
float h_14 = max(0.0, -0.190273 * LdotV_AI -0.084639 * L_up_AI -0.001645 * L_right_AI -0.238522);
float h_15 = max(0.0, -0.138020 * LdotV_AI -0.229155 * L_up_AI -0.077436 * L_right_AI +0.193579);
float h_16 = max(0.0, -0.117066 * LdotV_AI +0.217140 * L_up_AI -0.128668 * L_right_AI -0.296223);
float h_17 = max(0.0, +0.362289 * LdotV_AI +0.011607 * L_up_AI -0.214221 * L_right_AI -0.176922);
float h_18 = max(0.0, -0.317304 * LdotV_AI -0.156049 * L_up_AI -0.057126 * L_right_AI -0.231417);
float h_19 = max(0.0, -0.411545 * LdotV_AI -0.256329 * L_up_AI +0.241861 * L_right_AI +0.472187);
float h_20 = max(0.0, -0.053393 * LdotV_AI -0.150776 * L_up_AI -0.359346 * L_right_AI +0.242782);
float h_21 = max(0.0, -0.113302 * LdotV_AI -0.131622 * L_up_AI -0.268129 * L_right_AI -0.204946);
float h_22 = max(0.0, -0.375829 * LdotV_AI +0.499545 * L_up_AI +0.122062 * L_right_AI +0.140837);
float h_23 = max(0.0, -0.072530 * LdotV_AI +0.163661 * L_up_AI -0.207363 * L_right_AI -0.193405);
float h_24 = max(0.0, -0.262255 * LdotV_AI +0.344391 * L_up_AI -0.304583 * L_right_AI -0.176768);
float h_25 = max(0.0, +0.427571 * LdotV_AI +0.189273 * L_up_AI -0.253946 * L_right_AI +0.123205);
float h_26 = max(0.0, -0.145198 * LdotV_AI -0.050615 * L_up_AI -0.011609 * L_right_AI -0.084413);
float h_27 = max(0.0, -0.176163 * LdotV_AI +0.240888 * L_up_AI -0.189336 * L_right_AI +0.134083);
float h_28 = max(0.0, +0.121887 * LdotV_AI +0.226428 * L_up_AI +0.054102 * L_right_AI +0.137560);
float h_29 = max(0.0, -0.335607 * LdotV_AI +0.047124 * L_up_AI +0.161066 * L_right_AI -0.096568);
float h_30 = max(0.0, +0.075336 * LdotV_AI +0.192577 * L_up_AI -0.173279 * L_right_AI -0.223513);
float h_31 = max(0.0, -0.326164 * LdotV_AI -0.128856 * L_up_AI +0.282614 * L_right_AI -0.325314);
float h_32 = max(0.0, -0.532323 * LdotV_AI -0.204129 * L_up_AI +0.220714 * L_right_AI -0.354362);
float h_33 = max(0.0, +0.412110 * LdotV_AI +0.294529 * L_up_AI +0.474748 * L_right_AI -0.055457);
float h_34 = max(0.0, +0.159915 * LdotV_AI -0.221757 * L_up_AI +0.057864 * L_right_AI +0.261863);
float h_35 = max(0.0, +0.297830 * LdotV_AI -0.235927 * L_up_AI -0.146541 * L_right_AI -0.141997);
float h_36 = max(0.0, -0.300425 * LdotV_AI -0.296365 * L_up_AI -0.423164 * L_right_AI +0.243542);
float h_37 = max(0.0, -0.403508 * LdotV_AI +0.175674 * L_up_AI +0.633639 * L_right_AI -0.321708);
float h_38 = max(0.0, +0.320733 * LdotV_AI -0.212766 * L_up_AI -0.085961 * L_right_AI -0.106643);
float h_39 = max(0.0, -0.149978 * LdotV_AI +0.344328 * L_up_AI -0.253601 * L_right_AI -0.169778);
float h_40 = max(0.0, -0.251524 * LdotV_AI +0.389538 * L_up_AI -0.611305 * L_right_AI -0.335100);
float h_41 = max(0.0, +0.283682 * LdotV_AI -0.227358 * L_up_AI -0.160546 * L_right_AI -0.075734);
float h_42 = max(0.0, -0.127769 * LdotV_AI +0.036399 * L_up_AI +0.087852 * L_right_AI -0.335463);
float h_43 = max(0.0, +0.356602 * LdotV_AI +0.070111 * L_up_AI -0.320773 * L_right_AI +0.193349);
float h_44 = max(0.0, -0.032557 * LdotV_AI -0.121736 * L_up_AI +0.040610 * L_right_AI -0.224507);
float h_45 = max(0.0, +0.126163 * LdotV_AI -0.253765 * L_up_AI -0.204475 * L_right_AI -0.268785);
float h_46 = max(0.0, -0.310365 * LdotV_AI -0.346836 * L_up_AI +0.030163 * L_right_AI +0.195170);
float h_47 = max(0.0, +0.079880 * LdotV_AI -0.114665 * L_up_AI -0.479288 * L_right_AI -0.327563);
float h_48 = max(0.0, +0.044959 * LdotV_AI +0.284195 * L_up_AI +0.480479 * L_right_AI +0.198101);
float h_49 = max(0.0, -0.069523 * LdotV_AI +0.238404 * L_up_AI -0.008442 * L_right_AI +0.233778);
float h_50 = max(0.0, +0.703939 * LdotV_AI -0.067063 * L_up_AI +0.097034 * L_right_AI -0.234521);
float h_51 = max(0.0, +0.177633 * LdotV_AI +0.085354 * L_up_AI -0.005193 * L_right_AI +0.219630);
float h_52 = max(0.0, +0.351508 * LdotV_AI +0.199840 * L_up_AI -0.185479 * L_right_AI -0.191889);
float h_53 = max(0.0, +0.213452 * LdotV_AI -0.160510 * L_up_AI -0.153216 * L_right_AI +0.230213);
float h_54 = max(0.0, +0.070681 * LdotV_AI +0.154811 * L_up_AI +0.275724 * L_right_AI +0.035350);
float h_55 = max(0.0, +0.167043 * LdotV_AI -0.061280 * L_up_AI +0.149845 * L_right_AI +0.353317);
float h_56 = max(0.0, -0.310771 * LdotV_AI +0.475181 * L_up_AI -0.583460 * L_right_AI +0.354222);
float h_57 = max(0.0, -0.497064 * LdotV_AI +0.281945 * L_up_AI +0.183057 * L_right_AI +0.268572);
float h_58 = max(0.0, -0.032620 * LdotV_AI -0.070460 * L_up_AI +0.136913 * L_right_AI -0.283422);
float h_59 = max(0.0, -0.038401 * LdotV_AI -0.130253 * L_up_AI -0.065826 * L_right_AI -0.223690);
float h_60 = max(0.0, +0.080053 * LdotV_AI -0.178332 * L_up_AI -0.066944 * L_right_AI +0.196111);
float h_61 = max(0.0, +0.058059 * LdotV_AI +0.501921 * L_up_AI -0.176428 * L_right_AI -0.204383);
float h_62 = max(0.0, +0.059114 * LdotV_AI +0.042241 * L_up_AI -0.091152 * L_right_AI -0.411552);
float h_63 = max(0.0, +0.038160 * LdotV_AI +0.196090 * L_up_AI +0.359511 * L_right_AI +0.204689);

float AI_ShadowSmooth = clamp(+0.283430 * h_0 -0.310926 * h_1 -0.229708 * h_2 +0.230259 * h_3 -0.016666 * h_4 +0.108546 * h_5 +0.148411 * h_6 -0.093444 * h_7 +0.213355 * h_8 -0.242762 * h_9 -0.054621 * h_10 -0.075484 * h_11 +0.129885 * h_12 +0.002535 * h_13 +0.073490 * h_14 +0.005697 * h_15 +0.135206 * h_16 -0.069853 * h_17 +0.096179 * h_18 +0.267397 * h_19 +0.070262 * h_20 -0.217346 * h_21 +0.189076 * h_22 +0.171145 * h_23 +0.105475 * h_24 +0.271833 * h_25 -0.111407 * h_26 +0.054052 * h_27 +0.041042 * h_28 +0.218583 * h_29 +0.090938 * h_30 +0.300175 * h_31 +0.159293 * h_32 +0.046891 * h_33 +0.170823 * h_34 +0.065620 * h_35 +0.228954 * h_36 +0.377466 * h_37 -0.154769 * h_38 +0.143146 * h_39 +0.138964 * h_40 -0.126152 * h_41 +0.163142 * h_42 +0.409468 * h_43 +0.173370 * h_44 -0.023147 * h_45 -0.027912 * h_46 -0.134944 * h_47 -0.230476 * h_48 +0.263428 * h_49 -0.159590 * h_50 -0.031186 * h_51 +0.156034 * h_52 -0.029123 * h_53 +0.036906 * h_54 +0.146149 * h_55 -0.425225 * h_56 +0.351252 * h_57 -0.057881 * h_58 -0.218751 * h_59 -0.223334 * h_60 -0.058801 * h_61 +0.062437 * h_62 +0.235336 * h_63 +0.042413, 0.1377, 1.28);
float AI_ShadowLocation = clamp(+0.235121 * h_0 -0.199662 * h_1 +0.017744 * h_2 +0.316552 * h_3 -0.626916 * h_4 +0.376448 * h_5 -0.125058 * h_6 +0.561885 * h_7 +0.134067 * h_8 +0.046526 * h_9 +0.016941 * h_10 -0.392629 * h_11 -0.396613 * h_12 +0.463165 * h_13 -0.247968 * h_14 -0.082969 * h_15 +0.284566 * h_16 +0.195821 * h_17 -0.358274 * h_18 +0.592049 * h_19 -0.341484 * h_20 +0.236191 * h_21 -0.383591 * h_22 -0.152476 * h_23 -0.465851 * h_24 -0.382475 * h_25 +0.132223 * h_26 +0.263364 * h_27 +0.075681 * h_28 -0.187529 * h_29 -0.282519 * h_30 -0.353285 * h_31 -0.577261 * h_32 -0.498763 * h_33 +0.070532 * h_34 -0.240393 * h_35 -0.475927 * h_36 -0.380330 * h_37 -0.370625 * h_38 -0.368672 * h_39 -0.534212 * h_40 -0.185529 * h_41 +0.143091 * h_42 -0.127058 * h_43 +0.143042 * h_44 -0.094766 * h_45 +0.438641 * h_46 +0.450219 * h_47 +0.389630 * h_48 -0.015044 * h_49 -0.334490 * h_50 -0.009679 * h_51 +0.449656 * h_52 +0.067756 * h_53 +0.064448 * h_54 -0.224125 * h_55 +0.733797 * h_56 -0.387778 * h_57 +0.107631 * h_58 -0.219675 * h_59 +0.223254 * h_60 -0.214289 * h_61 +0.101061 * h_62 +0.246832 * h_63 +0.058248, -0.289, 0.713);
float AI_ExposureScale = clamp(-0.021020 * h_0 +0.405498 * h_1 +0.252121 * h_2 -0.023855 * h_3 +0.395635 * h_4 +0.106845 * h_5 +0.174981 * h_6 +0.113942 * h_7 -0.102651 * h_8 -0.276252 * h_9 -0.095318 * h_10 +0.154152 * h_11 -0.037301 * h_12 -0.427681 * h_13 -0.268100 * h_14 +0.203973 * h_15 +0.009748 * h_16 -0.241699 * h_17 -0.255978 * h_18 -0.172651 * h_19 -0.174091 * h_20 -0.038139 * h_21 +0.346766 * h_22 +0.123005 * h_23 -0.016454 * h_24 +0.060384 * h_25 +0.091891 * h_26 -0.254623 * h_27 -0.248034 * h_28 +0.032897 * h_29 -0.070949 * h_30 +0.319251 * h_31 -0.090964 * h_32 +0.158948 * h_33 +0.107723 * h_34 +0.214074 * h_35 +0.327485 * h_36 -0.189253 * h_37 -0.107671 * h_38 -0.046291 * h_39 +0.314514 * h_40 +0.117809 * h_41 +0.122097 * h_42 +0.068431 * h_43 +0.260606 * h_44 +0.178418 * h_45 +0.094932 * h_46 +0.125509 * h_47 +0.035808 * h_48 +0.169212 * h_49 +0.118592 * h_50 +0.209702 * h_51 -0.034710 * h_52 +0.009717 * h_53 +0.214749 * h_54 +0.146654 * h_55 -0.178695 * h_56 -0.284697 * h_57 +0.022444 * h_58 +0.115183 * h_59 +0.083683 * h_60 +0.228569 * h_61 +0.037154 * h_62 +0.225030 * h_63 +0.311857, 0.5601, 1.298);
// ==== AUTO-MLP-END ====

// UseAI 开关：预测值 vs 手动值
float ShadowSmooth_E   = (UseAI > 0.5) ? AI_ShadowSmooth   : ShadowSmooth;
float ShadowLocation_E = (UseAI > 0.5) ? AI_ShadowLocation : ShadowLocation;
float ExposureScale_E  = (UseAI > 0.5) ? AI_ExposureScale  : ExposureScale;

// 色带分支（过时方案）：保持手动参数，AI 不预测
float ShadowThreshold_E = ShadowThreshold;
float ShadowEnd_E       = ShadowEnd;
float MidSplit_E        = MidSplit;
float ShadowSharpness_E = ShadowSharpness;

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
    // rampU = saturate(NdotL / ShadowSmooth_E - ShadowLocation_E)
    // ShadowSmooth_E 越大过渡越平滑；ShadowLocation_E 越大阴影越多
    float rampU = saturate(NdotL / max(0.001, ShadowSmooth_E) - ShadowLocation_E);
    float3 RampLit = Texture2DSample(CurveAtlasTexture, CurveAtlasTextureSampler, float2(rampU, 0.5)).rgb;

    // 阴影色作为暗部 tint：rampU 低（暗）时偏向 ShadowColorAdj，高（亮）时保持 RampLit
    FinalToon = lerp(ShadowColorAdj, RampLit, saturate(rampU * 2.0));

    // 阴影遮罩：rampU 直接作为明暗，供后续高光/Rim/AO 遮蔽
    ShadowMask = saturate(rampU);
}
else if (UseRampTex > 0.5)
{
    // ---- Ramp 贴图映射（回退）----
    float rampU = saturate(NdotL / max(0.001, ShadowSmooth_E) - ShadowLocation_E);
    float3 RampLit = (UseToonTexture > 0.5)
        ? Texture2DSample(ToonTexture, ToonTextureSampler, float2(rampU, 0.5)).rgb
        : LitColor;

    FinalToon = lerp(ShadowColorAdj, RampLit, saturate(rampU * 2.0));
    ShadowMask = saturate(rampU);
}
else
{
    // ---- 三层色带（SingleFunc 回退方式）----
    float EdgeHalfWidth = lerp(0.05, 0.002, saturate(ShadowSharpness_E));

    float T1 = ShadowThreshold_E;
    float T3 = max(T1 + 0.05, ShadowEnd_E);
    float BandTotal   = T3 - T1;
    float Shadow2Width = saturate(MidSplit_E) * BandTotal;
    float Shadow3Width = (1.0 - saturate(MidSplit_E)) * BandTotal;
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
// 旧版 Rim / Matcap 直连 ShadowMask，导致"阴影一柔化、头发高光就消失"。
// 现改为独立的受光闸门：LightMask = saturate(NdotL)，SpecGate 再给暗侧一点余量。
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

// Matcap UV 缩放偏移（示例材质的 MatcaoScale_Offset）
MatcapUV = MatcapUV * MatcapScale + MatcapOffset;

// 高光 Matcap（× HM.R 高光蒙版）
float3 MatcapSample = Texture2DSample(MatcapTexture, MatcapTextureSampler, MatcapUV).rgb;

// 高光锐化/收窄（MatcapSharpen=0 时与旧版逐字一致：压掉灰色光晕、只留亮核并提对比）
float MSharp = saturate(MatcapSharpen);
float3 MatcapAdj = saturate((MatcapSample - 0.05 * MSharp) / max(0.001, 1.0 - 0.05 * MSharp));
MatcapAdj = pow(MatcapAdj, 1.0 + 3.0 * MSharp);

// 粗糙 Matcap（× RoughColor 混合色）
float3 RoughMatcapSample = Texture2DSample(RoughMatcapTexture, RoughMatcapTextureSampler, MatcapUV).rgb;
ResultColor += RoughMatcapSample * RoughMatcapColor * RoughColor * SpecGate;

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

// 高光 Matcap（× HM.R 高光蒙版 × 受光闸门 × 发丝调制 × 各向异性形状）
// MatcapScale=1.0 时 AnisoShape≈1，效果接近普通 Matcap
// MatcapScale>1.0 时 AnisoShape<1，产生各向异性拉长效果
ResultColor += MatcapAdj * MatcapColor * HM_HighLightMask * SpecGate * (1.0 + HairMapMask * 1.5) * AnisoShape;

// ---------- SSS 次表面散射（整合自示例材质） ----------
if (UseSSS > 0.5)
{
    float3 SSS = Texture2DSample(SSSTex, SSSTexSampler, UV).rgb;
    ResultColor += SSS * SSSColor;
}

// ---------- 曝光矫正 ----------
ResultColor *= ExposureScale_E;

return ResultColor;
