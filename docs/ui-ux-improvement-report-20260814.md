# SafeNotes UI/UX 精致度改进报告（修订版）

> 日期：2026-08-14
> 范围：客户端 Flutter / `shadcn_ui` 移植版（`shadcn_ui: ^0.56.1`）
> 目标：定位"相比主流 App 感觉粗糙"的根因，给出可执行、有优先级的改进方案。
> 修订说明（2026-08-14）：① 非 UI/UX 的条目（功能 / 工程 / 隐私）精简后移入文末「附录 A」；② 删除无实质内容的凑数条目（原 1.25、1.33）与不实细节（详见各条目内标注）；③ 「重点改动清单」前置。

---

## 0. 一句话结论

**字体不是主因。** 当前粗糙感的根因按影响排序为：

1. **双设计系统并存**（结构性，最致命）—— Material 与 Shad 两套语言在同一个 App 内混用；
2. **缺间距 / 字号体系**（"粗糙"的直接来源）—— 散落的魔法数字，没有统一刻度；
3. **卡片高度随机跳变**（明显逻辑缺陷）—— 网格列表看起来"错乱"；
4. **层次与微交互缺失** —— 扁平无边框、无 hover/press 反馈、无空/加载/错误态；
5. **字体**（锦上添花）—— 当前中性系统字体不丑，问题在缺乏统一 type scale，而非字体本身。

---

## 1. 提升整体质感的重点改动（先看这里）

> 按「投入产出比」排序：先视觉止血，再立设计令牌，最后收敛反馈通道。每项标注对应诊断（§2）与方案（§3）编号。

### 1.1 第一梯队：视觉粗糙感根因（改动小、见效快）

| # | 重点改动 | 对应诊断 | 对应方案 | 收益 |
|---|---------|---------|---------|------|
| 1 | **固定网格卡片高度**：`getMaxLine(index%4)` → 固定行数 / 等高 | 1.4 | P0-1 | 网格"锯齿错乱感"立即消失 |
| 2 | **统一卡片内边距与间距刻度**：note_card `all(10)` vs note_tile `h20/v10`、SizedBox 4/6/5 → `AppSpace` | 1.3 | P0-2 | 视觉节奏统一，去掉"手工感" |
| 3 | **卡片 hover/press 反馈**：4 个卡片外包 `Material+InkWell`（照抄 `_TileSurface` 模板） | 1.11 | P0-3 | 桌面端"可点击"肌肉记忆建立 |
| 4 | **文字截断改 `ellipsis`**：4 个卡片 `clip` → `…` | 1.12 | P0-4 | 用户清楚"还有内容" |
| 5 | **圆角 / 高度统一**：搜索框 44/7、卡片 10、设置项 12、按钮 8 → `AppShape`（输入 8 / 卡片 12 / 按钮 8，高度 48） | 1.30 | P1-14 | 全站圆角三档化，精致感最基础一环 |
| 6 | **空 / 加载 / 错误状态三件套**：主页与回收站接 `emptyState/loadingState/errorState` | 1.10 | P0-5 / P3-11 | 空态从"未完工"变"鼓励用户" |

### 1.2 第二梯队：设计令牌（一劳永逸，防复发）

| # | 重点改动 | 对应诊断 | 对应方案 | 收益 |
|---|---------|---------|---------|------|
| 7 | **统一 type scale**：卡片 20/13/16、编辑器 24/18 全手写 → `AppText` | 1.2 | P1-1 | 一处改字号，全站生效 |
| 8 | **动画时长令牌**：150/250/300/500ms 散落 5+ 文件 → `AppMotion` | 1.29 | P1-11 | 跨页动画节奏统一 |
| 9 | **图标尺寸令牌**：`isDesktop ? 22 : 28` 等局部覆写 → `AppIcon`（16/20/24） | 1.50 | P1-20 | 禁止再出现"18 vs 22 vs 28" |
| 10 | **收敛到单一设计系统**：`ShadApp.custom` 内嵌 `MaterialApp` → 逐步移除 Material 主题源 | 1.1 | P2-1 | 最大结构性收益：圆角/阴影/色彩映射全站一致 |

### 1.3 第三梯队：反馈与状态收敛

| # | 重点改动 | 对应诊断 | 对应方案 | 收益 |
|---|---------|---------|---------|------|
| 11 | **SnackBar → ShadToast**：`snack_message.dart` 圆角 5 / elevation 6 / 屏宽 80% 全部换 shad 体系 | 1.9 / 1.32 | P2-3 | 所有 toast 不再"掉出风格" |
| 12 | **6 个旧 Dialog 迁移 ShadDialog**：去掉 `BackdropFilter` + 硬编码 10 圆角 / 20 内边距 | 1.8 | P2-2 | 弹窗风格全站统一 |
| 13 | **错误色统一 `destructive`**：`colorScheme.error`（Material）与 `destructive`（Shad）两套来源并存 | 1.54 | P1-22 | 全 App 同一种红 |
| 14 | **同步失败内联化**：SnackBar 4 秒消失 → 主页内联 banner + 查看/重试 | 1.20 | P2-4 | 关键事件不再被遗忘 |
| 15 | **抽屉魔法数字**：`height*0.07/0.01/0.005` → `AppSpace` 固定值 | 1.16 | P1-5 | 桌面/手机间距统一 |
| 16 | **调试面板语义色**：22+ 处 Material `Colors.*` → 语义色映射 | 1.27 / 1.34 / 1.56 | P2-7 | 暗色主题下可读，随品牌色变化 |

> 其余条目见 §2 诊断与 §3 完整方案；非 UI/UX 项（置顶、Onboarding、下拉刷新、右键菜单、搜索防抖等）见文末「附录 A」。

---

## 2. 现状诊断（含证据）

> 编号沿用原报告。**已删除条目**：原 1.25（调试 Tab gap，报告自述"纯巧合"，凑数）、原 1.33（dev 连点入口，报告自评"无改进必要"，凑数）。**已移至附录 A**（非 UI/UX）：原 1.14、1.36、1.38、1.39、1.40、1.41、1.42、1.43、1.44、1.52、1.57、1.58。

### 2.1 结构性

#### 1.1 双设计系统并存（结构性问题）⚠️ 最高优先

证据：

- `lib/app.dart:61` 使用 `ShadApp.custom`，内部再嵌套 `MaterialApp`，注释明确"两套设计系统并存，互不干扰"；
- 主题层存在**两个独立主题源**：
  - `lib/models/app_theme.dart` 由 `FlexColorScheme` 生成 Material `ThemeData`；
  - `lib/models/shad_theme.dart` 生成 `ShadThemeData`，且注释声明"只作用于 ShadXxx 组件；旧 Material 页面仍由 FlexColorScheme 主题化"；
- 组件层混用：全仓同时出现 `Scaffold` / `AppBar` / `ListTile`（Material）与 `ShadCard` / `ShadButton` / `ShadDialog` / `ShadSettingsTiles`（Shad）。

影响：同一 App 内圆角、阴影、点击反馈、色彩映射规则各自为政，用户潜意识里感到"不统一"——这是精致感最大的杀手。

> 好的一面：`lib/widgets/shad_settings_tiles.dart`、`shad_nav_items.dart`、`shad_dialog.dart` 已经示范了"Shad 化"的正确写法，可作为迁移模板。

#### 1.7 已具备的良好基础（不要推翻）

- ✅ 平台原生字体策略——比打包衬线更"像原生"；
- ✅ `ColorScheme.fromSeed` 自动推导对比度合规前景色（`shad_theme.dart:24`）—— 色彩可访问性好；
- ✅ 按钮统一高度 48、与输入同高（`shad_theme.dart:51-63`）—— 触控友好；
- ✅ 动态品牌色 + 明暗自适应换肤机制完善（`ThemeProvider`）；
- ✅ 已有 Shad 化示范组件，迁移有模板可循。

### 2.2 卡片与排版

#### 1.2 字号 / 字重散落，无 type scale

证据（`note_card.dart`）：

```dart
// note_card.dart:65-72  标题
fontSize: 20, fontWeight: FontWeight.bold,
// note_card.dart:80-84  时间
fontSize: 13, fontWeight: FontWeight.w600,
// note_card.dart:90     摘要
fontSize: 16, height: 1.2,
```

`note_tile.dart:67/81/90` 是**完全相同的一套魔法数字**。这些 `Text` 直接手写 `TextStyle`，没有走 `ThemeData.textTheme` 或集中式样式对象，导致：

- 同一语义（标题 / 次要文字 / 正文）在不同卡片里重复硬编码；
- 想全局调字号/字重时无法一处修改；
- `letterSpacing` 在多数处缺失，中文/数字小字易显拥挤。

字体本身（`lib/utils/platform_ui.dart`）用的是平台原生 UI 字体（Windows=Segoe UI、macOS=`.AppleSystemUIFont`、Linux=Ubuntu）+ CJK 兜底，**这是合理且"原生"的选择**，不是问题根源。

#### 1.3 间距系统缺失（粗糙感主因）

证据：

```dart
// note_card.dart:54
padding: const EdgeInsets.all(10),
// note_tile.dart:53
padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
```

**同一类卡片的内边距不对称**（一个 10 全向、一个 20×10）。行间距是随手写的 `SizedBox(height:4)` / `(6)` / `SizedBox.square(5)`（`note_card.dart:76,86`、`note_tile.dart:76,86`）。没有 4/8/12/16 这种可复用的间距刻度。

影响：视觉节奏不统一，元素之间"松紧不一"，这是"手工感"的来源。

#### 1.4 卡片高度随机跳变（明显逻辑缺陷，仅网格视图）⚠️

> 修订：经核对，`getMaxLine(index%4)` **只在网格卡 `note_card.dart` 中存在**；列表卡 `note_tile.dart` 标题/摘要行数固定（1 / 2），**列表视图无锯齿问题**。

证据（`note_card.dart:99-112`）：

```dart
int getMaxLine(int index) {
  switch (index % 4) {
    case 0: return 2;
    case 1: return 3;
    case 2: return 4;
    case 3: return 3;
    default: return 3;
  }
}
```

网格视图下，摘要行数由 `index % 4` 决定（2/3/4/3 循环），导致**同一行里每张卡片高度都不同**、整列像锯齿。这是网格视图"错乱"的直接原因，应优先修正。

#### 1.5 圆角 / 边框 / 阴影层次不一致

- 卡片 `radius`：`note_card.dart:55` 与 `note_tile.dart:54` 均为 `10`；而按钮/输入由 `shad_theme.dart` 控制，存在 8/10/12 多处取值；
- 卡片 `border: ShadBorder.none`（`note_card.dart:56`、`note_tile.dart:55`）且无阴影 → 完全扁平，缺乏层次。

#### 1.30 搜索框 / 输入框 / 卡片高度、圆角不统一

