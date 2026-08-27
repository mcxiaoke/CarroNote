# 集成测试方案（integration_test）

> 调研 + 实施计划文档，依据官方指南
> https://docs.flutter.dev/testing/integration-tests
> 本文档只描述方案，不改动任何业务代码；实施步骤见第六节，需用户确认后再动手。

## 0. 背景与目标

Carro Note 当前已有 `test/` 下的"集成风格"widget 测试（`auth_flow_test.dart`
驱动真实 App 走登录流程、`settings_flow_test.dart` 验证设置页），但：

- `pubspec.yaml` 未引入 `integration_test` 包；
- `integration_test/` 目录为空，无法用官方 `flutter test integration_test`
  收编、也无法上真机/被 `flutter drive` 驱动；
- 大量交互控件缺少稳定 `Key`，测试只能靠 `find.text` / `find.byType`，多语言
  或同屏重复文案下会变脆。

目标：在不重写现有 harness 的前提下，按官方 `integration_test` 范式补齐外层
驱动 + 稳定标识，使下列业务流程可被自动化覆盖：

> 初始化（首次设密码）→ 登录 → 主界面 → 左侧菜单点击 → 添加笔记 →
> 编辑笔记 → 进入设置 → 进入设置各子项。

## 1. 现状盘点（关键代码位置）

| 项 | 现状 | 文件:行 |
|---|---|---|
| 路由架构 | 命令式命名路由 `Navigator`，`onGenerateRoute` 集中分发；非 go_router / auto_route | `lib/app.dart:69`（onGenerateRoute）、`lib/app.dart:38`（navigatorKey）、`lib/routes/route_generator.dart:44` |
| 启动首屏 | 无 Flutter 闪屏（仅原生 `flutter_native_splash`），首屏为 `AuthWall`；`AppBootState`（定义于 `authwall.dart:33`）的 `vaultInitialized` 分支到登录 / 首次设密码，该标志由 `main()` 预置 | `lib/authwall.dart:52`（分支处）、`lib/authwall.dart:33`（定义）、`lib/main.dart:165`（main 预置） |
| 登录 | 单个 `ShadInputFormField` 密码 + `ShadButton('Login')`；另有生物识别按钮 | `lib/views/authentication/login.dart:277`、`323`、`344` |
| 首次设密码 | 两个 `ShadInputFormField`（新 / 确认）+ `ShadButton('Confirm')` | `lib/views/authentication/set_passphrase.dart:183`、`213`、`264` |
| 主界面 | 窄屏(<600px)用 `Drawer`（`drawer.dart`），宽屏用 `HomeSidebar`（`home_navigation_rail.dart`）；菜单项为手写回调，无数据列表 | `lib/views/home.dart:306`、`339`、`540`；`lib/widgets/drawer.dart:95` |
| 左侧菜单项 | `shadNavMenuItem`（InkWell 整行点击，无 `Key`） | `lib/widgets/shad_nav_items.dart:17`、`33` |
| 添加笔记 | 主界面 FAB（`FloatingActionButton` + `Icons.add`）→ `/addnote` | `lib/views/home.dart:513`、`514` |
| 编辑笔记 | 点卡片经 `OpenContainer` 内联打开 `AddEditNotePage`；标题 + 正文两个 `ShadInputFormField`；保存 = `LucideIcons.save` 的 `IconButton`；删除 = `LucideIcons.trash2`；预览切换 = `IconButton` | `lib/views/add_edit_note.dart:75`、`112`、`201`、`211`、`287`、`289` |
| 设置页 | `SettingsScreen` + 多组 `shadSettingsCard`；子项 tile 用 `shadNavigationTile` / `shadSwitchTile`（均无 `Key`） | `lib/views/settings/settings.dart:56`、`lib/widgets/shad_settings_tiles.dart:67`、`141` |
| 测试 harness | `initTestEnv()` / `prepareUnlockedVault()`（默认密码 `hello.1111`）/ `prepareEmptyVault()` / `pumpApp()` / `settle()` | `test/test_helpers.dart:349`、`388`、`417`、`449`、`473` |
| 现有样例测试 | `auth_flow_test.dart`（登录三路径）、`settings_flow_test.dart`（设置页验证） | `test/auth_flow_test.dart`、`test/settings_flow_test.dart` |

