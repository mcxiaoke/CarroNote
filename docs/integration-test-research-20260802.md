# SafeNotes 真实集成测试（integration_test）可行性调研

> 调研日期：2026-08-02
> 目标：用官方 `integration_test` 在**真实进程、真实 UI、真实 SQLite、真实服务端**上验证「设置主密码 → 登录 → 笔记增删改 → 修改主密码 → 同步」，替代 `test/` 下的 Mock/Fake 测试。
> 参考：https://docs.flutter.cn/testing/integration-tests/

---

## 0. 结论速览

| 项 | 结论 |
|---|---|
| 可行性 | **可行**，且本项目基础条件不错（DB 有 `@visibleForTesting` 注入点、同步配置全是静态 setter、已有真实 Go/Node server 启动脚手架） |
| 首选平台 | **Windows 桌面**（`flutter test integration_test -d windows`）——设备即宿主机，可在测试进程内直接 `Process.start` 拉起真实 SafeServer，且完全绕开移动端原生弹窗 |
| 次选平台 | Android 真机/模拟器（做平台冒烟），服务端需宿主机预先启动 + 地址通过 `--dart-define` 注入 |
| 前置改造 | **3 项必改**（见 §3），否则测试跑不起来或会污染用户真实数据 |
| 覆盖不到的场景 | 生物识别、系统权限弹窗、文件选择器、真·进程重启（见 §4），需 `patrol` 或保留手工测试 |

---

## 1. `integration_test` 能做什么 / 不能做什么

### 1.1 能力
- 测试代码跑在**真实 App 进程内**（Android/iOS/Windows/macOS/Linux/Web），插件走真实原生实现，SQLite 是真库，HTTP 是真网络。
- 复用 `flutter_test` 的 `WidgetTester` API（`tap` / `enterText` / `pumpAndSettle` / `find`），写法与 widget test 几乎一致。
- 运行方式两种：
  - `flutter test integration_test/xxx.dart -d <device>` —— 主流用法，输出即 test reporter。
  - `flutter drive --driver=test_driver/integration_test.dart --target=integration_test/xxx.dart` —— 需要**截图**（`binding.takeScreenshot`）、性能追踪（timeline）或 Web 测试时才用。

### 1.2 官方明确的限制
> 引用官方文档：*「`integration_test` 无法与原生平台 UI 交互」*

| 限制 | 对本项目的影响 |
|---|---|
| **无法操作原生 UI** | `local_auth` 生物识别弹窗、`permission_handler` 权限弹窗、`file_picker` 系统文件选择器**全部点不了** |
| **无法重启 App 进程** | 「改完密码重启 App 用新密码登录」这种验证，只能在同进程内**模拟冷启动**（复位单例后重跑 bootstrap），不是真进程重启 |
| **一个 test 文件 = 一个 App 进程** | 文件内所有 `testWidgets` 共享进程状态：SharedPreferences、secure storage、SQLite、`SyncService.instance`、`LogWebServer` 端口全部串味，必须自己写 `setUp` 清理 |
| **设备上跑，不是宿主机上跑** | Android 真机上**不能** `Process.start('go run ...')` 拉起服务端；桌面端因为设备=宿主机所以可以 |
| **默认单用例超时 30s** | 真实 PBKDF2（20 万轮）+ 网络同步很容易超，需显式 `timeout: Timeout(Duration(minutes: 2))` |
| **`flutter test` 方式不支持截图** | 需要截图必须切 `flutter drive` + `integrationDriver()` |

---

## 2. 本项目现状盘点

