# MMD Toon Shader 原理深度解析 (面试备战版)

> 这份文档不是"代码说明书"，而是帮你回答"你在这个 Shader 里做了什么、为什么这么做、还有什么可以改进"这类面试追问的材料。每节末尾列出面试中可能被追问的问题和回答要点。

---

## 1. 一句话概括项目

这是一个 UE5 Unlit 材质下运行的 MMD 风格 Toon 着色器，单个 Custom Node 集成 Base Color 处理、最多三层离散 Toon 阴影色带、Fresnel Rim Light、Blinn-Phong Specular、Matcap 球面反射、头发 UV 定位高光，以及一个独立的 AI 子系统用 MLP 从光照几何预测最佳参数。

**面试官可能追问**："为什么选 Unlit 材质而不是让 UE5 光照管线处理？"

**回答要点**：卡通渲染的本质需求（离散色带、独立阴影色、HDR 高光溢出驱动 Bloom）与 PBR 光照管线的设计目标（物理正确、能量守恒）根本冲突。在 Lit 材质上做 Toon 意味着要跟 Base Pass 的 PBR 计算结果"打架"——你要的是 NdotL→smoothstep→离散色板，UE 给你的是 GGX + Lambert。Unlit + 完全重写光线交互，虽然多写了代码，但没有任何"引擎覆盖你的意图"的黑盒行为。

---

## 2. 渲染管线数据流

```
输入纹理 ─► 色调混合(3模式) ─► 饱和度 ─┬─► Toon阴影(3层色带+H/S/V统一调色)
                                       │         │
                             方向向量   │     ShadowMask ────────────────┐
                           N,V,L,H     │                               │
                              │        ├─► Rim Light (Fresnel×NdotL×SM) │
                              ▼        ├─► Specular (Blin-Phong×SM) ───┤
                          BumpNormal ──├─► 头发高光 (UV定位+NdotH) ────┤
                                       ├─► Matcap (球面映射×SM) ────────┤
                                       │                               │
                                       └───────────────────────────────┤
                                                                       ▼
                                                         ExposureScale 缩放 ─► 输出
```

**面试追问**："所有加法项都乘了 ShadowMask，为什么这很重要？"

**回答**：卡通渲染的审美核心是"明暗边界分明"。如果阴影区域的 Matcap 高光或 Specular 还能亮起来，视觉上立刻就不像赛璐璐了——观众会下意识觉得"光照不对"。这个 Mask 体系是风格一致性（consistency）的保障，不是性能优化。

---

## 3. 各子系统深度解析

### 3.1 Toon 阴影：三层色带参数化

**核心挑战**：如何让"最多三层的离散阴影色带"既好看又可调，还能让 AI 自动校准？

**方案**：三个独立参数 + 一个隐含中间分割点

```
    深阴影区         过渡带 (BandTotal)          亮区
   [0 ...... T1]  [T1 ... T2 ... T3]  [T3 ...... 1.0]
   ShadowColor   Shadow2  Shadow3    ToonTexture采样的亮部
                   ├─ W2 ─┤├─ W3 ─┤
                        ↑
                 W2/(W2+W3) = MidSplit
```

- `T1 = ShadowThreshold`：深阴影起点（AI 可调——与光照几何强相关）
- `T3 = max(T1 + 0.05, ShadowEnd)`：亮区起点（AI 可调）
- `MidSplit`：中间两层的宽度比（美术一次性设定，与光照无关）
- `ShadowSharpness`：所有色带边界的统一过渡半宽（`lerp(0.05, 0.002, sharpness)`）

**面试追问**："为什么 T1/T3 适合让 AI 控制，MidSplit 不适合？"

**回答要点**：T1/T3 决定的是"明暗交界线落在模型表面的哪个位置"，这直接取决于光源方向——光源一变，交界线位置就变。MidSplit 影响的是"中间那两个色带谁宽谁窄"，这是美术风格决策，和光照无关。把不相关的变量扔进同一个 MLP 输出层，只会增加过拟合和不可解释的参数耦合。这是 AI+渲染 交叉领域的基本判断力：**知道什么该学、什么不该学**。

