# note_meta 功能实施进度

> 设计文档：`docs/feature-note-meta-design.md`
> 开始时间：2026-08-19 09:04 (GMT+8)
> 用途：**context 丢失后的恢复锚点**。每完成一步立即更新本文件。

## 状态图例
`[ ]` 未开始 · `[~]` 进行中 · `[x]` 完成 · `[!]` 受阻

---

## 阶段 1：数据层（核心包）

- [x] 1.1 新增 `packages/core/lib/src/models/note_meta.dart`
  - `NoteMetaFields`（列名常量）+ `NoteMeta` 模型 + `payload` JSON 序列化
- [x] 1.2 `core.dart` 导出 `note_meta.dart`
- [x] 1.3 建表接入**三处**（`_createDBStatic` / `_createDB` / `_onUpgrade`）
- [x] 1.4 版本 4 → 5（抽出 `_schemaVersion` 常量，消除硬编码）
- [x] 1.5 `_onUpgrade` 加 `oldVersion < 5` 分支
- [x] 1.6 `_metaCache` 独立缓存（`db:324`）+ `_invalidateCache` 一并清理（`db:333`）+ 失效点覆盖（close/logout/setDatabaseForTesting/reEncryptAllNotes/deleteDbFile）
- [x] 1.7 meta CRUD：`readAllNoteMeta`（`db:1806`）/ `getNoteMeta`（`db:1827`）/ `_decodeMetaRow`（`db:1848`）/ `upsertNoteMeta`（`db:1875`）/ `_upsertMetaCacheEntry`（`db:1902`）/ `setNotePinned`（`db:1916`）/ `setNoteTags`（`db:1929`）/ `readAllTags`（`db:1945`）
- [x] 1.8 硬删除写墓碑：`hardDelete`（`db:1123`）/ `hardDeleteByUuid`（`db:1156`）/ `hardDeleteAllDeleted`（`db:1198`）事务内 `_markNoteMetaDeletedInTxn`（`db:1965`）擦 payload + 事务后 `_removeMetaCacheEntry`；`reEncryptAllNotes` 同事务重加密 payload（新增 `_readMetaPayloadsPlain` `db:1989`，关键正确性修复）
- [x] 1.9 测试（新建 `packages/core/test/db/note_meta_test.dart`，14 项全通过）
  - A 内存 CRUD：懒创建 / setNotePinned / setNoteTags 规范化 / payload 往返 / readAllTags / `_metaCache` 与 `_notesCache` 隔离（切 pinned 不失效 notes 缓存）
  - B 合成 v4→v5 升级：手工 v4 库经生产 onUpgrade 升级，note_meta 表创建 + 既有行完好
  - C 硬删除写墓碑：hardDelete / hardDeleteByUuid 后 meta 行 `deleted=1` 且 `payload` 擦除，UI 不可见
  - D dataKey 轮换：reEncryptAllNotes 后 payload 密文变化且新 key 可解密标签
  - E 真实库验证：`temp/note_meta_realtest` 复制件，密码 `hello.1111` 解锁，106 条笔记（含回收站）保全 + meta CRUD 可用
- [x] 1.10 `dart format` + `import_sorter` + `flutter analyze` + `dart test packages/core/test`
  - `dart format`（4 文件，2 变更）+ `flutter analyze packages/core` → No issues
  - `dart test packages/core/test/db/note_meta_test.dart` → **14/14 通过**（含真实库 E 组）

## 阶段 2：首页与卡片（无同步）

- [x] 2.1 `lib/views/home.dart` `_sortAndStoreNotes` 叠加 pinned 维度
  - 排序改为「置顶恒在前，组内保持原时间序」（`home.dart:289`）
  - 置顶判定走 `NoteMeta.pinned`（`_metaCache`，红线 5：零笔记解密）
  - 实现细节：`metaMap` <uuid→NoteMeta> 依赖 `readAllNoteMeta()` 首查
    懒初始化 `_metaCache`；`compareTo` 用 int 化分值 `(pinned?1:0)`
    避免 bool.compareTo 不存在；置顶组取「新→旧」、非置顶组按时间键