| 元素 | 高度 | 圆角 | 文件 |
|------|------|------|------|
| 搜索框 | 44 写死 | 7 写死 | `search_widget.dart:56, 64, 67` |
| ShadInput (主题) | minHeight 48 | 8 (主题默认) | `shad_theme.dart:60-63` |
| 笔记卡 (网格) | 随机 80-110 | 10 写死 | `note_card.dart:55` |
| 笔记卡 (列表) | 随机 80-110 | 10 写死 | `note_tile.dart:54` |
| 笔记卡 (compact) | 随机 70-100 | 10 写死 | `note_card_compact.dart:59` |
| 设置项 tile | 56 (内边距 13+13+内容) | 12 | `shad_settings_tiles.dart:282, 297` |
| 旧 Dialog | — | 10 写死 | `dialogs/*.dart` |
| 主题色块 (color setting) | 30/48 | 12 | `notes_color_setting.dart:83, 131, 110, 119` |

> 修订：主题色块圆角经核对为 `BorderRadius.circular(12)`，无 10。

问题：

- 搜索框 44 与 ShadInput 48 差 4 像素，但视觉上不一致；
- `searchBoxRadius = 7.0` 与 shad 默认 8 也差 1 像素，是"为了圆角看起来更圆"的自创；
- 笔记卡圆角 10、设置项圆角 12、按钮/输入 8，三套圆角共存。

#### 1.31 关闭"彩色笔记"时所有卡片固定 `0xFFA7BEAE`（硬编码灰绿）

`lib/utils/notes_color.dart:31`：

```dart
final base = PreferencesStorage.isColorful
    ? lightColors[notIndex % lightColors.length]
    : const Color(0xFFA7BEAE);  // 写死 Nord 风的灰绿
```

问题：

- 关闭"彩色"时所有笔记卡统一为同一个灰绿色，与品牌 seed 色、明暗自适应、用户当前主题完全无关；
- 用户选了品牌色（如 "Honey" 黄系），但关闭彩色后所有笔记变灰绿——视觉割裂。

建议：未启用彩色时取 `Theme.of(context).colorScheme.primary.withValues(alpha: 0.15)` 或 `colorScheme.surfaceContainerHighest`（仍用主色调但低饱和），让"无主题"卡片也跟随品牌色。

#### 1.48 笔记卡 4 个 widget 重复代码未抽取

`note_card.dart` / `note_tile.dart` / `note_card_compact.dart` / `note_tile_compact.dart`：

- 4 个文件几乎完全相同（`build` 内取色、取时间、`ShadCard` 包裹 + 标题/时间/摘要 3 个 `Text`），仅在 `padding / maxLines / 圆角 / 字号` 上有差异；
- 经 diff 核对，`note_card_compact` 与 `note_tile_compact` 的差异**仅类名不同**（`NoteCardWidgetCompact` / `NoteTileWidgetCompact`），其余逐字一致，是纯复制；
- 任何样式调整（如字号、padding）要改 4 个文件，极易漏改 → 4 个文件进度不一致是 §1.5 / §1.30 / §1.4 问题的根因。

建议：抽取 `NoteCardBody({note, index, padding, maxLines, isCompact})`，4 个 widget 退化为"外壳 + 共享 body"。`P0-2` 之后这步几乎免费。

#### 1.49 笔记编辑器标题字号 24、正文字号 18，无等级梯度

`lib/widgets/note_widget.dart:69-137`：

- 标题 24、正文 18，差 6px，但都在"字号梯度"的中段；
- 没有"小标题 / 引用 / 列表项"等次级排版。

影响：Markdown 笔记实际渲染时，标题用 `MarkdownBody` 的样式，与编辑时的 `ShadInputFormField` 字号 18 错位——用户写 `# 一级标题` 看到的预览是 M3 `headlineMedium` 字号，与编辑器 18px 视觉差异大。

建议：

- 编辑态标题输入框字号降到 20 / 加 `letterSpacing: 0.2`，与预览 `#` 字号更接近；
- 副标题用 16，正文用 14（与 §P1-1 type scale 一致）。

#### 1.55 笔记预览态（`add_edit_note.dart:_buildPreview`）标题字号 24，与编辑态 24 一样；但副标题 Markdown 用 `fontSize: 18`（写死）

`lib/views/add_edit_note.dart:244-269`：

- 预览标题 `fontSize: 24, fontWeight: FontWeight.bold`（写死）；
- 预览正文 MarkdownBody 用 `styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(p: const TextStyle(fontSize: 18))`（写死）；
- 与 §1.49 编辑态 18 一致，但与 `AppText` 未来令牌不对齐。

修复 P1-1 后这两处一并改为 `AppText.h1` / `AppText.body`，避免分散维护。

#### 1.28 笔记卡色彩对比度算法风险（写死 0.179 + 浅色提亮 0.4）

> 修订：原"14 个预设主题色"无出处——`allNotesColorTheme` 实际有 **16 个**卡片色主题（品牌 seed 另有 151 个，属另一体系），此处按 16 个计。

`lib/utils/notes_color.dart:43-45`：

```dart
Color getFontColorForBackground(Color background) {
  return (background.computeLuminance() > 0.179) ? Colors.black : Colors.white;
}
```

```dart
static const double _lightenAmount = 0.4;  // 浅色模式提亮 40%
```

问题：

- 阈值 `0.179` 是手调的"经验值"，并非按 WCAG 4.5:1 反推。对 16 个卡片色主题的浅色提亮后 (`Color.lerp(base, Colors.white, 0.4)`) 实际对比度未在所有 (base, lighten) 组合下校验；
- 字体色只取纯黑/纯白，**没有任何对比度回退**——卡片背景偏中性灰时（如 `0xFFA7BEAE` 关闭彩色模式）正面白字常显灰白叠加；
- `Colors.black` / `Colors.white` 硬编码，主题色 `primary.onPrimary` 的"对比前景色"在卡片背景上并不一定适用。

影响：随品牌色 / 主题色切换，可能出现"暗色品牌色 + 浅色提亮 + 黑色字 → 看起来 OK，但中等灰度背景上黑色字偏弱 / 提亮过头" 的边缘情况。

### 2.3 交互与反馈

#### 1.6 微交互与状态缺失

- 无统一的 hover（背景微变）、press（轻微缩放/背景加深）、focus ring 规范；
- 列表/卡片的选中态、空状态、加载态、错误态多为默认或缺失，与主流 App 差距明显。

#### 1.11 笔记卡无 hover/press 反馈，按下无视觉变化

`lib/widgets/note_card.dart:52-96` / `note_tile.dart:51-97` / `note_card_compact.dart:56-92` / `note_tile_compact.dart:56-92` 全部都是：

```dart
return ShadCard(
  backgroundColor: color,
  padding: const EdgeInsets.all(10),
  radius: BorderRadius.circular(10),
  border: ShadBorder.none,         // 完全无边框、无阴影
  child: Column( ... ),
);
```

点击通过外层 `OpenContainer`（`home.dart:635-680`）的 `closedBuilder` 触发，但卡片本体**没有任何 `InkWell` / 状态色变化 / `Material` 包裹**。结果是：用户按下笔记卡，鼠标光标没变成手型（除非在外层 GestureDetector 上），也看不到任何按下反馈——与桌面"可点击元素"的肌肉记忆不符。

相比之下，shadcn 模板 `shad_settings_tiles.dart:281-303` 已有正确的 `_TileSurface`（`Material(transparent) + InkWell` + 圆角），笔记卡可以照搬同一模式。

#### 1.12 笔记卡文字溢出策略：截断不提示

四个笔记卡全部使用 `overflow: TextOverflow.clip`（`note_card.dart:74/92`、`note_tile.dart:74/92`、`*_compact.dart:77`），长标题/正文被硬截断，**没有 `…` 提示**。

影响：用户看不到"还有内容"，只能凭标题行数和位置猜测。主流做法是 `TextOverflow.ellipsis`，并在卡片右侧/底部加一个微妙的"展开"暗示（如 chevron）。

#### 1.13 新建笔记按钮不是真正的 FAB

`lib/views/home.dart:518-541` 用 `ShadButton`（56×56 圆形）手写了一个"看起来像 FAB"的按钮：

```dart
return ShadButton(
  width: 56,
  height: 56,
  padding: EdgeInsets.zero,
  decoration: ShadDecoration(
    border: ShadBorder.all(radius: const BorderRadius.all(Radius.circular(28))),
  ),
  child: const Icon(Icons.add),
  onPressed: ...,
);
```

问题：

- 缺阴影/无 elevation lift（FAB 默认 `elevation: 6`、按下 `elevation: 12`）；
- 位置靠 `Scaffold.floatingActionButton` 挂着，但视觉是"普通按钮"，没有"浮在内容之上"感；
- 桌面端用户看不到阴影 = 失去层次（笔记列表"贴底"了）。

建议：换 `ShadButton` 配 `ShadDecoration` 显式 `BoxShadow`，或回归 `Material.FloatingActionButton` 并统一到 shad 主题色。

#### 1.17 键盘避让策略在 3 个页面间不一致

> 修订：原"键盘未弹出时底部留空白"的断言不成立（`viewInsets.bottom` 为 0 时 padding 为 0），删除该说法。真实问题是**实现方式与动画节奏不一致**。

- `add_edit_note.dart:316-332` `_KeyboardAwarePadding`（只在 `viewInsetsOf` 变化时动画，**OK**）；
- `set_passphrase.dart:81-117` 用 `SliverFillRemaining + Spacer` 套 `Padding(EdgeInsets.only(bottom: bottom))`，键盘弹出时底部 padding 与 Spacer 挤压布局，动画随 `scrollToBottomIfOnScreenKeyboard` 500ms 触发；
- `change_passphrase.dart:78-95` 同样在 `Padding(EdgeInsets.only(bottom: bottom))` 里 build（300ms），但没有 SliverFillRemaining 包裹，行为略好。

影响：3 个页面键盘弹出/收起的实现与时长（150 / 300 / 500ms）各不相同，布局"跳"动节奏不齐。

#### 1.21 全局 GestureDetector 拦截点击桌面端无意义

> 修订：删除原"配合 OpenContainer 闭合可能产生误触收起键盘/误触关闭"的推测性表述（无代码证据），保留已核实的部分。

`lib/views/home.dart:317-320`：

```dart
return GestureDetector(
  onTap: dismissKeyboard,
  onVerticalDragStart: dismissKeyboard,
  onVerticalDragDown: dismissKeyboard,
  child: Scaffold( ... ),
);
```

桌面端鼠标点击空白处会强制 unfocus——用户在桌面看笔记时点击空白区域是常规操作，不应触发"取消焦点"。建议：

- 移动端保留 onTap dismiss（手指友好）；
- 桌面端去掉（`if (!isDesktop) onTap: ...`）。

