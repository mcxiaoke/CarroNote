# Widget 测试可测性改造设计（Ports & Adapters + Provider DI）

> 文档状态：设计稿（仅方案，不含代码改动）
> 适用版本：safenotes 3.0.0 / Flutter ≥3.44 / Dart ≥3.12
> 关联文档：`docs/tests-overview.md`、`docs/integration-test-plan.md`、`docs/DEVELOPMENT.md`
> 约束红线：见 `CLAUDE.md` —— `packages/core` **禁止引入任何 Flutter 依赖**。

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

- 不要求重构 `packages/core`（其纯 Dart 测试已足够好，见 `docs/tests-overview.md` 第 1 节）。
- 不要求更换状态管理框架（继续用 `provider`，它本来就是 DI 容器）。
- 不追求 100% 覆盖率，先消除「写测试成本高」的结构性阻力。

---

## 1. 现状诊断（基于真实代码的证据）

### 1.1 根因：UI 直接依赖「全局单例 + 平台插件 + 静态全局状态」

UI 层（widget / view / dialog）不是通过构造函数或 `Provider` 拿到依赖，而是直接访问
全局可变的静态入口。下列统计来自 `lib/` 目录（`grep` 计数，2026-08-15）：

| 全局入口 | 形态 | 引用规模 | 测试里如何被 hack |
|---|---|---|---|
| `SyncService.instance` | 单例（`lib/sync/sync_service.dart:98`） | **50** 处 | 无法替换，UI 测试被迫走真实同步路径或依赖其默认态 |
| `NotesDatabase.instance` | 单例（`package:core`） | **38** 处 | `setDatabaseForTesting` + 真实内存 SQLite + 真实 `Keyring` |
| `PreferencesStorage.xxx` | 静态类（`lib/data/preference_and_config.dart`，~50 个静态方法） | **24** 个文件 | `SharedPreferences.setMockInitialValues` + 每用例手动清理 |
| `AppBootState.vaultInitialized` | `static bool?`（`lib/authwall.dart:35`） | 启动流关键分支 | 测试里直接赋值 |
| `Cryptography.instance` | 全局赋值（`package:cryptography`） | lib 1 / test 1 | 手写 `_TestArgon2id` / `_TestAesGcm` 替身（见 §1.3） |
| `SyncConfig.isXxx` | 静态（`lib/sync/sync_config.dart`） | 大量 | 真实 `SharedPreferences` 驱动 |
| `PhraseHandler` / `ImportEncryptionControl` | 静态内存态（`preference_and_config.dart`） | — | 测试需手动 init/destroy |
| `DeviceIdProvider.instance` | 单例 | `sync_service.dart` | 已有 `overrideForTesting` 注入点（**良好先例**） |
| `AppLogFile` / `LogWebServer.instance` / `AppLogBuffer.instance` | 日志单例 | `sync_service.dart` | `LogWebServer.enableWebServer = false` |

**结论**：测试的「mock 负担」与全局耦合点数量成正比。只要 UI 仍直接读这些全局，
每个测试就得把它们全部摆平。

### 1.2 平台插件散布（widget 直接 import，无中间层）

| 插件 | 直接引用的 `lib/` 文件数 | 典型用途 |
|---|---|---|
| `local_session_timeout` | 11 | `main.dart` 会话超时、`App` 路由 |
| `path_provider` | 6 | 日志目录、备份目录、journal 目录 |
| `file_picker` | 4 | 备份导入/导出选路径 |
| `flutter_secure_storage` | 2 | keyring 密文、凭据 |
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

---

## 2. 设计原则

1. **Ports & Adapters（端口与适配器）**：在「UI 边界」上只暴露**抽象接口（port）**；
   真实实现（adapter，包住现有的 `core` / 插件）与测试替身（fake / mock）都实现同一接口。
2. **依赖从 widget 树注入，不从全局读**：所有 port 通过 `MultiProvider` 在 `App`（或测试
   `pumpWidget` 根）注册；widget 用 `Provider.of<T>` / `context.watch<T>` 取，不再碰单例。
