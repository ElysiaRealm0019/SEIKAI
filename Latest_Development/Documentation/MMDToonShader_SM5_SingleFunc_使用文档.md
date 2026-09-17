# MMD Toon Shader — UE5 Custom Node

适用于 UE5 **Unlit 材质**的 MMD 风格 Toon 着色器，仅需一个 Custom 节点即可集成。  
实现功能：Toon 阴影（最多三层色带）、Rim Light（镜头 + 光源 + 法线三方向）、Matcap 球形高光、
头发专属高光贴图、饱和度调节、整体曝光控制。  
输出接 **Emissive Color** 引脚，完全脱离 UE5 光照系统。

---

## 目录

**使用指南**
- [文件说明](#文件说明) — 七个 .hlsl 分别干什么、怎么选
- [贴图传入方式](#贴图传入方式) — 为什么必须用 `TextureObjectParameter`
- [材质设置步骤](#材质设置步骤) / [Custom 节点 Inputs 配置](#custom-节点-inputs-配置) — 角色版完整参数表
- [哪些参数适合做动画](#哪些参数适合做动画sequencer--timeline) — ✅/🎯/⚙️/⛔ 四档分类
- [材质图连接示意](#材质图连接示意)
- [功能说明](#功能说明) — 各特性的实现原理
- [贴图制作规格](#贴图制作规格)
- [描边使用指南](#描边使用指南mmdtoonshader_sm5_outline_stablehlsl) — 前置 CVar、连接、参数表
- [MPC 工作流](#mpc-工作流sequencer-驱动) — Sequencer 驱动的实际入口
- [故障排查速查表](#故障排查速查表) — 症状 → 先查什么
- [建筑 Lit 版](#建筑-lit-版接收角色投影--引擎阴影) — 让建筑能接收动态阴影

---

## 文件说明

| 文件 | 用途 |
|------|------|
| `MMDToonShader_SM5_SingleFunc.hlsl` | **主文件**——直接粘贴到 Custom 节点 Code 字段，本文档后续内容均针对此文件 |
| `MMDToonShader_SM5_SingleFunc_Hair.hlsl` | 头发边缘半透明专属版，适用于 Translucent 材质（RGB 接 Emissive，A 接 Opacity） |
| `MMDToonShader_SM5_SingleFunc_Alpha.hlsl` | 支持 Alpha 输出的版本，适用于 Translucent / Masked 材质 |
| `MMDToonShader_SM5_SingleFunc_Architecture.hlsl` | 建筑/场景静态表面专属版：删除 Matcap/头发高光等角色专属功能，阴影简化为单一连续渐变（非离散色带），新增贴图模式 ORM（R=AO/G=Roughness/B=Metallic，`UseORM` 开关，默认关闭，让石材哑光与鎏金光滑共存于同一材质实例）和窗户/灯笼自发光（`EmissiveTexture`，不受光照/阴影/ORM 影响），参数和设计取舍见文件自身头部注释 |
| `MMDToonShader_SM5_Architecture_Lit.hlsl` | **建筑/场景 Lit 版**：把表面色处理交给 Custom 节点、把实际受光/投影交回 UE5 的 Default Lit 管线。角色、道具和建筑自身投下的动态阴影都会正确落在建筑上；支持法线、ORM、Lumen 与 Virtual Shadow Maps。 |
| `MMDToonShader_SM5_Outline_Stable.hlsl` | **Post Process 描边（抗抖动版，推荐）**：圆盘覆盖率超采样代替阈值判边，描边强度是连续量而非二值，天然带亚像素抗锯齿；只需 3 个 SceneTexture 节点；含内部结构线、遮挡剔除、距离淡出。**前置条件是 `r.CustomDepthTemporalAAJitter=0`**，不做这步其余全白搭 |
| `MMDToonShader_SM5_Outline.hlsl` | Post Process 描边（八方向阈值判边版，早期实现）：结构简单便于理解，但用二值阈值判边，轮廓移动半个像素就会整格翻转，有爬行/闪烁；需要在材质图里手工摆 10 个 SceneTexture 节点 |
| `MMDToonShader_SM5_OutlineHull.hlsl` | Inverted Hull 描边：真实几何体挤出+背面裁剪，正常参与引擎 TAA/TSR/MSAA，没有锯齿，代价是要多渲染一遍网格（Overlay Material 或复制 Mesh Component） |


三套描边方案择一，具体取舍和踩坑记录见各自文件顶部注释。

> **怎么选**：角色是 Alembic/GeometryCache 驱动的话优先 `_Stable` 后处理版 —— `GeometryCacheComponent` 有 `Render CustomDepth Pass` 但没有 Overlay Material，Inverted Hull 需要复制整个 Component 并同步播放时间，麻烦得多。角色是普通 SkeletalMesh 且要求零抖动，Inverted Hull 仍然是上限最高的方案（能吃到引擎原生 TAA/MSAA）。

**调试/演示专用**（不属于以上任何一套生产方案，不要粘进正式材质）：

| 文件 | 用途 |
|------|------|
| `MMDToonShader_SM5_Debug_NormalBugs.hlsl` | 独立复现「Z 反向」和「NaN」两个已修复的历史 bug，用于截图/录屏留证。`BugMode` 切换「正确实现 / NaN / Z反向」三种路径，`ViewMode` 切换「正常光照 / 把法线本身画成颜色」两种显示方式，不需要改材质图连线即可来回对比 |

---

## 贴图传入方式

贴图必须通过 **TextureObjectParameter** 节点传入 Custom 节点，不能使用 `TextureSampleParameter2D`。

| 节点 | 输出 | 能否用于 Custom 节点 | 说明 |
|------|------|---------------------|------|
| `TextureObjectParameter` | 贴图对象 | ✅ 正确用法 | 传入贴图对象，UV 由 Custom 节点内部 HLSL 自由控制 |
| `TextureSampleParameter2D` | 颜色值（RGB/RGBA） | ❌ 不适用 | 节点处已完成采样，无法再传入自定义 UV；连接后 UE5 不生成采样器，编译报错 |

`TextureObjectParameter` 同样是材质参数——在材质实例编辑器中可以逐个指定贴图资产，与 `TextureSampleParameter2D` 的参数功能完全等价，只是不在节点处采样。

---

## 材质设置步骤

1. 新建材质，**Details → Shading Model** 设置为 **Unlit**。
2. 右键 → 搜索 **Custom** → 添加 Custom 节点。
3. 选中 Custom 节点，在 Details 面板中：
   - 将 `MMDToonShader_SM5_SingleFunc.hlsl` 全部内容粘贴到 **Code** 字段
   - **Output Type** 设置为 `CMOT Float3`
4. 在 **Inputs** 数组中按下方列表添加所有输入引脚（名称区分大小写）。
5. 按照连接说明将各节点连入对应引脚。
6. 将 Custom 节点的输出（Return Value）连接到材质的 **Emissive Color** 引脚。

---

## Custom 节点 Inputs 配置

在 Custom 节点 Details 面板的 **Inputs** 列表中，点击 `+` 逐条添加。**名称区分大小写。**

### 贴图输入

| Input Name | Input Type | 连接节点 | 说明 |
|------------|------------|----------|------|
| `BaseColorTex` | `Texture2D` | **TextureObjectParameter** | Base Colour 漫反射贴图 |
| `ToonTexture` | `Texture2D` | **TextureObjectParameter** | Toon 渐变贴图（横向 1D 渐变，左暗右亮）。`UseToonTexture=0` 时不会被采样，可以留空不接 |
| `MatcapTexture` | `Texture2D` | **TextureObjectParameter** | Matcap 球面贴图（PMX 中的 Sphere Map） |
| `HairHighlightTexture` | `Texture2D` | **TextureObjectParameter** | 头发高光贴图，**UV 与 `BaseColorTex` 完全一致**（不是球面采样），美术直接在头发贴图对应位置画好高光带/高光点 |
| `NormalMapTex` | `Texture2D` | **TextureObjectParameter** | 切线空间法线贴图，标准 UE 格式（RG 编码 XY，蓝通道 Z），只影响 Specular 高光形状和 Matcap 采样位置，不影响 Toon 阴影/Rim（见下方「法线贴图」说明） |

> UE5 会为每个 `Texture2D` 类型输入 `Foo` 自动生成采样器 `FooSampler`，代码内已按此规则编写，无需手动添加采样器引脚。
>
> 注意：主文件不再使用独立的 `SpecularTexture`，身体/皮肤高光已改为纯参数驱动（见下方「高光参数」）。

### 方向 / 坐标输入

| Input Name | Input Type | 连接节点 | 说明 |
|------------|------------|----------|------|
| `UV` | `CMOT Float2` | **TexCoord** | 模型 UV（Index 0） |
| `WorldNormal` | `CMOT Float3` | **VertexNormalWS** | 世界空间顶点法线 |
| `WorldTangent` | `CMOT Float3` | **VertexTangentWS** | 世界空间顶点切线，重建法线贴图用的 TBN 基底 |
| `CameraVector` | `CMOT Float3` | **CameraDirectionVector** | 摄像机朝向向量 |
| `LightDirection` | `CMOT Float3` | 见下方说明 | 主光源方向向量 |

#### LightDirection 传入方式

Unlit 材质无法自动读取场景光源，必须手动传入。

| 方式 | 适用场景 |
|------|----------|
| **VectorParameter**（推荐）：创建向量参数，填写**从场景指向光源**的方向（与 DirectionalLight Forward 向量相反） | 静态场景，方向固定 |
| **蓝图实时驱动**：蓝图每帧读取 `DirectionalLight.GetForwardVector()`，乘以 -1 后写入材质实例向量参数 | 动态光源方向 |
| **Constant3Vector**：直接填写近似方向值，如 `(-0.3, 0.8, 0.5)`（指向右上方的光） | 快速测试 |

> **方向约定**：`LightDirection` 参数的含义是**从场景表面指向光源**的方向（pixel → light）。  
> DirectionalLight 的 `GetForwardVector()` 是光照射方向（从光指向场景），**需要乘以 -1** 再传入。  
> **如果阴影整体完全反了**（该亮的地方暗、该暗的地方亮），几乎总是这里传反了——把向量各分量取反即可，这是实测过的典型踩坑点。

### 色调参数

| Input Name | Input Type | 默认值 | 说明 |
|------------|------------|--------|------|
| `BaseTint` | `CMOT Float3` | `(1.0, 1.0, 1.0)` | 色调颜色（白色 = 无色偏） |
| `TintIntensity` | `CMOT Float1` | `0.0` | 色调混合强度（0 = 不改变颜色，1 = 完全应用色调效果） |
| `TintMode` | `CMOT Float1` | `0.0` | 色调模式：**0** = Overlay 混合（保留明暗，推荐）；**1** = 乘法（传统）；**2** = Soft-Light（柔和微调色温） |
| `Saturation` | `CMOT Float1` | `1.0` | 饱和度：**1** = 不改变；**>1** = 更鲜艳（皮肤发白/发灰时可调到 1.2~1.5）；**<1** = 更接近灰度；**0** = 纯灰度。基于 Rec.709 亮度权重，只调彩度不改明度 |
| `UseToonTexture` | `CMOT Float1` | `1.0` | `1` = 采样 `ToonTexture` 当亮部基础色（默认，兼容原有行为）；`0` = 不采样贴图，改用 `LitColor`，`ToonTexture` 可以留空不接 |
| `LitColor` | `CMOT Float3` | `(1.0, 1.0, 1.0)` | 仅 `UseToonTexture=0` 时生效的亮部基础色。**没有配套渐变贴图的材质（常见于皮肤）应该显式把 `UseToonTexture` 设成 0**，而不是让 `ToonTexture` 悬空吃默认的纯白占位贴图——那样等于亮部完全不参与调色，容易把贴图里本来就偏亮的区域（比如额头高光）直接曝出来，误以为是"发光" bug |
| `UseToonShading` | `CMOT Float1` | `1.0` | Toon 风格化**总开关**。`1` = 正常走完整 Toon 处理（默认）；`0` = 提前跳出，跳过阴影分层/Rim Light/Specular/Matcap/头发高光（以及法线贴图采样），只输出贴图色调+饱和度处理过的基础色，叠加一个不分层的连续明暗。某个部位出现异常发白/过曝/硬边条带时，先切到 0 排查是不是 Toon 处理本身导致的；也可以当应急保底显示 |

### 阴影参数（最多三层色带）

| Input Name | Input Type | 默认值 | 说明 |
|------------|------------|--------|------|
| `ShadowThreshold` | `CMOT Float1` | `0.5` | 深阴影起点 T1（0~1，越大阴影越多） |
| `ShadowEnd` | `CMOT Float1` | `0.75` | 亮区起点 T3，必须 > `ShadowThreshold`；`T3 ≤ T1` 时自动退化为单层阴影 |
| `MidSplit` | `CMOT Float1` | `0.60` | 中间两层（Shadow2/Shadow3）的宽度分配比 `W2/(W2+W3)`：0 = 只剩 Shadow3Color，1 = 只剩 Shadow2Color |
| `ShadowSharpness` | `CMOT Float1` | `0.8` | 边缘锋利度（0 = 柔和渐变，1 = 完全硬边），统一控制所有层的过渡宽度。代码内已 `saturate`——填成负数（实测踩过 `-5.94`）会让过渡宽度暴涨到 0.335、最深阴影永远到不了满值且中间两层被静默跳过，且没有任何报错 |
| `ShadowColor` | `CMOT Float3` | `(0.2, 0.2, 0.4)` | 第一层（最深）阴影颜色，偏冷色调符合 MMD 风格 |
| `Shadow2Color` | `CMOT Float3` | `(0.5, 0.5, 0.6)` | 第二层过渡色带颜色 |
| `Shadow3Color` | `CMOT Float3` | `(0.8, 0.8, 0.85)` | 第三层浅过渡色颜色，最接近亮部 |
| `ShadowHueShift` | `CMOT Float1` | `0.0` | 统一偏移三层阴影颜色的色相（角度）：数学上等价于同时旋转三者 HSV 的 H 分量，不用逐个调；转向反了就取负号 |
| `ShadowSaturation` | `CMOT Float1` | `1.0` | 统一调整三层阴影颜色的饱和度：等价于同时调整三者 HSV 的 S 分量，`1`=不变，`>1` 更鲜艳，`<1` 更灰，`0`=纯灰度 |
| `ShadowBrightness` | `CMOT Float1` | `1.0` | 统一调亮/调暗三层阴影颜色：数学上等价于同时缩放三者 HSV 的 V 分量（不影响色相/饱和度），不用逐个调，`>1` 变亮、`<1` 变暗 |

> ⚠️ **T1 / T3 是两个独立的绝对坐标，不是「起点 + 宽度」。** 代码里 `T3 = max(T1 + 0.05, ShadowEnd)`，只要 `ShadowThreshold < ShadowEnd - 0.05`，`max()` 就恒选中 `ShadowEnd`，**T3 完全不受 `ShadowThreshold` 影响**。调 `ShadowThreshold` 只会从下方挤宽/挤窄中间两层色带，Shadow3 与亮部之间那道边界纹丝不动。要移动亮部交界线，调的是 `ShadowEnd`。这一点很反直觉，实际调参时表现为「Shadow3 不受 ShadowThreshold 控制」。
>
> ⚠️ **`ShadowColor` 不要设成纯黑 `(0,0,0)`。** 最后一步是 `ResultColor *= saturate(FinalToon)`，纯黑意味着**乘零**——base color 纹理、法线细节全部被抹掉，只剩一块完全均匀的死黑。更麻烦的是它对 `ShadowBrightness` / `ShadowSaturation` / `ShadowHueShift` **完全免疫**（`0 × k = 0`，色相旋转矩阵作用在 `(0,0,0)` 上仍是 `(0,0,0)`），也对 `ExposureScale` 和后期调亮免疫。症状是「一块黑斑怎么调都不动」。要接近黑请用 `(0.015, 0.015, 0.02)` 这类极小非零值。

### 高光参数（纯参数驱动 Blinn-Phong，anti-plastic 优化）

| Input Name | Input Type | 默认值 | 说明 |
|------------|------------|--------|------|
| `SpecPower` | `CMOT Float1` | `32.0` | 高光锐度，越大光斑越小越锐利（类似镜面反射） |
| `SpecularStrength` | `CMOT Float1` | `0.5` | 高光整体强度（0 = 完全关闭，1 = 全强度；降低可消除塑料感） |
| `SpecularThreshold` | `CMOT Float1` | `0.3` | 高光可见阈值（NdotL 低于此值的区域完全无高光，防止侧面/背面出现不自然高光） |
| `SpecularSoftness` | `CMOT Float1` | `0.05` | `SpecularThreshold` 截断处的过渡宽度，越大越柔和、越小越接近硬切换（原本写死 0.05，现在可调） |
| `SpecularColor` | `CMOT Float3` | `(1.0, 1.0, 1.0)` | 高光颜色，对应 PMXEditor 材质面板的「スペキュラ色」RGB |

### Rim Light 参数

| Input Name | Input Type | 默认值 | 说明 |
|------------|------------|--------|------|
| `RimIntensity` | `CMOT Float1` | `1.0` | Rim Light 整体强度 |
| `RimWidth` | `CMOT Float1` | `0.35` | 条带宽度（0~1），越大条带从轮廓往表面内侧扩展得越多 |
| `RimGradient` | `CMOT Float1` | `0.15` | 边缘渐变程度，`0`=硬边界（贴纸感），`1`=柔和渐变；和 `RimWidth` 相互独立，不会互相牵扯 |
| `RimColor` | `CMOT Float3` | `(1.0, 1.0, 1.0)` | Rim Light 颜色 |

### Matcap 参数（对应 PMX スフィアマップ）

| Input Name | Input Type | 默认值 | 说明 |
|------------|------------|--------|------|
| `MatcapColor` | `CMOT Float3` | `(1.0, 1.0, 1.0)` | Matcap 颜色叠加，可调色温或染色（默认白色 = 不改变贴图颜色） |
| `MatcapInfluence` | `CMOT Float1` | `1.0` | Matcap 整体强度（0 = 关闭），当前实现为加法模式 |

### 头发高光参数（贴图定位 / 各向异性程序化，二选一）

| Input Name | Input Type | 默认值 | 说明 |
|------------|------------|--------|------|
| `UseHairHighlightTexture` | `CMOT Float1` | `1.0` | 高光模式。`1` = 采样 `HairHighlightTexture` 定位（美术画在哪就出现在哪）；`0` = 不采样贴图，改用 **Kajiya-Kay 各向异性**程序化计算，`HairHighlightTexture` 可留空不接 |
| `HairHighlightIntensity` | `CMOT Float1` | `1.0` | 头发高光整体强度（0 = 关闭） |
| `HairHighlightColor` | `CMOT Float3` | `(1.0, 1.0, 1.0)` | 颜色叠加/染色，白色 = 不改变贴图原色 |

> ⚠️ **`HairHighlightColor` 是总开关级的乘数**——设成纯黑等于关掉整个头发高光，**和 `UseHairHighlightTexture` 选哪个模式无关**。UE 新建 `VectorParameter` 默认就是纯黑，这是「头发完全没有高光」最常见的原因。同理 `SpecularColor` 黑掉会让身体高光也一起消失。
>
> **没有高光贴图的头发材质应该显式设 `UseHairHighlightTexture = 0`**，而不是让贴图引脚悬空。悬空时会吃 UE 的默认纯白占位贴图，`HairTint` 恒为 `(1,1,1)`，高光形状退化成绕法线的 **Blinn-Phong 圆斑**——糊在头发上像一颗塑料球，完全没有发丝感。这和 `UseToonTexture` 是同一类设计：把「没配这张贴图」变成显式声明的状态。

**两种模式的区别**：

| | `=1` 贴图定位 | `=0` 各向异性程序化 |
|---|---|---|
| 高光**位置** | 由贴图内容决定（美术完全控制） | 由发丝方向自动决定 |
| 高光**形状** | 复用 `SpecShape`（绕法线的圆斑），靠贴图裁出带状 | 垂直于发丝、沿发流拉长的**光带** |
| 依赖 | `HairHighlightTexture` | `WorldTangent`（接 `VertexTangentWS`） |
| 适合 | 手绘风格、要求高光位置固定不动 | 没有高光贴图、或希望高光随光源/视角在发面上滑动 |

> 各向异性的原理：让**发丝切线 `T` 代替法线**参与计算——`H` 越垂直于发丝（`dot(T,H)` 越接近 0）越亮，高光自然沿发流铺开成带状。头发建模时 UV 的 U 方向通常就是发流方向，所以 `VertexTangentWS` 天然对齐发丝，不需要额外的方向贴图。
>
> 代码里这条路径**不再乘 `SpecShape`**：各向异性光带 × 各向同性圆斑 = 双重收窄，高光会缩成一个点，各向异性就白做了。两种模式共用的只有 `SpecMask`（阴影/背光遮蔽）。
>
> `WorldTangent` 没接时会自动退回各向同性圆斑，表现等同于「第二层可独立调色调强度的 Specular」，不会变黑也不会报错。

> 与 Matcap 的区别：Matcap 用视角空间法线做球面采样，高光位置跟着相机转；头发高光用和 `BaseColorTex` 相同的 UV 采样，位置由贴图内容直接决定（美术画在哪就出现在哪），亮度则复用 Blinn-Phong 的 `NdotH` 随光源角度和摄像机角度同时变化，和 Toon 阴影一样"跟着光转"。
>
> **不再单独暴露高光形状参数**：原来的 `HairHighlightPower`/`HairHighlightThreshold`/`HairHighlightSoftness` 已删除，头发高光的锐利度/截断角度直接复用 `SpecPower`/`SpecularThreshold`/`SpecularSoftness`——两者紧挨着算，公式结构本来就完全一样，合并后少 3 个引脚。如果你之前的材质实例给这三个单独调过值，现在需要改成用 `SpecPower` 等三个参数去达到同样的效果；默认值下头发高光会比原来的 `HairHighlightPower=60` 更柔和一些（继承 `SpecPower=32`）。

### 法线贴图参数

| Input Name | Input Type | 默认值 | 说明 |
|------------|------------|--------|------|
| `NormalMapIntensity` | `CMOT Float1` | `1.0` | 法线贴图强度，`0` = 完全平坦（不生效），`1` = 贴图原始强度，可以 `>1` 夸张化凹凸效果 |

> 只影响 **Specular 高光的形状**和 **Matcap 的采样位置**（这两处是凹凸细节实际能被看见的地方），不影响 Toon 阴影分层和 Rim Light——否则大色块的卡通阴影/边缘光会被细碎的法线贴图细节搅乱，破坏 Toon 渲染想要的"大平面色块"观感。
>
> **法线贴图是可选的**：没接 `NormalMapTex` 的材质会自动回退到几何法线 `N`，表现和完全没有法线贴图时一致——所以皮肤、布料这类不需要法线细节的材质**留空即可**，不会被强制要求配一张法线图。原理：合法切线法线满足 `x² + y² ≤ 1`，而未赋值/纯黑/纯白的默认贴图算出来会 `> 1`，代码据此识别"这不是法线贴图"并回退到 `N`。（若不做这个回退，没接法线图的材质会在受光面冒出满屏乱高光、整体发亮发光滑。）
>
> **Z 通道处理**：代码只读法线贴图的 R/G 两个通道解包 XY，Z 用 `sqrt(1 - x² - y²)` 现算，不读蓝通道。因为 UE 的 `Normalmap` 压缩是 BC5、只存两个通道，在 Custom 节点里直接采样蓝通道会拿到不可靠的值（常为 0），若当作 Z 会把整条法线翻向内侧，导致**高光跑到背对摄像机的一面**。重建 Z 是 UE 法线贴图的标准处理方式，`Normalmap`(BC5) 压缩照常用即可。
>
> **已知限制**：没有处理镜像 UV 的副切线符号翻转，对称模型如果左右部位共用镜像 UV，凹凸方向在镜像那一半可能会反过来，需要美术手动翻转法线贴图的 G 通道配合，或者不用镜像 UV。

### 曝光参数

| Input Name | Input Type | 默认值 | 说明 |
|------------|------------|--------|------|
| `ExposureScale` | `CMOT Float1` | `1.0` | 整体曝光缩放，暗光环境下调低可避免 Unlit 材质的"自发光感"；>1 增强亮度，可驱动 Bloom |

---

## 哪些参数适合做动画（Sequencer / Timeline）

参数虽然多，但**真正会被拉进动画系统逐帧驱动的只有下面这一批**——它们改变的是"有多少"（强度、整体调色），数值线性变化时观感也线性变化，打关键帧不会出现中间态跳变。其余参数都是"这个材质长什么样"的一次性美术设置，调好就不用再碰，不必占用动画轨道。

### ✅ 推荐做动画（"有多少"类，可平滑插值）

| 参数 | 类型 | 动画能做出的效果 |
|------|------|------------------|
| `ExposureScale` | Float1 | 整体明暗呼吸、进出暗场、爆闪、渐入渐出 |
| `RimIntensity` | Float1 | 边缘光随剧情增强/消失（如角色蓄力、情绪高潮） |
| `SpecularStrength` | Float1 | 高光整体亮起/收敛 |
| `HairHighlightIntensity` | Float1 | 头发高光流动感的整体强弱 |
| `MatcapInfluence` | Float1 | Matcap 高光整体淡入淡出 |
| `Saturation` | Float1 | 全局饱和度变化（如回忆褪色、情绪去色到复色） |
| `TintIntensity` | Float1 | 整体色调覆盖的淡入淡出（配合固定的 `BaseTint`） |
| `ShadowHueShift` | Float1 | 阴影色相随时间偏移（如黄昏→夜晚的冷暖迁移） |
| `ShadowSaturation` | Float1 | 阴影饱和度变化 |
| `ShadowBrightness` | Float1 | 阴影整体提亮/压暗 |

> `ShadowHueShift` / `ShadowSaturation` / `ShadowBrightness` 这三个 HSV 层就是为动画准备的——它们一次性统一驱动三层阴影颜色，比给 `ShadowColor`/`Shadow2Color`/`Shadow3Color` 三个色板各打一条关键帧曲线省事得多，而且三层之间的关系永远协调。
>
> **`LightDirection` 不在这张表里**：它是蓝图从场景 DirectionalLight 读出来写进材质的场景数据，跟着光源自己走，不需要（也不应该）手动打关键帧。

### 🎯 需要时校准（阴影位置，与光照强相关）

| 参数 | 类型 | 什么时候需要动 |
|------|------|----------------|
| `ShadowThreshold` (T1) | Float1 | 深阴影起点——决定明暗交界线落在模型的哪个位置 |
| `ShadowEnd` (T3) | Float1 | 亮区起点——和 T1 一起决定色带的整体位置和跨度 |

这两个既不是"设一次就不动"，也不是常规的逐帧曲线，而是**按需校准**的一类：光源角度变化时明暗交界线会跟着移动，某些角度下会压到不好看的地方（典型如逆光时脸部大面积死黑、顶光时下半张脸全暗），这时需要按镜头微调 T1/T3 把交界线推回合适位置。

> 本项目的 AI 部分正是为此训练的——由 `LdotV` / `L_up` / `L_right` 三个特征预测
> `ShadowSmooth` / `ShadowLocation` / `ExposureScale`，实现自动校准，代替手工逐镜头调。
> 完整管线与闪烁修复见同目录的 `MMDToonShader_Full_AI_使用文档.md`。
>
> `MidSplit` **不属于**这一类：它只控制中间两层色带的相对宽度，与光照无关，归美术一次性决定（见下）。

### ⚙️ 一次性设置，通常不做动画（"长什么样"类）

- **形状/模式**：`MidSplit`、`ShadowSharpness`、`RimWidth`、`RimGradient`、`SpecPower`、`SpecularThreshold`、`SpecularSoftness`、`NormalMapIntensity`
- **基础色板**：`BaseTint`、`ShadowColor`、`Shadow2Color`、`Shadow3Color`、`RimColor`、`SpecularColor`、`MatcapColor`、`HairHighlightColor`、`LitColor`

> 这两类**技术上也能打关键帧**，只是正常工作流里不需要——想统一改色走上面的 HSV 三参数，比直接动色板更方便。

### ⛔ 不要做动画

- `TintMode`：内部用 `round()` 取整分档（0 / 1 / 2），在两档之间打关键帧只会在中点**硬跳**一下，不会平滑过渡。它是"选哪种混合模式"的开关，不是连续量——做动画时固定不动即可。
- `UseToonTexture`：代码里是 `if (UseToonTexture > 0.5)` 硬分支，`0.49→0.51` 会瞬间从纯贴图采样跳到纯 `LitColor`，没有过渡态。这个应该在材质实例里按"这个材质有没有配渐变贴图"一次性定好，不是动画开关。
- `UseToonShading`：同样是 `if (UseToonShading < 0.5)` 硬分支 + 提前 `return`，0/1 之间没有中间态，切换瞬间从完整 Toon 效果跳到简单明暗。这是排查/应急开关，不是动画参数。
- `UseHairHighlightTexture`：硬分支，0/1 之间会在「贴图定位高光」和「各向异性程序化高光」之间瞬间切换，两者形状完全不同、没有过渡态。按「这个头发材质有没有配高光贴图」一次性定好。

---

## 材质图连接示意

```
[TexCoord]                          ──► UV                     ┐
[VertexNormalWS]                    ──► WorldNormal             │
[VertexTangentWS]                   ──► WorldTangent            │
[CameraDirectionVector]             ──► CameraVector            │
[VectorParameter]                   ──► LightDirection          │
[TextureObjectParameter 基础色]     ──► BaseColorTex            │
[TextureObjectParameter Toon]       ──► ToonTexture             │
[TextureObjectParameter Matcap]     ──► MatcapTexture           │
[TextureObjectParameter 头发高光]   ──► HairHighlightTexture    │
[TextureObjectParameter 法线贴图]   ──► NormalMapTex            │
[VectorParameter]                   ──► BaseTint                │  ← 色调颜色
[ScalarParameter]                   ──► TintIntensity           │  ← 色调强度 (0=关, 1=全)
[ScalarParameter]                   ──► TintMode                │  ← 0=Overlay, 1=乘法, 2=Soft-Light
[ScalarParameter]                   ──► Saturation              ├──► Custom Node ──► Emissive Color
[ScalarParameter]                   ──► UseToonTexture           │  ← 0=不用渐变贴图，改用 LitColor
[VectorParameter]                   ──► LitColor                 │  ← 仅 UseToonTexture=0 时生效
[ScalarParameter]                   ──► UseToonShading           │  ← Toon 总开关，0=跳过全部风格化处理
[ScalarParameter]                   ──► ShadowThreshold         │  ← T1 深阴影起点
[ScalarParameter]                   ──► ShadowEnd               │  ← T3 亮区起点
[ScalarParameter]                   ──► MidSplit                │  ← Shadow2/3 宽度分配
[ScalarParameter]                   ──► ShadowSharpness         │
[VectorParameter]                   ──► ShadowColor             │
[VectorParameter]                   ──► Shadow2Color            │
[VectorParameter]                   ──► Shadow3Color            │
[ScalarParameter]                   ──► ShadowHueShift          │  ← 统一偏移三层阴影颜色的色相
[ScalarParameter]                   ──► ShadowSaturation        │  ← 统一调整三层阴影颜色的饱和度
[ScalarParameter]                   ──► ShadowBrightness        │  ← 统一调亮/调暗三层阴影颜色
[ScalarParameter]                   ──► SpecPower               │
[ScalarParameter]                   ──► SpecularStrength        │
[ScalarParameter]                   ──► SpecularThreshold       │
[ScalarParameter]                   ──► SpecularSoftness        │
[VectorParameter]                   ──► SpecularColor           │
[ScalarParameter]                   ──► RimIntensity            │
[ScalarParameter]                   ──► RimWidth                │
[ScalarParameter]                   ──► RimGradient             │
[VectorParameter]                   ──► RimColor                │
[VectorParameter]                   ──► MatcapColor             │
[ScalarParameter]                   ──► MatcapInfluence         │
[ScalarParameter]                   ──► UseHairHighlightTexture │  ← 1=贴图定位, 0=各向异性程序化
[ScalarParameter]                   ──► HairHighlightIntensity  │
[VectorParameter]                   ──► HairHighlightColor      │
[ScalarParameter]                   ──► NormalMapIntensity      │
[ScalarParameter]                   ──► ExposureScale           ┘
```

---

## 功能说明

### 基础渲染
采样 `BaseColorTex` 得到漫反射底色，所有光照效果叠加在其上。

### 饱和度
`Saturation` 用 Rec.709 亮度权重把颜色向灰度插值，只调彩度不动明度，用来纠正贴图发白/发灰（常见于皮肤）。

### Toon 阴影（最多三层）
以 `NdotL * 0.5 + 0.5`（`LightAtten`）为横向 UV 采样 `ToonTexture`，得到亮部基础色。`ShadowThreshold`（T1）和 `ShadowEnd`（T3）之间的区间按 `MidSplit` 分成两段，从暗到亮依次过渡：`ShadowColor → Shadow2Color → Shadow3Color → ToonTexture`。`T3 ≤ T1` 时自动退化为单层阴影（只有 `ShadowColor` 与 Toon 贴图之间的过渡）。`ShadowSharpness` 统一控制所有层边缘的过渡宽度。

**没有渐变贴图的材质**：把 `UseToonTexture` 设成 `0`，亮部基础色直接用 `LitColor`（一个纯色）代替采样 `ToonTexture`，`ToonTexture` 引脚可以不接。这是显式声明"这个材质没有 Toon 贴图"，而不是让引脚悬空——悬空时会吃到默认的纯白占位贴图，效果上和 `LitColor=(1,1,1)` 一样，但纯属意外而不是设计：亮部完全不参与调色，直接暴露 `BaseColorTex` 原始亮度，贴图里偏亮的区域（额头高光等）会显得像是在发光。皮肤类材质常见这种情况。

三层颜色代入插值之前，会先统一做一次 H/S/V 调整（共用一组参数，避免三层各调各的不协调）：
- `ShadowHueShift` 在 RGB 空间绕灰轴 `(1,1,1)` 旋转对应角度，等价于旋转 HSV 的 H 分量
- `ShadowSaturation` 向每层颜色自身的亮度插值，等价于调整 HSV 的 S 分量
- `ShadowBrightness` 直接乘系数，等价于缩放 HSV 的 V 分量

三者都不需要真正转换到 HSV 再转回来——都是数学上完全等价的 RGB 空间直接运算。

### Rim Light
综合**三个方向**决定边缘光强度：

| 方向 | 作用 |
|------|------|
| **镜头方向**（`NdotV`） | 视线与法线夹角越大（越边缘），Fresnel 越强 |
| **模型法线**（`N`） | 决定哪部分表面产生边缘高亮，也用来判断是否朝向光源 |
| **光源方向**（`NdotL`） | 只在朝向光源的那侧轮廓上出现边缘光，背光侧自然过渡到 0 |

条带范围用 `smoothstep(RimThreshold ± RimEdgeHalfWidth, Fresnel)` 生成的 `RimMask` 控制，而不是早期版本单一 `RimPower` 指数曲线：`RimWidth` 只决定条带从轮廓往内扩展多少（内部换算成 `RimThreshold = 1 - RimWidth`），`RimGradient` 只决定边界过渡的软硬（换算成 `RimEdgeHalfWidth`），两者互不影响——可以做出"很窄但边界很软"或"很宽但边界很硬"这类以前用单一指数做不到的组合。

**光源侧遮罩（`RimLightMask = saturate(NdotL)`）**：旧版用 `dot(L,V)*0.5+0.5` 算光源权重，只看光源和镜头的夹角，不含法线——结果是整圈轮廓统一乘上同一个系数，边缘光变成均匀包边的光晕，而且公式里有 `0.6` 的下限，怎么调都关不掉。现在换成含法线的 `NdotL`，只有表面朝向光源的那半边轮廓才会亮，背光那半边自然衰减到 0，更接近真实的逆光/侧光边缘光，而不是描边式的均匀发光圈。

Rim 加法项保留 HDR 值，可配合 Bloom 后处理产生发光边缘效果。

### 高光（Specular）
纯参数驱动的 Blinn-Phong：`SpecPower` 控制光斑锐利度，`SpecularThreshold` 硬截断防止侧面/背面出现不自然高光，`ShadowMask` 遮蔽阴影区域，`SpecularStrength` 做整体强度衰减以消除塑料感。不再依赖单独的高光贴图。

### Matcap 高光
在 Shader 内从法线即时构建切线空间（无需外部 Tangent 输入），对法线做球面映射后采样 `MatcapTexture`；两组参考轴（世界 Z 轴 / Y 轴）通过 `smoothstep` 平滑混合，消除相机转到头顶正上方时的高光跳变。`MatcapColor` 可整体调色，`ShadowMask` 防止暗部亮起。加法项保留 HDR，支持 Bloom。

### 头发高光（两种模式）

Specular 计算被拆成两部分供两处复用：`SpecShape`（`pow(NdotH, SpecPower)`，绕法线的各向同性圆斑）和 `SpecMask`（`ShadowMask × SpecFalloff`，阴影区/背光区遮蔽）。身体高光是两者相乘；头发高光复用 `SpecMask`，但**形状可以替换**。

**`UseHairHighlightTexture = 1`（贴图定位）**：和 Matcap 的思路互补——Matcap 高光位置由**视角空间法线**决定、跟着相机转；这里位置由**贴图内容本身**决定（与 `BaseColorTex` 同一套 UV），美术在头发贴图上画好高光带在哪，Shader 只负责用 `SpecShape` 控制它什么时候亮、多亮。因为 `NdotH` 同时依赖光源和视角方向，亮度会跟着两者一起变化，观感上和真实的头发高光滑动一致。

**`UseHairHighlightTexture = 0`（各向异性程序化）**：不采样贴图，改用 Kajiya-Kay——让**发丝切线 `T` 代替法线**参与计算，`H` 越垂直于发丝越亮，高光自然沿发流铺开成**带状**而不是圆斑。这是没有高光贴图时该走的路：直接复用 `SpecShape` 会得到一颗绕法线的圆形光斑，糊在头发上像塑料球，完全没有发丝感。

这条路径**不再乘 `SpecShape`**——各向异性光带 × 各向同性圆斑 = 双重收窄，高光会缩成一个点。`WorldTangent` 无效时自动退回 `SpecShape`，不会变黑或报错。

### 曝光
`ExposureScale` 在最后统一缩放整个输出，用于补偿 Unlit 材质没有场景光照参与导致的"自发光感"过强或过弱的问题；大于 1 时会让 Rim / Specular / Matcap / 头发高光的加法项溢出 HDR 范围，可驱动 Bloom。

---

## 贴图制作规格

| 贴图 | 推荐分辨率 | 格式 | 注意事项 |
|------|-----------|------|----------|
| **Base Colour** | 1024×1024 或更高 | RGB | 标准漫反射，sRGB 空间 |
| **Toon** | 256×4 ~ 512×4 | RGB | 横向渐变，关闭 Mip Maps；左端（U=0）= 阴影色，右端（U=1）= 高光色 |
| **Matcap（球面贴图）** | 256×256 ~ 512×512 | RGB | 直接使用 PMX 的 Sphere Map 文件；采样器 Wrap 模式设为 **Clamp** |
| **Hair Highlight（头发高光）** | 与 Base Colour 相同分辨率/UV | RGB | 和 `BaseColorTex` 用同一套 UV，只在需要出现高光的位置（如刘海、马尾顶部）画亮色/彩色高光带，其余区域纯黑；建议关闭 Mip Maps 避免远处高光带模糊消失 |
| **Normal Map（法线贴图）** | 与 Base Colour 相同分辨率/UV | RGB，**切线空间** | 标准 UE 法线贴图；导入时 **sRGB 必须关闭**（Compression Settings 选 `Normalmap`），因为法线是方向数据不是颜色，走 sRGB 曲线会解码出错误的凹凸方向 |

---

## Unlit 模式注意事项

- 输出接 Emissive Color，UE5 动态阴影不作用于 Unlit 材质，场景遮挡阴影需另行处理。
- Rim Light / Specular / Matcap / 头发高光的加法项保留 HDR 值（不做最终 `saturate`），可配合后处理 Bloom 产生发光效果；如不需要，可在代码末尾改成 `return saturate(ResultColor * ExposureScale);`。
- `LightDirection` 参数需与场景 DirectionalLight 方向保持同步，推荐通过蓝图实时写入材质实例参数；阴影方向整体反了，先检查这里有没有忘记取负。

---

## 描边使用指南（`MMDToonShader_SM5_Outline_Stable.hlsl`）

### 前置条件（缺一不可）

```bash
r.CustomDepthTemporalAAJitter 0
```

**不做这步，后面所有抗抖动措施全白搭。** 后处理材质无论挂在哪个 Blendable Location 都跑在 TAA/TSR 解析**之后**，此时 SceneColor 已经稳定；但 CustomDepth 缓冲默认是**带 TAA 抖动**渲染的，角色轮廓每帧在 ±0.5 像素横跳。拿抖动的深度给不抖动的画面描边，描边自己就在抖。确认效果后写进 `Config/DefaultEngine.ini`：

```ini
[/Script/Engine.RendererSettings]
r.CustomDepthTemporalAAJitter=0
```

> ⚠️ 如果之前用过「手动减 `View.TemporalAAJitter` 补偿 UV」的做法（第一代描边的 `StableUV` 步骤），开了这个 CVar 之后**必须删掉**——CustomDepth 已经不抖了，再减一次会引入固定的半像素错位。

其余前置：

- Project Settings → Rendering → **Custom Depth-Stencil Pass = Enabled**
- 角色 Mesh Component → Rendering → **Render CustomDepth Pass** 勾上（`GeometryCacheComponent` 也有这个选项）
- Post Process Volume 勾 **Infinite Extent (Unbound)**，Rendering Features → Post Process Materials 里加上本材质

### 材质设置

- **Material Domain** = Post Process
- **Blendable Location** = `Scene Color Before DOF`（描边会参与 DOF/Bloom/调色，跟画面融为一体。选 After Tonemapping 颜色更可控，但描边不吃景深，虚焦角色会带一圈死锐的线，反而更显脏）
- Custom 节点 **Output Type** = `CMOT Float3` → **Emissive Color**

### 材质图连接（只需 3 个 SceneTexture 节点）

环形采样在 Custom 节点内部用 `SceneTextureLookup()` 完成，不需要手工摆一堆偏移 UV。但这三个节点**必须保留并接进 Custom 节点**——它们既提供中心像素的值，也告诉 UE「这个材质要用这几张 SceneTexture」好建立资源绑定。不接的话 `SceneTextureLookup` 取到空数据，不报错但没描边。

```
[TextureCoordinate 0]                        ──► UV
[SceneTexture: PostProcessInput0] → InvSize  ──► TexelSize    ← 当前版本未使用，见下
[SceneTexture: PostProcessInput0] → Color    ──► SceneColor   （经 RGB Mask）
[SceneTexture: CustomDepth]       → Color    ──► CustomDepthC （经 R Mask）
[SceneTexture: SceneDepth]        → Color    ──► SceneDepthC  （经 R Mask）
```

### 参数表

| 参数 | 默认 | 单位 | 说明 |
|---|---|---|---|
| `OutlineColor` | `(0.04, 0.035, 0.05)` | 颜色 | 描边颜色。**这是唯一该调的粗细以外的外观参数** |
| `OutlineOpacity` | `1.0` | 0~1 | 整体不透明度。设 0 = 完全关闭，是排查「问题归不归描边」的最快手段 |
| `OutlineWidth` | `2.5` | **像素** | 采样盘半径。**想要更粗的线只调这个。**实际线宽 ≈ `OutlineWidth × 0.9` |
| `OutlineThickness` | `0.55` | **比例 0~1** | ⚠️ **不是像素！**线占采样盘半径的比例，代码内 `clamp(…, 0.02, 1.0)`。当成像素填会退化成光晕 |
| `OutlineSoftness` | `0.45` | 比例 0~1 | 边缘渐变。**不要设 0**（等于把连续覆盖率又二值化回去，抖动原样回来），**也不要设 1**（配合 Thickness=1 就是光晕退化）。想要锐利用 0.25~0.3 |
| `OutlineBias` | `0.5` | 0~1 | 线相对轮廓的位置。0.5 = 骑在轮廓上（最接近 Inverted Hull 观感）；<0.5 往外推（不啃角色但放大剪影）；>0.5 往内收 |
| `InteriorStrength` | `1.0` | 0~1 | 内部结构线强度（手臂压身体、衣褶）。0 = 只画外轮廓 |
| `InteriorWidth` | `1.0` | 像素 | 内部线检测半径 |
| `InteriorThreshold` | `0.004` | — | 内部线灵敏度，越小越敏感越容易出杂线 |
| `OcclusionBias` | `2.0` | 厘米 | 遮挡判定的绝对容差。代码内还叠加了 4% 的**相对**偏置（`MMD_OCC_REL`），吸收光栅化错位 |
| `FadeStart` / `FadeEnd` | `4000` / `15000` | 厘米 | 描边随距离淡出的区间。浓雾场景里远处角色已被雾吃掉，描边还满不透明度会像贴纸浮在雾上 |
| `TintByScene` | `0.0` | 0~1 | 0 = 纯 `OutlineColor`（干净墨线，推荐）；1 = `OutlineColor × 画面颜色` |

> `TexelSize` 引脚在当前版本**未使用**——偏移改用 `View.BufferSizeAndInvSize.zw`（场景缓冲纹素），因为开 TSR 时 `PostProcessInput0` 的 InvSize 是输出分辨率、和采样 UV 不同空间。保留引脚不影响编译，想清理可在 Details 面板删掉。
>
> 由此 **`OutlineWidth` / `InteriorWidth` 的单位是渲染分辨率像素**，不是输出分辨率像素。开 TSR 上采样时同样数值下描边会偏细。

### 出片时的最后一道

Movie Render Queue → Anti-aliasing → **Temporal Sample Count** 设 8~16。MRQ 用亚像素抖动渲多个子帧再累加，**后处理材质每个子帧都会跑一遍**，所以描边也会被一起超采样。这是渲染管线层面的解决，比 shader 里怎么调都彻底。

注意这和前面那条 CVar **不冲突也不互相替代**：CVar 解决的是「描边整体位置在动」，时域采样解决的是「描边边缘的锯齿」，两回事，都要做。

---

## MPC 工作流（Sequencer 驱动）

材质实例参数无法被 Sequencer 直接驱动跨多个材质槽——角色有 20+ 个槽，逐槽 K 帧不现实。改用 **Material Parameter Collection** 后，一条曲线同时驱动全部槽。

| MPC | 路径 | 内容 |
|---|---|---|
| `MPC_CharAnim` | `/Game/Shaders/New/MPCEnabled/` | 12 个标量：`Saturation` `TintIntensity` `ShadowHueShift` `ShadowSaturation` `ShadowBrightness` `RimIntensity` `SpecularStrength` `MatcapInfluence` `HairHighlightIntensity` `ExposureScale` `ShadowThreshold` `ShadowEnd` |
| `MPC_ArchAnim` | `/Game/Shaders/Architecture/` | 8 标量（`ExposureScale` `EmissiveIntensity` `RimIntensity` `SpecularStrength` `Saturation` `TintIntensity` `AOStrength` `ShadowThreshold`）+ 2 向量（`ShadowColor` `RimColor`） |

选参数的标准就是上面动画分档的 **✅ 档**（「有多少」类）加上 **🎯 档**（`ShadowThreshold`/`ShadowEnd`，按镜头校准）。⚙️/⛔ 档不进 MPC。

### 接法

材质图里把对应的 `ScalarParameter` / `VectorParameter` 换成 **`CollectionParameter`** 节点，绑定 MPC + 参数名。Sequencer 里加 **Material Parameter Collection Track** 即可 K 帧。

> ⚠️ **代价**：MPC 是全局的（per-world），不是 per-instance。原本各材质槽可以给同一参数设不同值，改成 MPC 后**全部槽被统一驱动**，逐槽差异丢失。如果某些槽需要保留独立数值，得改成「MPC 全局值 × 实例乘数」的结构，而不是直接替换。
>
> ⚠️ 建 MPC 参数时**显式写默认值**。向量参数尤其要注意——UE 新建默认是纯黑。

---

## 故障排查速查表

按「先查什么」排序。★ 表示静默失败，不会有任何报错提示。

| 症状 | 先查 |
|------|------|
| ★ 后处理描边一挂上整个画面全黑 | **Output Log** 搜 `Failed to compile Material`。材质编辑器不报错，`recompile` 返回成功也不代表着色器编译通过 |
| ★ 某个特性配好了完全不出现 | 对应的 `VectorParameter` 是不是纯黑 `(0,0,0)`——UE 新建向量参数默认就是黑的，乘上去等于关闭该特性 |
| ★ 一块黑斑怎么调都不动 | `ShadowColor` 是不是纯黑。乘零对所有后续乘法免疫，「调亮了也一样」正是它的特征 |
| 阴影整体反相 | `LightDirection` 是否忘了乘 -1 |
| 高光跑到背对镜头的一面 | 法线贴图是不是读了蓝通道当 Z（BC5 只存 RG） |
| ★ 加了法线贴图后整体发亮 | `WorldTangent` 是否接了 `VertexTangentWS` |
| ★ 某块区域莫名发白像发光 | 该材质是否漏配 Toon 贴图、引脚悬空吃了默认纯白贴图。切 `UseToonTexture=0` 验证 |
| 调 `ShadowThreshold` 推不动亮部交界 | 那道边由 `ShadowEnd` 控制，T1/T3 是独立绝对坐标 |
| 描边整体偏移但中心像素对 | 手动 `SceneTextureLookup` 漏了 ViewportUV → SceneTextureUV 转换 |
| 描边像光晕不像线 | `OutlineThickness` 是不是被当成像素填了（它是 0~1 比例） |
| 描边穿过地形 | 遮挡判定是否逐采样点做（不是全局取 `min`） |
| 描边有爬行/闪烁 | `r.CustomDepthTemporalAAJitter` 是否为 0；出片是否开了 MRQ Temporal Sample |
| 建筑收不到角色投影 | Unlit 架构限制，换 `_Architecture_Lit.hlsl` |

**通用手段**：先用 `OutlineOpacity=0` / `UseToonShading=0` 做排除法确认问题归属，再用「把中间量输出成颜色通道」定位到具体哪一项。

---

## 建筑 Lit 版：接收角色投影 / 引擎阴影

`MMDToonShader_SM5_SingleFunc_Architecture.hlsl` 是 Unlit 方案：自行计算明暗并输出到 Emissive，**不能接收**角色、树木或其他物体的 UE 动态投影。要让建筑上的阴影可信，改用 `MMDToonShader_SM5_Architecture_Lit.hlsl`。

### Unlit vs Lit 架构对比

| | Unlit 版 | Lit 版 |
|---|---|---|
| Shading Model | Unlit | **Default Lit** |
| Custom Node 数量 | 1 个 | **2 个**（Part A + Part B） |
| 阴影接收 | ❌ 不支持 | ✅ 原生支持（Virtual Shadow Maps / Shadow Maps） |
| 光照来源 | 手动 NdotL 渐变 | UE5 完整光照管线（直射光 + 天光 + 间接光） |
| ShadowColor | 直接乘 RGB 压暗 + 色偏 | 只做色相偏移（归一化到亮度=1），亮度由 UE5 控制 |
| 法线贴图 | Custom 内手算 TBN | 材质 Normal 引脚（UE5 自动处理 NdotL 微细节） |
| 高光 | Custom 内 Blinn-Phong | Custom 内 Blinn-Phong（放在 Emissive，不参与 UE5 光照） |
| ORM 粗糙度 | 只影响自定义 Specular | 只影响自定义 Specular；材质 Roughness 引脚=1（关闭 UE 高光） |

### 材质设置步骤

1. 新建（或复制）建筑材质，**Shading Model** = **Default Lit**，`Blend Mode` = **Opaque**
2. **Custom Node A（Base Color）**：
   - 粘贴文件 Part A 的完整代码（从 `// PART A` 到第一个 `return ResultColor;`）
   - `Output Type = CMOT Float3`
   - 按 Part A 开头的 Inputs 列表添加所有输入引脚
   - 输出连接到材质的 **Base Color** 引脚
3. **Custom Node B（Emissive Color）**：
   - 粘贴文件 Part B 的完整代码（从 `// PART B` 到最后的 `return EmissiveResult;`）
   - `Output Type = CMOT Float3`
   - 按 Part B 开头的 Inputs 列表添加所有输入引脚
   - 输出连接到材质的 **Emissive Color** 引脚
4. **法线贴图**（两处连接）：
   - 标准 UE `Texture Sample Parameter 2D` 采样同一张法线贴图 → `Normal Map` 节点 → **Normal** 引脚（UE5 自动用凹凸法线计算 NdotL，石缝/砖缝细节自然体现在光照中）
   - 同时以 `TextureObjectParameter` 方式传入 Custom Node B 的 `NormalMapTex` 引脚（Specular 高光形状用）
5. **材质固定常量**（在材质 Details 面板直接设，不需要连节点）：
   - `Roughness` = **1.0**（关闭 UE 自带高光，所有高光由 Part B 提供）
   - `Metallic` = **0.0**（金属感由 Part A/B 的 ORM Metallic 逻辑处理）
   - `Specular` = **0.0**
   - `Ambient Occlusion` = **1.0**（AO 在 Part A 内处理）
6. **贴图传入**：所有 `Texture2D` 类型输入必须用 **TextureObjectParameter** 节点，不能用 `TextureSampleParameter2D`

### ShadowColor 语义变化

Lit 版中 ShadowColor 只做**色相偏移**（内部自动归一化到亮度=1），不直接控制阴影亮度：

| 参数 | Unlit 版行为 | Lit 版行为 |
|---|---|---|
| 作用机制 | `ResultColor *= lerp(ShadowColor, 1, ShadowMask)` | `ResultColor *= lerp(ShadowTint, 1, ShadowMask)`，ShadowTint 是归一化后的纯色偏 |
| 阴影亮度 | 完全由 ShadowColor 的亮度决定 | 由场景直射光 NdotL + 阴影贴图 + 天光共同决定 |
| 默认值 | `(0.5, 0.58, 0.75)` 较暗 → 明显冷暖分离 | `(0.85, 0.92, 1.0)` 较轻冷色偏 |

**调参指引**：要更明显的冷暖分离，往更饱和的方向调 ShadowColor（如 `(0.6, 0.75, 1.0)`）；要更深的阴影，调低场景天光强度或减少间接光照。`ShadowThreshold` / `ShadowSoftness` 与 Unlit 版含义相同，控制色偏的起始位置和过渡宽度。

### 高光模式开关 `Use PBR Specular`（StaticSwitchParameter，默认 `False`）

Lit 版有两种互斥的高光路线，用一个静态开关切换。用静态开关而不是 `Lerp`，是因为它**编译期分支、运行时零开销**，而且天生属于⚙️「一次性设置」而非可动画参数。四个开关节点共用同一个参数名，材质实例里勾一次就同时切换全部四条线路。

| 引脚 | `False` = 模式 A（默认） | `True` = 模式 B |
|---|---|---|
| `Roughness` | 常量 `1.0` | **ORM 贴图 G 通道** |
| `Metallic` | 常量 `0.0` | **ORM 贴图 B 通道** |
| `Specular` | 常量 `0.0` | 常量 `0.5` |
| Part B 的 `SpecularStrength` | MPC 的 `SpecularStrength` | 常量 `0.0`（关掉自定义高光） |

**模式 A（风格化，默认）**：引擎只负责漫反射 + 阴影，关掉 UE 自带 PBR 高光，全部高光走 Part B 的卡通 Blinn-Phong。高光形状完全可控、和角色 Toon 高光同一套语言。

> ⚠️ **这个模式下 ORM 的 G 通道（粗糙度）不进入引擎的高光/反射管线**，只影响 Part B 那一小簇自定义高光。「接了 ORM 贴图但看不出粗糙度差异」在模式 A 下是**预期行为**，不是 bug。AO（R 通道）和 Metallic 的漫反射衰减（B 通道）仍然在 Part A 内正常生效。

**模式 B（物理，需要反射时用）**：ORM 的 G/B 通道真正进入 UE 原生 PBR 管线，引擎接管高光和反射（配合 Lumen 会有真实环境反射）。此时 Part B 的自定义 Blinn-Phong 被开关强制归零——两套高光叠加会很脏，这是刻意的互斥设计。

**怎么选**：整体走风格化路线就留在 A；场景里有大量湿路面 / 玻璃 / 金属残骸这类**靠反射才成立**的材质，就切 B。

> ⚠️ 两种模式各自编译成独立的着色器排列，而且**只有被实际用到的那个分支会被编译**。改动这条路径后两种模式都要各验一遍，不能只测默认模式就以为没问题。

### 局限性

- 模式 A 下 Specular 高光放在 Emissive 中，不参与 UE5 的间接镜面反射（SSR 等），大面积光滑表面不会有环境反射（这正是模式 B 存在的理由）
- ShadowColor 不能完全复现 Unlit 版的直接压暗效果——Lit 版的阴影最终亮度 = 色偏 × 场景光照，受场景光源和天光影响较大
- 若要**严格的卡通色带 + 引擎阴影系数**同时存在，需要自定义 UE Shading Model，不在单个 Material Custom 节点能解决的范围
