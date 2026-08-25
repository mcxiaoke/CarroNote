# SafeNotes Web 版移植计划（WEB-PORT-PLAN）

> 状态：**已完成**（已全量落地并通过自动化测试与生产出包验证）
> 目标：让 `safenotes` 能以 `flutter build web` 出包，并在浏览器里跑通**完整用户流程**（建库→设密码→登录→增删改笔记→列表/搜索→设置→登出/会话超时）。
> 定位：**纯本地开发 / 测试用途**。

---

## 0. 范围与边界（已与用户确认）

| 项 | 决策 |
|---|---|
| 安全强度 | **弱化无所谓**。Web 版为本地 dev/test，不要求 HTTPS/CSP/SRI、不要求 OS 级安全存储。 |
| 导入 / 导出 | **Web 上不支持**。相关 UI 与逻辑在 Web 一律禁用 / no-op。 |
| 指纹 / 生物识别 | **Web 上不支持**。login 走纯密码；`local_auth` 在 Web 不引入。 |
| 存储引擎 | **保留 SQLite**，Web 端用 `sqflite_common_ffi_web`（WASM SQLite + IndexedDB 持久化）。**不使用 LevelDB**（无浏览器移植，且换成 NoSQL 要重写全部 SQL）。 ⚠️ `sqflite` 本身**不支持 Web**，Web 依赖 `sqflite_common_ffi_web` + `sqlite3.wasm` 二进制（见 §3.2）。 |
| 同步 | Web 端只走 `webdav` / `safe_server`（HTTP，`http` 包，跨平台可用）；`local_fs` 后端（纯 `dart:io`）在 Web 排除。本地 dev/test 可不配置同步，app 不依赖同步即可跑全流程。 |

**不做的事**：安全加固、导入导出 Web 实现、生物识别 Web 实现、SQL 改写、LevelDB 移植。

---

## 1. 全流程验收清单（Web 必须跑通）

1. [x] 首次启动 → 进入初始化（设主密码）→ 建库成功。
2. [x] 重启用主密码登录 → 进入主页（笔记列表为空）。
3. [x] 新建笔记 → 输入标题/正文 → 保存 → 列表出现该笔记。
4. [x] 打开笔记 → 编辑 → 保存 → 返回列表内容更新。
5. [x] 删除笔记 → 软删除生效 → 列表消失。
6. [x] 搜索（按标题/正文）→ 结果正确。
7. [x] 设置页打开 → 普通设置项可读写（主题、超时、语言切换）。
8. [x] 会话超时 / 手动登出 → 回到 AuthWall。
9. [x] 二次登录 → 数据仍在（IndexedDB 持久化）。
10. [x] 调试日志：Web 上不启日志 WebServer，仅 console / 内存日志，不崩。

**明确不在验收内**：备份/导出/导入对话框、生物识别登录、本地文件同步。

---

## 2. 现有架构优势与平台关键认知

- `packages/core` 是纯 Dart 包，DB 访问已通过 `NotesDatabase.dbFactoryOverride` 注入（`database_handler.dart:125`），`main.dart:206` 把这个工厂设成全局 `databaseFactory`。Web 上只要把全局 factory 换成 `databaseFactoryFfiWeb`（见 §3.2），**同一套 SQL 零改动**。
- `DeviceIdProvider.overrideForTesting` 已存在（`device_id.dart`），Web 设备 ID 只需加一个 `kIsWeb` 分支。
- `main.dart` 里 ffi 初始化、`SystemChrome` 取向已经被 `isDesktopPlatform` / `!kIsWeb` 守卫，逻辑分支清晰。
- `easy_localization` / `shared_preferences` / `url_launcher` / `device_info_plus` / `file_picker` 均有 Web 实现，开箱可用。
- ⚠️ **重大修正（`path_provider` 的 Web 特性）**：`path_provider_web` 在浏览器环境下**没有真实文件系统**，调用 `getApplicationSupportDirectory()` / `getApplicationDocumentsDirectory()` / `getTemporaryDirectory()` 会**直接抛出 `UnsupportedError`**！因此 Web 上所有涉及 `path_provider` 的调用路径**必须通过 `kIsWeb` 门控跳过或返回安全默认值**（见 §6），不能假设其能正常返回路径。

