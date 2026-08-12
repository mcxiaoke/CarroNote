# SafeNotes Web 版移植计划（WEB-PORT-PLAN）

> 状态：规划文档（仅文档，尚未动代码）
> 目标：让 `safenotes` 能以 `flutter build web` 出包，并在浏览器里跑通**完整用户流程**（建库→设密码→登录→增删改笔记→列表/搜索→设置→登出/会话超时）。
> 定位：**纯本地开发 / 测试用途**。

---

## 0. 范围与边界（已与用户确认）

| 项 | 决策 |
|---|---|
| 安全强度 | **弱化无所谓**。Web 版为本地 dev/test，不要求 HTTPS/CSP/SRI、不要求 OS 级安全存储。 |
| 导入 / 导出 | **Web 上不支持**。相关 UI 与逻辑在 Web 一律禁用 / no-op。 |
| 指纹 / 生物识别 | **Web 上不支持**。login 走纯密码；`local_auth` 在 Web 不引入。 |
| 存储引擎 | **保留 SQLite**，Web 端用 `sqflite` 自带的 Web 后端（WASM SQLite + IndexedDB 持久化）。**不使用 LevelDB**（无浏览器移植，且换成 NoSQL 要重写全部 SQL）。 |
| 同步 | Web 端只走 `webdav` / `safe_server`（HTTP，`http` 包，跨平台可用）；`local_fs` 后端（纯 `dart:io`）在 Web 排除。本地 dev/test 可不配置同步，app 不依赖同步即可跑全流程。 |

**不做的事**：安全加固、导入导出 Web 实现、生物识别 Web 实现、SQL 改写、LevelDB 移植。

---

## 1. 全流程验收清单（Web 必须跑通）

1. 首次启动 → 进入初始化（设主密码）→ 建库成功。
2. 重启用主密码登录 → 进入主页（笔记列表为空）。
3. 新建笔记 → 输入标题/正文 → 保存 → 列表出现该笔记。
4. 打开笔记 → 编辑 → 保存 → 返回列表内容更新。
5. 删除笔记 → 软删除生效 → 列表消失。
6. 搜索（按标题/正文）→ 结果正确。
7. 设置页打开 → 普通设置项可读写（主题、超时、语言切换）。
8. 会话超时 / 手动登出 → 回到 AuthWall。
9. 二次登录 → 数据仍在（IndexedDB 持久化）。
10. 调试日志：Web 上不启日志 WebServer，仅 console / 内存日志，不崩。

**明确不在验收内**：备份/导出/导入对话框、生物识别登录、本地文件同步。

---

## 2. 现有架构优势（已具备，复用即可）

- `packages/core` 是纯 Dart 包，DB 访问已通过 `NotesDatabase.dbFactoryOverride` 注入（`database_handler.dart:107`），`main.dart:134` 把这个工厂设成全局 `databaseFactory`。Web 上只要**不进 ffi 分支**，`sqflite` 的 Web 工厂自动接管，**同一套 SQL 零改动**。
- `DeviceIdProvider.overrideForTesting` 已存在（`device_id.dart`），Web 设备 ID 只需加一个 `kIsWeb` 分支。
- `main.dart` 里 ffi 初始化、`SystemChrome` 取向已经被 `!kIsWeb && Platform.isX` 守卫，逻辑分支正确，只差**顶层 import** 在 Web 编译不过。
- `easy_localization` / `shared_preferences` / `path_provider` / `url_launcher` / `device_info_plus` / `file_picker` 均有 Web 实现，开箱可用。

---

## 3. 核心机制：平台垫片（platform shim）

Web 编译的死穴是**文件里出现 `import 'dart:io'` / `import 'package:sqflite_common_ffi'` / 不支持 Web 的插件**。Dart 不允许"导入但不使用"——只要 import 存在，Web 编译即失败。统一解法：**条件 import（conditional import）**，让 Web 走一个空/桩实现。

### 3.1 `dart:io` 垫片

新建 `lib/src/platform/platform_io.dart`：

```dart
// lib/src/platform/platform_io.dart
export 'dart:io' if (dart.library.html) 'io_stub.dart';
```

新建 `lib/src/platform/io_stub.dart`，提供 Web 上被引用到的 `dart:io` 符号（编译期占位，**运行时不会被调用**，因为相关代码路径已被 `kIsWeb` 门控）：

