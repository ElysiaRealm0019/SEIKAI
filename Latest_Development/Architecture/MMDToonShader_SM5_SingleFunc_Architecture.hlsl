// MMD Toon Shader - UE5 Custom Node 直接粘贴版本（建筑/场景表面专属版）
// 适用于 Unlit 材质模式，Blend Mode = Opaque，输出连接至 Emissive Color 引脚
//
// ================================================================
// 与主文件（MMDToonShader_SM5_SingleFunc.hlsl）的差异
// ================================================================
// 主文件是完全按角色（皮肤/头发/衣服）设计的：三层离散 Toon 阴影色带、
// 逐色带 HSV 批量调色、Matcap 球面高光、头发定位高光贴图——这些机制的
// 目的都是做出"赛璐璐动画分色带"的观感。
//
// 本文件面向建筑/场景静态表面，参考观感是暖光/冷影分离的连续渐变（例如
// 夕阳下的石制/鎏金建筑），没有离散色带，因此相对主文件：
//   - 删除：MatcapTexture/MatcapColor/MatcapInfluence（高光跟摄像机转，
//     大型静态建筑运镜时会明显穿帮，角色小转得快不容易看出来）
//   - 删除：HairHighlightTexture 及全部 HairHighlight* 参数（头发专属）
//   - 删除：三层阴影（ShadowEnd/MidSplit/Shadow2Color/Shadow3Color）和
//     整套 HSV 批量调色（ShadowHueShift/ShadowSaturation/ShadowBrightness）
//   - 阴影系统重写为单一连续渐变（见下方 ShadowThreshold/ShadowSoftness）
//   - 阴影渐变改用 BumpNormal（响应法线贴图的石缝/砖缝/浮雕细节），
//     Rim Light 仍然用平滑几何法线 N，不受影响（避免轮廓边缘出现高频噪点）
//   - 新增：ORMTexture 贴图（R=AO, G=Roughness, B=Metallic），通过 UseORM
//     显式开关（默认关闭，行为等同于完全没有这个功能，避免材质实例忘记绑
//     贴图导致意外整体发黑）。AO 压暗基础色；Roughness 驱动 Specular 的
//     锐度/强度（哑光石材 vs 光滑鎏金共用一个材质实例时非常有用）；
//     Metallic 把 Specular 颜色从 SpecularColor 拉向底色（金属反射自身颜色）
//   - 新增：EmissiveTexture 自发光（窗户/灯笼等夜景光源），不受 Shadow
//     Gradient / AO / Rim / Specular 影响，未接或纯黑时不影响不需要它的材质
//   - 其余（法线贴图双重回退、Base Color 色调三模式、Saturation、
//     Rim Light、Specular、ExposureScale）与主文件机制一致，仅调整了
//     部分默认值以贴合建筑光影观感（暖色 Rim、更内敛的 Specular 等）
//
// 关于植被（片面树/Alpha 卡片）：本文件不做任何专门处理（不加风吹摆动、
// 不加叶片半透明散射等）。如果要把这份材质直接用在 Masked 混合模式的
// 植被卡片上，需要额外把 BaseColorTex 的 Alpha 通道接到材质的 Opacity Mask
// 引脚——这是材质设置层面的事，不需要改这份 Custom 节点代码。
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
// 名称                  类型              连接来源
// ----------------------------------------------------------------
// UV                    Float2            TexCoord 节点
// WorldNormal           Float3            VertexNormalWS 节点
// WorldTangent          Float3            VertexTangentWS 节点（模型切线，世界空间，法线贴图用）
// CameraVector          Float3            CameraDirectionVector 节点
// LightDirection        Float3            从场景指向光源的方向（见 Documentation/MMDToonShader_SM5_SingleFunc_使用文档.md）
// BaseColorTex          Texture2D         TextureObjectParameter（Base Colour 贴图）
// ORMTexture            Texture2D         TextureObjectParameter（R=AO/G=Roughness/B=Metallic，
//                                          UE/glTF 标准约定；只有 UseORM=1 时才会被采样）
// NormalMapTex          Texture2D         TextureObjectParameter（切线空间法线贴图，标准 UE 格式）
// EmissiveTexture       Texture2D         TextureObjectParameter（自发光贴图，窗户/灯笼等夜景光源，
//                                          UV 与 BaseColorTex 一致，未接或纯黑=无自发光）
// BaseTint              Float3            色调颜色  默认（1.0, 1.0, 1.0）无色偏
// TintIntensity         Float1            色调混合强度  默认 0.0（0=不改变, 1=完全应用色调）
// TintMode              Float1            色调模式  默认 0.0（0=Overlay混合, 1=乘法, 2=色相偏移）
// Saturation            Float1            饱和度  默认 1.0（1=不改变；>1 更鲜艳；<1 更灰；0=纯灰度）
// ShadowThreshold       Float1            阴影渐变中心点  默认 0.5（0~1，越大阴影范围越广）
// ShadowSoftness        Float1            阴影渐变柔和度  默认 0.5（0~1，越大过渡越宽越柔和；
//                                          注意和主文件 ShadowSharpness 语义相反）
// ShadowColor           Float3            阴影侧颜色  默认（0.5, 0.58, 0.75）冷紫蓝，配合暖色
//                                          BaseTint/BaseColorTex 做出冷暖分离；亮部固定用白色
//                                          （不改变 BaseColorTex 原色），没有单独的亮部渐变贴图
// UseORM                Float1            ORM 开关  默认 0.0（0=完全不采样 ORMTexture，AO/粗糙度/
//                                          金属度全部不生效；1=启用）
// AOStrength            Float1            AO 强度  默认 1.0（仅在 UseORM=1 时生效）
// RoughnessInfluence    Float1            粗糙度影响  默认 0.0（仅在 UseORM=1 时生效；0=忽略 G 通道、
//                                          维持原高光；1=完全按贴图，粗糙区高光变弱变散，光滑区保留锐利）
// MetallicStrength      Float1            金属度影响  默认 0.0（仅在 UseORM=1 时生效；0=不生效；
//                                          1=完全按 B 通道生效：把高光染成底色（模拟金属反射自身
//                                          颜色）同时压低漫反射到 15%，让金属感在整个受光面都能看出来，
//                                          不局限于 Specular 那个小高光点）
// SpecPower             Float1            高光锐度  默认 32.0（越大光斑越小越锐利）
// SpecularStrength      Float1            高光强度  默认 0.25（建筑高光比角色更内敛）
// SpecularThreshold     Float1            高光截断阈值  默认 0.3（NdotL 低于此值区域无高光）
// SpecularSoftness      Float1            高光截断过渡宽度  默认 0.05（越大过渡越柔和）
// SpecularColor         Float3            高光颜色  默认（1.0, 1.0, 1.0）白色
// RimIntensity          Float1            Rim Light 强度  默认 1.0
// RimWidth              Float1            Rim Light 条带宽度  默认 0.5（0~1，越大条带从轮廓往内扩展越多）
// RimGradient           Float1            Rim Light 边缘渐变  默认 0.4（0=硬边界，1=柔和渐变）
// RimColor              Float3            Rim Light 颜色  默认（1.0, 0.75, 0.5）暖橙，贴合夕阳色温
// NormalMapIntensity    Float1            法线贴图强度  默认 1.0（0=完全平坦不生效，1=贴图原始强度）
// EmissiveColor         Float3            自发光颜色叠加  默认（1.0, 1.0, 1.0）（白色=不改变贴图颜色）
// EmissiveIntensity     Float1            自发光强度  默认 2.0（>1 可让窗户/灯笼溢出 HDR 驱动 Bloom）
// ExposureScale         Float1            整体曝光  默认 1.0（>1 增强亮度，可驱动 Bloom）
// ----------------------------------------------------------------
// Output Type: CMOT Float3  →  连接至材质的 Emissive Color 引脚
// ================================================================
//
// ================================================================
// 参数分类：哪些适合做动画驱动，哪些建议只在材质实例里设一次
// ================================================================
// 建筑场景最典型的动画需求是"昼夜循环"——白天暖光 → 黄昏 → 入夜亮灯。
// 下面这批参数就是为这个准备的。
//
// 注：LightDirection 不在任何一档里——它是蓝图从场景 DirectionalLight 读出来
// 写进材质的场景数据，跟着太阳自己走，不需要（也不应该）手动打关键帧。
//
// [✅ 适合逐帧驱动] 昼夜循环核心：
//   EmissiveIntensity 入夜时窗户/灯笼亮起来的关键——白天设 0（灯灭），
//                     天黑时渐变到 2.0 左右（灯亮），是最直观的一条曲线
//   ExposureScale     整体明暗，配合昼夜推移压暗/提亮
//   ShadowColor       白天偏中性 → 黄昏偏紫 → 夜晚偏冷蓝。本文件只有一个
//                     阴影色（不像角色版有三层需要 HSV 层统一驱动），
//                     直接给这一个 Float3 打关键帧最省事
//   RimColor          同理，夕阳暖橙 → 夜晚冷蓝月光边缘光
//   RimIntensity / SpecularStrength / Saturation / TintIntensity / AOStrength
//                     都是连续量，需要时随场景氛围渐变即可
//   RoughnessInfluence / MetallicStrength 技术上也能动，但通常是"这块贴图
//                     该有多少 ORM 效果"的一次性决定，不属于昼夜循环范畴
//
// [🎯 需要时校准] 阴影位置——与光照强相关，随太阳角度变化可能需要修正：
//   ShadowThreshold   决定明暗交界线落在建筑表面的哪个位置。太阳升落过程中
//                     交界线会跟着移动，某些角度下可能压到不好看的位置
//                     （比如整面墙几乎全暗、或者交界线正好切在装饰构件中间），
//                     这时按镜头微调把它推回合适位置即可。
//                     不是"设一次就不动"，也不是常规逐帧曲线，属于按需校准。
//   注意 ShadowSoftness 不属于这一类：它只控制过渡带宽窄（观感软硬），
//   与太阳角度无关，归美术一次性决定。
//
// [⚙️ 一次性设置] "这个材质长什么样"，美术调好就不用再碰：
//   ShadowSoftness, RimWidth, RimGradient, SpecPower,
//   SpecularThreshold, SpecularSoftness, NormalMapIntensity,
//   BaseTint, SpecularColor, EmissiveColor
//
// [⛔ 不要做动画] 这两个是开关量，不是连续量，中间没有有意义的过渡态：
//   TintMode  内部用 round() 取整分档（0/1/2），两档之间打关键帧只会在
//             中点硬跳一下
//   UseORM    代码里是 if (UseORM > 0.5) 硬分支，0.49→0.51 会瞬间跳变。
//             要让 AO/高光效果渐入渐出请固定 UseORM=1，改为动画 AOStrength
//             / RoughnessInfluence / MetallicStrength
// ================================================================

