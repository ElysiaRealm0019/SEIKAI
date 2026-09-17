// MMD Toon Shader - UE5 Custom Node 直接粘贴版本
// 适用于 Unlit 材质模式，输出连接至 Emissive Color 引脚
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
// WorldTangent       Float3            VertexTangentWS 节点（模型切线，世界空间，法线贴图用）
// CameraVector       Float3            CameraDirectionVector 节点
// LightDirection     Float3            从场景指向光源的方向（见 Documentation/MMDToonShader_SM5_SingleFunc_使用文档.md）
// BaseColorTex       Texture2D         TextureObjectParameter（Base Colour 贴图）
// ToonTexture        Texture2D         TextureObjectParameter（Toon 渐变贴图，UseToonTexture=0 时
//                                       不会被采样，可以不接）
// MatcapTexture      Texture2D         TextureObjectParameter（Matcap 球面贴图）
// HairHighlightTexture Texture2D       TextureObjectParameter（头发高光贴图，UV 与 BaseColorTex 一致，
//                                       高光画在贴图哪里就出现在头发哪里，专为头发准备）
// NormalMapTex       Texture2D         TextureObjectParameter（切线空间法线贴图，标准 UE 格式，
//                                       只影响 Specular 高光形状和 Matcap 采样位置，见下方原理说明）
// BaseTint           Float3            色调颜色  默认（1.0, 1.0, 1.0）无色偏
// TintIntensity      Float1            色调混合强度  默认 0.0（0=不改变, 1=完全应用色调）
// TintMode           Float1            色调模式  默认 0.0（0=Overlay混合, 1=乘法, 2=色相偏移）
// Saturation         Float1            饱和度  默认 1.0（1=不改变；>1 更鲜艳；<1 更灰；0=纯灰度。皮肤发白时可调高，如 1.2~1.5）
// UseToonTexture     Float1            Toon 贴图开关  默认 1.0（1=采样 ToonTexture 当亮部基础色；
//                                       0=不采样贴图，直接用 LitColor 当亮部基础色，ToonTexture 可留空。
//                                       没有配套渐变贴图的材质（常见于皮肤）应该显式设成 0，而不是让
//                                       ToonTexture 悬空吃默认贴图——那样等于亮部完全不参与调色，容易把
//                                       贴图里本来就偏亮的区域（比如额头高光）直接曝出来）
// LitColor           Float3            亮部基础色  默认（1.0, 1.0, 1.0）（仅 UseToonTexture=0 时生效；
//                                       发现亮部某块区域过亮/过曝，先检查是不是漏配 ToonTexture，
//                                       确认没有的话可以把这个调暗一点点来压一下亮部整体亮度）
// UseToonShading     Float1            Toon 风格化总开关  默认 1.0（1=正常走下面全部 Toon 处理；
//                                       0=直接跳过阴影分层/Rim/Specular/Matcap/头发高光，只输出
//                                       贴图色调+饱和度处理过的基础色叠加一个简单连续明暗，无分层
//                                       无硬边。某处出现异常发白/过曝/条带时可先切到 0 排查是不是
//                                       Toon 处理本身导致的；也可以当某个部件的应急保底显示）
// ShadowThreshold    Float1            深阴影起点 T1  默认 0.5（0~1，越大阴影越多）
// ShadowEnd          Float1            亮区起点 T3   默认 0.75（必须 > ShadowThreshold；T3 ≤ T1 时退化为单层）
// MidSplit           Float1            中间两层分配比 默认 0.60（W2/(W2+W3)；0=只剩 Shadow3，1=只剩 Shadow2）
// ShadowSharpness    Float1            阴影锋利度 默认 0.8（0~1，越大边缘越硬）
// ShadowColor        Float3            第一层阴影颜色  默认（0.2, 0.2, 0.4）深阴影
// Shadow2Color       Float3            第二层阴影颜色  默认（0.5, 0.5, 0.6）过渡色带
// Shadow3Color       Float3            第三层阴影颜色  默认（0.8, 0.8, 0.85）浅过渡色
// ShadowHueShift     Float1            三层阴影统一色相偏移（角度）  默认 0.0（等价于同时旋转三层
//                                       颜色 HSV 的 H 分量；正值/负值转向相反，转错方向就取负号）
// ShadowSaturation   Float1            三层阴影统一饱和度  默认 1.0（等价于同时调整三层颜色 HSV
//                                       的 S 分量；1=不变，>1 更鲜艳，<1 更灰，0=纯灰度）
// ShadowBrightness   Float1            三层阴影统一调亮/调暗  默认 1.0（等价于同时缩放三层颜色
//                                       HSV 的 V 分量，不影响色相/饱和度；>1 变亮，<1 变暗）
// RimWidth           Float1            Rim Light 条带宽度  默认 0.35（0~1，越大条带从轮廓往内扩展越多）
// RimGradient        Float1            Rim Light 边缘渐变  默认 0.15（0=硬边界，1=柔和渐变；越小越接近贴纸感硬边）
// RimColor           Float3            Rim Light 颜色+强度  默认（1.0, 1.0, 1.0）（白色=全强度，黑色=关闭）
// SpecPower          Float1            高光锐度  默认 32.0（越大光斑越小越锐利）
// SpecularThreshold  Float1            高光截断阈值  默认 0.3（NdotL 低于此值区域无高光）
// SpecularSoftness   Float1            高光截断过渡宽度  默认 0.05（越大过渡越柔和，越小越接近硬切换）
// SpecularColor      Float3            高光颜色+强度  默认（0.5, 0.5, 0.5）（白色=全强度，黑色=关闭）
// MatcapColor        Float3            Matcap 颜色+强度  默认（1.0, 1.0, 1.0）（白色=全强度，黑色=关闭；可调色温或染色）
// UseHairHighlightTexture Float1       头发高光模式  默认 1.0
//                                       1=采样 HairHighlightTexture 定位高光（美术画在哪就出现在哪）
//                                       0=不采样贴图，改用 Kajiya-Kay 各向异性程序化计算，
//                                         得到沿发丝方向拉长的光带；HairHighlightTexture 可留空。
//                                         没有高光贴图的头发材质应该显式设成 0——否则贴图悬空吃
//                                         默认纯白，高光形状退化成 Blinn-Phong 圆斑（塑料球感）
// HairHighlightColor     Float3        头发高光颜色+强度  默认（1.0, 1.0, 1.0）（白色=全强度，黑色=关闭）
//                                       ⚠ 设成纯黑等于关掉整个头发高光，与 UseHairHighlightTexture 选哪个模式无关
//                                       注：头发高光的"形状"（锐利度/截断角度）直接复用 SpecPower/
//                                       SpecularThreshold/SpecularSoftness，不再单独暴露一套，
//                                       减少动画/材质实例要维护的引脚数量
// NormalMapIntensity Float1            法线贴图强度  默认 1.0（0=完全平坦不生效，1=贴图原始强度，可 >1 夸张化）
// ExposureScale      Float1            整体曝光  默认 1.0（暗光环境下调低以避免发光感，>1 增强亮度）
// ----------------------------------------------------------------
// Output Type: CMOT Float3  →  连接至材质的 Emissive Color 引脚
// ================================================================
//
// ================================================================
// 参数分类：哪些适合做动画驱动，哪些建议只在材质实例里设一次
// ================================================================
// 注：LightDirection 不在下面任何一档里——它是蓝图从场景 DirectionalLight
// 读出来写进材质的场景数据，跟着光源自己走，不需要（也不应该）手动打关键帧。
//
// [✅ 适合逐帧驱动] "有多少"类——改变的是强度/整体调色，不是"长什么样"，
// 数值线性变化时观感也线性变化，插值不会跳变：
//   Saturation, TintIntensity, ShadowHueShift, ShadowSaturation, ShadowBrightness,
//   ExposureScale
//
// [🎯 需要时校准] 阴影位置——与光照强相关，随镜头/光源角度变化可能需要修正：
//   ShadowThreshold (T1)  深阴影起点
//   ShadowEnd        (T3)  亮区起点
//   这两个决定明暗交界线落在模型的哪个位置。光源角度变化时，交界线可能会
//   压到不好看的地方（典型如逆光时脸部大面积死黑、顶光时下半张脸全暗），
//   这时需要按镜头微调 T1/T3 把交界线推回合适的位置——所以它们既不是
//   "设一次就不动"，也不是常规的逐帧曲线，而是按需校准的一类。
//   （本项目的 AI 部分正是为此训练的：由 LdotV / L_up 预测 T1/T3 自动校准）
//   注意 MidSplit 不属于这一类：它只控制中间两层色带的相对宽度，与光照无关，
//   归美术一次性决定。
//
// [⚙️ 一次性设置] "这个材质长什么样"，美术调好就不用再碰：
//   形状：MidSplit, ShadowSharpness, RimWidth, RimGradient, SpecPower,
//     SpecularThreshold, SpecularSoftness, NormalMapIntensity
//   基础色板：BaseTint, ShadowColor, Shadow2Color, Shadow3Color, RimColor,
//     SpecularColor, MatcapColor, HairHighlightColor, LitColor
//     （需要统一改色走 ShadowHueShift/Saturation/Brightness 三个 HSV 参数，
//      比给三个色板各打一条曲线省事，且三层之间关系永远协调）
//     注：强度已合并到颜色中，通过颜色亮度控制（默认值已相应调整）
//
// [⛔ 不要做动画]
//   TintMode：内部用 round() 取整分档（0/1/2），两档之间打关键帧只会在中点
//     硬跳一下，不会平滑过渡——它是"选哪种混合模式"的开关，不是连续量。
//   UseToonTexture：代码里是 if (UseToonTexture > 0.5) 硬分支，0.49→0.51 会
//     瞬间从纯贴图采样跳到纯 LitColor，没有过渡态。这个应该在材质实例里按
//     "这个材质有没有配渐变贴图"一次性定好，不是拿来做动画的开关。
//   UseToonShading：同样是 if (UseToonShading < 0.5) 硬分支 + 提前 return，
//     0/1 之间没有中间态，切换瞬间从完整 Toon 效果跳到简单明暗。这是排查/
//     应急开关，不是动画参数。
//   UseHairHighlightTexture：硬分支，0/1 之间会在贴图定位高光和各向异性
//     程序化高光之间瞬间切换，两者形状完全不同，没有过渡态。按"这个头发材质
//     有没有配高光贴图"一次性定好。
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
// Saturation = 1：不改变；> 1：更鲜艳（可用于纠正贴图发白、发灰，如皮肤缺乏血色）；
// < 1：更接近灰度；= 0：完全去饱和
// 使用 Rec.709 亮度权重保持明度不变，只调整色彩鲜艳程度
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
// UseToonShading = 0：提前跳出，跳过下面全部 Toon 专属处理（阴影分层、Rim Light、
// Specular、Matcap、头发高光——以及它们都要用到的法线贴图采样），只保留贴图色调 +
// 饱和度处理过的基础色，乘一个不分层的连续明暗（LightAtten）。用来快速确认某处
// 异常（发白 / 过曝 / 硬边条带）是不是这套 Toon 处理本身造成的，或者作为某个
// 部件出问题时的应急保底显示。
if (UseToonShading < 0.5)
{
    ResultColor *= LightAtten;
    ResultColor *= ExposureScale;
    return ResultColor;
}