## 2. 全局变量 / 单例的影响（重点）

经通读 `test_helpers.dart` 与 `auth_flow_test.dart`，确认单例**不影响"能否加"集成测试，
但会影响"多流程串跑时的稳定性"**——根因是跨用例状态泄漏。明细：

| 全局 / 单例 | 现状 | 风险 |
|---|---|---|
| `AppBootState.vaultInitialized` | `prepare*` 里赋值；`tearDown` 只 `disposeVault()` 关库，**不复位该标志** | 串跑时若某用例设成"已初始化"，后续假定"首次运行"的用例需各自 `setUp` 显式 `prepare*`，否则分支错误 |
| `_secureStore`（内存安全存储） | 仅在 `initTestEnv`（setUpAll，**只一次**）里 `clear()` | 跨用例累积：登录用例写入 keyring 后，"首次运行设密码"用例仍能读到旧 keyring，导致 `AuthWall` 分支与 `Keyring.isInitialized` 不一致 |
| `NotesDatabase.instance` / `setDatabaseForTesting` | 每用例 `prepare*` 重设，`tearDown` 关库 | 只要每用例都 `prepare*` + `disposeVault` 即安全 |
| `PreferencesStorage` 单例 | `init()` 一次 | 跨用例偏好累积，可能影响深色/浅色、排序等断言 |
| `Cryptography.instance` / `LogWebServer.enableWebServer` | `initTestEnv` 设一次 | 无状态、无副作用，安全 |
| `testThemeProvider` / `testNotesColor` | `late` 全局，仅 `wrapScreen` 用 | 不影响 `pumpApp` 流程测试 |

**重置策略（实施时加入 harness）**：在 `test_helpers.dart` 新增一个
`resetTestState()`，在集成测试的 `tearDown` / `setUp` 中调用，内容：

```dart
Future<void> resetTestState() async {
  _secureStore.clear();                 // 清空内存安全存储，避免 keyring 泄漏
  AppBootState.vaultInitialized = false; // 复位启动分支标志
  await PreferencesStorage.init();       // 重建偏好单例（清空跨用例偏好）
}
```

> 注：`NotesDatabase` 由 `disposeVault()` 关库，`prepare*` 重新注入，无需在
> `resetTestState` 内处理。每个集成测试用例的 `setUp` 仍须调用 `prepareUnlockedVault`
> 或 `prepareEmptyVault` 来建立具体场景。

## 3. 关键约束（决定测试写法）

1. **`settle()` 替代 `pumpAndSettle`**：登录 / 设密码页在 `build()` 内按软键盘显隐
   触发 `scrollToBottomIfOnScreenKeyboard`，在 `flutter_test` 下 autofocus 唤起模拟
   软键盘使该滚动动画永不收敛，`pumpAndSettle` 会卡死超时。全程用 `settle()`（有限
   时长 pump，见 `test_helpers.dart:473`）。
2. **图标不可靠 `find.byIcon`**：多数图标是 shadcn 的 `LucideIcons`，不在
   `Material IconData` 体系内，`find.byIcon(Icons.x)` 只对少数 Material 图标有效
   （FAB 的 `Icons.add`、drawer 部分 `Icons.*`）。其余一律靠 `find.text` 或加 `Key`。
3. **多语言文案**：UI 走 EasyLocalization，当前测试用 `en-US` 且资产加载器退化为
   键即值（`test_helpers.dart` 的 `_TestAssetLoader`），断言英文文本与 `.tr()` 渲染
   一致。**加 `Key` 可彻底摆脱对文案的依赖**，是稳定性核心。
