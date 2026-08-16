# SafeNotes 桌面平台与移动平台差异处理梳理

> 本文档梳理 `lib/` 与 `packages/core/` 代码中，针对**桌面端**（Windows / macOS / Linux）
> 与**移动端**（Android / iOS）所做的一切平台分支、平台专属插件与平台相关常量。
> 目的是为后续维护、重构与新增平台适配提供一张完整地图。

涵盖平台：桌面 = Windows / macOS / Linux；移动 = Android / iOS；Web（`kIsWeb`）当前非主目标，
但代码中已有防御性短路保护。

---

## 1. 平台判定机制（先看这里）

代码里存在 **三套**判定方式，认知它们很重要：

| 方式 | 来源 | 使用位置 | 适用场景 |
| --- | --- | --- | --- |
| `isDesktopPlatform` | `defaultTargetPlatform`（Flutter 框架层） | `platform_ui.dart`、`app_theme.dart`、`login.dart`、`notes_color_setting.dart`、`export_backup_dialog.dart`、`sync_backend_config_page.dart` | 主题、字体、控件尺寸、弹框形态 |
| `_isDesktopUi` / 内联 `!kIsWeb && (Platform.isWindows\|\|Platform.isLinux\|\|Platform.isMacOS)` | `dart:io` 的 `Platform` | `home.dart`、`main.dart` | 布局、滚动条、屏幕旋转、sqflite_ffi |
| `Platform.isAndroid` / `Platform.isIOS` / `Platform.isWindows` … | `dart:io` 的 `Platform` | `file_handler.dart`、`scheduled_task.dart`、`device_id.dart`、`window_title_bar.dart`、`backup_setting.dart`、`log_webserver.dart` | 具体平台行为（路径、扫描、通道） |

`platform_ui.dart` 是**唯一的集中式**平台 UI 助手，主要内容：

- `isDesktopPlatform`：`windows/macOS/linux` → `true`，其余 `false`（基于 `defaultTargetPlatform`）。
- `uiFontFamily`：桌面返回系统原生无衬线字体（`Segoe UI` / `.AppleSystemUIFont` / `Ubuntu`），移动返回 `null`（沿用 Roboto / SF）。
- `uiFontFamilyFallback`：桌面额外指定 CJK 兜底字体（Windows→雅黑/苹方/Noto；macOS→苹方/雅黑/Noto），避免中英混排字体不一致；移动返回空。
- `applyUiFont` / `uiTitleStyle`：把上述字体族应用到 `TextTheme`。

> ⚠️ **观察**：`isDesktopPlatform`（框架层）与 `_isDesktopUi`（`dart:io`）语义几乎相同，但实现来源不同。
> 在 Web 上，`defaultTargetPlatform` 在 `flutter test` / Web 下行为不同于 `dart:io`，
> 故 `kIsWeb` 判断统一收敛到 `lib/utils/platform_ui.dart` 的单一助手（`isDesktopPlatform` / `isMobilePlatform` / `isWeb`），调用方不再内联 `!kIsWeb`（见 §12 / §14.1）。

---

## 2. 字体与主题观感（桌面=原生感，移动=系统默认）

文件：`lib/models/app_theme.dart`、`lib/utils/platform_ui.dart`、`lib/utils/styles.dart`

- **字体族**：`AppThemes._build()` 调用 `applyUiFont()`，使桌面端使用系统原生字体而非打包字体，贴合原生观感；移动端返回 `null` 沿用系统默认。
- **控件尺寸**：`app_theme.dart:85` 用 `isDesktopPlatform` 切换：
  - 圆角 `radius`：桌面 `8` vs 移动 `12`
  - 按钮字号：桌面 `14` vs 移动 `15`
  - 输入框内边距：桌面垂直 `12` vs 移动 `14`
