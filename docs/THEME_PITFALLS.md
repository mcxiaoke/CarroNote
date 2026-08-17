# 主题踩坑记录与解决方案（M3 ColorScheme 系列问题）

> 汇集 Safenotes 动态品牌色（seed 色库 → ColorScheme.fromSeed）实现中踩过的坑与最终解法。
> 共性问题根源于：**M3 的 fromSeed 不是"把 seed 当主题色"，而是"用 seed 生成一套对比度
> 合规的协调色板"**，且明暗色板行为不同。本文记录每个坑的现象、根因、修复。

## 背景：双主题体系

Material（`lib/models/app_theme.dart`，`AppThemes.build`）与 ShadCN（`lib/models/shad_theme.dart`，
`ShadThemes.build`）两套主题并存，共用 `lib/models/seed_scheme.dart` 的 `buildSeedColorScheme`
生成 M3 色板。**改配色必须两端同步**，否则出现"按钮新色、列表旧色"的割裂。

## 坑 1：灰度 seed 被渲染成彩色（米白偏青、纯黑偏粉紫）

- 现象：通用分组 6 个灰度尾色（石墨灰/雾灰/米白/瓷白/墨黑/纯黑）应用后主题变彩色。
- 根因：`tonalSpot` 变体把 primary 色度硬编码为 36，**丢弃 seed 的明暗与饱和度，只取 HCT 色相**；
  灰度 seed 的 hue 是无意义伪色相（米白→209.5 青、纯黑→0 粉紫），被按高色度放大成彩色。
  彩色 seed 有真实 hue，放大后仍是协调彩色，所以"彩色正常、灰度变彩"。
- 修复（方案 A+C）：`seed_scheme.dart` 新增 `isNeutralSeed`（RGB 最大差值 ≤ 26），
  中性 seed 走 `DynamicSchemeVariant.monochrome`（色度恒 0），彩色保持 `tonalSpot`。
  详见 `docs/THEME_COLOR_INVESTIGATION.md`。
- 已知取舍：monochrome 下所有中性 seed 明暗色板彼此观感接近（暗色都近黑、亮色都近白），已接受。

## 坑 2：暗色模式下 primary 被提亮，AppBar 刺眼（黑 seed 变纯白）

- 现象：暗色模式下 AppBar 太亮；选黑色 seed 时 AppBar 直接变成白色。
- 根因：**M3 暗色面板会把 primary 提亮成浅色**（以便 onPrimary 用深色保证对比）。
  经实测：monochrome 黑色 seed 暗色下 `primary=#ffffff` 纯白；彩色 blue seed 暗色下
  `primary=#a0cafd` 浅蓝，而亮色下是 `#36618e` 深蓝。
- 修复：AppBar/状态栏背景固定用**亮色板**生成的 `primary`（`buildSeedColorScheme(seed, Brightness.light)`），
  即用户认知里的"按钮深色"（黑=纯黑、蓝=深蓝），亮/暗观感一致。
- 注意：这里并非"暗色不用亮色板的场景"——暗色模式我们最终让 AppBar 跟随页面背景
  `surfaceContainerLow`（见坑 4），亮色模式才用亮色板 primary。

## 坑 3：暗色模式下 error 被提亮成浅粉，destructive 按钮变粉色

- 现象：alertDialog 的 destructive 按钮暗色模式下变浅粉色。
- 根因：与坑 2 同源——M3 暗色面板把 `error` 提亮成 `#ffb4ab` 浅粉（亮色下是深红 `#ba1a1a`）。
- 修复：两端同步，error/onError 恒定用**亮色板**值：
  - Material（`app_theme.dart`）：`scheme.copyWith(error: 亮色板.error, onError: 亮色板.onError)`
    作为 ThemeData.colorScheme。
  - ShadCN（`shad_theme.dart`）：`destructive / destructiveForeground` 映射到亮色板 error。
- 关键坑：对话框按钮（AlertDialog + FilledButton）走 Material 的 `Theme.colorScheme.error`，
  **只改 Shad 面板不生效**，两端都要改。

## 坑 4：AppBar 滚动变色的根因（backgroundColor 为 null 时）

- 现象：亮色滚动不变色、暗色滚动变色。
- 根因（Flutter `app_bar.dart:935-940`）：滚动时 `scrolledUnderBackground` 由 `_resolveColor`
  解析，`backgroundColor` 为 null 时**落到 `colorScheme.surfaceContainer`（比 surface 亮一档）**。
  亮色因显式设了 primary 被兜住，暗色传 null 就露馅。
- 修复：暗色模式 `backgroundColor` 显式设 `scheme.surface`（即 M3 默认 AppBar 背景，观感等同
  不设置），滚动时被 `_resolveColor` 兜住，不再跳到 surfaceContainer。
- 教训：**不要依赖"不设置 = 默认"**。只要期望值等同默认，也应显式赋值，才能让滚动兜底逻辑生效。

## 坑 5：状态栏（SystemUiOverlayStyle）要随 AppBar 同步

- 现象/要求：状态栏颜色需与 AppBar 一致，图标亮度要按背景色选。
- 做法：在 `appBarTheme.systemOverlayStyle` 显式设 `statusBarColor`（跟随 AppBar 背景）
  与 `statusBarIconBrightness: Brightness.light`（深色背景下用亮色图标）。
  暗色模式若走默认背景，可直接传 null 交给 AppBar 自动按背景亮度计算。

## 排查工具备忘

- 用临时 `flutter test` 脚本打印 `ColorScheme.fromSeed` 各角色色值（light/dark × 不同 seed），
  可快速确认 primary/error 的实际渲染值，避免凭直觉猜颜色。
- 例：黑色 seed 暗色 `primary=#ffffff`、`error=#ffb4ab`；亮色 `primary=#000000`、`error=#ba1a1a`。
