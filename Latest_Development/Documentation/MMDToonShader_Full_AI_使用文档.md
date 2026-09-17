# MMD Toon Shader AI 驱动版 — 使用文档

> 对应文件：`Latest_Development/AI/MMDToonShader_SM5_SingleFunc_Full_AI.hlsl`
> 基线版本：`MMDToonShader_SM5_SingleFunc_Full_Accessories.hlsl`（配件增强版）
> 训练工具：`Latest_Development/AI/AIControl/` 目录下全套 Python 脚本

---

## 1. 版本定位

Full_AI 是在**配件增强版**（Full_Accessories）基础上的 AI 集成变体。核心变化是内嵌了一个 **MLP 神经网络（3 -> 64 -> 3）**，根据光照方向实时预测 3 个阴影/曝光参数，实现"每帧、每像素"的自适应渲染。

**一句话总结**：把美术在不同光照角度下手动调好的最优参数，用神经网络学下来，运行时自动适配——玩家转视角、换场景、打光变化都不需要手动干预。

### 1.1 相对配件增强版的变化

| 维度 | 配件增强版 | Full_AI |
|------|-----------|---------|
| ShadowSmooth / ShadowLocation / ExposureScale | 手动参数，固定值 | **AI 实时预测**（UseAI=1 时） |
| 各向异性高光（Kajiya-Kay） | 有 | 有（完全保留） |
| 其余全部功能 | 有 | **完全一致** |

UseAI 开关可随时切回手动模式，此时行为与配件增强版完全相同。

### 1.2 AI 预测的 3 个参数

| 参数 | 语义 | AI 预测值范围（clamp） |
|------|------|--------------|
| `ShadowSmooth` | 阴影过渡柔化程度（>1 扩散柔化，<1 收窄变陡） | [0.138, 1.280] |
| `ShadowLocation` | 阴影位置偏移（>0 阴影前移变多，<0 阴影后移变少） | [-0.289, 0.713] |
| `ExposureScale` | 整体曝光矫正（背光自动提亮防死黑） | [0.560, 1.298] |

这三个参数在「曲线阴影」（UseCurve=1，默认）与「Ramp 回退」（UseRampTex=1）两条路径都生效。色带分支为过时方案，AI 不对其生效；Rim 为确定性几何函数，天生自适应，无需 AI 预测。