#### 1.35 笔记编辑页键盘避让动画时长 150ms 过短，桌面/移动端无差异化

`add_edit_note.dart:316-332` `_KeyboardAwarePadding`：

```dart
return AnimatedPadding(
  duration: const Duration(milliseconds: 150),  // 写死
  ...
);
```

移动端 iOS / Android 键盘弹出动画默认 250ms 左右；桌面端没有键盘问题。150ms 比系统动画快，导致内容会"先动一步"，与系统键盘的弹出节奏不齐。

#### 1.29 动画时长散落 150/250/300/500ms，无统一令牌

```dart
// add_edit_note.dart:326   _KeyboardAwarePadding
duration: const Duration(milliseconds: 150),   // 键盘避让
// home.dart:639            OpenContainer
transitionDuration: const Duration(milliseconds: 250),  // 卡片转场
// login.dart:192           scrollToBottomIfOnScreenKeyboard
duration: const Duration(milliseconds: 500),  // 滚动到底
// set_passphrase.dart:174  scrollToBottomIfOnScreenKeyboard
duration: const Duration(milliseconds: 500),  // 滚动到底
// change_passphrase.dart:102 scrollToBottomIfOnScreenKeyboard
duration: const Duration(milliseconds: 300),  // 滚动到底
// sync_backend_config_page.dart:292 _radioIndicator
duration: const Duration(milliseconds: 100),  // 圆点切换
```

问题：

- 同一"页面滚动到底"动画在 3 个页面用 3 个不同时长（300 / 500 混用）；
- 卡片转场 / 键盘避让 / 选项切换 / 抽屉进出没有时长级别（fast/normal/slow）映射；
- 没有任何一处显式定义 `AppMotion` 令牌，新增动画时各自拍脑袋。

### 2.4 系统一致性

#### 1.8 双系统遗留更深：旧 `Dialog + BackdropFilter` 仍未收敛

报告 §1.1 已点出"双设计系统并存"。但落地盘点发现：除了设置页/主页，其他**弹窗路径**仍全部用 Material `Dialog + BackdropFilter` 自绘，与 shadcn 弹窗风格脱节：

- `lib/dialogs/generic.dart`（通用信息框 + 单 OK）
- `lib/dialogs/confirm_import.dart`（导入数量确认）
- `lib/dialogs/logout_alert.dart`（闲置倒计时登出）
- `lib/dialogs/backup_import.dart`（导入备份入口）
- `lib/dialogs/backup_passphrase.dart`（旧导入密码框，新流程不再调用）
- `lib/dialogs/backup_password_input.dart`（新导入密码框）

证据特征（每个文件都有）：

```dart
return BackdropFilter(
  filter: ImageFilter.blur(),
  child: Dialog(
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10.0),  // 全部 10
    ),
    child: Padding(
      padding: const EdgeInsets.all(20.0),         // 全部 20
      ...
```

影响：每个弹窗都是"模糊遮罩 + 10px 圆角 + 20 内边距 + 硬编码 14 号正文"，与 `ShadDialog`（更大圆角 / 阴影 / 自带 action bar / 与 shad 主题色一致）并排出现时观感割裂。Shad 化模板已有（`shad_dialog.dart`），迁移成本低。

#### 1.9 反馈通道未统一：SnackBar 仍走 Material 体系

`lib/utils/snack_message.dart:17-36` 全局统一用 `Material.ScaffoldMessenger.of(context).showSnackBar(...)`，**未走 shadcn**：

```dart
SnackBar(
  width: width,                                  // 屏宽 80% 硬编码
  content: Text(message, textAlign: TextAlign.center),
  elevation: 6.0,
  duration: const Duration(milliseconds: 2000),
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(5)),
  ),
  behavior: SnackBarBehavior.floating,
);
```

问题：

- 圆角 5 / elevation 6 / 文字居中 / `textAlign: center` 都是 Material 风格参数，与 Shad 体系无关；
- 文字色/背景色靠 Material 主题推断，与 shadcn `colorScheme.foreground` 不一定同步；
- "屏宽 80%" 硬编码在桌面大窗口会出现一条横带（470 / 540 / 1080…），桌面应改为固定宽度居中。

影响：所有同步结果、登录失败、设置变更等反馈都受此拖累，每次 toast 都"掉出风格"。

#### 1.32 回收站 / 删除成功提示 SnackBar 仍 Material

`lib/views/deleted_notes.dart:115-123, 135-143, 199-207` 三处：

```dart
ScaffoldMessenger.of(context).showSnackBar(
  SnackBar(
    content: Text('Restored: "{title}"'.tr(...)),
  ),
);
```

未走 Shad `ShadToast`，与 §1.9 整改方向一致（同属 P2-3 的替换清单）。

#### 1.22 设置 tile 的 value 文字偏弱

> 修订：原"一律 fontSize: 13"不实——经核对 `shad_settings_tiles.dart` 的 6 处 value 中 **4 处是 12、仅 2 处是 13**（行 101/165/217/256=12，122/272=13），且全部用 `textTheme.muted`（低对比）。

```dart
style: ShadTheme.of(context).textTheme.muted.copyWith(fontSize: 12),  // 多数处 12
```

12-13 号 muted 文字 + 与 title 14 号正文仅差 1-2 像素 + muted 色（低对比），右侧 value 视觉权重过弱，看不清"当前状态"。建议：

- 提至 13.5-14；
- 或用 `textTheme.small` + `onSurfaceVariant`（更高对比）；
- 选中态用 `primary` 色 + 600 字重（与 `shadRadioTile` 已有做法一致，可复用）。

#### 1.23 主题色/语言切换后无选中视觉

> 修订：简化原描述——"主页 tile 不更新/渲染失序"表述混乱，无代码证据；已核实的问题聚焦于**导航型 tile 无选中指示**。

`settings.dart` 主题色 / 语言等入口用的是 `shadNavigationTile`（`shad_settings_tiles.dart:67-136`）：点击后 push 子页，改完返回，**没有任何 "✓ 已选" 或"主色高亮" 视觉提示**（`shadRadioTile` 有 check 图标 `:224`，但 `shadNavigationTile` 只有 chevron，无选中态）。建议 `shadNavigationTile` 在 `value` 与已知值匹配时显示 `LucideIcons.check`。

#### 1.24 旧 Dialog 标题居左，新 ShadDialog 居中——不一致

旧弹窗（`confirm_import.dart` / `logout_alert.dart` / `backup_import.dart` / `generic.dart` / `backup_password_input.dart`）的标题用 `Align(alignment: Alignment.centerLeft)` + `dialogHeadTextStyle`（**居左**）；`ShadDialog`（如 `delete_confirmation.dart`）的标题是**居中**。

弹窗标题对齐方式不统一是"半成品"观感的典型来源之一。

#### 1.54 错误提示颜色用 `Theme.of(context).colorScheme.error` 而非 shad destructive

`lib/dialogs/confirm_import.dart:96`：

```dart
style: TextStyle(
  color: Theme.of(context).colorScheme.error,  // Material 体系
  fontSize: 12,
),
```

而 `lib/views/settings/sync_backend_config_page.dart:594` 等更多新代码用 `theme.colorScheme.destructive`（shad 体系）。两套错误色来源不同——`colorScheme.error` 由 `FlexColorScheme` 生成，`colorScheme.destructive` 由 `ShadThemeData` 生成，**在某些 seed 色下两者略有差异**（如 red 700 vs red 500）。

影响：错误色"应该全 App 一致"，但实际有两套来源。修复 P2-1 后会自动消化（移除 Material 体系）。

#### 1.56 调试面板 6 个状态 chip 颜色与按钮语义不统一

`lib/views/settings/sync_diagnostics_page.dart:355-392`（已提 §1.34）。补充：chip 颜色除"Upload=蓝"和"Download=绿"外，"Delete=红"易与"Failed"混淆；"Conflicts=橙"和"Skipped=灰"无业务意义对应（skip 不算失败）。

建议映射到语义色：

- Upload / Download → `primary`
- Delete / Conflicts / Failed → `destructive`
- Migrated / Skipped → `mutedForeground`

### 2.5 状态与信息

#### 1.10 状态三件套缺失：空 / 加载 / 错误

主流 App 的"列表"路径有 4 种状态：loaded / empty / loading / error。当前实现：

| 页面 | loaded | empty | loading | error |
|------|--------|-------|---------|-------|
| 主页笔记列表 | ✅ | ⚠️ 仅文字 `No Notes` | ⚠️ 仅 `CircularProgressIndicator` | ⚠️ SnackBar 4 秒后消失、无操作 |
| 回收站 | ✅ | ⚠️ 仅灰色文字 | ⚠️ `CircularProgressIndicator` | ❌ 无 |
| 同步设置/调试 | ✅ | — | ⚠️ 仅 `CircularProgressIndicator` | — |

> 修订：主页错误态为 `home.dart:265` 的 SnackBar（默认时长 4 秒），非"一闪"。

证据：

- `lib/views/home.dart:507-512`：空状态

  ```dart
  Center(
    child: Text(
      noNotes,
      style: const TextStyle(fontSize: fontSize), // 24 号孤零零一行
    ),
  )
  ```

- `lib/views/deleted_notes.dart:82-87`：空状态

  ```dart
  Center(
    child: Text(
      'No deleted notes'.tr(),
      style: TextStyle(fontSize: 16, color: Colors.grey),  // 写死 grey
    ),
  )
  ```

- 加载态全是 `Center(child: CircularProgressIndicator())`，无骨架屏 / shimmer。

影响：空状态看起来"未完工"，加载态转圈生硬，错误态一闪即逝——这是主流 App 与"看着像半成品"之间的明显分水岭。

#### 1.15 AppBar 操作图标过密 + 全图标无文字

主页右上角挤了 4 个 `IconButton`（`home.dart:325-333`）：

```dart
actions: isLoading
    ? null
    : [
        _syncStatusButton(),     // 同步
        _diagnosticsButton(),    // 调试（仅 dev）
        _gridListView(),         // 列表/网格
        _shortNotes(),           // 排序
      ],
```

问题：

- 桌面端无文字标签，仅靠 tooltip，新用户不知道"上下箭头"是排序；
- 4 个图标宽度 ≈ 4×48 = 192，在 1300 限宽 + 左 rail(240) 的桌面布局下，搜索框 + AppBar 标题被挤；
- 调试按钮（dev 模式）应与正式功能物理隔离（不在同一行），避免"开发可见的按钮看起来像正式功能"。

笔记编辑页 AppBar 同样问题（`add_edit_note.dart:94-100`）：预览/删除/保存三连图标，仅 tooltip 解释。**保存是高频关键操作**，应改文字+主色或更显眼的"主按钮"位置。

#### 1.16 抽屉/侧栏/编辑页用了魔法数字（height 百分比）