- **对话框宽度常量**（`styles.dart`）：`kDialogMaxWidthCompact=420`、`kDialogMaxWidth=440`、`kDialogMaxWidthWide=560`、`kDialogMaxHeightWide=760`，均为桌面限宽用，避免宽窗口把表单拉满。
- **输入框图标**：`kInputIconButton` 压制 Material 默认 48dp 触控区，使桌面/移动表现一致（Android/M3 下会撑高密码框）。

---

## 3. 数据库层（桌面用 sqflite_ffi，移动用 sqflite）

文件：`lib/main.dart`（`_bootstrap`）、`packages/core/lib/src/logger/app_logger.dart`

- `main.dart:116`：桌面（且非 Web）执行 `sqfliteFfiInit()`，并把 `databaseFactory` 替换为 `databaseFactoryFfi`。
  - **关键修正**：`setDatabasesPath` 指向 `getApplicationSupportDirectory()`（如 `%APPDATA%/<app>`），
    否则 sqflite_ffi 默认用「CWD 相对路径」会把 DB 放到 exe 所在目录，打包到 `Program Files` 后无写权限。
- 移动端由 `sqflite` 插件自动注册原生实现，注入点相同（`NotesDatabase.dbFactoryOverride = databaseFactory`），不引入额外分支。
- `packages/core` 的同步引擎测试也统一用 `sqflite_common_ffi`（见 `packages/core/test/sync/*`）。

---

## 4. 窗口、布局与响应式（桌面=可缩放自由布局，移动=强制竖屏+抽屉）

### 4.1 屏幕旋转
- `main.dart:171`：仅在**非桌面**（移动、非 Web）调用 `SystemChrome.setPreferredOrientations` 锁定竖屏（含自动旋转开关）。
- 桌面窗口可自由缩放，强制取向是 no-op 且不符合预期，故跳过。

### 4.2 导航形态（抽屉 vs 导航栏）
文件：`lib/views/home.dart`（`build`）

- 取**整个窗口宽度** `MediaQuery.sizeOf(context).width` 做断点：
  - `width < 600`（Compact）：保留移动端 `Drawer`（汉堡菜单），`drawer != null`。
  - `width ≥ 600`：左侧常驻 `HomeSidebar`（NavigationRail）+ `Expanded` 内容区。
- `_buildDrawer` 在每个离开主页的入口前先 `pop` 抽屉；桌面 Rail 模式直接调导航回调，无需 pop。

### 4.3 内容限宽与网格列数
- `home.dart` `_homeBody`：用 `Center` + `ConstrainedBox(maxWidth: 1300)` 收束内容，避免大屏行过宽；窄屏不生效。
- 笔记网格 `_buildNotes`：桌面按真实可用宽度算列数 `max(2, (width/300).floor())`（宽屏自动增列）；手机维持 2 列。
- `notes_color_setting.dart:94`：主题选择网格桌面 `3` 列、移动 `2` 列。

### 4.4 弹框 vs 全屏对话框
- `export_backup_dialog.dart` `show()`：桌面用 `showDialog`（居中弹框）；移动用 `Navigator.push` + `fullscreenDialog: true`（全屏页）。
- `sync_backend_config_page.dart:45`：桌面用 `Dialog`（限宽限高居中）；移动保持 `fullscreenDialog` 整页。
- `export_backup_dialog.dart` 内：`isDesktopPlatform` 时宽度固定 `kDialogMaxWidthCompact`，否则 `min(kDialogMaxWidthCompact, 屏幕宽-32)`。

---

## 5. 滚动行为（桌面常驻滚动条）

文件：`lib/utils/app_scroll_behavior.dart`、`lib/views/home.dart`、`lib/app.dart`

- `AppScrollBehavior`（在 `app.dart` 注入 `scrollBehavior`）覆写 `buildScrollbar`：
  跳过依赖 `PrimaryScrollController` 的自动滚动条，避免多路由共存时旧路由 Scrollbar 失去 `ScrollPosition` 抛异常。
- `home.dart` 列表/网格：显式 `Scrollbar(controller: …, thumbVisibility: _isDesktopUi, …)`——
  桌面**常驻可见**滚动条，移动端保持默认覆盖式。