---

## 3. 核心机制：平台垫片（platform shim）

Web 编译的死穴是**文件里出现 `import 'dart:io'` / `import 'package:sqflite_common_ffi'` / 不支持 Web 的原生插件**。Dart 不允许“导入但不使用”——只要静态 import 存在，Web 编译即失败。统一解法：**条件 import（conditional import）**，让 Web 走一个空/桩实现。

### 3.1 `dart:io` 垫片与标准条件导出

为兼容 JS 编译（`dart2js`/`ddc`）与 WASM 编译（`dart2wasm`，此时 `dart:html` 不可用），采用**以 stub 为默认基底、反向匹配 `dart.library.io`** 的标准模式：

新建 `lib/src/platform/platform_io.dart`：

```dart
// lib/src/platform/platform_io.dart
export 'io_stub.dart' if (dart.library.io) 'io_real.dart';
```

新建 `lib/src/platform/io_real.dart`：

```dart
// lib/src/platform/io_real.dart
export 'dart:io';
```

新建 `lib/src/platform/io_stub.dart`，提供 Web 上被引用到的全部 `dart:io` 符号（编译期占位与安全默认值，运行时不会执行真实文件 I/O）：

```dart
// lib/src/platform/io_stub.dart
// 仅用于让 Web 编译通过；Web 上这些符号永远不会被真实调用，或返回安全默认值。
import 'dart:async';
import 'dart:typed_data';

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
  static const Map<String, String> environment = <String, String>{};
}

class File {
  File(this.path);
  final String path;
  Directory get parent => Directory('');
  Future<bool> exists() async => false;
  bool existsSync() => false;
  Future<File> create({bool recursive = false}) async => this;
  Future<void> delete() async {}
  Future<File> writeAsString(String c, {FileMode mode = FileMode.write, bool flush = false}) async => this;
  Future<File> writeAsBytes(List<int> bytes, {FileMode mode = FileMode.write, bool flush = false}) async => this;
  Future<String> readAsString() async => '';
  String readAsStringSync() => '';
  Future<Uint8List> readAsBytes() async => Uint8List(0);
  Future<File> rename(String newPath) async => File(newPath);
  Future<File> copy(String newPath) async => File(newPath);
  Future<int> length() async => 0;
  Stream<List<int>> openRead([int? a, int? b]) => const Stream.empty();
  IOSink openWrite({FileMode mode = FileMode.write, dynamic encoding}) => throw UnsupportedError('Web openWrite');
}

class Directory {
  Directory(this.path);
  final String path;
  Future<Directory> create({bool recursive = false}) async => this;
  Future<bool> exists() async => false;
  bool existsSync() => false;
  Future<void> delete({bool recursive = false}) async {}
  void deleteSync({bool recursive = false}) {}
  Stream<FileSystemEntity> list({bool recursive = false, bool followLinks = true}) => const Stream.empty();
  List<FileSystemEntity> listSync({bool recursive = false, bool followLinks = true}) => const [];
}

abstract class FileSystemEntity {
  String get path => '';
}

class FileMode {
  const FileMode._();
  static const write = FileMode._();
  static const writeOnlyAppend = FileMode._();
  static const append = FileMode._();
  static const read = FileMode._();
}

class FileSystemException implements Exception {
  FileSystemException([this.message, this.path]);
  final String? message;
  final String? path;
  @override
  String toString() => 'FileSystemException: $message ($path)';
}

abstract class IOSink implements Sink<List<int>> {}
```

#### 需替换 `import 'dart:io'` 的完整文件清单（共 14 个 App 文件）

将所有 app 层的 `import 'dart:io';` / `import 'dart:io' show ...;` 替换为 `import 'package:safenotes/src/platform/platform_io.dart';`：
1. `lib/main.dart`
2. `lib/utils/window_title_bar.dart`
3. `lib/utils/device_id.dart`
4. `lib/models/file_handler.dart`
5. `lib/utils/scheduled_task.dart`
6. `lib/utils/cache_manager.dart`
7. `lib/views/settings/backup_setting.dart`
8. `lib/views/settings/sync_diagnostics_page.dart`
9. `lib/dialogs/export_backup_dialog.dart`
10. `lib/utils/vault_backup.dart`
11. `lib/src/logger/log_webserver.dart`
12. **`lib/data/prefs_store_override.dart`（关键遗漏补全）**
13. **`lib/sync/sync_service.dart`（关键遗漏补全）**
14. **`lib/utils/env_config.dart`（关键遗漏补全）**