**面试追问**："三层色带的合成顺序为什么是从亮到暗逐层覆盖，而不是从暗到亮？"

**回答**：从亮到暗的覆盖模型 (`FinalToon = ToonSample → lerp(Shadow3) → lerp(Shadow2) → lerp(Shadow1)`) 确保最暗的 ShadowColor 始终"胜出"——LightAtten 最低的区域，Layer1Mask 最接近 1，ShadowColor 的权重最大。如果反过来从暗到亮，亮部的 ToonSample 会在最后覆盖一切，阴影就出不来。

**面试追问**："为什么每个色带边界的宽度是统一的 `EdgeHalfWidth`？不应该不同层不同宽度吗？"

**回答**：这是权衡——三层分四条边界（T1 的暗边、T2 的两侧、T3 的亮边），如果每层独立控制 softness，多 3 个参数，但 99% 的使用场景下美术不需要这么细的粒度。而且 ShadowSharpness 统一控制时，所有边界一起变硬/变软，观感上是一致的"这个材质的阴影风格"——这是一种刻意限定的自由度，避免过度参数化（over-parameterization）导致材质实例调参成本爆炸。

---

### 3.2 HSV 统一调色：数学等价的 RGB 空间操作

**核心洞察**：对阴影三色板做 H/S/V 调整，不真的走 `RGB→HSV→调→RGB→RGB` 的转换管线，而是在 RGB 空间做数学等价操作。

**色相旋转（H）**——绕 `(1,1,1)` 灰轴的 3×3 旋转矩阵：

```
为什么等价？
HSV 的 Hue = 绕灰轴 (1,1,1) 旋转的角度。
绕任意单位向量的旋转有解析 3×3 矩阵——直接乘就行，不需要转出 RGB。
```

**饱和度（S）**——向该颜色的 Rec.709 亮度做 lerp。因为 HSV 的 S 定义为"纯色 vs 灰度的比例"，而灰度就是 RGB 三个通道相等的情况——lerp 到等值灰度就是减饱和度。

**明度（V）**——直接乘标量。V = max(R,G,B)，全部通道乘同一个 k 让 max 也乘以 k，H 和 S 保持严格不变（H 是角度、S 是三个通道之间的比例）。

**面试追问**："为什么选择 RGB 空间直接操作而不是调用 HSV 转换函数？"

**回答要点**：(1) 少 3 次来回转换（9 ALU 指令 vs 一次矩阵乘法），ALU 是 Toon shader 在移动端的主要瓶颈；(2) 避免 HSV 空间的色相环绕边界条件（0° = 360° 的判断分支）；(3) 三层颜色用同一个矩阵，只需要算一次矩阵系数。

**如果面试官继续追问**："你怎么验证这个矩阵是正确的？"

**回答**：矩阵的推导来自 Rodriguez 旋转公式，可以通过数值验证——取一个已知 RGB、手动算 HSV → 调 H → 回 RGB 的结果，再拿 RGB 直接乘矩阵，两者在 float 精度下差小于 1e-6。另外边界验证：HueShift = 0° 时矩阵 = 单位矩阵（cos0=1, sin0=0），颜色不变。

---

### 3.3 法线贴图：三个设计决策的链式推理

#### 决策 1：为什么只读 RG、重建 Z，不读蓝通道？

**根因链**：
```
UE NormalMap 压缩 = BC5（只存 RG 两个通道）
→ Custom 节点采样 BC5 压缩纹理时，蓝通道返回什么？不可靠（可能是 0 或未定义）
→ 如果 B=0 直接用作切线空间 Z → 法线翻向内侧 → dot(BumpNormal, H) 异常
→ 高光出现在背面（视觉 bug："角色脸朝前，后脑勺在发光"）
→ 所以：只读 XY，Z = sqrt(1 - x² - y²)
```

**面试追问**："你怎么知道 BC5 不存蓝通道？"

