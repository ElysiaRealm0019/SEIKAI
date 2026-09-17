// MMD Toon Outline Shader - Post Process 抗抖动版
// UE5 Custom Node 直接粘贴，放在 Post Process 材质中
//
// 与 MMDToonShader_SM5_Outline.hlsl（八方向阈值判边版）的区别：
//   旧版用「相邻像素深度差 > 阈值」判断边缘，本质是二值判断 —— 轮廓在像素之间
//   移动半个像素，某个像素就会整个翻转成描边或整个消失，表现为爬行/闪烁。
//   本版改为「圆盘覆盖率超采样」：统计一圈采样点里有多少落在角色上，得到一个
//   连续的 0~1 覆盖率，描边强度直接由覆盖率决定 —— 轮廓移动半个像素时，
//   变化的是描边的不透明度而不是"有没有描边"，天然带亚像素抗锯齿。
//
// ================================================================
// ★★★ 第一步：关掉 CustomDepth 的 TAA 抖动（不做这步，后面全白搭）★★★
// ================================================================
// 控制台 / DefaultEngine.ini 里设置：
//
//     r.CustomDepthTemporalAAJitter 0
//
// 写进 Config/DefaultEngine.ini 让它常驻：
//     [/Script/Engine.RendererSettings]
//     r.CustomDepthTemporalAAJitter=0
//
// 为什么这是抖动的头号来源：
//   后处理材质（无论挂在哪个 Blendable Location）都运行在 TAA/TSR 解析**之后**，
//   此时 SceneColor 已经是稳定的合成结果。但 CustomDepth 缓冲默认是**带 TAA 抖动**
//   渲染的 —— 每帧投影矩阵会做亚像素偏移，所以角色在 CustomDepth 里的轮廓每帧
//   都在 ±0.5 像素范围内左右横跳，而 SceneColor 不动。拿抖动的深度去给不抖动的
//   画面描边，结果就是描边自己在抖。
//   这个 CVar 会让 CustomDepth Pass 用未抖动的投影矩阵渲染，两者对齐，抖动消失。
//
//   ⚠️ 如果你之前用过「手动减 View.TemporalAAJitter 补偿 UV」的做法（旧版
//      MMDToonShader_SM5_Outline.hlsl 的 StableUV 步骤），开了这个 CVar 之后
//      必须把那一步**删掉**——CustomDepth 已经不抖了，再减一次 jitter 反而会
//      引入一个固定的半像素错位，描边会整体偏向一侧。
//
// ================================================================
// 材质编辑器配置
// ================================================================
//   Material Domain     Post Process
//   Blendable Location  Before Tonemapping
//                       （描边会参与 DOF / Bloom / 调色，跟画面融为一体。
//                        选 After Tonemapping 的话颜色更可控，但描边不吃景深，
//                        虚焦的角色也会带一圈死锐的线，反而更显脏）
//   Custom Node 输出    CMOT Float3 → Emissive Color
//
// ================================================================
// Project Settings
// ================================================================
//   Edit → Project Settings → Rendering
//   → Custom Depth-Stencil Pass：Enabled（本 shader 不需要 Stencil）
//
// ================================================================
// 角色配置
// ================================================================
//   角色的 Mesh Component → Details → Rendering
//   → Render CustomDepth Pass：勾选
//
//   GeometryCacheComponent（Alembic/.abc 角色）同样支持这个选项，
//   不像 Overlay Material 那样只在 UMeshComponent 上才有 —— 这也是
//   ABC 驱动的角色更适合走后处理描边、而不是 Inverted Hull 的原因。
//
// ================================================================
// Post Process Volume
// ================================================================
//   勾选 Infinite Extent (Unbound)
//   Rendering Features → Post Process Materials → 添加此材质
//
// ================================================================
// 材质图连接（只需要 3 个 SceneTexture 节点，不是旧版的 10 个）
// ================================================================
// 环形采样在 Custom 节点内部用 SceneTextureLookup() 完成，不需要在材质图里
// 手动摆一堆偏移 UV 和 SceneTexture 节点。但**必须**在图里保留下面三个
// SceneTexture 节点并接进 Custom 节点 —— 它们的作用有两个：提供中心像素的值，
// 以及告诉 UE「这个材质要用这几张 SceneTexture」，好让引擎把对应的资源绑定
// 建立起来。如果不接，SceneTextureLookup 会取到空数据（不报错，画面全黑或无描边）。
//
//   [TextureCoordinate 0]                        → UV
//   [SceneTexture: PostProcessInput0] → InvSize  → TexelSize
//   [SceneTexture: PostProcessInput0] → Color    → SceneColor
//   [SceneTexture: CustomDepth]       → Color(R) → CustomDepthC
//   [SceneTexture: SceneDepth]        → Color(R) → SceneDepthC
//   （PostProcessInput0 的 Color 和 InvSize 可以来自同一个节点的两个输出）
//
// ================================================================
// Custom Node 输入配置
// ================================================================
// 名称               类型      连接来源 / 默认值
// ----------------------------------------------------------------
// UV                 Float2    TextureCoordinate（Index 0）
// TexelSize          Float2    SceneTexture(PostProcessInput0) → InvSize
//                              ⚠️ 当前版本代码里**没有使用**这个引脚：偏移量改用
//                              View.BufferSizeAndInvSize.zw（场景缓冲纹素尺寸），
//                              原因见代码内注释。保留引脚不影响编译，想清理可在
//                              Details 面板删掉。
// SceneColor         Float3    SceneTexture(PostProcessInput0) → Color
// CustomDepthC       Float1    SceneTexture(CustomDepth) → Color 的 R 通道
// SceneDepthC        Float1    SceneTexture(SceneDepth)  → Color 的 R 通道
// OutlineColor       Float3    描边颜色  默认（0.04, 0.035, 0.05）接近黑但不死黑
// OutlineOpacity     Float1    描边不透明度  默认 1.0（0=完全关闭）
// OutlineWidth       Float1    采样盘半径【像素】  默认 2.5
//                              ★ 这是唯一以像素为单位的宽度参数。想要更粗的线调它。
//                              实际线宽 ≈ OutlineWidth × 0.9（默认 Thickness/Softness 下）
// OutlineThickness   Float1    线宽占采样盘的【比例 0~1】  默认 0.55
//                              ⚠️⚠️ 不是像素！代码里 clamp(…, 0.02, 1.0)。
//                              实测踩过的坑：当成像素数填了 20.87 → 被 clamp 到 1.0，
//                              再配上 OutlineSoftness=1，公式退化成
//                                  Silhouette = 1 - smoothstep(0, 1, Dist)
//                              变成从轮廓一路平滑衰减到采样盘边缘的渐变 ——
//                              **看起来是一圈光晕而不是描边**。
//                              命名教训：OutlineWidth（像素）和 OutlineThickness（比例）
//                              两个都像"宽度"却是不同单位，很容易填错。
//                              想要粗线请调 OutlineWidth，别动这个。
// OutlineSoftness    Float1    线的边缘渐变【比例 0~1】  默认 0.45（0=硬边，1=完全羽化）
//                              ⚠️ 不要设成 0：这是亚像素抗锯齿的过渡带，
//                                设 0 等于把好不容易算出来的连续覆盖率又二值化回去，
//                                抖动会原样回来。想要锐利感用 0.25~0.3，别用 0。
//                              ⚠️ 也不要设成 1：配合 Thickness=1 就是上面那个光晕退化。
// OutlineBias        Float1    线相对轮廓的位置  默认 0.5
//                              0.5=骑在轮廓上（内外各占一半，最接近 Inverted Hull 观感）
//                              <0.5 往外推（不啃角色，但会略微放大剪影）
//                              >0.5 往内收（不改变剪影，但会吃掉角色边缘细节）
// InteriorStrength   Float1    内部线强度  默认 1.0（0=只画外轮廓，不画内部结构线）
// InteriorWidth      Float1    内部线检测半径（像素）  默认 1.0
// InteriorThreshold  Float1    内部线灵敏度  默认 0.004（越小越敏感，越容易出杂线）
// OcclusionBias      Float1    遮挡判定容差（厘米）  默认 2.0
// FadeStart          Float1    描边开始随距离淡出的距离（厘米）  默认 4000
// FadeEnd            Float1    描边完全消失的距离（厘米）  默认 15000
// TintByScene        Float1    描边是否吃画面底色  默认 0.0
//                              0=纯 OutlineColor（干净的墨线，推荐）
//                              1=OutlineColor × 画面颜色（旧版行为，暗部描边会更隐蔽）
// ----------------------------------------------------------------
// Output Type: CMOT Float3  →  Emissive Color 引脚
// ================================================================
//
// ================================================================
// 抗抖动的七道措施（按重要性排序）
// ================================================================
// 1. r.CustomDepthTemporalAAJitter=0        ← 见文件开头，不做这步其余全白搭
// 2. 覆盖率超采样代替阈值判边                 ← 本 shader 的核心改动
//      16 个采样点求平均得到连续覆盖率，轮廓移动半像素时改变的是不透明度
//      而不是"有没有边"。想进一步压残留爬行，重算一组 32 点的 Vogel 常量
//      替换代码里那 16 行 MMD_TAP（不能改成 for 循环，原因见代码内注释）。
//      生成常量的脚本：
//        import math
//        N = 32
//        for i in range(N):
//            a = i * 2.39996323
//            r = math.sqrt((i + 0.5) / N)
//            print(f"MMD_TAP(float2({math.cos(a)*r:+.6f}, {math.sin(a)*r:+.6f}));")
//      记得同步把代码末尾的 Coverage /= 16.0 改成对应点数。
// 3. 全流程没有任何硬判断
//      所有 0/1 判定（遮挡、淡出、线宽）都走 smoothstep，没有一处 if / step
//      作用在连续变化量上。硬判断 = 某帧突然翻转 = 抖动。
// 4. 内部线用二阶差分而非一阶
//      一阶深度差在掠射角地面/大腿侧面这种"深度变化快但不是边缘"的地方会误判，
//      而且误判与否随视角连续变化 → 闪烁。二阶差分（dL + dR - 2*dC）对匀速倾斜
//      的表面恒为 0，只在真正的深度断裂处出尖峰，从根上消掉这类误检。
// 5. 深度归一化
//      内部线阈值除以中心深度，远近处灵敏度一致，镜头推拉时描边不会忽有忽无。
// 6. 默认恒定屏幕线宽
//      线宽不随距离变化（没有 WidthDistanceFalloff 之类的参数），采样图案每帧
//      完全一致。线宽如果逐帧连续变化，采样点会不断跨越轮廓，本身就是抖动源。
// 7. 最终出片时开 MRQ 时域采样                ← 这一步能把残留抖动清干净
//      Movie Render Queue → Anti-aliasing → Temporal Sample Count 设 8~16。
//      MRQ 会用亚像素抖动渲多个子帧再累加，**后处理材质每个子帧都会跑一遍**，
//      所以描边也会被一起超采样。这是渲染管线层面的解决，比 shader 里怎么调都彻底。
//      （Spatial Sample Count 同理，但更吃显存；一般优先加 Temporal）
//      注意：开了 MRQ 时域采样后，上面第 1 条依然要做 —— 时域采样解决的是
//      "描边边缘的锯齿"，CustomDepth 抖动造成的是"描边整体位置在动"，两回事。
//
// ================================================================

