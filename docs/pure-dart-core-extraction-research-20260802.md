# SafeNotes 核心逻辑纯 Dart 化研究报告

> 撰写时间（本机系统时间）：2026-08-02 18:44:21
> 环境：Dart SDK 3.12.2 / Flutter 3.44.8 (stable) / Windows 10 Pro
> 目标：把核心逻辑（加密、数据库、同步引擎）从 Flutter 剥离，用纯 Dart CLI 驱动测试，不涉及 UI

---

## 0. 结论先行

**本项目距离「纯 Dart 核心」只差 3 个文件的 5 行 import。** 这不是推测——本次调研做了真机实验并已完整回滚，实验证据见第 6 节。

> 口径说明：这里的"5 行 import"指**编译期阻塞点**；配套改动（pubspec 增加 `meta`/`test` 声明、`logDirResolverOverride`/`dbFactoryOverride` 等接线、移动端 factory 注入）见第 4 节各阶段，工作量已包含在阶段估算里。本文档已于 2026-08-02 经独立复核并修正，复核记录见 6.4。

实测结果（`dart run` / `dart test`，纯 Dart VM，**无 Flutter 引擎**）：

| 验证项 | 结果 |
|---|---|
| SQLite 读写（sqflite_common_ffi） | ✅ 通过 |
| AES-256-GCM 加解密（cryptography） | ✅ 通过 |
| PBKDF2 / SHA256（pointycastle） | ✅ 通过 |
| `NotesDatabase` 笔记存取 + 字段级加解密往返 | ✅ `title=纯Dart标题 desc=纯Dart正文` |
| 落盘确为密文（不含明文） | ✅ `raw=mJy0BXiadDqP7rh9KSoxvyUd…` |
| `SyncEngine` / `Keyring` / `Journal` / `LocalFsBackend` / `WebDavBackend` / `SyncCrypto` 加载 | ✅ 全部通过 |
| `dart test` 跑 `keyring_test.dart`（仅换 import） | ✅ **28/28 All tests passed**（耗时 1分10秒） |

**核心判断：不需要大重构，不需要 Clean Architecture 全套，不需要引入 DI 框架。** 本项目已经具备良好的接口设计（`SyncBackend` 抽象 + `SyncEngine` 构造函数注入），真正的障碍只是**两个"顺手写下"的 import**。

---

## 1. 现状诊断

### 1.1 量化污染

`lib/` 共 77 个 `.dart` 文件，其中 `lib/sync/` + `lib/data/` + `lib/encryption/` 共 **11625 行**（含空行，即"约 11600 行"）是核心逻辑。

按 import 传递闭包分析：

| 指标 | 数值 |
|---|---|
| 直接 import `package:flutter/*` 或 `dart:ui` | 48 / 77 |
| 直接 import Flutter-only 插件 | 51 / 77 |
| **传递闭包被污染** | **72 / 77** |
| 当前真正纯 Dart | 5 / 77 |

当前仅有的 5 个纯 Dart 文件：`sync/sync_backend.dart`、`sync/sync_error.dart`、`utils/build_info.dart`、`utils/passphrase_util.dart`、`utils/string_utils.dart`。

### 1.2 两个"元凶"文件

传递闭包分析显示，**约 9000 行核心逻辑被 2 个文件卡住**：

**元凶 A：`lib/utils/app_logger.dart`** —— 被 33 个文件 import，是头号污染源。

```dart
lib/utils/app_logger.dart:34  import 'package:flutter/foundation.dart' show kDebugMode, kReleaseMode;
lib/utils/app_logger.dart:36  import 'package:path_provider/path_provider.dart';
```

实际用到的地方只有 4 处（`:269`、`:344`、`:502`、`:565`）。一个日志工具类把整个项目焊死在 Flutter 上。

**元凶 B：`lib/data/database_handler.dart`**（1348 行）

```dart
lib/data/database_handler.dart:25  import 'package:flutter/foundation.dart' show visibleForTesting;
lib/data/database_handler.dart:27  import 'package:sqflite/sqflite.dart';
```

第 25 行尤其讽刺：`visibleForTesting` 本来就是 `package:meta` 的注解，Flutter 只是转出（re-export）。**换个 import 零成本、零风险。**

第 27 行 `sqflite` 是 Flutter plugin，但它的实现 `sqflite_common` 是**纯 Dart 包**（自身依赖只有 synchronized/path/meta；sqlite3 由 `sqflite_common_ffi` 提供，同为纯 Dart + 原生库），且已经在 `pubspec.lock` 里。

### 1.3 编译期错误实录

```
$ dart run <import database_handler.dart>
Error: Dart library 'dart:ui' is not available on this platform.
Context: The unavailable library 'dart:ui' is imported through these packages:
    => package:safenotes/data/database_handler.dart
    => package:flutter/foundation.dart
    => package:flutter/src/foundation/assertions.dart
    => package:flutter/src/foundation/diagnostics.dart
    => dart:ui
```

