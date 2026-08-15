# Widget 测试可测性改造设计（Ports & Adapters + Provider DI）

> 文档状态：设计稿（仅方案，不含代码改动）
> 适用版本：safenotes 3.0.0 / Flutter ≥3.44 / Dart ≥3.12
> 关联文档：`docs/tests-overview.md`、`docs/integration-test-plan.md`、`docs/DEVELOPMENT.md`
> 模块边界：`packages/core` 是**本项目的一部分**，只是被模块化为纯 Dart 包（供 CLI 与
> 独立测试复用）。core **可以自由修改、重构**，唯一硬约束是不引入 Flutter 依赖（见
> `CLAUDE.md`，由 workspace 编译器强制）——这是保持纯 Dart 的技术边界，**不是「禁止改动 core」**。
> 修订说明：本稿已按真实代码校准 §4 各接口签名（`NotesDatabase` / `PreferencesStorage` /
> `SyncService` 的公开 API），并修正了初稿中与代码不符的接口草案与事实性错误。

---

## 0. 背景与目标

当前 `test/` 下的 widget / 集成测试写起来很重：为了 `pumpWidget(App(...))` 启动真实 UI，
每个测试文件都得先重建一整套运行环境——加密实现、内存 SQLite、安全存储通道、
i18n 资源、会话超时——集中体现在 `test/test_helpers.dart`（22KB）。

`test/export_backup_dialog_test.dart` 还**独立复制了一份** `_TestAssetLoader`，
说明这套环境搭建逻辑并未真正复用，正在腐化。

**目标**：让「一个 widget 的测试」只提供它真正用到的 1–2 个测试替身（fake / mock），
而不必启动整个 App、不必 mock 任何平台通道、不必手写加密替身。

**非目标**：

- 不优先重构 `packages/core`（其纯 Dart 测试已足够好，见 `docs/tests-overview.md` 第 1 节）。
  强调：core 是本项目的一部分，只是模块化为纯 Dart 包，**没有任何「不能改」的限制**；唯一
  技术边界是不引入 Flutter 依赖（`CLAUDE.md`）。需要注入纯 Dart 依赖（如 `Cryptography`）时，
  直接在 core 加参数即可。
- 不要求更换状态管理框架（继续用 `provider`，它本来就是 DI 容器）。
- 不追求 100% 覆盖率，先消除「写测试成本高」的结构性阻力。

---

## 1. 现状诊断（基于真实代码的证据）

### 1.1 根因：UI 直接依赖「全局单例 + 平台插件 + 静态全局状态」

UI 层（widget / view / dialog）不是通过构造函数或 `Provider` 拿到依赖，而是直接访问
全局可变的静态入口。下列统计来自 `lib/` 目录（`grep` 计数，2026-08-15，已复核）：

| 全局入口 | 形态 | 引用规模 | 测试里如何被 hack |
|---|---|---|---|
| `SyncService.instance` | 单例（`lib/sync/sync_service.dart:98`） | **50** 处 | 无法替换，UI 测试被迫走真实同步路径或依赖其默认态 |
| `NotesDatabase.instance` | 单例（`package:core`，`database_handler.dart:103`） | **38** 处 | `setDatabaseForTesting` + 真实内存 SQLite + 真实 `Keyring` |
| `PreferencesStorage.xxx` | 静态类（`lib/data/preference_and_config.dart`，~50 个静态方法） | **24** 个文件 | `SharedPreferences.setMockInitialValues` + 每用例手动清理 |
| `AppBootState.vaultInitialized` | `static bool?`（`lib/authwall.dart:35`） | 启动流关键分支 | 测试里直接赋值 |
| `Cryptography.instance` | 进程全局（`package:cryptography`） | **lib 0 / test 1**，但被 core 通过工厂构造器**间接读取**（见 §1.4） | 手写 `_TestArgon2id` / `_TestAesGcm` 替身（见 §1.3） |
| `SyncConfig.isXxx` | 静态（`lib/sync/sync_config.dart`） | 大量 | 真实 `SharedPreferences` 驱动 |
| `Session` | 全静态（`lib/models/session.dart`） | — | 见 §4.7，尚未收敛 |
| `NoteEditorState` | 全静态（`lib/models/editor_state.dart`） | — | 见 §4.7，尚未收敛 |
| `ScheduledTask` / `BiometricAuth` | 全静态（`scheduled_task.dart` / `biometric_auth.dart`） | — | 见 §4.7，尚未收敛 |
| `PhraseHandler` / `ImportEncryptionControl` | 静态内存态（`preference_and_config.dart`） | — | 测试需手动 init/destroy |
| `DeviceIdProvider.instance` | 单例 | `sync_service.dart` | 已有 `overrideForTesting` 注入点（**良好先例**） |
| `AppLogFile` / `LogWebServer.instance` / `AppLogBuffer.instance` | 日志单例 | `sync_service.dart` | `LogWebServer.enableWebServer = false` |
| `devModeProvider` / `logDirResolverOverride` | 进程全局函数变量（`core` logger） | `main.dart` | 见 §4.7 |