**回答**：UE 文档写明 `Normalmap` 压缩 preset 使用 BC5（R=G 通道存 X，G=B 通道存 Y）。这是标准做法——DX10+ 所有平台的 Normalmap 压缩格式都只存两个通道，Z 要么在 PS 重建，要么在 VS 用 matrix 算回来。如果面试官想深入，可以讨论 BC5 对比 BC1/BC3 的精度优势（BC5 每个通道有独立的 8-bit 精度，BC1 三个通道共享 16-bit 调色板不适合方向数据）。

#### 决策 2：为什么需要 Gram-Schmidt 正交化 T？

```
问题：顶点 T 和 N 来自不同数据源
  ↓
T 可能不在 N 的切平面上（美术误差 + 三角形内插值）
  ↓
直接 cross(N, T) 得到的 B 会和 N 不正交
  ↓
TBN 不是正交基 → BumpNormal 的方向扭曲 → 高光位置偏移
  ↓
解决：T = normalize(T - N * dot(N,T))
  ↓
把 T 投影到切平面再归一化 → 保证 cross(N,T_ortho) = 真正正交的 B
```

**面试追问**："Gram-Schmidt 有精度问题吗？"

**回答**：单次 GS 校正在这个场景下足够——T 偏离切平面的角度通常小于 1°，一次投影误差远小于 float 精度。需要多轮 GS 的场景是基向量几乎平行时（退化），但这里 T 已经在顶点阶段和 N 近似正交，不会退化。

#### 决策 3：为什么 BumpNormal 只用于 Specular/Matcap，不用于 Toon 阴影/Rim？

**这是整个 Shader 里最能体现"卡通渲染审美判断"的地方。**

```
卡通渲染的视觉目标 = 大块平面色带（赛璐璐风格的本质特征）

如果 Toon 阴影也用 BumpNormal：
  布料皱褶处的 NdotL 会产生微小波动
  → smoothstep 输出的阴影 Mask 在这些区域出现细碎斑块
  → 看起来像是"阴影贴图分辨率不够"的画面 bug，而不是风格化表达

如果 Rim 也用 BumpNormal：
  轮廓边缘的 Fresnel 会因为法线波动出现锯齿/噪点
  → 边缘光呈现碎屑感而不是干净的一条环

但 Specular 和 Matcap 用 BumpNormal 是正确选择：
  高光斑被法线切碎 → 看起来像"材质有表面细节"（毛孔/划痕/纹理）
  这正是法线贴图的"本职工作"
```

**面试追问（进阶）**："如果有一天美术投诉'我想要衣服褶皱处的阴影也跟随法线贴图变化'，你怎么处理？"

**回答**：加一个开关参数 `NormalMapAffectsShadow`（默认关），在 `LightAtten` 计算时用 `lerp(NdotL_geo, NdotL_bump, switch)` 混合两种法线。不改默认行为（向后兼容），但给美术选项。还可以考虑对 BumpNormal 做一次低频滤波（mip level 更高或 blur）——既响应大的褶皱又不引入高频噪声。

---

### 3.4 Rim Light：从单参数到三参数解耦

**演进过程**：

```
v1: pow(1 - NdotV, RimPower)  ← 条带宽窄和边缘软硬耦合在一个指数里
v2: smoothstep(1-RimWidth ± RimEdgeHalfWidth, Fresnel)  ← Width 和 Gradient 独立
v3: v2 + saturate(NdotL) 遮罩  ← 只在朝向光源的轮廓亮，背光面自然消失
```

**v3 为什么重要**：旧版用 `dot(L,V)*0.5+0.5` 判断"光源是否在相机后方"——这个公式不包含模型法线 N，所以整个轮廓的强度是均匀的（形成一圈均匀的光晕/描边），而且有个 0.6 的保底系数关不掉。换成 `saturate(NdotL)` 后，"哪半边轮廓亮"由模型表面自己决定（朝向光源的半边亮、背对光源的半边不亮）——这更接近真实边缘光的物理行为（Fresnel 叠加方向性照明），同时不需要额外参数就能自然切换到侧光和逆光场景的正确观感。

