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

## 修复方向（供参考，最终采用方案 B）

1. 对"低色度/中性"种子做特判：当 `Hct.fromInt(seed).chroma` 低于阈值（如 < 8）时，
   不用 `tonalSpot`，改传 `DynamicSchemeVariant.monochrome`（色度恒 0）或 `neutral`（色度 12），
   或直接将 seed 自身作为 `primary` 用 `copyWith` 固定，保证灰度色产生中性主题。
2. 或在 `AppThemes.build` / `ShadThemes.build` 中检测种子是否为中性色，是则构造中性 `ColorScheme`，
   否则再走 `fromSeed`。
3. 数据源无需改（灰度色值正确）。

## 复现脚本

`temp/seedtest/bin/seedtest.dart`（依赖 Flutter 缓存中的 material_color_utilities 0.13.0），
可直接重跑验证上述 primary 值。

## 修复实施演进

### 最终采用：方案 A+C（最简单，已实施）

对中性 seed 统一用 `DynamicSchemeVariant.monochrome`（色度恒 0），明暗跟随**全局暗色开关**
（与彩色 seed 一致）；彩色 seed 保持默认 `tonalSpot`。两端（Material / ShadCN）共用
`buildSeedColorScheme`，保证同步换肤。不自定义 ShadCN 色板。

- 代码最小：仅 `seed_scheme.dart` 一处判定 + 一个生成函数，`app_theme.dart` / `shad_theme.dart`
  都只调用 `buildSeedColorScheme(seed, brightness)`。
- 已知取舍：所有中性 seed 在暗色模式下都渲染成同一套深色中性主题（背景近黑、品牌色近白），
  在亮色模式下都渲染成同一套浅色中性主题；即"不同灰度彼此观感接近"。这是 monochrome + 全局
  开关的固有行为，用户已接受（见下方回退说明）。

### 方案 B（曾试，已回退，备忘）

为避免"所有中性色没区别"，曾尝试：中性明暗由 **seed 自身亮度**决定（米白→浅、墨黑→深），
且 ShadCN 端改用 shadcn_ui 内置 `ShadNeutralColorScheme`。实测观感未提升、且引入较多自定义
ShadCN 代码，故回退到上面的方案 A+C。两条思路保留在 `seed_scheme.dart` 顶部注释中作备选。

改动文件（2026-08-17）：

- 新增 `lib/models/seed_scheme.dart`：
  - `isNeutralSeed(Color)` —— 通道最大差值 ≤ 26 判定中性灰度色（全色库扫描恰好命中
    通用组 6 个灰度尾色 + 深邃组黑曜石，不误伤米色/奶油棕/灰豆绿等浅彩色）；
  - `buildSeedColorScheme(Color, Brightness)` —— 中性走 monochrome（明暗=传入 brightness），
    否则 tonalSpot。
- `lib/models/app_theme.dart`：`AppThemes.build` 改用 `buildSeedColorScheme`（Material 主题）。
- `lib/models/shad_theme.dart`：`ShadThemes.build` 同样调用 `buildSeedColorScheme`，再映射到
  `ShadSlateColorScheme`（原行为，无自定义中性色板）；switch 未选中轨道用 `m3.surfaceContainerHighest`。
- 回归测试 `test/theme_neutral_verify_test.dart`：中性识别 + monochrome 输出为灰度 + 彩色不误判。

验证：

- `flutter analyze` 三个 model 文件 + 测试：No issues found。
- `flutter test test/theme_neutral_verify_test.dart`：全过。

修复前后对照（中性 seed 经 monochrome）：

| 颜色 | 修复前(tonalSpot) | 方案 A+C 结果 |
|---|---|---|
| 石墨灰 `#56616F` | `#33618D` 蓝 | 中性（色度 0） |
| 雾灰 `#78828C` | `#28638A` 蓝 | 中性 |
| 米白 `#F5F5F5` | `#006874` 青 | 中性 |
| 瓷白 `#FAFAFA` | `#006874` 青 | 中性 |
| 墨黑 `#171717` | `#006874` 青 | 中性 |
| 纯黑 `#000000` | `#8C4A60` 粉紫 | 中性 |

对照（不受影响，仍为 tonalSpot 彩色）：蓝色 `#2563EB`→`#4B5C92`、灰豆绿 `#A9BFA3`→`#3B693A`、米色 `#D4C5A0`→`#725C0C`。

要点：6 个灰度尾色都不再被染成彩色，得到真正中性主题；彩色/浅彩色种子行为完全不变。