> **关键认知：`package:flutter/foundation.dart` 不是"轻量的 Flutter"。** 它传递依赖 `dart:ui`，在纯 Dart VM 下必然编译失败。`kDebugMode`、`debugPrint`、`compute`、`ChangeNotifier`、`visibleForTesting`、`listEquals` 这些"看起来无害"的符号，每一个都会让文件永久绑死在 Flutter 上。这是 Flutter 项目中最常见、也最容易被忽视的架构泄漏。

### 1.4 已有的良好设计（不要推翻）

调研中发现本项目**已经做对了很多事**，重构时应当保留而非重做：

- `lib/sync/sync_backend.dart:28` —— `abstract class SyncBackend` 已是干净的端口抽象，4 个实现（LocalFS / WebDAV / SafeServer / Fake），且**本身就是纯 Dart**。
- `lib/sync/sync_engine.dart:58-112` —— `SyncEngine` 已经是**构造函数注入**：`backend`、`database`、`keyring`、`deviceId`、`journal`、`passphraseProvider`，完全不依赖 `BuildContext`。
- `lib/data/database_handler.dart:338` `setDatabaseForTesting` / `:345` `createDBForTesting`、`Journal.inMemory` —— 已有测试注入后门。
- `test/` 已有 16 个文件约 12000 行测试（含 `sync_test_support.dart`），其中 10 个已在 `setUp` 里写 `sqfliteFfiInit(); databaseFactory = databaseFactoryFfi;`（逐文件核对，见 5.5）。

> **换句话说：测试其实早就跑在纯 Dart SQLite 上了，只是被 `flutter test` 这层壳包着。**

### 1.5 真正的反模式

| 问题 | 位置 |
|---|---|
| 静态单例，无法替身化 | `NotesDatabase.instance` (`database_handler.dart:97`)、`SyncService.instance` (`sync_service.dart:102`)、`AppLogBuffer.instance`、`DeviceIdProvider.instance`、`LogWebServer.instance` |
| 全静态 getter/setter | `PreferencesStorage`、`SyncConfig`（`preference_and_config.dart`、`sync_config.dart`） |
| 配置类里混了 UI 查询 | `preference_and_config.dart:140,147` 直接读 `WidgetsBinding...platformBrightness` |
| 平台能力被 service 层直呼 | `path_provider` 出现在 `app_logger.dart:36`、`sync_service.dart:26`、`cache_manager.dart:18` |

好消息：项目**没有任何自定义 MethodChannel**，`dart:ui` 只出现在 dialogs（`ImageFilter`）和 `text_direction_util.dart:15`，都在 UI 层。

另一个好消息（复核发现）：pubspec 虽声明了 `cryptography_flutter`，但 `lib/`、`test/`、`server/` 里**没有任何真实 import**（仅注释提及），核心加密栈当前就是纯 `cryptography`（DartAesGcm），提取路径没有隐藏障碍；是否移除这个未使用依赖是另一个议题，与本次改造无关。

---

## 2. 业界怎么做

### 2.1 Very Good Ventures：分层 monorepo（最贴合本项目）