```dart
// lib/src/platform/io_stub.dart
// 仅用于让 Web 编译通过；Web 上这些符号永远不会被真实调用。
class Platform {
  static const bool isAndroid = false;
  static const bool isIOS = false;
  static const bool isWindows = false;
  static const bool isMacOS = false;
  static const bool isLinux = false;
  static const bool isFuchsia = false;
  static String get operatingSystem => 'web';
  static String get operatingSystemVersion => 'web';
  static String get version => 'web';
  static String get localeName => 'en_US';
  static String get resolvedExecutable => '';
  static String get executable => '';
}

// File / Directory 占位：Web 上相关调用已被 kIsWeb 门控，不会执行到这里。
class File {
  File(this.path);
  final String path;
  Future<bool> exists() async => false;
  Future<File> create({bool recursive = false}) async => this;
  Future<void> delete() async {}
  Future<File> writeAsString(String c, {FileMode mode = FileMode.write}) async => this;
  Stream<List<int>> openRead([int? a, int? b]) => const Stream.empty();
}
class Directory {
  Directory(this.path);
  final String path;
  Future<Directory> create({bool recursive = false}) async => this;
  Future<bool> exists() async => false;
}
class FileMode { const FileMode._(); static const write = FileMode._(); static const writeOnlyAppend = FileMode._(); }
class FileSystemException implements Exception { FileSystemException([this.message, this.path]); final String? message; final String? path; }
typedef FileStat = void; // 若未使用可省略
```

> 实际符号集合以各文件真实引用为准；迁移时编译器报错会精确指出缺哪个符号，补到 stub 即可。

所有 app 层 `import 'dart:io';` / `import 'dart:io' show Platform;` 替换为 `import 'package:safenotes/src/platform/platform_io.dart';`。涉及文件：
`main.dart:16` · `window_title_bar.dart:2` · `device_id.dart:24` · `file_handler.dart` · `scheduled_task.dart:15` · `cache_manager.dart:15` · `home.dart` · `backup_setting.dart:12` · `sync_diagnostics_page.dart:17` · `export_backup_dialog.dart:15`。

`core` 包内：`app_logger.dart:31` · `journal.dart:46`（用同样的垫片思路，见 §4）。

### 3.2 SQLite ffi 条件 import

`main.dart:28` 的 `import 'package:sqflite_common_ffi/sqflite_ffi.dart';` 直接拖垮 Web 编译。改法：把 ffi 初始化抽到一个仅在非 Web 才真正导入的文件。

```dart
// lib/src/platform/database_bootstrap.dart
export 'database_bootstrap_native.dart'
    if (dart.library.html) 'database_bootstrap_web.dart';
```

- `database_bootstrap_native.dart`：`import 'package:sqflite_common_ffi/sqflite_ffi.dart';` 并实现 `void initDatabaseForNative() { sqfliteFfiInit(); databaseFactory = databaseFactoryFfi; ...setDatabasesPath... }`。
- `database_bootstrap_web.dart`：空实现 `void initDatabaseForNative() {}`（Web 上 `sqflite` 自带后端自动注册，无需手动设工厂）。

`main.dart:_bootstrap()` 改为调用 `initDatabaseForNative()`（原本那段 `!kIsWeb && (Windows|Linux|macOS)` 分支整体搬进 native 实现里）。

---

## 4. core 包内的 `dart:io` 守卫（Web 编译 + 不崩）

`core` 是纯 Dart 包，但以下文件现实用了 `dart:io`，必须处理，否则 Web 编译失败或运行崩溃。

### 4.1 `app_logger.dart`（文件日志层）
`main._initLogging()` 早期就调用 `AppLogFile.init()`（`app_logger.dart` 用 `File`/`Directory`/`Platform.resolvedExecutable` 写文件）。Web 无文件系统 → **Web 上日志改为 console / 内存**。

推荐：在 `core.dart` 把
```dart
export 'src/logger/app_logger.dart';
```
改为条件 export，Web 走 `app_logger_web.dart`（只 `print` / 内存 ring buffer，无 `dart:io`）。`Log.app.xxx` 调用签名保持不变，业务代码零改动。

### 4.2 `log_webserver.dart`（调试日志 HTTP 服务）
`ServerSocket` / `HttpRequest` / `File` 全是 `dart:io`（`log_webserver.dart:36,176,231,249,265`）。Web 上**整个禁用**：同 §4.1 思路，`core.dart` 条件 export，Web 走 `log_webserver_web.dart`，所有方法（`start`/`stop`/`isRunning`/`port`/`diagnosticsProvider`）返回安全默认值（`isRunning=false`、`start()` 直接返回端口占位）。调用方（`home.dart:103/141` 的 `_startLogWebServer`、`main.dart:202` 的 `_shutdown`、`sync_diagnostics_page.dart` 的启停 UI）无需改逻辑，因为桩已保证 no-op。