---

### 3.2 SQLite Web 后端 + ffi 条件 import

`main.dart:27` 的 `import 'package:sqflite_common_ffi/sqflite_ffi.dart';` 会拖垮 Web 编译。改法：把 ffi 初始化抽离为条件导出。

```dart
// lib/src/platform/database_bootstrap.dart
export 'database_bootstrap_stub.dart'
    if (dart.library.io) 'database_bootstrap_native.dart'
    if (dart.library.js_interop) 'database_bootstrap_web.dart';
```

- `database_bootstrap_native.dart`：
  ```dart
  import 'package:sqflite_common_ffi/sqflite_ffi.dart';
  import 'package:path_provider/path_provider.dart';
  import 'package:safenotes/main.dart' show dataDirOverride;

  Future<void> initDatabaseForPlatform() async {
    sqfliteFfiInit();
    databaseFactoryOrNull = databaseFactoryFfi;
    final dbDir = dataDirOverride ?? (await getApplicationSupportDirectory()).path;
    await databaseFactory.setDatabasesPath(dbDir);
  }
  ```
- `database_bootstrap_web.dart`：
  ```dart
  import 'package:sqflite_common/sqflite.dart';
  import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

  Future<void> initDatabaseForPlatform() async {
    databaseFactory = databaseFactoryFfiWeb;
  }
  ```
- `database_bootstrap_stub.dart`：空实现。

`main.dart:_bootstrap()` 改为调用 `initDatabaseForPlatform()`，移除原有的桌面 FFI 平台分支。

**新增依赖与脚手架（P0 必做）**：
```bash
flutter pub add sqflite_common_ffi_web
dart run sqflite_common_ffi_web:setup        # 生成 web/sqlite3.wasm + web/sqflite_sw.js
```
- 验证 `web/sqlite3.wasm` 和 `web/sqflite_sw.js` 已正确生成。
- 依赖升级时使用 `--force` 重新生成。

---

### 3.3 桌面端原生插件隔离（`window_manager`）

`lib/utils/desktop_window.dart` 顶层导入了 `package:window_manager/window_manager.dart`。为保证 Web 构建的纯净性，对该文件做条件隔离：

```dart
// lib/utils/desktop_window.dart
export 'desktop_window_stub.dart'
    if (dart.library.io) 'desktop_window_native.dart';
```
- `desktop_window_native.dart`：保留原有的 `window_manager` 初始化与尺寸控制。
- `desktop_window_stub.dart`：所有方法（`initDesktopWindowManager`、`setWindowSize` 等）为空操作（no-op）。

---

## 4. core 包内的 `dart:io` 守卫与解耦（纯 Dart + 零 Flutter 依赖）

`packages/core` 是纯 Dart 包（严禁引入 Flutter），必须在内部完成平台解耦。

### 4.1 `app_logger.dart`（文件日志层）
`main._initLogging()` 调用 `AppLogFile.init()`。Web 无本地文件系统，日志改为 console / 内存 ring buffer。
在 `app_logger.dart` 文件内部做条件 import：
```dart
// packages/core/lib/src/logger/app_logger.dart 顶部
import 'app_logger_io.dart'
    if (dart.library.js_interop) 'app_logger_web.dart'
    if (dart.library.html) 'app_logger_web.dart';
```
- `app_logger_io.dart`：现有文件日志实现。
- `app_logger_web.dart`：同名 `AppLogFile` 桩，`init()`/`flush()`/`close()` 为 no-op，`dirPath` 返回 null。
业务层 `Log.app.xxx` 签名完全保持不变。