---

## 6. 文件备份、导入与导出（路径、选择器、媒体库各不相同）

### 6.1 备份落盘通道
文件：`lib/utils/scheduled_task.dart`（`unitBackupAttempt`）

- `Platform.isAndroid` → `androidBackup()`：首选 `Download/Safe Notes`（分区存储下可能无权限，捕获 `FileSystemException` 后回退应用私有目录）；写完后 `MediaScanner.loadMedia` 让系统文件管理器可见。
- `Platform.isIOS` → `iosBackup()`：落应用文档目录（iOS 无外部目录概念）。
- 桌面（`windows/macOS/linux`）→ `desktopBackup()`：写应用文档目录（`path_provider` 桌面返回 Documents）。
  - **历史坑**：桌面此前直接 `return true` 形成「假备份」，现已补全为真实加密落盘（评审 #2 修复）。

### 6.2 默认备份目录
文件：`lib/models/file_handler.dart`（`defaultBackupDirectory`）

- Android：优先 `Download/Safe Notes`，不可用回退应用文档目录。
- iOS / 桌面：统一 `getApplicationDocumentsDirectory()`。

### 6.3 写盘后媒体库收录
文件：`lib/models/file_handler.dart`（`writeBackupFile`）

- 仅 `Platform.isAndroid` 调用 `MediaScanner.loadMedia`，让备份文件出现在系统文件管理器；iOS/桌面无此需求。

### 6.4 导入文件选择
文件：`lib/models/file_handler.dart`（`getFileAsString`）

- Android：`CacheManager.emptyCache()`（Android 11+ 文件经缓存机制），并**按 SDK 版本分支**：
  - SDK > 29：`FilePicker.pickFiles(type: custom, allowedExtensions: [json, snbak])`
  - 其余：`FilePicker.pickFiles(type: any)`
- iOS：自定义扩展名选择器。
- 桌面：自定义扩展名选择器（json / snbak）。
- 三端统一 256MB 导入体积上限，读取走后台 isolate（避免主线程卡死）。

### 6.5 备份位置选择 / 打开目录
文件：`lib/views/settings/backup_setting.dart`

- `_pickBackupLocation()`：`Platform.isIOS` → 提示「iOS 备份位置固定」并 return；桌面/Android → `FilePicker.getDirectoryPath`。
- `onBackupNow()`：`Platform.isAndroid` → 先 `handleBackupPermissionAndLocation()` 申请存储权限。
- `openBackupDirectory()`：`Platform.isIOS` → `launchUrl('shareddocuments://…')`；否则 `launchUrl(file://, externalApplication)`。

### 6.6 导出面板位置选择
文件：`lib/dialogs/export_backup_dialog.dart`（`_pickLocation`）

- 桌面：`FilePicker.saveFile`（原生「另存为」，用户定文件名与位置）。
- Android：`FilePicker.getDirectoryPath`（选目录，文件名自动生成）。
- iOS：无目录选择器，落应用文档目录（仅展示默认路径）。

### 6.7 平台相关常量
文件：`lib/data/preference_and_config.dart`（`SafeNotesConfig`）

- `androidDownloadDirectory = /storage/emulated/0/Download/`
- `androidBackupDirectory = /storage/emulated/0/Download/Safe Notes/`
- `iosBackupDirectoryIndicativePath = /On My iPhone/Safe Notes/`（仅指示用）
- `backupFileName` / `exportFileNameFor()`：备份 `.snbak`、明文导出 `.json`、加密导出 `.snbak`，文件名带时间戳防覆盖。

---

## 7. 权限（仅 Android 需要）

文件：`lib/utils/storage_permission.dart`、`lib/utils/device_info.dart`

- `handleStoragePermission()`：用 `permission_handler`，仅当 `!isAndroidSdkVersionAbove(29)` 时才需申请 `Permission.storage`（Android 10+ 写 Download 无需权限）。
- `isAndroidSdkVersionAbove(api)`：`device_info_plus` 读 `androidInfo.version.sdkInt`。
- 桌面/iOS 无存储权限概念，对应逻辑直接跳过。