4. **binding 初始化顺序**：`integration_test` 驱动必须先初始化
   `IntegrationTestWidgetsFlutterBinding`，而 `initTestEnv()` 当前无条件调
   `TestWidgetsFlutterBinding.ensureInitialized()`，会覆盖集成绑定。需改为防御式
   （见第六节 C）。

## 4. 方案 A：采用官方 `integration_test` 包

相比"直接把测试塞进 `test/`"（方案 B），方案 A 改动小、结构官方、可被
`flutter test integration_test` 收编、能上真机 / 被 `flutter drive` 驱动。测试逻辑
两者完全相同，区别只在最外层驱动与运行目标。本方案选定 **A**。

### A. `pubspec.yaml` 加依赖

```yaml
dev_dependencies:
  flutter_test:
    sdk: flutter
  integration_test:        # 新增
    sdk: flutter
  # 其余保持不变
```

### B. 新建 `integration_test/integration_test.dart`（官方驱动）

```dart
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // 各 *_test.dart 通过 run(...) 或直接 import 本文件后写 testWidgets
}
```

### C. 微调 `test/test_helpers.dart:350` 的 binding 初始化

将无条件初始化改为防御式，避免覆盖集成绑定（同时不影响现有 Headless widget 测试）：

```dart
Future<void> initTestEnv() async {
  // 原写法（会强制基类绑定，覆盖集成绑定）：
  // TestWidgetsFlutterBinding.ensureInitialized();
  // 改为防御式：仅当尚无绑定实例时才初始化，保留
  // integration_test 驱动已建立的 IntegrationTestWidgetsFlutterBinding。
  if (WidgetsBinding.instance == null) {
    TestWidgetsFlutterBinding.ensureInitialized();
  }
  ...
}
```

并新增第二节的 `resetTestState()`。`pumpApp()` / `settle()` 其余原样复用。

### D. 给交互控件加 `Key`（稳定性核心，唯一像样的"业务代码"改动）

统一前缀便于查找。按优先级：

| 控件 | 文件:行 | 建议 Key |
|---|---|---|
| 登录密码框 | `login.dart:277` | `Key('loginPassphraseField')` |
| 登录按钮 | `login.dart:323` | `Key('loginButton')` |
| 生物识别按钮 | `login.dart:344` | `Key('biometricButton')` |
| 设密码（新） | `set_passphrase.dart:183` | `Key('newPassphrase')` |
| 设密码（确认） | `set_passphrase.dart:213` | `Key('confirmPassphrase')` |
| 设密码确认按钮 | `set_passphrase.dart:264` | `Key('setPassphraseButton')` |
| 主界面 FAB（加笔记） | `home.dart:513` | `Key('addNoteFAB')` |
| 笔记列表项 | `note_tile.dart:31` / `note_card.dart` | `ValueKey(note.uuid)` |
| 编辑器保存 | `add_edit_note.dart:287` | `Key('saveNoteButton')` |
| 编辑器删除 | `add_edit_note.dart:211` | `Key('deleteNoteButton')` |
| 编辑器预览切换 | `add_edit_note.dart:201` | `Key('previewToggle')` |
| 设置 tile | `shad_settings_tiles.dart:67`、`141` | `Key('settings_<name>')` |
| 抽屉 / 侧栏菜单项 | `shad_nav_items.dart:17` | `Key('menu_<label>')` |

> 不加 Key 也能写（靠 `find.text` / `find.byType`），但 UI 文案改动即脆。D 项是
> "方便加集成测试"的关键投入点。涉及改动的文件需在提交前跑 `make analyze` 并修复
> 所有 Error（`CLAUDE.md` 第 2、3 节）。

### E. 新建 `integration_test/*_test.dart` 测试文件（对应业务流程）

直接复用 `test/test_helpers.dart` 的 `initTestEnv` / `pumpApp` / `settle` /
`prepare*`，可平移现有 `auth_flow_test` 写法：

