# 主题系统总览 (Theme System Overview)

> 合并并简化自 `THEME_PITFALLS.md` 与 `THEME_COLOR_INVESTIGATION.md`，
> 并补充本 app 双主题体系、颜色角色、按钮与 AppBar 的特殊处理。
> 涉及文件：`lib/models/seed_scheme.dart`、`lib/models/app_theme.dart`、
> `lib/models/shad_theme.dart`、`lib/utils/env_config.dart`。

---

## 1. 两套主题体系并存

| 体系 | 入口 | 负责范围 |
|---|---|---|
| **Material (M3)** | `AppThemes.build` (`app_theme.dart`) | 原生 `ThemeData`、AppBar、原生 FilledButton/OutlinedButton、对话框、输入框 |
| **ShadCN (shadcn_ui)** | `ShadThemes.build` (`shad_theme.dart`) | `ShadXxx` 组件（按钮、输入、对话框、switch 等） |

- 两端共用 `buildSeedColorScheme(seed, brightness)`（`seed_scheme.dart`）生成 M3 色板，
  **改品牌色必须两端同步**，否则会出现“按钮新色、列表旧色”的割裂。
- 中性（灰度）seed 走 `monochrome`（色度恒 0）；彩色 seed 走 `tonalSpot`。
  判定在 `seed_scheme.dart: isNeutralSeed`（RGB 通道最大差值 ≤ 26）→ 中性；`buildSeedColorScheme` 内部据此选 variant。
- 本质约束：**`ColorScheme.fromSeed` 不是“把 seed 当主题色”，而是“用 seed 的 hue 生成对比度合规的协调色板”**。
  primary 只继承 seed 的 hue，chroma 被算法固定、tone 被算法固定，任何 seed 的 primary 都不是 seed 本身。

---

## 2. 颜色角色与映射

### M3 关键角色语义（易混，务必记清）
- `primary` / `onPrimary`：主色 / 主色上的文字。**注意 `primary` 常作“文字/强调色”使用。**
- `primaryContainer` / `onPrimaryContainer`：**容器背景色** / **该背景上的文字色**。
  （奶油主题下 `primaryContainer` ≈ 浅奶油，`onPrimaryContainer` ≈ 深色文字。）
- `error` / `onError`、`secondary…`、`surface` / `surfaceContainerLow…` 等按 M3 标准语义。

### Material ColorScheme → ShadColorScheme 映射（`shad_theme.dart`）

| Shad 键 | 来源 | 用途 |
|---|---|---|
| `primary` | `m3.primary` | **outline/link 按钮文字、焦点环 ring** |
| `primaryForeground` | `m3.onPrimary` | primary 上的文字 |
| `secondary` | `m3.secondary` | — |
| `secondaryForeground` | `m3.onSecondary` | — |
| `accent` | `m3.primaryContainer` | 次按钮背景 |
| `accentForeground` | `m3.onPrimaryContainer` | 次按钮文字 |
| `destructive` / `destructiveForeground` | 亮色板 `error` / `onError` | 危险/删除按钮 |
| `ring` | `m3.primary` | 焦点环 |
| `selection` | `m3.primary` @20% | 选区高亮 |

> 中性基底沿用 `ShadSlateColorScheme`（背景/卡片/边框不随品牌色走）。

---

## 3. 按钮颜色特殊处理（重点）

### shadcn 按钮按变体各自读自己的 `ShadButtonTheme`
`button.dart` 中 `primary→primaryButtonTheme`、`outline→outlineButtonTheme`、
`link→linkButtonTheme`、`ghost→ghostButtonTheme`… 每类变体的背景/前景都来自对应主题。

### 关键坑：outline/link 的文字色取自 `colorScheme.primary`
- `ShadButton.outline`、`ShadButton.raw(link)` 的**文字色 = `primary`**。
- 若把全局 `primary` 设成 `primaryContainer`（浅色），outline/link 文字会变浅、压不住浅背景 → 不可读。

### 正确做法（让填充主按钮用奶油色，且不破坏其它）
1. **全局 `primary` 保持 `m3.primary`**（深品牌色）—— 专门给 outline/link 文字与 ring 用。
2. **只给 `primaryButtonTheme` 单独覆盖**：
   ```dart
   primaryButtonTheme: ShadButtonTheme(
     backgroundColor: m3.primaryContainer,   // 奶油背景
     foregroundColor: m3.onPrimaryContainer,  // 深色文字
     textStyle: ...,
   ),
   ```
   填充主按钮 `ShadButton`（primary 变体）即呈“奶油背景 + 深色文字”。
3. Material 侧（`app_theme.dart`）的 `filledButtonTheme` / `outlinedButtonTheme` 等只兜底
   未显式定制的裸控件，沿用 M3 默认（filled 用 `primary`）。

> 结论：**“填充按钮背景用 primaryContainer” ≠ 把全局 primary 改成 primaryContainer。**
> 前者只动 `primaryButtonTheme`，后者会牵连 outline/link 文字。

---