// ==================== PASTE START ====================

// ================================================================
// ★★★ 采样必须手工展开，不能用 for + [unroll] ★★★
// ================================================================
// 实测 UE 5.6 / SM6（DX12）下，[unroll] 循环里调 SceneTextureLookup 会让
// DXIL 验证失败：
//   PostProcessMaterialShaders.dxil: error: Instructions should not read uninitialized value
// 单次调用 SceneTextureLookup 完全没问题，问题只在循环展开时出现——
// 推测是 SceneTextureLookup 内部的 switch 在被内联 N 次后，DXC 无法证明
// 返回值的所有分支都已初始化。
//
// ⚠️ 这个坑最恶心的地方在于失败方式：材质编译失败后 UE **静默回退到
//    Default Material**，后处理输出直接全黑，而材质编辑器里不显示任何错误。
//    只有翻 Output Log 才能看到 "Failed to compile Material ...
//    Default Material will be used in game"。第一次遇到很容易误以为是
//    描边参数调错了或者 CustomDepth 没开。
//
// 下面 16 个偏移量是 Vogel 螺旋（黄金角）预先算好的常量，等价于原来的
//   Ang = i * 2.39996323;  Rad = sqrt((i + 0.5) / 16)
//   offset = float2(cos(Ang), sin(Ang)) * Rad
// sqrt 是为了让采样点在圆盘内**面积均匀**分布（不做 sqrt 会向圆心聚集，
// 等于给近处加权，覆盖率就不再正比于面积，线宽会失真）。
// Vogel 螺旋比同心圆环分布均匀得多，同样点数下覆盖率的量化台阶更细，
// 且没有环状规律图案（规律图案在轮廓扫过时会产生周期性摩尔纹）。
//
// 要提高采样数压残留爬行：按上方公式重新算一组常量，替换下面这 16 行即可。
//
// ================================================================
// ★★★ 手动调 SceneTextureLookup 必须先做 ViewportUV → SceneTextureUV 转换 ★★★
// ================================================================
// 材质图里的 SceneTexture 节点会**自动**把 ViewportUV 转成对应缓冲的 UV 再采样；
// 在 Custom 节点里手动调 SceneTextureLookup 则不会。直接把 TexCoord[0]
// （ViewportUV）传进去，所有采样点会整体错位。
//
// 开了 TSR 的项目错位尤其明显：后处理跑在**输出分辨率**，而 SceneDepth /
// CustomDepth 缓冲在**渲染分辨率**，两者的 UV 映射根本不是一个空间。
// 即使不开 TSR，UE 的场景缓冲通常也比视口大（向上取整分配），ViewportUV
// 直接当 BufferUV 用会产生一个从左上角起算的缩放偏差。
//
// ⚠️ 典型症状：描边整体偏移 / 缩放，但**中心像素是对的** —— 因为中心值
//    （CustomDepthC / SceneDepthC / SceneColor）走的是材质图节点，转换过了；
//    只有环形采样走手动调用，没转换。这个"中心对、周围偏"的特征是判断
//    这个 bug 的关键线索。
// ================================================================
// 未写入 CustomDepth 的像素会返回远裁面（量级 1e7），用这个阈值区分"是不是角色"
// 场景尺度超过 10km 时需要调大
#define MMD_MASK_FAR  1.0e6