**结论**：测试的「mock 负担」与全局耦合点数量成正比。只要 UI 仍直接读这些全局，
每个测试就得把它们全部摆平。

### 1.2 平台插件散布（widget 直接 import，无中间层）

| 插件 | 直接引用的 `lib/` 文件数 | 典型用途 |
|---|---|---|
| `local_session_timeout` | 11 | `main.dart` 会话超时、`App` 路由 |
| `path_provider` | 6 | 日志目录、备份目录、journal 目录 |
| `file_picker` | 4 | 备份导入/导出选路径 |
| `flutter_secure_storage` | 2 | keyring 密文、凭据（`BiometricAuth` 也直接用） |
| `local_auth` | 2 | 生物识别解锁 |
| `device_info_plus` | 2 | 设备 ID（`DeviceIdProvider`） |
| `url_launcher` | 2 | 反馈/开源链接 |
| `media_scanner` | 2 | 备份后刷新相册 |
| `permission_handler` | 1 | 存储权限 |
| `shared_preferences` | 2 | `PreferencesStorage` 底层 |

这些插件多数走 `MethodChannel`，在 `flutter test` 下未注册 → `MissingPluginException`，
所以 `test_helpers.dart` 必须 `_setupSecureStorageMock()` + 标题栏通道 mock。

### 1.3 `test_helpers.dart` 当前为「启动 App」付出的代价（真实存在的代码）

- 手写 `_TestArgon2id` / `_TestAesGcm`（`test_helpers.dart:68-198`）：因为 `cryptography`
  的 `Argon2id` 在 `flutter test` 子进程里 `spawn isolate` 会**永久挂起**，被迫用纯 Dart
  XOR 流密码替身。这是环境 workaround，不是业务需求。
- `_TestAssetLoader`（`test_helpers.dart:297-316`）：`easy_localization` 的 JSON 在
  `flutter test` 下走 `dart:io` 会挂起，改用 `rootBundle.loadString`。
- `_setupSecureStorageMock()` + 标题栏通道（`test_helpers.dart:318-362`）。
- `prepareUnlockedVault` / `prepareEmptyVault`（`test_helpers.dart:399-441`）：
  用**真实** `Keyring.createNew` + 真实内存 SQLite 造库——耦合了加密与 DB 两层的正确性。
- `pumpApp` / `settle`（`test_helpers.dart:460-488`）：因登录页按 `viewInsets.bottom`
  做「软键盘显隐滚动动画」，`pumpAndSettle` 永不收敛，被迫手写 14 段 `pump` 循环。

> 这些代价**每一行都不是业务断言**，纯粹是为了「让 App 在测试进程里能起来」。
> 本方案的衡量标准就是：把这些都删掉，测试还能跑。

### 1.4 关键事实：`Cryptography.instance` 的注入缝在 core，不在 app

`lib/` 层**没有**任何一处直接读写 `Cryptography.instance`（实测 lib 0 / test 1）。
真正消费它的是 `packages/core/src/crypto/crypto.dart`：`Argon2id(...)` / `AesGcm.with256bits()`
等**工厂构造器**在内部读取进程全局 `Cryptography.instance`。

**推论**：app 层无法通过「注入一个 `CryptoProvider`」来拦截 core 的密码学实现——真正的
注入缝在 core。由于 core **可以改**（唯一技术边界是不引入 Flutter 依赖，而 `cryptography`
是纯 Dart 包、core 已依赖），有两条等价方案，详见 §4.5：
- **A（推荐，显式注入）**：给 core 的 `SyncCrypto` / `Keyring` 增加 `Cryptography` 参数
  （默认 `Cryptography.instance`），测试传 `FakeCryptography()`。
- **B（零改动兜底）**：保留进程全局 `Cryptography.instance = Fake()` 替换（当前
  test_helpers 已在这么做）。

---

## 2. 设计原则

1. **Ports & Adapters（端口与适配器）**：在「UI 边界」上只暴露**抽象接口（port）**；
   真实实现（adapter，包住现有的 `core` / 插件）与测试替身（fake / mock）都实现同一接口。
2. **依赖从 widget 树注入，不从全局读**：所有 port 通过 `MultiProvider` 在 `App`（或测试
   `pumpWidget` 根）注册；widget 用 `Provider.of<T>` / `context.watch<T>` 取，不再碰单例。
3. **core 是模块化边界，不是禁区**：`packages/core` 可自由修改，唯一硬约束是保持纯 Dart
   （不引入 Flutter 依赖，供 CLI 与独立测试复用）。接口定义放 `lib/`（app 层）是本方案的
   **选择**（部分 port 含 Flutter 类型，如 `ThemeMode`），并非「core 不能放接口」；纯 Dart
   接口同样可放 core。真实 adapter `import 'package:core/core.dart'` 完全允许。
4. **测试替身与业务解耦**：fake 是「内存数据 + 可控状态」；mock（用 `mocktail`）用于验证
   调用行为。两者都不触发 isolate / 文件 I/O / MethodChannel。