`lib/widgets/drawer.dart:55-61`：

```dart
const drawerPaddingHorizontal = 15.0;        // 又是 15
const double drawerRadius = 15.0;             // 又是 15
final height = MediaQuery.of(context).size.height;
final topHeadPadding = height * 0.07;        // 7% 屏高
final bottomHeadPadding = height * 0.01;     // 1%
final double dividerSpacing = height * 0.01;  // 1%
const double itemSpacing = 1;                 // 1 像素
```

随后 `_buildMenuItem` 在 `home.dart` 也用 `topPadding: height * 0.005`（抽屉第 90 行）——同样是屏高百分比。问题：

- 不同屏高（手机 vs 桌面）下间距/头部高度不一致，桌面"过分稀"，手机"过分挤"；
- 与 §1.3 间距体系矛盾：明明已经有 `AppSpace` 提案，但抽屉还在用 `height * 0.01` 这种"按屏高算的怪刻度"。

#### 1.19 Recycle bin / 已删除笔记用写死 `Colors.grey` 与字号

`lib/views/deleted_notes.dart:85`：

```dart
style: TextStyle(fontSize: 16, color: Colors.grey),  // 写死
```

应改用 `Theme.of(context).colorScheme.onSurfaceVariant`（与 `footer.dart:50` 同源做法），否则暗色主题下"灰字 + 黑底"看不清。

#### 1.20 同步结果提示"快闪即逝"

`lib/views/home.dart:179-188`（同步完成但有 failed 笔记）：

```dart
ScaffoldMessenger.of(context).showSnackBar(
  SnackBar(
    content: Text(
      '{count} notes failed to sync ...'.tr(...),
    ),
    duration: const Duration(seconds: 4),  // 4 秒
  ),
);
```

因 §1.9 的 Material SnackBar 风格，且无操作（"查看详情/重试"），用户只能眼睁睁看消息消失。同步失败是关键事件，应提供：

- 内联错误卡片（主页内显示"上次同步失败，点此查看"）；
- 或长驻的 banner（顶部红条）+ 跳转入口。

#### 1.26 抽屉 / 侧栏 / 主页"操作项"的触控区高度不统一

- 抽屉 `shadNavMenuItem` 内容区高 34+padding 10×2 = 54；
- 侧栏同样 54；
- 设置项 `_TileSurface` 内边距 14×13 → 高度 ≈ 标题 16+副标题 14+padding 26 = 56；
- 笔记卡内容区 ≥ 80（高度随机跳变）。

桌面端差异不大，但移动端（特别是大字号辅助功能开启后）这些 50-56 的触控区容易与"列表项"挤压。

#### 1.37 搜索"无结果"状态未做

`lib/views/home.dart:506-512`：

```dart
notes.isEmpty
    ? Center(
        child: Text(noNotes, style: const TextStyle(fontSize: fontSize)),
      )
```

搜索 `allnotes` 过滤后为空时，与"数据库里根本没笔记"显示完全相同的一句话 `No Notes`（24px 灰色）。用户会以为笔记都被删了。

影响：搜索体验断裂。建议：

- 搜索无结果时显示 `No notes match "{query}"` + "清空搜索"按钮；
- 空数据库仍显示 `No Notes` + "新建笔记"引导按钮（与 P0-5 联动）。

#### 1.45 主页 / 侧栏未显示"上次同步时间"

`lib/views/home.dart:381-409` `_syncStatusButton` 只显示云图标的 `cloud_outlined / cloud_done / cloud_off`：

- 用户看到"绿云"知道同步成功过，但**不知道是 1 小时前还是 1 个月前**；
- 设置页 `sync_settings.dart:91-96` 的 `Last Sync` 信息是孤立的，不在主页暴露。

建议：tooltip / 长按显示"Last synced 5 min ago"；或者状态图标上叠加一个小数字（"3" 失败数）作为辅助信息。

#### 1.46 主题色预览色条 48px 过矮，色块辨识度低

`lib/views/settings/theme_color_setting.dart:194` 预览色条 `height: 48`：

- 16 色调色板，每色块 30px，主预览色条 48px；
- 用户切组时只能从 48px 的色条上感知"这组大概是蓝/黄系"，色块细节无法呈现。

建议：色条提到 80-100px + 圆角更大；下方加组内所有色块的小预览行（横向 16 个 8x8 色块），让"换组前"就能预判组内包含哪些颜色。

#### 1.50 生物识别按钮图标大小桌面 22 / 移动 28 不一致

`lib/views/authentication/login.dart:347`：

```dart
leading: Icon(LucideIcons.fingerprint, size: isDesktop ? 22 : 28),
```

桌面 22、移动 28 的差别源于"移动端图标按 Material 推荐放大"。但其他页面的图标（`shad_settings_tiles.dart:325`、`shad_nav_items.dart:47`）都固定 18，没有"桌面/移动"分支。

影响：局部"按平台调字号"与全局"统一 18px"冲突。`P1-1` type scale 应同步解决："图标字号 18 / 20 / 24"三档全局令牌，禁止局部覆写。

#### 1.51 笔记卡"切换 Grid/List"无显式状态保留

`lib/views/home.dart:458-470` `_gridListView()` 只切 `isGridView` 偏好：

- 状态本身被持久化（`PreferencesStorage.setIsGridView`），OK；
- 但**没有"当前是 Grid 还是 List"的视觉指示**——图标在 `grid_view_outlined` 与 `splitscreen_outlined` 之间切换，桌面端用户不一定能认出。

建议：把按钮改成 `ShadButton.ghost` 含"Grid / List"文字（与 P3-6 一致），状态一目了然。

#### 1.53 主题色预览"Current / Preview"双标签混在标题里

`lib/views/settings/theme_color_setting.dart:173-175`：

```dart
title = isCurrent
    ? '${'Current'.tr()}: $name · $groupName'
    : '${'Preview'.tr()}: $name · $groupName';
```

`title` 一行有 4 段（标签 + 名称 + 分组名 + 状态），中等屏幕宽度下"Current: Honey · 暖色系"接近截断。

建议：把"Current / Preview"做成右上角的小 badge（带颜色边框），主标题只保留"色名 · 分组"。

#### 1.27 调试面板诊断页颜色/字号/间距全面硬编码 Material

`lib/views/settings/sync_diagnostics_page.dart` 几乎每个 Tab 都在用 Material `Color` 和魔法数字：

**颜色硬编码**（共 22+ 处，全部为 Material `Colors.*`，不跟主题色变）：

```dart
// _StatusTab._buildKVRow:232
style: TextStyle(color: Colors.grey[600], fontSize: 13),
// _SyncResultTab:287, 303
color: snapshot.lastResultSuccess! ? Colors.green : Colors.red,
color: (snapshot.lastResultRequiresRelogin ?? false) ? Colors.red : null,
// _SyncResultTab 错误条:316
color: Colors.red.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4),
// _SyncResultTab 失败 UUID 列表:342
style: TextStyle(fontSize: 12, color: Colors.orange[700]),
// _ActionsTab._buildActionCard:516-538
color = Colors.red;  color = Colors.green;  color = Colors.orange;
color = Colors.blue;  color = Colors.teal;   color = Colors.red[300];
color = Colors.purple; color = Colors.grey;
// _LogsTab 等级色:869-883
return Colors.grey[600]!; return Colors.blue[300]!; ...
// _WebServerTab 状态框:1014-1019
color: (isRunning ? Colors.green : Colors.grey).withValues(alpha: 0.1),
// _WebServerTab 安全提示:1078-1090
color: Colors.orange.withValues(alpha: 0.1); ... color: Colors.orange[800];
```

**字号/间距/圆角硬编码**（共 35+ 处）：`fontSize: 11/12/13/16/20`、`BorderRadius.circular(4/8)`、`EdgeInsets.all(8/12/16)`、`EdgeInsets.symmetric(vertical: 2/4)`、`SizedBox(width: 4/8/10/12/16/80/120)`、`SizedBox(height: 4/6/8/12/16/24)`。

影响：

- 用户切到深色/浅色/任意 seed 色主题，调试面板的绿/红/橙都还是"Material 默认色"，与设置页和主页的语义色（`colorScheme.destructive` / `colorScheme.primary`）不一致；
- 灰底 + 灰字（`Colors.grey[600]`）在暗色主题下"灰字+灰底"接近不可读；
- 字号 11-13 不走 `AppText`，是"内部页面所以随便写"的心态外溢。

#### 1.34 调试面板统计 chip 颜色与品牌色脱钩

`lib/views/settings/sync_diagnostics_page.dart:355-392`：

```dart
final stats = [
  ('Upload'.tr(), snapshot.lastResultUploaded ?? 0, Icons.upload, Colors.blue),
  ('Download'.tr(), ..., Icons.download, Colors.green),
  ('Delete'.tr(), ..., Icons.delete, Colors.red),
  ('Conflicts'.tr(), ..., Icons.warning, Colors.orange),
  ('Migrated'.tr(), ..., Icons.swap_horiz, Colors.purple),
  ('Skipped'.tr(), ..., Icons.skip_next, Colors.grey),
];
```

6 个状态 chip 全部硬编码 Material 蓝/绿/红/橙/紫/灰——和"upload 算成功/失败"等语义没有真正对应（绿色既表示 download 也表示 heal），且不随 seed 色变化。

建议：用 `colorScheme.primary` / `colorScheme.destructive` / `mutedForeground` 等语义色映射，而不是 RGB 直选。

#### 1.47 同步结果页失败笔记 UUID 列表过长时无折叠

`lib/views/settings/sync_diagnostics_page.dart:325-346`：

```dart
...snapshot.lastResultFailedNoteUuids!.map(
  (uuid) => Padding(
    ...
    child: SelectableText(uuid, ...),
  ),
),
```

如果有 100+ 失败 UUID，列表会占满整个面板（`SyncResultTab.build` 外层是 `ListView`，能滚但视觉上"100 个橙色 UUID"容易让用户焦虑）。

建议：默认展示前 10 个 + `Show all {n}` 折叠展开；或按失败原因分组。

### 2.6 无障碍

#### 1.18 Logo 与图标无 `semanticLabel`

`drawer.dart:186` `home_navigation_rail.dart:89` `login.dart:210` `set_passphrase.dart:131` 都是 `Image.asset(SafeNotesConfig.appLogoPath)`，**无 `semanticLabel`**：

- 屏幕阅读器（TalkBack / VoiceOver）会跳过图片或读"图片"；
- 无障碍合规（WCAG 1.1.1 Non-text Content）要求非装饰图必须提供替代文本。

影响：盲用户/视障用户不知道"打开 SafeNotes"。

---

## 3. 完整改进方案（按优先级）

> 已删除：P3-9（对应已删除的 §1.25，凑数）。已移至附录 A：P1-6、P1-16、P1-17、P1-18、P2-5、P2-8、P2-9、P3-14、P3-16、P3-17、P3-18、P3-21。

