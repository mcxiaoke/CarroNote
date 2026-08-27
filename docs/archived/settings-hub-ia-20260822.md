# 设置页 Hub 化重构方案 2026-08-22

> 现状：`lib/views/settings/settings.dart:130` 单页承载 4 分区 24 行（Appearance 10 / Data 4 / Security 7 / General 3），移动端约 3 屏，认知负荷高。
> 目标：按“使用频率 × 重要性”降序，Hub 聚合 + 二级页分流；同步与备份拆为顶级入口（应用户要求）；桌面端 Master-Detail 双栏，移动端 Hub 列表。

## 1. 主流做法参考

| 模式 | 代表 | 特点 |
|---|---|---|
| Hub + 二级页 | 微信 / Telegram / iOS 设置 | 首页 6–8 入口，每入口进独立页，单页 ≤8 项 |
| Master-Detail | VS Code / Notion / Windows 11 设置 | 左 Nav 列表，右详情，宽屏无滚动 |
| 可折叠 + 搜索 | Android 14+ / VS Code | 保留单页，搜索过滤 + 分区折叠 |
| Tabs | GitHub / Slack | 顶部 Tab 切分区，适合分区 ≤5 |

SafeNotes 已有响应式框架：`lib/widgets/drawer.dart` (Drawer <600px) / `lib/widgets/home_navigation_rail.dart` (Sidebar ≥600px)，适合采用 **Hub（全端）+ 桌面双栏增强**。

## 2. 新 IA（6 顶级入口）

此前方案 Data 含 Sync+Backup 共 4 tile；本次按要求拆为两个顶级入口，共 6 入口，均 ≤8 项、单屏可视。

```
Settings Hub (/settings)
├─ 1. 外观 Appearance            [palette]  摘要: 主题色·字体·Markdown
│   ├─ 主题：DarkMode(BottomSheet) / ThemeColor / NotesColor
│   └─ 显示：FontSettings(Global) / NoteStyle(字号行高对齐) / Compact / Markdown / RelativeTime / SortByModified
│       → 子页内分两张 shadSettingsCard，避免仍过长
├─ 2. 同步 Sync                  [cloud]    摘要: Disabled / Not configured / backend 名称
│   └─ 复用 SyncSettingsPage (/syncSettings) 5 段：总开关 / Status / BackendConfig / AutoSync / Keyring
├─ 3. 备份 Backup                [cloudUpload] 摘要: On/Off · 上次备份时间
│   ├─ AutoBackup 开关 + LastBackup / Location / ChangeLocation / BackupNow
│   └─ 传输：ExportBackup / ImportBackup（原 Data 组的导出导入收敛至此）
├─ 4. 安全与隐私 Security        [shield]   摘要: 生物识别·PIN·锁定时间
│   ├─ 认证：Biometric / PIN / ChangePassphrase
│   └─ 隐私：Inactivity / SecureDisplay / IncognitoKeyboard
├─ 5. 通用 General               [sliders]  摘要: 语言·DevMode
│   └─ Language / AutoRotate(仅移动) / DeveloperMode(条件)
└─ 6. 关于 About                 [info]     → 复用 AboutPage (/about)
```

* 原 Appearance 10 项拆为 2 卡片；Backup 聚合原分散的 4 个 Data 动作；Security 认证/隐私分组；General 轻量。Hub 仅 6 行，移动端 1 屏，桌面端左栏 240px。
* 摘要 value 复用原 `settings.dart:92 _loadDisplayValues` 逻辑：主题色中英文、同步三态、Backup On/Off、Biometric/PIN、失效时间、语言。

## 3. 交互与响应式

### 3.1 移动端 (<600px)
Hub 为 `shadSettingsList` + `shadNavigationTile`（icon + title + value + chevron），点击 `pushNamed` 进二级页（复用既有路由 `/syncSettings` `/backup` 等，新增 `/appearance` `/security` `/general`）。

