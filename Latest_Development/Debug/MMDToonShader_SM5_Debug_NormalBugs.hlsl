// MMD Toon Shader - 法线贴图 Bug 复现工具
// UE5 Custom Node 直接粘贴，用于演示/截图/录屏两个已修复的历史 bug：
//   Bug A（NaN）  ：WorldTangent 未连接 → normalize(0,0,0) 产生 NaN → 全表面满强度高光
//   Bug B（Z反向）：法线贴图直接读蓝通道当 Z（BC5 不存蓝通道）→ Z=-1 → 高光跑到背面
// 两个 bug 在正式文件 MMDToonShader_SM5_SingleFunc.hlsl 里都已经修好，这个文件是
// 专门为了"复现"而写的独立工具——不要把这份代码粘回正式材质。
//
// ================================================================
// 用法：两个开关，不需要改材质图连线就能来回切换对比
// ================================================================
// BugMode 控制"用哪种方式算 BumpNormal"，ViewMode 控制"怎么显示这个向量"。
// 建议流程：
//   1. ViewMode=1（把法线本身画成颜色）配合三种 BugMode 各截一张图，
//      直接看清向量本身出了什么问题，不用先去猜高光形状。
//   2. ViewMode=0（正常光照）配合三种 BugMode 各截一张图，
//      看向量的问题最终在画面上表现成什么样。
//
// ★ BugMode=1（NaN）不需要你真的去材质图里拔掉 WorldTangent 的连线——
//   这个文件会在代码内部强制把 WorldTangent 当成 (0,0,0) 来复现，不管你
//   实际接没接 VertexTangentWS。这样比每次去改图连线更稳定、更方便截图对比。
//
// ================================================================
// 材质编辑器配置
// ================================================================
//   Shading Model      Unlit
//   Custom Node 输出   CMOT Float3  →  Emissive Color
//   NormalMapTex 必须接一张真实的、标准 UE 格式（Normalmap / BC5 压缩）的法线贴图，
//   否则 Bug B 无法稳定复现——贴图格式不对，蓝通道可能凑巧是有效值，现象就不稳定。
//
// ================================================================
// Custom Node 输入配置
// ================================================================
// 名称               类型              连接来源
// ----------------------------------------------------------------
// UV                 Float2            TexCoord 节点
// WorldNormal        Float3            VertexNormalWS 节点
// WorldTangent       Float3            VertexTangentWS 节点
//                                       （BugMode=1 时这个引脚的实际值会被忽略，
//                                        代码内部强制归零，正常连接即可）
// CameraVector       Float3            CameraDirectionVector 节点
// LightDirection     Float3            从场景指向光源的方向（见 Documentation/MMDToonShader_SM5_SingleFunc_使用文档.md）
// NormalMapTex       Texture2D         TextureObjectParameter（切线空间法线贴图，
//                                       必须是真实的 BC5 压缩法线贴图，见上方说明）
// BaseColorTex       Texture2D         TextureObjectParameter（可选，不接则默认纯白，
//                                       纯白反而更利于观察高光形状，不需要额外配贴图）
// BugMode            Float1            复现模式  默认 0
//                                       0 = 正确实现（两道守卫 + Z 重建，与正式文件逐字节等价，作对照组）
//                                       1 = 复现 NaN bug（强制 WorldTangent=(0,0,0)，不做切线守卫）
//                                       2 = 复现 Z 反向 bug（采样 RGB，蓝通道直接当 Z，不做 sqrt 重建）
// ViewMode           Float1            显示模式  默认 0
//                                       0 = 正常光照输出（Lambert 底色 + Blinn-Phong 高光）
//                                       1 = 把 BumpNormal 本身画成颜色（N*0.5+0.5），
//                                           跳过光照计算，直接看向量对不对——
//                                           正确朝外的法线应该偏浅蓝紫色（Z 分量高→蓝色分量高）；
//                                           Bug B 因为 Z=-1，应该偏黄绿色（蓝色分量掉到 0）；
//                                           Bug A（NaN）在这个模式下实测是纯黑，原因见下方
//                                           「同一个 NaN，两种显示模式下颜色相反」的说明。
//
// ★ 同一个 NaN，两种显示模式下颜色相反，不是 bug ★
// BugMode=1（NaN）配合 ViewMode=0 时，实测是全表面发白（原始生产环境的症状）；
// 配合 ViewMode=1 时，实测是纯黑。两者用的是同一个 NaN 的 BumpNormal，
// 结果相反是因为下游经过的运算类型不同：
//   ViewMode=0：NaN 最终流进 saturate(dot(BumpNormal, H))。saturate 底层是
//     min/max 指令，很多 GPU 的 min/max 遇到一个操作数是 NaN 时不传播 NaN，
//     而是直接返回另一个有效操作数——saturate(NaN) 在这类硬件上被"吸收"成 1.0，
//     pow(1.0, SpecPower)=1.0，全表面满强度高光，观感发白。
//   ViewMode=1：NaN 走的是 BumpNormal*0.5+0.5，纯乘法加法，没有任何 min/max/
//     比较类指令。乘法加法严格遵守 IEEE 754——NaN 参与运算恒为 NaN，不会被
//     "吸收"成任何有效值。(NaN,NaN,NaN) 原封不动写到 Emissive Color，而渲染
//     管线后段（后处理/色调映射/曝光计算）大量使用 > / < 比较，NaN 参与比较
//     恒为 false，常见结果是被当成无效值、落到默认的 0，也就是黑色。
// 这正是 NaN bug 难排查的地方：同一处"向量算错了"，会因为后面具体接了什么
// 运算而表现出完全不同的症状——白/黑/花屏都有可能，取决于 NaN 流经的最后
// 一道运算是不是 min/max 类型。
// SpecPower          Float1            高光锐度  默认 32.0
// SpecularStrength   Float1            高光强度  默认 1.0（故意给默认值调高，让复现效果更醒目）
// SpecularColor      Float3            高光颜色  默认（1.0, 1.0, 1.0）
// NormalMapIntensity Float1            法线贴图强度  默认 1.0（仅正确实现/Bug B 分支使用；
//                                       Bug A 分支里这个向量已经是 NaN，强度乘多少都还是 NaN）
// ----------------------------------------------------------------
// Output Type: CMOT Float3  →  连接至材质的 Emissive Color 引脚
// ================================================================

