# 评审报告：`refact-architecture-design-20260801.md` v3（G-Set 删除集合）——对照当前代码复核

- 评审对象：`docs/refact-architecture-design-20260801.md`（v3 设计评审稿，含 §12 可运行性审查）
- 评审时间：2026-08-01 17:00（本机时间）
- 评审方式：逐条对照当前工作区代码（`lib/sync/*`、`lib/data/database_handler.dart`、`lib/models/safenote.dart`、`lib/views/*`、`lib/utils/device_id.dart`、`git log/status`、`docs/CHANGES-20260801.md`）
- 结论：**方案核心（G-Set 删除集合）设计合理、方向正确、数学论证成立，值得实施；但文档的 §12「可运行性审查」基于今日 15:19 提交之前的旧代码快照，行号与存在性引用已大面积过时，且存在 1 处会导致数据不可恢复的实现细节遗漏（trash 恢复 AAD 重加密）、1 处未覆盖的新增代码（gcOrphanCandidates 两阶段 GC）、1 处虚构的现状（deleted_uuids 表）。实施前必须重新对照代码。**

---

## 1. 总体结论

### 1.1 方案核心设计：合理 ✅

| 项 | 核验结论 |
|---|---|
| G-Set 数学性质（幂等/交换/结合） | 论证正确。删除集合为 grow-only set，并集运算不依赖顺序、成功与否、时间 |
| 三条铁律（D/G/R）与 §8 对照证明 | 穷举路径充分，拦截点完整 |
| §0.1 红线澄清「单用户 ≠ 无冲突」 | 与今日 09:08 修复的 base-hash 三方合并衔接正确，未误删冲突检测 |
| 删除与内容对账解耦（步骤 3 无「删除」字样） | 成立，是结构性收益 |
| 恢复发新 uuid + blob 内容寻址 | 已核实 `_uploadNote` 用 contentHash 作为 AAD（sync_engine.dart:1473 附近），新 uuid + 相同内容 → 相同 hash → 共享 blob，互不覆盖 |
| 服务端零影响 | 成立。Go/Node 服务端把 manifest 当不透明二进制，不解析 JSON |
| SyncBackend GC 接口保留、同步路径不调用 | 接口方法（deleteBlob/listBlobs/deleteBlobSoft/listOrphanBlobs/purgeOrphans）确实存在，方案处置合理 |

### 1.2 方案文档与当前代码的脱节：🔴 严重（v3 之后代码又变了）

**关键时间线**：
- 11:58 —— 方案 v3 成稿（§12 声称「行号基于本次审查时读取的代码」）
- 15:19 —— 提交 `b382839`「移除迁移/兼容/fallback 代码」（删除 `fromLegacyMeta`、`loadFromMeta`、history 归档、v2→v3 迁移钩子 `_upgradeDB`、`openOrMemory` 内存降级等）
- 16:00 —— 提交 `bbf4ece`（authwall 修复）
- 16:46 —— 工作区尚有未提交的 DS002 修复（`gcOrphanCandidates` 两阶段 GC 候选表、`markAllSyncedExcept`、`removePendingReuploadUuids`）

**方案 v3 声称要删除、但当前代码中已不存在或从未存在的对象**：

| 方案引用 | 方案声称 | 当前代码事实 |
|---|---|---|
| `_upgradeDB`（§12.1 第 395-417 行） | 删 v1→v2 / v2→v3 迁移分支 | **不存在**。`_initDB`（database_handler.dart:229）只传 `onCreate`，无 onUpgrade，无任何迁移代码 |
| `_upgradeDBStatic`（§12.1 第 299-319 行） | 删对应测试迁移分支 | **不存在**。`_createDBStatic` 只是建表 |
| `KeyringLedger.fromLegacyMeta`（§12.1 第 246-297 行） | 删除及调用方 | **不存在**。keyring.dart 全文无此方法；已在 15:19 提交中移除 |
| 7 个 legacy meta 键（vault_id 等） | 删除 | **不存在**。MetaKeys 仅 4 键：keyring / purgedUuids / blobReuploadPending / gcOrphanCandidates |
| `deleted_uuids` 表（§3 #9、§4.2 表 3） | 「改名 deleted_items」 | **从未存在**。DB 仅 safe_notes + sync_meta 两表。该描述疑从旧设计稿继承，未对照代码 |

**行号引用全部失效**（偏差 30~200 行，v2 评审时的行号被原样保留、未按 b382839 后的代码重校）：