### 4.2 `log_webserver.dart`（调试日志 HTTP 服务）
`lib/src/logger/log_webserver.dart` 是 **app 层**文件，内部大量使用 `ServerSocket` / `HttpRequest` / `File`。
Web 上通过条件 import 导出一个桩实现 `log_webserver_web.dart`，`start()` / `stop()` 为 no-op，`isRunning` 恒返回 false。

### 4.3 `journal.dart`（同步日志持久化）
在 `packages/core` 内新建 `packages/core/lib/src/platform/platform_io.dart` 垫片。
`journal.dart` 顶部的 `import 'dart:io';` 改为引用 core 内部的 `platform_io.dart`。桩中的 `File`/`Directory` 安全返回空，journal 自动退化为内存态，不抛异常。

### 4.4 `local_fs_backend.dart` 与 `sync_backend.dart`
- `local_fs_backend.dart`：通过同步后端注册处的条件 import 引入 Web 桩（`local_fs_backend_stub.dart`）。
- **`sync_backend.dart` 解耦**：公共基类文件中的 `writeRingBackup(Directory dir, ...)` 仅用于本地文件后端，将其移入 `local_fs_backend.dart`，或让 `sync_backend.dart` 引用 core 垫片，消除基类对 `dart:io` 的直接硬依赖。

### 4.5 `deleteDbFile()`（登录页“重置/删除保险库”）
`sqflite_common_ffi_web` 官方明确 **"deleteDatabase is not supported on wasm"**。
解决方案：
- 在 `database_handler.dart` 中，Web 端调用 `deleteDbFile()` 时执行**清空重建**（Drop 所有业务表与元数据表 + 重新执行建表），等价于重置本地数据库，WASM 原生完美支持。

---

## 5. 插件级条件 import（无 Web 实现的原生插件）

### 5.1 `media_scanner`
`file_handler.dart` 与 `scheduled_task.dart` 中的 `MediaScanner.loadMedia` 在 Web 上通过条件 import 替换为同名 no-op 桩。

### 5.2 `local_auth`
`lib/views/authentication/login.dart` 中通过条件 import 引入 `local_auth_stub.dart`：
- `LocalAuthentication` 桩类：`canCheckBiometrics = false`、`isDeviceSupported() = false`、`authenticate() = false`。
- `login.dart` UI 自动隐藏指纹登录入口（结合 `!kIsWeb` 门控）。

### 5.3 `permission_handler`
`lib/utils/storage_permission.dart` 顶层 import 替换为 Web 桩（`Permission.storage.request()` 恒返回 `PermissionStatus.granted`）。

### 5.4 `cryptography_flutter`
Web 构建时跳过原生插件注册，自动回退到 `cryptography` 的 `BrowserCryptography` / 纯 Dart 加密实现，无须手动干预。

---

## 6. 功能门控（Web 关键阻碍拦截与禁用）

| 文件 | 门控点与处理方式 |
|---|---|
| `main.dart:_initLogging` | `logDirResolverOverride` 增加 `if (kIsWeb) return null;`（**防止调用 `getApplicationSupportDirectory` 抛 UnsupportedError 导致启动崩溃**）。 |
| `main.dart:onAppUpdate` | 升级后自动备份增加 `if (kIsWeb) return;`。 |
| `login.dart:_performLocalDataReset` | **关键修正**：前置备份 `backupVaultBeforeReset()` 增加 `if (!kIsWeb)` 包裹；Web 端跳过文件备份直接执行 DB 重置与 Prefs 清理，防止重置流程被中止。 |
| `sync_service.dart:_openJournal` | 沙盒目录解析增加 `kIsWeb` 保护（Web 返回安全 dummy 路径或跳过文件创建）。 |
| `cache_manager.dart:emptyCache` | 增加 `if (kIsWeb) return;`（防止 `getTemporaryDirectory` 抛错）。 |
| `scheduled_task.dart` | `backup()` / `forceBackup()` 入口首行 `if (kIsWeb) return;`。 |
| `backup_setting.dart` | 备份/导出相关 Tile 使用 `if (!kIsWeb) ...` 隐藏。 |
| `export_backup_dialog.dart` | 对话框入口门控 `if (!kIsWeb)`。 |
| `sync_diagnostics_page.dart` | 日志 WebServer 启停按钮 `if (!kIsWeb)` 隐藏。 |
| `home.dart:_startLogWebServer` | `if (kIsWeb) return;`。 |
| `file_handler.dart` | 导入/导出方法体首行 `if (kIsWeb) return <安全占位>;`。 |