// ---------- 法线贴图（切线空间凹凸细节）----------
// 只用来生成 BumpNormal，供 Specular 高光形状和 Matcap 采样位置使用；
// Toon 阴影分层（LightAtten）和 Rim Light 的 Fresnel 仍然用平滑的几何法线 N —
// 这两处如果也吃细碎的法线贴图细节，大色块的卡通阴影/边缘光会变得破碎不干净，
// 不符合 Toon 渲染想要的"大平面色块"观感。如果确实需要阴影/Rim 也响应凹凸细节，
// 把对应位置的 N 换成 BumpNormal 即可。
// 采样并解包 XY（[0,1] → [-1,1]），Z 后面用 sqrt 重建，不直接读蓝通道 ——
// UE 的 Normalmap 压缩是 BC5，只存 R/G 两个通道；Custom 节点里直接采样的蓝通道
// 不可靠（常为 0），当作 Z 会得到 -1，使法线翻向内侧、高光跑到背面。
float2 RawXY     = Texture2DSample(NormalMapTex, NormalMapTexSampler, UV).rg * 2.0 - 1.0;
float TangentLen = length(WorldTangent);

// 两道回退到几何法线 N 的守卫，任一命中都退回 N（表现与未加法线贴图完全一致）：
//   守卫 1（切线无效）：WorldTangent 未连接 VertexTangentWS 时为 (0,0,0)，
//     normalize 会得到 NaN，而 saturate(dot(NaN, H)) 在部分 GPU 上返回 1 →
//     pow(1, SpecPower)=1 → 全表面满强度高光（"无论什么底色都被糊成一层白、无比光滑"）。
//     ★ 这一道才是"放入有效法线贴图后整体发亮"的真正拦截点，纹理检查拦不住。
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
    // 对称模型如果左右部位共用镜像 UV，镜像那一半的凹凸方向可能会反过来；
    // 常见做法是美术在镜像部分手动翻转法线贴图的 G 通道来配合，或者干脆不用镜像 UV。
    float3 T = WorldTangent / TangentLen;
    T = normalize(T - N * dot(N, T));  // Gram-Schmidt 正交化，防止插值/非均匀缩放导致 T 偏离切平面
    float3 B = cross(N, T);
    float2 NormalXY = RawXY * NormalMapIntensity;       // 0=完全平坦，1=贴图原始强度
    float NormalZ   = sqrt(saturate(1.0 - dot(NormalXY, NormalXY)));  // 重建 Z，保证恒朝外
    BumpNormal = normalize(NormalXY.x * T + NormalXY.y * B + NormalZ * N);
}