### 2.1 有利条件
| 能力 | 位置 | 说明 |
|---|---|---|
| DB 可注入 | `lib/data/database_handler.dart:259` `setDatabaseForTesting()` / `:265` `createDBForTesting()` | 可换成 `:memory:` 或临时文件库 |
| 同步配置全静态可写 | `lib/sync/sync_config.dart:83/170/182/197` `setBackendType` / `setSafeServerUrl` / `setSafeServerToken` / `setAutoSyncEnabled` | 测试可**跳过 UI 直接编程配好后端**，也可走 UI 验证设置页 |
| 同步有可 await 的完成信号 | `lib/sync/sync_service.dart:398` `Future<SyncResult?> sync()`；`:135` `stateStream`（broadcast） | 不必 `Future.delayed` 瞎等 |
| 真实服务端脚手架已存在 | `test/sync/safe_server_integration_test.dart`（构建 Go 二进制 → 起进程 → 轮询 `/api/v2/health` → `clearData()`）+ `test/scripts/test-cleanup.ps1` | **可整体抽出复用**，是本次最大的现成资产 |
| 生物识别默认关闭 | `preference_and_config.dart:285` `isBiometricAuthEnabled` 默认 `false` | 登录页不会自动弹原生指纹框 |
| Windows 桌面完整支持 | `windows/` 目录齐全；`main.dart:107` 已处理 sqflite_ffi | 桌面端可直接跑 |

### 2.2 不利条件
| 问题 | 位置 | 影响 |
|---|---|---|
| **全 `lib/` 无一个 `Key`/`ValueKey`** | 全项目 | 只能靠 `.tr()` 文案 / `Icon` / `byType` 定位，脆弱且与语言强耦合 |
| **文案全走 easy_localization** | 各 view | `find.text('Login')` 无效，必须 `find.text('Login'.tr())` 且保证 EasyLocalization 已初始化 |
| **`main()` 包了 `runZonedGuarded`** | `lib/main.dart:51` | 触发 Zone mismatch 断言，**直接导致用例失败**（见 §3.1） |
| **DB 路径指向真实用户目录** | `main.dart:118` `getApplicationSupportDirectory()` | 集成测试会**读写用户真实笔记库**（见 §3.2） |
| 防截屏默认开启 | `preference_and_config.dart:167` `isFlagSecure` 默认 `true` | Android 上 `flutter drive` 截图会黑屏 |
| 无操作自动登出默认开启 | `:242` `isInactivityTimeoutOn` 默认 `true`，300s | 长用例可能被弹「即将登出」对话框打断 |
| 登录失败锁定 + 倒计时 Timer | `login.dart:212/780` `Timer.periodic` | 错密码用例超过允许次数会进入锁定倒计时，且 `pumpAndSettle` 会因周期重建而超时 |
| 日志 Web 服务器占 8888 | `home.dart:87` → `log_webserver.dart` | CI 上端口冲突风险（有 `isRunning` 幂等保护，风险可控） |
| 无 integration 相关构建配置 | `Makefile:36` 只有 `flutter test`；`android/app/build.gradle` 无 androidTest sourceSet | 需要补 |

---

## 3. 三项必做改造（阻塞项）

### 3.1 【阻塞】抽出可测试的 `bootstrap()`，绕开 Zone mismatch

**问题**：集成测试里 `IntegrationTestWidgetsFlutterBinding.ensureInitialized()` 在测试 zone 初始化 binding；而 `app.main()` 内部 `runZonedGuarded` 又创建了子 zone，在子 zone 中调 `runApp` → `BindingBase.debugCheckZone` 抛断言：

```
Zone mismatch. The Flutter bindings were initialized in a different zone than is now being used.
```

在 `testWidgets` 中，任何 `FlutterError` 都会被判定为用例失败，所以这不是"红字警告"而是**硬阻塞**。

**改法**（对生产行为零影响）：

```dart
// lib/main.dart
Future main() async {
  runZonedGuarded<Future<void>>(() async {
    WidgetsFlutterBinding.ensureInitialized();
    await bootstrap();          // ← 原来的 _initLogging + _installGlobalErrorHandlers + _bootstrap
  }, (error, stack) { Log.app.f('未捕获的异步异常', error: error, stackTrace: stack); });
}

/// 应用启动序列（集成测试直接调用此函数，跳过 runZonedGuarded 以避免 Zone mismatch）
@visibleForTesting
Future<void> bootstrap() async {
  await _initLogging();
  _installGlobalErrorHandlers();
  await _bootstrap();
}
```

集成测试中：`await app.bootstrap(); await tester.pumpAndSettle();`