### P0 — 立刻修，改动小、见效快

#### P0-1 固定卡片高度，消除锯齿（网格）
- **问题**：`getMaxLine(index % 4)` 让网格卡片高度随机（列表卡无此问题）。
- **方案**：网格摘要统一 `maxLines: 3`；若需要等高的网格卡片，用 `SliverGrid`/`GridView` 的 `childAspectRatio` 固定卡片高度，或给卡片容器固定 `height`。
- **文件**：`lib/widgets/note_card.dart:99-112`。
- **收益**：网格"错乱感"立即消失。

#### P0-2 统一卡片内边距与间距刻度
- **方案**：新建 `lib/utils/spacing.dart`：

```dart
class AppSpace {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 20.0;
  static const xxl = 24.0;
  // 卡片内边距规范：同类型卡片保持一致
  static const cardPadding = EdgeInsets.symmetric(horizontal: 16, vertical: 12);
}
```

- 将 `note_card.dart:54` 与 `note_tile.dart:53` 的 padding 收敛为同一规范；行间距改用 `AppSpace.sm/xs`。
- **收益**：视觉节奏统一，去掉"手工感"。

#### P0-3 笔记卡加 hover/press 反馈（与设置项一致）
- **问题**：4 个笔记卡（`note_card.dart` / `note_tile.dart` / `note_card_compact.dart` / `note_tile_compact.dart`）按下无视觉变化。
- **方案**：外包 `Material(color: transparent) + InkWell` 圆角 10（参考 `shad_settings_tiles.dart:281-303` 的 `_TileSurface`），OpenContainer 的 `tappable: false` 保持；鼠标按下时给个 8% 黑/白叠加或 ripple。
- **收益**：桌面端"可点击"的肌肉记忆立即建立。

#### P0-4 文字截断改 `ellipsis`，提示有更多内容
- **问题**：4 个笔记卡全部 `TextOverflow.clip`，长内容硬截无 `…`。
- **方案**：统一 `TextOverflow.ellipsis`；网格卡片右下角可加微小 chevron（`LucideIcons.chevronRight` 12px muted）暗示"可点开"。
- **文件**：`note_card.dart:74/92`、`note_tile.dart:74/92`、两个 `*_compact.dart:77`。
- **收益**：用户清楚"还有内容没显示"。

#### P0-5 空状态 / 加载态最小可用版
- **问题**：空列表只有一行灰字，加载只有转圈。
- **方案**：建 `lib/widgets/states.dart` 导出：

  ```dart
  Widget emptyState({required IconData icon, required String text, String? cta, VoidCallback? onCta})
  Widget loadingState()           // 骨架屏占位（先用 3 个 shimmer card 兜底）
  ```

- 主页 / 回收站接入。
- **收益**：空状态从"未完工"变"鼓励用户"；加载态从"生硬"变"在准备中"。

#### P0-6 关键操作给文字标签
- 主页 AppBar "新建笔记"按钮（FAB）保持图标但加 shadow（见 P1-4）；
- 笔记编辑 AppBar 的"保存"（`add_edit_note.dart:275-284`）改 `ShadButton(child: Text('Save'))` 主操作按钮放右侧；
- 抽屉/侧栏"切换主题"等主项用文字 + 图标（已有，OK）。
- **收益**：关键操作不再依赖 tooltip。

### P1 — 建立设计令牌（design tokens），一劳永逸

#### P1-1 统一 type scale
- 新建 `lib/utils/text_styles.dart`：

```dart
class AppText {
  static const title = TextStyle(fontSize: 18, fontWeight: FontWeight.w600, height: 1.3, letterSpacing: 0.1);
  static const body  = TextStyle(fontSize: 14, height: 1.5);
  static const label = TextStyle(fontSize: 12, fontWeight: FontWeight.w500, letterSpacing: 0.2);
  static const caption = TextStyle(fontSize: 12, color: /* 次级色 */ null);
}
```

- 让 `note_card` / `note_tile` 复用，而非各自手写。
- 在 `ShadThemeData.textTheme` 与 Material `ThemeData.textTheme` 中同时接入，保证两套主题字面一致。

#### P1-2 统一 radius / 阴影令牌
- 在 `shad_theme.dart` 中固定：`cardRadius: 12`、`buttonRadius: 8`、`inputRadius: 8`、`dialogRadius: 12`。
- 给卡片增加"层次"：浅色用 1px 边框（`colorScheme.border`），深色用微妙阴影（`BoxShadow`），**不要 `ShadBorder.none` 全平**。

#### P1-3 微交互规范
- hover：背景色叠加 `colorScheme.muted` 8%~12%；
- press：轻微 `scale(0.98)` 或背景加深；
- focus：使用 `shad_theme.dart` 已定义的 `ring` 色做焦点环。

#### P1-4 主页 FAB 加阴影 + 抬升感
- **问题**：`home.dart:518-541` 的"假 FAB"无 elevation，桌面端看不出浮起。
- **方案**：`ShadDecoration` 加 `BoxShadow(color: primary.withValues(alpha: 0.25), blurRadius: 12, offset: Offset(0, 6))`，按下时 `blurRadius: 8 / offset: (0, 4)`，模拟 Material FAB 的 lift 反馈。
- **收益**：FAB 视觉真正"浮"在内容之上。

#### P1-5 抽屉/侧栏间距改用 `AppSpace`，去掉 height 百分比
- `drawer.dart:55-90` 的 `height * 0.07` / `0.01` / `0.005` / `itemSpacing = 1` 全部换为 `AppSpace.lg / sm / xs`。
- 头部留白按 `AppSpace.xxl(24)` 固定，不再随屏高变。
- **收益**：桌面/手机间距统一，符合 P1-2 的设计令牌目标。

#### P1-7 Logo / 关键图标加 `semanticLabel`
- `drawer.dart:186` / `home_navigation_rail.dart:89` / `login.dart:210` / `set_passphrase.dart:131` 的 `Image.asset` 加 `semanticLabel: SafeNotesConfig.appName`。
- 调试面板 5 个 Tab 已有 value，OK；侧栏底部"Lock"按钮已有 tooltip（OK）。
- **收益**：通过无障碍合规（WCAG 1.1.1）。

#### P1-8 字体回退补全（特别是 Web）
- `platform_ui.dart:36-38` `fuchsia` 平台返回 `Roboto`，但 Web 走 `default` 返回 `null`——与"平台原生 UI 字体"目标不一致。
- 建议为 `kIsWeb` 单独加分支：`return 'Inter'` 或回退到 `null`。
- **收益**：Web 版字体策略统一。

#### P1-9 键盘避让统一用 `_KeyboardAwarePadding`
- 把 `add_edit_note.dart:316-332` 的 `_KeyboardAwarePadding` 抽到 `lib/widgets/keyboard_aware_padding.dart`。
- `set_passphrase.dart` / `change_passphrase.dart` 改用同一组件，去掉 `SliverFillRemaining` + `Padding(EdgeInsets.only(bottom: bottom))` 组合。
- **收益**：3 个页面键盘弹出/收起动画一致，无布局"跳"动。

#### P1-10 全局 GestureDetector 桌面端去掉
- `home.dart:317-320` 在桌面端去掉 onTap dismiss 逻辑（用 `if (!isDesktopPlatform)` 包一层）。
- 移动端保留。
- **收益**：桌面端点击空白不再强制 unfocus。

#### P1-11 动画时长令牌（AppMotion）
- §1.29：当前 `Duration(milliseconds: 150/250/300/500)` 散落 5+ 个文件，曲线 / 时长没有级别。
- 新建 `lib/utils/motion.dart`：

```dart
class AppMotion {
  static const fast = Duration(milliseconds: 120);     // 选项切换、icon 替换
  static const normal = Duration(milliseconds: 220);   // 卡片 hover/press、键盘避让
  static const slow = Duration(milliseconds: 320);     // 抽屉进出、卡片转场
  static const pageTransition = Duration(milliseconds: 250);  // 页面 push
  // 曲线
  static const standard = Curves.easeOutCubic;
  static const emphasized = Curves.easeInOutCubic;
}
```

- 替换 `add_edit_note.dart`（150ms → normal）、`home.dart`（250ms → slow）、`login.dart` / `set_passphrase.dart`（500ms → slow）、`change_passphrase.dart`（300ms → normal）、`sync_backend_config_page.dart`（100ms → fast）。
- **收益**：跨页面动画节奏统一，移动端与系统动画对齐。

#### P1-12 笔记卡色彩对比度算法升级
- §1.28：当前 `computeLuminance() > 0.179` 是手调阈值，未与 WCAG 4.5:1 对应。
- 重写 `getFontColorForBackground` 为"按对比度反推"：

  ```dart
  Color getFontColorForBackground(Color background) {
    final blackContrast = _contrast(Colors.black, background);
    final whiteContrast = _contrast(Colors.white, background);
    return blackContrast >= whiteContrast ? Colors.black : Colors.white;
  }
  static double _contrast(Color a, Color b) {
    final l1 = a.computeLuminance();
    final l2 = b.computeLuminance();
    return (math.max(l1, l2) + 0.05) / (math.min(l1, l2) + 0.05);
  }
  ```

- `lightenAmount = 0.4` 改为常量集合 `0.0 / 0.25 / 0.4` 走 `AppSpace` 风格。
- 写一个 widget test 跑全 **16** 个卡片色主题 × 浅色提亮 × 字体色组合，断言对比度 ≥ 4.5。
- **收益**：跨任意 seed 色 / 提亮程度，字体色都保证 WCAG 合规。

#### P1-13 关闭"彩色笔记"时笔记色跟随品牌 seed
- §1.31：当前 `0xFFA7BEAE` 写死，与品牌色无关。
- 改为 `Theme.of(context).colorScheme.primary.withValues(alpha: 0.12)`，或取 `colorScheme.surfaceContainerHighest`（即"卡片底色跟随页面背景"）。
- 入口：`lib/utils/notes_color.dart:25-35` `getNoteColor` 改为接受 `BuildContext`。
- **收益**：用户选 Honey 主题，关闭彩色后所有笔记呈 Honey 系淡色调；选 Nord 蓝，呈浅蓝灰；不再"无论如何都是灰绿"。

#### P1-14 搜索框 / 输入框 / 卡片高度与圆角对齐
- §1.30：搜索框 44/7、笔记卡 10、设置项 12、按钮 8 多套值。
- 在 `AppSpace` 旁新建 `AppShape`：

  ```dart
  class AppShape {
    static const inputRadius = 8.0;   // 输入框、搜索框
    static const cardRadius = 12.0;   // 笔记卡、设置卡片
    static const buttonRadius = 8.0;  // 按钮
    static const inputHeight = 48.0;  // 输入框
    static const searchHeight = 48.0; // 搜索框（与输入框同高）
  }
  ```

