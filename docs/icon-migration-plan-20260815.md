# 图标统一替换计划（Material Icons → Lucide Icons）

> 备忘文档 · 创建日期：2026-08-15 · 状态：待执行

## 1. 背景

当前代码库混用两套图标体系：

| 图标来源 | 调用方式 | 涉及文件 | 去重后图标数 |
|---|---|---|---|
| Material Icons | `Icons.xxx` | 24 个文件 | 73（实际落地的 45 个） |
| Lucide Icons | `LucideIcons.xxx` | 17 个文件 | 47 |

UI 整体是 shadcn 风格（`shad_settings_tiles.dart`、`shad_nav_items.dart` 等），设计语言应为 Lucide（线性描边）。
但 `home.dart`、`settings.dart`、`deleted_notes.dart`、`sync_*.dart` 等老页面仍用 Material `Icons.`，
导致描边粗细、圆角、视觉风格不统一。

`cupertino_icons` 已在 `pubspec.yaml` 声明为依赖，但代码里**没有任何 `CupertinoIcons.` 调用**（冗余依赖，可删）。

## 2. 调查结论

- Lucide（`lucide_icons_flutter` 3.1.15）提供 **1991 个**规范图标（含字重/方向变体共 27874 条声明）。
- 代码实际用到的 Material 图标为 **45 个**（已用 `(?<!Lucide)Icons\.` 排除 `LucideIcons.` 误匹配）。
- **45 个 Material 图标在 Lucide 中全部能找到概念对应物，无“Material 有但 Lucide 没有”的缺口。**
- 结论：可 100% 迁移，不会卡住。

## 3. 完整映射表（45 项，已逐一核验 Lucide 目录）

| # | Material | → Lucide | 契合度 |
|---|---|---|---|
| 1 | `Icons.add` | `plus` | 高 |
| 2 | `Icons.arrow_downward` | `arrow-down` | 高 |
| 3 | `Icons.arrow_upward` | `arrow-up` | 高 |
| 4 | `Icons.bug_report_outlined` | `bug` | 高 |
| 5 | `Icons.check_box` | `square-check` | 高 |
| 6 | `Icons.check_box_outline_blank` | `square` | 高 |
| 7 | `Icons.cloud_done_outlined` | `cloud-check` | 高 |
| 8 | `Icons.cloud_off_outlined` | `cloud-off` | 高 |
| 9 | `Icons.cloud_outlined` | `cloud` | 高 |
| 10 | `Icons.copy` | `copy` | 高 |
| 11 | `Icons.delete` | `trash-2` | 近似（见 4） |
| 12 | `Icons.delete_forever` | `trash-2` | 近似（见 4） |
| 13 | `Icons.delete_outline` | `trash-2` | 近似（见 4） |
| 14 | `Icons.delete_sweep` | `trash-2` | 近似（见 4） |
| 15 | `Icons.delete_sweep_outlined` | `trash-2` | 近似（见 4） |
| 16 | `Icons.download` | `download` | 高 |
| 17 | `Icons.error_outline` | `circle-alert` | 高 |
| 18 | `Icons.filter_list` | `list-filter` | 高 |
| 19 | `Icons.grid_view_outlined` | `layout-grid` | 高 |
| 20 | `Icons.healing` | `heart-pulse` | 近似（见 4） |
| 21 | `Icons.info` | `info` | 高 |
| 22 | `Icons.lock` | `lock` | 高 |
| 23 | `Icons.lock_outline` | `lock` | 高（Lucide 无描边变体，统一用 `lock`） |
| 24 | `Icons.more_vert` | `more-vertical` | 高 |
| 25 | `Icons.note_alt_outlined` | `sticky-note` | 近似（见 4） |
| 26 | `Icons.play_arrow` | `play` | 高 |
| 27 | `Icons.refresh` | `rotate-cw` | 高 |
| 28 | `Icons.restore` | `rotate-ccw` | 近似（见 4） |
| 29 | `Icons.search_off` | `search-x` | 高 |
| 30 | `Icons.settings_outlined` | `settings` | 高 |
| 31 | `Icons.skip_next` | `skip-forward` | 高 |
| 32 | `Icons.splitscreen_outlined` | `columns-2` | 近似（见 4） |
| 33 | `Icons.stop` | `square` | 近似（见 4） |
| 34 | `Icons.swap_horiz` | `arrow-left-right` | 高 |
| 35 | `Icons.sync` | `refresh-cw` | 高（Lucide 无独立 sync，用 refresh-cw 为社区惯例） |
| 36 | `Icons.toggle_off` | `toggle-left` | 高 |
| 37 | `Icons.toggle_on` | `toggle-right` | 高 |
| 38 | `Icons.upload` | `upload` | 高 |
| 39 | `Icons.vertical_align_bottom` | `align-end-vertical` | 近似（见 4） |
| 40 | `Icons.vertical_align_top` | `align-start-vertical` | 近似（见 4） |
| 41 | `Icons.visibility` | `eye` | 高 |
| 42 | `Icons.visibility_off` | `eye-off` | 高 |
| 43 | `Icons.warning` | `triangle-alert` | 高 |
| 44 | `Icons.wifi` | `wifi` | 高 |
| 45 | `Icons.wifi_off` | `wifi-off` | 高 |

