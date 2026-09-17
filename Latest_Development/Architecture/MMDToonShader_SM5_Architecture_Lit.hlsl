// MMD Toon Shader — Architecture / Scene Surface Lit Edition
//
// !!! 请勿将整个文件粘贴到一个 Custom Node !!!
// 本文件包含两个独立段落（Part A / Part B），必须分别粘贴到两个 Custom Node：
//   Part A（第 56 行起）→ Custom Node A → 连接至 Base Color
//   Part B（第 164 行起）→ Custom Node B → 连接至 Emissive Color
// 如果整个文件贴进一个 Custom Node，Part B 引用的输入变量在 Part A 的 Inputs
// 列表中不存在，会导致编译报错。
// ================================================================
//
// 与 Unlit 版本（MMDToonShader_SM5_SingleFunc_Architecture.hlsl）的核心差异：
//
//   Unlit 版：输出接 Emissive Color，独立计算全部光照（NdotL 渐变阴影、
//   Rim/Specular/Emissive），完全不参与 UE5 光照系统 → 无法接收角色/其他
//   物体投射的阴影。
//
//   Lit 版（本文件）：材质设为 Default Lit，分两个 Custom Node：
//     Part A → Base Color：贴图处理 + 色调 + 饱和度 + AO + ShadowColor 色相偏移
//             + 金属度漫反射衰减。UE5 在此之上叠加 NdotL × ShadowAttenuation，
//             自动接收来自角色、建筑、植被等任何物体的场景阴影。
//     Part B → Emissive Color：Rim Light + Specular + EmissiveTexture + 曝光，
//             保留 NdotL ShadowMask 遮蔽确保阴影侧自然淡出，但不参与 UE5 光照。
//
//   法线贴图 → 材质 Normal 引脚（标准 UE 法线贴图节点），UE5 自动用凹凸法线
//   计算 NdotL，石缝/砖缝细节自然体现在光照中，不再需要手动 BumpShadingDelta。
//
//   材质的 Roughness=1 / Metallic=0 / Specular=0（固定常量），引擎不产生额外的
//   PBR 高光，所有高光由 Part B 的自定义 Blinn-Phong 提供。
//
// ShadowColor 语义变化：Lit 版中 ShadowColor 只做色相偏移（归一化到亮度=1），
// 不参与亮度控制。阴影区域的亮度由场景光源（NdotL）+ 阴影贴图（ShadowAtten）
// + 天光/间接光照决定。默认值调整为更轻的冷色偏 (0.85, 0.92, 1.0)，要更强的
// 冷暖分离效果可调饱和 ShadowColor（例如 (0.7, 0.8, 1.0)），或调低场景天光
// 让阴影侧更深。
//
// ================================================================
// 材质设置步骤
// ================================================================
//
// 1. 新建材质，Shading Model = Default Lit，Blend Mode = Opaque
// 2. 添加两个 Custom 节点：
//    - Custom Node A：粘贴 Part A → Code 字段，Output Type = CMOT Float3
//      连接至材质的 Base Color 引脚
//    - Custom Node B：粘贴 Part B → Code 字段，Output Type = CMOT Float3
//      连接至材质的 Emissive Color 引脚
// 3. 法线贴图 → Normal 引脚：
//    TextureSample 节点（SamplerType = Normal）→ FlattenNormal 材质函数 → Normal 引脚
//    ⚠️ TextureSample 的 SamplerType 设成 Normal 之后，UE **会自动解包**，输出已经是
//      [-1,1] 的切线空间向量——**绝对不要再加 ×2−1**。Custom 节点内部之所以要手动
//      ×2−1，是因为那里读的是原始 .rg 通道，两个场景的约定不一样。加了会双重解包：
//      平面法线 (0,0,1) 被算成 (-1,-1,1)，整个表面法线全错，NdotL 大面积为负被
//      saturate 砸到 0 → 跟着法线贴图图案走的黑斑。（实际踩过这个坑）
//    FlattenNormal 的 Flatness 输入接 NormalMapIntensity 取反（OneMinus）——
//      语义相反：NormalMapIntensity 0=平坦/1=原始强度，Flatness 0=原始/1=拍平。
//    注意：NormalMapTex 仍需作为 TextureObjectParameter 传入 Part B 的
//      Custom Node B（Specular 高光形状用），两条路径共用同一个参数名。
//
// 4. 高光模式开关（StaticSwitchParameter，名为 "Use PBR Specular"，默认 False）
//
//    下面四个引脚不是固定常量，而是接同一个静态开关的两个分支——用静态开关而不是
//    Lerp，是因为它在编译期分支、运行时零开销，且天生是"一次性设置"而非可动画参数。
//    四个开关节点共用同一个参数名，材质实例里勾一次就同时切换全部四条线路。
//
//    ┌──────────────────┬───────────────────────┬───────────────────────────┐
//    │ 引脚             │ False = 模式 A（默认）│ True = 模式 B             │
//    ├──────────────────┼───────────────────────┼───────────────────────────┤
//    │ Roughness        │ 常量 1.0              │ ORM 贴图 G 通道           │
//    │ Metallic         │ 常量 0.0              │ ORM 贴图 B 通道           │
//    │ Specular         │ 常量 0.0              │ 常量 0.5                  │
//    │ Part B 的        │ MPC SpecularStrength  │ 常量 0.0（关掉自定义高光）│
//    │ SpecularStrength │                       │                           │
//    └──────────────────┴───────────────────────┴───────────────────────────┘
//
//    G / B 通道用独立的 ComponentMask 节点取，不要依赖直接拖 TextureSample 的
//      G / B 输出针脚——图上写明是哪个通道，读图的人（和半年后的自己）不用去点
//      针脚才知道 Roughness 取的是 G 不是 R。
//
//    模式 A（风格化，默认）：引擎只负责漫反射 + 阴影，关掉 UE 自带 PBR 高光，
//      全部高光走 Part B 的卡通 Blinn-Phong。高光形状完全可控、和角色 Toon 高光
//      同一套语言。代价：没有真实环境反射/SSR，湿滑路面、玻璃、金属这类**靠反射
//      才成立**的材质做不出来。
//      ⚠️ 这个模式下 ORM 的 G 通道（粗糙度）只影响 Part B 那一小簇自定义高光，
//        不进入引擎的高光/反射管线——"接了 ORM 贴图但看不出粗糙度差异"是预期行为。
//
//    模式 B（物理，需要反射时用）：ORM 的 G/B 通道真正进入 UE 原生 PBR 管线，
//      引擎接管高光和反射（配合 Lumen 会有真实环境反射）。此时 Part B 的自定义
//      Blinn-Phong 被开关强制归零——两套高光叠加会很脏，这是刻意的互斥设计。
//
//    ⚠️ 两种模式各自编译成独立的着色器排列，而且**只有被实际用到的那个分支会被
//      编译**。改完两种模式都要各验一遍，不能只测默认模式就以为没问题。
//
// 5. Ambient Occlusion 引脚：常量 1.0（AO 始终在 Part A 内处理，不参与上面的开关）
//
// 6. ORM / 法线贴图都在两条路径上被消费，且**采样器类型不同**，这是有意为之不是重复：
//    - TextureObjectParameter → 两个 Custom 节点（内部自己 Texture2DSample）
//    - TextureSample → 材质原生引脚（ORM 用 LinearColor，法线用 Normal）
//    两者共用同一个参数名（"ORM Texture" / "Normal Map Texture"），UE 按参数名匹配
//    实例覆盖，所以材质实例里只需要设一次贴图，两条路径自动同步，不会出现
//    "改了一个忘了改另一个"。
//
//    ⚠️ 不要图省事让两条路径共用同一个 TextureObjectParameter 节点：Custom 节点需要
//      UE 自动生成配套的 FooSampler 变量，标准 TextureSample 自己管理另一套采样器，
//      两边同时引用同一节点时 UE 在合并采样器资源时会把 Custom 节点期望的名字弄丢，
//      报 "use of undeclared identifier 'NormalMapTexSampler'"。（实际踩过）
//
// ================================================================
// 贴图传入方式：必须使用 TextureObjectParameter 节点
// ================================================================
// 不可使用 TextureSampleParameter2D（其输出为颜色值，无法自定义 UV）。
// UE5 会为 Texture2D 类型输入 Foo 自动生成 FooSampler，代码内已按此编写。
// ================================================================


