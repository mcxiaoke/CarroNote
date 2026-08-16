# SafeNotes 集成测试指南

> 维护日期：2026-08-16
> 本文是 SafeNotes 集成测试（integration_test）的使用与维护指南：
> 目的、方法、现有覆盖、未覆盖场景，以及如何正确新增测试用例。

---

## 1. 目的与原则

集成测试驱动的是**真实 App 进程**（与正常启动同一套 bootstrap），目标是验证**各界面是否正常渲染、功能是否可用、交互是否流畅**（不崩溃、不布局溢出）。

**核心原则**：
- core 包的加密 / 数据库 / 同步引擎逻辑已有完善单元测试，**integration_test 不重复覆盖 core 逻辑**，只关注 UI 层。
- 用例用 `Key` / `Icon` / `WidgetType` 定位（与现有 `ui-<screen>-<type>-<name>` 约定一致），**不依赖本地化文本**（避免语言切换后失效）。
- 所有用例集中在**一个进程**内顺序执行，保证连续、可重复。

---

## 2. 运行方式

```powershell
# 全部用例（桌面 Windows runner）
flutter test integration_test/app_test.dart -d windows

# 只跑某组（按 description 前缀过滤）
flutter test integration_test/app_test.dart -d windows --name "auth:"
flutter test integration_test/app_test.dart -d windows --name "trash:"
```

- 密码固定为 `hello.1111`（首次运行会自动用该口令创建密码库）。
- 完整跑约 4 分 30 秒，25 个用例通过。
- **注意**：debug 构建下日志会输出到 stdout，噪音较大；集成测试已把日志级别压到
  `error`（见 §6「日志降噪」），出错时才看得到日志。

---

## 3. 现有集成测试（A–H 功能组，25 用例）

全部实现在 [app_test.dart](../integration_test/app_test.dart) 的 `group('SafeNotes flows')` 中，
按 `description` 前缀区分功能组：

| 组 | 前缀 | 覆盖内容 |
| --- | --- | --- |
| 基础 | （无前缀） | 登录进入主界面；两套视口（compact 手机 / desktop 桌面）渲染；打开笔记预览↔编辑切换；新建笔记保存；设置页 12 个导航 tile 逐个打开不崩溃/不溢出 |
| A 认证 | `auth:` | 锁定（抽屉/侧栏 Lock）→ 重新登录；登录页密码显隐切换 |
| B 主界面 | `home:` | 搜索过滤与无结果空态、清空恢复；网格↔列表切换；排序切换 |
| C 笔记 | `note:` | 编辑已有笔记并保存；删除移入回收站；未保存改动三选弹框（取消/放弃/保存三分支）；Markdown 预览渲染 |
| D 回收站 | `trash:` | 回收站空态渲染；恢复单条；永久删除单条；清空全部 |
| E 备份 | `backup:` | 导出面板渲染与密码一致性校验；导入确认框取消 |
| F 设置 | `settings:` | 暗黑模式底部弹层切换；笔记色开关；改密页渲染（不改）；偏好开关切换 |
| G 同步 | `sync:` | 同步设置页渲染；后端配置面板类型切换 |
| H 滚动 | `scroll:` | 设置页上/下滚动；主页笔记列表上/下滚动 |

---

## 4. 未覆盖场景（后续可补）

以下场景**有意不测**（会让测试中断或依赖外部），新增用例时请继续遵守：

| 跳过项 | 原因 |
| --- | --- |
| 首次设置密码页 `/signup` | 一次性引导，`_ensureVaultReady` 已兜底创建密码库 |
| 修改密码**真正执行** | 触发密钥轮换 + 备份 + 同步，副作用大；只做「进入渲染 + 返回」 |
| 他端改密码强制重登录弹窗 | 依赖远端同步状态触发，无法稳定构造 |
| 调试面板 `/diagnostics` | dev 专属，非核心功能 |
| 所有跳转到 App 外部的操作 | 网页（launchUrl）、系统文件选择器（FilePicker）、打开目录、生物识别系统弹窗——一旦弹出测试无法继续 |
| 同步「测试连接 / 保存后应用」 | 依赖真实网络后端，且会改变运行态 |

**尚未覆盖、价值较高的候选**（当前未实现）：
- 主题色（Theme Color）选择页实际选色并返回后值刷新的断言。
- 语言（Language）切换后返回设置页值刷新的断言（需注意切换语言会影响后续用例，做完需切回）。
- 备份页「立即备份」「更改位置」的交互（会写本地文件 / 弹系统目录选择器，需权衡）。
- `About` 页内容渲染与「源码/开源许可/反馈」入口的存在性。
- 会话超时锁定（AuthWall）流程（依赖 `local_session_timeout` 的真实计时，较难稳定）。