// ---------- Toon 阴影（最多三层） ----------
// 参数化：T1 = ShadowThreshold（深阴影起点）、T3 = ShadowEnd（亮区起点）
// MidSplit ∈ [0, 1] 控制 Shadow2 / Shadow3 两层的相对宽度（0.6 = W2 略宽，复刻原默认 0.15:0.10）
// 该参数化便于 AI 控制：T1 / T3 与光照强相关，MidSplit 与光照无关由美术决定
// ShadowSharpness 统一控制所有层边缘的过渡宽度
// saturate 防呆：ShadowSharpness 文档标注范围 0~1，但材质实例里手滑填成负数
// （实测踩过：某材质被填成 -5.94）会让 EdgeHalfWidth 变成 0.335，
// smoothstep 下界跑到负数区间、最深阴影永远到不了满值，且下面两道色带宽度守卫
// 永远不通过，中间两层被静默跳过——症状很像"阴影参数失灵"，但没有任何报错。
float EdgeHalfWidth = lerp(0.05, 0.002, saturate(ShadowSharpness));

// AI 输出 → shader 内部三参数还原
float T1 = ShadowThreshold;
// 强制预留 0.05 的最小色带宽度。
// 防止用户在材质中手动调高 ShadowThreshold 时追上 ShadowEnd 导致色带消失。
//
// ★ 注意 T1 / T3 是两个独立的绝对坐标，不是"起点 + 宽度"：
//   只要 ShadowThreshold < ShadowEnd - 0.05，max() 恒选中 ShadowEnd，
//   T3 就完全不受 ShadowThreshold 影响。调 ShadowThreshold 只会从下方
//   挤宽/挤窄中间两层，Shadow3 与亮部之间那道边界纹丝不动。
//   要移动亮部交界线，调的是 ShadowEnd —— 这一点很反直觉，实际调参时
//   会表现为"Shadow3 不受 ShadowThreshold 控制"，已经踩过一次。
float T3 = max(T1 + 0.05, ShadowEnd);
float BandTotal   = T3 - T1;
float Shadow2Width = saturate(MidSplit) * BandTotal;
float Shadow3Width = (1.0 - saturate(MidSplit)) * BandTotal;
float T2 = T1 + Shadow2Width;