// SceneTextureId: 1 = SceneDepth, 13 = CustomDepth, 14 = PostProcessInput0
// 采样前夹住 UV：不夹的话屏幕边缘的采样会落到视口矩形之外，读到相邻区域的
// 垃圾深度，在画面四边产生假描边。夹住等于边缘复制，角色被画面切掉时
// 覆盖率保持连续，不会在切边处凭空冒出一条线。
// 遮挡判定的**相对**偏置（占深度的比例）。纯绝对偏置（厘米）在远处太严、
// 相对偏置能吸收光栅化错位和自遮挡量级的差异。
// 降低到 0.005（0.5%）以防止描边穿透距离角色很近的未开启 CustomDepth 的装饰物。
#define MMD_OCC_REL   0.005

#define MMD_CD(uv)    SceneTextureLookup(clamp((uv), STUVMin, STUVMax), 13, false).r
#define MMD_SD(uv)    SceneTextureLookup(clamp((uv), STUVMin, STUVMax),  1, false).r
// 二值遮罩，但注意：它只用在"单个采样点算不算角色"上，
// 后面所有对外输出的量都是这些二值结果的**平均**，因此整体仍是连续的
#define MMD_MASKED(d) ((((d) > 0.0) && ((d) < MMD_MASK_FAR)) ? 1.0 : 0.0)
// 每个采样点分开统计三个量，★ 绝不相乘（原因见下面第 3 条约束）：
//   MaskedCount  = 是不是角色（只看 CustomDepth，决定覆盖率 / 线形）
//   VisCount     = 其中确实没被挡住的（只用于算比例，不影响线形）
//   BlockerCount = 非角色但深度比角色更近的前景遮挡物采样点
//     ★ 这是本版新增的关键计数器，用于解决"描边穿过装饰物"的问题。
//     原理：当采样盘扫到的像素既不在角色上（无 CustomDepth），又比角色更近
//     （SceneDepth < 角色的 MinMaskedDepth），说明该像素属于前景遮挡物。
//     如果这类像素占比过高，说明描边正在试图穿过/跨越一个不透明装饰物，
//     应该被抑制。
#define MMD_TAP(o) { \
    float2 U_ = BaseUV + (o) * DiscR; \
    float D_ = MMD_CD(U_); \
    float S_ = MMD_SD(U_); \
    float M_ = MMD_MASKED(D_); \
    MaskedCount += M_; \
    VisCount += M_ * step(D_, S_ + OccBias + D_ * MMD_OCC_REL); \
    MinMaskedDepth = min(MinMaskedDepth, lerp(1.0e9, D_, M_)); \
    BlockerCount += (1.0 - M_) * step(S_ + 1.0, RefCharDepth); \
}

