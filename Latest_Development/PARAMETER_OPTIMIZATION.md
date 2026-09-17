# 参数优化记录

## 优化日期
2026/9/4

## 优化内容

### 合并的参数对（4 组）

#### 1. 高光参数
**删除**：`SpecularStrength` (Float1, 默认 0.5)
**保留**：`SpecularColor` (Float3, 默认改为 (0.5, 0.5, 0.5))
**说明**：强度通过颜色亮度控制，白色=全强度，黑色=关闭

#### 2. Rim Light 参数
**删除**：`RimIntensity` (Float1, 默认 1.0)
**保留**：`RimColor` (Float3, 默认 (1.0, 1.0, 1.0))
**说明**：强度通过颜色亮度控制

#### 3. 头发高光参数
**删除**：`HairHighlightIntensity` (Float1, 默认 1.0)
**保留**：`HairHighlightColor` (Float3, 默认 (1.0, 1.0, 1.0))
**说明**：强度通过颜色亮度控制，纯黑=关闭整个头发高光

#### 4. Matcap 参数
**删除**：`MatcapInfluence` (Float1, 默认 1.0)
**保留**：`MatcapColor` (Float3, 默认 (1.0, 1.0, 1.0))
**说明**：强度通过颜色亮度控制，可调色温或染色

## 代码修改

### 修改前
```hlsl
ResultColor += Spec * SpecularStrength * SpecularColor;
ResultColor += RimColor * Rim * RimIntensity;
ResultColor += HairTint * HairHighlightColor * HairShape * SpecMask * HairHighlightIntensity;
ResultColor += MatcapSample * MatcapColor * MatcapMask * MatcapInfluence;
```

### 修改后
```hlsl
ResultColor += Spec * SpecularColor;
ResultColor += RimColor * Rim;
ResultColor += HairTint * HairHighlightColor * HairShape * SpecMask;
ResultColor += MatcapSample * MatcapColor * MatcapMask;
```

## 影响分析

### 参数数量变化
- 修改前：44 个参数
- 修改后：40 个参数
- 减少：4 个参数

### 文件大小变化
- 修改前：31580 字节
- 修改后：31279 字节
- 减少：301 字节

### 动画驱动影响
- 删除的参数原本适合逐帧驱动（改变强度）
- 现在需要通过颜色亮度控制强度，对动画驱动不太直观
- 建议：如果需要动画驱动强度，可在材质实例中使用 Scalar Parameter 控制颜色亮度

## 保留的参数

### 仍然独立的参数对
| 参数对 | 原因 |
|--------|------|
| `TintIntensity` / `TintMode` | 强度用于动画，模式是开关 |
| `ShadowThreshold` / `ShadowEnd` | T1/T3 是独立绝对坐标 |
| `SpecularThreshold` / `SpecularSoftness` | 截断位置和过渡宽度独立 |
| `RimWidth` / `RimGradient` | 宽度和渐变独立控制 |
| `Saturation` / `ShadowSaturation` | 全局 vs 阴影专用 |

### HSV 参数
保留 `ShadowHueShift`、`ShadowSaturation`、`ShadowBrightness` 三个独立参数，因为：
1. 分别控制色相、饱和度、亮度
2. 动画驱动时需要独立控制
3. 合并为 Float3 会损失独立性

## 兼容性说明

### 破坏性修改
- 删除了 4 个参数，现有材质实例需要更新
- 需要调整默认值以保持相同效果

### 迁移指南
1. **SpecularStrength + SpecularColor** → 调整 SpecularColor 亮度
2. **RimIntensity + RimColor** → 调整 RimColor 亮度
3. **HairHighlightIntensity + HairHighlightColor** → 调整 HairHighlightColor 亮度
4. **MatcapInfluence + MatcapColor** → 调整 MatcapColor 亮度