---

## 8. 设备标识（每平台来源不同）

文件：`lib/utils/device_id.dart`（`DeviceIdProvider._queryDeviceId`）

格式 `<platform>-<id>`，来源各异：

| 平台 | 标识来源 |
| --- | --- |
| Android | `androidInfo.id`（重装系统变、重装 app 不变） |
| iOS | `iosInfo.identifierForVendor`（卸载重装变） |
| Windows | `windowsInfo.deviceId` |
| macOS | `macOsInfo.systemGUID`（空则 `computerName-model`） |
| Linux | `linuxInfo.machineId` |

仅用于诊断/同步冲突排查，**不参与加密或权限控制**；支持 `overrideForTesting` 注入 mock。

---

## 9. Windows 标题栏主题（原生 MethodChannel，仅 Windows）

文件：`lib/utils/window_title_bar.dart`、原生 `windows/runner/flutter_window.cpp`、`win32_window.cpp`

- Dart 侧：`syncWindowsTitleBar(isDark)` 通过 `MethodChannel('safenotes/window_title_bar')` 调 `setDarkMode`。
  - 非 Windows 提前 `return`，无该通道。
- 原生侧：runner 注册同名 MethodChannel；`SetDarkMode` 调 `DwmSetWindowAttribute(…, DWMWA_USE_IMMERSIVE_DARK_MODE, …)`。
- 触发点：`app_theme.dart` 的 `ThemeProvider` 切换明暗时调用；解决「应用内暗黑模式」与「Windows 系统标题栏」不联动的问题。
- 其它桌面（Linux/macOS）与移动端无此通道，标题栏由系统/框架处理。

---

## 10. 生物识别（移动为主，桌面依赖平台支持）

文件：`lib/views/authentication/login.dart`、`lib/models/biometric_auth.dart`

- `login.dart` 用 `isDesktopPlatform` 调 UI 细节：指纹图标尺寸桌面 `22` vs 移动 `28`；「忘记密码」字号桌面 `14` vs 移动 `12`。
- `biometric_auth.dart` 用 `local_auth` + `flutter_secure_storage` 存凭据（v1 包裹态，非明文）。
  - 逻辑本身不分平台，但 `local_auth` 在桌面（如 Windows Hello）是否可用取决于平台实现。

---

## 11. 日志与诊断 Web 服务器（全平台，主要服务移动/远程）

文件：`lib/src/logger/log_webserver.dart`、`lib/views/settings/sync_diagnostics_page.dart`

- 全局单例 HTTP 服务器，进入主界面自动启动，应用退出（`detached`）停止。
- 绑定 `0.0.0.0:8888`，浏览器可实时查看全应用日志（含 `/logs`、`/api/*`、`/stream` WebSocket 等端点）。
- 设计初衷：移动端沙箱限制日志导出，桌面也常需远程观察；两端表现一致。
- `log_webserver.dart:77` `_platformLabel` 按 `Platform` 返回 Android/iOS/Windows/Linux/macOS/Fuchsia，用于日志面板标题。
- **测试保护**：`enableWebServer=false` 时跳过绑定，避免 `flutter test` 下 `FakeAsync` 中 Timer pending 导致测试失败。

### 11.1 日志目录
文件：`packages/core/lib/src/logger/app_logger.dart`（`_resolveLogDir`）

- 桌面：优先 `exe 同目录/logs/`，不可写（如 Program Files）则回退应用数据目录。
- 移动：应用私有数据目录的 `logs/`（经 `logDirResolverOverride` 注入 `path_provider` 实现）。
- 设计使 `app_logger` 保持纯 Dart 可编译，不依赖 Flutter 插件。

---

## 12. kIsWeb 防御性短路