// ---------- Base Colour ----------
float3 ResultColor = Texture2DSample(BaseColorTex, BaseColorTexSampler, UV).rgb;

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
    float3 softlightA = ResultColor - (1.0 - 2.0 * BaseTint) * ResultColor * (1.0 - ResultColor);
    float3 softlightB = ResultColor + (2.0 * BaseTint - 1.0) * (sqrt(ResultColor) - ResultColor);
    softlight = select(BaseTint <= 0.5, softlightA, softlightB);
    TintedColor = softlight;
}

ResultColor = lerp(ResultColor, TintedColor, TintIntensity);

// ---------- 饱和度调节 ----------
// Saturation = 1：不改变；> 1：更鲜艳；< 1：更接近灰度；= 0：完全去饱和
// 使用 Rec.709 亮度权重保持明度不变，只调整色彩鲜艳程度
float Luminance = dot(ResultColor, float3(0.2126, 0.7152, 0.0722));
ResultColor = lerp(float3(Luminance, Luminance, Luminance), ResultColor, Saturation);

// 保存一份此刻的底色，供后面金属高光染色使用（金属反射自身颜色而非纯白 SpecularColor）
float3 BaseAlbedo = ResultColor;

// ---------- 方向向量 ----------
float3 N = normalize(WorldNormal);
float3 V = normalize(-CameraVector);   // pixel → camera
float3 L = normalize(LightDirection);  // pixel → light