**面试追问**："smoothstep 的边界是 `C¹` 连续，为什么这很重要？"

**回答**：`C⁰`（值连续但导数不连续）在时间轴上表现为"当相机慢慢旋转经过边缘光边界时，像素亮度变化率突然改变"——人眼对这个很敏感，看起来像闪烁/抖动。`smoothstep` 的 Hermite 曲线 (`3t² − 2t³`) 保证一阶导数在边界处连续（两端导数为 0），消除了这个视觉缺陷，且不增加任何 ALU 开销（`smoothstep` 是 GPU 单指令）。

---

### 3.5 Specular：Anti-Plastic 策略

**问题**："为什么很多 Toon 材质看着像塑料？"

**根因**：标准 Blinn-Phong / Phong 的 `pow(NdotH, power)` 只控制高光斑的锐利度，不控制"高光出现在表面的哪些位置"。物理上，布料的侧面不应该有镜面高光——但 `pow(NdotH, power)` 在 NdotL→0 时仍然可能产生非零值。

**三层防御**：

```
1. SpecularThreshold 截断：
   NdotL < threshold 的区域 → 完全无高光
   用 smoothstep 过渡避免硬切换边缘

2. SpecFalloff = smoothstep(...)²：
   二次幂让阈值附近衰减更快
   侧面残余高光被进一步压缩

3. SpecularStrength：
   整体强度系数，降低整体以去除"过度抛光"感
```

**面试追问**："为什么用 SpecFalloff² 而不是 ³ 或直接用 SpecLightMask？"

**回答**：二次幂是经验值——三次幂衰减太快，导致阈值附近原本有体量的高光区域突然消失；一次（直接用 mask）衰减不够，侧面还能看到明显的残余亮斑。二次幂在这个项目的美术素材上效果最好。但这不是物理正确的——如果要理论上更严谨，应该用 Oren-Nayar 漫反射 + Cook-Torrance 镜面，但对于卡通渲染来说，参数化的经验模型比物理模型的调参成本更低。

---

### 3.6 Matcap：极点平滑混合方案

**问题**：Matcap 球面映射需要一个"上方向"来构建相机平面的正交参考系。通常用世界 Z 轴 `(0,0,1)`。但当相机俯视/仰视时 `CamDir ≈ (0,0,±1)`，与参考轴平行 → `cross((0,0,1), CamDir) → (0,0,0)` → 参考基退化 → UV 跳变。

**旧方案缺陷**：`if (abs(dot(CamDir, Z)) > 0.99) → 切换参考轴`。这个硬切换在旋转经过头顶时会产生可见的高光瞬间跳变。

**新方案**：

```
参考轴 A = (0,0,1)  Z轴  （常规视角）
参考轴 B = (0,1,0)  Y轴  （极点区域备选）

AlignA = abs(dot(CamDir, Z))  ← CamDir 离 Z 轴多近
BlendFactor = smoothstep(0.85, 0.99, AlignA)  ← 在靠近极点的区间平滑过渡

CamRight = normalize(lerp(RightA, RightB, BlendFactor))
CamUp    = normalize(cross(CamDir, CamRight))
```

**关键设计点——为什么混 Right 而不是直接混 Up**：

```
观察：cross(Up, CamDir) = Right，cross(CamDir, Right) = Up（正交基关系）

如果直接混 Up：lerp(Z, Y, blend) → cross(CamDir, Up_mix) → 当 CamDir ≈ Up_mix 时
仍然退化（混合中间的 Up 恰好平行 CamDir）。

如果把混合放到 Right 端：RightA 和 RightB 分别是两组参考轴与 CamDir 的叉积，
它们在各自的有效范围内不会退化，混出来的中间 Right 也不会正好平行 CamDir，
从而保证 cross(CamDir, Right_mix) 永远有效。

这类似于四元数球面线性插值（slerp）在欧拉角框架下的一个简化实现——
本质都是避免"中间插值经过退化点"。
```

**面试追问**："为什么 BlendFactor 的区间是 [0.85, 0.99] 而不是更宽或更窄？"