// ---------- 基础向量 ----------
float3 N = normalize(WorldNormal);
float3 V = normalize(-CameraVector);
float3 L = normalize(LightDirection);
float3 H = normalize(L + V);

// ---------- 底色（简单 Lambert，只用几何法线，不受两个 bug 影响）----------
float3 BaseColor = Texture2DSample(BaseColorTex, BaseColorTexSampler, UV).rgb;
float  NdotL      = saturate(dot(N, L));
float3 LitBase    = BaseColor * (0.3 + 0.7 * NdotL);   // 留一点环境底光，纯黑背光面不利于观察高光

// ---------- 按 BugMode 计算 BumpNormal ----------
float3 BumpNormal;

if (BugMode < 0.5)
{
    // ---- 模式 0：正确实现，与正式文件的两道守卫逐字节等价，作为对照组 ----
    float2 RawXY     = Texture2DSample(NormalMapTex, NormalMapTexSampler, UV).rg * 2.0 - 1.0;
    float  TangentLen = length(WorldTangent);

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
        float  NormalZ  = sqrt(saturate(1.0 - dot(NormalXY, NormalXY)));
        BumpNormal = normalize(NormalXY.x * T + NormalXY.y * B + NormalZ * N);
    }
}
else if (BugMode < 1.5)
{
    // ---- 模式 1：复现 Bug A（NaN）----
    // 故意无视传进来的 WorldTangent 真实值，强制当成 (0,0,0)——
    // 这就是"WorldTangent 没连接 VertexTangentWS"时 UE 给的默认值。
    // 不做 TangentLen 守卫，直接 normalize(0,0,0)：
    //   length((0,0,0)) = 0  →  (0,0,0) / 0 = NaN（0 除以 0）
    float3 FakeUnconnectedTangent = float3(0.0, 0.0, 0.0);
    float3 T = normalize(FakeUnconnectedTangent);      // NaN
    T = normalize(T - N * dot(N, T));                  // 仍然 NaN，NaN 参与任何运算结果还是 NaN
    float3 B = cross(N, T);                             // NaN

    float2 RawXY    = Texture2DSample(NormalMapTex, NormalMapTexSampler, UV).rg * 2.0 - 1.0;
    float2 NormalXY = RawXY * NormalMapIntensity;
    float  NormalZ  = sqrt(saturate(1.0 - dot(NormalXY, NormalXY)));
    BumpNormal = normalize(NormalXY.x * T + NormalXY.y * B + NormalZ * N);   // NaN

    // 下游 NdotH = saturate(dot(NaN, H))：数学上应为 NaN，但部分 GPU 的 saturate
    // （编译成 min/max 指令）在操作数为 NaN 时返回另一个有效操作数，实测常常
    // 直接变成 1.0 —— pow(1.0, SpecPower) = 1.0，高光形状信息全部丢失，
    // 全表面（只要几何条件允许）变成满强度高光，观感是均匀发白、无比光滑。
}
else
{
    // ---- 模式 2：复现 Bug B（Z 反向）----
    // 采样全部三个通道，蓝通道直接当 Z 用，不做 sqrt 重建。
    // UE 的 Normalmap 压缩是 BC5，物理上只存 R/G 两个通道；Custom 节点里
    // 直接采样的蓝通道读到的不是"贴图里的蓝色值"，是压缩格式对缺失通道的
    // 默认填充，实测常年是 0 —— 解包后 0*2-1 = -1，Z 被钉死在 -1，
    // 相当于告诉 shader「这里的法线整个翻到了表面内侧」。
    float3 RawXYZ    = Texture2DSample(NormalMapTex, NormalMapTexSampler, UV).rgb * 2.0 - 1.0;
    float  TangentLen = length(WorldTangent);

    if (TangentLen < 1e-4)
    {
        // 这个模式专门演示 Z 反向问题，切线依然需要有效才能看出效果，
        // 未连接切线时退回 N（不然会和 Bug A 混在一起，不利于对照）
        BumpNormal = N;
    }
    else
    {
        float3 T = WorldTangent / TangentLen;
        T = normalize(T - N * dot(N, T));
        float3 B = cross(N, T);
        BumpNormal = normalize(RawXYZ.x * T + RawXYZ.y * B + RawXYZ.z * N);
        // RawXYZ.z 常年 ≈ -1：BumpNormal 在 N 轴上的分量被迫反向，
        // 用它算出来的高光位置会出现在几何上说不通的地方——
        // 本该朝摄像机这一侧的高光核心，会被算到背对摄像机的那一侧。
    }
}

// ---------- 按 ViewMode 决定输出 ----------
if (ViewMode > 0.5)
{
    // 直接把法线向量画成颜色，跳过光照计算：
    //   正确朝外的法线 Z 分量高 → 蓝色分量高 → 偏浅蓝紫色
    //   Bug B 的 Z=-1           → 蓝色分量掉到 0 → 偏黄绿色
    //   Bug A 是 NaN            → 颜色由驱动决定，常见是纯黑或花屏色，
    //                              这本身就是「NaN 在画面上长什么样」的直接证据
    return BumpNormal * 0.5 + 0.5;
}

// ---------- 正常光照：Lambert 底色 + Blinn-Phong 高光 ----------
float NdotH = saturate(dot(BumpNormal, H));
float Spec  = pow(NdotH, max(1.0, SpecPower));

float3 ResultColor = LitBase + Spec * SpecularStrength * SpecularColor;
return ResultColor;
