// MMD Toon Outline Shader - Inverted Hull（反向外壳）版本
// 与 MMDToonShader_SM5_Outline.hlsl（Post Process CustomDepth 版）是两套独立方案，二选一：
//   - Post Process 版：不用改网格/材质槽，但描边发生在 TAA/TSR 解析之后，天生有锯齿
//   - Inverted Hull 版（本文件）：描边是真实几何体，在 Base Pass 里正常参与 TAA/TSR/MSAA，
//     没有锯齿问题；代价是需要多渲染一遍网格（多一个 Draw Call / Overlay Pass）
//
// ================================================================
// 原理
// ================================================================
//   1. 用同一份网格，沿顶点法线方向把所有顶点向外推出一小段距离，形成一个比原网格
//      略大的"壳"（Inverted Hull）
//   2. 这个壳只画背面（剔除正面）：从摄像机看过去，壳的正面（朝外的一面）会被裁掉，
//      只剩壳的背面（朝内的一面）
//   3. 壳比原网格大，所以壳的背面在角色内部会被原网格（正常绘制、深度更近）挡住；
//      只有在轮廓边缘，壳的背面比"背景"更靠近摄像机，才会露出来 —— 这一圈露出来的
//      部分正是描边
//   4. 因为整个过程就是普通的三角形光栅化（Base Pass），会被引擎原生的 TAA/TSR/MSAA
//      正常抗锯齿，不存在 Post Process 版本"后处理阶段画的硬边锯齿"问题
//
// ================================================================
// 材质编辑器配置
// ================================================================
//   Material Domain          Surface
//   Blend Mode                Masked（必须，用于裁剪掉壳的正面）
//   Shading Model              Unlit（描边通常是纯色，不需要参与光照）
//   Two Sided                  True（必须勾选，否则背面三角形会被引擎直接剔除，
//                               壳背面永远不会被光栅化，也就没有"Two Sided Sign"可用）
//   Opacity Mask Clip Value    保持默认 0.333333，不需要改
//
// ================================================================
// 网格 / 组件配置（推荐：Overlay Material，零改动网格资产）
// ================================================================
//   选中角色的 Mesh Component（StaticMeshComponent / SkeletalMeshComponent 均可，
//   Overlay Material 定义在 UMeshComponent 基类上，两者都有）：
//     Details 面板 → Rendering 分类 → Overlay Material
//     → 把本材质拖进去即可
//   引擎会在正常渲染这个 Mesh 之后，专门用这个材质把整个网格再画一遍，
//   不需要新增 Material Slot，也不需要复制 Mesh 资产。
//
//   备选方案（如果你的引擎版本 / 组件类型没有 Overlay Material 选项）：
//     给 Mesh 资产新增一个覆盖全部三角形的 Material Slot（Section），
//     把本材质指定到该 Slot 上，效果等价，但需要改网格资产（增加一个 Element）。
//
// ================================================================
// 材质图连接方式
// ================================================================
//   [Emissive Color] 直接接一个 Vector Parameter "OutlineColor"（默认建议深色/黑色，
//                     如 (0.02, 0.02, 0.02)，不建议纯黑，容易在暗场景里完全看不见轮廓感）
//                     注意：Shading Model = Unlit 时材质没有 Base Color 引脚，
//                     颜色统一走 Emissive Color 输出，这是 Unlit 的正常表现，不是配置错误
//
//   [Opacity Mask]    Two Sided Sign 节点（原生节点，材质面板搜索 "TwoSidedSign"）
//                     → Multiply（× -1）→ 接到 Opacity Mask
//                     背面 TwoSidedSign = -1 → 乘 -1 = 1（> 默认阈值 0.333，保留）
//                     正面 TwoSidedSign =  1 → 乘 -1 = -1（< 默认阈值，裁剪掉）
//
//   [World Position Offset]  Custom 节点（见下方 Inputs 配置 + PASTE 代码）
//
// ================================================================
// Custom Node 输入配置（World Position Offset 引脚专用）
// ================================================================
// 名称               类型              连接来源
// ----------------------------------------------------------------
// WorldNormal        Float3            VertexNormalWS 节点（顶点法线，世界空间）
// AbsWorldPosition   Float3            Absolute World Position 节点（当前顶点世界坐标）
// CameraPosition     Float3            Camera Position 节点（摄像机世界坐标，Vertex Shader 阶段可用）
// OutlineWidth       Float1            外壳挤出宽度（世界单位）  默认 0.15
//                                       MMD 模型（厘米级 UE 单位）建议 0.08~0.3 之间试
// ----------------------------------------------------------------
// Output Type: CMOT Float3  →  连接至材质的 World Position Offset 引脚
// ================================================================
//
// 关于粗细一致性：
//   同样的世界空间挤出量，近处看会显得粗、远处看会显得细甚至消失。
//   下面代码按到摄像机的距离做了一个简单的缩放补偿，让描边粗细在不同距离下更接近，
//   不需要时可以把 DistanceScale 那一行删掉，直接用 OutlineWidth 做定长挤出。
// ================================================================

// ==================== PASTE START ====================

float3 N = normalize(WorldNormal);

// 距离越远，适当增大挤出量，避免远处描边被相机透视压缩到不可见
// ReferenceDistance 是参考距离（世界单位），根据场景实际取景距离调整即可
float DistanceToCamera = length(AbsWorldPosition - CameraPosition);
float ReferenceDistance = 500.0;
float DistanceScale = saturate(DistanceToCamera / ReferenceDistance);
float FinalWidth = OutlineWidth * lerp(0.6, 1.4, DistanceScale);

return N * FinalWidth;

// ==================== PASTE END ====================