**回答**：[0.85, 0.99] 是一个权衡区间：起点 0.85 → 相机离 Z 轴大约 31.8° 时开始混合，外观上混合在过渡完成前不可见；终点 0.99 → 离 Z 轴约 8.1° 时完成混合，此时 RightA（用 Z 轴构建）还没有明显退化。如果区间太宽（如 [0.7, 0.99]），正常视角下就开始混 Y 轴，会让 Matcap 出现不必要的漂移；如果区间太窄（如 [0.95, 0.99]），混合过渡太突然，导数不连续可能仍然可见。

---

### 3.7 头发高光：为什么要和 Matcap 分开设计？

**核心区别**：

| | Matcap | 头发高光 |
|---|---|---|
| UV 来源 | 视角空间法线→球面映射 | 模型 UV（和 BaseColorTex 一样） |
| 位置由谁决定 | 摄像机旋转 | 美术在贴图上画的 |
| 亮度由谁决定 | ShadowMask 遮蔽 | Blinn-Phong NdotH |
| 效果 | 球形反射高光 | 头发特定位置的高光带 |

**动机解释**：Matcap 用球面映射做的是"整个角色像镜面球一样反射环境"——这适合全身通用的反射效果。但头发很特殊：高光应该出现在刘海边缘、马尾顶部这类具体位置，球面映射决定的位置是"错的"（例如正常视角下可能会在后脑勺出现高光）。让美术直接在贴图上画好高光带，Shader 用 NdotH（光源+视角几何）决定亮度——这样高光位置是对的，亮度跟随光源变化也是对的。

**为什么复用 Specular 的形状参数而不是独立暴露？**

减少 3 个引脚 = 减少材质实例调参负担。头发高光和皮肤高光的"锐利度"在 99% 的场景下应该一致（都是同一个光源下的镜面反射），分开调反而是冗余自由度。

---

### 3.8 色调系统：三种混合模式

| 模式 | 公式 | 特点 |
|---|---|---|
| Overlay | 暗部: `2×SRC×Tint`, 亮部: `1−2×(1−SRC)×(1−Tint)` | 保留明暗层次，色调自然融合 |
| Multiply | `SRC × Tint` | 传统乘法，暗部可能过暗 |
| Soft-Light | `SRC−(1−2Tint)×SRC×(1−SRC)` (<0.5) / `SRC+(2Tint−1)×(sqrt(SRC)−SRC)` (≥0.5) | 最柔和，适合微调色温 |

**面试追问**："为什么用 `round()` 硬分档？不能用连续插值让模式之间平滑过渡吗？"

**回答**：这是有意为之的限制。三种模式各自有不同的数学形式——让"Overlay"和"Multiply"之间做插值，没有"物理意义"的中间态；结果要么看起来像某种奇怪的双重曝光，要么出现意外的色偏。大多数图形软件（如 Photoshop 的图层混合模式）也不支持"两个模式之间的 50% 混合"——这是一个离散选择，不是连续谱。代码用 `round()` 让浮点输入自然落到最近的整数档位，写 0.6 就当 Mode 1、写 1.4 就当 Mode 1——比要求美术传精确整数更容错。

---

### 3.9 Gram-Schmidt 正交化

这是法线贴图 TBN 构建的关键一步，但独立分析更清楚：

```hlsl
float3 T = WorldTangent / TangentLen;                    // 归一化
T = normalize(T - N * dot(N, T));                        // Gram-Schmidt
float3 B = cross(N, T);                                  // 副切线
float3 BumpNormal = normalize(NormalXY.x*T + NormalXY.y*B + NormalZ*N);
```

**为什么需要**：GPU 管线里从 VS 传到 PS 的 T 和 N 并不保证正交——(1) 美术建的模型的顶点法线和切线本来就不是严格正交的；(2) 三个顶点的 T 和 N 插值后更可能偏离。非正交的 TBN 基会导致法线方向系统性地向某个方向偏移。