VGV（Flutter 领域最知名的咨询公司，`very_good_cli` 作者）的[分层架构规范](https://engineering.verygood.ventures/development/architecture/architecture/)把 App 分成四层，**并明确规定哪些层禁止依赖 Flutter**：

| 层 | 职责 | Flutter 依赖 |
|---|---|---|
| Data Layer | 裸数据获取：SQLite、Shared Preferences、文件系统、REST | **禁止** |
| Repository Layer | 组合多个 data client，施加业务规则 | 原文：*"Packages in this layer should **not import any Flutter dependencies** and not be dependent on other repositories."* |
| Business Logic Layer | bloc/cubit，feature 级逻辑 | 原文：*"should have **no dependency on the Flutter SDK**"* |
| Presentation Layer | Widget 渲染 | 是（唯一一层） |

关键的**物理隔离**手段（这是本报告推荐路线的核心）：

> *"The presentation layer and state management live in the project's `lib` folder. The data and repository layers will live as separate packages within the project's `packages` folder."*

目录形态：

```
my_app/
  lib/            ← Flutter UI + 状态管理
  packages/
    user_repository/   ← 纯 Dart package，有自己的 pubspec + test
    api_client/        ← 纯 Dart package
  test/
```

依赖方向硬约束：*"data should only flow from the bottom up, and a layer can only access the layer directly beneath it."*

**为什么这是最有效的做法**：把纯 Dart 代码放进独立 package，其 `pubspec.yaml` 里**根本没有 `flutter: sdk: flutter`**。此时"不许 import Flutter"不再是靠自觉或 code review，而是**编译器强制**——写错了直接编译失败。这是"用构建系统代替纪律"。

### 2.2 Flutter 官方架构指南

Flutter 官方[架构指南](https://docs.flutter.dev/app-architecture/guide)推荐 MVVM，分 UI Layer（View + ViewModel）与 Data Layer（Repository + Service），Domain Layer（use-case / interactor）为**可选**：

- Repository 是 *"the source of truth for your model data"*，负责缓存、错误处理、重试、轮询。
- Service *"wrap API endpoints"*、*"hold no state"*，一个数据源一个 service。
- 关于 Domain 层，官方态度很克制：*"This layer is optional because not all applications... A good approach is to **add use-cases only when needed**."*，并列出缺点：*"Increases complexity of your architecture, adding more classes and higher cognitive load"*、*"Testing requires additional mocks"*。

> **对本项目的启示**：官方明确反对为了架构而架构。SafeNotes 的 `SyncEngine` 本质上就是一个巨型 use-case，已经足够，**不需要再套一层 UseCase 类**。

### 2.3 Dart Pub Workspaces（Dart 3.6+，官方 monorepo 方案）

从 [Dart 3.6](https://dart.dev/tools/pub/workspaces) 起，pub 原生支持 workspace，**这是拆多 package 的成本从"高"降到"低"的关键变化**——过去必须靠第三方的 melos，现在官方内置。

根 `pubspec.yaml`：

```yaml
name: _
publish_to: none
environment:
  sdk: ^3.6.0
workspace:
  - packages/safenotes_core
```

子包 `pubspec.yaml` 加一行：

```yaml
environment:
  sdk: ^3.6.0
resolution: workspace
```

收益（官方原文）：
- 单一 `pubspec.lock` + 单一 `.dart_tool/package_config.json`，一次 `dart pub get` 搞定全部
- *"reduces the amount of memory required for analysis"* —— IDE 不再为每个 package 建独立分析上下文
- 子包互相依赖时自动解析到本地版本
- Dart 3.11+ 支持 glob：`workspace: [packages/*]`

本项目 SDK 约束是 `>=3.12.0`，**完全满足，可以直接用**。

### 2.4 用 lint 守住边界

`clean_architecture_kit` 这类 lint 包提供的规则很有代表性：

> *"Disallows any `import 'package:flutter/...'` statement in any domain layer file, guaranteeing that your core business logic is pure Dart and can be tested without a Flutter environment."*

不过如果采用 2.1 的独立 package 方案，**这条 lint 就是多余的**——编译器已经做了这件事。lint 只在"单 package 内靠目录分层"的方案里才需要。

### 2.5 更激进的参照：核心逻辑完全脱离 Dart

AppFlowy（Rust core + Flutter shell）、Serverpod（client/server 共享 model package）代表了另一极端。对 SafeNotes 而言**过度**了：本项目的加密与同步逻辑用 Dart 写得很好，`cryptography` / `pointycastle` / `sqlite3` 生态都有成熟的纯 Dart 实现，没有跨语言的必要。

---

## 3. 接口 vs DI：本项目该选什么

用户问题里提到"可以用接口或 DI"。这两者不是二选一，而是**同一件事的两半**：接口定义边界，DI 负责在边界两侧接线。真正要决策的是**接线机制**。

### 3.1 三种接线机制对比

| 机制 | 做法 | 优点 | 缺点 | 适配度 |
|---|---|---|---|---|
| **构造函数注入**（纯手工 DI） | `SyncEngine(backend: ..., database: ...)` | 零依赖、零魔法、编译期检查、纯 Dart 可用 | 顶层装配代码略啰嗦 | ⭐⭐⭐⭐⭐ **项目已在用** |
| **Service Locator**（get_it） | `getIt<SyncEngine>()` | 调用点简洁 | 隐式依赖、运行时才报错、易退化成全局变量 | ⭐⭐ 本质是把现有的 `.instance` 单例换个写法 |
| **Riverpod / Provider** | `ref.watch(syncEngineProvider)` | 与 UI 响应式联动好 | `provider` 依赖 `BuildContext`，**核心层不能用**；riverpod 虽可脱离 Flutter 但要引入 `riverpod` 纯 Dart 包并重构 | ⭐⭐ 引入成本 > 收益 |

### 3.2 建议

**核心层用构造函数注入 + 抽象接口；UI 层继续用现有的 `provider`（它只管 `ThemeProvider`/`NotesColor` 两个主题类，与业务无关，不必动）。**

理由：
1. `SyncEngine` **已经是**构造函数注入了（`sync_engine.dart:58-112`），沿用即可，改动量为零。
2. 引入 get_it / riverpod 会新增依赖、新增学习成本，而**解决不了任何当前的实际问题**——阻塞点是 import，不是接线方式。
3. 构造函数注入在纯 Dart CLI 里天然可用，不需要任何容器初始化。

### 3.3 需要新抽出的接口（端口）

沿用现有 `SyncBackend` 的风格，为剩余平台能力定义端口。**只抽 4 个，不要更多**：

```dart
// packages/safenotes_core/lib/src/ports.dart

/// 目录解析：日志目录、数据库目录、缓存目录
abstract interface class PathProvider {
  Future<String> dataDir();
  Future<String> logDir();
}

/// 普通键值存储（当前由 shared_preferences 承担）
abstract interface class KeyValueStore {
  String? getString(String key);
  Future<void> setString(String key, String value);
  Future<void> remove(String key);
}

/// 安全存储（当前由 flutter_secure_storage 承担）
abstract interface class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// 日志下沉（core 只产生日志事件，写文件/控制台由外部决定）
abstract interface class LogSink {
  void write(AppLogLevel level, String tag, String message,
      {Object? error, StackTrace? stackTrace});
}
```

两侧实现：

| 端口 | Flutter App 侧实现 | CLI / 测试侧实现 |
|---|---|---|
| `PathProvider` | `path_provider` 包 | `Directory.systemTemp` 或 CLI `--data-dir` 参数 |
| `KeyValueStore` | `shared_preferences` | JSON 文件 / 内存 Map |
| `SecretStore` | `flutter_secure_storage` | 明文 JSON 文件（**仅测试**，需显式告警）或环境变量 |
| `LogSink` | 现有三路输出（console/ring/file） | stdout |
| `DatabaseFactory` | `databaseFactoryFfi`（桌面）/ sqflite（移动） | `databaseFactoryFfi` |

> 注：`DatabaseFactory` 不需要自己定义接口，直接用 `sqflite_common` 提供的即可——它本来就是纯 Dart 的抽象。

---

## 4. 推荐实施路线

分 4 阶段，**每阶段独立可交付、可回滚、不破坏现有功能**。前两阶段就能拿到 80% 的收益。

### 阶段 0：一行修复（10 分钟，零风险）

```dart
// lib/data/database_handler.dart:25
- import 'package:flutter/foundation.dart' show visibleForTesting;
+ import 'package:meta/meta.dart' show visibleForTesting;
```

`visibleForTesting` 本就来自 `package:meta`，语义完全一致。改完 `flutter test` 应当全绿。

**配套改动（必须）：pubspec.yaml 的 `dependencies` 增加 `meta`**（锁文件中已解析为 1.18.0，直接声明即可）。原因：`flutter_lints` 6 启用的 `depend_on_referenced_packages`（来自 `lints/core.yaml`）要求被 import 的包必须是直接依赖——只换 import 不声明，`flutter analyze` 会报 lint。实验补丁没踩到它，是因为 `dart run`/`dart test` 不做 lint 检查（见 6.3 #4）。

开工前先 `git status` 确认基线：当前工作区存在与提取无关的未提交改动（`lib/sync/sync_engine.dart`、`test/sync/longrun_persistent_store_test.dart`），实施与回滚时避免混淆（见 6.4）。

### 阶段 1：解耦 app_logger（半天）—— 收益最大的一步

单独做完这一步，纯 Dart 文件数从 **5 → 15**（业务口径，不含 `app_logger.dart` 本身；含则 16，口径说明见收益表），直接解锁 `crypto.dart`、`journal.dart`、`sync_models.dart`、`safenote.dart`、`parse_import.dart`、`aes_encryption.dart`、三个 backend、`log_webserver.dart`，合计约 **5400 行**。这些文件当前都只通过 `app_logger.dart` 这一个 Flutter 污染入口，解耦后即可被 `dart run`/`dart test` 直接驱动。

两处改动：

1. **`kDebugMode` / `kReleaseMode`** → 编译期常量（已实测可行）：
   ```dart
   const bool kReleaseMode = bool.fromEnvironment('dart.vm.product');
   const bool kDebugMode = !kReleaseMode;
   ```
   ⚠️ 注意语义差异：Flutter 的 `kDebugMode` 在 profile 模式下为 `false`，而上式在 profile 下为 `true`。若项目在意 profile 模式，需补 `kProfileMode = bool.fromEnvironment('dart.vm.profile')` 并写成 `kDebugMode = !kReleaseMode && !kProfileMode`。

2. **`getApplicationSupportDirectory()`（`:344`）** → 改为可注入。最小侵入版本（已实测）：
   ```dart
   Future<String?> Function()? logDirResolverOverride;
   ```
   App 启动时在 `main.dart` 注入 `path_provider` 实现，CLI 注入临时目录。彻底版本则并入阶段 3 的 `PathProvider` 端口。

### 阶段 2：解耦 database_handler（1 天）

```dart
- import 'package:sqflite/sqflite.dart';
+ import 'package:sqflite_common/sqlite_api.dart';
```

`Database` / `Transaction` / `ConflictAlgorithm` / `DatabaseFactory` / `OpenDatabaseOptions` 全部由 `sqflite_common` 导出，类型完全兼容。

三处顶层函数调用改为注入的 factory（已实测）：

```dart
// :308 getDatabasesPath()  → 注入的 dbPath
// :312 openDatabase(...)   → factory.openDatabase(path, options: OpenDatabaseOptions(...))
// :1332/:1337              → 同上
```

App 侧在 `main.dart` 注入（桌面端逻辑 `main.dart:114-126` 已存在，直接复用）；CLI 侧注入 `databaseFactoryFfi`。

**移动端接线细节（复核补充）**：Android/iOS 上注入的 factory **必须来自 sqflite 插件**——插件注册时会把全局 `databaseFactory` 设为自身实现，直接注入 FFI factory 会在移动端报 `databaseFactory not initialized`。最省事的做法是 main.dart 统一注入全局 `databaseFactory`：桌面端启动时它已被换成 `databaseFactoryFfi`（main.dart:114-126），移动端由插件注册，**同一注入点、两套平台实现**，不引入分支。`dbPathOverride` 同理：桌面端传 `getApplicationSupportDirectory()` 的结果，移动端传 `getDatabasesPath()`。阶段 2 完成后必须在 Android/iOS 真机各跑一次登录 + 建库 + 读写回归（风险表已有该行）。

完成后 `keyring.dart`（908 行）与 `sync_engine.dart`（2488 行）全部转纯 Dart，**核心逻辑闭环打通**。

### 阶段 3：物理隔离到独立 package（2–3 天）

前两阶段是"逻辑上纯了"，但没有任何机制阻止将来有人再写一行 `import 'package:flutter/foundation.dart'` 把它污染回去。**阶段 3 用编译器把这个约束固化下来。**

目标结构（VGV 风格 + Dart pub workspaces）：

```
safenotes/
├── pubspec.yaml              # 根：workspace 声明 + Flutter app
├── lib/                      # Flutter UI（views/widgets/dialogs/utils 中的 UI 部分）
├── bin/
│   └── safenotes_cli.dart    # 纯 Dart CLI 入口
├── packages/
│   └── safenotes_core/
│       ├── pubspec.yaml      # ★ 没有 flutter: sdk: flutter ★
│       ├── lib/
│       │   ├── safenotes_core.dart      # 唯一公开出口
│       │   └── src/
│       │       ├── ports.dart           # PathProvider/KeyValueStore/SecretStore/LogSink
│       │       ├── crypto/              # ← lib/sync/crypto.dart, lib/encryption/
│       │       ├── models/              # ← lib/models/safenote.dart, parse_import.dart
│       │       ├── db/                  # ← lib/data/database_handler.dart
│       │       └── sync/                # ← lib/sync/（engine/keyring/journal/backends）
│       └── test/                        # ← test/sync/, test/encryption/（改 package:test）
└── test/                     # 仅剩 widget_test.dart 等 UI 测试
```

根 `pubspec.yaml` 增加：
```yaml
workspace:
  - packages/safenotes_core
dependencies:
  safenotes_core:
    path: packages/safenotes_core
```

`packages/safenotes_core/pubspec.yaml`：
```yaml
name: safenotes_core
publish_to: none
environment:
  sdk: ^3.12.0
resolution: workspace
dependencies:
  crypto: ^3.0.3
  cryptography: ^2.9.0
  http: ^1.1.0
  logger: ^2.1.0
  meta: ^1.15.0
  path: ^1.9.0
  pointycastle: ^4.0.0
  sqflite_common: ^2.5.11
  tuple: ^2.0.0
dev_dependencies:
  test: ^1.25.0
  sqflite_common_ffi: ^2.4.2
```

> 依赖清单说明（复核补充）：`tuple` 被 `lib/encryption/aes_encryption.dart` 使用；`logger` 被 `app_logger.dart` 的 `Level → AppLogLevel` 映射使用。核心文件实际用到的第三方包完整清单为：crypto / cryptography / http / logger / meta / path / pointycastle / sqflite_common / tuple（全部已存在于当前 `pubspec.lock`，约束兼容，无新增解析风险）。

> 迁移时用 `git mv` 保留文件历史。`lib/utils/app_logger.dart` 需要拆成两半：抽象部分（`AppLogLevel`、`AppLog`、`LogSink` 接口）进 core，文件/path_provider 落地部分留在 app。**拆分策略（复核补充）**：建议把 `Log` 门面（静态 API + 可注入的 `LogSink`）整体搬进 core，落地实现留在 app 侧注册——这样核心文件里大量 `Log.x.y(...)` 调用点**零改动**；若只搬抽象枚举和接口，就要逐文件改写所有日志调用点，工作量会被低估。

> 边界说明（复核补充）：`lib/sync/sync_config.dart`（依赖 `flutter_secure_storage`/`shared_preferences`）与 `lib/sync/sync_service.dart`（依赖 `path_provider`/`preference_and_config`/`device_id`）**不搬入 core**，留在 app 侧作为配置装配与接线层；core 包的 `analysis_options.yaml` 建议 include `package:lints/recommended.yaml`（纯 Dart 包不应依赖 `flutter_lints`）。

> 实施前先花 10 分钟验证 `flutter pub get` / `flutter test` 与 pub workspace 共存（Flutter 3.44 已支持，一次性验证成本极低；若遇工具链问题可退回阶段 2 + 目录级 lint 守卫方案，见第 7 节）。

### 阶段 4：CLI + 测试 runner 切换（1 天）

见第 5 节。

### 各阶段收益表

| 阶段 | 工作量 | 纯 Dart 文件数 | 核心逻辑可 CLI 驱动 | 边界由编译器强制 |
|---|---|---|---|---|
| 现状 | — | 5 / 77 | ❌ | ❌ |
| 阶段 0 | 10 分钟 | 5 | ❌ | ❌ |
| 阶段 1 | 半天 | 15 | 部分 | ❌ |
| 阶段 2 | 1 天 | 17（核心全覆盖）| ✅ | ❌ |
| 阶段 3 | 2–3 天 | 独立 package | ✅ | ✅ |
| 阶段 4 | 1 天 | — | ✅ | ✅ |

**若时间紧张，做到阶段 2 即可停。** 阶段 3 的价值是防腐化，属于长期投资。

> 计数口径：表中"纯 Dart 文件数"为**业务文件**计数，不含 `app_logger.dart`、`database_handler.dart` 两个基础设施文件（含则阶段 1 为 16、阶段 2 为 19）。阶段 1 解锁的 10 个文件约 5400 行；阶段 2 累计解锁约 **8950 行业务逻辑**（加上两个基础设施文件约 10900 行）——即"约 9000 行核心逻辑被 2 个文件卡住"的精确值。

---

## 5. 纯 Dart CLI 设计

### 5.1 定位

CLI **不是**给终端用户的产品，而是**核心逻辑的第二个前端**——用来做冒烟验证、混沌测试、同步互操作性验证、性能压测、故障现场复现。它的存在本身就是架构约束的守卫：CLI 一旦编译不过，说明有人往核心层塞了 Flutter 依赖。

### 5.2 入口与装配

```dart
// bin/safenotes_cli.dart
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:safenotes_core/safenotes_core.dart';

Future<void> main(List<String> args) async {
  sqfliteFfiInit();

  // 顶层装配（Composition Root）——所有平台差异只在这里出现
  final core = SafeNotesCore(
    dbFactory: databaseFactoryFfi,
    paths: CliPathProvider(dataDir: args.dataDir),
    kv: JsonFileKeyValueStore('${args.dataDir}/prefs.json'),
    secrets: EnvSecretStore(),          // 从环境变量读密码，避免落盘
    logSink: StdoutLogSink(verbose: args.verbose),
  );

  await runCommand(core, args);
}
```

> 这就是构造函数注入的价值：**没有容器、没有注册表、没有代码生成**。App 侧的 `main.dart` 做同样的事，只是换成 `path_provider` / `shared_preferences` / `flutter_secure_storage` 的实现。

### 5.3 建议的子命令

| 命令 | 用途 |
|---|---|
| `note add/list/get/rm` | 笔记 CRUD，验证字段级加密往返 |
| `db info` / `db verify` | schema 版本、行数、墓碑数、密文完整性校验 |
| `sync run --backend local\|webdav\|server` | 跑一次完整同步，打印每一步决策 |
| `sync inspect` | dump manifest / keyring / journal（脱敏） |
| `keyring rotate` | 改密码流程，验证重加密 |
| `import/export` | 备份文件的导入导出 |
| `chaos --clients N --rounds M` | 多客户端并发混沌测试（复用现有 `chaos_multi_client_test.dart` 逻辑） |

### 5.4 依赖建议

用 `package:args`（Dart 官方，纯 Dart）。**不要**引入 `mason` / `very_good_cli` 那套模板体系——本项目不需要。

### 5.5 测试 runner 切换

已实测：`test` 与 `flutter_test` 可以在同一个 `pubspec.yaml` 里共存（`flutter pub get` 成功，`Changed 18 dependencies`）。

改造量极小——16 个测试文件里**只有 `test/widget_test.dart` 真正用了 `testWidgets`**（逐文件核对：其余 15 个只用到 `test()` / `expect()` / `setUp()` / `setUpAll()` 等 `package:test` 同名 API），只需批量替换：

```
package:flutter_test/flutter_test.dart  →  package:test/test.dart
```

唯一的例外是 `test/sync/crypto_test.dart:10` 用了 `listEquals`，替换为 `package:collection` 的 `const ListEquality().equals(a, b)`，或直接改用 `expect(a, equals(b))`。

Makefile 相应调整：

```makefile
test:            # 全部
	dart test packages/safenotes_core/test && flutter test
test-core:       # 只跑核心，秒级反馈，CI 里不需要 Flutter SDK
	dart test packages/safenotes_core/test
```

> **额外收益：CI 提速。** 核心测试用 `dart test` 跑，不需要下载 Flutter SDK、不需要启动引擎，也能开 `-j` 并发。当前 `keyring_test.dart` 单文件 70 秒，全量约 12000 行测试的节省相当可观。

---

## 6. 实验记录（本次调研实测）

**方法**：备份 → 打补丁 → 运行 → 还原 → `git status` 校验。所有改动已完整回滚，工作区与实验前逐字节一致。

### 6.1 补丁内容（共 5 处 import 及其配套）

| 文件 | 改动 |
|---|---|
| `lib/utils/app_logger.dart:34` | 删除 `flutter/foundation` import，改用 `bool.fromEnvironment('dart.vm.product')` |
| `lib/utils/app_logger.dart:36` | 删除 `path_provider` import，`:344` 改为可注入的 `logDirResolverOverride` |
| `lib/data/database_handler.dart:25` | `flutter/foundation` → `meta/meta` |
| `lib/data/database_handler.dart:27` | `sqflite/sqflite` → `sqflite_common/sqlite_api` |
| `lib/data/database_handler.dart:308,312,1332,1337` | 顶层 `getDatabasesPath()`/`openDatabase()`/`databaseFactory` → 注入的 `dbFactoryOverride` / `dbPathOverride` |
| `pubspec.yaml` | dev_dependencies 增加 `test: ^1.25.0` |

> 注：实验补丁**没有**给 pubspec 增加 `meta` 声明——`dart run`/`dart test` 不做 lint 检查，实验因此照常通过；正式实施阶段 0 时必须补上（见 6.3 #4）。

### 6.2 运行结果

```
$ dart run .tmp_probe_core.dart
DB OK -> saved=a0441ce6 count=1 title=纯Dart标题 desc=纯Dart正文
ENCRYPTED-AT-REST OK -> true (raw=mJy0BXiadDqP7rh9KSoxvyUd…)
CLASSES OK -> SyncEngine Keyring Journal LocalFsBackend WebDavBackend SyncCrypto
```

```
$ dart test .tmp_dt/sync/keyring_test.dart
01:10 +28: All tests passed!
```

（`keyring_test.dart` 除了把 `flutter_test` 换成 `test` 之外**未作任何修改**，28 个用例含 KeyringLedger 持久化、dataKey 迁移、多设备场景，全部通过。）

### 6.3 踩到的坑（实施时会遇到）

1. **Dart 语法**：`import` 必须在所有声明之前。把 `const kReleaseMode = ...` 插在 import 中间会报 `Directives must appear before any declarations`。
2. **`dart pub add --dev test` 在本项目会失败**，报 `Unable to resolve package "test" with the given git parameters`（疑似与 `safenotes_nord_theme` 的 git 依赖有关）。**绕过方法：手动编辑 `pubspec.yaml` 后跑 `flutter pub get`**，可以正常解析。
3. `sqflite_common` 的 `DatabaseFactory.openDatabase` 签名与顶层 `openDatabase` 不同——参数要包进 `OpenDatabaseOptions(...)`。
4. **只换 `meta` import 不声明依赖会触发 lint**：`flutter_lints` 6 启用的 `depend_on_referenced_packages`（来自 `lints/core.yaml`）要求被 import 的包必须是直接依赖。实验没踩到是因为没跑 `flutter analyze`；阶段 0 的正式补丁必须在 pubspec 声明 `meta`。
5. **移动端 factory 接线**：注入的 factory 在 Android/iOS 上必须取 sqflite 插件的实现（全局 `databaseFactory` 由插件注册），注入 FFI factory 会在移动端报 `databaseFactory not initialized`。接线方式见阶段 2。

### 6.4 独立复核记录（2026-08-02，只读静态复核，未重跑实验）

对本文档做了独立复核（import 传递闭包脚本 + `package_config.json`/pubspec 解析），结论：**现状诊断与实验结论可信**，以下为核对结果与修正项。

核对一致（与文档原值完全吻合）：
- 污染统计：直接 import `flutter/*`/`dart:ui` 48/77、直接 import Flutter 依赖包 51/77、传递闭包 72/77、当前纯 Dart 5/77。
- 行数：`database_handler=1348`、`sync_engine=2488`、`keyring=908`；`lib/sync+data+encryption` 合计 11625 行（"约 11600"成立）；阶段 2 解锁的业务文件合计约 8950 行（"约 9000"成立）。
- 环境与依赖：Dart 3.12.2 / Flutter 3.44.8 stable 与本机一致；`sqflite` 2.4.3 确认 re-export `sqflite_common` 的 `sqlite_api.dart` 与门面函数；`main.dart:114-126` 桌面 FFI 初始化逻辑存在；`visibleForTesting` 确为 `package:meta` 转出。
- 测试：仅 `widget_test.dart` 使用 `testWidgets`；`crypto_test.dart:10` 为 `listEquals`（来自 `flutter/foundation`）；10 个测试文件已写 `sqfliteFfiInit()`。

本次修正项（已并入正文）：
1. 测试文件计数 17 → **16**（含 `sync_test_support.dart`，合计约 12000 行）；写 `sqfliteFfiInit` 的 11 → **10**。
2. 阶段 0 补充 pubspec 声明 `meta`（`depend_on_referenced_packages` lint，见 6.3 #4）。
3. 阶段 3 的 core pubspec 补 `tuple`、`logger`（见 4·阶段 3）。
4. 阶段 2 补充移动端 factory 接线方式（见 4·阶段 2）。
5. 阶段 3 明确 `app_logger` 拆分策略：`Log` 门面整体进 core，调用点零改动（见 4·阶段 3）。
6. 计数口径说明："15/17 个纯 Dart 文件"为业务口径，不含 `app_logger`/`database_handler`（含则 16/19），见收益表。
7. 发现 `cryptography_flutter` 无真实 import（仅注释），核心加密栈当前即纯 `cryptography`。

复核范围说明：复核为只读静态分析，未重跑 `dart run`/`dart test` 实验；实验所需的全部前提（imports、依赖树、测试结构、版本）均已独立验证，与实验日志（28/28 通过、落盘为密文）一致。

实施基线提醒：复核时工作区存在与提取无关的未提交改动（`lib/sync/sync_engine.dart`、`test/sync/longrun_persistent_store_test.dart`），实施前先 `git status` 确认基线。

---

## 7. 风险与防腐

| 风险 | 缓解 |
|---|---|
| `kDebugMode` 语义在 profile 模式下与 Flutter 不一致 | 见阶段 1 的注意事项，补 `kProfileMode` |
| 大范围移动文件导致 git 历史断裂 | 用 `git mv`；分阶段小步提交，每步跑全量测试 |
| 移动端 sqflite 与 `sqflite_common` 行为差异 / 误注入 FFI factory | `sqflite` 本就是 `sqflite_common` 的实现，类型与语义一致；接线上 Android/iOS 必须注入 sqflite 插件工厂（全局 `databaseFactory` 由插件注册，main.dart 统一注入即可，见阶段 2）；阶段 2 后必须在真机跑一次回归 |
| 阶段 0 忘记声明 `meta` | `flutter analyze` 报 `depend_on_referenced_packages`（flutter_lints 6 启用）；阶段 0 必须同步改 pubspec（见 6.3 #4） |
| 将来有人重新引入 Flutter 依赖 | 阶段 3 的独立 package 由编译器强制；若暂不做阶段 3，在 `analysis_options.yaml` 里对核心目录加自定义 lint |
| CLI 的 `SecretStore` 明文落盘 | CLI 默认从环境变量读；文件实现必须打印显式告警，且**禁止**在 App 侧注册 |
| 单一 `pubspec.lock` 导致依赖冲突 | 这是 pub workspaces 的**设计意图**（官方原文：*"forces you to resolve incompatibilities between your packages when they arise"*），属于好事 |

---

## 8. 一句话总结

SafeNotes 的核心逻辑**在架构上已经准备好了**——`SyncBackend` 抽象干净、`SyncEngine` 是构造函数注入、测试早就跑在纯 Dart SQLite 上。挡路的不是架构，是 `app_logger.dart` 和 `database_handler.dart` 里的 **5 行 import**（配套的 pubspec 声明与接线见第 4 节）。先花半天做掉阶段 0+1+2 拿到全部实用价值，再视情况用阶段 3 的独立 package 把边界永久固化。**不需要引入 DI 框架，不需要 Clean Architecture 全套。**（本文档已按 2026-08-02 独立复核意见修正，修正项见 6.4。）

---

## 参考资料

- [Layered Architecture — VGV Engineering](https://engineering.verygood.ventures/development/architecture/architecture/)
- [Guide to app architecture — Flutter 官方](https://docs.flutter.dev/app-architecture/guide)
- [Pub workspaces (monorepo support) — Dart 官方](https://dart.dev/tools/pub/workspaces)
- [sqflite_common_ffi — pub.dev](https://pub.dev/packages/sqflite_common_ffi)
- 项目内已有相关文档：`docs/integration-test-research-20260802.md`（integration_test 路线，与本报告互补）、`docs/refact-architecture-design-20260801.md`