5. **渐进式、可回退**：每个 port 改造独立成 PR。旧的静态全局入口先保留为「**转发桥**」——
   静态方法委托给一个进程级持有的 repository 实例（bootstrap 时注入），而非保留第二份逻辑。
   这样迁移期间不存在「部分 widget 读静态、部分读 provider」的双事实源，也不会读脏。
   桥接机制直接复用 `DeviceIdProvider.overrideForTesting` 的既有先例（见 §4.1 代码示例）。
6. **port 必须可被 `watch`**：任何会被 UI `context.watch<T>()` 订阅的 port，其实现类必须
   是 `ChangeNotifier`（或提供独立 `Listenable`），setter 改动后调用 `notifyListeners()`。

---

## 3. 目标架构

```
┌──────────────────────────────────────────────────────────┐
│  UI 层 (widget / view / dialog)                            │
│  只认接口，不认单例：                                       │
│   context.watch<NotesRepository>()                         │
│   context.watch<PreferencesRepository>()                  │
│   context.watch<SessionProvider>()   // 替代 AppBootState  │
│   context.watch<SyncServicePort>()   // 替代 SyncService.instance │
│   context.watch<BiometricPort>()      // 替代 BiometricAuth │
└───────────────┬──────────────────────────────────────────┘
                │ Provider 注入
┌───────────────▼──────────────────────────────────────────┐
│  App 层 ports (lib/di/ 或 lib/services/)                  │
│   abstract class NotesRepository        (extends ChangeNotifier 视需) │
│   abstract class NotesDbAdminPort       (DB 检查器/备份/逃生通道)      │
│   abstract class PreferencesRepository  (extends ChangeNotifier)      │
│   abstract class SecureStoragePort / BiometricPort / DeviceInfoPort / … │
│   abstract class SyncServicePort  (SyncService 实现之)    │
│   class SessionProvider extends ChangeNotifier  (含会话密码) │
└───────────────┬──────────────────────────────────────────┘
        ┌───────┴────────┬───────────────┬───────────────┐
        ▼                ▼                ▼               ▼
   真实 adapter     真实 adapter      真实 adapter      (无 Flutter 依赖)
   包 NotesDatabase 包 SharedPreferences 包各平台插件    core 纯 Dart
   (来自 core)      (+ secure storage)                 同步引擎
```

**关于加密替身**：`Cryptography` 不在上图（UI 从不直接接触密码学）。普通 widget 测试注入
fake 后**根本不碰密码学**；仅少数集成测试需要真实加密路径，此时用 §4.5 的两种方案之一
（core 加 `Cryptography` 参数注入 / 进程全局替换）隔离。

**装配点**：
- 生产：`lib/app.dart` 的 `MultiProvider` 注册所有真实 adapter（构造参数从 `main._bootstrap`
  已初始化好的实例传入）。
- 测试：`test` harness 的 `withProviders(widget, overrides: [...])` 注册 fake。

---

## 4. 具体改造项（按模块）

> 每项给出：现状 → 目标 → 影响面 → 测试收益。类名与接口签名均已对照真实代码校准。

### 4.1 `PreferencesStorage` → `PreferencesRepository` 接口

- **现状**：`lib/data/preference_and_config.dart` 是 ~50 个静态方法的巨型类，被 24 个文件
  直接读写（含 `ThemeProvider` 构造里 `PreferencesStorage.isThemeDark`、`home.dart` 里
  `PreferencesStorage.isNewFirst`）。`isThemeDark` 内部还直接读
  `WidgetsBinding.instance.platformDispatcher.platformBrightness`（平台耦合）。
- **目标**：把持久化的 getter/setter 1:1 映射为实例接口，**并让实现类可被 `watch`**：
  ```dart
  abstract class PreferencesRepository extends ChangeNotifier {
    bool get isThemeDark;          // 注意：不是 themeMode，themeMode 由 ThemeProvider 派生
    bool get isSystemDarkLightSwitchEnabled;
    int  get themeGroupIndex;
    int  get themeColorIndex;
    bool get isGridView;
    bool get isNewFirst;
    bool get isColorful;
    bool get isMarkdownEnabled;
    bool get isCompactPreview;
    bool get isRelativeTime;
    bool get isSortByModified;
    int  get inactivityTimeout;
    bool get isInactivityTimeoutOn;
    bool get isBiometricAuthEnabled;
    bool get isBackupOn;
    bool get isDevMode;
    // …其余开关/数值 1:1 映射现有 getter（见 preference_and_config.dart 全量清单）
    Future<void> setThemeColorIndex(int i);
    Future<void> setThemeGroupIndex(int i);
    Future<void> setIsGridView(bool v);
    Future<void> setIsThemeDark(bool v);
    // …setter 同样 1:1
  }

  class SharedPreferencesPreferencesRepository extends PreferencesRepository {
    // 内部仍用 SharedPreferences，但由构造注入而非静态 _preferences；
    // 每个 setter 落盘后调用 notifyListeners()。
  }
  class FakePreferencesRepository extends PreferencesRepository {
    // 内存字段 + 可选 seed 构造参数；setter 直接改字段 + notifyListeners()。
  }
  ```