// ================================================================
// ★★★ 遮挡判定的结果绝不能直接乘进覆盖率 ★★★
// ================================================================
// 先说为什么需要遮挡判定：CustomDepth 是**独立 pass**，角色被地形挡住时
// 照样会写入，所以光看 CustomDepth 根本分不清"露出来的角色"和"藏在山后的
// 角色"，描边会穿过地形漏出来。
//
// 但把 step() 硬判断**直接乘进逐点覆盖率**（曾经这么写过）会引入新 bug：
// CustomDepth 和 SceneDepth 是两次独立光栅化，同一纹素上不保证严格相等：
//   - 开了 r.CustomDepthTemporalAAJitter=0 后（本文件开头要求的那条），
//     CustomDepth 用不抖动投影、主深度 pass 用抖动投影，两者天然错开半像素；
//   - 在角色**内部的深度断裂处**（裙子压腿、两腿之间、头发压肩），半像素
//     错位会让纹素在近面/远面之间翻转，深度差直接是整个自遮挡量（几十厘米）。
// 于是零星采样点被误判成"被遮挡"，角色内部的覆盖率从 1.0 掉到 0.75，
// Dist 跌进线带 → **画面上冒出黑色斑点**。硬判断的噪声被原样放大了。
//
// 正确做法（当前版本）：覆盖率只看 CustomDepth（干净、无精度噪声）；
// 可见性单独统计成"可见采样点 / 角色采样点"的比例，再过一层 smoothstep。
//   16 点里误判 2 个 → VisibleFrac = 0.875 → Occlusion = 1，斑点消失
//   角色整片被地形挡住 → VisibleFrac = 0   → Occlusion = 0，照样剔除
// 平均 + smoothstep 把逐点硬判断的噪声吃掉了，只保留大尺度的遮挡信号。
//
// → 因此**不需要给地形/场景物件开 CustomDepth**，SceneDepth 本来就包含它们。
//
// ⚠ 前提：角色材质必须是 Opaque 或 Masked（会写 SceneDepth）。
//   Translucent 的部件（比如半透明头发）不写 SceneDepth，会被判成"被遮挡"
//   而完全没有描边 —— 那类部件只能改走 Inverted Hull 方案。
//
// ================================================================
// ★★★ 前景遮挡物抑制（BlockerSuppression）★★★
// ================================================================
// 上面的 Occlusion 解决的是"角色整体被地形挡住"的情况。但还有一种更隐蔽的
// 泄漏场景：
//
//   摄像机 → [装饰物(无CustomDepth)] → [角色(有CustomDepth)]
//
// 角色的轮廓描边是画在**角色外围的背景像素**上的。当装饰物紧贴在角色前方时，
// 角色轮廓附近的某些背景像素的 SceneDepth 是远处背景（因为装饰物刚好没覆盖
// 这个像素），但环形采样的部分点扫到了角色的 CustomDepth → Coverage > 0
// → 产生描边。这条描边会紧贴在装饰物的轮廓旁边"漏出来"。
//
// 解决方案：在 TAP 宏里增加 BlockerCount，统计"非角色但比角色更近"的采样点。
// 如果这类前景遮挡物像素占了采样盘的相当比例（>25%），说明描边正在穿过装饰物，
// 用 smoothstep 把描边平滑压掉。
// ================================================================