3. **core 包零 Flutter 依赖**：接口定义放在 `lib/`（app 层），真实 adapter 里 `import
   'package:core/core.dart'` 是**允许**的（约束只禁止 core 反向依赖 Flutter）。
4. **测试替身与业务解耦**：fake 是「内存数据 + 可控状态」；mock（用 `mocktail`）用于验证
   调用行为。两者都不触发 isolate / 文件 I/O / MethodChannel。
5. **渐进式、可回退**：每个 port 改造独立成 PR，旧全局入口先保留为「默认 adapter 的桥接」，
   不一次性大改。

---

## 3. 目标架构

```
┌──────────────────────────────────────────────────────────┐
│  UI 层 (widget / view / dialog)                            │
│  只认接口，不认单例：                                       │
│   context.watch<NotesRepository>()                         │
│   context.watch<PreferencesRepository>()                  │
│   context.watch<SessionProvider>()   // 替代 AppBootState   │
│   context.watch<SyncServicePort>()   // 替代 SyncService.instance │
└───────────────┬──────────────────────────────────────────┘
                │ Provider 注入
┌───────────────▼──────────────────────────────────────────┐
│  App 层 ports (lib/di/ 或 lib/services/)                  │
│   abstract class NotesRepository                          │
│   abstract class PreferencesRepository                    │
│   abstract class SecureStoragePort                        │
│   abstract class BiometricPort / DeviceInfoPort / ...     │
│   abstract class SyncServicePort  (SyncService 实现之)    │
│   class SessionProvider extends ChangeNotifier            │
│   class CryptoProvider (封装 Cryptography.instance)       │
└───────────────┬──────────────────────────────────────────┘
        ┌───────┴────────┬───────────────┬───────────────┐
        ▼                ▼                ▼               ▼
   真实 adapter     真实 adapter      真实 adapter      (无 Flutter 依赖)
   包 NotesDatabase 包 SharedPreferences 包各平台插件    core 纯 Dart
   (来自 core)      (+ secure storage)                 同步引擎
```

**装配点**：
- 生产：`lib/app.dart` 的 `MultiProvider` 注册所有真实 adapter（构造参数从 `main._bootstrap`
  已初始化好的实例传入）。
- 测试：`test` harness 的 `withProviders(widget, overrides: [...])` 注册 fake。

---

## 4. 具体改造项（按模块）

> 每项给出：现状 → 目标 → 影响面 → 测试收益。类名均为真实存在。

### 4.1 `PreferencesStorage` → `PreferencesRepository` 接口

- **现状**：`lib/data/preference_and_config.dart` 是 ~50 个静态方法的巨型类，
  被 24 个文件直接读/写（含 `ThemeProvider` 构造里 `PreferencesStorage.isThemeDark`、
  `home.dart` 里 `PreferencesStorage.isNewFirst`）。`isThemeDark` 内部还直接读
  `WidgetsBinding.instance.platformDispatcher.platformBrightness`（平台耦合）。
- **目标**：
  ```dart
  abstract class PreferencesRepository {
    ThemeMode get themeMode;
    int get themeGroupIndex;
    int get themeColorIndex;
    bool get isGridView;
    bool get isNewFirst;
    // …其余开关/数值 1:1 映射现有 getter
    Future<void> setThemeColorIndex(int i);
    Future<void> setIsGridView(bool v);
    // …setter 同样 1:1
  }
  class SharedPreferencesPreferencesRepository implements PreferencesRepository {
    // 内部仍用 SharedPreferences，但由构造注入而非静态 _preferences
  }
  class FakePreferencesRepository implements PreferencesRepository {
    // 内存字段 + 可选 seed 构造参数
  }
  ```
- **影响面**：`ThemeProvider`、`NotesColor`、各 settings view、`home.dart` 等改用
  `context.watch<PreferencesRepository>()`。
- **测试收益**：`theme_color_setting_test` 删掉 `SharedPreferences.setMockInitialValues`
  + `prepareProviders` 前置清理，改成 `Provider<PreferencesRepository>.value(
  FakePreferencesRepository(seedGroup: 1, seedColor: 0))`。

### 4.2 `NotesDatabase.instance` → `NotesRepository` 接口