// ################################################################
// PART A — Base Color（粘贴到 Custom Node A）
// ################################################################
// Output Type: CMOT Float3
// 连接至材质的 Base Color 引脚
//
// Inputs 面板按顺序添加：
// 名称              类型        连接来源
// ------------------------------------------------------------------
// UV                Float2      TexCoord 节点
// WorldNormal       Float3      VertexNormalWS 节点
// LightDirection    Float3      从场景指向光源的方向（与 Unlit 版相同约定）
// BaseColorTex      Texture2D   TextureObjectParameter
// ORMTexture        Texture2D   TextureObjectParameter（R=AO/G=Roughness/B=Metallic）
// BaseTint          Float3      默认 (1.0, 1.0, 1.0)
// TintIntensity     Float1      默认 0.0
// TintMode          Float1      默认 0.0（0=Overlay, 1=乘法, 2=SoftLight）
// Saturation        Float1      默认 1.0
// ShadowThreshold   Float1      默认 0.5（0~1，色相偏移的起始位置）
// ShadowSoftness    Float1      默认 0.5（0=硬过渡, 1=最柔过渡）
// ShadowColor       Float3      默认 (0.85, 0.92, 1.0) 冷色阴影色偏
// UseORM            Float1      默认 0.0（0=不采样 ORM，避免未绑贴图时意外发黑）
// AOStrength        Float1      默认 1.0
// MetallicStrength  Float1      默认 0.0
//
// Lit 版 ShadowColor 行为说明：
//   只做色相偏移（内置归一化到亮度=1），不参与亮度控制。默认 (0.85,0.92,1.0)
//   是轻微冷色偏；要更明显的冷暖分离，把 ShadowColor 往更饱和的方向调，例如
//   (0.6, 0.75, 1.0)。调到 (1,1,1) = 完全不色偏，等价于标准 Lit。