// ViewportUV → CustomDepth / SceneDepth 缓冲的 UV
// （两者都是场景缓冲尺寸，共用同一个映射）
float2 BaseUV  = ViewportUVToSceneTextureUV(UV, 13);
float2 STUVMin = ViewportUVToSceneTextureUV(float2(0.0, 0.0), 13);
float2 STUVMax = ViewportUVToSceneTextureUV(float2(1.0, 1.0), 13);

// 偏移必须用**场景缓冲**的纹素尺寸，不能用 PostProcessInput0 的 InvSize
// （也就是 TexelSize 引脚）—— 开 TSR 时后者是输出分辨率，和 BaseUV 所在的
// 空间对不上，会让线宽随分辨率缩放比例失真。
// → 因此 OutlineWidth / InteriorWidth 的单位是**渲染分辨率像素**，
//   不是输出分辨率像素。开了 TSR 上采样时描边会比同数值下细一些。
// → TexelSize 引脚因此变成未使用状态。保留着不影响编译（UE 允许 Custom
//   节点有未引用的输入），想清理的话在 Details 面板里删掉那个引脚即可。
float2 TexelST = View.BufferSizeAndInvSize.zw;

float OccBias = max(0.01, OcclusionBias);
// 中心遮罩只看 CustomDepth，**不**参与可见性判定 —— 可见性统一交给下面的
// Occlusion 平滑因子处理，避免硬判断噪声直接变成斑点
float CenterMask = MMD_MASKED(CustomDepthC);

