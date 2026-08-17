# 主题换色问题调查报告（灰度色变彩色）

> 调查时间：2026-08-17
> 范围：仅调查，未修改任何代码。
> 现象：通用分组最后 6 个灰度色（石墨灰/雾灰/米白/瓷白/墨黑/纯黑）应用后主题变成彩色，
> 米白/瓷白/墨黑偏青色，纯黑偏粉紫色；彩色都正常。

## 结论（根因）

主题色不是"直接用 seed 颜色"，而是经过 Flutter 的 `ColorScheme.fromSeed()` 重新生成整套 M3 调色板。
默认变体 `tonalSpot` 的关键实现（material_color_utilities 0.13.0，`scheme_tonal_spot.dart`）：

```dart
primaryPalette: TonalPalette.of(sourceColorHct.hue, 36.0),
```

**`primary` 色板的色度被硬编码为 36.0，完全忽略 seed 自身的色度，只取 seed 的 HCT 色相（hue）。**
对于接近中性的灰度色，HCT 的 hue 是一个"伪色相"（由 CAM16 白点适配/舍入决定，没有真实色彩含义），
于是 `tonalSpot` 把这个无意义色相按固定高色度放大，UI 整体变成彩色。

- 米白/瓷白/墨黑 → HCT hue ≈ 209.5（青/蓝绿）→ 主题变青
- 纯黑 `#000000` → HCT hue = 0 → 主题变粉紫

彩色种子之所以"正常"，是因为它们有真实、明确的 hue，放大后仍是一个协调的彩色主题，符合预期。
灰度种子则被赋了一个任意 hue，所以"彩色正常、灰度变彩"。

## 涉及代码位置

- `lib/models/app_theme.dart:71` — `ColorScheme.fromSeed(seedColor: seed, brightness: ...)`
- `lib/models/shad_theme.dart:24` — 同样 `ColorScheme.fromSeed(seedColor: seed, ...)`，并把
  `m3.primary` 映射到 Shad 的 `primary/ring/accent` 等，所以 Material 与 ShadCN 两端都受影响。
- `lib/models/app_theme.dart:44` — `seedColor` 返回的正是原始 seed（`#F5F5F5` 等），未被改动后传入。
- `lib/data/theme_colors.json` / `lib/models/theme_seeds.g.dart` — 灰度色值本身正确，不是数据源问题。

## 复现证据（独立 Dart 脚本，使用与 Flutter 相同的 material_color_utilities 0.13.0）

| seed（通用组尾色） | HCT hue | 亮色 primary | 实际观感 |
|---|---|---|---|
| 米白 `#F5F5F5` | 209.5 | `#006874` | 青/蓝绿 |
| 瓷白 `#FAFAFA` | 209.5 | `#006874` | 青/蓝绿 |
| 墨黑 `#171717` | 209.5 | `#006874` | 青/蓝绿 |
| 纯黑 `#000000` | 0.0 | `#8C4A60` | 粉紫/酒红 |

对照（彩色，仅验证 hue 被保留，primary 也非 seed 本身）：

| seed | HCT hue | 亮色 primary |
|---|---|---|
| 蓝色 `#2563EB` | 272.2 | `#4B5C92` |
| 薄荷绿 `#2A9D8F` | 185.2 | `#006A60` |
| 李子紫 `#A855B7` | 326.3 | `#7A4F80` |

附带影响：不仅是 `primary`，`secondary/tertiary` 与 `surfaceContainerLow`（页面背景）也都带该 hue 的轻染。
例如米白在亮色下 `surfaceContainerLow = #EFF5F6`（轻微青染），整页背景也偏青——与"整体偏青"一致。
暗色模式下同样复现（米白→`#82D3E0` 亮青、纯黑→`#FFB1C8` 亮粉）。

## 为什么"彩色正常、灰度变彩"

`fromSeed` 的设计目的本就不是"把 seed 当主题色"，而是"用 seed 的 hue 生成一套对比度合规的协调色板"。
它对任何 seed 都会丢弃 seed 的明暗与饱和度，只保留 hue。彩色种子 hue 有意义 → 主题协调 → 用户感知"正确"；
灰度种子 hue 是无意义残值 → 主题被染成任意彩色 → 用户感知"bug"。

注意：即使是彩色种子，其 `primary` 也不是 seed 本身（如蓝色 seed → `#4B5C92` 而非 `#2563EB`），
这是 M3 的既定行为，并非本次问题。

## 修复方向（未实施，供参考）

1. 对"低色度/中性"种子做特判：当 `Hct.fromInt(seed).chroma` 低于阈值（如 < 8）时，
   不用 `tonalSpot`，改传 `DynamicSchemeVariant.monochrome`（色度恒 0）或 `neutral`（色度 12），
   或直接将 seed 自身作为 `primary` 用 `copyWith` 固定，保证灰度色产生中性主题。
2. 或在 `AppThemes.build` / `ShadThemes.build` 中检测种子是否为中性色，是则构造中性 `ColorScheme`，
   否则再走 `fromSeed`。
3. 数据源无需改（灰度色值正确）。

## 复现脚本

`temp/seedtest/bin/seedtest.dart`（依赖 Flutter 缓存中的 material_color_utilities 0.13.0），
可直接重跑验证上述 primary 值。
