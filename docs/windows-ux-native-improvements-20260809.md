# SafeNotes Windows 端 UI/UX 原生化改进建议

> 生成日期：2026-08-09
> 范围：SafeNotes（Flutter 跨平台笔记应用）Windows 桌面端的观感与交互改进
> 背景：用户反馈 Windows 上的 UI/UX 与原生差异很大，涉及按钮、颜色、界面切换方式等

---

## 0. 现状摘要

SafeNotes 是一个 Flutter 跨平台应用，支持 Windows / Android / iOS。当前 Windows 端**完全是 Material 移动端范式**，未引入任何 Windows 原生化依赖或窗口类插件，因此"不像 Windows"是系统性问题，而非个别细节。

### 0.1 已具备的基础（良好，应保留）

- **原生 Win32 标题栏** + 沉浸式暗色联动：`lib/utils/window_title_bar.dart`、`windows/runner/flutter_window.cpp:37-54`、`windows/runner/win32_window.cpp:286-297`。
- **DPI 正确**：`windows/runner/runner.exe.manifest:5` 为 `PerMonitorV2`。
- **桌面布局已做一轮适配**：见 `docs/ui-adaptation-report-20260808.md`，含 600px 断点、常驻侧栏、内容限宽居中、网格自适应、常驻滚动条。

### 0.2 关键缺失（问题根源）

| 维度 | 现状 | 影响 |
|---|---|---|
| 字体 | 全局强制 `NotoSerif`（衬线）+ `MerriweatherBlack` | 最不像 Windows 的单点因素 |
| 颜色 | 笔记卡片 16 套硬色板绕过 `ColorScheme`；未读系统强调色 | "花花绿绿"脱离系统 |
| 按钮 | 触摸尺寸（高 50、elevation 5、字号 20）、AppBar 内 ElevatedButton、弹窗双撑满按钮 | 像手机不像桌面 |
| 转场 | `PageTransitionType.leftToRight` + 300ms 写死 17 条路由 | 移动端整页推入 |
| 窗口 | 原生标题栏已做暗色，但无 Mica/圆角/最小尺寸/位置持久化/系统主题实时跟随 | 质感不足 |
| 桌面范式 | 设置页强制 iOS 风格、Cupertino 控件泄漏、FAB 残留、底部弹层、无快捷键/菜单/右键 | 交互不地道 |

---

## 1. 字体（优先级 P0，立竿见影）

### 1.1 问题

- `lib/models/app_theme.dart:60-63`：整个 `TextTheme` 与 `primaryTextTheme` 都 `.apply(fontFamily: 'NotoSerif')`——**衬线体做 UI 字体**。Windows 原生 UI 字体是 **Segoe UI / 微软雅黑（无衬线）**。
- 标题用 `MerriweatherBlack` + `FontWeight.bold` + 负字距（`lib/utils/styles.dart:26,33`）。
- `NotoSerif-Regular` 不含中日韩字形，界面大量中文（如 `home_navigation_rail.dart:150` `'调试面板'`）会回退系统字体，导致**中英字体不一致**。

### 1.2 建议

1. 封装 `platformFontFamily()`，按 `defaultTargetPlatform` 返回系统字体：
   - Windows：`Segoe UI`（CJK 回退 `Microsoft YaHei`）
   - macOS：`SF Pro` / `.AppleSystemUIFont`
   - Android/iOS：各自系统字体
2. **不要**全局 `apply(fontFamily: 'NotoSerif')`；改为仅在"笔记正文预览"等真正需要衬线的场景使用衬线。
3. 标题字重改为常规 `FontWeight.w600`，移除负字距。
4. 在 `pubspec.yaml` 声明中文字体（如思源黑体/微软雅黑回退）以统一中英文显示。

---

## 2. 颜色（优先级 P0/P1）

### 2.1 问题

- **笔记卡片调色板完全脱离主题**：`lib/utils/notes_color.dart:21-28,48-194`，16 套 Nord 硬色板按 `index % colorList.length` 轮转，前景色二值化为纯黑/纯白。这是 Windows 上最跳脱的视觉噪声。
- **侧栏/抽屉硬编码灰色**：`lib/widgets/home_navigation_rail.dart:65-69`、`lib/widgets/drawer.dart:229-231` 直接用 `Colors.grey.shadeXXX`，与 `ColorScheme` 脱节（代码注释承认这是 Nord 主题下的 workaround）。
- **深色背景纯黑**：`lib/models/app_theme.dart:80-81` 用 `Colors.black`，但 Windows 深色标准约 `#202020`（Mica 风格）。
- **未读系统强调色**：无 `system_theme` / `dynamic_color`，无法跟随"设置→个性化→颜色"中的强调色。

