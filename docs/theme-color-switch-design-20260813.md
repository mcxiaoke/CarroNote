# 实时主题颜色切换 — 设计方案（v3：JSON 分组色库 + 双语）

> 日期：2026-08-13
> 状态：方案评审中（未实施）
> 涉及：flex_color_scheme 8.4.0、shadcn_ui 0.56.1
> 源码参考：F:\Develop\github\flex_color_scheme、F:\Develop\github\flutter-shadcn-ui
> 数据源：`temp/theme_colors.json`（已调整，正式位置待定）

## 1. 背景与目标

Safenotes 目前只支持「明暗模式」实时切换，品牌色（seed）是硬编码常量，用户无法换肤。
目标：让用户能在**运行中实时更换主题颜色**（品牌色），无需重启、立即生效、持久化保存。

现有明暗切换已经验证了这套机制可行（`ThemeProvider extends ChangeNotifier` + `notifyListeners`），
本方案只是把「颜色」从常量提升为同样的可观察状态，工程量很小。

## 2. 现状分析

### 2.1 已具备的条件（无需改动）

- `lib/models/app_theme.dart`：`ThemeProvider`（ChangeNotifier）持有 `themeMode`，
  `setIsDarkMode()` 改值 → 持久化 → `notifyListeners()` → `app.dart` 中
  `themeMode: themeProvider.themeMode` 触发整棵主题树重建。**切换即时生效**。
- `AppThemes._build(Brightness)` 用 `ColorScheme.fromSeed(seedColor:)` +
  `FlexThemeData.light/dark(colorScheme: ...)` 生成主题。
- FCS 8.4.0 的 `colorScheme`/`colors`/`scheme` 参数均为运行期可求值。
- shadcn_ui 0.56.1 提供 `ShadTabs<T>`（泛型，`value`/`onChanged`），适合分组切换。
- 项目已用 easy_localization（`context.locate`/`.tr()`），可按语言环境选显示名。

### 2.2 需要改动的点

| 位置 | 现状 | 问题 |
|---|---|---|
| `app_theme.dart` `_brandSeed` | `static const Color(0xFF5E81AC)` | seed 写死 |
| `app_theme.dart` `AppThemes.lightTheme/darkTheme` | 无参 getter | 不接受 seed 参数 |
| `shad_theme.dart` `_brand` | `static const Color(0xFF5E81AC)` | FCS/Shad 双轨要同步 |
| `app.dart` | `theme: AppThemes.lightTheme`（静态） | 不随 seed 变化 |
| `preference_and_config.dart` | 无主题色存储 | 缺少持久化 key |
| 色库 | 无 | 需从 JSON 生成 |

业务层（`Theme.of(context).colorScheme.*` 取色）零改动。

## 3. 方案设计（v3）

### 3.1 数据层：JSON 分组色库（6 组 × 16 色 = 96 色）

**数据源**：`temp/theme_colors.json`（已调整好，含双语名）。正式位置二选一：
- A. `assets/theme_colors.json`（assets 已整目录打包，运行时加载）
- B. `lib/data/theme_colors.json`（作为生成脚本的输入，不打包进运行时）

**JSON 结构（已就绪）**：数组 = 6 组，每组 `name`（中文）+ `nameEn`（英文）+ `colors[]`；
每个颜色 `name`（中文）+ `nameEn`（英文）+ `color`（`#RRGGBB`，恒不透明）。

```json
[
  {
    "name": "冷调专业", "nameEn": "Cool Professional",
    "colors": [
      { "name": "深海蓝", "nameEn": "Deep Sea Blue", "color": "#0F3460" },
      ...
    ]
  },
  { "name": "经典通用", "nameEn": "Classic Universal", "colors": [...] },
  { "name": "柔和马卡龙", "nameEn": "Soft Macaron", "colors": [...] },
  { "name": "复古莫兰迪", "nameEn": "Retro Morandi", "colors": [...] },
  { "name": "高饱和活力", "nameEn": "Vibrant", "colors": [...] },
  { "name": "自然大地", "nameEn": "Natural Earth", "colors": [...] }
]
```

**6 组概要**（已核验：全部 `#RRGGBB` 6 位、无透明、无重复色值）：

| 组 | 英文名 | 首色（组内默认） | 色值 |
|---|---|---|---|
| **冷调专业（第一组）** | Cool Professional | 深海蓝 Deep Sea Blue | `#0F3460` ← **全站默认** |
| 经典通用 | Classic Universal | 红色 Red | `#E53935` |
| 柔和马卡龙 | Soft Macaron | 樱花粉 Sakura Pink | `#F4A6B8` |
| 复古莫兰迪 | Retro Morandi | 灰玫瑰 Gray Rose | `#B08989` |
| 高饱和活力 | Vibrant | 烈焰红 Flame Red | `#E63946` |
| 自然大地 | Natural Earth | 深棕色 Dark Brown | `#6B4423` |