// ---------- 法线贴图（切线空间凹凸细节）----------
// 只用来生成 BumpNormal；本文件里 Shadow Gradient、整个向光面的微观明暗
// （见下方"法线贴图微观明暗"）和 Specular 都会用到它，
// Rim Light 仍然用平滑的几何法线 N（见下方 Rim Light 小节的说明）。
// 采样并解包 XY（[0,1] → [-1,1]），Z 后面用 sqrt 重建，不直接读蓝通道 ——
// UE 的 Normalmap 压缩是 BC5，只存 R/G 两个通道；Custom 节点里直接采样的蓝通道
// 不可靠（常为 0），当作 Z 会得到 -1，使法线翻向内侧、高光跑到背面。
float2 RawXY     = Texture2DSample(NormalMapTex, NormalMapTexSampler, UV).rg * 2.0 - 1.0;
float TangentLen = length(WorldTangent);

// 两道回退到几何法线 N 的守卫，任一命中都退回 N（表现与未加法线贴图完全一致）：
//   守卫 1（切线无效）：WorldTangent 未连接 VertexTangentWS 时为 (0,0,0)，
//     normalize 会得到 NaN，而 saturate(dot(NaN, H)) 在部分 GPU 上返回 1 →
//     pow(1, SpecPower)=1 → 全表面满强度高光。
//   守卫 2（纹理无效）：有效切线法线一定满足 x²+y² ≤ 1；未赋值 / 纯黑 / 纯白等
//     "不是法线贴图"的输入解包后会 > 1。
float3 BumpNormal;
if (TangentLen < 1e-4 || dot(RawXY, RawXY) > 1.0)
{
    BumpNormal = N;
}
else
{
    // 注意：这里没有处理镜像 UV 的副切线符号翻转（UE 标准节点不直接暴露 Tangent 符号位）。
    // 对称结构如果两侧共用镜像 UV，镜像那一半的凹凸方向可能会反过来；
    // 常见做法是美术在镜像部分手动翻转法线贴图的 G 通道来配合，或者干脆不用镜像 UV。
    float3 T = WorldTangent / TangentLen;
    T = normalize(T - N * dot(N, T));  // Gram-Schmidt 正交化，防止插值/非均匀缩放导致 T 偏离切平面
    float3 B = cross(N, T);
    float2 NormalXY = RawXY * NormalMapIntensity;       // 0=完全平坦，1=贴图原始强度
    float NormalZ   = sqrt(saturate(1.0 - dot(NormalXY, NormalXY)));  // 重建 Z，保证恒朝外
    BumpNormal = normalize(NormalXY.x * T + NormalXY.y * B + NormalZ * N);
}