---

## 5. 如何新增一条集成测试

### 5.1 定位目标
- 优先用现有 `ui-*` 测试 key；找不到就给目标 widget 加一个 key（见 §5.4）。
- 读目标页面源码，确认交互路径与异步加载点。

### 5.2 用例骨架
```dart
testWidgets('<组>: <一句话描述>', (WidgetTester tester) async {
  await _loginToHome(tester);          // 一律从 home 开始
  // ... 操作与断言 ...
  // 结束时必须回到 home（或登录页），便于下一个用例从干净状态继续
  await _backToHome(tester);
});
```

### 5.3 复用辅助函数（app_test.dart 内）
- `_loginToHome` / `_loginIfNeeded`：登录并落到 home。
- `_backToHome`：循环弹出路由直到 home / 登录页。
- `_isHome`：判断当前是否在主界面顶层路由。
- `_waitFor(tester, condition)`：轮询等待异步完成（**优先于 `pumpAndSettle`**，因为登录解锁、列表刷新、同步配置等不触发帧调度）。
- `_forEachViewport`：在手机 + 桌面两套尺寸下各跑一遍 body，用于检查 overflow。
- `_openSettings` / `_openNavEntry`：从抽屉/侧栏打开某入口。
- `_createNote` / `_openNoteByTitle` / `_deleteNoteByTitle`：新建、按标题打开、删除并清理笔记。
- `_toggleSettingSwitch`：滚动到设置页某开关并切换。
- `_clearAllTrash`：清空回收站，给回收站用例干净的起点。

### 5.4 加测试 key（行为不变的纯增量改动）
在对应 widget 上包一层 `KeyedSubtree(key: Key('ui-...'))` 或给组件加 `key:`，命名遵循
`ui-<screen>-<type>-<name>`。例如已经加的：
- 导航：`ui-home-nav-settings` / `ui-home-nav-lock` / `ui-home-nav-deleted`
- 工具栏：`ui-home-toolbar-layout` / `ui-home-toolbar-sort` / `ui-home-search-input`
- 对话框：`ui-dialog-confirm` / `ui-dialog-cancel` / `ui-dialog-discard`
- 设置开关：`ui-setting-switch-markdown` / `ui-setting-switch-compact` 等

### 5.5 注意事项（踩过的坑）
1. **自建笔记必须清理**：用 `_createNote` 建的临时笔记，在 `finally` 里用
   `_deleteNoteByTitle` 删除，否则笔记数随运行累积。
2. **toast/ snackbar 会遮挡控件**：上一个操作（如清空回收站）的 6 秒错误 toast 会盖住
   FAB，导致点击落空。操作前先 `await tester.pump(const Duration(seconds: 8))` 消退。
3. **异步加载用 `_waitFor`** 而非 `pumpAndSettle`；`pumpAndSettle` 在纯计算/无帧调度时
   会提前返回。
4. **搜索防抖 200ms**：输入搜索词后要等过滤生效；用 `_waitFor` 等目标消失/出现，别用
   立即断言。
5. **`_isHome` 必须识别所有全屏子页**：如给某页加了根 `Scaffold(key: ui-xxx-screen)`，
   记得把它加进 `_isHome` 的排除列表，否则 `_backToHome` 会误判已回 home。
6. **桌面侧栏也是 Scrollable**：定位主页笔记列表滚动时用 `find.byType(Scrollable).last`，
   `Scrollable.first` 会命中侧栏。
7. **不要点会弹系统对话框/跳外部的按钮**（见 §4），否则测试卡住。
8. **改密码、语言等全局副作用项**：只渲染不执行，或做完切回原值。

---

## 6. 稳定性基线与日志降噪

为让测试在测试机（同步后端不可达）上稳定、可重复，落地时做了以下处理：

- **禁用同步（一次性）**：首次登录后经 UI 关闭「Enable Sync」，使 `autoSync` 变为 no-op，
  避免 `BackendNotInitializedException` 在后台同步时污染后续用例（helper `_disableSync`）。
- **日志降噪**：测试启动后调用 `AppLog.setLevel(AppLogLevel.error)`，只保留 error 级输出，
  压掉 INFO/DEBUG 噪音。配套在 `AppLog` 加了 `setLevel`/`resetLevel`（`_manualOverride`
  非空时 `refreshLevel()` 不再覆盖）。

---

## 7. 待核实 / 历史决策

- 桌面侧栏（NavigationRail）与移动抽屉都含「Lock」，但**设置页本身没有退出口**
  （已确认无 logout，全部为「Lock」）；认证用例的 Lock 入口统一指向抽屉/侧栏。
- 导出面板在桌面为居中弹框、移动端为全屏页；涉及视口差异的用例可用 `_forEachViewport` 各确认一次。