- **现状**：`NotesDatabase` 定义在 `package:core`（`core.dart` 导出），是单例，
  `lib/` 内 38 处直接 `NotesDatabase.instance`。测试靠 `setDatabaseForTesting` + 真实库。
- **目标**：
  ```dart
  abstract class NotesRepository {
    Future<List<SafeNote>> listNotes();
    Future<void> storeNote(SafeNote note);
    Future<void> deleteNote(String uuid);
    Stream<List<SafeNote>> watchNotes(); // UI 列表可直接 StreamBuilder
    // 加解密 dataKey 注入仍由 core 内部处理，不暴露密钥
  }
  class SqliteNotesRepository implements NotesRepository {
    SqliteNotesRepository(NotesDatabase db); // db 由装配点注入
  }
  class FakeNotesRepository implements NotesRepository {
    final List<SafeNote> _store = []; // 内存
  }
  ```
- **约束遵守**：接口与真实 adapter 都在 `lib/`，adapter `import 'package:core/core.dart'`
  不违反 core 无 Flutter 红线。
- **测试收益**：列表/网格类 widget 测试只需 `FakeNotesRepository(seed: [n1, n2])`，
  **完全不碰 `Keyring` / 加密 / SQLite**。

### 4.3 `SyncService.instance` → `SyncServicePort` 接口 + 可注入实例

- **现状**：`lib/sync/sync_service.dart` 是单例（`:98`），50 处引用，且内部直接依赖
  `NotesDatabase.instance`、`SyncConfig`、`PhraseHandler`、`DeviceIdProvider.instance`、
  `AppLogFile`/`AppLogBuffer`。
- **目标**：
  - 把 `SyncService` 从单例改为**普通可构造类**（去掉 `factory SyncService._()` 与
    `static instance`）。
  - 定义 `abstract class SyncServicePort { SyncServiceState get state;
    Stream<SyncServiceState> get stateStream; Future<SyncResult?> sync();
    void autoSync(); /* … */ }`，`SyncService implements SyncServicePort`。
  - 通过 `Provider<SyncServicePort>` 注入；UI 用 `context.watch` 监听 `stateStream`。
  - 内部对 `NotesDatabase` / `DeviceIdProvider` 的调用改为构造注入（或同样走 port）。
- **测试收益**：`home.dart` 同步状态按钮、同步诊断页等测试，注入
  `FakeSyncServicePort(state: SyncStatus.success)`，**不再触发真实网络/后端/jounal**。
- **注意**：`SyncService` 体量很大（1300+ 行），此项**风险最高、收益也最高**，
  放在 Phase 3 单独成 PR，且保留 `SyncService.instance` 桥接一段时间。

### 4.4 `AppBootState.vaultInitialized` → `SessionProvider`

- **现状**：`lib/authwall.dart:33-36` 的 `static bool? vaultInitialized`，在
  `main._bootstrap` 预查询后赋值，`AuthWall.build` 直接读它决定登录/设密码路由。
- **目标**：
  ```dart
  class SessionProvider extends ChangeNotifier {
    bool vaultInitialized = false;
    // 登录态、session stream 也可一并收敛
  }
  ```
  `AuthWall` 改为 `context.watch<SessionProvider>()`。测试里
  `Provider<SessionProvider>.value(SessionProvider()..vaultInitialized = true)` 即可走登录页。
- **测试收益**：无需再为 `AppBootState.vaultInitialized` 直接赋值；路由分支可独立测。

### 4.5 `Cryptography.instance` 全局 → `CryptoProvider`

- **现状**：`test_helpers.dart` 因 isolate 挂起，手写 `_TestArgon2id` / `_TestAesGcm` 替身
  并 `Cryptography.instance = _TestCryptography()`。
- **目标**：抽象一个 `CryptoProvider`（或直接在 `notesRepository` / keyring 装配时传入
  `Cryptography` 实例），生产用真实 `DartCryptography()`，测试注入「无 isolate、确定性」
  的实现（把现有 `_TestCryptography` 提升为正式测试替身，不再藏在 test 文件里）。