- [x] 2.2 卡片/列表项置顶角标
  - `note_card_body.dart` 新增 `_buildPinnedBadge`：标题行末尾品牌色圆形
    pin 图标胶囊（`scheme.primary` + `onPrimary`，非半透明，醒目）
  - **修复裁切缺陷**：初版用 `Positioned(top:-4, right:-4)` 负偏移把角标推出
    卡片被 ShadCard 圆角裁切成四分之一；改为**标题行 Row 内嵌**（Expanded
    标题 + 角标），从布局上杜绝越界，四类外壳无需各自处理
  - 图标用 `LucideIcons.pin`（语义化置顶，非 star）
  - 四类外壳分别判定 `noteMeta != null && noteMeta.pinned`：
    `note_card.dart`（网格卡）/ `note_tile.dart`（桌面列表行）/
    `note_card_compact.dart`（紧凑网格）/ `note_tile_compact.dart`（紧凑列表行）
  - 角标挂 `Key('ui-note-pinned-badge')` 供测试定位
  - 翻译 key `Pinned` 补齐 `en-US` / `zh-CN`（卡片 Tooltip 文案）
- [x] 2.3 编辑器 AppBar 改造 + 操作菜单（**先做，用户当面指定的形态**）
  - AppBar 由「预览 / 删除 / 保存」三按钮改为「预览 / 保存 / 更多(⋮)」
  - 新增 `lib/widgets/note_actions_sheet.dart`：底部 sheet，含
    复制全文（`LucideIcons.copy`）/ 添加·取消星标（`star`·`starOff`）/
    删除笔记（`trash2`，危险色）
  - 新增 `shadActionTile`（`widgets/shad_settings_tiles.dart`）：裸图标 + 文本
    的轻量动作行，复用既有 `_TileSurface` 点击表面
  - sheet **只返回选择结果**（`NoteAction` 枚举），业务动作在编辑页执行
    → 删除确认框与 toast 都挂在本页 context，不用已销毁的 sheet context
  - 星标只写 `note_meta`，不动正文与 `notes.updated_at`（不触发 blob 重传）
  - 翻译 key ×8 补齐 `en-US` / `zh-CN`
  - 集成测试适配：抽出 `_tapEditorDelete`（先开 sheet 再点删除项），
    替换原先直接 `tap(LucideIcons.trash2)` 的两处
  - 新增 `test/note_actions_sheet_test.dart` 回归测试（4 项）：三项可见性 +
    复制/星标/删除点击返回对应枚举 + pinned 时星标项「取消星标」+starOff 图标 +
    删除项危险色 + 遮罩关闭返回 null
- [x] 2.4 新增 `test/note_pinned_home_test.dart`
  - 从真实 App 层锁契约：seed 三条不同 `updatedAt` 的笔记（新→旧 C/B/A），
    置顶最旧的 A → 登录后 A 排 `ui-home-note-0` 且带 `ui-note-pinned-badge`，
    B/C 无角标（隐式验证红线 5：切 pinned 不打乱笔记缓存排序）
  - **角标裁切回归断言**：`cardRect.contains(badgeRect.topLeft/bottomRight)`
    校验角标完整落在卡片内（负偏移裁切缺陷的看门狗）+ 断言图标为
    `LucideIcons.pin`（防回退成 star）

## 阶段 3：侧栏与标签

- [ ] 3.1 `home_navigation_rail.dart`（桌面）加「仅看星标」+「按标签」
- [ ] 3.2 `drawer.dart`（移动）同步加（**易漏，必须两端**）
- [ ] 3.3 标签选择弹窗
- [ ] 3.4 `editor_state.dart` tags 编辑
- [ ] 3.5 偏好持久化过滤态

## 阶段 4：items.meta 同步

- [ ] 4.1 `sync_backend.dart` 加 `putMetaObject`/`getMetaObject`（默认空实现）
- [ ] 4.2 三套后端实现（SafeServer / LocalFS / WebDAV）
- [ ] 4.3 新增 `note_meta_sync.dart`（AES-GCM + per-note LWW 合并）
- [ ] 4.4 `sync_engine.dart` 集成（manifest 阶段后，容错不阻断）
- [ ] 4.5 同步测试

## 阶段 5（独立任务，暂不做）

- [ ] 5.1 `purgedUuids` → note_meta 墓碑迁移

---

## 红线速查（每次改动前确认）

1. **绝不触碰** `SafeNote.computeHash` / `toContentBytes` / `fromContentBytes` / blob AAD
2. **绝不改** `notes.updated_at` / `notes.content_hash`（元数据变更走 `note_meta.updated_at`）
3. **note_meta 不加 FOREIGN KEY CASCADE**（墓碑需在 notes 行消失后存活）
4. **建表语句两份**（`_createDBStatic` + `_createDB`），漏一处报 `no such table`
5. **`_metaCache` 与 `_notesCache` 不耦合**（切 pinned 零笔记解密）
6. 诊断输出**不打印 `payload` 原文**

## 关键代码坐标