- **桥接（迁移期）**：保留 `PreferencesStorage` 静态类，其方法改为**转发**到进程级实例：
  ```dart
  // 与 DeviceIdProvider.overrideForTesting 同款先例
  class PreferencesStorage {
    static PreferencesRepository _repo = SharedPreferencesPreferencesRepository();
    @visibleForTesting
    static set instance(PreferencesRepository r) => _repo = r;
    static bool get isGridView => _repo.isGridView;
    static Future<void> setIsGridView(bool v) => _repo.setIsGridView(v);
    // …其余静态方法一律转发，删除内部 _preferences 逻辑
  }
  ```
  迁移完成后，逐个把静态调用点换成 `context.watch<PreferencesRepository>()`，最后删掉
  静态桥。
- **影响面**：`ThemeProvider`、`NotesColor`、各 settings view、`home.dart` 等改用
  `context.watch<PreferencesRepository>()`。`ThemeProvider.themeMode` 仍由
  `isThemeDark` 派生，不新增 `themeMode` 持久化字段。
- **测试收益**：`theme_color_setting_test` 删掉 `SharedPreferences.setMockInitialValues`
  + `prepareProviders` 前置清理，改成 `Provider<PreferencesRepository>.value(
  FakePreferencesRepository(seedGroup: 1, seedColor: 0))`。

### 4.2 `NotesDatabase.instance` → `NotesRepository`（+ 窄 `NotesDbAdminPort`）

- **现状**：`NotesDatabase` 定义在 `package:core`，是单例，`lib/` 内 38 处直接
  `NotesDatabase.instance`。测试靠 `setDatabaseForTesting` + 真实内存 SQLite。
- **重要区分**：`NotesDatabase` 的公开方法**并非都属「笔记领域 CRUD」**。按 `lib/` 实际
  调用点（已 grep 统计）分成两类：
  - **领域 CRUD（列表/编辑/回收站用）** → 归入 `NotesRepository`。
  - **原始 DB 句柄 + 检查器 + 导出/删库/逃生通道**（`database` / `queryTableRows` /
    `inspectMetadata` / `exportAll` / `deleteDbFile` / `dbFilePath`）→ 归入窄
    `NotesDbAdminPort`，只被 DB 检查器、备份、忘记密码三个屏使用。
  - **dataKey 注入/清除**（`setDataKey` / `clearDataKey` / `isEncryptionEnabled`）→ 属
    keyring 生命周期，随 §4.7 收敛进 `SessionProvider`，不放进 `NotesRepository`。
- **目标**（接口签名与真实 `NotesDatabase` 一致，**无臆造方法**）：
  ```dart
  abstract class NotesRepository {
    Future<List<SafeNote>> readAllNotes();
    Future<List<SafeNote>> readDeletedNotes();
    Future<List<SafeNote>> readUnsyncedNotes();
    Future<List<SafeNote>> readAllNotesIncludingDeleted();
    Future<SafeNote> readNote(int id);
    Future<SafeNote?> readNoteByUuid(String uuid);
    Future<SafeNote> storeNote(SafeNote note);            // 返回入库后的 SafeNote
    Future<int> storeNotesInTransaction(List<SafeNote> notes);
    Future<int> updateNote(SafeNote note);
    Future<int> updateNoteByUuid(SafeNote note);
    Future<int> softDelete(int id);
    Future<int> hardDelete(int id);
    Future<int> hardDeleteByUuid(String uuid);
    Future<int> hardDeleteAllDeleted();
    Future<int> restoreNote(int id);
    // 注意：本接口**不含** watchNotes()/Stream。当前 UI 用 refreshNotes() 轮询，
    // 不是响应式流；若日后要引入响应式列表，属于新增特性，另行立项，不混入本重构。
  }
  class SqliteNotesRepository implements NotesRepository {
    SqliteNotesRepository(NotesDatabase db); // db 由装配点注入（而非单例）
  }
  class FakeNotesRepository implements NotesRepository {
    final Map<String, SafeNote> _store = {}; // 内存，按 uuid 索引，自增 id
  }

  abstract class NotesDbAdminPort {  // 仅 DB 检查器 / 备份 / 忘记密码屏使用
    Future<Database> get database;
    Future<List<Map<String, dynamic>>> queryTableRows(String table, {int? limit});
    Future<Map<String, dynamic>> inspectMetadata();
    Future<String> exportAll();
    Future<void> deleteDbFile();
    String? get dbFilePath;
  }
  ```
- **约束遵守**：接口与真实 adapter 都在 `lib/`，adapter `import 'package:core/core.dart'`
  完全允许（core 可自由修改，唯一技术边界是保持纯 Dart、不引入 Flutter 依赖）。
- **测试收益**：列表/网格/编辑器 widget 测试只需 `FakeNotesRepository(seed: [n1, n2])`，
  **完全不碰 `Keyring` / 加密 / SQLite**。DB 检查器/备份屏用 `FakeNotesDbAdminPort`。