float Layer1Mask = smoothstep(T1 - EdgeHalfWidth, T1 + EdgeHalfWidth, LightAtten);
float Layer2Mask = smoothstep(T2 - EdgeHalfWidth, T2 + EdgeHalfWidth, LightAtten);
float Layer3Mask = smoothstep(T3 - EdgeHalfWidth, T3 + EdgeHalfWidth, LightAtten);

float ShadowMask = Layer1Mask;  // 供后续高光 / Rim 遮蔽使用

// UseToonTexture=0：不采样 ToonTexture，直接用 LitColor 当亮部基础色——
// 显式声明"这个材质没有渐变贴图"，而不是让 ToonTexture 悬空、隐性吃默认贴图。
// 之前踩过的坑：悬空时默认贴图是纯白，等价于亮部完全不参与调色，直接把
// BaseColorTex 里偏亮的区域（比如额头）原样曝出来，很容易被误认成"发光"。
float3 ToonSample = (UseToonTexture > 0.5)
    ? Texture2DSample(ToonTexture, ToonTextureSampler, float2(LightAtten, 0.5)).rgb
    : LitColor;

// ---------- 阴影颜色统一调整（H / S / V，三层颜色共用一组参数）----------
// V（ShadowBrightness）：HSV 的 V = max(R,G,B)，H 和 S 只描述三个通道之间的相对比例，
//   与整体缩放无关；给 RGB 同时乘一个正数 k，H、S 数学上完全不变，V 精确变成 k 倍，
//   所以直接乘系数即可，不需要真的转换到 HSV。
// H（ShadowHueShift，角度）：色相旋转在数学上等价于在 RGB 空间绕灰轴 (1,1,1) 旋转
//   同样的角度（Hue 本来就是绕这条轴的角度），用旋转矩阵直接对 RGB 做变换，
//   同样不需要转换到 HSV 再转回来。如果转向反了，把角度取负号即可。
// S（ShadowSaturation）：复用文件开头整体 Saturation 参数同一种"向亮度插值"手法。
// 三层颜色共用同一个 H/S/V，避免每层单独调导致互相不协调。
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

