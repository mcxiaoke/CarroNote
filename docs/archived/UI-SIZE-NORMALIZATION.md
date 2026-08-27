# UI 尺寸/字号规范化对照表（2026-08-15）

统一散落的 fontSize 与其它 size 魔法数字。改动前全部文件已备份至 `temp/backups/size_normalize_20260815_163755`。

## 新增常量

`lib/utils/text_styles.dart` 新增 `AppTextSize`（纯字号刻度，仅统一字号数字来源，不附加字重/字距，避免替换时视觉漂移）：

| 常量 | 值 |
|---|---|
| `AppTextSize.s12` | 12 |
| `AppTextSize.s14` | 14 |
| `AppTextSize.s16` | 16 |
| `AppTextSize.s20` | 20 |

## A. fontSize 硬编码 → `AppTextSize` 引用（值不变，仅统一来源）

| 文件 | 原值 → 新值 | 处数 |
|---|---|---|
| sync_diagnostics_page.dart | 12→s12 | 15 |
| sync_diagnostics_page.dart | 20→s20 | 1 |
| sync_backend_config_page.dart | 12→s12 | 3 |
| backup_setting.dart | 12→s12 | 1 |
| notes_color_setting.dart | 12→s12 | 1 |
| theme_color_setting.dart | 12→s12 | 1 |
| about_page.dart | 20→s20 | 1 |
| shad_settings_tiles.dart | 12→s12 | 4 |
| footer.dart | 12→s12 | 2 |
| drawer.dart | 20→s20 / 12→s12 | 2 |
| home_navigation_rail.dart | 16→s16 | 1 |
| app_dialogs.dart | 12→s12 | 2 |
| change_passphrase.dart | 20→s20 | 1 |
| login.dart | 12→s12 / 14→s14 / 三元 `12:14`→`s12:s14` | 3 |
| export_backup_dialog.dart | 12→s12 | 3 |

## B. 圆角/间距奇数 → 向上最近偶数

| 文件 | 原值 → 新值 | 类别 |
|---|---|---|
| sync_diagnostics_page.dart | 1→2（×2） | vertical padding |
| sync_backend_config_page.dart | 5→6 | vertical padding |
| backup_setting.dart | 13→14 | vertical padding |
| shad_settings_tiles.dart | 13→14（×2） | vertical padding |
| shad_nav_items.dart | 圆角 9→10 | borderRadius |
| footer.dart | 3→4 | vertical padding |
| drawer.dart | 15→16（×2） | horizontal padding / radius |
| drawer.dart | 1→2 | itemSpacing |
| drawer.dart | 5→6（×2） | vertical/bottom padding |
| change_passphrase.dart | 25→26（×2） | input 间距 / top padding |
| login.dart | 5→6 | top padding |
| set_passphrase.dart | 5→6 | top padding |
| theme_setting.dart | 圆角 2→4 | borderRadius |

## 明确排除，未改动

- **Markdown 编辑器标题**（`add_edit_note.dart` h1–h4：24/20/18/17）及行内 code（14）——用户要求保留 markdown 排版。
- **全局按钮默认样式**（`app_theme.dart` 16 + w600）——用户要求保留全局默认。
- **页面/面板最大宽度**：`home.dart` 1300、`theme_color_setting.dart` 720、`about_page.dart` 420、`theme_setting.dart` 560、`shad_dialog.dart` 560——用户要求暂时不动。
- 布尔/逻辑表达式、非尺寸用途数字（`constraints.maxWidth / N`、`index % 2`、`Divider` 的 thickness 等）。
- 已是 `AppText`/`AppSpace`/`AppShape`/`AppIcon`/`kDialogMaxWidth*`/`kInput*` 的 token 引用。

## 验证

- `flutter analyze`：No issues found。
- `flutter test`：全部通过（含 `theme_color_setting_test.dart`）。
- `packages/core` 测试仅有 1 项既有失败（`longrun_persistent_store_test`，依赖真实 DB 跨运行累积，与本次无关）。