### 4.3 `SyncService.instance` → `SyncServicePort` 接口 + 可注入实例

- **现状**：`lib/sync/sync_service.dart` 是单例（`:98`），50 处引用，内部直接依赖
  `NotesDatabase.instance`、`SyncConfig`、`PhraseHandler`、`DeviceIdProvider.instance`、
  `AppLogFile`/`AppLogBuffer`。
- **目标**：
  - 把 `SyncService` 从单例改为**普通可构造类**（去掉 `static final instance` 与私有
    构造），依赖改构造注入。
  - 定义 port。**UI 真正消费的是「观察 + 触发」这一小面**（已 grep 统计）：`state` /
    `stateStream` / `autoSync` / `sync` 覆盖了 50 处引用里的 19 处，是测试替身的主战场；
    其余 `initBackend` / `initKeyringFromPassword` / `logout` / `updateKeyring` /
    `switchBackend` / `applyConfigToService` / 诊断类方法（`getDebugJson` / `getJournalDump`
    / `exportAllLogsAsText` 等）由登录/设置/诊断屏调用，也一并进 port，但迁移优先级靠后。
  ```dart
  abstract class SyncServicePort {
    SyncServiceState get state;
    Stream<SyncServiceState> get stateStream;
    void autoSync();
    Future<SyncResult?> sync();
    Future<SyncResult?> repairRemote();
    Future<void> logout();
    // …其余见 §4.3 全量清单（P4 拆分时逐条对照 sync_service.dart 补全）
  }
  class SyncService implements SyncServicePort { /* 现实现，去掉单例 */ }
  ```
  - 通过 `Provider<SyncServicePort>` 注入；UI 用 `context.watch` 监听 `stateStream`。
  - 内部对 `NotesDatabase` / `DeviceIdProvider` 的调用改为构造注入（`initialize` 已接受
    `database` 参数，是现成的注入缝）。
- **测试收益**：`home.dart` 同步状态按钮、同步诊断页等测试，注入
  `FakeSyncServicePort(state: SyncStatus.success)`，**不再触发真实网络/后端/journal**。
- **注意**：`SyncService` 体量很大（1300+ 行），此项**风险最高、收益也最高**，
  放在 Phase 4 单独成 PR，且保留 `SyncService.instance` 桥接一段时间（转发到进程级实例，
  与 §4.1 桥接同款）。

### 4.4 `AppBootState.vaultInitialized` → `SessionProvider`

- **现状**：`lib/authwall.dart:33-36` 的 `static bool? vaultInitialized`，在
  `main._bootstrap` 预查询后赋值，`AuthWall.build` 直接读它决定登录/设密码路由。
- **目标**：
  ```dart
  class SessionProvider extends ChangeNotifier {
    bool vaultInitialized = false;
    // 登录态、session stream、会话密码(PhraseHandler 归并)也可一并收敛，
    // 会话密码**绝不进日志**（沿用现有「只记录长度」红线）。
  }
  ```
  `AuthWall` 改为 `context.watch<SessionProvider>()`。测试里
  `Provider<SessionProvider>.value(SessionProvider()..vaultInitialized = true)` 即可走登录页。
- **测试收益**：无需再为 `AppBootState.vaultInitialized` 直接赋值；路由分支可独立测。

### 4.5 加密替身：正式化 + 集中，注入缝放 core（**不引入 app 层 `CryptoProvider`**）

- **现状**：`test_helpers.dart` 因 isolate 挂起，手写 `_TestArgon2id` / `_TestAesGcm` 并
  `Cryptography.instance = _TestCryptography()`。
- **关键事实**：`lib/` 从不直接接触密码学（§1.4），core 通过 `Argon2id(...)` /
  `AesGcm.with256bits()` 工厂构造器读取进程全局。所以 app 层不需要、也无法直接注入加密实现；
  注入缝在 core。由于 core **可以改**（技术边界仅限「不引入 Flutter 依赖」，`cryptography`
  是纯 Dart 包、core 已依赖），加密隔离有两种等价方案：
  - **方案 A（推荐，显式注入）**：给 core 的 `SyncCrypto` / `Keyring` 增加可选
    `Cryptography` 参数（默认 `Cryptography.instance`）。把 `_gcm = AesGcm.with256bits()`
    改为 `cryptography.aesGcm()`、`Argon2id(...)` / `Pbkdf2(...)` 改为
    `cryptography.argon2id(...)` / `cryptography.pbkdf2(...)`。测试在
    `Keyring.createNew(..., cryptography: FakeCryptography())` 传入替身，不再碰全局。
  - **方案 B（零改动兜底）**：保留 `Cryptography.instance = FakeCryptography()` 进程全局
    替换（`package:cryptography` 官方支持这种可写全局，已被现有测试证明可行）。
- **无论 A/B，测试替身本身都正式化**：把 `_TestCryptography` / `_TestArgon2id` /
  `_TestAesGcm` 从 test 文件**提升**为正式替身，放进 `test/support/fake_cryptography.dart`。