## 4. AppBar 特殊处理（重点）

### 全局 `appBarTheme`（`app_theme.dart`）
- **亮色模式**：
  - 背景 = **亮色板**的 `primaryContainer`（奶油色），前景 = `onPrimaryContainer`（深色）
  - 状态栏同步为该奶油色，`statusBarIconBrightness: Brightness.dark`（深色图标）
  - 用“亮色板”色值是为了规避 M3 暗色把 primary 提亮的坑（见 §5 坑 B）
- **暗色模式**：
  - 背景 = `scheme.surface`（中性深），前景 = `scheme.onSurface`（亮色），状态栏交默认（null）
- 固定 `surfaceTintColor: Colors.transparent` + `scrolledUnderElevation: 0`
  （显式赋值，避免滚动兜底逻辑把背景跳到 `surfaceContainer`）。

### 部分页面显式把 AppBar 设透明（露出页面背景）
`login.dart` / `set_passphrase.dart` / `change_passphrase.dart` 均覆盖为：
```dart
appBar: AppBar(
  backgroundColor: Colors.transparent,
  elevation: 0,
  scrolledUnderElevation: 0,
  title: Text('...', style: appBarTitle.copyWith(
    color: Theme.of(context).colorScheme.onSurface,
  )),
  centerTitle: true,
),
```
> 这些页的 AppBar 全局 `primaryContainer` 配色不生效（被透明覆盖）；其余页面才显示奶油色 AppBar。

---

## 5. 踩坑与特殊处理（简化自两份旧文档）

| # | 现象 | 根因 | 处理 |
|---|---|---|---|
| A | 灰度 seed 应用后变彩色（米白偏青、纯黑偏粉紫） | `tonalSpot` 把 primary 色度硬编码 36，**只取 seed 的 HCT hue**；中性 seed 的 hue 是无意义伪色相，被按高色度放大 | 中性 seed 走 `monochrome`（`isNeutralSeed`：通道最大差值 ≤ 26）。彩色保持 `tonalSpot` |
| B | 暗色下 AppBar 太亮（黑 seed 变纯白 AppBar） | M3 暗色面板把 `primary` 提亮（黑→`#fff`、蓝→浅蓝） | AppBar/状态栏背景用**亮色板**色值，明暗观感一致 |
| C | 暗色下 destructive/error 按钮变浅粉 | 同 B，`error` 暗色被提亮成 `#ffb4ab` | `error`/`onError` 两端（Material + ShadCN）均用**亮色板**值 |
| D | AppBar 滚动时变色 | `backgroundColor` 为 null 时，Flutter 滚动兜底落到 `colorScheme.surfaceContainer`（比 surface 亮一档） | 显式赋值 `backgroundColor`（含暗色 `scheme.surface`），不依赖“不设置=默认” |
| E | 状态栏与 AppBar 不一致 | 状态栏图标亮度需随背景计算 | `systemOverlayStyle` 同步 `statusBarColor` 与 `statusBarIconBrightness` |

补充说明：
- 坑 A 是“彩色正常、灰度变彩”的根本原因：彩色 seed 有真实 hue → 协调；灰度 seed 的 hue 是残值 → 被染彩。
- 坑 C 尤其要注意：对话框按钮走 Material `Theme.colorScheme.error`，**只改 Shad 面板不生效**，两端都改。
- 已知取舍：所有中性 seed 在暗/亮模式下观感各自趋同（暗都近黑、亮都近白），已接受。

---

## 6. 调试与实验手段

- **环境变量换色**：`lib/utils/env_config.dart` 解析 `SN_THEME_DSV`（tonalSpot/monochrome/neutral/vibrant/expressive/fidelity）与 `SN_ENV_VARS`，可临时切换 `DynamicSchemeVariant` 看效果，无需改代码。
- **登录页对比截图**：`scripts/screenshot_login.py` 对每个 variant 启动 app 截登录页（带 `SN_DATA_DIR`/`SN_THEME_DSV`），产物在 `temp/screenshots/`。
- **独立打印色值**：用 `material_color_utilities` 直接 `ColorScheme.fromSeed` 打印各角色，快速确认 primary/error 实际渲染值，避免凭直觉猜色。

---

## 7. 修改清单（本系列涉及的文件）

- `lib/models/seed_scheme.dart`：`isNeutralSeed` + `buildSeedColorScheme`（中性→monochrome）。
- `lib/models/app_theme.dart`：AppBar 用亮色板 primaryContainer；error 用亮色板；暗色 `surface`。
- `lib/models/shad_theme.dart`：`primary`/`primaryForeground` 保留为 `m3.primary`/`m3.onPrimary`；
  `accent`=`primaryContainer`；`destructive`=亮色板 error；**`primaryButtonTheme` 单独设 primaryContainer/onPrimaryContainer**。
- `lib/views/authentication/login.dart`、`set_passphrase.dart`、`change_passphrase.dart`：AppBar 透明覆盖。
- `lib/utils/env_config.dart`：环境变量 → `DynamicSchemeVariant`。