// ---------- Base Colour ----------
float3 ResultColor = Texture2DSample(BaseColorTex, BaseColorTexSampler, UV).rgb;

// ---------- 色调（多模式，与 Unlit 版相同）----------
float3 TintedColor;
float TintModeVal = round(clamp(TintMode, 0.0, 2.0));

if (TintModeVal < 0.5)
{
    // Mode 0: Overlay
    TintedColor.r = (ResultColor.r < 0.5) ? (2.0 * ResultColor.r * BaseTint.r)
                                          : (1.0 - 2.0 * (1.0 - ResultColor.r) * (1.0 - BaseTint.r));
    TintedColor.g = (ResultColor.g < 0.5) ? (2.0 * ResultColor.g * BaseTint.g)
                                          : (1.0 - 2.0 * (1.0 - ResultColor.g) * (1.0 - BaseTint.g));
    TintedColor.b = (ResultColor.b < 0.5) ? (2.0 * ResultColor.b * BaseTint.b)
                                          : (1.0 - 2.0 * (1.0 - ResultColor.b) * (1.0 - BaseTint.b));
}
else if (TintModeVal < 1.5)
{
    TintedColor = ResultColor * BaseTint;
}
else
{
    float3 softlightA = ResultColor - (1.0 - 2.0 * BaseTint) * ResultColor * (1.0 - ResultColor);
    float3 softlightB = ResultColor + (2.0 * BaseTint - 1.0) * (sqrt(ResultColor) - ResultColor);
    TintedColor = select(BaseTint <= 0.5, softlightA, softlightB);
}

ResultColor = lerp(ResultColor, TintedColor, TintIntensity);

// ---------- 饱和度 ----------
float Luminance = dot(ResultColor, float3(0.2126, 0.7152, 0.0722));
ResultColor = lerp(float3(Luminance, Luminance, Luminance), ResultColor, Saturation);

// ---------- ShadowColor 色相偏移（仅色偏，不调亮度）----------
// 与 Unlit 版的关键差异：这里不乘 ShadowColor 本身来压暗，而是先把 ShadowColor
// 归一化到亮度=1，只取它的色相/饱和度信息。亮度由 UE5 的 NdotL × ShadowAttenuation
// 在 Base Color 之后自动叠加。
float3 N = normalize(WorldNormal);
float3 L = normalize(LightDirection);
float NdotL = dot(N, L);
float LightAtten = NdotL * 0.5 + 0.5;

float ShadowHalfWidth = lerp(0.02, 0.55, saturate(ShadowSoftness));
float ShadowMask = smoothstep(ShadowThreshold - ShadowHalfWidth,
                               ShadowThreshold + ShadowHalfWidth,
                               LightAtten);

// 归一化 ShadowColor 到亮度=1（保留色相/饱和度，去掉亮度信息）
float ShadowColorLum = dot(ShadowColor, float3(0.2126, 0.7152, 0.0722));
float3 ShadowTint = ShadowColor / max(0.001, ShadowColorLum);