// ---------- 基础光照衰减 ----------
// 用 BumpNormal（而不是主文件里的平滑 N）：本文件没有离散色带需要保护，
// 让阴影渐变响应法线贴图的石缝/砖缝/浮雕细节，观感更接近参考图的"绘画感"渲染
float NdotL      = dot(BumpNormal, L);
float LightAtten = NdotL * 0.5 + 0.5;  // [-1,1] → [0,1]

// ---------- Shadow Gradient（单一连续渐变，无离散色带，无贴图） ----------
// ShadowSoftness 语义和主文件的 ShadowSharpness 相反：这里越大越柔和/过渡越宽，
// 上限放宽到能覆盖 LightAtten 大半个 [0,1] 区间，做出真正连续的渐变而不是硬边
// 没有配套的渐变贴图，亮部直接用 (1,1,1) 白色（=不改变 BaseColorTex 原色），
// 只有暗部会按 ShadowColor 压色，等价于"阴影侧染色，亮侧保持底色"
float ShadowHalfWidth = lerp(0.02, 0.55, saturate(ShadowSoftness));
float ShadowMask = smoothstep(ShadowThreshold - ShadowHalfWidth,
                               ShadowThreshold + ShadowHalfWidth,
                               LightAtten);

float3 FinalTone = lerp(ShadowColor, float3(1.0, 1.0, 1.0), ShadowMask);
ResultColor *= saturate(FinalTone);