- **测试收益**：UI 测试（尤其登录/设密码流）不再需要手写加密替身，且彻底规避 isolate 挂起。

### 4.6 平台插件 → 各自 port（消灭 MethodChannel mock）

为每个在 widget 测试里会造成 `MissingPluginException` 的插件定义窄接口，并包一层 adapter：

| 插件 | 建议 port | 真实 adapter | 测试替身 |
|---|---|---|---|
| `flutter_secure_storage` | `SecureStoragePort` | 包插件 | `FakeSecureStorage`（内存 Map） |
| `local_auth` | `BiometricPort` | 包插件 | `FakeBiometric`（永远成功/可配置） |
| `device_info_plus` | `DeviceInfoPort` | 包 `DeviceIdProvider` | `FakeDeviceInfo`（固定 id） |
| `permission_handler` | `PermissionPort` | 包插件 | `FakePermission`（永远授予） |
| `path_provider` | `AppDirsPort` | 包 `getApplicationSupportDirectory` 等 | `FakeAppDirs`（临时内存路径） |
| `file_picker` | `FilePickerPort` | 包插件 | `FakeFilePicker`（返回固定路径） |
| `url_launcher` | `UrlLauncherPort` | 包插件 | `FakeUrlLauncher`（记录调用） |
| `media_scanner` | `MediaScannerPort` | 包插件 | `FakeMediaScanner`（no-op） |

- **依据**：`DeviceIdProvider` 已有 `overrideForTesting` 先例（见 `lib/utils/device_id.dart`），
  证明「为测试留注入点」是团队认可的做法，这里只是把它**统一成 port + provider** 模式。
- **测试收益**：删除 `_setupSecureStorageMock()` 与标题栏通道 mock；插件相关 widget
  （生物识别解锁、备份导入导出）测试注入 fake 即可。

### 4.7 收敛静态内存态（`PhraseHandler` / `ImportEncryptionControl` 等）

`preference_and_config.dart` 里 `PhraseHandler`（会话密码）、`ImportEncryptionControl`、
`ImportPassPhraseHandler` 是全局可变的「会话内存态」。改造时：
- 会话密码归并进 `SessionProvider`（或专门的 `SessionSecrets` port，注意**绝不**进日志）。
- 导入态（`ImportEncryptionControl`）随导入流程以参数/局部状态传递，不再用静态全局。

---

## 5. 第三方库清单与取舍

| 库 | 版本策略 | 解决什么 | 必要性 |
|---|---|---|---|
| **mocktail** | 加 `dev_dependencies` | 类型安全 mock，**无需 `build_runner` 代码生成**（与现有 `generated/build_info.g.dart` 的少量 codegen 不冲突）。替换手写 `_TestArgon2id` 等替身 | **强烈建议** |
| **clock** + **fake_async** | 加 `dev_dependencies` | 会话超时、自动锁屏、`timeago`、`local_session_timeout` 的确定性时间。注入 `Clock`（`DateTime.now()` 统一改为 `clock.now()`） | 建议（有相关测试时） |
| **easy_localization**（代码生成模式，**需验证版本兼容**） | `easy_localization: ^3.0.8` 是否支持 `easy_localization_gen` 待确认 | 把翻译编成 Dart 常量，**彻底去掉运行时 JSON 加载** → 删掉 `_TestAssetLoader` | 可选（根治 i18n 测试地雷，但有 build_runner 成本） |
| **network_image_mock** | 加 `dev_dependencies` | 含远程/同步图标的 widget 测试，省掉真实网络 | 按需（仅当 widget 真的加载远程图） |
| **golden_toolkit** / **alchemist** | 加 `dev_dependencies` | shadcn_ui + 主题切换非常适合视觉回归（`theme_color_setting_test` 当前靠逐像素断言，脆弱）。`alchemist` 支持设备变体 + 主题矩阵 | 建议（Phase 4） |
| **patrol** | 加 `dev_dependencies` | 集成测试更顺手的 API + 原生权限/弹窗处理，减少 `pumpApp` 手写 pump 循环 | 可选（集成测试多时） |