---

## 7. `device_id` Web 分支

`lib/utils/device_id.dart` 增加 `kIsWeb` 分支，利用 `shared_preferences` 持久化一个稳定的随机 UUID：

```dart
if (kIsWeb) {
  final prefs = await SharedPreferences.getInstance();
  var id = prefs.getString('web_device_id');
  if (id == null) {
    id = const Uuid().v4();
    await prefs.setString('web_device_id', id);
  }
  return '${prefix}web-$id';
}
```

---

## 8. 构建脚手架与本地调试

### 8.1 资源初始化与构建
```bash
# 1. 初始化 sqflite wasm 二进制
dart run sqflite_common_ffi_web:setup

# 2. Web 生产构建
flutter build web --release

# 3. 本地预览服务器
cd build/web && python -m http.server 8080
```

### 8.2 注意事项
- **MIME 类型**：确保 Web 服务器对 `.wasm` 文件响应 `Content-Type: application/wasm`。
- **IndexedDB 作用域**：数据与“协议+主机名+端口”强绑定，调试时请固定端口（如 `8080`），避免更换端口造成“数据丢失”假象。

---

## 9. 测试与验收方案

1. [x] **静态检查**：`flutter analyze` 零 Error。
2. [x] **编译验证**：`flutter build web --release` 成功出包。
3. [x] **冒烟流程（按 §1 清单验证）**：
   - 首次初始化设置主密码 → 建库成功。
   - 新建笔记 → 标题/正文编辑 → 保存 → 列表展示。
   - 刷新页面（F5）→ 弹出登录页 → 输入密码成功解锁 → 数据完好。
   - 搜索、修改、软删除、恢复测试。
   - 设置页切换深色模式、语言切换、会话超时测试。
   - 忘记密码 / 重置本地数据流程测试。
4. [x] **自动化 E2E**：已通过 Chrome/Edge DevTools CDP 自动化启动验证。

---

## 10. 分步执行清单（Checklist）

### P0：编译与基础脚手架（让 `flutter build web` 成功）
- [x] **P0-WASM**：`sqflite_common_ffi_web: ^1.1.2` + `web/sqlite3.wasm` + `web/sqflite_sw.js` 就绪。
- [x] **P0-App-Platform**：建立 `lib/src/platform/{platform_io.dart, io_real.dart, io_stub.dart, data_dir_override.dart, env_reader.dart}`。
- [x] **P0-App-IO 替换**：全库 App 文件 `import 'dart:io'` 均替换为 `platform_io.dart` / 条件导出。
- [x] **P0-Core-Platform**：建立 `packages/core/lib/src/platform/platform_io.dart`，core 包彻底解耦 `dart:io`。
- [x] **P0-DB-Bootstrap**：建立 `database_bootstrap.dart`，Web 端注入 `databaseFactoryFfiWebNoWebWorker`。
- [x] **P0-Plugin-Stubs**：为 `local_auth`、`window_manager`、`log_webserver` 建立 Web 桩。

### P1：运行时门控与流程跑通（消灭运行时崩溃）
- [x] **P1-PathProvider 门控**：在 `main._initLogging`、`sync_service`、`cache_manager` 拦截 `path_provider` 调用，Web Journal 走 `Journal.inMemory`。
- [x] **P1-Reset 流程修复**：`login.dart:_performLocalDataReset` 在 Web 跳过文件备份，直接重置。
- [x] **P1-UI 门控**：隐藏 Web 上的备份、导入导出、生物识别、日志 WebServer 入口。
- [x] **P1-DeviceId**：`device_id.dart` 实现 `kIsWeb` 稳定 UUID。
- [x] **P1-DB-Reset**：`database_handler.dart:deleteDbFile` 在 Web 走 Drop/重建表与安全路径回退。

### P2：验证与固化
- [x] **P2-Build**：`flutter build web --release` 编译出包成功。
- [x] **P2-Smoke**：Edge/Chrome DevTools 自动化冒烟走通全流程。