// Toon 贴图为基础，从亮部往阴影方向逐层覆盖色带
// BandTotal = 0（T3 ≤ T1）时 W2 = W3 = 0，退化为 lerp(ShadowColorAdj, ToonSample, Layer1Mask) 单层 toon
// MidSplit = 0 → W2 = 0，跳过 Shadow2ColorAdj；MidSplit = 1 → W3 = 0，跳过 Shadow3ColorAdj
// 色带宽度不足时的淡出因子：色带比自身边缘过渡还窄时，Layer2/Layer3 两条
// smoothstep 斜坡会互相重叠、算出没意义的中间色，所以要把这一层撤掉。
// ★ 这里必须是连续淡出，不能用 if 硬判断（旧版本的写法）：
//   Shadow3Width = (1-MidSplit) * (T3 - T1) 是随 ShadowThreshold 连续变化的量，
//   而 ShadowThreshold 是挂在 Sequencer 上做动画的。用 if 的话，曲线扫过临界宽度
//   的那一帧整层色带会凭空消失，该区域瞬间从阴影色跳到亮部色（实测 3 倍亮度突变）。
//   改成 smoothstep 后，色带变窄时是"逐渐融回上一层"，动画过程中无跳变。
float BandGuard  = EdgeHalfWidth * 2.0 + 0.001;
float Band3Fade  = smoothstep(0.0, BandGuard, Shadow3Width);
float Band2Fade  = smoothstep(0.0, BandGuard, Shadow2Width);

float3 FinalToon = ToonSample;
FinalToon = lerp(FinalToon, lerp(Shadow3ColorAdj, FinalToon, Layer3Mask), Band3Fade);
FinalToon = lerp(FinalToon, lerp(Shadow2ColorAdj, FinalToon, Layer2Mask), Band2Fade);
FinalToon = lerp(ShadowColorAdj, FinalToon, Layer1Mask);
ResultColor *= saturate(FinalToon);