### 3.2 【阻塞，且是数据安全问题】测试数据目录隔离

桌面端 `main.dart:118` 把 DB 指向 `%APPDATA%\safenotes\safenotes_sync.db` —— 这是**开发者本机的真实笔记库**。集成测试跑一遍设置密码 + 改密码，会直接破坏真实数据。同理 `flutter_secure_storage`（Windows DPAPI）存的 token、`shared_preferences` 也都是真实的。

**改法**：在 `_bootstrap()` 里加一个测试数据根目录开关，通过 `--dart-define` 注入：

```dart
// _bootstrap() 中，setDatabasesPath 之前
const testDataDir = String.fromEnvironment('SN_TEST_DATA_DIR');
final supportDir = testDataDir.isNotEmpty
    ? Directory(testDataDir)..createSync(recursive: true)
    : await getApplicationSupportDirectory();
await databaseFactory.setDatabasesPath(supportDir.path);
```

运行时：`flutter test integration_test/... -d windows --dart-define=SN_TEST_DATA_DIR=C:\Temp\sn-it`

> secure storage 无法改路径，只能在 `setUp` 里 `deleteAll()` + 用测试专用 key 前缀；因此**不建议在日常开发机上跑带真实 secure storage 的用例**，或接受它会清掉本机 SafeNotes 的 token。

### 3.3 【阻塞】新增 `resetForTesting()` 复位单例

同一进程内跑多个用例，必须能回到"全新安装"状态。涉及的全局状态：

| 单例 | 位置 |
|---|---|
| `NotesDatabase._database`（static） + `_dataKey` | `database_handler.dart:99/105` |
| `PreferencesStorage._preferences` | `preference_and_config.dart` |
| `AppBootState.vaultInitialized` | `authwall.dart:35` |
| `SyncService.instance`（含 `_autoSyncTimer`） | `sync_service.dart:165` |
| `SyncConfig._webdavPasswordCache` / `_safeServerTokenCache` | `sync_config.dart:135/178` |
| `LogWebServer.instance`（8888 端口） | `log_webserver.dart:45` |
| `Journal._flushTimer` | `journal.dart:402` |

建议在各类中补 `@visibleForTesting static Future<void> resetForTesting()`，再由 `integration_test/helpers/app_harness.dart` 统一编排。

---

## 4. 场景可测性分级

### A 档 — 桌面端可全自动、无需妥协
| 场景 | 路径要点 |
|---|---|
| 首次设置主密码 | `set_passphrase.dart` 两个输入框 + `'Confirm'.tr()` → `SyncService.initKeyringFromPassword` → `/home` |
| 登录 / 错密码提示 | `login.dart` `'Enter Passphrase'.tr()` + `'Login'.tr()`（**注意别超过允许失败次数**） |
| 新建笔记 | home FAB `Icons.add` → `add_edit_note.dart` 填标题/正文 → `'Save'.tr()` → 断言 DB + 列表 |
| 编辑笔记 | 点卡片 → `/viewnote` → 编辑 → 保存 → 断言内容变更 |
| 软删除 + 回收站 | `note_view.dart` `Icons.delete` → `delete_confirmation.dart` `'Delete'.tr()` → `deleted_notes.dart` 断言 |
| **修改主密码** | `change_passphrase.dart` 全流程 → 断言 keyring `keyVersion` 递增、旧密码失败、新密码成功、**已有笔记仍能解密**（这是最有价值的用例） |
| **SafeServer 同步** | 测试进程内起 Go server → `SyncConfig.setSafeServerUrl/Token` → 触发同步 → `await SyncService.instance.sync()` → 断言 `SyncResult` + server 数据目录 |
| 同步设置页 UI | `sync_settings.dart` 走真实 UI 填地址/Token 再同步 |