**色值修正记录**：原「桃红色」`#FF6B9D` 在旧版为 `0xFF6B9D`（6 位、alpha=0 透明），
JSON 中已是合法 `#FF6B9D`。

**运行时模型**（推荐方案：生成 Dart 常量，与项目 `notes_color.dart` 纯常量模式一致）：

```dart
// lib/models/theme_seeds.dart —— 由 scripts/generate_theme_seeds.py 从 JSON 生成
class ColorSeedItem {
  final String name;   // 中文名
  final String nameEn; // 英文名
  final Color color;   // alpha 恒为 0xFF
}
class ColorSeedGroup {
  final String name;
  final String nameEn;
  final List<ColorSeedItem> colors;
}
class AppThemeSeeds {
  static const List<ColorSeedGroup> groups = [ /* 96 色 */ ];
  static ColorSeedGroup groupByIndex(int i) { ... }      // clamp
  static ColorSeedItem itemByIndex(int g, int i) { ... } // clamp
  static Color colorByIndex(int g, int i) { ... }
  /// 按当前语言取显示名：中文用 name，其他用 nameEn
  static String displayName(ColorSeedItem c, {required bool isZh}) =>
      isZh ? c.name : c.nameEn;
}
```

> **为什么不运行时读 JSON**：`ThemeProvider` 在 `app.dart` 的
> `ChangeNotifierProvider(create: ...)` 同步构造，需要立即拿到 seed；
> assets 的 rootBundle 读取是异步的，会打乱启动流程。用脚本把 JSON 编译成
> Dart 常量（同 `scripts/generate_build_info.py` 思路），运行时零异步、
> 零启动成本；JSON 仍是唯一数据源，改色值只改 JSON 再跑脚本即可。

**脚本**：`scripts/generate_theme_seeds.py` —— 读 JSON → 输出
`lib/models/theme_seeds.g.dart`（含生成时间戳注释，勿手改）。

### 3.2 模型层：ThemeProvider 扩展（二维索引）

```dart
class ThemeProvider extends ChangeNotifier {
  int _groupIndex = PreferencesStorage.themeGroupIndex;
  int _colorIndex = PreferencesStorage.themeColorIndex;

  Color get seedColor => AppThemeSeeds.colorByIndex(_groupIndex, _colorIndex);

  void setThemeColor(int groupIndex, int colorIndex) {
    _groupIndex = groupIndex;
    _colorIndex = colorIndex;
    PreferencesStorage.setThemeGroupIndex(groupIndex);
    PreferencesStorage.setThemeColorIndex(colorIndex);
    notifyListeners();   // 关键：全局重建
  }
}
```

> 明暗共用一个 seed：`ColorScheme.fromSeed(brightness: dark)` 自动适配暗色。
> **默认值 = group 0 / color 0 = 冷调专业·深海蓝 `#0F3460`**（用户指定）。

### 3.3 主题生成：AppThemes / ShadThemes 参数化

```dart
// app_theme.dart —— 静态 getter 改为接受 seed 的方法
class AppThemes {
  static ThemeData build(Color seed, Brightness brightness) {
    final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
    // ...其余逻辑与现在完全一致
  }
}

// shad_theme.dart —— 品牌色参数化，双轨同步
class ShadThemes {
  static ShadThemeData build(Color seed, Brightness brightness) {
    // ShadSlateColorScheme 的 primary/ring/selection 全部由 seed 派生
  }
}
```

### 3.4 接线：app.dart

```dart
builder: (context, _) {
  final themeProvider = Provider.of<ThemeProvider>(context);
  final seed = themeProvider.seedColor;

  return ShadApp.custom(
    themeMode: themeProvider.themeMode,
    theme: ShadThemes.build(seed, Brightness.light),
    darkTheme: ShadThemes.build(seed, Brightness.dark),
    appBuilder: (context) => MaterialApp(
      themeMode: themeProvider.themeMode,
      theme: AppThemes.build(seed, Brightness.light),
      darkTheme: AppThemes.build(seed, Brightness.dark),
      // ...
    ),
  );
}
```

### 3.5 持久化：preference_and_config.dart（两个 int）

