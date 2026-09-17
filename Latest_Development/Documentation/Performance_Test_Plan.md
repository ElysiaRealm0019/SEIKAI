# 性能与兼容性测试计划：MMD Toon Shader / Full_AI

> 关联：`Documentation/MMDToonShader_Full_AI_使用文档.md`（9.5 闪烁修复）、
> shader 文件 `AI/MMDToonShader_SM5_SingleFunc_Full_AI.hlsl`。
> 目标：回答一个问题——**这套 AI 着色器到底需不需要针对各家 GPU 做适配。**

---

## 0. 结论前置（TL;DR）

- 现代设备（桌面独显、M1、8 Elite、8 Gen 2、Tensor G2 级）上，MLP 只占个位数到 ~20% 的
  ALU 预算，**无需厂商适配**。
- **麒麟 710F / iPhone 6S 不列为目标设备**：现代二次元游戏的受众不会用这类设备，
  为其做适配是负 ROI。本计划只把它们记为「非目标」，不进入通过判据。
- 建议**最低支持线**：Adreno 6xx / Mali-G7x / Apple A13 级以上（约 2019 中高端，
  FP32 ≥ ~2 TFLOPS）。Tensor G2 是这条线附近的最低数据点。
- 在此线之上不做 per-vendor 适配，正常出包；真要覆盖更低的设备，优先做两件与厂商无关
  的事：**把全屏恒定的 AI 输出提到每帧算一次**、**质量分级**，而不是微调这 ~450 条指令。

---

## 1. 设备与预期分档

MLP 部分约 450 条标量 ALU/像素。下表按 1080p、60fps、FP32 粗估
（手机内部分辨率通常更低，实际压力再降一截）：

| 设备 | GPU | 粗算吞吐 | MLP 占比 | 角色 |
|---|---|---|---|---|
| R5 9600X + RTX 5070 | Blackwell | ~30+ TFLOPS | <0.5% | 正确性基线 |
| R7 4800H + RTX 3060 Laptop | Ampere | ~10–13 TFLOPS | ~1% | 正确性基线 |
| MacBook · M1 (8 核 GPU, 8GB) | Apple GPU | ~2.6 TFLOPS | ~4–5% | **Metal 兼容性代理** |
| 手机 · 骁龙 8 Elite | Adreno 830 | ~4–5 TFLOPS | ~2–3% | 现代移动基线 |
| 手机/平板 · 骁龙 8 Gen 2 | Adreno 740 | ~2–3 TFLOPS | ~4–5% | 主目标档 |
| 手机 · Tensor G2 | Mali-G710 MP7 | ~0.6–1 TFLOPS | ~10–20% | 最低支持线数据点 |
| 手机 · 麒麟 710F | Mali-G51 MP4 | ~0.1–0.15 TFLOPS | **70–100%+** | **非目标**（仅记录） |
| 手机 · iPhone 6S | A9 / PowerVR GT7600 | ~0.1–0.25 TFLOPS | ~25–50% | **非目标**（仅记录） |

> 数字是量级估计，真实值取决于 FMA 融合、FP16、tile GPU 占用率与分辨率。

---

## 2. 测试项

### 2.1 兼容性（先做，不通后面免谈）

| 项 | 内容 |
|---|---|
| 平台目标 | Android: Vulkan ES3.1 / iOS: Metal |
| 关键风险 | `LWCToFloat`、`GetWorldCameraOrigin` 等 LWC/引擎函数在移动目标是否可用 |
| 判定 | 能 cook、能启动、材质不回落 Default Material（查 Output Log 的 `Failed to compile`） |
| 兜底 | 若某函数不可用，用等价的移动可用表达式替换（例如相机位置由 MPC 传入） |

### 2.2 正确性（画面）

- 同一场景、同一机位、同一光照，对比桌面基线截图与参考图
  （见 `AI/_ue_shots/`，6 张根目录参考图）。
- 重点看：暗部是否保留色彩（cel 质感）、Rim/高光/发丝是否正常、有无回落默认材质。

### 2.3 性能

- 固定机位、固定分辨率（打开 `r.ScreenPercentage` 记录实际渲染分辨率）。
- A/B 三组：
  1. `UseAI=0`（关 AI）
  2. `UseAI=1`（当前实现，逐像素推理）
  3. 若已实现：AI 输出提到 MPC/每帧一次 的版本
- 记录 Δ（2−1）即 AI 的净成本；Δ（2−3）验证「提常数」这个杠杆值多少。

---

## 3. 测量方法

### 3.1 引擎内

```
stat unit          # Frame / Game / Draw / GPU 的 ms
stat gpu           # 各 pass 细分
stat rhi
profilegpu         # 抓一帧 GPU 时间线（CSV/截图）
r.ScreenPercentage 100   # 固定内部分辨率，避免动态分辨率干扰
```