// ---------- Rim Light ----------
// 宽度（RimWidth）/ 强度（RimIntensity）/ 渐变（RimGradient）三参数独立控制，
// 替代原来单一 RimPower 把"条带宽窄"和"边缘软硬"耦合在一个指数里、没法分开调的问题
float NdotV   = abs(dot(N, V));
float Fresnel = 1.0 - NdotV;   // 0=正对镜头，1=轮廓边缘

// RimWidth 越大，条带起点越往表面内侧推（从轮廓往中心扩展得越多）
float RimThreshold = 1.0 - saturate(RimWidth);
// RimGradient 越大，边界过渡越柔和；越小越接近参考图那种硬边界
float RimEdgeHalfWidth = lerp(0.002, 0.3, saturate(RimGradient));

float RimMask = smoothstep(RimThreshold - RimEdgeHalfWidth, RimThreshold + RimEdgeHalfWidth, Fresnel);

// 朝光侧遮罩：复用上面"基础光照衰减"已经算好的 NdotL（同一个 N），
// 只在表面朝向光源的那侧轮廓上出现边缘光，背光侧自然过渡到 0——
// 不再有旧版 0.6 保底（旧版无论光源在哪都至少 60% 强度，关不掉）。
// NdotL 本身是绕轮廓连续变化的量，不需要额外 smoothstep 就已经是平滑过渡。
float RimLightMask = saturate(NdotL);
float Rim = RimMask * RimLightMask * ShadowMask;
ResultColor += RimColor * Rim;

// ---------- Specular 高光（Blinn-Phong，纯参数驱动，跟随光源方向）----------
// 与 Matcap 的区别：Specular 随光源角度变化；Matcap 随相机角度变化
// SpecPower 越大光斑越小越锐利（类似镜面反射）
// NdotL 低于 SpecularThreshold 的区域被硬截断，无高光
// NdotH 用 BumpNormal（而不是平滑的 N），这样法线贴图的凹凸细节能通过高光形状体现出来
float3 H    = normalize(L + V);
float NdotH = saturate(dot(BumpNormal, H));

float SpecLightMask = smoothstep(SpecularThreshold, SpecularThreshold + max(0.001, SpecularSoftness), saturate(NdotL));
float SpecFalloff   = SpecLightMask * SpecLightMask;

// 拆成"形状"和"遮蔽"两部分：头发高光要复用遮蔽，但可能需要替换形状
float SpecShape = pow(NdotH, max(1.0, SpecPower));   // 各向同性圆斑（绕法线）
float SpecMask  = ShadowMask * SpecFalloff;          // 阴影区 / 背光区遮蔽

float Spec = SpecShape * SpecMask;
ResultColor += Spec * SpecularColor;

// ---------- 头发高光（两种模式）----------
// UseHairHighlightTexture = 1（贴图定位，默认）：
//   用和 BaseColorTex 完全相同的 UV 采样 HairHighlightTexture —— 美术在头发贴图上
//   画好高光带，画在哪里就出现在哪里。形状复用上面的 SpecShape（同一套 SpecPower/
//   SpecularThreshold/SpecularSoftness），头发和身体共用锐利度/截断角度。
//
// UseHairHighlightTexture = 0（程序化计算，没有高光贴图时用）：
//   改用 Kajiya-Kay 各向异性高光，不采样贴图（HairHighlightTexture 可以留空不接）。
//   ★ 为什么不直接复用 SpecShape：Blinn-Phong 是绕法线的**圆形**光斑，糊在头发上
//     像一颗塑料球；而头发高光的特征形状是一条**垂直于发丝、沿发流拉长的光带**。
//     做法是让发丝切线 T 代替法线参与计算 —— H 越垂直于发丝（TdotH 越接近 0）越亮，
//     于是高光自然沿着发流方向铺开成带状。
//   ★ 这条路径下**不能再乘 SpecShape**：各向异性光带 × 各向同性圆斑 = 双重收窄，
//     高光会缩成一个点，各向异性就白做了。所以下面是用 HairShape 替换而非相乘。
//
// 两种模式共用 SpecMask（阴影/背光遮蔽）和 HairHighlightColor / HairHighlightIntensity。
float3 HairTint;
float  HairShape;