### 4.3 `journal.dart`（同步日志持久化）
`_writeLogFile()` / `_loadLogFile()` 用 `Directory.create` / `File`（`journal.dart:479,491,529,646,654`）。Web 上若启用同步需持久化 journal，但本地 dev/test 通常不同步。最稳做法：**`kIsWeb` 时跳过文件读写**（内存态 journal），方法入口 `if (kIsWeb) return;`。文件顶部 `import 'dart:io'` 走 §3.1 垫片。

### 4.4 `local_fs_backend.dart`（本地文件同步后端）
整个文件是 `dart:io` 实现（`local_fs_backend.dart:22` 起几十处 `File`/`Directory`）。Web 不使用该后端。在同步后端工厂处做条件 import：

```dart
// 在 sync_backend 注册处
import 'src/sync/backends/local_fs_backend.dart'
    if (dart.library.html) 'src/sync/backends/local_fs_backend_stub.dart';
```

`local_fs_backend_stub.dart` 提供同名类，构造与所有方法体为空实现（Web 永不实例化，仅满足编译）。`webdav` / `safe_server` 后端基于 `http` 包，跨平台，无需改动。

### 4.5 `deleteDbFile()`（登录页"删除保险库"）
`login.dart:710` 调用 `NotesDatabase.instance.deleteDbFile()`（推测内部 `File(path).delete()`）。Web 上应走 `sqflite` 的 `deleteDatabase()`（删 IndexedDB 库）。在 `database_handler.dart` 内对该方法做 `kIsWeb` 分支：Web 用 `databaseFactory.deleteDatabase(dbPath)`；非 Web 保留原 `File.delete()`。

---

## 5. 插件级条件 import（Web 无实现的插件）

### 5.1 `media_scanner`（无 Web 实现）
`file_handler.dart:27` / `scheduled_task.dart:18` 的 `import 'package:media_scanner/media_scanner.dart';` 拖垮 Web。因导入导出已在 Web 禁用，`MediaScanner.loadMedia` 在 Web 永不该被调用。做法：条件 import 一个 Web 桩（同名 `MediaScanner.loadMedia` → no-op）。或把这些调用包进 `if (!kIsWeb)` 且 import 走垫片。

### 5.2 `local_auth`（无 Web 实现）
`login.dart:24` 的 `import 'package:local_auth/local_auth.dart';` 拖垮 Web。条件 import 一个 Web 桩：`LocalAuthentication` 类存在但 `canCheckBiometrics=false`、`authenticate()` 直接返回 `false`/抛 `UnsupportedError` 被上层 catch。同时 `login.dart` UI 隐藏生物识别按钮：`if (!kIsWeb) ... 显示指纹入口`。

### 5.3 `cryptography_flutter`（仅原生）
app 未直接 import（靠插件自动注册），Web 构建会跳过它、回退 `BrowserCryptography`。**验证点**：`flutter build web` 不应硬失败；若告警/失败，在 `web/` 的 `pubspec` 覆盖或临时从 Web 依赖移除（crypto 仍可用纯 Dart / 浏览器 crypto，仅少硬件加速）。

---

## 6. 功能门控（Web 上禁用导入导出 / 备份 / 日志服务 UI）

| 文件 | 处理 |
|---|---|
| `scheduled_task.dart` | `backup()` / `forceBackup()` 入口首行 `if (kIsWeb) return;`（整体备份在 Web 不做）。 |
| `backup_setting.dart` | 备份/导出相关 tile 用 `if (!kIsWeb) ...` 包裹；`openBackupDirectory`、`writeBackupFile` 调用处同样门控。 |
| `export_backup_dialog.dart` | Web 不展示该对话框（触发入口门控 `if (!kIsWeb)`）。 |
| `sync_diagnostics_page.dart` | 日志 WebServer 启停按钮 `if (!kIsWeb)` 隐藏（底层桩已 no-op，双重保险）。 |
| `main.dart:onAppUpdate()` | 升级后自动备份分支 `if (kIsWeb) return;`（避免触碰文件 I/O）。 |
| `home.dart:_startLogWebServer()` | `if (kIsWeb) return;`。 |
| `file_handler.dart` | 导入/导出方法体首行 `if (kIsWeb) return <安全占位>;`；其余（如纯内存解析）保留。 |

---

## 7. `device_id` Web 分支

`device_id.dart` 无 `kIsWeb` 处理，会落到 `'unknown-<时间戳>'`（`device_id.dart:125`）。加分支返回稳定 id：

