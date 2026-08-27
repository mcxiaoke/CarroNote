# note_meta 同步实施方案（items.meta + per-note LWW）

> 状态：**已实施**（2026-08-26 12:56，Q1-Q4 均按方案 a 落地；实施偏差见文末 §7）
> 日期：2026-08-26 12:11 (GMT+8)
> 上游设计：`docs/feature-note-meta-design.md`（§6 同步层为其原始设想，本文按当前代码现实修订）
> 前置事实：阶段 1-3（数据层 / 置顶 UI / 标签+锁定 UI）已全部完成；
> `PROGRESS-note-meta.md` 中阶段 3 未勾选系进度文件未回填，实际由
> `progress-note-lock-tags-task.md` 记录的任务完成（含 schema v6 `locked` 列）。

## 0. 目标与非目标

**目标**：note_meta（pinned / tags / color / archived / 墓碑）跨设备同步。
两台设备改不同笔记的元数据，双向同步后互不丢失（per-note LWW）。

**非目标**：
- 不动 notes 表、blob 协议、服务端（零改动红线）。
- 不做阶段 5（purgedUuids → note_meta 墓碑迁移），保持独立任务。
- `locked` **不同步**（既有拍板决策：「本地行为标志，不参与同步推送语义」，
  见 `progress-note-lock-tags-task.md` 决策记录；wire 格式不含 locked，将来若要
  同步，走 extra 透传机制平滑加入，无需破坏性变更）。

## 1. 与原设计文档的偏差（按当前代码修订）

| # | 原设计假设 | 当前代码现实 | 本文处置 |
|---|---|---|---|
| 1 | wire 条目含 pinned/archived/color/deleted | schema 已 v6，新增 `locked` 列 | wire **不含** locked（非目标）；其余字段照旧 |
| 2 | 「复用 SyncCrypto 现有封装」 | `SyncCrypto.seal/open` 的 AAD 绑定 blob 内容 hash（`crypto.dart:386` `_blobAad(id)`），直接复用会与 blob 信封域混淆 | 仿 `sealBackup(aadHeader)` 模式新增独立 AAD 域分隔符封装（如 `safenotes-note-meta-v1`） |
| 3 | — | `readAllNoteMeta()` 只返回 `deleted=0` 行 | 新增含墓碑的全量读查询（上传需带 `deleted=1 AND synced=0` 的待上报墓碑） |
| 4 | 阶段 3 未完成，是阶段 4 前置 | 已完成 | 无阻塞，可直接开工 |

## 2. 任务分解

### A. 后端抽象 + 三实现（小，~各30行）

- [ ] A1 `sync_backend.dart`：新增 `putMetaObject(Uint8List)` / `getMetaObject()`
      （默认空实现保持向后兼容）+ `kRemoteMetaMaxBytes` 上限常量，
      读取时复用 `checkRemoteReadSize`。
- [ ] A2 LocalFS：keyring 根目录下 `items.meta`（写法参照 `putJournalObject`，
      `local_fs_backend.dart:367`）。
- [ ] A3 WebDAV：vault 根目录 PUT/GET（参照 `webdav_backend.dart:711` 模式）。
- [ ] A4 SafeServer：复用 `_putResource`/`_getResource('items.meta')`
      （参照 `safe_server_backend.dart:700` 模式）。**服务端零改动。**

### B. wire 格式与加解密模块（中，核心）

新增 `packages/core/lib/src/sync/note_meta_sync.dart`：

- [ ] B1 文件结构（整文件 AES-GCM(dataKey) 加密，payload 条目内放**明文对象**，
      避免双重加密）：

```json
{
  "v": 1,
  "notes": {
    "<noteUuid>": {
      "pinned": 1,
      "archived": 0,
      "color": null,
      "deleted": 0,
      "updated_at": 1755500000000,
      "payload": { "tags": ["work"] }
    }
  }
}
```

- [ ] B2 加密封装：AES-GCM(dataKey)，独立 AAD 域分隔符（偏差 #2）。
- [ ] B3 序列化：本地 NoteMeta 全量（含待上报墓碑）→ wire 对象 → 密文。
- [ ] B4 反序列化容错：格式损坏返回空结果**不抛异常**（元数据是次要数据）；
      未知顶层键进 `NoteMeta.extra` 透传（沿用模型已有前向兼容机制）。