// ---------- 圆盘覆盖率超采样 ----------
float2 DiscR          = TexelST * max(0.25, OutlineWidth);
float  MaskedCount    = 0.0;
float  VisCount       = 0.0;
float  BlockerCount   = 0.0;
float  MinMaskedDepth = (CenterMask > 0.5) ? CustomDepthC : 1.0e9;
// RefCharDepth: TAP 宏中用于判定"采样点是否属于前景遮挡物"的参考深度。
// 如果中心像素本身在角色上（CenterMask > 0.5），直接用中心 CustomDepth；
// 否则先用 SceneDepthC 做初始估计（后面 MinMaskedDepth 会在采样中更新，
// 但 TAP 宏里需要一个立即可用的值）。
float  RefCharDepth   = (CenterMask > 0.5) ? CustomDepthC : SceneDepthC;

MMD_TAP(float2(+0.176777, +0.000000));
MMD_TAP(float2(-0.225772, +0.206826));
MMD_TAP(float2(+0.034558, -0.393771));
MMD_TAP(float2(+0.284571, +0.371173));
MMD_TAP(float2(-0.522223, -0.092374));
MMD_TAP(float2(+0.494695, -0.314685));
MMD_TAP(float2(-0.165466, +0.615525));
MMD_TAP(float2(-0.315561, -0.607594));
MMD_TAP(float2(+0.684642, +0.250030));
MMD_TAP(float2(-0.712256, +0.294009));
MMD_TAP(float2(+0.343355, -0.733729));
MMD_TAP(float2(+0.253730, +0.808932));
MMD_TAP(float2(-0.764746, -0.443186));
MMD_TAP(float2(+0.897134, -0.197232));
MMD_TAP(float2(-0.547507, +0.778772));
MMD_TAP(float2(-0.126487, -0.976090));

float Coverage = MaskedCount / 16.0;

// 可见比例：盘内的角色采样点里有多少确实没被挡住。
// 取平均 + smoothstep 是抗噪声的关键：零星几个采样点因为深度缓冲错位而误判时
// 比例只掉一点点，完全落在 smoothstep 的饱和区内，不会产生斑点。
float VisibleFrac = VisCount / max(MaskedCount, 1.0);
float Occlusion   = smoothstep(0.15, 0.45, VisibleFrac);

// 中心像素遮挡判定：防止描边渲染在比角色更近的装饰物上
// 如果当前像素的 SceneDepth 比周围角色的 CustomDepth 还要近很多，说明是前面的遮挡物，不该画描边
float CenterOcclusion = step(MinMaskedDepth, SceneDepthC + OccBias + MinMaskedDepth * MMD_OCC_REL);

// ---------- 前景遮挡物抑制 ----------
// BlockerCount 统计的是：在 16 个采样点中，不属于角色（无 CustomDepth）
// 但 SceneDepth 比角色更近的像素数。这些像素属于摄像机和角色之间的装饰物。
// 当描边的采样盘扫到装饰物边缘时，部分采样点会落在装饰物上（Blocker），
// 部分落在角色上或远处背景上 → Coverage > 0 → 产生描边。
// 如果不抑制，这条描边就会"穿过"装饰物显示出来。
//
// BlockerFrac = 前景遮挡物像素占**非角色采样点**的比例。
// 非角色采样点 = 16 - MaskedCount（可能为 0，用 max 保护）。
// smoothstep(0.15, 0.50, BlockerFrac): 
//   < 15% blocker → 保留全部描边（防止零星噪声误杀）
//   > 50% blocker → 完全压掉描边
//   中间平滑过渡
float NonCharCount      = max(16.0 - MaskedCount, 1.0);
float BlockerFrac       = BlockerCount / NonCharCount;
float BlockerSuppression = 1.0 - smoothstep(0.15, 0.50, BlockerFrac);

