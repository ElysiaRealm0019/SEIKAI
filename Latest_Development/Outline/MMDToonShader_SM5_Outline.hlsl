// MMD Toon Outline Shader - Post Process 多点采样版
// UE5 Custom Node 直接粘贴，放在 Post Process 材质中
//
// ================================================================
// 材质编辑器配置
// ================================================================
//   Material Domain     Post Process
//   Blendable Location  Before Tonemapping
//   Custom Node 输出 Float3 → Emissive Color
//
// ================================================================
// Project Settings 配置
// ================================================================
//   Edit → Project Settings → Rendering
//   → Custom Depth-Stencil Pass：改为 Enabled with Stencil
//
// ================================================================
// 角色 Mesh Component 配置
// ================================================================
//   Details → Rendering → Render Custom Depth Pass：开启
//
// ================================================================
// Post Process Volume 配置
// ================================================================
//   勾选 Infinite Extent (Unbound)
//   Rendering Features → Post Process Materials → 添加此材质
//
// ================================================================
// 材质图连接方式
// ================================================================
//
//  Step 1  TexCoord 节点（Index 0） → 记为 jitteredUV
//
//  Step 2  ★ TAA 抖动补偿（消除帧间闪烁的关键）
//          新建一个小 Custom Node "StableUV"：
//            Inputs:
//              jitteredUV  Float2  ← TexCoord 节点
//            Output Type:  CMOT Float2
//            HLSL 代码（单行）：
//              return jitteredUV - View.TemporalAAJitter.xy * View.BufferSizeAndInvSize.zw;
//          其输出记为 UV（之后所有 SceneTexture Coordinates 都用这个稳定 UV）
//
//  Step 3  SceneTexture(PostProcessInput0) → InvSize 输出 (Float2)
//          乘以 OutlineWidth 参数（默认 1.5）→ 记为 TexelSize
//
//  Step 4  计算九组采样 UV（全部基于稳定的 UV，非 jitteredUV）：
//            UV_C  = UV
//            UV_N  = UV + TexelSize * (0, -1)
//            UV_S  = UV + TexelSize * (0,  1)
//            UV_E  = UV + TexelSize * (1,  0)
//            UV_W  = UV + TexelSize * (-1, 0)
//            UV_NE = UV + TexelSize * (1, -1)
//            UV_NW = UV + TexelSize * (-1, -1)
//            UV_SE = UV + TexelSize * (1,  1)
//            UV_SW = UV + TexelSize * (-1,  1)
//          （NE/NW/SE/SW 为对角采样，用于消除 45° 附近轮廓的锯齿，见下方原理说明）
//
//  Step 5  1 个 SceneTexture(PostProcessInput0)：Coordinates 接 UV_C
//          Color → Custom Node colorC
//
//  Step 6  9 个 SceneTexture(CustomDepth)：Coordinates 分别接 UV_C/N/S/E/W/NE/NW/SE/SW
//          Color 输出 → Custom Node 各 depth 输入
//
//  共 10 个 SceneTexture 节点 + 1 个 StableUV 辅助 Custom Node
//
// ================================================================
// Custom Node 输入配置
// ================================================================
// 名称              类型      连接来源
// ----------------------------------------------------------------
// colorC            Float3    SceneTexture(PostProcessInput0) → Color
// depthC            Float4    SceneTexture(CustomDepth) 当前像素 → Color
// depthN            Float4    SceneTexture(CustomDepth) UV_N → Color
// depthS            Float4    SceneTexture(CustomDepth) UV_S → Color
// depthE            Float4    SceneTexture(CustomDepth) UV_E → Color
// depthW            Float4    SceneTexture(CustomDepth) UV_W → Color
// depthNE           Float4    SceneTexture(CustomDepth) UV_NE → Color
// depthNW           Float4    SceneTexture(CustomDepth) UV_NW → Color
// depthSE           Float4    SceneTexture(CustomDepth) UV_SE → Color
// depthSW           Float4    SceneTexture(CustomDepth) UV_SW → Color
// OutlineColor      Float3    描边暗调乘数  默认（0.4, 0.35, 0.45）
// OutlineStrength   Float1    描边不透明度  默认 1.0
// OutlineThreshold  Float1    边缘灵敏度    默认 0.05（越小越敏感）
// OutlineSoftness   Float1    描边柔和度    默认 0.3（smoothstep 过渡宽度）
// ----------------------------------------------------------------
// Output Type: CMOT Float3  →  Emissive Color 引脚
// ================================================================
//
// 原理：
//   - 仅采样 CustomDepth：地形/未启用 Custom Depth 的物体上 customDepth 恒定，
//     偏移采样的差值 = 0，自然不会产生描边
//   - 用八方向（十字 4 向 + 对角 4 向）偏移采样的连续浮点深度差之和作为边缘信号，
//     比 ddx/ddy 提供更宽且更平滑的过渡区间，配合 smoothstep 实现抗锯齿
//   - OutlineWidth 控制偏移距离：值越大描边越粗，越粗越平滑
//
// 关于锯齿（重要）：
//   - 该描边运行在 Before Tonemapping 阶段，此时引擎的 TAA/TSR 抗锯齿已经完成解析，
//     之后新画出来的描边硬边不会再被引擎的抗锯齿处理，这是后处理描边方案的通病，
//     并非本 shader 独有的 bug
//   - 早期版本只采样十字 4 方向，在角色轮廓接近 45° 的位置容易漏检、产生明显的
//     阶梯状锯齿；现在补齐对角 4 方向采样（NE/NW/SE/SW），让边缘信号在所有角度
//     下都能被连续检测到，配合 smoothstep 后锯齿会明显减轻（但不会完全消失）
//   - 如果仍然觉得有锯齿，最简单的调法是调大 OutlineSoftness（更宽的过渡带）
//     或适当调大 OutlineWidth，用"软"换"锐利"；如果需要更彻底解决，
//     需要提高 r.ScreenPercentage（渲染分辨率）或考虑改用基于网格外壳
//     （inverted hull）的正向渲染描边方案，那种方案能吃到引擎原生 TAA/MSAA
//
// ================================================================