**Gram-Schmidt 的数学**：`T_ortho = T - N * dot(N, T)` 把 T 投影到以 N 为法线的切平面上——去掉 T 在 N 方向的分量，只保留在切平面内的部分。然后 `cross(N, T_ortho)` 保证 B 与 N、T_ortho 都正交。

---

## 4. AI 子系统

### 4.1 训练流水线

```
艺术家的参数标注 (5000 样本)
         │
collect_training_data.py
    ├── 在 Python 里仿真了完整的 shader 前向计算
    │   （NdotL→LightAtten→smoothstep→色带合成→Rim→Spec→Matcap→Exposure）
    ├── Nelder-Mead 最优化：给定 (LdotV, L_up)，搜索使损失函数最小的 6 参数
    └── 输出 training_data.csv
         │
fit_mlp.py
    ├── 2 输入 → 24 隐藏 (ReLU) → 6 输出 (Linear) MLP
    ├── weight clamping + clamp 出层，防止极端角度过冲
    └── 输出 ai_mlp.hlsl（硬编码权重，纯 ALU，无采样）
         │
MMDToonShader_SM5_SingleFunc_AI.hlsl
    └── 两个前置 Custom Node → ComponentMask → 主 Shader 对应引脚
```

### 4.2 为什么用 MLP 而不是查表（LUT）或多项式回归？

**LUT 的问题**：2D 输入 → 6D 输出，如果用 2D 纹理 LUT，需要 6 张 RGBA 纹理（4+2 通道）或纹理数组。但 2D 纹理采样有带宽开销（可能在移动端成为瓶颈），且插值方式是双线性（边界 C⁰ 光滑而非常见的 C¹ smoothstep）。

**多项式的问题**：高次多项式在训练数据覆盖不到的极端角度（例如 `LdotV ≈ -0.9` 的极端背光）会过冲到不合理的值（例如预测 `ShadowThreshold > 0.9`，整个画面全是阴影）。MLP 的 ReLU 激活 + 出层 clamp 天然限制了这种边界外推。

**MLP 的优势**：

- 24 个隐藏神经元 = 24×2 + 24 + 24×6 + 6 = 222 个参数 ≈ 222 条 FMADD 指令——比 6 次多项式的 27 项更多，但在现代 GPU 上仍然微不足道（不到一个 wave 的 ALU 占比）
- ReLU 激活在 GPU 上是单周期操作，且完全无分支
- 所有计算都是 ALU，无纹理采样、无带宽消耗
- 可微分 → 如果需要在线微调或增量训练，可以直接接学习 pipeline

### 4.3 部署：为什么拆成两个 Custom Node？

UE5 的 Custom Node 输出类型是静态的（`CMOT Float4` 最多 4 通道）。6 个输出需要至少两个 Node。

Group1（4 个主参数）：`(ShadowThreshold, BandWidth, ShadowSharpness, ExposureScale)`——这四个 R² 更高（0.565~0.873），对画面影响最大。

Group2（2 个副参数）：`(RimIntensity, MidSplit)`——R² 较低（0.470, 0.486），说明这两个参数和光照几何的相关性弱于其他四个，AI 的预测更偏"均值回归"。这也印证了前面的判断——MidSplit 和光照无关。

**面试追问**："R² 只有 0.4~0.5，这个 AI 真的有用吗？"

**回答**：(1) R² 低说明这些参数和光照几何的相关性本就弱——但它们仍然参与损失函数优化，不是随机的；(2) 关键是 R² 最高的两个（ShadowEnd=0.968, ShadowThreshold=0.962）是"决定阴影交界线位置"的参数——正是手动调整最痛苦的部分，AI 在这两个参数上效果最好；(3) 不需要完美的参数预测——AI 给一个合理的初值，美术只需微调而非从零开始每镜头拖滑块，已经显著降低了工作量。

---

## 5. 关键设计哲学总结

### 5.1 参数分层

```
适合动画（连续量，平滑插值）:
  ExposureScale, RimIntensity, SpecularStrength, 各种 Intensity,
  ShadowHueShift, ShadowSaturation, ShadowBrightness

需要时微调（与光照几何耦合）:
  ShadowThreshold(T1), ShadowEnd(T3)

一次性设置（形状/色板）:
  ShadowSharpness, MidSplit, RimWidth, RimGradient, SpecPower,
  SpecularThreshold, SpecularSoftness, 各种 Color

不要做动画（离散开关）:
  TintMode (round() 硬分档)
```