| 位置 | 文件:行 |
|---|---|
| 表名常量 | `models/safenote.dart:28`（`safe_notes`）/ `db/database_handler.dart:45`（`sync_meta`） |
| 字段加密 | `database_handler.dart:437` `_encryptField` / `:450` `_decryptField` |
| 建表 ×2 | `:535` `_createDBStatic` / `:571` `_createDB` |
| 版本号 | `:498` `version: 4` |
| 升级回调 | `:624` `_onUpgrade` |
| 笔记缓存 | `:308` `_notesCache` / `:312` `_invalidateCache` / `:320` `_upsertCacheEntry` |
| 硬删除 | `:1008` / `:1054` / `:1079`，事务内 `_addPurgedUuidInTxn` `:1116` |
| 首页排序 | `lib/views/home.dart:289` `_sortAndStoreNotes` |

---

## 相比设计文档的偏差（已评估，均为改进）

1. **建表语句只有一份**：设计文档 §5.1 说"必须两处都改"。实际做法是抽出
   `_createNoteMetaTable(DatabaseExecutor)` 单一副本，供 `_createDBStatic` /
   `_createDB` / `_onUpgrade` 三处调用 → **从结构上消灭漏改风险**（该风险原
   为文档 §12.2 第一项）。notes 表的两份重复保持原样，不在本次范围。
2. **不建 `idx_note_meta_uuid`**：`uuid TEXT NOT NULL UNIQUE` 已隐含唯一索引，
   再显式建是冗余（浪费空间且略拖慢写入）。
3. **不建 `idx_note_meta_pinned`**：设计 §3.4 明确星标/标签过滤在内存完成
   （全量行已进 `_metaCache`），该索引无 SQL 消费者。
4. **`payload` 的 `extra` 改为顶层键透传**（而非嵌套 `"extra": {}`）：
   解析时未识别的**顶层**键收进 `extra`，序列化时展开回顶层。一个机制同时
   满足「零成本加字段」与「前向兼容（旧版本不丢新版本字段）」。
5. **`payload` 已加入 `_inspectorHiddenColumns`**：落实设计 §5.3「不打印
   payload 原文」。

## 变更记录

- **2026-08-19 09:04** 创建进度文件，任务分解完成，开始阶段 1。
- **2026-08-19 09:20** 完成 1.1–1.5：`NoteMeta` 模型 + core.dart 导出 +
  note_meta 建表（单一副本接入三处）+ schema v4→v5 + 升级分支。
- **2026-08-19 09:22–09:30** 完成 1.6–1.8（缓存隔离 / CRUD / 硬删墓碑 + reEncrypt
  重加密 payload）+ 1.9 测试（14 项，含真实库复制件 v4→v5 升级验证：106 条笔记
  含回收站保全 + 密码解锁 meta CRUD）+ 1.10 格式化与分析全绿。
  **阶段 1（数据层）完成**。
- **2026-08-19 09:50** 提交前安全整改：测试 E 组的真实库路径与口令由硬编码
  改为环境变量 `SAFENOTES_TEST_DB` / `SAFENOTES_TEST_PASSWORD`，未设置时自动
  skip（13 通过 + 1 skip；带变量时 14 通过）。**仓库内不留任何本机路径与口令。**
- **2026-08-19 09:52** 阶段 1 已提交 `5e2ffc9`（6 文件，+1628/−11）。
  本进度文件按用户要求**不提交**；`docs/feature-starred-tags-design.md`
  为已废弃旧稿，同样未提交。
- **2026-08-19 10:0x** 完成 2.3 编辑器 AppBar 与操作菜单改造（详见阶段 2）。
  `flutter analyze lib integration_test test` → No issues；
  `flutter test` → 44 通过；`dart test packages/core/test` → 310 通过 + 1 skip。
- **2026-08-19 11:0x** 完成阶段 2.1/2.2/2.4（置顶排序 + 卡片角标 + 回归测试）。
  `flutter analyze` → No issues；`dart format` + `import_sorter` 通过；
  全量 `flutter test` → 49 通过（含新增 2.4 的 1 项）；`dart test packages/core/test`
  → 310 通过 + 1 skip。**阶段 2（首页与卡片）完成**，置顶链路全绿。
- **2026-08-18 16:33** 为 2.3 补充 widget 回归测试 `test/note_actions_sheet_test.dart`
  （4 项，见阶段 2.3 末条）。`flutter analyze test/note_actions_sheet_test.dart`
  → No issues；`dart format` + `import_sorter` 通过；全量 `flutter test` → 48 通过
  （含新增 4 项）。**阶段 2.3 收尾完成**（2.1/2.2 置顶排序与角标待做）。