// ==================== PASTE START ====================

float dC  = depthC.r;
float dN  = depthN.r;
float dS  = depthS.r;
float dE  = depthE.r;
float dW  = depthW.r;
float dNE = depthNE.r;
float dNW = depthNW.r;
float dSE = depthSE.r;
float dSW = depthSW.r;

// 八方向连续浮点深度差之和（十字 4 向 + 对角 4 向）：
//   均匀表面（含地形、角色内部）：八向差值均接近 0 → 求和仍接近 0
//   角色轮廓 silhouette：至少一向差值极大（跳到远裁面）→ 求和很大
// 相比仅用十字 4 向，补齐对角采样能检测到 45° 附近的轮廓边缘，减少阶梯状锯齿
// 乘以 0.5 是为了把 8 项求和的量级拉回和原来 4 项求和相近，
// 这样 OutlineThreshold / OutlineSoftness 的默认值含义不会因为采样数变化而跑偏
float diffSum = (abs(dN - dC) + abs(dS - dC) + abs(dE - dC) + abs(dW - dC)
               + abs(dNE - dC) + abs(dNW - dC) + abs(dSE - dC) + abs(dSW - dC)) * 0.5;

// 距离归一化：远近处描边强度一致
float normalizedEdge = diffSum / max(dC, 1.0);

// smoothstep 提供过渡区间
// 增大 OutlineWidth（材质图）+ 增大 OutlineSoftness 可获得更宽更柔和的描边
float isOutline = smoothstep(OutlineThreshold,
                             OutlineThreshold + OutlineSoftness,
                             normalizedEdge);

// 描边颜色 = 当前像素颜色 × 暗调乘数
float3 outlineColor = colorC * OutlineColor;

return lerp(colorC, outlineColor, isOutline * OutlineStrength);

// ==================== PASTE END ====================