- `integration_test/flow_init_login_test.dart`
  - 首次运行：设密码 `hello.1111` → 进入主界面
  - 已有保险库：用 `hello.1111` 登录 → 主界面显示已 seed 笔记
  - 错误密码：停留登录页并提示
- `integration_test/flow_home_menu_test.dart`
  - 进主界面；分别覆盖窄屏 `Drawer` 与宽屏 `HomeSidebar` 两条菜单路径
  - 点击各菜单项（导入备份、改密码、深色/浅色、生物识别、设置、最近删除、登出…）
    并断言到达对应页
- `integration_test/flow_note_crud_test.dart`
  - FAB（`addNoteFAB`）加笔记 → 填标题/正文 → `saveNoteButton` 保存 → 列表可见
  - 点开笔记 → 改内容 → 保存 → 断言更新；删除路径用 `deleteNoteButton`
- `integration_test/flow_settings_test.dart`
  - 进设置 → 逐一点击各子项（Backup / Sync / Language / Biometric /
    Inactivity / Change Passphrase / Notes Color / 等）并断言到达对应子页

每个用例统一结构：

```dart
void main() {
  setUpAll(() async => initTestEnv());
  setUp(() async => prepareUnlockedVault());      // 或 prepareEmptyVault()
  tearDown(() async {
    await disposeVault();
    await resetTestState();                        // 第二节重置策略
  });

  testWidgets('...', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('loginButton')));
    await settle(tester);
    expect(find.text('CarroNote'), findsAtLeastNWidgets(1));
  }, timeout: const Timeout(Duration(seconds: 90)));
}
```

## 5. 运行方式

- 桌面 Headless（Windows，复用 mock，最快）：
  `flutter test integration_test`
- 真机 / 模拟器（上设备，可用 `flutter drive`）：
  `flutter test integration_test --device-id=<device>`
- 跑单个流程文件：
  `flutter test integration_test/flow_note_crud_test.dart`

> 现有 `test/` 下的 widget 测试继续用 `flutter test` 运行，与 `integration_test/`
> 互不干扰。改码后按 `CLAUDE.md` 先 `make analyze` 再跑测试。

## 6. 实施步骤（待用户确认后执行，本文档不改动代码）

1. `pubspec.yaml` 加 `integration_test: sdk: flutter`（第四节 A）。
2. 新建 `integration_test/integration_test.dart` 驱动（第四节 B）。
3. 改 `test/test_helpers.dart`：`initTestEnv` 改防御式 binding（第四节 C），
   新增 `resetTestState()`（第二节）。
4. 按第四节 D 给约 12 处控件加 `Key`（补简体中文注释，遵守 `flutter_lints`）。
5. 按第四节 E 新建 4 个集成测试文件。
6. `make analyze` 修复 Error → `flutter test integration_test` 验证全绿。

## 7. 风险与回滚

- **风险 1**：加 `Key` 改动分散在多个 UI 文件，review diff 成本略高。
  缓解：按文件分批、每批跑 `analyze`。
- **风险 2**：binding 守卫改动若遗漏，集成测试报告回调失效。
  缓解：第四节 C 的防御式写法向后兼容现有 Headless 测试。
- **风险 3**：单例状态泄漏导致偶发失败。
  缓解：第二节 `resetTestState` 在 `tearDown` 强制复位。
- 回滚：以上均为新增文件 + 局部可还原改动，未触及 `core` 包与协议，可分段回退。

## 8. 与现有测试体系的关系

`CLAUDE.md` 第 2 节把 `flutter test`（含现有 `test/`）称为"App 侧单元测试/集成风格
测试"，把 `packages/core/test/sync/safe_server_integration_test.dart` 称为"同步集成
测试"。本文档的 `integration_test/` 是**第三类**：UI 层端到端流程测试，补齐了
"初始化→登录→主界面→菜单→笔记→设置"这一整条用户路径的自动覆盖，与既有两层不冲突。