// 阴影侧施色偏，亮部保持底色不变
ResultColor *= lerp(ShadowTint, float3(1.0, 1.0, 1.0), ShadowMask);

// ---------- ORM 贴图（AO + Metallic 漫反射衰减）----------
// AO 压暗基础色；Metallic 压低漫反射（金属几乎没有漫反射，颜色靠高光/反射）
// Roughness 不影响 Base Color，只在 Part B 的 Specular 中使用。
// UseORM=0（默认）完全跳过采样，避免材质实例忘记绑贴图导致意外发黑。
if (UseORM > 0.5)
{
    float3 ORMSample     = Texture2DSample(ORMTexture, ORMTextureSampler, UV).rgb;
    float ORM_AO         = ORMSample.r;
    float ORM_Metallic   = ORMSample.b;

    float AODiffuse = lerp(1.0, ORM_AO, saturate(AOStrength));
    ResultColor *= AODiffuse;

    // 金属度压低漫反射到 15%：金属感体现在 Part B 的 Specular 染色上，
    // 这里确保整个表面（不仅是高光点）看起来像金属而不是 diffuse 材质。
    float MetalDiffuseAtten = lerp(1.0, 0.15, saturate(ORM_Metallic * MetallicStrength));
    ResultColor *= MetalDiffuseAtten;
}

return ResultColor;


// ################################################################
// PART B — Emissive Color（粘贴到 Custom Node B）
// ################################################################
// Output Type: CMOT Float3
// 连接至材质的 Emissive Color 引脚
//
// Inputs 面板按顺序添加：
// 名称                  类型        连接来源
// ----------------------------------------------------------------------
// UV                    Float2      TexCoord 节点（与 Part A 相同）
// WorldNormal           Float3      VertexNormalWS 节点
// WorldTangent          Float3      VertexTangentWS 节点（法线贴图 TBN 基底）
// CameraVector          Float3      CameraDirectionVector 节点
// LightDirection        Float3      从场景指向光源的方向（与 Part A 相同）
// NormalMapTex          Texture2D   TextureObjectParameter（与材质 Normal 引脚同一张贴图）
// ORMTexture            Texture2D   TextureObjectParameter（与 Part A 同一张贴图，R=AO/G=Rough/B=Metal）
// EmissiveTexture       Texture2D   TextureObjectParameter（窗户/灯笼自发光贴图，未接或纯黑=无效果）
// SpecPower             Float1      默认 32.0
// SpecularStrength      Float1      默认 0.25
// SpecularThreshold     Float1      默认 0.3
// SpecularSoftness      Float1      默认 0.05
// SpecularColor         Float3      默认 (1.0, 1.0, 1.0)
// RimIntensity          Float1      默认 1.0
// RimWidth              Float1      默认 0.5
// RimGradient           Float1      默认 0.4
// RimColor              Float3      默认 (1.0, 0.75, 0.5)
// NormalMapIntensity    Float1      默认 1.0
// EmissiveColor         Float3      默认 (1.0, 1.0, 1.0)
// EmissiveIntensity     Float1      默认 2.0
// ExposureScale         Float1      默认 1.0
// UseORM                Float1      默认 0.0（与 Part A 相同）
// RoughnessInfluence    Float1      默认 0.0（ORM 粗糙度对 Specular 的调制强度）
// MetallicStrength      Float1      默认 0.0（与 Part A 相同，控制 Specular 染色）
// ShadowThreshold       Float1      默认 0.5（与 Part A 相同，用于 ShadowMask）
// ShadowSoftness        Float1      默认 0.5（与 Part A 相同）

// ---------- 方向向量 ----------
float3 N_Emissive = normalize(WorldNormal);
float3 V_Emissive = normalize(-CameraVector);
float3 L_Emissive = normalize(LightDirection);

// ---------- 法线贴图（为 Specular NdotH 重建 BumpNormal）----------
float2 RawXY     = Texture2DSample(NormalMapTex, NormalMapTexSampler, UV).rg * 2.0 - 1.0;
float TangentLen = length(WorldTangent);

float3 BumpNormal_Emissive;
if (TangentLen < 1e-4 || dot(RawXY, RawXY) > 1.0)
{
    BumpNormal_Emissive = N_Emissive;
}
else
{
    float3 T_Emissive = WorldTangent / TangentLen;
    T_Emissive = normalize(T_Emissive - N_Emissive * dot(N_Emissive, T_Emissive));
    float3 B_Emissive = cross(N_Emissive, T_Emissive);
    float2 NormalXY   = RawXY * NormalMapIntensity;
    float NormalZ     = sqrt(saturate(1.0 - dot(NormalXY, NormalXY)));
    BumpNormal_Emissive = normalize(NormalXY.x * T_Emissive + NormalXY.y * B_Emissive + NormalZ * N_Emissive);
}