| 方案行号 | 当前实际 |
|---|---|
| `database_handler.dart:102`（purgedUuids） | 85 |
| `database_handler.dart:604/637/675/739`（softDelete/hardDelete/hardDeleteByUuid/restoreNote） | 526/559/599/663 |
| `database_handler.dart:690-731`（purged 方法组） | 613-655 |
| `sync_engine.dart:98/491/1958-2010`（kTombstoneGcThresholdMs/skipGc/_gcOrphanBlobs） | 97/495/2041 |
| `sync_engine.dart:1298`（_preserveConflictCopy deleted 早退） | 1420 |
| `sync_engine.dart:2164`（_hasEffectiveChange） | 2271 |
| `sync_engine.dart:1070`（_mergeAndTransfer） | 1084 |

**方案未覆盖的新增代码（DS002，当前工作区已存在）**：
- `MetaKeys.gcOrphanCandidates`（database_handler.dart:91）+ `getGcOrphanCandidates`/`setGcOrphanCandidates`（899-922）
- `markAllSyncedExcept`（789-816）、`removePendingReuploadUuids`（873-886）
- sync_engine 的 `_mergeAndTransfer` 已改为返回 record（`reuploadedOk`），`_updateLocalState` 增 `excludeSynced` 参数

> 影响：方案 §4.7 要「移除 `_gcOrphanBlobs()` 全套、listBlobs 枚举、孤儿计算」——若只删 `_gcOrphanBlobs` 而遗漏 `gcOrphanCandidates` 键与其读写方法，会留下死代码与死 meta 键；实施清单必须补充。

---

## 2. 新发现的问题（v3 未覆盖）

### P1：trash 恢复的 AAD 重加密细节缺失 🔴（可能造成恢复的笔记无法解密）

当前本地字段级加密：`_encryptField(uuid, plaintext)` 用 **uuid 作为 AAD**（database_handler.dart:178-183，`SyncCrypto.seal(dataKey, uuid, bytes)`）。

方案 §4.2 表 2：`trash_notes` 存「与 safe_notes 同一套字段级加密」的密文，并保留 `original_uuid`。
方案 §5.4：恢复时「生成**全新 uuid Y** 写入 safe_notes」。

**问题**：若实现时直接把 trash 行的密文插入 safe_notes（换 uuid 为 Y），读取时用 Y 做 AAD 解密 GCM 必然失败（密文是 X 加密的）→ 恢复的笔记**永久无法打开**，违反铁律 D。

**必须补进 §5.4 / §4.4 `restoreFromTrash`**：
1. 用 `original_uuid` 解密 trash 行 title/description → 明文
2. 用**新 uuid Y** 重新加密 → 写入 safe_notes
3. 删除 trash 行

（moveToTrash 拷贝密文不触碰明文是 OK 的，AAD 保持 original_uuid 不变；只有恢复路径需要解密→重加密。）

### P2：manifest.deleted 的带宽成本被低估 🟠

方案 §4.3 表 3 用 P3「空间不值钱」论证 deleted 集合永不裁剪（10 万条约 12MB）。但 manifest 是**每次同步全量 PUT/GET** 的（非增量）：
- deleted 集合只增不减 → **每次同步的加密体 payload 单调增长**（12MB 密文每次上传/下载）
- 对 WebDAV 公网同步、移动网络，这是**每次同步的带宽成本**，不是一次性存储成本
- P3 只覆盖了「存储」，未覆盖「每次同步的传输成本」

建议：明确接受该成本，或在 §4.3 补一句「deleted 元数据可周期性压缩为纯 uuid 集合 / 阈值裁剪（未来项）」；至少文档要承认这是每同步常数成本。

### P3：DB 版本升级的落地方式需要明确 🟠

方案 §7 说「本地 DB 遇到 oldVersion < 4 统一 drop 全部表后重建」，§12.1 说「删 _upgradeDB」。但当前 `_initDB` **本来就没有 onUpgrade 回调**（版本不符时 sqflite 会抛异常，即现有「旧库打不开」策略，见 database_handler.dart:9 注释）。

实施时**需要新增 onUpgrade**（`oldVersion < 4 → drop 全部表 + 重建`），或明确沿用「旧库打不开、用户手动删库」策略。方案把「删除迁移代码」当成了工作量，实际是要**新增**迁移处置逻辑——语义相反。