### 5.2 取舍决策速查

| 决策 | 选择 | 舍弃 |
|------|------|------|
| 阴影法线 | 平滑 N | 法线贴图细节带来的阴影质感 |
| 高光法线 | BumpNormal | —（高光本就该有细节） |
| Rim 光源遮罩 | `saturate(NdotL)` 含法线 | 无 N 的均匀光晕（更干净但不物理） |
| Matcap 参考轴 | 两组轴 smoothstep 混合 | 单参考轴的简单实现（有极点 bug） |
| 阴影色调整 | HSV 数学等价（RGB 空间） | 调用标准 HSV 转换函数（多指令） |
| Toon 层数 | 最多 3 层 | 更多层（调参成本 > 视觉收益） |
| 头发高光形状 | 复用 Specular 参数 | 独立控制（引脚暴增） |
| AI 模型 | MLP (24 hidden, ReLU) | LUT（带宽）、多项式（边界过冲） |

### 5.3 如果面试官问"还有什么可以改进的"

1. **移动端适配**：全文 float → 移动到支持 half 的平台时，Rim/smoothstep 等操作可以降到 min16float，阴影色板 → half3。需要验证移动端 GPU 的 half 精度在 NdotH 这类接近 1 的数值上不会出现条带（banding）。

2. **LOD 系统**：远距离 LOD 可以跳过法线贴图（BumpNormal=N）、减少阴影层数（三层→单层）、关闭头发高光采样。这是项目实用化会做的，但当前 Demo 不需要。

3. **GPU 场景数据自动读取**：`LightDirection` 需要外部蓝图传入。如果 UE 未来版本 Custom Node 能直接读 `Primitive.xxx` 或 SceneData，可以省掉这个手动连接。

4. **法线贴图镜像 UV 处理**：对称模型的镜像 UV 会导致凹凸方向在镜像侧反转。标准解决方案是靠美术手动翻转 G 通道，或者用顶点色的某通道存储切线符号位（需要引擎侧支持暴露给材质）。

5. **训练数据质量**：当前 AI 训练用仿真 shader + Nelder-Mead 寻优生成的伪标签（pseudo-labels）。如果有美术团队手工标注"这个光照角度下最好看的参数组合"，模型效果会更好——但标注成本太高，5000 样本的人工标注不现实。可以考虑用主动学习（active learning）策略：让模型标出它最不确定的样本，只让人工标注那些。

---

## 6. 面试通用应答框架

当被问到"讲一个你做的渲染项目"时，建议按以下结构回答：

1. **项目目标**（1 句）："为 MMD 角色在 UE5 中实现赛璐璐风格的 Toon 渲染，单 Custom Node 集成，脱离 UE PBR 管线。"

2. **核心技术挑战**（挑 2-3 个讲，选你最熟悉的）：
   - 三层离散阴影色带的参数化 + AI 自动校准
   - 法线贴图用于 Specular/Matcap 但不用于 Toon 阴影的设计取舍
   - Matcap 极点退化的 smoothstep 混合方案

3. **每个挑战用"问题→方案→为什么→验证"四步讲**。

4. **"你学到了什么"**（面试官一定问）：
   - 卡通渲染和 PBR 的本质矛盾——"物理正确"和"风格化表达"需要不同的设计哲学
   - 参数分层的重要性——不是所有参数都应该暴露给美术，也不是所有暴露了的都适合做动画
   - AI+渲染的交叉——模型拟合能力重要，但"知道什么参数该让 AI 管、什么不该"更重要

5. **主动提一处你有意的限制/局限性**（展示工程判断力，而非"我忘了做"）：
   - 例子：法线贴图没有处理镜像 UV 的副切线符号——如果要解决，需要引擎侧改动，已列入已知限制并在文档中说明了替代方案。