```dart
static const _keyThemeGroupIndex = 'themeGroupIndex';
static const _keyThemeColorIndex = 'themeColorIndex';

static int get themeGroupIndex => _preferences?.getInt(_keyThemeGroupIndex) ?? 0;
static int get themeColorIndex => _preferences?.getInt(_keyThemeColorIndex) ?? 0;
static Future<void> setThemeGroupIndex(int index) async { ... _logPrefChange(...); }
static Future<void> setThemeColorIndex(int index) async { ... _logPrefChange(...); }
```

> 存 index 不存色值 —— 以后调整 hex 老用户自动生效；读取经 clamp 防越界。

### 3.6 UI：shadcn 分组色库选择器

**6 组 × 16 色必须分组展示**（单一网格 96 色不可用）。全部用 shadcn 组件：

- **分组切换**：`ShadTabs<int>`（泛型，`value`=当前组 index，`onChanged` 切组）。
- **颜色网格**：参照现有 `ColorPallet`（notes_color_setting.dart）：
  - 每色一圆角色块卡片（InkWell + 选中边框高亮 + 勾选图标），
  - 顶部常驻大预览（当前组当前色色条 + 双语名称），
  - 桌面 4 列圆形色块 / 移动 3 列。
- **双语显示**：组名/色名取 `AppThemeSeeds.displayName(...)`，
  按 `EasyLocalization` 的 `context.locale` 判断 `isZh`（中文 locale 用中文名，其他用英文名）。
- **入口**：`theme_setting.dart` 底部弹层「Dark mode」开关组下方新增入口行
  （调色板图标 + 'Theme color'），进入新页面 `theme_color_setting.dart`。
- 选中回调：`Provider.of<ThemeProvider>(context, listen: false).setThemeColor(g, i)`。

## 4. 实施步骤（分阶段，每阶段独立验证）

| 阶段 | 内容 | 验证标准 |
|---|---|---|
| 0 | 定 JSON 正式位置（assets 或 lib/data）+ 写 `scripts/generate_theme_seeds.py` → 生成 `theme_seeds.g.dart` | 脚本输出 Dart 可编译 |
| 1 | `preference_and_config.dart` 持久化（两个 int） | `flutter analyze` 通过 |
| 2 | `ThemeProvider` 扩展 + `AppThemes.build(seed)` + `ShadThemes.build(seed)` | `flutter analyze` 通过 |
| 3 | 接线 `app.dart` 动态取 seed；临时入口验证实时换色 + 持久化 | analyze → build debug → run 冒烟 |
| 4 | UI：`theme_color_setting.dart`（ShadTabs + 色块网格 + 顶部预览 + 双语）+ 弹层入口 | analyze → build debug → run 冒烟 |
| 5 | 明暗 × 颜色 × 语言组合冒烟：切暗色自动适配、重启记住、切换语言名跟随 | run 冒烟 + 重启验证 |

## 5. 风险与注意事项

- **透明色值**：seed 色 alpha 必须恒为 `0xFF`（JSON 已核验，脚本侧再加一道校验）。
- **性能**：seed 变化重建主题树为纯内存计算，毫秒级，可接受。
- **渐变过渡（可选）**：`AnimatedTheme` 包裹实现换色平滑过渡。
- **双轨同步**：FCS（Material）与 Shad 必须同 seed，否则 UI 割裂。
- **Windows 标题栏**：`syncWindowsTitleBar(isDarkMode)` 只同步明暗，标题栏跟随品牌色
  后续单独评估。
- **默认色变更**：默认从 Nord 蓝 `#0F3460`？否 —— 默认改为**冷调专业·深海蓝
  `#0F3460`**（用户指定），启动即生效，无需迁移。
- **生成文件勿手改**：`theme_seeds.g.dart` 由脚本生成，改色走 JSON。

## 6. 关联文件清单

| 文件 | 动作 |
|---|---|
| `temp/theme_colors.json` | ✅ 已调整（6 组 96 色、双语、冷调专业第一） |
| `assets/theme_colors.json` 或 `lib/data/theme_colors.json` | 新增：正式 JSON 位置（待定） |
| `scripts/generate_theme_seeds.py` | 新增：JSON → Dart 生成脚本 |
| `lib/models/theme_seeds.g.dart` | 新增（生成）：分组色库 |
| `lib/models/app_theme.dart` | 改：`ThemeProvider` 扩展 + `AppThemes.build(seed)` |
| `lib/models/shad_theme.dart` | 改：`ShadThemes.build(seed, brightness)` |
| `lib/app.dart` | 改：动态 seed 接线 |
| `lib/data/preference_and_config.dart` | 改：`themeGroupIndex`/`themeColorIndex` |
| `lib/views/settings/theme_color_setting.dart` | 新增：分组色库选择器页 |
| `lib/views/settings/theme_setting.dart` | 改：弹层加入口行 |