### P4：`readAllNotes` 与 `readActiveNotes` 冗余 🟡

G-Set 下 safe_notes 无墓碑行，`readAllNotes`（WHERE deleted=0，恒真）与 `readActiveNotes`（无过滤）完全等价。v2 评审 W3 已提出，v3 未合并。建议只保留一个，减少混淆。

---

## 3. 必要性评估

**有必要，是既定方向**：
- 现有删除机制 = 软删墓碑（deleted=1）+ 30 天 GC（kTombstoneGcThresholdMs）+ purged_uuids 待清理 + softDelete/hardDelete/restoreNote 三态，入站判定分支 11 条 + GC 边界情况，复杂度高、历史 bug 多（skipGc 的存在本身就是「GC 可能误删其他设备 blob」P0 风险的承认）
- CHANGES-20260801.md（09:08）明确记录用户已确认：**删除架构改造（trash_notes 替代墓碑、恢复发新 uuid、服务端真实删除）为待办**，本方案即该决定的落地
- 但注意：**方案的一部分「收益」已经被今天的提交提前实现了**——迁移分支、legacy 键、fromLegacyMeta 在 b382839 已删除；方案的剩余净收益集中在：trash/deleted_items 表、G-Set 同步算法、manifest.deleted、真删、UI 改造

## 4. 是否会引入新问题（汇总）

| # | 风险 | 级别 | 处置 |
|---|---|---|---|
| 1 | trash 恢复 AAD 不匹配 → 恢复笔记无法解密（违反 D） | 🔴 | §5.4 补充解密→重加密流程（见 §2 P1） |
| 2 | §12 行号/存在性引用过时 → 实施者按文档找代码会扑空/误删 | 🔴 | 实施前以当前工作区代码重写 §12 |
| 3 | gcOrphanCandidates 未纳入删除清单 → 死代码残留 | 🟠 | §4.7/§12.1 补充清理该键与方法 |
| 4 | manifest.deleted 全量序列化的每同步带宽成本 | 🟠 | 文档明确接受或给出裁剪预案 |
| 5 | DB v4 需要新增 onUpgrade（而非删除） | 🟠 | §7 措辞改为「新增 drop+重建 onUpgrade」 |
| 6 | readAllNotes/readActiveNotes 重复 | 🟡 | 合并为一个 |
| 7 | E36 墓碑记录 UI（deleted_items 展示区）工作量低估 | 🟡 | 已列入 §12.1，实施时注意 |

## 5. 更好的方案 / 简化建议

1. **核心思路无需更换**：G-Set 删除集合 + 本地回收站 + 真删，是单用户场景的正确模型；base-hash 冲突检测保留正确。
2. **可选的更简化项**：Q8 把 manifest.deleted 从 `uuid→timestamp` 升级为 `uuid→元数据对象`（含 deletedBy/createdBy 等）+ Q9 远端优先合并规则，是「debug 友好」增强，但同步增大了序列化体积与合并复杂度。若追求最小实现，可让**远端 deleted 保持 uuid→timestamp**（仅防复活），元数据只存本地 deleted_items 表。此为权衡项，取决于是否坚持 Q8 溯源。
3. **必须先做的修订**（阻塞开工）：
   - 以当前代码重写 §12（行号 + 存在性 + 新增 DS002 代码）
   - §5.4 补 trash 恢复「解密（original_uuid）→ 重加密（新 uuid）」流程及测试用例
   - §7 改为「新增 v4 onUpgrade drop+重建」并删除「删 _upgradeDB」等已过时表述
   - §4.7 补 `gcOrphanCandidates` 键与方法的清理
   - 测试清单补：trash 恢复后能正常解密打开（AAD 回归）；gcOrphanCandidates 清理后无残留

## 6. 结论

- **方案核心合理、数学正确、方向正确，与 base-hash 冲突修复衔接无误，服务端零影响**——值得实施。
- **但文档不能直接作为实施依据**：§12 基于 15:19 提交前的旧快照，存在性引用（迁移分支/fromLegacyMeta/legacy 键/deleted_uuids 表）与当前代码不符，行号全部失效；并遗漏了新增的 gcOrphanCandidates 代码与 trash 恢复 AAD 重加密这一关键实现细节。
- **建议流程**：先按 §5.3 修订方案（预计 1-2 小时），再以 `flutter analyze` + 全量测试为基线开工；第 1 条测试用例应包含「删除→恢复→解密打开」的端到端 AAD 回归。
