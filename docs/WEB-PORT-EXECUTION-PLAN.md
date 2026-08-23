# SafeNotes Web 版移植实施计划（WEB-PORT-EXECUTION-PLAN）

> 日期：2026-08-23
> 目标：实现 `flutter build web` 成功出包，并以本地固定端口 **8000** 跑通完整用户流程。
> 定位：纯本地开发与测试用途，弱化外部安全存储与未支持的原生特性。

---

## 0. 范围与约定

1. **调试端口**：固定为 **8000**（`http://localhost:8000`）。因 WASM SQLite 基于 IndexedDB 存储，数据与 Origin（协议+域名+端口）强绑定，固定 8000 端口确保刷新与重启时数据持久化。
2. **存储引擎**：SQLite WASM（通过 `sqflite_common_ffi_web` + `sqlite3.wasm` + IndexedDB 持久化）。
3. **Core 包纯净性**：`packages/core` 保持纯 Dart，不引入任何 Flutter 依赖，通过条件导出实现 I/O 解耦。
4. **原生功能裁剪**：Web 上禁用/隐藏本地文件导入导出、生物识别、系统窗口管理、调试日志 WebServer。

---

## 1. 架构与垫片设计

### 1.1 条件导出标准范式
全项目统一采用「以 Stub 为默认基底、反向匹配 `dart.library.io`」的标准模式，同时兼容 `dart2js`、`ddc` 与 `dart2wasm`：
```dart
export 'io_stub.dart' if (dart.library.io) 'io_real.dart';
```

### 1.2 目录与文件布局
- **App 层 Platform Shim**：
  - `lib/src/platform/platform_io.dart`（条件导出）
  - `lib/src/platform/io_real.dart`（`export 'dart:io';`）
  - `lib/src/platform/io_stub.dart`（提供 `Platform`, `File`, `Directory`, `FileSystemEntity`, `FileMode`, `FileSystemException`, `IOSink` 等桩实现）
- **Core 包 Platform Shim**：
  - `packages/core/lib/src/platform/platform_io.dart`
  - `packages/core/lib/src/platform/io_real.dart`
  - `packages/core/lib/src/platform/io_stub.dart`
- **数据库引导抽象**：
  - `lib/src/platform/database_bootstrap.dart`（条件导出 Native 与 Web 实现）
  - `lib/src/platform/database_bootstrap_native.dart`（`sqfliteFfiInit` + `databaseFactoryFfi`）
  - `lib/src/platform/database_bootstrap_web.dart`（`databaseFactoryFfiWeb`）
  - `lib/src/platform/database_bootstrap_stub.dart`
- **原生插件与模块隔离**：
  - `lib/utils/desktop_window.dart` → 条件导出 `desktop_window_native.dart` / `desktop_window_stub.dart`
  - `lib/src/logger/log_webserver.dart` → 条件导出 `log_webserver_io.dart` / `log_webserver_web.dart`
  - `packages/core/lib/src/logger/app_logger.dart` → 条件导出 `app_logger_io.dart` / `app_logger_web.dart`
  - `media_scanner` / `permission_handler` / `local_auth` → 条件导入桩类

---

## 2. 分阶段实施任务清单

### 阶段 P0：编译与基础脚手架（让 `flutter build web` 成功出包）
- [ ] **P0-1 WASM 脚手架**：
  - 根目录添加 `sqflite_common_ffi_web: ^0.4.5` 依赖。
  - 执行 `dart run sqflite_common_ffi_web:setup` 生成 `web/sqlite3.wasm` 和 `web/sqflite_sw.js`。
- [ ] **P0-2 Core 包 I/O 解耦**：
  - 移除 `packages/core/lib/src/db/database_handler.dart` 与 `packages/core/lib/src/sync/sync_backend.dart` 中未使用的 `import 'dart:io'`。
  - 建立 `packages/core/lib/src/platform/` 垫片，解耦 `journal.dart`、`local_fs_backend.dart`。
  - 拆分 `app_logger.dart` 为文件日志与 Web 控制台/内存日志。
- [ ] **P0-3 App 层 Platform Shim**：
  - 建立 `lib/src/platform/{platform_io.dart, io_real.dart, io_stub.dart}`。
  - 替换 14 处 App 文件的 `import 'dart:io'` 为 `platform_io.dart`。
- [ ] **P0-4 数据库引导与插件隔离**：
  - 建立 `database_bootstrap.dart`，重构 `main.dart` 中的数据库初始化。
  - 建立 `desktop_window.dart`、`log_webserver.dart` 条件导出。
  - 对 `media_scanner`、`storage_permission`、`local_auth` 进行桩化隔离。

### 阶段 P1：运行时门控与流程打通（消灭运行时崩溃）
- [ ] **P1-1 `path_provider` 拦截**：
  - 在 `main.dart:_initLogging`、`cache_manager.dart`、`sync_service.dart:_openJournal`、`scheduled_task.dart` 中增加 `kIsWeb` 保护，防止调用 `getApplicationSupportDirectory` 抛出 `UnsupportedError`。
- [ ] **P1-2 Web 设备 ID**：
  - `device_id.dart` 实现 `kIsWeb` 分支，利用 `SharedPreferences` 持久化生成稳定的 UUID。
- [ ] **P1-3 数据库重置与删除适配**：
  - `database_handler.dart:deleteDbFile` 针对 Web 环境执行清空表/重建表逻辑，规避 WASM 不支持 `deleteDatabase`。
  - `login.dart:_performLocalDataReset` 在 Web 环境跳过文件备份，直接重置。
- [ ] **P1-4 UI 门控**：
  - 设置页、登录页隐藏备份/导入导出、生物识别、日志 WebServer 启停开关。

### 阶段 P2：验证、测试与固化
- [ ] **P2-1 静态检查与单测**：
  - 运行 `flutter analyze` 确保 0 errors/warnings。
  - 运行 `dart test packages/core/test` 确保核心单测全部通过。
  - 运行 `flutter test` 确保 App 单元/Widget 测试全部通过。
- [ ] **P2-2 Web 构建与冒烟验证**：
  - 运行 `flutter build web --release` 验证出包。
  - 启动本地测试服务器 `python -m http.server 8000 --directory build/web`。
  - 浏览器访问 `http://localhost:8000`，按 §1 验收清单验证全流程。

---

## 3. 全流程验收标准（Web 8000 端口）
1. 首次启动 → 初始化设置主密码 → 建库成功进入主界面。
2. 增删改查笔记 → 搜索过滤正常。
3. 设置页修改主题（亮/暗）和语言 → 即时生效。
4. 会话超时/手动登出 → 返回锁屏。
5. 刷新页面（F5）重新用密码登录 → 数据完整保留（IndexedDB 持久化生效）。
6. 重置本地数据（忘记密码逃生通道）→ 数据库清空、回到初始建库页面。