// ---------- ORM 粗糙度/金属度（Specular 调制用）----------
float RoughExpScale = 1.0;
float RoughIntScale = 1.0;
float ORM_Metallic_B = 0.0;
if (UseORM > 0.5)
{
    float3 ORMSample_B  = Texture2DSample(ORMTexture, ORMTextureSampler, UV).rgb;
    float ORM_Roughness = saturate(ORMSample_B.g);
    ORM_Metallic_B      = ORMSample_B.b;

    float SmoothFactor = 1.0 - ORM_Roughness;
    RoughExpScale = lerp(1.0, SmoothFactor, saturate(RoughnessInfluence));
    RoughIntScale = lerp(1.0, SmoothFactor * SmoothFactor, saturate(RoughnessInfluence));
}

// ---------- ShadowMask（NdotL 渐变，用于遮蔽 Rim/Specular）----------
float NdotL_Emissive  = dot(BumpNormal_Emissive, L_Emissive);
float LightAtten_Em   = NdotL_Emissive * 0.5 + 0.5;
float ShadowHalfW_B   = lerp(0.02, 0.55, saturate(ShadowSoftness));
float ShadowMask_B    = smoothstep(ShadowThreshold - ShadowHalfW_B,
                                    ShadowThreshold + ShadowHalfW_B,
                                    LightAtten_Em);

// ---------- Rim Light ----------
// 用平滑几何法线 N，不用 BumpNormal——Rim 是大范围轮廓效果，
// 掺入法线贴图细节会在轮廓上引入高频噪点。
float NdotV_Emissive  = abs(dot(N_Emissive, V_Emissive));
float Fresnel         = 1.0 - NdotV_Emissive;
float RimThreshold    = 1.0 - saturate(RimWidth);
float RimEdgeHalfW    = lerp(0.002, 0.3, saturate(RimGradient));
float RimMask_B       = smoothstep(RimThreshold - RimEdgeHalfW, RimThreshold + RimEdgeHalfW, Fresnel);

float RimNdotL_B      = dot(N_Emissive, L_Emissive);
float RimLightMask    = saturate(RimNdotL_B);
float Rim             = RimMask_B * RimLightMask * ShadowMask_B * RimIntensity;

float3 EmissiveResult = RimColor * Rim;

// ---------- Specular（Blinn-Phong，受 ORM 粗糙度/金属度调制）----------
float3 H_Emissive            = normalize(L_Emissive + V_Emissive);
float NdotH_Emissive         = saturate(dot(BumpNormal_Emissive, H_Emissive));

float SpecLightMask_B        = smoothstep(SpecularThreshold,
                                           SpecularThreshold + max(0.001, SpecularSoftness),
                                           saturate(NdotL_Emissive));
float SpecFalloff_B          = SpecLightMask_B * SpecLightMask_B;

float SpecPowerEff           = max(1.0, SpecPower * RoughExpScale);
float Spec = pow(NdotH_Emissive, SpecPowerEff) * ShadowMask_B * SpecFalloff_B * RoughIntScale;

// Specular 颜色：金属区域 Specular 向中性白色偏移（物理规律——金属反射光源颜色，
// 不反射自身颜色），非金属区域保持 SpecularColor 的美术控制。
// Unlit 版可以 `lerp(SpecularColor, BaseAlbedo, metal)` 因为它知道底色；
// Lit 版 Part A/B 分属两个节点，Part B 拿不到 Part A 计算出的 BaseAlbedo，
// 所以这里向中性白色插值作为近似——更接近真实的金属高光行为。
float3 MetalTint = lerp(SpecularColor, float3(1.0, 1.0, 1.0), saturate(ORM_Metallic_B * MetallicStrength));
EmissiveResult += Spec * SpecularStrength * MetalTint;

// ---------- 自发光（窗户/灯笼，不受光照影响）----------
float3 EmissiveSample = Texture2DSample(EmissiveTexture, EmissiveTextureSampler, UV).rgb;
EmissiveResult += EmissiveSample * EmissiveColor * EmissiveIntensity;

// ---------- 曝光 ----------
EmissiveResult *= ExposureScale;

return EmissiveResult;