if (UseHairHighlightTexture > 0.5)
{
    HairTint  = Texture2DSample(HairHighlightTexture, HairHighlightTextureSampler, UV).rgb;
    HairShape = SpecShape;
}
else if (TangentLen > 1e-4)
{
    // 发丝方向 = 模型切线。头发建模时 UV 的 U 方向通常就是发流方向，
    // 所以 VertexTangentWS 天然对齐发丝，不需要额外的方向贴图。
    float3 HairT = WorldTangent / TangentLen;
    float  TdotH = dot(HairT, H);
    float  SinTH = sqrt(saturate(1.0 - TdotH * TdotH));  // H 与发丝夹角的正弦
    HairTint  = float3(1.0, 1.0, 1.0);
    HairShape = pow(SinTH, max(1.0, SpecPower));
}
else
{
    // WorldTangent 没接 VertexTangentWS → 算不出发丝方向，退回各向同性圆斑。
    // 表现等同于「第二层可独立调色调强度的 Specular」，不会变黑或报错。
    HairTint  = float3(1.0, 1.0, 1.0);
    HairShape = SpecShape;
}

ResultColor += HairTint * HairHighlightColor * HairShape * SpecMask;

// ---------- Matcap 球面贴图 ----------
// 使用视角空间法线 XY 作为 UV，随视角变化自动更新高光位置
// UE5 世界空间 Z 轴朝上
//
// 修复：旧版本在 CamDir 与 WorldUp 对齐时使用硬切换（< 0.99 阈值），
// 导致旋转经过头顶时高光瞬间跳变。新版本使用两组参考轴的平滑混合，
// 通过 smoothstep 在极点附近连续过渡，消除所有角度的不连续性。
float3 CamDir   = normalize(CameraVector);

// 参考轴 A：以世界 Z 为"上"（常规视角）
float3 RefUpA   = float3(0.0, 0.0, 1.0);
// 参考轴 B：以世界 Y 为"上"（俯视/仰视极点区域）
float3 RefUpB   = float3(0.0, 1.0, 0.0);

// 计算 CamDir 与两组参考轴的对齐程度
float AlignA    = abs(dot(CamDir, RefUpA));  // 接近 1.0 = 极点退化

// 平滑混合因子：AlignA 在 [0.85, 0.99] 区间从 0 过渡到 1
// 使用 smoothstep 确保混合曲线 C1 连续（无跳变、无突变导数）
float BlendFactor = smoothstep(0.85, 0.99, AlignA);

// 分别用两组参考轴构建正交基（只需要 Right，Up 最终会用 CamRight 重新正交化算出）
float3 RightA   = normalize(cross(RefUpA, CamDir));
float3 RightB   = normalize(cross(RefUpB, CamDir));

// 平滑混合两组基向量，然后重新正交化
float3 CamRight = normalize(lerp(RightA, RightB, BlendFactor));
float3 CamUp    = normalize(cross(CamDir, CamRight));

// 用 BumpNormal 而不是 N，让法线贴图的凹凸细节也能体现在 Matcap 反射的采样位置上
float2 MatcapUV;
MatcapUV.x = dot(BumpNormal, CamRight) * 0.5 + 0.5;
MatcapUV.y = dot(BumpNormal, CamUp)    * 0.5 + 0.5;

// MatcapColor 可调整 Matcap 高光的颜色倾向（默认白色=不改变贴图颜色）
// 冷色调高光：(0.8, 0.9, 1.0)；暖色调：(1.0, 0.9, 0.8)
float3 MatcapSample = Texture2DSample(MatcapTexture, MatcapTextureSampler, MatcapUV).rgb;
float MatcapMask    = ShadowMask;  // 使用 ShadowMask 遮蔽，防止在阴影区亮起
ResultColor += MatcapSample * MatcapColor * MatcapMask;

// 曝光控制：统一缩放最终输出
// ExposureScale 由 AI 多项式输出，根据 LdotV / L_up 自适应
// （旧版的 (0.6+0.4*AmbientLevel) 因子与 ExposureScale 功能重复，已移除）
// 值 > 1.0 时加法项（Rim/Spec/Matcap）溢出 HDR 范围，可驱动 Bloom
ResultColor *= ExposureScale;
return ResultColor;