- **范围收窄**：这套替换只服务于「确需真实加密 + 真实 DB」的少数**集成测试**
  （登录/设密码主流程）。普通 widget 测试注入 fake 后**根本不触发密码学**，与它无关。
- **测试收益**：集成测试复用同一份、集中维护的加密替身；普通 widget 测试彻底绕开 isolate
  挂起与加密替身。
- **落地顺序**：先做方案 B（零改动，立刻见效）；core 为别的理由动到 `SyncCrypto`/`Keyring`
  时，再顺手升级为方案 A。

### 4.6 平台插件 → 各自 port（消灭 MethodChannel mock）

为每个在 widget 测试里会造成 `MissingPluginException` 的插件定义窄接口，并包一层 adapter：

| 插件 | 建议 port | 真实 adapter | 测试替身 |
|---|---|---|---|
| `flutter_secure_storage` | `SecureStoragePort` | 包插件 | `FakeSecureStorage`（内存 Map） |
| `local_auth` | `BiometricPort` | 包插件（吸收 `BiometricAuth` 静态类） | `FakeBiometric`（永远成功/可配置） |
| `device_info_plus` | `DeviceInfoPort` | 包 `DeviceIdProvider` | `FakeDeviceInfo`（固定 id） |
| `permission_handler` | `PermissionPort` | 包插件 | `FakePermission`（永远授予） |
| `path_provider` | `AppDirsPort` | 包 `getApplicationSupportDirectory` 等 | `FakeAppDirs`（临时内存路径） |
| `file_picker` | `FilePickerPort` | 包插件 | `FakeFilePicker`（返回固定路径） |
| `url_launcher` | `UrlLauncherPort` | 包插件 | `FakeUrlLauncher`（记录调用） |
| `media_scanner` | `MediaScannerPort` | 包插件 | `FakeMediaScanner`（no-op） |

- **依据**：`DeviceIdProvider` 已有 `overrideForTesting` 先例（见 `lib/utils/device_id.dart`），
  证明「为测试留注入点」是团队认可的做法，这里只是把它**统一成 port + provider** 模式。
- **注意**：`BiometricAuth` 内部直接 `FlutterSecureStorage()`，收敛 `BiometricPort` 时须一并
  把 secure storage 访问改走 `SecureStoragePort`，否则生物识别测试仍会踩
  `MissingPluginException`。
- **测试收益**：删除 `_setupSecureStorageMock()` 与标题栏通道 mock；插件相关 widget
  （生物识别解锁、备份导入导出）测试注入 fake 即可。

### 4.7 收敛静态内存态（不止 PhraseHandler，含全部遗漏的全局）

`lib/` 里除 `PhraseHandler` / `ImportEncryptionControl` / `ImportPassPhraseHandler` 外，还有
以下**初稿遗漏**的全局可变态，同样必须收敛，否则 HomePage/编辑器测试仍起不来：

| 全局 | 现状 | 处置 | Phase |
|---|---|---|---|
| `PhraseHandler`（会话密码） | 静态内存 | 归并入 `SessionProvider`，**绝不过日志** | P2 |
| `Session`（`login/logout/onPasswordSet`） | 全静态，内部再调 `SyncService`/`NotesDatabase`/`BiometricAuth`/`ScheduledTask` | 拆成 `SessionProvider` 实例方法，依赖改为注入 | P2 |
| `NoteEditorState`（`original/title/description/wasNoteSaveAttempted`） | 全静态 | 改为编辑器页面局部状态，或注入 `EditorState`（`ChangeNotifier`）；`addOrUpdateNote` 的 `SyncService.instance.autoSync()` 改注入 | P3 |
| `ScheduledTask.backup()` | 全静态 | 备份逻辑包进 `BackupPort`/`ScheduledTaskPort`，注入 | P3 |
| `BiometricAuth` | 全静态 + 直接 `FlutterSecureStorage()` | 收敛进 `BiometricPort`（§4.6） | P3 |
| `ImportEncryptionControl` / `ImportPassPhraseHandler` | 静态内存 | 随导入流程以参数/局部状态传递 | P3 |
| `devModeProvider` / `logDirResolverOverride`（core） | 进程全局函数变量 | 测试里置空/内存路径；生产由 `main` 注入不变 | P1 |

> 这些全局若不在方案内列出并排期，重构后 widget 测试依然会被它们卡住——这是初稿最大的遗漏。

---

## 5. 第三方库清单与取舍