- 把 `search_widget.dart:56-67` 的 44 / 7 改为 48 / 8。
- 把 `note_card.dart:55` / `note_tile.dart:54` / `*_compact.dart:59` 的 10 改为 12。
- 旧 Dialog 圆角 10（§1.8）改为 12（与 ShadDialog 一致）。
- **收益**：全站圆角三档化（8/12），高度两档化（48/卡片自适应），是"精致感"的最基础一环。

#### P1-15 笔记卡 4 个 widget 抽取公共 body
- §1.48：4 个文件高度重复，仅 `padding / maxLines / 圆角 / 字号` 差异；`note_card_compact` 与 `note_tile_compact` 仅类名不同。
- **方案**：
  - 抽 `lib/widgets/note_card_body.dart` 导出 `NoteCardBody({note, index, padding, maxLines, isCompact})`；
  - 4 个 widget 退化为"外壳 + 共享 body"，外壳只负责 padding/圆角/maxLines 三个参数透传；
  - `isGridView` / `isCompactPreview` 走 PreferenceStorage，已存在但分散在外层调用处；一并收敛到 `NoteCardFactory.create(note, index)` 工厂方法。
- **收益**：P0-2 / P0-3 / P1-1 / P1-14 任一处样式调整，1 个文件搞定，避免"4 个文件进度不一致"。

#### P1-19 编辑器标题/正文字号走 type scale
- §1.49：`note_widget.dart:69-137` 标题 24、正文 18 写死，与未来 `AppText` 令牌不对齐；编辑态与 Markdown 预览态视觉差异大。
- **方案**：
  - 标题 `fontSize: 20, fontWeight: w700, letterSpacing: 0.2`（与 P1-1 `AppText.h1` 对齐）；
  - 正文 `fontSize: 14`（与 `AppText.body` 对齐，编辑态与预览态用同一字号）；
  - 调整 `AddEditNotePage._buildPreview` 同步用 `AppText.h1` / `AppText.body`；
  - 验证 Markdown `# 一级标题` 预览字号与编辑态 20px 视觉一致。
- **收益**：P1-1 的 type scale 在编辑器落地，编辑/预览切换"字号不变"。

#### P1-20 全局图标尺寸令牌化
- §1.50：登录页 `LucideIcons.fingerprint size: isDesktop ? 22 : 28`（`login.dart:347`）的桌面/移动分支与其他页面"统一 18"冲突；其他位置（`shad_settings_tiles.dart:325`、`shad_nav_items.dart:47`）散落 `size: 14/16/18/20/22/28`。
- **方案**：
  - 在 `lib/utils/spacing.dart` 旁加 `AppIcon`：

    ```dart
    class AppIcon {
      static const sm = 16.0;   // 列表项 leading
      static const md = 20.0;   // 输入框 leading/trailing
      static const lg = 24.0;   // AppBar 按钮
    }
    ```

  - 登录页删除"桌面/移动"分支，统一 `AppIcon.lg`；
  - 全仓 `Icon(... size: ...)` 搜索替换为 `AppIcon.{sm/md/lg}`。
- **收益**：禁止局部"按平台调字号"，避免再次出现"18 vs 22 vs 28"不一致。

#### P1-21 笔记卡 Grid/List 切换显式状态
- §1.51：`_gridListView()` 只切图标 `grid_view_outlined ↔ splitscreen_outlined`，桌面端用户识别困难。
- **方案**：
  - 按钮改为 `ShadButton.ghost(child: Row([Icon(...), Text('Grid'/'List')]))`，文字 + 图标并存；
  - 与 P3-6 / P3-10 一致，桌面端 4 个 AppBar 按钮全部"图标 + 文字"化；
  - 移动端保留纯图标（节省空间）。
- **收益**：一眼可辨"当前是 Grid 还是 List"。

#### P1-22 错误色统一走 shad destructive
- §1.54：`confirm_import.dart:96` `colorScheme.error`（Material 体系）与新代码 `colorScheme.destructive`（shad 体系）共存，某些 seed 色下两者略有差异。
- **方案**：
  - 全仓搜索 `colorScheme.error` 替换为 `ShadTheme.of(context).colorScheme.destructive`；
  - 文件清单：`confirm_import.dart:96`、`backup_password_input.dart:85`（已用 `colorScheme.error`）、其他可能散落处；
  - 验证 6 个 seed 色下两种颜色视觉一致（差异 < 5% ΔE）。
- **收益**：全 App 错误色统一来源，避免"同一种红色两种 RGB"。

### P2 — 收敛到单一设计系统（结构性）

#### P2-1 制定 Material → Shad 迁移路线
目标：最终只保留 `ShadThemeData` 一个主题源，移除 `FlexColorScheme` 双主题并存。

迁移顺序（参考已有 Shad 示范组件）：

1. 设置页：`FlexColorScheme` 主题页 → `ShadSettingsTiles`（已有模板）；
2. 导航：`AppBar`/`Drawer` → `ShadAppBar` / `ShadNavItems`（已有模板）；
3. 列表项：`ListTile` → `ShadListTile`；
4. 主操作：`FloatingActionButton` → `ShadButton`；
5. 弹窗：`AlertDialog` → `ShadDialog`（已有模板）；
6. 最后移除 `app.dart` 中嵌套的 `MaterialApp`，仅保留 `ShadApp`。

- **文件**：`lib/app.dart:61`、`lib/models/app_theme.dart`、`lib/models/shad_theme.dart`。
- 每步单独提交、可灰度，避免一次性大改引入回归。