- `kIsWeb` 的防御性保护**集中在 `lib/utils/platform_ui.dart`**：`isDesktopPlatform` / `isMobilePlatform` / `isWeb` 三个语义桶内部统一处理 `kIsWeb`（`platform_ui.dart:91/103/109/123/131` 等处 `if (kIsWeb) return …`），调用方（含 `main.dart` / `home.dart`）只需使用这些助手，**无需、也不再内联 `!kIsWeb`**。（早期版本曾在 `main.dart` / `home.dart` 内联 `!kIsWeb` 短路，现已收敛到 `platform_ui.dart`，见 §14.1。）
- 当前 Web 非发布目标（`pubspec.yaml` 未排除 `web` 平台，默认可编译；完整移植见 `WEB-PORT-PLAN.md`），但代码已对 `kIsWeb` 做了最小保护。

---

## 13. 文件索引（速查）

| 文件 | 桌面/移动差异点 |
| --- | --- |
| `lib/utils/platform_ui.dart` | 集中式 `isDesktopPlatform`、平台字体族与 CJK 兜底 |
| `lib/main.dart` | sqflite_ffi 初始化、DB 路径重定向、屏幕旋转限定移动、日志平台信息 |
| `lib/app.dart` | 注入 `AppScrollBehavior` |
| `lib/utils/app_scroll_behavior.dart` | 跳过 PrimaryScrollController 自动滚动条 |
| `lib/views/home.dart` | 窗口宽度断点（Drawer↔NavigationRail）、内容限宽 1300、网格动态列数、桌面常驻滚动条 |
| `lib/views/settings/notes_color_setting.dart` | 主题网格 3/2 列 |
| `lib/dialogs/export_backup_dialog.dart` | 桌面弹框 vs 移动全屏；saveFile vs getDirectoryPath vs 固定目录 |
| `lib/views/settings/sync_backend_config_page.dart` | 桌面 Dialog vs 移动 fullscreenDialog |
| `lib/utils/scheduled_task.dart` | androidBackup / iosBackup / desktopBackup 三通道 |
| `lib/models/file_handler.dart` | 默认备份目录、MediaScanner 仅 Android、导入选择器分平台、256MB 上限 |
| `lib/views/settings/backup_setting.dart` | iOS 位置固定提示、Android 权限前置、桌面/Android 目录选择器、打开目录方式 |
| `lib/utils/storage_permission.dart` | 仅 Android SDK<29 申请存储权限 |
| `lib/utils/device_info.dart` | Android SDK 版本判断 |
| `lib/utils/device_id.dart` | 每平台设备标识来源 |
| `lib/utils/window_title_bar.dart` | Windows 标题栏暗色 MethodChannel |
| `windows/runner/flutter_window.cpp`、`win32_window.cpp` | 注册通道 + DWM 暗色标题栏（仅 Windows 原生） |
| `lib/models/app_theme.dart` | 平台字体、圆角/字号/内边距按桌面切换、切主题同步 Windows 标题栏 |
| `lib/utils/styles.dart` | 桌面对话框限宽常量、输入框图标尺寸 |
| `lib/views/authentication/login.dart` | 指纹图标尺寸、忘记密码字号按桌面切换 |
| `lib/models/biometric_auth.dart` | local_auth 凭据存储（桌面可用性依赖平台） |
| `lib/src/logger/log_webserver.dart` | 全平台日志服务器、平台标签 |
| `packages/core/lib/src/logger/app_logger.dart` | 桌面 exe 目录日志 vs 移动数据目录日志 |
| `lib/data/preference_and_config.dart` | 平台相关路径常量、备份/导出文件名 |

---

## 14. 观察与后续建议

### 14.1 平台判定应统一为「桌面 / 移动 / Web」三态

**现状**：代码中实际存在三套判定来源，语义高度重叠：

| 判定来源 | 底层 | 代表符号 | 覆盖 |
| --- | --- | --- | --- |
| `defaultTargetPlatform`（框架层） | Flutter 框架 | `isDesktopPlatform` | 桌面 vs 其它 |
| `dart:io` 的 `Platform` | 原生进程信息 | `_isDesktopUi` / `!kIsWeb && (Platform.isWindows\|\|isLinux\|\|isMacOS)` | 桌面 vs 移动 |
| `dart:io` 的 `Platform` | 原生进程信息 | `Platform.isAndroid` / `Platform.isIOS` / `Platform.isWindows` … | 具体 OS |