| 库 | 版本策略 | 解决什么 | 必要性 |
|---|---|---|---|
| **mocktail** | 加 `dev_dependencies` | 类型安全 mock，**无需 `build_runner` 代码生成**。用于**行为 mock**：验证 `SyncServicePort` / `FilePickerPort` 等 port 的调用次数/参数 | **强烈建议**（注意：它**不**替代加密 fake，见下） |
| **clock** + **fake_async** | 加 `dev_dependencies` | 会话超时、自动锁屏、`timeago`、`local_session_timeout` 的确定性时间。注入 `Clock`（`DateTime.now()` 统一改为 `clock.now()`） | 建议（有相关测试时） |
| **network_image_mock** | 加 `dev_dependencies` | 含远程/同步图标的 widget 测试，省掉真实网络 | 按需（仅当 widget 真的加载远程图） |
| **golden_toolkit** / **alchemist** | 加 `dev_dependencies` | shadcn_ui + 主题切换非常适合视觉回归（`theme_color_setting_test` 当前靠逐像素断言，脆弱）。`alchemist` 支持设备变体 + 主题矩阵 | 建议（Phase 4） |
| **patrol** | 加 `dev_dependencies` | 集成测试更顺手的 API + 原生权限/弹窗处理，减少 `pumpApp` 手写 pump 循环 | 可选（集成测试多时） |
| ~~`easy_localization` 代码生成~~ | ~~`easy_localization_gen`~~ | ~~把翻译编成 Dart 常量~~ | **已移除**：`easy_localization_gen` 非官方团队维护，且现有 `_TestAssetLoader`（`rootBundle.loadString`）已可稳定工作，为此引入 build_runner 收益/风险比差。i18n 只做 §7 的「集中 loader」 |

> 澄清：mocktail 是**行为 mock**；`_TestArgon2id` / `_TestAesGcm` 是**fake**（要真的能加解密往返 +
> 校验 MAC），二者正交。加密 fake 必须手写并提升到 `test/support/`（§4.5），mocktail 管不了它。
>
> 状态管理**不换** `provider`；如需全局 DI 图再考虑 `get_it`+`injectable`，但会增加 churn，不优先。

---

## 6. 测试支撑层重设计

把现有 `test/test_helpers.dart` 拆成三层：

1. **`test/support/fakes.dart`**：所有 `FakeXxx`（内存实现，无 Flutter/插件依赖）。
2. **`test/support/fake_cryptography.dart`**：`FakeCryptography` / `FakeArgon2id` / `FakeAesGcm`
   （从 `_TestXxx` 提升，仅供集成测试）。
3. **`test/support/harness.dart`**：
   - `withProviders(Widget child, {List<Override> overrides = const []})`：
     包 `EasyLocalization` + `ShadApp` + `MultiProvider` + 默认一组 fake，允许按用例 override。
   - `initTestEnv()`（仅集成测试用，统一入口）。
   - **删除** `prepareUnlockedVault` / `prepareEmptyVault` / 手写加密替身对普通 widget 测试的依赖
     （这些只留给「确需真实加密+DB」的少数集成测试）。
4. **`test/support/clock_override.dart`**：封装 `withClock` / `FakeAsync` 辅助。

**键盘动画导致 `pumpAndSettle` 卡死**（真实问题，见 `test_helpers.dart:456-488` 注释）：
在 `withProviders` 里默认包一层
`MediaQuery(data: const MediaQueryData(viewInsets: EdgeInsets.zero), child: child)`，
让「软键盘显隐滚动动画」分支永不触发 → 登录/设密码页的 `pumpAndSettle` 自然收敛。

> **范围修正**：该 MediaQuery 修复只消除**登录/设密码页**的键盘滚动动画。`settle()` 还服务于
> **HomePage 的重复动画**（`test_helpers.dart:482` 注释自述），HomePage 仍需有限次 `pump`。
> 故 P1 验收**不得**写死「删掉 `settle()`」，只能写「登录/设密码页改用 `pumpAndSettle`」。

---

## 7. 两个「不重构也能立刻减负」的小修

即使暂不推进 §4，这两处可单独成 PR，立竿见影：

1. **集中 asset loader（低风险）**：把 `test_helpers.dart` 的 `_TestAssetLoader` 提到
   `test/support/`，并删除 `export_backup_dialog_test.dart:29-48` 的重复副本。
   i18n 的「根治」已从 §5 移除（codegen 收益/风险比差），集中 loader 即终态方案。
2. **MediaQuery 包裹**（见 §6）：一行包裹，消除登录/设密码流的 pump 循环。

---

## 8. 改造前后对照（用真实类示意）

### 8.1 改造前（`theme_color_setting_test.dart` 现状，节选）

```dart
setUpAll(() async { await initTestEnv(); });          // 启动整套环境
setUp(() async {
  SharedPreferences.setMockInitialValues({});          // 清 mock
  await PreferencesStorage.init();                     // 真实 SharedPreferences
  prepareProviders();                                 // 重建 ThemeProvider
});
// 还要在用例里手动 PreferencesStorage.setThemeGroupIndex(g) 预置持久化
```

### 8.2 改造后（示意，非提交代码）

```dart
void main() {
  testWidgets('Apply 后重进页面保持选中态', (tester) async {
    final fakePrefs = FakePreferencesRepository(
      themeGroupIndex: 1, themeColorIndex: 0,
    );
    await tester.pumpWidget(withProviders(
      const ThemeColorPicker(),
      overrides: [Provider<PreferencesRepository>.value(fakePrefs)],
    ));
    await tester.pumpAndSettle();
    expect(fakePrefs.themeGroupIndex, 1);             // 直接断言 fake，不碰 SharedPreferences
  });
}
```