> ⚠️ **预测值的训练口径（2026-09-12 起）**：标签不再用「精确穿过每个锚点」的 IDW，
> 而是先扣掉每条拍摄的系统性偏置、再用 **3 阶球谐最小二乘**拟合出一个全局光滑场。
> 原因是手工锚点在相近光向下互相矛盾（4° 内 `ShadowSmooth` 分歧最大 0.64），
> IDW 精确穿点会让参数沿光向出现鼓包，光扫时阴影边界逐帧跳变（>0.5°/帧 的帧占 14%）。
> 改为光滑场后同一指标降到 **0%**，代价是 15/75 个锚点不再被精确复现（残差中位 0.15）。
> 详见[训练管线](#7-训练管线)与 [9.5 闪烁修复](#95-闪烁修复为什么从-idw-换成光滑标签)。

---

## 2. AI 架构详解

### 2.1 输入特征（3 个）

从场景光照信息中提取三个几何特征：

| 特征 | 计算方式 | 物理意义 |
|------|---------|---------|
| `LdotV` | `dot(LightDirection, V_cam)` | 光源与相机视线的夹角。1=顺光，-1=绝对逆光 |
| `L_up` | `LightDirection.z` | 光源高度。1=正顶光，-1=正底光，0=水平 |
| `L_right` | `dot(LightDirection, Right)`，`Right = cross(Z_up, V_cam)` | 光源在角色**左右**哪一侧 |

`V_cam` 是**每帧一个常量**（物体中心 → 相机），不是逐像素视线向量：
`GetWorldCameraOrigin - GetObjectWorldPosition`。这一点必须与 Python 侧 `V_CAM`、
导出器逐行记录的 `VcamX/Y/Z` 三处严格一致，否则整张特征空间会错位而上机才发现。

> **为什么需要 `L_right`**：本项目设计为「相机固定、正对角色正面、光源动」。此时光向
> 被限制在一个圆上，`LdotV` 与 `L_up` 无法区分光的左右 —— 正左前光与正右前光会落到
> 同一组特征上。补上第三维取回的其实只是**符号**，而那正是区分左右所需的全部信息。
>
> 副作用：`(V_cam, Z_up, Right)` 三个基向量**不再正交**（V_cam·Z = 0.38），
> 于是 `LdotV² + L_up² + L_right²` 不再恒等于 1（均匀采样下 mean≈1、std≈0.20）。

这三个参数构成描述"人类视觉感知光照角度"的潜空间，抛弃了世界坐标的绝对性，只关注光、眼、物三者的相对关系。

### 2.2 网络结构

```
输入层 (3)  -->  隐藏层 (64, ReLU)  -->  输出层 (3, Linear)
  LdotV                                        ShadowSmooth
  L_up                                         ShadowLocation
  L_right                                      ExposureScale
```

- **训练框架**：scikit-learn MLPRegressor
- **激活函数**：ReLU（隐藏层）、线性（输出层）
- **优化器**：L-BFGS（`lbfgs`）。Adam 的定步长在平坦谷底会被 `tol` 判停，实测第 210 次
  就停机、R² 被压到 0.9 上下，纯属优化器假象
- **训练样本**：500 条（球面均匀采样光照方向）
- **留出 R²（20% holdout）**：ShadowSmooth ≈ 0.999, ShadowLocation ≈ 0.998,
  ExposureScale ≈ 0.998（对**光滑标签场**的复刻保真度；含义见 9.5）

> **隐藏层为什么是 64 而不是更大**：容量越高，网络越能把 IDW 标签里「相近光向下互相
> 矛盾的锚点」形成的脊也拟合进去 —— 那正是闪烁。实测边界抖 >0.5°/帧 的帧占比随容量单调
> 上升：H=16 → 1.3%、24 → 5.0%、64 → 12.7%、256 → 14.2%。64 配合光滑标签时降到 0.14%，
> 且 shader 侧乘加数只有 256 版的 1/4。**R² 是在给噪声打分，越高反而越糟。**

### 2.3 推理方式

**线下训练，线上常量固化**。训练完成后，脚本将权重矩阵展开为纯 HLSL 代码，内嵌到 shader 文件的 `// ==== AUTO-MLP-BEGIN ====` 和 `// ==== AUTO-MLP-END ====` 标记之间。

运行时推理 = 64 次 ReLU + 3 次线性组合 = 几十条 GPU 指令，零 CPU 负担，零外部依赖（不需要 ONNX / PyTorch 运行时）。

---

## 3. 材质结构

UE 材质需要**两个 Custom 节点**：

| 节点 | 说明 | Output Type |
|------|------|-------------|
| **主节点** | 完整 Toon + AI 推理（51 输入） | CMOT Float3 |
| **ToneMap 节点** | ACES 色调映射（2 输入：col、UseTonemap） | CMOT Float3 |

接线：`主节点输出 -> ToneMap.col` -> `ToneMap输出 -> Emissive Color`

---

## 4. 贴图说明（8 张）

均使用 **TextureObjectParameter** 传入（不能用 TextureSampleParameter2D）。

| 参数名 | 用途 | 说明 |
|--------|------|------|
| `BaseColorTex` | 基础色贴图 | 必须 |
| `CurveAtlasTexture` | 曲线图集（CurveLinearColorAtlas） | UseCurve=1 时必须，可实时调曲线 |
| `ToonTexture` | Ramp 渐变贴图 | UseCurve=0 时的回退 |
| `MatcapTexture` | 高光 Matcap 球面贴图 | 各向异性高光复用此参数 |
| `RoughMatcapTexture` | 粗糙 Matcap 球面贴图 | 控制哑光/光滑区域 |
| `NormalMapTex` | 切线空间法线贴图（BC5） | 可选 |
| `HMTexture` | HM 贴图（R=高光蒙版，G=AO） | UseHM=1 时生效 |
| `SSSTex` | 次表面散射贴图 | UseSSS=1 时生效 |

---

## 5. 参数说明（按分组）

### AI 控制
| 参数 | 类型 | 默认 | 说明 |
|------|------|------|------|
| `UseAI` | Float1 | 0.0 | **1=MLP 预测覆盖 ShadowSmooth/ShadowLocation/ExposureScale，0=全部手动** |

### Tint（色调）
| 参数 | 类型 | 默认 | 说明 |
|------|------|------|------|
| `BaseTint` | Float3 | (1,1,1) | 色调颜色 |
| `TintIntensity` | Float1 | 0.0 | 色调强度 |
| `TintMode` | Float1 | 0.0 | 0=Overlay, 1=乘法, 2=SoftLight |
| `Saturation` | Float1 | 1.0 | 饱和度 |

### Toon（总开关）
| 参数 | 类型 | 默认 | 说明 |
|------|------|------|------|
| `UseToonTexture` | Float1 | 1.0 | 1=采样 ToonTexture，0=用 LitColor |
| `LitColor` | Float3 | (1,1,1) | UseToonTexture=0 时亮部色 |
| `UseToonShading` | Float1 | 1.0 | Toon 总开关 |

### Shadow（阴影）
| 参数 | 类型 | 默认 | 说明 |
|------|------|------|------|
| `UseCurve` | Float1 | 1.0 | 1=曲线图集阴影，0=回退到 Ramp/色带 |
| `UseRampTex` | Float1 | 1.0 | UseCurve=0 时：1=Ramp 贴图，0=三层色带 |
| `ShadowSmooth` | Float1 | 1.0 | 阴影平滑度（**UseAI=1 时被 AI 覆盖**） |
| `ShadowLocation` | Float1 | 0.0 | 阴影位置（**UseAI=1 时被 AI 覆盖**） |
| `ShadowThreshold` | Float1 | 0.5 | 色带方式深阴影起点 |
| `ShadowEnd` | Float1 | 0.75 | 色带方式亮区起点 |
| `MidSplit` | Float1 | 0.60 | 色带方式中间层分配比 |
| `ShadowSharpness` | Float1 | 0.8 | 色带方式阴影锋利度 |
| `ShadowColor` | Float3 | (0.2,0.2,0.4) | 第一层阴影色 |
| `Shadow2Color` | Float3 | (0.5,0.5,0.6) | 第二层阴影色 |
| `Shadow3Color` | Float3 | (0.8,0.8,0.85) | 第三层阴影色 |
| `ShadowHueShift` | Float1 | 0.0 | 阴影色相偏移 |
| `ShadowSaturation` | Float1 | 1.0 | 阴影饱和度 |
| `ShadowBrightness` | Float1 | 1.0 | 阴影亮度 |

### AO（环境光遮蔽）
| 参数 | 类型 | 默认 | 说明 |
|------|------|------|------|
| `UseHM` | Float1 | 0.0 | 1=启用 HM 贴图 |
| `UseAO` | Float1 | 1.0 | 1=启用 AO |
| `AO_Power_ShadowMask` | Float1 | 1.0 | AO 强度 |
| `AO_Shadow_Strengh` | Float1 | 0.0 | AO 阴影混合强度 |

### SSS（次表面散射）
| 参数 | 类型 | 默认 | 说明 |
|------|------|------|------|
| `UseSSS` | Float1 | 0.0 | 1=启用 SSS |
| `SSSColor` | Float3 | (1,1,1) | SSS 颜色+强度 |

### Rim（边缘光）
| 参数 | 类型 | 默认 | 说明 |
|------|------|------|------|
| `RimWidth` | Float1 | 0.35 | 条带宽度 |
| `RimGradient` | Float1 | 0.15 | 边缘渐变 |
| `RimColor` | Float3 | (1,1,1) | 颜色+强度 |

### Matcap + 各向异性高光
| 参数 | 类型 | 默认 | 说明 |
|------|------|------|------|
| `MatcapColor` | Float3 | (1,1,1) | 高光 Matcap 颜色+强度 / 各向异性强度 |
| `RoughMatcapColor` | Float3 | (1,1,1) | 粗糙 Matcap 颜色+强度 |
| `RoughColor` | Float3 | (1,1,1) | 粗糙 Matcap 混合色 |
| `MatcapScale` | Float1 | 1.0 | Matcap UV 缩放 / **各向异性锐利度** |
| `MatcapOffset` | Float1 | 0.0 | Matcap UV 偏移 |

### Normal（法线）
| 参数 | 类型 | 默认 | 说明 |
|------|------|------|------|
| `NormalMapIntensity` | Float1 | 1.0 | 法线贴图强度 |

### 曝光（**UseAI=1 时被 AI 覆盖**）
| 参数 | 类型 | 默认 | 说明 |
|------|------|------|------|
| `ExposureScale` | Float1 | 1.0 | 整体曝光矫正 |

---

## 6. 各向异性高光（Kajiya-Kay）

这是配件增强版引入的功能，在 Full_AI 中完全保留。用 Kajiya-Kay 模型为丝袜、皮革、布料等材质产生拉长的各向异性光带。

**参数复用**（无需新增参数或贴图）：
- `MatcapScale` -> 各向异性锐利度（值越大光带越窄越锐利）
  - `1.0` = 普通 Matcap 效果
  - `2.0~4.0` = 各向异性拉长光带（丝袜/皮革/布料）
- `MatcapColor` -> 各向异性强度（颜色越亮强度越高）

**使用方式**：为不同配件创建独立材质实例
- 金属配件：MatcapScale=1.0（普通高光）
- 丝袜材质：MatcapScale=3.0（各向异性光带）
- 皮革材质：MatcapScale=2.0（中等各向异性）

---

## 7. 训练管线

### 7.1 目录结构

```
Latest_Development/AI/AIControl/
  anchors.csv               -- 锚点表（光照方向 -> 理想参数），唯一需要手改的输入
  offset_anchors.py         -- 扣掉每条拍摄的系统性偏置（--take-offset 时自动跑）
  merge_anchors.py          -- 合并同一光向的重复锚点（可选）
  collect_training_data.py  -- 训练数据采集（锚点 IDW 插值；--smooth-order 切光滑场）
  fit_mlp.py                -- MLP 训练 + HLSL 代码生成
  retrain_all.py            -- 一键重训脚本（偏置/光滑 + 采集 + 训练 + 同步）
  training_data.csv         -- 生成的训练数据（生成物）
  ai_mlp.hlsl               -- 独立前置节点版 MLP HLSL（生成物）
```

### 7.2 训练流程

```
anchors.csv（5 条甩拍、每条 15 帧的美术校准锚点）
    |  offset_anchors.py（可选，--take-offset）
    |      扣掉每条拍摄相对其余拍摄的系统性偏置
    v
anchors_prepared.csv
    |  collect_training_data.py（--smooth-order 3）
    |      球面均匀采样光照方向；标签 = 锚点的 3 阶球谐最小二乘光滑场
    |      （不加 --smooth-order 则退回精确穿点的 IDW）
    v
training_data.csv  -- 500 条训练样本
    |
    v
fit_mlp.py  -- sklearn MLPRegressor 训练 3->HIDDEN_DEFAULT->3（当前 64，见 fit_mlp.py）
    |
    v
ai_mlp.hlsl  -- 独立前置节点版（可用 ComponentMask 拆出 3 个标量）
    |
    v
retrain_all.py::sync_all_targets()  -- 内嵌权重到 Full_AI.hlsl 与 Full_Alpha_AI.hlsl
                                        的 AUTO-MLP 标记之间（两份必须逐字相同）
```

### 7.3 锚点系统

`anchors.csv` 每行定义一个光照方向下的理想参数。v6 表有 **3 个特征列** —— v5 及更早
只有前两个，缺 `L_right` 时相机固定正对角色正面会把光向只确定到一个圆，左前光与右前光
落到同一组特征上：

```csv
LdotV,L_up,L_right,ShadowSmooth,ShadowLocation,ExposureScale,VcamX,VcamY,VcamZ,note
-0.00,-0.00,1.00,0.30,-0.33,0.50,0.0000,0.9247,0.3807,正面-0度 frame=0
-0.56,-0.00,0.79,1.00,0.10,0.35,0.0000,0.9247,0.3807,正面-0度 frame=30
-0.90,-0.00,0.21,0.81,-0.08,0.20,0.0000,0.9247,0.3807,正面-0度 frame=45
```

| 列 | 含义 |
|---|---|
| `LdotV` | `dot(L, V_cam)` 光的前后分量（>0 顺光，<0 逆光） |
| `L_up` | `L.Z` 光源高度 |
| `L_right` | `dot(L, Right)` 光的左右分量（★ 唯一的左右信息） |
| 后三列 | 该光向下理想的 `ShadowSmooth` / `ShadowLocation` / `ExposureScale` |
| `VcamX/Y/Z` | **生成这一行时导出器实际用的 `V_cam`**（逐行记录，见下） |
| `note` | `<序列名> frame=<帧号>`，必须是**最后一列**（合并逻辑靠它判定行归属） |

采集脚本默认通过**反距离加权（IDW, power=2）**在三维特征空间里对任意光照方向插值出理想参数。
直接编辑 `anchors.csv` 即可调整美术风格，改完重训即可。

> **推荐走光滑标签（`--take-offset --smooth-order 3`）。** 这份锚点表是 5 条甩拍各自
> 手工校的，相近光向之间并不一致（4° 内 `ShadowSmooth` 分歧最大 0.64，跨拍摄分歧是
> 同拍摄内的 1.6~2.4×；每条拍摄还带一个系统性偏置，如 `正面-0度` 的 SS 中位 −0.38）。
> IDW 精确穿过每个锚点，就会在这些矛盾点之间形成脊，光扫时表现为阴影边界逐帧抖动。
> 光滑场（3 阶球谐最小二乘，ridge 1e-6）是全局 C∞ 的，没有脊；代价是不再精确复现每个
> 锚点。**阶数必须低**：4 阶以上会出现龙格式震荡，抖动反而飙升。详见 9.5。

#### ⚠ V_cam 出处必须逐行记录

`V_cam` 决定整张锚点表落在哪个特征空间。锚点表里的 `VcamX/Y/Z` 就是**每一行**生成时
用的那个值，`collect_training_data.py` 启动时会拿它逐行校验，三种情况直接中止训练：

| 情况 | 含义 | 处置 |
|---|---|---|
| 缺这三列 | 加这三列之前导出的旧表 | 重新导出（旧表无法就地升级） |
| 各行 `V_cam` 不一致 | 文件里混了不同批次的导出 | 把各序列都重新导出 |
| 与配置区 `V_CAM` 不符 | 相机/参考原点动过，或常量没跟上 | 按提示改常量，或重新导出 |

**为什么必须是逐行而不是全表一个值**：同一个文件里可能混着不同批次。真踩过一次 ——
25 个锚点里有 15 个是用**错误的参考原点**导出的（在 Sequencer 里调光的关键帧时灯处于
选中状态，导出器把位于世界原点的灯当成了角色原点），`V_cam` 偏 36.9°。全表一个值分不出
这种「混」，逐行才能。而且这种错**全程不报任何错**：训练指标一切正常，上机才发现全错。

> 这份表还有个副作用是好事：`V_cam` 取错时导出器不会再猜。导出现在要求选中项里
> **恰好一个**承载 MMD 材质（暴露 `ShadowSmooth`/`ShadowLocation`/`ExposureScale`
> 三个标量参数）的 Actor，否则中止导出并说明原因。**宁可拒绝，也不猜。**

#### 多角度采集：一个角度一个 Level Sequence

采集约定是**每个光照角度做一个独立的 Level Sequence**，逐个用
`ExportAnchorsFromSequence` 导出。导出器按 note 列的 `"<序列名> "` 前缀合并：

- 其它序列的行 **保留** —— 多圈锚点（赤道圈 / 顶光圈 / 底光圈…）累积成一张表
- 本序列的旧行 **替换** —— 同一序列反复微调不会留下重复行

导出后的通知与 `LogTemp` 日志都会报告「替换 N 行 / 保留 M 行」，据此核对。

#### ⚠ V_cam 的三处来源

`V_cam` 决定整张锚点表落在哪个特征空间。它出现在三个地方：

| 位置 | 取值方式 |
|---|---|
| shader（`Full_AI.hlsl`） | 运行时算 `GetWorldCameraOrigin − GetObjectWorldPosition` |
| 导出器（UE） | 导出时从关卡相机 Actor 解出，**写进每条锚点行的 `VcamX/Y/Z`**，也进日志和完成通知 |
| `collect_training_data.py` | 配置区的常量 `V_CAM`，启动时与锚点表的逐行记录比对，不符即中止 |

后两者以前是「靠人手工同步」，而手工同步会漏 —— 常量就这么悄悄过期过。现在
锚点表自带来处，脚本比对不上就停下并给出可直接粘贴的正确常量行；退出码非 0，
`retrain_all.py` 会因此中止，不会带着错的常量去训练。

**角色原点在脚底时，相机必然高于原点才能拍到全身，所以 `V_cam` 带 Z 分量是正常且
必要的**，不是配置错误。实测值 `(0.0000, 0.9247, 0.3807)`（相机约在身高 71% 处）。

要记住的副作用：`(V_cam, Z_up, Right)` 三个基向量**不再正交**，于是
`LdotV² + L_up² + L_right²` 不再恒等于 1（均匀采样下实测均值 1.0、std 0.20、
范围 0.62~1.38）。**只有 `V_cam` 恰好水平时它才退化成常量 1** —— 所以「平方和恒为 1」
是 `V_CAM` 被配成水平的特征，不是正确性证据。

> 早期版本拿「平方和」当一致性判据，已删除：它只在「脚本 `V_CAM` 是水平、而锚点不是」
> 这一个特例下才触发，挡不住真正踩到的那次（`V_CAM` 非水平、导出器用了另一个非水平
> 的 `V_cam`）。而且锚点特征只有两位小数，几何反推的精度不足以还原 `V_cam` ——
> 实测赤道圈（`L_up≈0`）对 `V_cam` 的 Z 分量几乎没有分辨力。现在直接比 `V_cam` 本身。

### 7.4 一键重训

```bash
cd Latest_Development/AI/AIControl

# 推荐：扣拍摄偏置 + 3 阶光滑标签，64 隐藏层
python retrain_all.py --take-offset --smooth-order 3

# 旧口径（精确穿点的 IDW）：不推荐，会出现逐帧闪烁
python retrain_all.py

# 其它自定义
python retrain_all.py --take-offset --smooth-order 3 --samples 1000 --hidden 32
```

重训后 `Full_AI.hlsl` 与 `Full_Alpha_AI.hlsl` 中 `AUTO-MLP-BEGIN/END` 之间的权重代码
会被自动替换，并在写完后校验两份逐字相同 —— 同一角色身上不透明槽位与半透明槽位必须
共用一套权重，只写一份会让另一份静默停在旧权重。

### 7.5 训练侧回归验证

改完锚点/管线后，`_exp/` 下的诊断脚本是判断"是否又抖了"的尺子（不参与训练）：

| 脚本 | 量什么 |
|---|---|
| `diag_sweep_flicker.py` | 沿 5 条光扫轨迹的逐帧边界位移，>0.5°/帧 的帧占比（人眼可见阈值） |
| `diag_mlp_smoothness.py` | MLP 在球面上的方向导数、`ShadowSmooth` 安全区 |
| `diag_camera_sensitivity.py` | 相机每转 1° 造成的参数跳变（与光扫并列的第二条抖动通路） |
| `explore_merge_radius.py` | 合并半径 / IDW 幂次 / 光滑插值器的对照扫参 |

当前生成物实测：>0.5°/帧 = **0.00%**、>1.0°/帧 = 0.00%、u 极差 0.489（未被抹平）。

---

## 8. 使用步骤

1. 在 UE 中创建材质，按第 3、4 节配置两个 Custom 节点和 8 张贴图
2. **默认 `UseAI=0`（手动模式）**，此时行为与配件增强版完全一致
3. 指定贴图、调整阴影/Rim/Matcap 等参数至满意
4. **开启 `UseAI=1`**，MLP 接管 ShadowSmooth / ShadowLocation / ExposureScale
5. 转动光源方向观察效果——AI 会自动适配不同光照角度
6. 如需微调 AI 行为，编辑 `anchors.csv` 后重训

---

## 9. 关键设计说明

### 9.1 AI 覆盖范围

| 参数 | UseAI=0 | UseAI=1 |
|------|---------|---------|
| ShadowSmooth | 手动值 | **AI 预测** |
| ShadowLocation | 手动值 | **AI 预测** |
| ExposureScale | 手动值 | **AI 预测** |
| 色带参数 (Threshold/End/MidSplit/Sharpness) | 手动值 | 手动值（AI 不覆盖） |
| Rim / Matcap / AO / SSS | 正常 | 正常（无需 AI） |

### 9.2 为什么只预测这 3 个参数

- **ShadowSmooth**：控制明暗交界线的过渡宽度。顶光/极端角时需要自动柔化，避免写实阴影
- **ShadowLocation**：控制阴影的整体偏移。侧光时微调阴影位置，保持风格不漂
- **ExposureScale**：背光时 NdotL<0 阴影参数救不了，只有曝光提亮能防死黑

其余参数（Rim、Matcap 等）要么是确定性几何函数（天生自适应），要么对光照方向不敏感（由贴图/颜色控制），无需 AI 介入。

### 9.3 常量折叠优化

训练后若某输出参数的留出 R² < 0.20（即该参数对光照方向基本无响应），代码生成器会直接
替换为常量值，省略相关的神经元计算分支。当前三个输出对光照方向都有明显响应，未触发折叠；
若某次重训后某列退化，`ai_mlp.hlsl` 里会出现 `float out_X = 常数;  // 常数（留出R² ...）`。

### 9.4 Tonemap 色调映射（独立节点）

示例材质用 `include "/Engine/Private/TonemapCommon.ush"` 的 hack 调用 `FilmToneMapInverse`，该 hack 在 UE 5.8 已失效。本版改为 HLSL 手写 ACES Filmic 正向色调映射：

```
f(x) = x*(2.51x + 0.03) / (x*(2.43x + 0.59) + 0.14)
```

独立 ToneMap 节点，`UseTonemap` 开关控制（默认关闭）。与 ExposureScale 配合：ExposureScale 提亮 -> Tonemap 压缩高光，两者叠加不过曝。

### 9.5 闪烁修复：为什么从 IDW 换成光滑标签

**症状**：光源沿 Level Sequence 扫过时，阴影边界逐帧抖动（闪烁）。实测沿 5 条光扫轨迹，
边界位移 >0.5°/帧 的帧占 **14.2%**，P99 达 1.7°、最大 8.3°。

**根因（两条，已分别排除）**：

1. **标签矛盾**：锚点是 5 条甩拍各自手工校的。相近光向下 `ShadowSmooth` 分歧最大 0.64；
   每条拍摄还带系统性偏置（`正面-0度` SS 中位 −0.38、`正面-65度` SL 中位 +0.54）。
   IDW 精确穿过每个锚点 ⇒ 目标场在矛盾点之间带脊。
2. **容量过拟合**：把这些脊也拟合进去。容量扫描（同一份标签只改 H）——16→1.3%、
   24→5.0%、64→12.7%、256→14.2%。**R² 越高反而抖得越厉害**，因为 R² 是在给矛盾打分。
   （项目早期 24 单元版"彻底根绝闪烁"的说法，正是因为容量小、拟合不动这些脊。）

**处置**：

- 先 `offset_anchors.py` 扣掉每条拍摄的系统性偏置（跨拍摄 |ΔSS| 中位 0.310→0.180）；
- 再用 **3 阶球谐最小二乘**拟合全局光滑场当标签（`collect_training_data.py --smooth-order 3`）；
- `HIDDEN_DEFAULT` 从 256 降回 **64**。

**结果**（同一批轨迹、生成物实测）：

| 指标 | 旧（IDW + 256） | 新（光滑 + 64） |
|---|---|---|
| 边界抖 >0.5°/帧 | 14.2% | **0.00%** |
| 边界抖 >1.0°/帧 | 6.8% | **0.00%** |
| P95 / P99 | 0.88° / 1.71° | 0.18° / 0.31° |
| u 极差（防抹平哨兵） | 0.466 | 0.489 |

**代价与边界**：

- 光滑场不再精确穿过锚点：15/75 行残差 >0.3（残差中位 0.149），最大的是 `正面-65度`
  尾帧被美术推到极值的 `ShadowLocation`（1.79 / 1.98）。要保留这类有意极值，就得回到
  IDW 口径，或把那几帧重录成连续变化。
- 光滑**阶数必须低**：4 阶以上出现龙格式震荡，抖动反而回升到 20~36%。
- 相机运动是**独立**的第二条抖动通路，训练侧改不掉：相机每转 1°，边界中位移 0.12°、
  P95 0.76°。固定机位可忽略；推轨/环绕镜头需要在镜头侧控制转速。见
  `_exp/diag_camera_sensitivity.py`。

---

## 10. 注意事项

1. **贴图必须用 TextureObjectParameter**，不能用 TextureSampleParameter2D
2. **UseAI 默认关闭**：开箱即用为手动模式，与配件增强版行为一致
3. **AI 不覆盖色带分支**：色带（UseRampTex=0）为过时方案，AI 仅对曲线/Ramp 路径生效
4. **AO 依赖 HM 贴图**：UseAO=1 但 UseHM=0 时 AO 无效果
5. **LightDirection 用 SkyAtmosphereLightDirection**：自动跟随场景太阳
6. **法线贴图双守卫**：切线无效 NaN 守卫 + BC5 蓝通道守卫，任一命中退回几何法线
7. **重训后需检查内嵌标记**：确认 `AUTO-MLP-BEGIN` / `AUTO-MLP-END` 标记完整
8. **不透明版与半透明版必须共用同一套权重**：`retrain_all.py` 会同步
   `Full_AI.hlsl` 与 `Full_Alpha_AI.hlsl` 两份并校验逐字相同。推送到 UE 时同样两份材质
   （`M_MMDToon_Full_AI` 与 `M_MMDToon_Full_Alpha_AI`）都要推 —— 角色身上
   `*_Alpha_AI` 槽位挂的是后者，只推一份会出现两套预测参数
9. **闪烁排查顺序**：先看 `_exp/diag_sweep_flicker.py` 的 >0.5°/帧 占比；若标签口径
   还是 IDW，按 7.4 的推荐命令重训；若已用光滑标签仍抖，多半是相机运动（见 9.5）

---

## 11. 文件清单

| 文件 | 说明 |
|------|------|
| `MMDToonShader_SM5_SingleFunc_Full_AI.hlsl` | 主 shader 文件（内嵌 MLP 权重） |
| `MMDToonShader_SM5_SingleFunc_Full_Alpha_AI.hlsl` | 半透明变体（共用同一套权重） |
| `AIControl/anchors.csv` | 锚点表（美术校准的光照->参数映射） |
| `AIControl/offset_anchors.py` | 扣拍摄系统性偏置（`--take-offset`） |
| `AIControl/merge_anchors.py` | 合并同光向重复锚点（可选） |
| `AIControl/collect_training_data.py` | 训练数据采集（IDW / `--smooth-order` 光滑场） |
| `AIControl/fit_mlp.py` | MLP 训练 + HLSL 生成 |
| `AIControl/retrain_all.py` | 一键重训（偏置/光滑+采集+训练+同步两份） |
| `AIControl/ai_mlp.hlsl` | 独立前置节点版 MLP（可选使用） |
| `AIControl/training_data.csv` | 训练数据（自动生成） |