## 4. 需留意的近似项（迁移后视觉会略有变化）

1. **`delete*` 系列（11–15）合并为 `trash-2`**：Material 里 `delete` / `delete_forever` / `delete_outline` / `delete_sweep` 的语义细分会丢失，统一成一个垃圾桶图标。功能无影响，但“永久删除/批量清扫”的视觉提示减弱。
2. **`healing` → `heart-pulse`**：Material 是医疗十字，Lucide 用心电图爱心。
3. **`restore` → `rotate-ccw`**：Material 是“历史回退”环形箭头，Lucide 用逆时针旋转箭头。
4. **`stop` → `square`**：Material 是实心方块，Lucide 是描边方块（shadcn 标准做法）。
5. **`splitscreen_outlined` → `columns-2`**：双栏示意。
6. **`note_alt_outlined` → `sticky-note`**：便签纸示意。
7. **`vertical_align_bottom/top` → `align-end/start-vertical`**：对齐语义一致。

> 上述“近似”项反而更贴合 Lucide 线性风格，整体统一性优于现状。

## 5. 迁移步骤（计划）

1. **预处理**：确认全部 45 处 `Icons.xxx` 均出自上述映射表（grep 复核）。
2. **逐文件替换**：按“高契合度优先、近似项集中复核”的顺序，替换以下文件中的 Material 图标：
   - `lib/views/home.dart`
   - `lib/views/settings.dart`
   - `lib/views/deleted_notes.dart`
   - `lib/views/settings/sync_settings.dart`
   - `lib/views/settings/sync_backend_config_page.dart`
   - `lib/views/settings/sync_diagnostics_page.dart`
   - `lib/views/settings/backup_setting.dart`
   - `lib/views/settings/notes_color_setting.dart`
   - `lib/views/settings/theme_color_setting.dart`
   - `lib/views/settings/theme_setting.dart`
   - `lib/views/settings/about_page.dart`
   - `lib/widgets/drawer.dart`
   - `lib/widgets/states.dart`
   - `lib/widgets/app_dialogs.dart`
   - `lib/views/change_passphrase.dart`、`login.dart`、`set_passphrase.dart` 中残留的 `Icons.`（若有）
3. **近似项人工核对**：对第 4 节列出的 7 类图标，在真机/模拟器上确认视觉可接受。
4. **清理依赖**：从 `pubspec.yaml` 移除未使用的 `cupertino_icons`（保留 `flutter_launcher_icons` 用于 app 启动图标）。
5. **Lint & 构建**：运行 `flutter analyze` 修复 Error；`flutter build` 验证图标字体打包正常。
6. **回归测试**：运行项目既有测试（若有）；无测试则注明跳过。

## 6. 待确认 / 开放问题

- [ ] 接受 `delete*` 系列合并为单一 `trash-2`（丢失语义细分）
- [ ] 删除 `cupertino_icons` 依赖
- [ ] 不需要为“近似项”补充自定义 SVG 以 1:1 还原原意（不推荐，违背统一目标）

## 7. 参考

- Lucide 目录来源：`lucide_icons_flutter` 3.1.15（pub cache 路径 `.../hosted/pub.flutter-io.cn/lucide_icons_flutter-3.1.15/lib/lucide_icons.dart`，1991 个规范图标）。
- 现状统计：Material 45 个 / Lucide 47 个（见对话调查）。