```dart
if (kIsWeb) {
  // 用 localStorage（shared_preferences）持久化一个随机 uuid，保证同浏览器稳定
  final prefs = await SharedPreferences.getInstance();
  var id = prefs.getString('web_device_id');
  if (id == null) { id = const Uuid().v4(); prefs.setString('web_device_id', id); }
  return 'web-$id';
}
```

---

## 8. 构建脚手架

```bash
flutter create . --platforms=web     # 生成 web/ + index.html + flutter_bootstrap.js
flutter build web --release           # 产物在 build/web，可托管任意静态服务器
# 本地预览
cd build/web && python -m http.server 8080
```

`web/index.html` 默认即 Flutter 引导页，无需改。资源（`assets/translations` 等）已在 `pubspec.yaml` 的 `flutter.assets` 中，Web 走 `rootBundle` 正常加载（也顺带修好了之前 `_TestAssetLoader` 的 I/O 挂起隐患）。

---

## 9. 测试方案（呼应"Web 测试最省事"）

1. **编译验证**：`flutter build web` 成功 = 所有条件 import 收口。
2. **手动冒烟**：起静态服务器，按 §1 清单逐条走一遍。
3. **Playwright / CDP e2e**（用户偏好路线）：
   - 用 Playwright 驱动 Chromium 打开 Web 版，跑登录→建笔记→列表断言。
   - Chrome DevTools Protocol 做截图、网络拦截、性能分析。
4. **官方 integration_test 也能上 Web**：`flutter test --platform=chrome` 直接在 Chrome 跑现有 widget 测试，无需桌面 GUI 适配。
   - 之前卡住的 `auth_flow_test` 根因（`_TestAssetLoader` 用 `File.readAsString` 挂起）在 Web/测试环境都应改为 `rootBundle.loadString(..).timeout(5s)`（已在另一轮诊断中给出修复），改完 Web 与桌面测试一并解。

---

## 10. 风险与开放问题

- **sqflite Web 持久化**：依赖 IndexedDB，浏览器隐私模式 / 配额 / 清缓存会让库"消失"，开发测试无碍，需注意。
- **同步 CORS**：若 Web 真接 `webdav`/`safe_server`，目标服务需开 CORS；本地 dev 不同步则无此问题。
- **`flutter_secure_storage` Web = localStorage 明文**：因定位是本地测试、安全弱化，可接受；但别把 Web 版当"安全产品"对外发布。
- **构建告警**：`cryptography_flutter`、`media_scanner`(若未完全排除) 等原生插件在 Web 构建可能告警，逐条确认不硬失败即可。
- **`io_stub.dart` 符号完整度**：以编译器报错为准逐步补齐，无预见性风险。

---

## 11. 分步执行清单（checklist）

- [ ] **P0-脚手架**：`flutter create . --platforms=web`
- [ ] **P0-shim**：建 `lib/src/platform/{platform_io.dart, io_stub.dart, database_bootstrap.dart, database_bootstrap_native.dart, database_bootstrap_web.dart}`
- [ ] **P0-sqlite**：`main.dart` ffi import → 条件 import + 抽 `initDatabaseForNative()`
- [ ] **P0-io**：10 个 app 文件 `import 'dart:io'` → `platform_io.dart`
- [ ] **P0-core**：`core.dart` 对 `app_logger` / `log_webserver` 改条件 export（Web 桩）；`local_fs_backend` 条件 import 桩；`journal` / `app_logger` / `deleteDbFile` 加 `kIsWeb` 门控
- [ ] **P0-插件**：`media_scanner` / `local_auth` 条件 import 桩；`login.dart` 隐藏生物识别 UI
- [ ] **P1-门控**：`scheduled_task`/`backup_setting`/`export_backup_dialog`/`sync_diagnostics_page`/`home`/`file_handler`/`main.onAppUpdate` 加 `kIsWeb` 门控
- [ ] **P1-deviceId**：`device_id.dart` 加 Web 分支
- [ ] **P1-验证**：`flutter build web` 出包；起静态服务手动走 §1 清单
- [ ] **P2-e2e**：Playwright 冒烟 + `flutter test --platform=chrome` 跑通 `auth_flow_test`（含 `_TestAssetLoader` rootBundle 修复）

---

## 附：与之前诊断的关联

- `_TestAssetLoader` I/O 挂起修复（改 `rootBundle.loadString`）同时让 Web 翻译加载正确，属一修两用。
- service 层可注入化（KeyValueStore/SecretStore 接入）**不是 Web 移植的硬依赖**，但做完能让 `integration_test` 在 Web/桌面统一用内存 fake，建议作为并行长期项推进。
