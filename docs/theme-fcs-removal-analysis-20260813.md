# 是否需要 FCS？全量 shadcn 的可行性评估（2026-08-13）

> 结论先行：**FCS 在当前项目里只承担了「Material 主题生成器」一个角色，且只用到了
> 它两个能力（FlexThemeData + FlexSubThemesData.defaultRadius），这些 Flutter 内置
> ThemeData + ThemeData.copyWith 完全能替代。理论上去掉 FCS 可行，但有 4 类
> Material 控件 shadcn 没有对应物，需要自己实现或继续用 Material 组件。**

## 1. FCS 在项目里实际做了什么

盘点代码事实（`lib/models/app_theme.dart`）：

| FCS API | 项目用法 | 替代方案 |
|---|---|---|
| `FlexThemeData.light/dark(colorScheme: ...)` | 把 M3 ColorScheme 包装成完整 ThemeData | `ThemeData(colorScheme: ..., useMaterial3: true)` 原生等价 |
| `FlexSubThemesData(defaultRadius: 8)` | 统一组件圆角 | `ThemeData.copyWith` 逐个设置 button/input/card 圆角 |
| FCS 的 surface 混合 / blendLevel / 组件微调等高级特性 | **未使用** | — |

**结论：FCS 的 90% 能力（surface 混合、主题配色方案切换、组件级深度定制）项目都没用到**，
只剩一个"生成 ThemeData"的壳。这部分 Flutter 原生 `ThemeData` 就能做。

## 2. shadcn_ui 组件全景 vs 项目需求

shadcn_ui 0.56.1 公开导出 31 个组件：
accordion / alert / avatar / badge / breadcrumb / button / calendar / card /
checkbox / context_menu / date_picker / dialog / icon_button / input / input_otp /
menubar / popover / progress / radio / resizable / select / separator / sheet /
slider / sonner(通知) / switch / table / tabs / textarea / time_picker / toast / tooltip

项目当前用到的 Material 控件中，**shadcn 有对应物**：

| Material 用法 | 数量 | shadcn 对应 |
|---|---|---|
| Scaffold（页面壳） | 18 | ⚠️ 无 —— 但只是布局容器，与主题无关 |
| AppBar | 18 | ⚠️ 无 —— 同上，可自定义 Header |
| SnackBar | 19 | **ShadSonner / ShadToast** ✓ |
| showDialog | 10 | **ShadDialog** ✓ |
| Card | 37 | **ShadCard** ✓ |
| Badge | 5 | **ShadBadge** ✓ |
| Switch | 1 | **ShadSwitch** ✓ |
| TabBar/TabBarView | 2 | **ShadTabs** ✓ |
| BottomSheet | 6 | **ShadSheet** ✓ |
| IconButton | 29 | **ShadIconButton** ✓ |
| Divider | 9 | ShadSeparator / 原生 Divider（无主题依赖） |
| CircularProgressIndicator | 4 | **ShadProgress** / 原生（主题无关） |

**shadcn 没有、项目在用（4 类）**：

| Material 控件 | 数量 | 场景 | 影响 |
|---|---|---|---|
| ListTile | 3 | deleted_notes 列表项 | 低 —— 列表项本就是自定义布局，用 ShadCard/自定义 Row 替代 |
| PopupMenuButton | 2 | 删除笔记菜单、日志级别菜单 | 中 —— shadcn 有 **menubar / context_menu / popover**，可替代但需改交互 |
| ExpansionTile | 1 | sync_diagnostics 展开项 | 低 —— 用 Accordion（shadcn 有）替代 |
| FloatingActionButton | 1 | home 新建笔记 FAB | 低 —— 用 ShadButton 悬浮容器替代 |

**没有使用**的 Material 控件（无需担心）：TextField（只有 1 处，且 ShadInputFormField 已覆盖）、
Checkbox/Radio/Slider/DatePicker/TimePicker/DataTable/Stepper —— 项目里 0 使用。

## 3. 全量 shadcn 的四个问题

### 3.1 Scaffold/AppBar 没有 shadcn 对应物（最大缺口）
shadcn 是**组件库不是页面框架**，不提供页面壳。18 个页面都依赖 Scaffold + AppBar
（抽屉、导航栏、SnackBar 宿主、键盘避让等基础设施）。全量 shadcn 意味着：
- 要么保留 Material 的 Scaffold/AppBar（它们只是容器，不涉及主题色，混用无害）；
- 要么自建 Shell 组件（工作量 = 重写所有页面布局）。

**实际建议：Scaffold/AppBar 保留 Material 是合理且常见的**（shadcn web 版也没有
"页面壳"概念）。这不构成"主题割裂"——页面壳不渲染主题色，只是结构容器。

### 3.2 取色体系要统一到 ShadTheme
现在 22 处 `Theme.of(context).colorScheme.*`（Material 取色）需要改成
`ShadTheme.of(context).colorScheme.*`。但 **ShadColorScheme 和 Material ColorScheme
字段名/语义不同**（如 background vs surface、无 onSurface 概念），部分取色点需要
改写法，有回归风险。

### 3.3 组件行为差异需要逐项验收
Material Switch/Button 的按压反馈、禁用态、焦点环和 Shad 版本不同；PopupMenuButton
换成 menubar/popover 后交互方式（点击 vs 悬浮）会变。需要人工验收每个替换点。

### 3.4 生态/文档
Material 组件有 Flutter 官方文档和大量示例，shadcn_flutter 生态相对小；
部分高级场景（如无障碍、文本方向 RTL、桌面快捷键）Material 更成熟。

## 4. 建议

| 方案 | 去 FCS？ | 内容 | 风险 |
|---|---|---|---|
| **A. 保留 FCS（推荐）** | 否 | 现状双轨；只做取色出口统一（AppColors helper） | 最低；治标不治本，但当前功能已稳定 |
| B. 去 FCS + 壳留 Material | **是** | `ThemeData(colorScheme: scheme)` 原生替代 FCS；Shad 组件不变；Scaffold/AppBar 保留 | 中；可去掉一个依赖，主题维护聚焦 Shad |
| C. 全量 Shad | 是 | 页面壳自建 + 全部控件换 Shad + 取色统一 | 高；几乎重写 UI 层 |

> **个人倾向 B**：FCS 确实冗余（只用了生成壳），去掉后主题维护只剩 Shad 一套；
> Scaffold/AppBar 保留 Material（它们不渲染主题色，不产生视觉割裂）。
> 若想更稳，先做 A 的取色收敛，验证无回归后再去掉 FCS。