### B 档 — 可测但需要变通
| 场景 | 变通方式 |
|---|---|
| 改密码后"重启 App"验证 | `resetForTesting()` + 重新 `bootstrap()` 模拟冷启动（非真进程重启；真重启只能靠手工或 CI 分两次 run 同一数据目录） |
| 多设备同步冲突 | 单进程模拟两端很别扭。建议：① 保留现有 `test/sync/multi_device_test.dart` 的引擎级测试；② 集成测试只验证「本端 push / 本端 pull 到他端预置数据」，他端数据由测试代码直接写进 server 数据目录 |
| WebDAV 后端 | 需额外起一个 WebDAV 容器/进程，成本高，优先级低 |
| 自动同步（debounce Timer） | 不要等 `autoSync()`，直接 `await sync()`；或监听 `stateStream` 等 `SyncStatus.success` |

### C 档 — `integration_test` 做不到
| 场景 | 原因 | 出路 |
|---|---|---|
| 生物识别登录 | 原生指纹弹窗 | `patrol` 的 `native.` API，或保持手工 |
| 存储权限申请（Android ≤29） | 原生权限弹窗 | `patrol`，或测试机预授权 |
| 备份/导入选目录（`file_picker`） | 系统文件选择器 | `patrol`，或给 `FileHandler` 加可注入的路径 |
| `media_scanner` 刷新相册 | 原生副作用无法断言 | 跳过 |
| Android 防截屏截图 | `FLAG_SECURE` | 测试前 `setIsFlagSecure(false)` |

---

## 5. 建议的落地结构

```
safenotes/
  integration_test/
    helpers/
      app_harness.dart        # bootstrap + resetForTesting + 统一 setUp/tearDown
      ui_actions.dart         # setPassphrase() / login() / createNote() 等语义化动作
      test_server.dart        # 从 test/sync/safe_server_integration_test.dart 抽出的 server 管理
    auth_flow_test.dart       # 设置密码 / 登录 / 改密码
    notes_crud_test.dart      # 增删改查 + 回收站
    sync_safeserver_test.dart # 真实 SafeServer 同步
  test_driver/
    integration_test.dart     # 仅当需要截图时
```

### 5.1 依赖
```bash
flutter pub add "dev:integration_test:{sdk: flutter}"
```

### 5.2 `app_harness.dart` 骨架

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:safenotes/main.dart' as app;

/// 统一的集成测试环境：复位全局状态 → 关闭干扰开关 → 启动真实 App
Future<void> launchFreshApp(WidgetTester tester) async {
  await resetAllSingletons();                       // §3.3
  await PreferencesStorage.init();
  await PreferencesStorage.setIsFlagSecure(false);        // 关防截屏
  await PreferencesStorage.setIsInactivityTimeoutOn(false); // 关自动登出
  await PreferencesStorage.setIsBiometricAuthEnabled(false);
  await app.bootstrap();                            // §3.1，不走 runZonedGuarded
  await tester.pumpAndSettle(const Duration(seconds: 3));
}
```

### 5.3 用例骨架（改密码 + 笔记仍可解密）

```dart
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('改主密码后旧笔记仍可解密、旧密码失效', (tester) async {
    await launchFreshApp(tester);

    await setPassphrase(tester, 'OldPass#12345');       // 首次初始化保险库
    await createNote(tester, title: '会议纪要', body: '密钥轮换验证');

    await changePassphrase(tester, from: 'OldPass#12345', to: 'NewPass#67890');

    await relaunchApp(tester);                           // 模拟冷启动
    await expectLoginFails(tester, 'OldPass#12345');
    await login(tester, 'NewPass#67890');

    expect(find.text('会议纪要'), findsOneWidget);        // 旧笔记用新密码可解密
  }, timeout: const Timeout(Duration(minutes: 3)));      // PBKDF2 20万轮很慢
}
```

### 5.4 运行命令

```bash
# Windows 桌面（推荐）
flutter test integration_test -d windows --dart-define=SN_TEST_DATA_DIR=C:\Temp\sn-it

# 单文件
flutter test integration_test/auth_flow_test.dart -d windows

# Android 真机/模拟器（服务端需宿主机先起，模拟器用 10.0.2.2）
flutter test integration_test/notes_crud_test.dart -d <deviceId> \
  --dart-define=SN_SERVER_URL=http://10.0.2.2:8090

# 需要截图时
chromedriver --port=4444   # 仅 Web
flutter drive --driver=test_driver/integration_test.dart \
              --target=integration_test/auth_flow_test.dart -d windows