- **用 Shipping/Test 配置测帧率**，别用 Development/Debug（校验与调试层会严重拖慢）。
- 固定 CineCamera（如项目里的 `CineCameraActor_1`），避免编辑器视口抖动。
- 热机 5–10 分钟后再读数，避开首帧编译与瞬时睿频。

### 3.2 发热与持续性能

- 移动端记录：起始 GPU ms → 10 分钟后 GPU ms（热降频幅度）。
- 有条件的话记录功耗/温度（PerfDog、Xcode Instruments、Adreno GPU Profiler、Arm Mobile Studio）。

---

## 4. 各设备具体动作

| 设备 | 动作 | 期望 |
|---|---|---|
| 5070 / 3060 Laptop | 正确性截图 + `stat unit` 基线 | 全部通过，作为「地面真值」 |
| M1 (8GB) | 先验证 Metal 编译与正确性，再读打包版性能 | 作为 6S 的对照：把 Metal 路径问题与「老旧设备」问题分开 |
| 8 Elite | 正确性截图 + A/B 性能 | AI 净成本 <1ms，无热问题 |
| 8 Gen 2（手机+平板） | 同上 | AI 净成本个位数 ms 内，可接受 |
| Tensor G2 | 同上 + 热机 10 分钟 | 作为最低支持线：确认 A/B 与热机后仍达标 |
| 麒麟 710F | 不测（非目标） | 可选：仅编译一次留档，判断是否需在配置里硬性排除 |
| iPhone 6S | 不测（非目标） | 同上 |

---

## 5. 通过 / 失败判据

- **兼容通过**：目标平台能 cook、运行、不回落默认材质。
- **性能通过**：在目标帧率预算内（如 60fps → 16.6ms；30fps → 33.3ms），
  AI 净成本不把总帧时推过预算，热机后仍达标。
- **不合格处置顺序**：① 提常数到 MPC → ② 移动端开 FP16 → ③ 质量分级关 AI → ④ 砍特性。

---

## 6. 已知风险清单

1. **移动编译**：LWC 相关函数、Custom 节点在 ES3.1/Metal 的可用性（最可能翻车点）。
2. **寄存器压力**：64 个 `h_i` 同时存活；移动 tile GPU 对 occupancy 敏感。
3. **Overdraw**：半透明头发/多材质槽叠加会把成本翻倍。
4. **热降频**：峰值数据不代表持续表现。
5. **动态分辨率**：会掩盖真实成本，测性能时务必固定 `r.ScreenPercentage`。
6. **桌面 Metal ≠ 移动 Metal**：M1 能过不等于 iPhone 6S 能过——特性集与最低 iOS 版本
   不同。M1 只用于排除「Metal 后端整体不工作」，6S 仍需单独验证编译。
7. **M1 8GB 内存**：UE5.8 编辑器本身就吃紧，性能数据务必在打包版里读。

---

## 7. 结果记录表（待填）

| 设备 | 平台目标 | 编译 | UseAI=0 GPU(ms) | UseAI=1 GPU(ms) | ΔAI | 热机后 | 备注/截图 |
|---|---|---|---|---|---|---|---|
| 5070 | SM5 | | | | | | |
| 3060 Laptop | SM5 | | | | | | |
| M1 (8GB) | Metal | | | | | | 打包版测，回避 8GB 编辑器内存瓶颈 |
| 8 Elite | Vulkan | | | | | | |
| 8 Gen 2（手机） | Vulkan | | | | | | |
| 8 Gen 2（平板） | Vulkan | | | | | | |
| Tensor G2 | Vulkan | | | | | | 最低支持线 |
| 麒麟 710F | Vulkan | | — | — | — | — | 非目标，不测 |
| iPhone 6S | Metal | | — | — | — | — | 非目标，不测 |

---

## 8. 结论与后续

- **目标平台 = 现代设备（最低支持线：Adreno 6xx / Mali-G7x / Apple A13 级）**：
  不做 per-vendor 适配，正常出包。回归集：5070 / M1 / 8 Gen 2 / Tensor G2
  （M1 顺带守住 Metal 后端）。
- 麒麟 710F / iPhone 6S **不列为目标**，不进入通过判据；如需在启动时硬性排除低端设备，
  用设备档次查询在项目侧做，而不是改 shader。
- 若将来真要覆盖更低设备：按第 5 节顺序优化，优先「提常数」+「质量分级」，不写厂商分支。
- 不建议为 MLP 写 per-vendor intrinsic（FP16/int8 可按目标平台统一开，而非分厂商手写）。