- [ ] B5 per-note LWW 合并纯函数（便于单测）：逐 uuid 比 `updated_at`，
      远端新→覆盖本地，本地新→保留，相等→跳过，单边存在→插入。

### C. DB 层配套（小-中）

- [ ] C1 含墓碑全量读查询（供序列化上传）。
- [ ] C2 远端条目批量合并写入：普通条目 upsert + 更新 `_metaCache` 单 entry；
      墓碑条目应用时**擦 payload** + 从 `_metaCache` 移除（对齐 `_markNoteMetaDeletedInTxn` 语义）。
- [ ] C3 上传成功后**条件置 synced**：
      `UPDATE ... SET synced=1 WHERE uuid=? AND updated_at=<读取快照值>`——
      防「序列化后、标记前用户又改动」丢脏标记。
- [ ] C4 墓碑 GC：上报成功后物理删除 `deleted=1 AND synced=1` 行。
- [ ] C5 确认无需改动：`reEncryptAllNotes` 已覆盖 payload 重加密（dataKey 轮换场景）。

### D. 引擎集成 `sync_engine.dart`（小但关键）

- [ ] D1 插入点：`sync()` 中 `_syncOnce` **成功返回后执行一次**
      （不放乐观锁冲突重试循环内，避免重复跑）；整体 try-catch 只记日志，
      对齐 `_uploadJournal()` 的「永不抛异常、永不阻断同步」契约（`sync_engine.dart:177`）。
- [ ] D2 流序：`getMetaObject()` 下载解密 → 合并入库 → 查 dirty（synced=0）
      → 有才序列化加密上传 → 条件置 synced → GC 墓碑。
- [ ] D3 解密失败策略：**待拍板 Q1**。
- [ ] D4 dataKey 迁移联动：**待拍板 Q2**。
- [ ] D5 journal 留痕（可选）：meta 同步 start/done 事件，便于诊断。

### E. 应用层 UI 刷新（易漏）

- [ ] E1 `home.dart:331` 的 `metaMap` 只在加载时读一次存 `_noteMeta`。
      远端合并可能改变 pinned/tags → 必须在 meta 合并完成后触发首页重排序刷新
      （挂到现有同步完成通知流上），否则用户看到过期置顶/标签状态。
- [ ] E2 编辑页打开中的笔记被远端改动的行为（color/tags 变化）：低优先级，
      可仅保证下次打开生效。
- [ ] E3 同步状态展示：meta 失败只记日志（次要数据，不打扰用户）。

### F. 测试（项目规则要求全绿）

- [ ] F1 core 单测：wire 往返 / LWW 四象限（本地新、远端新、相等、单边存在）/
      墓碑合并与应用 / 损坏容错 / extra 透传穿过 wire / 条件 synced 标记 /
      上传期间再改的脏标记保全 / 墓碑 GC。
- [ ] F2 三后端 put/get 往返测试；引擎测试用 fake backend。
- [ ] F3 引擎测试：meta 失败不影响 SyncResult 成功态；
      双库共享 backend 模拟双设备——A 星标笔记1、B 星标笔记2 →
      双向同步后两者都保留（原设计 §11 验收场景）。
- [ ] F4 红线回归：切 pinned 不失效 `_notesCache` 的既有测试保持绿。
- [ ] F5 `dart format` + `import_sorter`（仅改动文件）、`flutter analyze`、
      `dart test packages\core\test`、`flutter test`、
      `flutter build windows --debug`。

### G. 文档

- [ ] G1 `PROGRESS-note-meta.md` 回填阶段 3 勾选 + 阶段 4 进度。
- [ ] G2 `docs/CHANGES-YYYYMMDD.md` 顶部追加变更摘要。
- [ ] G3 原设计文档 §6 补充「locked 不同步」「AAD 域分离」等偏差批注。

## 3. 实施顺序建议

A（后端管道打通）→ B+C（格式与合并，纯 core 可独立测）→ D（引擎集成）→ E（UI 刷新）→ F/G 收尾。
B/C 完成前完全不碰同步链路，可独立回滚。

## 4. 已知局限（记录即可，不修）