#### P2-2 旧 Dialog → ShadDialog 批量迁移
- **问题**：§1.8 列出 6 个 dialogs/* 文件仍用 `BackdropFilter + Material.Dialog`。
- **方案**：
  1. `generic.dart`：单 OK 信息框，迁到 `ShadDialog(child: Text(...), actions: [shadDialogActionBar([ShadDialogAction(label: 'OK', primary: true, ...)])])`；
  2. `confirm_import.dart` / `backup_import.dart`：两按钮确认，同上模式；
  3. `logout_alert.dart`：倒计时 + 两按钮，迁到 `ShadDialog` + 内嵌 `StreamBuilder`；
  4. `backup_password_input.dart`：标题 + 描述 + 输入框 + 错误提示 + 两按钮；
  5. `backup_passphrase.dart`：已无新流程调用，可直接删除（保留备份）。
- 配套：去掉所有 `BackdropFilter`、`ImageFilter.blur`、硬编码 `10.0` 圆角 / `20.0` 内边距。
- **收益**：弹窗风格统一到 shadcn；与设置页/主页观感一致。

#### P2-3 全局 SnackBar → Shad 化
- **问题**：§1.9 `utils/snack_message.dart` 用 Material `SnackBar`。
- **方案**：
  - 直接用 `ShadToast`（shadcn_ui 提供）替代：主题色/圆角/动画与 shad 体系一致；
  - 桌面端宽度固定 420 / 居中（不再 `width: 80%` 屏宽）；
  - 持续时间统一 3 秒（信息）/ 6 秒（错误 + 操作）；
  - 错误 toast 提供 "详情" 按钮跳转到调试面板/帮助。
- 接入点：全仓 `ScaffoldMessenger.of(context).showSnackBar(...)` 替换（`home.dart:179-187/264-271`、`deleted_notes.dart:115-123/135-143/199-207` 等）。
- **收益**：所有反馈通道统一到 shad 主题，去掉"掉出风格"现象。

#### P2-4 同步失败状态内联化
- §1.20：把"快闪 SnackBar"换成主页内联 banner（顶部红条 sticky）+ "查看详情/重试"操作。
- 文件：`home.dart:178-188`。
- **收益**：关键事件不再被遗忘。

#### P2-6 主页 / 侧栏显示"上次同步时间"
- §1.45：主页 `_syncStatusButton` 只显示云图标，tooltip 是 "Sync successful" 等状态，但不知道"5 分钟前"还是"1 个月前"。
- **方案**：
  - `IconButton` 改为 `ShadButton.ghost`（桌面端），主图标旁叠加 `Text(noteTimeLabel(lastSyncTime, isRelative: PreferencesStorage.isRelativeTime))`（10-12px muted 色）；
  - tooltip 加完整时间戳（如 "Last synced 5 min ago · 2026-08-14 18:32"）；
  - 移动端保留纯图标，tooltip 显示完整时间。
- **收益**：用户能感知同步新鲜度。

#### P2-7 调试面板 6 个状态 chip 颜色映射语义色
- §1.34 / §1.56：`sync_diagnostics_page.dart:355-392` 6 个 chip 写死 Material 蓝/绿/红/橙/紫/灰；"Delete=红"易与"Failed"混淆，"Conflicts=橙"无业务对应。
- **方案**：
  - 映射到 shad 语义色：
    - Upload / Download → `colorScheme.primary`
    - Delete / Conflicts / Failed → `colorScheme.destructive`
    - Migrated / Skipped → `colorScheme.mutedForeground`
  - 实际渲染用 `ShadBadge(variant: ...)` 替代手工 `Container+color`；
  - 同步结果页 `_SyncResultTab:287/303` 写死的 `Colors.green/red/orange` 一并替换。
- **收益**：chip 颜色与"成功/失败/中性"语义对齐，随品牌色变化；与 P1-22 错误色统一一脉相承。

### P3 — 状态与细节打磨（接近主流 App 的关键）

- **空状态**：空列表用插画 + 引导文案 + 主操作按钮，替代当前纯文本；
- **加载态**：列表/详情用骨架屏（shimmer），而非空白或转圈；
- **错误态**：统一错误卡片 + 重试按钮，色彩用已定义的 `destructive`；
- **列表密度**：桌面多列栅格的 gutter 用 `AppSpace.lg/xl` 统一；
- **无障碍复核**：`NotesColor.getFontColorForBackground` 的对比度在任意 seed 下需 ≥ 4.5:1（当前仅靠 fromSeed 保证 primary 侧，卡片彩色背景上的文字仍需校验）。

#### P3-1 设置页 value 文字提权
- §1.22：tile 右侧 value 从 `muted+12/13` 改 `textTheme.small + onSurfaceVariant`（更高对比），选中态 `primary + 600`。
- 文件：`shad_settings_tiles.dart:101/122/165/217/256/272`。

#### P3-2 导航型 tile 加"已选"指示
- §1.23：`shadNavigationTile` 当 `value` 与当前选择匹配时显示 `LucideIcons.check`（参考 `shadRadioTile:223-224` 已有做法）。
- 让"主题色/语言/备份状态"在子页改完回主页后能立即看到 ✓ 标记。

#### P3-3 弹窗标题对齐方式统一
- §1.24：所有 `dialogHeadTextStyle` 标题从 `Align(centerLeft)` 改 `textAlign: center`（与 ShadDialog 一致）；或者反过来 ShadDialog 改居左（需在 shad 主题配置中处理）。
- 选一种"全局默认"后禁止局部再覆盖。

#### P3-4 Debug badge 与品牌色冲突
- `footer.dart:32` 写死 `Color(0xFFD32F2F)`（Material Red 700），与 shad 主题的 `destructive` 调色板不一定匹配。
- 改 `theme.colorScheme.destructive`。
- 文件：`footer.dart:32`。

#### P3-5 抽屉 logo 尺寸桌面端偏小
- `drawer.dart:166-167` `logoHightWidth = width * 0.25`（屏宽 25%）。手机侧屏宽 300 时 = 75，桌面侧屏宽 480 时 = 120，桌面偏小。
- 改固定值（手机 64 / 桌面 80），与 `home_navigation_rail.dart:86-87` 固定 32 的做法一致思路。

#### P3-6 主页 AppBar 桌面端加文字标签
- §1.15：4 个图标按钮在桌面窗口（≥ 1024）时改 "图标 + 文字" 的 `ShadButton.ghost`，移动端仍纯图标。
- 调试按钮放到独立 "..." 菜单（PopupMenu）里，避免与正式功能视觉同级。

#### P3-7 笔记编辑 AppBar "保存" 改主色按钮
- §1.15：`add_edit_note.dart:275-284` 的保存按钮从 `IconButton(icon: LucideIcons.save)` 改为 `ShadButton(child: Text('Save'))` 主操作样式，文字 + 品牌色填充。
- 删除保留 IconButton（次操作），预览切换可保留 IconButton（toggle）。

#### P3-8 触控区高度统一
- §1.26：把 50-56 的差异（`shadNavMenuItem` 54 / `_TileSurface` 56 / 笔记卡 ≥80）按"主操作 48 / 列表项 56 / 卡片 80+"分档，写入 `AppSpace` 同源的设计令牌。
- 大字号辅助功能开启后（系统设置 `textScaleFactor = 1.3`）自动放大。

#### P3-10 主页操作项去重（grid/list + sort 合一个菜单）
- §1.15：把 "网格/列表 + 排序方向 + 排序依据" 合并为 `PopupMenuButton` 单一入口（含图标 + 文字 + 当前选中），释放 AppBar 3/4 空间。
- 同步状态按钮（云图标）保持独立（高频入口）。
- 调试按钮（dev）独立到 "..." 菜单。

#### P3-11 状态三件套组件化
- §1.10：抽取 `lib/widgets/states.dart`：
  - `emptyState({icon, text, cta?})` —— 用于主页/回收站/搜索无结果；
  - `loadingState({count = 3})` —— 骨架卡片；
  - `errorState({error, onRetry?})` —— 主页加载失败内联展示。
- 替换所有 `Center(child: Text('No Notes'))` / `CircularProgressIndicator()` / 临时 SnackBar。

#### P3-12 `Recycle bin` 字号与配色统一
- `deleted_notes.dart:85` 写死 `Colors.grey` → 改 `Theme.of(context).colorScheme.onSurfaceVariant`；字号 16 走 `AppText.body`。

#### P3-13 同步设置页步骤进度
- `sync_backend_config_page.dart` 多步表单：建议顶部加 `Stepper`（如 shadcn 的 `ShadStepper`）展示「后端类型 → 凭据 → 测试 → 保存」进度，让用户知道走到哪一步、还要几步。

#### P3-15 搜索"无结果"独立状态
- §1.37：`home.dart:506-512` 空状态不管"数据库没笔记"还是"搜索无结果"都显示 `No Notes`，用户会以为笔记被删。
- **方案**：
  - 与 P3-11 状态三件套联动：

    ```dart
    if (notes.isEmpty) {
      return query.isNotEmpty
          ? emptyState(
              icon: LucideIcons.searchX,
              text: 'No notes match "{query}"'.tr(),
              cta: 'Clear Search',
              onCta: () => _searchNote(''),
            )
          : emptyState(
              icon: LucideIcons.notebook,
              text: 'No Notes',
              cta: 'New Note',
              onCta: _addANewNoteButtonOnPressed,
            );
    }
    ```

  - 同步设置页搜索空结果、回收站空结果统一调用此组件。
- **收益**：空状态有"为什么空 + 怎么办"，符合主流 App 体验。

#### P3-19 主题色预览色条加高 + Current/Preview 状态独立 badge
- §1.46 / §1.53：`theme_color_setting.dart:194` 色条 `height: 48` 过矮、辨识度低；"Current / Preview"双标签混在 title 里，中等屏幕易截断。
- **方案**：
  - 预览色条 `height: 48` → `AppSpace.xxl + 48 = 72`（`mainAxisExtent` 改 84 → 108，色条高 72 + 间距 10 + 标题行 ~26）；
  - 色条下方加组内所有色块的小预览行（横向 16 个 8x8 色块，1 行），让"换组前"就能预判组内包含哪些颜色；
  - `title` 不再拼"Current/Preview"，改为右上角独立 `ShadBadge(variant: ...)`：
    - Current → `variant: secondary`（绿底 / 主色底）
    - Preview → `variant: outline`（描边透明）
- **收益**：色条足够大能感知色相；Current/Preview 状态一眼可辨，不挤占标题。

#### P3-20 同步结果失败 UUID 列表折叠
- §1.47：`sync_diagnostics_page.dart:325-346` 失败 UUID 列表无折叠，100+ 条占满面板。
- **方案**：
  - 默认展示前 10 个 + `ShadButton.ghost` 写 "Show all {n}" 折叠展开；
  - 折叠展开时 `AnimatedSize` 平滑过渡；
  - 进一步：按失败原因分组（"key mismatch" vs "tombstone conflict"）展示，加 `Badge` 标签。
- **收益**：避免"100 个橙色 UUID"造成的视觉压迫感；主流调试面板（Chrome DevTools / Sentry）做法。

### P4 — 字体增强（可选，锦上添花）

- 当前系统字体已不丑；若想进一步有"设计感"，可引入一款精致无衬线作为**品牌字体**（如 Inter、Manrope、Plus Jakarta Sans），通过 `pubspec.yaml` 打包并在 `platform_ui.dart` 作为首选、`fontFamilyFallback` 兜底系统字体。
- 优先级最低，不建议在 P0~P2 之前投入。

---

## 4. 落地路线图

| 阶段 | 内容 | 风险 | 预期收益 |
|------|------|------|----------|
| **P0** | 修网格卡片高度 / 卡片间距 / 卡片 hover-press / 文字 ellipsis / 空-加载态最小版 / 关键操作文字标签 | 极低 | 列表不再"错乱"，粗糙感立减 |
| **P1** | type scale / radius / 阴影 / 微交互令牌 / FAB shadow / 抽屉间距 / semanticLabel / 键盘避让统一 / 桌面 GestureDetector / 笔记卡抽取 body / 编辑器字号 / 全局图标尺寸 / Grid-List 文字标签 / 错误色统一 | 低 | 全站视觉统一、可维护性↑ |
| **P2** | Material→Shad 单主题迁移（页面/弹窗/SnackBar） + 同步失败内联化 + 主页显示同步时间 + 调试 chip 语义色 | 中 | 彻底消除双系统割裂（最大收益），关键路径同步反馈到位 |
| **P3** | 状态三件套组件化（含搜索无结果） + value 文字提权 + 导航已选 + 弹窗标题对齐 + 操作项去重 + Stepper + 无障碍 + 主题色预览 badge + 失败 UUID 折叠 | 低 | 接近主流 App 完成度 |
| **P4** | 品牌字体（可选） | 低 | 个性与精致度微调 |

> 建议顺序：**先 P0 立刻止血，再 P1 立规矩，P2 做结构收敛，P3 补细节，P4 最后点缀。**
>
> P1~P3 内部建议：与 P0 强耦合的（如 P1-15 笔记卡抽取 → P0 卡片 hover/ellipsis → P0 笔记卡样式）先做。
>
> 非 UI/UX 项（附录 A）与样式 PR 互相独立，可另行排期，避免混在一个 PR 里。

---

## 5. 验收标准（如何判断"精致了"）

**视觉与设计系统**

- [ ] 同一语义（标题/正文/次要）在全 App 字号字重一致；
- [ ] 同类型卡片内边距、圆角、阴影一致；
- [ ] 网格卡片高度稳定（无 index 驱动的锯齿）；
- [ ] 卡片按下有 ripple / 颜色变化，鼠标 hover 时光标变手型；
- [ ] 文字截断用 `…` 提示有更多内容；
- [ ] 所有可点击元素具备统一 hover/press/focus 反馈；
- [ ] 圆角三档化（输入 8 / 卡片 12 / 按钮 8），高度两档化（输入 48 / 卡片自适应），全部由 `AppShape` 令牌管控；
- [ ] 动画时长由 `AppMotion` 令牌管控（fast 120 / normal 220 / slow 320），不出现散落 150/250/300/500ms；
- [ ] 全 App 仅由单一设计系统（Shad）主题化（含 SnackBar、Dialog）；
- [ ] 文字与背景对比度在任意主题色下 ≥ 4.5:1（卡片彩色背景 + 字体色组合有 widget test 覆盖）；
- [ ] Logo / 关键图标带 `semanticLabel`（无障碍合规）；
- [ ] 全局图标尺寸走 `AppIcon`（sm 16 / md 20 / lg 24），禁止局部覆写。

**交互与状态**

- [ ] 空 / 加载 / 错误三种状态均有精致设计，且组件化复用；
- [ ] 搜索"无结果"与"空数据库"显示不同文案与 CTA 按钮（清空搜索 vs 新建笔记）；
- [ ] FAB 有 elevation lift；
- [ ] AppBar 关键操作有文字标签；
- [ ] 抽屉 / 侧栏 / 列表项的间距走 `AppSpace`，无 height 百分比 / 魔法数字；
- [ ] 桌面端点击空白不再强制 unfocus；
- [ ] 保存按钮按下后有明确 loading / 状态反馈（与附录 A 防重入联动）。

**同步与反馈**

- [ ] 主页显示"上次同步时间"（5 min ago / 2026-08-14 18:32），随 `Relative Time` 设置；
- [ ] 同步失败以内联 banner 显示，含"查看详情 / 重试"操作；
- [ ] 所有 toast 走 `ShadToast`（不再 Material SnackBar）；
- [ ] 错误色统一走 `colorScheme.destructive`（不再 `colorScheme.error`）；
- [ ] 调试面板 6 个状态 chip 颜色映射语义色（primary / destructive / mutedForeground），随 seed 色变化。

**P1-15 / P1-19 / P1-20 落地**

- [ ] 笔记卡 4 个 widget 收敛为 `NoteCardBody` + 工厂方法，样式调整 1 个文件搞定；
- [ ] 编辑器标题 20 / 正文 14 走 `AppText` 令牌，与 Markdown 预览态视觉一致；
- [ ] 全局 `Icon(... size: ...)` 走 `AppIcon` 令牌。

---

## 附录 A：非 UI/UX 改进项（功能 / 工程 / 隐私，另行排期）

> 以下条目原属 §1 诊断，经核对**不属于视觉/交互精致度范畴**（功能需求、性能、工程正确性、i18n、隐私），精简保留于此，**不参与 UI/UX 排期**。编号沿用原报告以便追溯。

**功能需求**

- **原 1.36 / P3-14 Onboarding 引导**：首次启动直接进登录页。3 步引导（介绍 → 密码 → 可选同步），完成写 `PreferencesStorage.onboardingCompleted`。新增 3 屏翻译资源。属于新功能，非视觉。
- **原 1.40 / P1-16 笔记置顶**：`SafeNote` 无 `pinned` 字段。DB 迁移（core 包版本号 + 迁移脚本）+ 排序 + pin 图标 + 长按菜单项。功能 + 数据迁移。
- **原 1.43 / P1-18 设置页搜索**：5 分区 14 个 tile 无搜索框。顶部 `ShadInput` + 关键词过滤。功能需求。
- **原 1.42 / P1-17 密码强度实时反馈**：`_firstInputValidator` 只在 `form.validate()` 时报错。新增强度条组件（弱/中/强，红/橙/绿）。功能增强。
- **原 1.38 / P3-16 下拉刷新**：主页/回收站无 `RefreshIndicator`。移动端习惯行为。功能。
- **原 1.39 / 1.52 / P3-17 / P3-21 长按 / 右键菜单与单条删除**：笔记卡无 `onLongPress`/`contextMenuBuilder`，删除需 5 步。新增 Pin / Delete / Copy / Share 菜单。功能 + 交互路径新增。
- **原 1.41 / P3-18 保存后滚动到新笔记**：保存返回后列表停在原位置。`onSavedNoteId` 回调 + `animateTo`。功能。

**工程正确性**

- **原 1.44 / P2-5 保存按钮防重入**：`add_edit_note.dart:275-284` 保存 `IconButton` 无 loading/禁用，连点可触发多次 `addOrUpdateNote` 产生重复笔记。属 **bug 修复**（loading 视觉部分可随 P3-7 一并做，但防重入是正确性问题，不归视觉）。
- **原 1.14 / P1-6 搜索防抖**：`_searchNote` 在 `onChanged` 直接 `setState` 全量重建，百条以上掉帧。300ms 防抖。属**性能优化**。

**i18n / 隐私**

- **原 1.57 / P2-8 同步时间本地化**：`_lastSyncText` 用裸 `M/D H:MM`，未跟随 locale 与 `Relative Time` 开关。复用 `noteTimeLabel`。属 **i18n**。
- **原 1.58 / P2-9 搜索日志脱敏**：`home.dart:760-764` 日志记录 `query.trim().length`，在密码类应用中可能构成侧信道。改二值化或去除。属 **隐私/安全**。

**已删除（凑数，无实质内容）**

- **原 1.25 / P3-9 调试面板 Tab 间距**：报告自述"gap: 8 与 AppSpace.sm=8 一致——但这是巧合"，无实际待改项，删除。
- **原 1.33 dev 模式入口**：报告自评"保持现状即可（无改进必要）"，删除。

---

## 附录 B：关键文件索引

| 文件 | 角色 | 本次相关点 |
|------|------|-----------|
| `lib/app.dart:61,80` | 应用入口 | 双主题 `ShadApp.custom` + `MaterialApp`（§1.1 / P2-1） |
| `lib/models/shad_theme.dart` | Shad 主题源 | radius/按钮/输入/微交互令牌 |
| `lib/models/app_theme.dart` | Material 主题源（待收敛） | 双系统并存（§1.1 / P2-1） |
| `lib/utils/spacing.dart`（拟新增） | 间距/圆角/图标/动画令牌 | `AppSpace` / `AppShape` / `AppIcon` / `AppMotion` 一处定义（P0-2 / P1-1 / P1-2 / P1-11 / P1-14 / P1-20） |
| `lib/utils/text_styles.dart`（拟新增） | type scale | `AppText`（P1-1）；编辑器接入 P1-19 |
| `lib/utils/notes_color.dart` | 笔记卡色彩 | 关闭彩色时硬编码 `0xFFA7BEAE`（§1.31 / P1-13）；字体色对比度算法（§1.28 / P1-12） |
| `lib/utils/styles.dart` | 通用样式 | `dialogBodyTextStyle` / `kInputPadding` / `kDialogMaxWidth*` |
| `lib/utils/snack_message.dart` | 全局 SnackBar | Material 风格未走 shad（§1.9 / P2-3） |
| `lib/utils/platform_ui.dart` | 字体策略 | 系统字体 + CJK 兜底；Web 缺分支（P1-8） |
| `lib/widgets/note_card.dart:54-112` | 笔记卡片（网格） | 内边距/字号/高度锯齿（仅网格）/无 hover（§1.4 / §1.11 / P0-1 / P0-3） |
| `lib/widgets/note_tile.dart:53-93` | 笔记卡片（列表） | 内边距不对称 / 无 hover（§1.3 / P0-2 / P0-3） |
| `lib/widgets/note_card_compact.dart` | 笔记卡片（紧凑-网格） | 与 tile_compact 仅类名不同（§1.48 / P1-15） |
| `lib/widgets/note_tile_compact.dart` | 笔记卡片（紧凑-列表） | 复用紧凑样式（§1.48 / P1-15） |
| `lib/widgets/note_card_body.dart`（拟新增） | 笔记卡 body 共享 | P1-15 抽取 4 个 widget 公共逻辑 |
| `lib/widgets/note_widget.dart:69-137` | 笔记编辑器表单 | 标题 24 / 正文 18 写死（§1.49 / P1-19） |
| `lib/widgets/states.dart`（拟新增） | 状态三件套 | emptyState / loadingState / errorState（P0-5 / P3-11） |
| `lib/widgets/search_widget.dart` | 搜索框 | `searchBoxRadius: 7` 与 shad 不一致（§1.30 / P1-14） |
| `lib/widgets/drawer.dart:55-90,166-167` | 移动端 Drawer | height 百分比魔法数字；logo 屏宽 25%（§1.16 / §1.5 / P1-5 / P3-5） |
| `lib/widgets/home_navigation_rail.dart:86-87,89` | 桌面 Sidebar | 固定 240 宽；logo 缺 `semanticLabel`（§1.18 / P1-7） |
| `lib/widgets/footer.dart:32` | 底部版本徽标 | DEBUG 色写死 `0xFFD32F2F`（P3-4） |
| `lib/widgets/shad_settings_tiles.dart:67-136,180-224,281-303,325` | Shad 化模板（设置项） | 迁移参考；value 文字偏弱（§1.22 / P3-1）；navigation tile 无选中（§1.23 / P3-2）；`_TileSurface` hover 模板 |
| `lib/widgets/shad_nav_items.dart:47` | Shad 化模板（导航项） | 迁移参考 |
| `lib/widgets/shad_dialog.dart` | Shad 化模板（弹窗） | 迁移参考 |
| `lib/dialogs/generic.dart` | 旧通用弹框 | 待迁 ShadDialog（§1.8 / P2-2） |
| `lib/dialogs/confirm_import.dart:96` | 旧导入确认 | 待迁 ShadDialog + 错误色 `colorScheme.error`（§1.54 / P1-22） |
| `lib/dialogs/logout_alert.dart` | 旧闲置倒计时登出 | 待迁 ShadDialog |
| `lib/dialogs/backup_import.dart` | 旧导入入口 | 待迁 ShadDialog |
| `lib/dialogs/backup_passphrase.dart` | 旧导入密码框 | 已被 `backup_password_input` 取代，可删 |
| `lib/dialogs/backup_password_input.dart:85` | 新导入密码框 | 待迁 ShadDialog + 错误色 `colorScheme.error`（§1.54 / P1-22） |
| `lib/dialogs/delete_confirmation.dart` | 删除确认（已 Shad） | 模板 |
| `lib/views/home.dart:178-188,317-541,458-470,506-512,635-680` | 主页 | 全局 GestureDetector / FAB 假阴影 / 4 图标过密 / 搜索无结果与空状态同文案（§1.10 / §1.13 / §1.15 / §1.20 / §1.21 / §1.37 / P0-5 / P1-10 / P1-21 / P2-4 / P3-6 / P3-10 / P3-15） |
| `lib/views/home.dart:381-409` | 同步状态按钮 | 仅图标无时间（§1.45 / P2-6） |
| `lib/views/add_edit_note.dart:94-100,244-269,275-284,316-332` | 编辑页 | AppBar 预览/删除/保存全 IconButton；保存应主操作（§1.15 / P3-7）；预览字号写死 24/18（§1.55 / P1-19）；键盘避让 150ms（§1.35 / P1-11） |
| `lib/views/authentication/login.dart:210,347` | 登录页 | Logo 缺 `semanticLabel`（§1.18 / P1-7）；生物识别图标桌面 22/移动 28（§1.50 / P1-20） |
| `lib/views/authentication/set_passphrase.dart:81-117,131,170-178` | 设置密码页 | `SliverFillRemaining` + viewInsets 拼装；Logo 缺 `semanticLabel`；滚动 500ms（§1.17 / §1.18 / §1.29 / P1-9 / P1-11 / P1-7） |
| `lib/views/authentication/change_passphrase.dart:78-95,102` | 修改密码页 | 同 set_passphrase 的 keyboard 问题（§1.17 / P1-9 / P1-11） |
| `lib/views/deleted_notes.dart:82-87,89-102` | 回收站 | 空状态写死 `Colors.grey`；SnackBar 未走 ShadToast（§1.10 / §1.19 / §1.32 / P3-12 / P2-3） |
| `lib/views/settings/settings.dart:62-310` | 设置页 | 入口 + 5 个分区 14 个 tile（§1.15 / §1.23 / P3-2 / P3-6） |
| `lib/views/settings/theme_color_setting.dart:173-175,194` | 主题色选择 | Current/Preview 混在 title；预览色条 48px 过矮（§1.46 / §1.53 / P3-19） |
| `lib/views/settings/sync_backend_config_page.dart:292,594` | 同步配置 | 多步表单可加 Stepper；`_radioIndicator` 100ms（§1.29 / P1-11 / P3-13）；错误色用 `colorScheme.destructive`（§1.54 / P1-22） |
| `lib/views/settings/sync_diagnostics_page.dart` | 同步调试 | 22+ 处硬编码 Material 色 / 35+ 处魔法数字（§1.27 / §1.34 / §1.47 / §1.56 / P2-7 / P3-20） |