```

### 5.5 Makefile 补充
```makefile
itest:
	@echo "-> Run integration tests on Windows desktop"
	flutter test integration_test -d windows --dart-define=SN_TEST_DATA_DIR=$(TEMP)/sn-it
```

---

## 6. 分阶段实施建议

| 阶段 | 内容 | 产出 |
|---|---|---|
| **P0 可测试性改造** | §3 三项：`bootstrap()` 抽取、`SN_TEST_DATA_DIR` 隔离、`resetForTesting()` | 改 `main.dart` / `database_handler.dart` / `sync_service.dart` / `sync_config.dart` / `preference_and_config.dart` |
| **P0.5 加 Key**（强烈建议） | 给约 20 个关键控件加 `ValueKey`：`sn-pass-new` / `sn-pass-confirm` / `sn-btn-confirm` / `sn-pass-login` / `sn-btn-login` / `sn-fab-add` / `sn-note-title` / `sn-note-body` / `sn-btn-save` / `sn-btn-delete` / `sn-dialog-delete-confirm` / `sn-sync-url` / `sn-sync-token` / `sn-btn-sync-now` … | 测试从"文案匹配"升级为"稳定定位"，且不受多语言影响 |
| **P1 脚手架** | `integration_test/helpers/*`、server 管理代码从 `test/sync/` 抽出复用 | 可跑通一个 hello-world 用例 |
| **P2 认证 + CRUD 用例** | A 档前 6 项 | `auth_flow_test.dart` / `notes_crud_test.dart` |
| **P3 同步用例** | 真实 Go server（`SN_SERVER=node` 可切 Node） | `sync_safeserver_test.dart` |
| **P4 CI** | GitHub Actions `windows-latest`：`flutter test integration_test -d windows -r github`；Android 走 Firebase Test Lab（需补 `android/app/build.gradle` 的 androidTest 配置） | CI workflow |

---

## 7. 风险清单（实施时逐条确认）

1. **数据污染**：未做 §3.2 之前，**不要**在有真实笔记的机器上跑集成测试。
2. **secure storage 无法隔离**：Windows DPAPI / Android Keystore 写的是真实条目，`setUp` 必须 `deleteAll()`，或接受清空本机 SafeNotes 凭据。
3. **PBKDF2 20 万轮**：设置密码/登录/改密码每次几百毫秒到数秒，所有用例都要放宽 `Timeout`。
4. **`pumpAndSettle` 与周期 Timer**：`logout_alert.dart:158` 和 `login.dart:780` 的 `Timer.periodic` 会让 `pumpAndSettle` 永不 settle；对应场景改用 `pump(Duration)` 循环 + 显式 `expect`。
5. **端口占用**：8888（LogWebServer）、8090（测试 server）；CI 上建议随机端口 + 沿用 `test/scripts/test-cleanup.ps1`。
6. **Android 明文 HTTP**：连本地 server 需在 debug manifest 允许 `usesCleartextTraffic`，且模拟器用 `10.0.2.2` 而非 `localhost`。
7. **多语言**：CI 与本地 locale 不同会导致文案 finder 失配 —— 这也是 P0.5 加 Key 的核心理由。

---

## 8. 与现有 `test/` 的分工建议

不要用集成测试替换现有测试，而是分层：

| 层 | 位置 | 职责 | 速度 |
|---|---|---|---|
| 单元 | `test/encryption`、`test/sync/crypto_test.dart` 等 | 算法正确性、边界 | 毫秒 |
| 引擎集成（进程内真 server） | `test/sync/safe_server_integration_test.dart` 等 | 协议互操作、冲突/自愈/混沌 | 秒~分钟 |
| **端到端 UI（新增）** | `integration_test/` | **用户视角的完整旅程**：真 UI + 真 DB + 真 server | 分钟 |

现有 `test/sync/` 的混沌/多设备测试在引擎层做更高效，**不建议**搬到 UI 层重做。集成测试应聚焦"UI 到存储到网络这条链路是通的"，而非再验证一遍协议细节。