### 3.2 桌面端 (≥600px)
`SettingsScreen` 内 `LayoutBuilder` 判断宽度：
- ≥600px：`Row` 左 `~220px` 侧栏（复用 `shadNavMenuItem` 样式，选中态 primary 底色），右 `Expanded` 展示选中分组详情（直接嵌入对应 Page 的 body widget，避免二次 push）。
- <600px：Hub 列表 push 模式。
切换分组仅 `setState(selectedIndex)`，不产生路由栈；返回键在 Hub 层级直接 pop 到 Home。

### 3.3 搜索（P1，可选）
Hub 顶部 `SearchWidget`（同 Home），过滤标题/别名（如搜“指纹”命中 Biometric）。首版可不做，留接口。

## 4. 文件与路由

```
lib/views/settings/
  settings.dart              → 重构为 Hub (6 tile + 桌面双栏逻辑)
  appearance_settings_page.dart  (新建)  AppearancePage
  security_settings_page.dart    (新建)  SecurityPage
  general_settings_page.dart     (新建)  GeneralPage
  backup_setting.dart        → 增强：加入 Export/Import 两 tile
  sync_settings.dart         (复用)
  about_page.dart            (复用)
  // theme_color_setting.dart, notes_color_setting.dart 等保持为更深二级页
lib/routes/route_generator.dart
  + '/appearance' → AppearancePage
  + '/securitySettings' → SecurityPage
  + '/generalSettings' → GeneralPage
```

Hub Keys：`ui-setting-hub-appearance` / `ui-setting-hub-sync` / `ui-setting-hub-backup` / `ui-setting-hub-security` / `ui-setting-hub-general` / `ui-setting-hub-about`
子页内保留原 Keys：`ui-setting-item-darkmode` 等迁移至对应子页，确保集成测试可 `scrollUntilVisible` 到正确 Scrollable。

## 5. 设计细节

- 复用 `lib/widgets/shad_settings_tiles.dart` 的 `shadSettingsList / shadSettingsCard / shadNavigationTile / shadSwitchTile`，Hub 与子页视觉统一。
- DevMode 开关：仅当 `DevMode.isActive` 时在 General 子页显示，关闭后即刻消失（复用原 `if (DevMode.isActive)` 逻辑）。
- 主题切换：`showThemeBottomSheet` 仍在 Appearance 子页触发，通过 `Provider.of<ThemeProvider>` 刷新。
- 从子页返回 Hub 需 `_refreshDisplayValues()` 更新摘要（语言/主题色等依赖 `context.locale` 的需在 `didChangeDependencies` 刷新）。

## 6. 测试与兼容

- 集成测试 `integration_test/app_test.dart:78 _settingsTileKeys` 由 12 个平铺 tile 改为：先断言 Hub 6 tile 存在，再遍历 Hub 点击进各子页，校验各子页首个 tile 存在后返回 Hub。需更新 `testWidgets('settings: visit every sub-page...')` 与 `testWidgets('settings: preference switches...')` 等涉及 `ui-setting-item-*` 直接位于 settings 的用例。
- `tester.scrollUntilVisible` 的 `find.byType(Scrollable).first` 在桌面双栏下需指向右侧详情的 Scrollable；Hub 列表的 scrollable 与详情 scrollable 分离已通过 `shadSettingsList` 的独立 `ListView` 保证。
- 无数据迁移，偏好键不变。

## 7. 实施步骤

1. 本文档落盘 `docs/settings-hub-ia-20260822.md`。
2. 新建 3 子页文件 + 增强 backup_setting。
3. 重构 settings.dart 为 Hub + 桌面双栏。
4. 新增路由 3 条。
5. 更新集成测试与相关单元测试。
6. `flutter analyze` + `dart test packages/core/test` + `flutter test` + `flutter build windows --debug` 验证。
7. 更新 `docs/CHANGES-20260822.md`。

## 8. 回滚与风险

- 单页改 Hub 属 UI 重组，无 DB/偏好变更，回滚仅需还原 `settings.dart` + `route_generator.dart`。
- 风险：集成测试因 Key 迁移失败 → 通过 KeyedSubtree 保留原 Key 规避。