> 状态管理**不换** `provider`；如需全局 DI 图再考虑 `get_it`+`injectable`，但会增加 churn，
> 不优先。

---

## 6. 测试支撑层重设计

把现有 `test/test_helpers.dart` 拆成三层：

1. **`test/support/fakes.dart`**：所有 `FakeXxx`（内存实现，无 Flutter/插件依赖）。
2. **`test/support/harness.dart`**：
   - `withProviders(Widget child, {List<Override> overrides = const []})`：
     包 `EasyLocalization` + `ShadApp` + `MultiProvider` + 默认一组 fake，允许按用例 override。
   - `initTestEnv()`（仅集成测试用，保留现有 `_TestCryptography` 等，但统一入口）。
   - **删除** `prepareUnlockedVault` / `prepareEmptyVault` / 手写加密替身对普通 widget 测试的依赖
     （这些只留给「确需真实加密+DB」的少数集成测试）。
3. **`test/support/clock_override.dart`**：封装 `withClock` / `FakeAsync` 辅助。

**键盘动画导致 `pumpAndSettle` 卡死**（真实问题，见 `test_helpers.dart:456-488` 注释）：
在 `withProviders` 里默认包一层
`MediaQuery(data: const MediaQueryData(viewInsets: EdgeInsets.zero), child: child)`，
让「软键盘显隐滚动动画」分支永不触发 → `pumpAndSettle` 自然收敛，**删掉 `settle()` 手动循环**。

---

## 7. 两个「不重构也能立刻减负」的小修

即使暂不推进 §4，这两处可单独成 PR，立竿见影：

1. **集中 asset loader（低风险）**：把 `test_helpers.dart` 的 `_TestAssetLoader` 提到
   `test/support/`，并删除 `export_backup_dialog_test.dart:29-48` 的重复副本。
   *根治* 方案见 §5 `easy_localization` 代码生成（需先验证与 `^3.0.8` 兼容）。
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
| **P1** | §7 两个小修 + 引入 `mocktail` + 集中 `test/support/` | 极低 | 0.5–1 天 | 无 |
| **P2** | §4.1 `PreferencesRepository` + §4.4 `SessionProvider` | 低（接口 1:1 映射） | 2–3 天 | P1 |
| **P3** | §4.2 `NotesRepository` + §4.5 `CryptoProvider` + §4.6 平台 port | 中 | 3–5 天 | P2 |
| **P4** | §4.3 `SyncServicePort`（去单例）+ §5 golden/patrol | 高（1300+ 行单例） | 4–7 天 | P3 |
| **P5** | §5 `easy_localization` 代码生成（可选根治 i18n） | 中（需验证版本兼容） | 1–2 天 | 任意 |

**每 Phase 验收**：`flutter analyze` + `flutter test` + `dart test packages/core/test` 全绿；
`test_helpers.dart` 体积逐 Phase 下降（目标最终 < 5KB，仅服务于少量真实集成测试）。

---

## 10. 风险与回退

- **P4 风险最高**：`SyncService` 单例被 50 处引用，去单例时容易漏改。
  缓解：保留 `SyncService.instance` 桥接（内部委托给全局持有实例），分文件迁移，
  每 PR 保证测试全绿；出现回归时按文件 `git revert` 该 PR 即可。
- **`easy_localization` 代码生成**：需先确认 `^3.0.8` 与 `easy_localization_gen` 的兼容，
  以及 build_runner 对现有 `build_info.g.dart` 无冲突；验证不过则只做 §7 的集中 loader。
- **core 红线**：所有新增接口/adapter 落在 `lib/`，绝不向 `packages/core` 引入 Flutter；
  CI 已有 workspace 编译器强制，违反会直接失败。
- **`Cryptography` isolate 挂起**：确认 `FakeCryptography` 仅用于测试；生产路径保持真实
  `DartCryptography()`，密码学强度不受影响。

---

## 附录 A：引用计数证据（2026-08-15，`lib/` 目录）

```
NotesDatabase.instance        : 38 处
PreferencesStorage. (文件数)  : 24 个文件
SyncService.instance          : 50 处
Cryptography.instance         : lib 1 / test 1
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