// ---------- 外轮廓线 ----------
// 覆盖率的几何含义：角色内部深处 = 1，轮廓正上方 ≈ 0.5，完全在外 = 0，
// 中间是随「到轮廓的距离」单调连续变化的。所以「离 0.5 有多远」就等价于
// 「离轮廓有多远」，而且是亚像素精度的连续量 —— 这正是抗锯齿描边需要的信号。
// OutlineBias 把线心从 0.5 挪开，即可让线整体偏内或偏外。
float Bias = clamp(OutlineBias, 0.05, 0.95);
// 用较长的一侧归一化，避免 Bias 偏离 0.5 时两侧线宽不对称
float Span = max(Bias, 1.0 - Bias);
float Dist = saturate(abs(Coverage - Bias) / Span);   // 0 = 线心，1 = 采样盘边缘

float Th   = clamp(OutlineThickness, 0.02, 1.0);
float Soft = saturate(OutlineSoftness);
// Dist < Th*(1-Soft) 时完全实心，到 Th 处渐变到 0
float Silhouette = 1.0 - smoothstep(Th * (1.0 - Soft), Th, Dist);

// ---------- 内部结构线（手臂压在身体上、衣褶等自遮挡）----------
// 只在角色内部检测，外轮廓已经由上面的覆盖率负责，两者不重叠
// 同样只看 CustomDepth，不做逐点可见性硬判断（交给上面的 Occlusion）
float2 IW = TexelST * max(0.25, InteriorWidth);
float dL  = MMD_CD(BaseUV + float2(-IW.x, 0.0));
float dR  = MMD_CD(BaseUV + float2( IW.x, 0.0));
float dU  = MMD_CD(BaseUV + float2(0.0, -IW.y));
float dD  = MMD_CD(BaseUV + float2(0.0,  IW.y));

// 四个邻居和中心都必须是角色，否则这里是外轮廓的位置，交给 Silhouette 处理
float InteriorGate = MMD_MASKED(dL) * MMD_MASKED(dR)
                   * MMD_MASKED(dU) * MMD_MASKED(dD) * CenterMask;

// 二阶差分（拉普拉斯）：匀速倾斜的表面上 dL + dR 恰好等于 2*dC，结果为 0；
// 只有深度真正断裂的地方才出尖峰。这一步是内部线不闪烁的关键 ——
// 用一阶差分的话，大腿侧面这种掠射角表面会因为深度梯度大而被误判成边缘，
// 且随视角连续变化时在"刚好过阈值"附近反复横跳。
float Curv    = abs(dL + dR - 2.0 * CustomDepthC)
              + abs(dU + dD - 2.0 * CustomDepthC);
// 除以深度做归一化，让阈值在远近处含义一致
float RelCurv = Curv / max(CustomDepthC, 1.0);

float IntTh    = max(1e-6, InteriorThreshold);
float Interior = smoothstep(IntTh, IntTh * 3.0, RelCurv)
               * InteriorGate * saturate(InteriorStrength);

// ---------- 距离淡出 ----------
// 雾很浓的场景里，远处角色本身已经被雾吃掉了，描边却还是满不透明度，
// 会显得像贴纸浮在雾上；让描边跟着距离一起退掉
float CharDepth = (CenterMask > 0.5) ? CustomDepthC : MinMaskedDepth;
float FadeS     = max(0.0, FadeStart);
float Fade      = 1.0 - smoothstep(FadeS, max(FadeS + 1.0, FadeEnd), CharDepth);

// ---------- 合成 ----------
// 外轮廓与内部线取 max 而非相加：交界处相加会叠出一条更黑更粗的重线
float Mask = saturate(max(Silhouette, Interior)) * Occlusion * CenterOcclusion * BlockerSuppression * Fade * saturate(OutlineOpacity);

// .rgb 是防御性写法：OutlineColor 接 VectorParameter 时 UE 可能给 float3 也可能给 float4
// （取决于有没有自动加 RGB 遮罩），SceneColor 接的是 ComponentMask 出来的 float3。
// .rgb 对 float3 和 float4 都合法，两种情况都不会有类型错误。
float3 LineColor = lerp(OutlineColor.rgb, SceneColor.rgb * OutlineColor.rgb, saturate(TintByScene));
return lerp(SceneColor.rgb, LineColor, Mask);

// ==================== PASTE END ====================