- LWW 依赖设备墙钟（unix ms），时钟倒挂可能旧值覆盖新值——与笔记正文 LWW 同款固有限制。
- 整文件上传无 ETag CAS，并发上传为 last-writer-wins，靠下一轮下载 per-note 合并收敛，
  分歧窗口一轮。
- 元数据永远滞后正文同步一步（引擎成功后才跑），属有意设计。

## 5. 待拍板问题

### Q1 items.meta 解密失败时的策略？

触发场景：远端文件损坏，或 dataKey 迁移后旧文件未重封（见 Q2）。

- **方案 a（推荐）：自愈重建** —— 备份损坏密文（仿 `backupCorruptManifest`）+
  journal 留痕 + 忽略远端内容 + 用本地全量状态重建上传。
  优点：永不卡死；缺点：若他端有「本端没有的较新条目」且远端恰在此刻坏掉，这些条目丢失
  （概率极低：正常流程中他端上传前必先下载合并，本端多数情况已持有其状态）。
- 方案 b：保守中止 meta 部分（记日志，下次重试）。优点：绝不主动覆盖远端；
  缺点：永久性损坏时 meta 同步永久失效，需人工介入。

### Q2 dataKey 迁移（换密码引发的 reEncrypt 流程）时要不要显式处理 items.meta？

背景：items.meta 用 dataKey 加密。manifest 有完整迁移编排（`_executeMigration`
重新加密所有 blob 后 PUT）。换 dataKey 后旧 items.meta 解不开。

- **方案 a（推荐）：迁移完成后主动重封重传** —— 在迁移编排尾部把本地 meta 全量
  用新 dataKey 加密上传一次。语义最干净，「迁移后一切远端对象都用新 key」不变式成立。
- 方案 b：不特殊处理，完全靠 Q1a 自愈兜底（下次同步发现解不开→重建上传）。
  少一段迁移代码，但依赖自愈路径正确性，且窗口期其他设备会看到 meta 同步失败日志。

### Q3 上传触发条件细化：远端无文件且本地无任何 meta 时，要不要上传空文件？

- **方案 a（推荐）：不上传**。等首次真实元数据写入后再建立远端文件，
  减少无意义对象。
- 方案 b：首传空 `{v:1,notes:{}}` 占位，让「远端是否存在文件」成为明确的初始化信号。

### Q4 repairRemote（远端修复流程）要不要也跑 meta 同步？

- **方案 a（推荐）：不跑**。repairRemote 只管 manifest/blob 主链路；
  meta 下次常规同步自然收敛。
- 方案 b：修复成功后顺带重传 meta，缩短收敛时间但增加修复流程复杂度。

## 6. 工作量评估

约 8-10 个文件：3 个后端各 ~30 行、新模块 ~200 行、DB 层 ~80 行、
引擎集成 ~60 行、UI 刷新 ~20 行、测试若干新文件。
风险面小：全程不碰 notes 表、blob 协议、服务端三红线。

## 7. 实施结果与偏差（2026-08-26）

全部落地。验证：core 测试 483 通过 + 1 skip（真实库可选组）、
`flutter analyze` 无 error、`flutter test` 241 全过、Windows debug 构建成功。
详见 `docs/CHANGES-20260826.md`。

实施中的三处偏差（均为必要修正）：

1. **journal 缺口回归修复**：meta 段初版挂在 `sync()` 外层，其 journal 留痕晚于
   `_uploadJournal()`，造成「远端 journal 副本缺最后一条」（chaos 测试锁定不变式）。
   改为 PUT 路径内置于 `_uploadJournal()` 之前；skip-PUT 路径单独调用一次。
2. **新增 `supportsMetaObjects` 能力标志**：默认空实现的 `getMetaObject()` 返回
   null 与「远端无文件」不可区分，不支持的后端会把脏行误标 synced=1 永久丢传。
   三后端覆写为 true，引擎据此整段跳过。
3. **Q1a 自愈的物理备份简化**：不加 `backupCorruptMeta` 后端接口（三后端×小实现
   成本高），改为 journal 留痕记录字节数——自愈覆盖上传本身即消除坏文件，
   留痕足以事后诊断。

E 组（UI 刷新）经核实零改动：home 的 `_onSyncStateChanged` → `refreshNotes()`
链路已天然覆盖（meta 合并在引擎内完成后状态才发出）。