// ---------- 法线贴图微观明暗（整个向光面都响应，不局限于阴影分界线附近）----------
// 上面 ShadowMask 一旦离开自己的过渡带就会饱和到 0 或 1，BumpNormal 带来的
// NdotL 波动在那之后不会再影响 ShadowMask —— 也就是说石缝/砖缝的凹凸只有在
// 明暗分界线附近才看得出来，太阳完全照到的大片墙面反而是平的。
// 这里用"凹凸法线 vs 平滑法线"的 NdotL 差值做一次相对修正：差值本身正负都有，
// 以平滑表面为基准，凸起处比基准亮、凹陷处比基准暗，不会整体拉亮或拉暗。
// NormalMapIntensity=0 或没接法线贴图时 BumpNormal 退化成 N，差值恒为 0，
// 这一步自动变成无效果，不需要额外参数控制。
float FlatNdotL        = dot(N, L);
float BumpShadingDelta = NdotL - FlatNdotL;
ResultColor *= saturate(1.0 + BumpShadingDelta);

// ---------- ORM 贴图（R=AO, G=Roughness, B=Metallic，可整体开关） ----------
// UseORM = 0（默认）：完全跳过 ORMTexture 采样，AO/粗糙度/金属度全部不生效，
// 行为和没有这个功能完全一样，避免材质实例忘记绑贴图导致意外整体发黑。
// UseORM = 1：R 通道压暗基础色（AO）；G 通道驱动下面 Specular 段落的锐度/
// 强度衰减（Roughness）；B 通道既压低漫反射、又给 Specular 染色（Metallic）
// ——解决"一整栋楼共用一个材质实例时，石材哑光、鎏金光滑没法共存"的问题，
// 不需要拆成多个材质槽。
//
// 金属度为什么要压漫反射：真实金属几乎没有漫反射，颜色全靠高光/反射。
// 如果 Metallic 只接进 Specular 那个加法项，金属感就只有那一个小高光点
// 能看出来，受光面剩下的大片区域、以及整个背光面，金属和非金属会长得
// 一模一样——所以这里额外压低漫反射（MetalDiffuseAtten），让金属感能在
// 整个表面体现，不局限于高光范围。
float AODiffuse         = 1.0;
float MetalDiffuseAtten = 1.0;
float RoughExpScale      = 1.0;
float RoughIntScale      = 1.0;
float ORM_Metallic       = 0.0;
if (UseORM > 0.5)
{
    float3 ORMSample     = Texture2DSample(ORMTexture, ORMTextureSampler, UV).rgb;
    float ORM_AO         = ORMSample.r;
    float ORM_Roughness  = saturate(ORMSample.g);
    ORM_Metallic         = ORMSample.b;

    AODiffuse = lerp(1.0, ORM_AO, saturate(AOStrength));

    // 粗糙度 → 高光衰减。SmoothFactor = 1-Roughness：光滑=1、粗糙=0。
    // RoughExpScale 缩放高光指数（越粗糙指数越小 → 光斑越大越散）；
    // RoughIntScale 缩放高光强度（平方，让中高粗糙度更快趋于哑光）。
    // RoughnessInfluence=0 时两者恒为 1（即原高光，向后兼容）。
    float SmoothFactor = 1.0 - ORM_Roughness;
    RoughExpScale = lerp(1.0, SmoothFactor, saturate(RoughnessInfluence));
    RoughIntScale = lerp(1.0, SmoothFactor * SmoothFactor, saturate(RoughnessInfluence));

    // 漫反射压到 0.15 而不是 0：纯黑在这种偏卡通的渲染里容易看着像破图，
    // 留一点点底色更稳妥，视觉上金属感已经足够强
    MetalDiffuseAtten = lerp(1.0, 0.15, saturate(ORM_Metallic * MetallicStrength));
}
ResultColor *= AODiffuse * MetalDiffuseAtten;