### 2.2 建议

1. 引入 `system_theme` 或 `dynamic_color`，用 Windows 系统强调色作为 `ColorScheme` 的 seed——按钮/选中态跟随用户系统，是"像原生"的关键。
2. 开启 FlexColorScheme 的 `subThemesData`（`lib/models/app_theme.dart` 当前只传 4 个参数，组件级样式等于裸 Material 默认），统一按钮圆角/密度。
3. 笔记卡片改为"主题派生 + 用户可选"：默认用低饱和、与 `ColorScheme` 协调的色板，而非高饱和 Nord 色；前景色用 `onSurface` 而非纯黑/白。
4. 深色背景用 `#202020` 而非纯黑；深色文字用 `Colors.white70`。

---

## 3. 按钮（优先级 P0）

### 3.1 问题

- `lib/widgets/login_button.dart:30-37`：高度 50、圆角 10、`elevation:5`、字号 20——典型触摸尺寸；Windows 标准按钮高约 **32px、无投影、字号 14**。
- `lib/views/add_edit_note.dart:123-134`：AppBar 内塞 `ElevatedButton`（保存）——桌面标题栏不放凸起按钮。
- 弹窗按钮（如 `lib/dialogs/logout_alert.dart:144-170`）是两个 `Expanded` 撑满的 `ElevatedButton`——移动端范式；Windows 对话框应为**右下角对齐的小号 Accent/Standard 按钮对**。
- 全仓 `ElevatedButton` 散落（`change_passphrase.dart`、`dialogs/*`），无统一封装，样式漂移。

### 3.2 建议

1. 建立集中按钮封装（如 `AppButton.primary` / `AppButton.text`），统一 Windows 尺寸：height 32、fontSize 14、无 elevation、圆角 4~8。
2. AppBar 的"保存"改为 `TextButton` 或放入 `CommandBar`/工具栏。
3. 对话框按钮：**右下角对齐、`mainAxisSize: min`**；主操作用 Accent 色、次操作用标准样式。
4. 全仓散落按钮统一走封装，消除样式漂移。

---

## 4. 导航与转场（优先级 P1）

### 4.1 问题

- `lib/routes/route_generator.dart:55-56` 写死 `transitionDuration = 300` + `transitionType = PageTransitionType.leftToRight`，被 **17 条路由**复用——整页从左推入，方向与"前进"相反，是明确移动端范式。
- `MaterialApp` 未设 `theme.pageTransitionsTheme`，故 `showDialog` 等走 Material 默认。

### 4.2 建议

1. Windows 用 **Fluent Entrance 转场**：轻微上移 + 淡入，时长 ~150ms；或简单 `FadeTransition`。
2. 在 `MaterialApp` 设 `theme.pageTransitionsTheme`，让所有 `showDialog` 页面也一致。
3. 宽屏下对笔记查看/编辑做 **master-detail**（右侧详情面板），而非整页 push（`lib/views/home.dart:604,653`）——桌面笔记应用最该有的形态。

---

## 5. 窗口与标题栏（优先级 P1，需改 C++）

### 5.1 现状

已用原生标题栏 + 沉浸式暗色联动，DPI 为 PerMonitorV2，基础良好。具体文件：
- `lib/utils/window_title_bar.dart:14-25`
- `windows/runner/flutter_window.cpp:37-54`
- `windows/runner/win32_window.cpp:147-158,192-230,286-297`

### 5.2 改进点（C++ 侧 `windows/runner/`）

1. **Mica / Acrylic 背景**：`DwmSetWindowAttribute(DWMWA_SYSTEMBACKDROP_TYPE)`，让窗口融入桌面——Win11 原生感核心。
2. **Win11 圆角**：`DwmSetWindowAttribute(DWMWA_WINDOW_CORNER_PREFERENCE)`。
3. **系统主题实时跟随**：`MessageHandler`（`win32_window.cpp:192-230`）增加 `WM_SETTINGCHANGE`，用户切换系统亮/暗时应用自动跟随（当前仅在主题切换时手动同步一次）。
4. **最小尺寸 + 窗口位置/尺寸持久化**：`main.cpp:28-33` 固定 `1280×720` 且无最小限制；引入 `window_manager` 或手写记住上次位置/大小。
5. **修正二进制/公司元数据**：`windows/runner/Runner.rc:92-99` 的 `CompanyName "com.trisven"`、`windows/CMakeLists.txt:7` 小写 `safenotes`——任务栏/关于框显示不美观。

---

## 6. 桌面范式（优先级 P1/P2）

### 6.1 iOS 控件泄漏