`isDesktopPlatform` 已是唯一的集中桌面判定，但「移动」与「Web」两桶没有对等助手，导致每个调用点自行拼 `!kIsWeb && (…)` 或 `Platform.isAndroid/isIOS`，在 Web 下行为容易不一致。

**建议**：在 `lib/utils/platform_ui.dart` 收敛为单一入口，对外只暴露三个语义桶：

- `isWeb` → `kIsWeb`（Web 单独成桶，优先级最高）
- `isDesktopPlatform`（保留现有：windows/macOS/linux）
- `isMobilePlatform` → `defaultTargetPlatform` 为 android/iOS

内部统一处理 `kIsWeb` 短路，调用方（如 `home.dart`、`main.dart`）不再各自写 `!kIsWeb && (…)`。这样所有「桌面特性 / 移动特性 / Web 短路」判断都走同一来源，Web 行为一致、不会误入 `dart:io` 分支。

### 14.2 `isAndroid` / `isIOS` 应统一定义，收敛散落的 `Platform.*` 判断

**现状**：`Platform.isAndroid` / `Platform.isIOS` 散落在约 10 处，每处重复引入 `dart:io` 并写同形分支：

| 文件 | 行 | 用途 |
| --- | --- | --- |
| `lib/models/file_handler.dart` | 236, 284, 297, 327 | 备份目录、MediaScanner、导入选择器分支 |
| `lib/utils/scheduled_task.dart` | 91, 93 | `androidBackup` / `iosBackup` 落盘通道 |
| `lib/utils/device_id.dart` | 94, 99 | 设备标识来源 |
| `lib/views/settings/backup_setting.dart` | 190, 217, 297 | iOS 位置固定提示、Android 权限前置 |
| `lib/dialogs/export_backup_dialog.dart` | 153 | 导出位置选择 |
| `lib/src/logger/log_webserver.dart` | 78, 79 | 日志面板平台标签 |
| `lib/utils/storage_permission.dart` | 23 | 仅 Android SDK<29 申请存储权限 |

**建议**：把 `isAndroid` / `isIOS`（以及 14.1 的 `isMobilePlatform`）作为导出 getter 集中到 `platform_ui.dart`，所有散落判断改为调用这两个符号：

- Android 专属 SDK 门槛 `isAndroidSdkVersionAbove(api)` 仍留在 `lib/utils/device_info.dart`，但只在「移动」分支内可达，不再被 `Platform.*` 直接判定触发。
- Web 短路收敛到助手内部一处，不再在每个调用点写 `!kIsWeb &&`。
- 备份等「Android / iOS / 桌面」分支可改写为干净的三态 `switch`，消除重复。
- 现有 `isDesktopPlatform` 是唯一集中桌面判定，本次只补齐移动与 Web 两桶，使三态齐全，与 14.1 的「桌面 / 移动 / Web」分类一致。

> 说明：个别功能天然只属于单一 OS（如 Windows 标题栏 DWM、Android 的 MediaScanner、iOS 无目录选择器），这些仍保留具体 `Platform.isX` 判断，不强行套三态；三态助手只用于「桌面 / 移动 / Web」这类通用分桶。

### 14.3 iOS 能力受限

目录选择器、备份位置自定义在 iOS 上均不可用（系统限制），代码以「提示/固定路径」兜底，符合平台规范。

### 14.4 Windows 原生集成点孤立

标题栏通道仅在 `windows/runner` 原生层实现，macOS/Linux 无对应主题联动；若后续要全桌面统一，需在各自 runner 补相同 MethodChannel。

### 14.5 Web 未正式支持

仅做 `kIsWeb` 短路保护，未做 Web 特化（如 IndexedDB 替代 sqflite_ffi、无生物识别等）。