// ---------- Rim Light ----------
// 宽度（RimWidth）/ 强度（RimIntensity）/ 渐变（RimGradient）三参数独立控制。
// 仍然用平滑的几何法线 N（不用 BumpNormal）——Rim 是大范围轮廓效果，
// 用带凹凸细节的法线会在轮廓边缘引入不需要的高频闪烁噪点。
float NdotV   = abs(dot(N, V));
float Fresnel = 1.0 - NdotV;   // 0=正对镜头，1=轮廓边缘

// RimWidth 越大，条带起点越往表面内侧推（从轮廓往中心扩展得越多）
float RimThreshold = 1.0 - saturate(RimWidth);
// RimGradient 越大，边界过渡越柔和
float RimEdgeHalfWidth = lerp(0.002, 0.3, saturate(RimGradient));

float RimMask = smoothstep(RimThreshold - RimEdgeHalfWidth, RimThreshold + RimEdgeHalfWidth, Fresnel);

// 朝光侧遮罩：只在表面朝向光源的那侧轮廓上出现边缘光（比如夕阳只照亮背光柱子
// 靠光源那一侧的边缘），背光侧自然过渡到 0——不再有旧版 0.6 保底。
// 用平滑 N 重新算 NdotL（不复用上面 BumpNormal 版的 NdotL），原因和 Fresnel
// 一致：Rim 是大范围轮廓效果，掺入法线贴图细节会在轮廓上引入高频噪点。
float RimNdotL     = dot(N, L);
float RimLightMask = saturate(RimNdotL);
float Rim = RimMask * RimLightMask * RimIntensity;
ResultColor += RimColor * Rim;

// ---------- Specular 高光（Blinn-Phong，纯参数驱动，跟随光源方向） ----------
// NdotH 用 BumpNormal，让法线贴图的凹凸细节能通过高光形状体现出来；
// ShadowMask 复用 Shadow Gradient 算出的连续遮蔽系数，让高光在阴影侧自然淡出
float3 H    = normalize(L + V);
float NdotH = saturate(dot(BumpNormal, H));

float SpecLightMask = smoothstep(SpecularThreshold, SpecularThreshold + max(0.001, SpecularSoftness), saturate(NdotL));
float SpecFalloff   = SpecLightMask * SpecLightMask;

// 粗糙度调制：指数用 RoughExpScale 变散、强度用 RoughIntScale 变弱（粗糙区几乎无高光）
float SpecPowerEff = max(1.0, SpecPower * RoughExpScale);
float Spec = pow(NdotH, SpecPowerEff) * ShadowMask * SpecFalloff * RoughIntScale;

// 金属度染色：金属反射自身颜色，把高光色从 SpecularColor 偏向底色 BaseAlbedo
float3 SpecTint = lerp(SpecularColor, BaseAlbedo, saturate(ORM_Metallic * MetallicStrength));
ResultColor += Spec * SpecularStrength * SpecTint;

// ---------- 自发光（窗户/灯笼等不受光照影响的光源） ----------
// EmissiveTexture 画出哪里是自己会发光的部分（窗户、灯笼、霓虹装饰等），
// 亮度不受 Shadow Gradient / AO / Rim / Specular 影响——夜景里灯光该亮多亮，
// 不管旁边石墙是被月光照到还是完全在阴影里，这是"自己发光"和"反射外部光"
// 的本质区别，所以这一项故意不乘 ShadowMask / AODiffuse。
// EmissiveTexture 未接或纯黑时这一项恒为 0，不影响不需要自发光的材质实例。
float3 EmissiveSample = Texture2DSample(EmissiveTexture, EmissiveTextureSampler, UV).rgb;
ResultColor += EmissiveSample * EmissiveColor * EmissiveIntensity;

// 曝光控制：统一缩放最终输出
// 值 > 1.0 时加法项（Rim/Spec/Emissive）溢出 HDR 范围，可驱动 Bloom
ResultColor *= ExposureScale;
return ResultColor;