### 8.3 列表类 widget（`home.dart` 依赖 `PreferencesStorage.isNewFirst` + `SyncService.instance`）

```dart
await tester.pumpWidget(withProviders(
  const HomePage(),
  overrides: [
    Provider<NotesRepository>.value(FakeNotesRepository(seed: [n1, n2])),
    Provider<SyncServicePort>.value(FakeSyncServicePort(state: SyncStatus.idle)),
    // isNewFirst / isGridView 等全部来自 FakePreferencesRepository 默认值
  ],
));
// 不再需要 prepareUnlockedVault / Cryptography.instance 替身 / 内存 SQLite
```

---

## 9. 落地路线图

| Phase | 内容 | 风险 | 预计工时 | 前置 |
|---|---|---|---|---|
| **P1** | §7 两个小修 + 引入 `mocktail` + 集中 `test/support/` + `devModeProvider`/`logDirResolverOverride` 测试处置 | 极低 | 0.5–1 天 | 无 |
| **P2** | §4.1 `PreferencesRepository`（含静态桥）+ §4.4 `SessionProvider` + §4.7 里 `PhraseHandler`/`Session` 归并 | 低（接口 1:1 映射） | 2–3 天 | P1 |
| **P3** | §4.2 `NotesRepository`（+`NotesDbAdminPort`）+ §4.5 crypto 替身提升 + §4.6 平台 port + §4.7 里 `NoteEditorState`/`ScheduledTask`/`BiometricAuth`/导入态收敛 | 中（接口须严格对照真实 API） | 4–6 天 | P2 |
| **P4** | §4.3 `SyncServicePort`（去单例）+ §5 golden/patrol | 高（1300+ 行单例） | 4–7 天 | P3 |
| ~~P5~~ | ~~`easy_localization` 代码生成~~ | — | — | 已移除 |

**每 Phase 验收**：`flutter analyze` + `flutter test` + `dart test packages/core/test` 全绿；
`test_helpers.dart` 体积逐 Phase 下降（目标最终 < 5KB，仅服务于少量真实集成测试）。
P1 的 `settle()` 收敛仅针对登录/设密码页（见 §6 范围修正）。

---

## 10. 风险与回退

- **P4 风险最高**：`SyncService` 单例被 50 处引用，去单例时容易漏改。
  缓解：保留 `SyncService.instance` 桥接（内部委托给进程级持有实例），分文件迁移，
  每 PR 保证测试全绿；出现回归时按文件 `git revert` 该 PR 即可。
- **接口漂移风险（P3）**：`NotesRepository` / `SyncServicePort` 必须**逐条对照真实公开签名**
  编写，禁止臆造方法（初稿曾臆造 `watchNotes()` / `deleteNote(uuid)` / `themeMode`）。
  缓解：每新增一个 port 前先 `grep` 该类的公开成员，并在接口注释里标注来源行号。
- **core 边界**：`packages/core` 是项目的一部分、可自由修改，唯一技术约束是不引入 Flutter
  依赖（保持纯 Dart，CI 的 workspace 编译器强制）。可在 core 加纯 Dart 参数注入（如
  `Cryptography`，§4.5）。加密替身先走「进程全局替换」兜底，需要时再升级为 core 参数注入。
- **`Cryptography` isolate 挂起**：确认 `FakeCryptography` 仅用于集成测试；生产路径保持真实
  `DartCryptography()`（经 `FlutterCryptography.enable()` 后走平台原生），密码学强度不受影响。
- **静态桥的双事实源风险**：§4.1/§4.3 的静态桥必须是「转发到进程级实例」而非「保留第二份
  逻辑」，否则迁移期会出现读脏。桥接实现一律沿用 `DeviceIdProvider.overrideForTesting` 先例。

---

## 附录 A：引用计数证据（2026-08-15，`lib/` 目录，已复核）

```
NotesDatabase.instance        : 38 处
PreferencesStorage. (文件数)  : 24 个文件
SyncService.instance          : 50 处
Cryptography.instance         : lib 0 / test 1（实际由 core 的 Argon2id()/AesGcm.with256bits()
                               工厂构造器间接读取，见 §1.4）
平台插件直接引用文件数：
  local_session_timeout : 11
  path_provider         : 6
  file_picker           : 4
  flutter_secure_storage: 2
  local_auth            : 2
  device_info_plus      : 2
  url_launcher          : 2
  media_scanner         : 2
  permission_handler    : 1
  shared_preferences    : 2
```

## 附录 B：与现有测试文档的关系

- 本方案不改动 `packages/core/test/`（纯 Dart 核心测试已足够好，见 `docs/tests-overview.md` §1）。
- 本方案重构 `test/` 下的应用层测试（§2.1–2.4 of `tests-overview.md`），并提供新的
  `test/support/` 支撑层替代 `test_helpers.dart`。
- 集成测试 `integration_test/app_test.dart` 仍可用现有 `initTestEnv` 真实路径，
  只在 Phase 4 后逐步迁移到 `withProviders` + fake。