- `lib/views/settings/settings.dart:64` 等 8 个文件 `platform: DevicePlatform.iOS`——Windows 上呈现 iOS 分组表样式。
- `lib/utils/ios_style_list_tiles.dart:52` `CupertinoSwitch`、`:83` `CupertinoButton`、`:113-156` `CupertinoColors.activeBlue` 硬编码——在 Windows 上直接暴露为 iOS 控件。

### 6.2 移动端残留交互

- `lib/views/home.dart:473-487` 桌面仍用右下角 `FloatingActionButton`——桌面应为 CommandBar/工具栏"新建"按钮。
- 主题切换用 `showModalBottomSheet`（`lib/views/settings/theme_setting.dart:27-34`）——桌面应为对话框/flyout。
- 反馈全靠 `SnackBar`（`lib/utils/snack_message.dart`）——桌面应为 InfoBar/通知。
- **零键盘快捷键、零菜单栏、零右键菜单**（全仓 grep `Shortcuts / MenuBar / onSecondaryTap` 无命中）。
- 笔记卡片用 `GestureDetector`（`home.dart:599,649`）而非 `InkWell`，桌面上无 hover 高亮、无鼠标手型。

### 6.3 建议

1. 设置页改用 adaptive 或移除 `platform: iOS` 强制；开关用 `Switch`（M3 桌面已可接受）而非 Cupertino。
2. FAB → 侧栏/工具栏"新建"按钮（CommandBar 风格）。
3. 桌面底部弹层 → `Dialog`/`AlertDialog` 或 flyout。
4. 加分项：加 `MenuBar`（文件/编辑/帮助）、快捷键（Ctrl+N 新建、Ctrl+F 搜索、Delete 删除）、卡片 `InkWell` + hover、右键菜单。

---

## 7. 实施路线

### 7.1 两条可选路线

- **路线 A（推荐，低风险）**：保持 Material 3，做上面的适配调优。改动可控，Android/iOS 不受影响，最快见效。
- **路线 B（最地道，高成本）**：引入 `fluent_ui` 做真正的 WinUI 外观。最像原生，但需对 `lib/` 大规模重写，并用条件导入保留移动端样式。

### 7.2 分阶段建议

| 优先级 | 改动 | 工作量 | 收益 |
|---|---|---|---|
| P0 | 字体改系统无衬线 + 去掉全局衬线 | 小 | 立刻"像 Windows" |
| P0 | 读系统强调色 + 卡片/侧栏接入 `ColorScheme` | 中 | 配色统一 |
| P0 | 按钮尺寸/形态 Windows 化 + 集中封装 | 中 | 不再像手机 |
| P1 | 转场改 Entrance/fade，去 leftToRight | 小 | 切换手感 |
| P1 | 去 iOS 控件、设置页去 `platform:iOS` | 中 | 消除泄漏 |
| P1 | 标题栏加 Mica + 系统主题实时跟随 | 中(C++) | 原生质感 |
| P2 | master-detail、菜单栏、快捷键、窗口持久化 | 大 | 完整桌面体验 |

### 7.3 推荐起点

按 **路线 A 的 P0+P1** 先做一轮。字体 + 颜色 + 按钮 + 转场这四项改完，观感差距可缩小一大半，且无需碰 C++ 与重写组件。

---

## 8. 关键文件速查

| 关注点 | 文件 | 核心行 |
|---|---|---|
| 主题总入口 | `lib/models/app_theme.dart` | 50, 55-73, 80-81 |
| MaterialApp 装配 | `lib/app.dart` | 52-65 |
| 路由 + 转场 | `lib/routes/route_generator.dart` | 55-56, 60-243 |
| 桌面布局断点 | `lib/views/home.dart` | 50-51, 267-316, 320-331, 636-640 |
| 桌面侧栏 | `lib/widgets/home_navigation_rail.dart` | 65-69, 99-186 |
| 主按钮组件 | `lib/widgets/login_button.dart` | 30-37 |
| 字体常量 | `lib/utils/styles.dart` | 23-37 |
| 笔记调色板 | `lib/utils/notes_color.dart` | 21-28, 48-194 |
| iOS 控件 | `lib/utils/ios_style_list_tiles.dart` | 52, 83, 113-156 |
| 标题栏 Dart 通道 | `lib/utils/window_title_bar.dart` | 14-25 |
| 标题栏 C++ 通道 | `windows/runner/flutter_window.cpp` | 37-54 |
| DWM 暗色实现 | `windows/runner/win32_window.cpp` | 147-158, 192-230, 286-297 |
| 窗口初始尺寸 | `windows/runner/main.cpp` | 28-33 |
| 已有适配报告 | `docs/ui-adaptation-report-20260808.md` | 全文 |
