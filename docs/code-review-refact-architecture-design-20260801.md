# 评审报告：`refact-architecture-design-20260801.md`（G-Set 删除集合 · 本地回收站 · 真删 · created_at 统一 INT · 设备溯源字段）

- 评审对象：`docs/refact-architecture-design-20260801.md`（v2 设计评审稿，共 941 行）
- 评审时间：2026-08-01 11:44（本机时间）
- 评审方式：逐条对照现有代码核实（`lib/sync/*`、`lib/data/database_handler.dart`、`lib/models/safenote.dart`、`lib/views/*`、`docs/sync-protocol-spec.md`、`server/`），两名子代理并行核对 DB/keyring 层与协议/测试/UI/服务端影响面
- 结论：**方案核心合理、数学正确、方向正确，推荐实施；但存在 1 处文档内部矛盾、6 处实现遗漏（其中 2 处可能违反铁律）、若干编译失败点，须修订后方可开工**

---

## 0. 总体结论

### 0.1 方案优点（确认成立）

| 项 | 核验结论 |
|---|---|
| **G-Set 数学性质** | 幂等 / 交换 / 结合律论证正确。删除集合为 grow-only set，并集运算确实「不依赖执行顺序、不依赖是否成功、不依赖时间」 |
| **三条铁律论证** | D（不丢数据）的穷举路径充分，G（无幽灵）的拦截点完整，R（机制不报废）的缓解措施到位。§8 对照证明可信 |
| **0.1 红线澄清** | 「单用户 ≠ 无冲突」，保留 base-hash 三方合并与冲突副本机制 —— 与今日刚修复的冲突判定（`docs/CHANGES-20260801.md`）衔接正确，未误删冲突检测 |
| **删除与内容对账解耦** | 步骤 3 无「删除」字样，删除处理退化为纯集合运算，是结构性收益 |
| **blob 生命周期安全** | 已核实 `_uploadNote` 用 `contentHash` 作为加密 AAD（`sync_engine.dart:1473`），故「恢复发新 uuid 且内容相同 → contentHash 相同 → AAD 相同 → blob 幂等共享」，**不会互相覆盖**。文档未显式论证此点但设计正确 |
| **服务端零影响** | Go / Node.js 服务端均把 manifest 当作不透明二进制，不解析 JSON 字段（`server/go/internal/server/handlers.go`、`server/nodejs/src/handlers.js`）。`hash`→`contentHash` 改名不影响 URL 路径参数。**文档 §12.4「后端传输层完全不变」成立** |
| **行号引用** | 文档 §12 的约 40 处行号引用经抽查全部准确（`sync_engine.dart:98/491/697/1272/1298/1958-2010`、`database_handler.dart:102/522/604/637/675/739/801` 等） |

### 0.2 必须修订后才能开工的问题（优先级排序）

| # | 级别 | 问题 | 后果 |
|---|---|---|---|
| R1 | 🔴 严重 | **文档内部矛盾**：§12.1 说删 `safe_notes.deleted` 列 + `idx_notes_deleted` + 去 `WHERE deleted = 0`；§3/§4.2/§4.4 说保留为预留列 | 实施者按哪段实现都会错一半 |
| R2 | 🔴 严重 | **schemaVersion=2 校验无实现点**。现有代码无 schemaVersion 硬校验；不校验时旧 manifest（schemaVersion=1，items 含 `deleted=true` 墓碑）会被新代码静默解析、墓碑字段被忽略 → **删除复活为活跃笔记 → 违反铁律 G** |
| R3 | 🔴 严重 | **熔断「确认应用」的持久化机制缺失**（§5.3 只说了 UI 动作，未设计 sync_meta 标记与放行逻辑） | 用户点了「确认应用」后下次同步仍会熔断，功能不可用 |
| R4 | 🟠 高 | **D 集合元数据合并优先级未定义**。`deleted_items` / `manifest.deleted` 对同一 uuid 本地与远端都有元数据时，`deleted_by`/`deleted_at`/`origin` 谁优先未说明；`INSERT OR REPLACE` 语义下「最后写入者覆盖」，重复删除会丢失首次删除者溯源 → **Q8 溯源价值受损** |
| R5 | 🟠 高 | **删除传播到无明文设备的 trash 空壳**。步骤 2 只在「本地 safe_notes 存在」时拷入 trash；B 设备若从未有 X 明文，B 的回收站无 X 记录，用户看不到「X 已被其他设备删除」 | UX 缺口 + 文档未明确此分支 |
| R6 | 🟠 高 | **`_hasEffectiveChange` 未纳入 deleted 集合比较**（`sync_engine.dart:2164-2215` 只比较 items 与 actions） | 极端场景（远端 deleted 回滚、纯墓碑）下不 PUT，远端无法修正。防御性改进，但需落实 |

---

## 1. 文档内部矛盾（R1）

| 位置 | 矛盾内容 | 建议 |
|---|---|---|
| §12.1 vs §3 简化清单 #1 | §12.1 说「删 `deleted` 列 + `idx_notes_deleted`」；§3/§4.2 表 1 说「保留为预留列 + 索引保留」 | **以 §4.2（Q8 修订）为准：保留三列预留**。§12.1 为旧稿残留，须同步修正 |
| §12.1 vs §4.4 / §3.1 | §12.1 说 `readAllNotes` 的 `WHERE deleted = 0`「去掉条件」；§4.4 说「保留」；§3.1 说「保留 WHERE deleted = 0（恒真，未来软删钩子）」 | 保留条件。§12.1 修正为与 §4.4 一致 |
| §12.1 vs §4.4 | `markAllForBlobReupload` 的 `WHERE deleted = 0` 去留同样矛盾 | 保留 |
| §12.1 sync_service 段 | 说「repairRemote 委托（492-554）内 `for (entry in items.entries)` → `for (item in items)`」；实际该遍历在 **`sync_engine.dart:694`**，sync_service 只是委托无遍历 | 归属修正到 sync_engine 段 |
| §4.4 | `softDelete(uuid)` —— 实际签名为 `softDelete(int id)`（`database_handler.dart:604`） | 签名描述修正 |
| §12.1 | `fromLegacyMeta` 行号 246-~270 —— 实际 246-**297** | 行号修正 |
| §4.2 | `getDataDataKeyHistory` —— 应为 `getDataKeyHistory`（多了个 Data） | typo 修正 |

---

## 2. 实现遗漏点（会导致编译失败或逻辑缺口）

### 2.1 编译失败点（文档 §12 未列出）

| # | 位置 | 内容 | 后果 |
|---|---|---|---|
| E1 | `database_handler.dart:594` | `updateNoteByUuid` 日志插值 `'deleted=${note.deleted}'` 访问 `SafeNote.deleted` | 模型删字段后**编译失败** |
| E2 | `test/sync/keyring_test.dart:55/750/763/776/798` | 5 处 `lastModifiedBy:` 命名参数 | 改名后**编译失败**（文档只标了 `_makeNote(deleted:false)`） |
| E3 | `test/sync/diag_baseline_integrity_test.dart:63-105` | 10+ 处 `item.hash` 断言 | 改名后**编译失败**（文档只标了 `item.deleted`） |
| E4 | `test/sync/webdav_integration_test.dart:308`、`chaos_multi_client_test.dart:154`、`longrun_persistent_store_test.dart:370` | 各 1 处 `lastModifiedBy:` | **编译失败** |
| E5 | `test/sync/p0p1_self_heal_test.dart`、`change_password_multi_client_test.dart:395/715`、`safe_server_integration_test.dart`、`chaos_multi_client_test.dart:484/709`、`longrun_persistent_store_test.dart:569`、`keyring_test.dart:630` | `readAllNotesIncludingDeleted` 调用 | 方法改名后**编译失败**（文档清单覆盖不全） |
| E6 | `lib/views/deleted_notes.dart:34/191` | `List<SafeNote>` / `final SafeNote note` 类型 | 需改为 `TrashNote`，否则**编译失败** |

### 2.2 逻辑 / 语义缺口（R2–R6 之外）

| # | 位置 | 内容 | 建议 |
|---|---|---|---|
| E7 | `note_view.dart:144` | `widget.noteId` 是 `int`，`moveToTrash` 需 `uuid` + `deviceId`；文档未说明需先 `readNote` 取 uuid | 实施步骤补充「先取 note 再 moveToTrash」 |
| E8 | `deleted_notes.dart:203` | 展示用 `note.updatedAt`，回收站应按 `deleted_at` 倒序展示删除时间 | 语义修正 |
| E9 | `database_handler.dart:502-513` | `existsContentHash` 注释为「含墓碑」查询，G-Set 下 safe_notes 无墓碑后**自动降级为仅活跃查询**；被 `sync_engine.dart:1421`（冲突副本标题 hash 探测）使用 | 文档补充说明此语义变化（无代码改动） |
| E10 | `home.dart:483`、`drawer.dart:34/44/139/144` | `onDeletedNotesCallback` / `DeletedNotesPage` 命名保留 | 若不改类名则无影响，文档应明确「回收站页类名保留」 |

### 2.3 注释 / 文档引用遗漏（不影响编译，影响维护）

- `lib/utils/device_id.dart:5`、`sync_engine.dart:36/72`、`sync_models.dart:6/30/418`、`deleted_notes.dart:7-14` 文件头注释 —— 含 `lastModifiedBy` / 墓碑 / 30 天 GC 等旧语义，须同步更新。
- `keyring.dart:200` `kKeyringSchemaVersion`、`journal.dart:63/664` `kJournalSchemaVersion` —— 是 **keyring / journal 各自的独立版本号**，与 manifest `schemaVersion` 无关，**不受影响**；文档应注明避免实施时误改。

---

## 3. 设计层面需确认的新问题 / 权衡（R3–R6 详述）

### 3.1 R3：schemaVersion=2 校验必须落到实现步骤

文档 §4.6 说「读到 ≠2 直接报错」，§7 说「读到 ≠ 2 → 直接报错要求清空重来」，但 §9 实施步骤与 §12 可运行性审查均**未列出校验实现点**。现有代码链（`ManifestHeader.fromJson` 对 schemaVersion 缺省为 1，`sync_service` 读 manifest 后无校验）不会拦截旧 manifest。若不补：
- 旧 manifest（items 含 `deleted=true` 墓碑）→ 新代码 fromJson 忽略 `deleted` → **墓碑被当活跃笔记下载 → 违反铁律 G（已删笔记复活）**。
- 这是 P4「一刀切」策略生效的前提，必须显式列入 §9 步骤（建议在 `sync_service.sync()` 与 `repairRemote()` 的 `deserialize` 后校验 `schemaVersion == 2`，不等则报错中断）。

### 3.2 R4：熔断「确认应用」的持久化机制

§5.3 只描述 UI 行为。缺失：
- 放行标记存哪？（建议 `sync_meta` 新增键，如 `delete_circuit_breaker_release:<providerKey>`）
- 「放行一次」的判定：下次同步读标记 → 跳过熔断检查 → 应用后清除标记？
- 被放行的 uuid 应用后移入 trash、不再活跃 → 不再触发熔断，标记可清除。
- 需在测试清单补充「熔断 → 确认应用 → 下次同步真正放行」用例。

### 3.3 R5：D 集合元数据合并优先级（溯源失真）

`deleted_items` 表与 `manifest.deleted` 都是「uuid → 元数据」。同一 uuid 本地与远端各有元数据时合并规则未定义；`INSERT OR REPLACE` 语义下后写者覆盖先写者。后果：
- A 删 X（`deleted_by=A`）→ B 同步（B 的 `deleted_items` 记 `deleted_by=A`）→ B 又删 X（本地事务 `INSERT OR REPLACE` → `deleted_by=B` 覆盖）→ 溯源丢失「首次删除者是 A」。
- 建议明确：**远端 deleted 元数据优先（全局真相），本地缺省填充缺失字段**；`moveToTrash` 对已存在于 `deleted_items` 的 uuid 保留原 `deleted_by`/`deleted_at`，仅补 `origin`。
- 顺带：`deleted_items.origin` 单值同样存在「先 remote 后 local」覆盖问题，语义需定义为「首次来源」。

### 3.4 R6：删除传播到无明文设备的回收站空壳

文档 §2.2 步骤 2 明确「本地 safe_notes **若存在** → 内容拷入 trash」。由此推断：
- 从未持有 X 明文的设备，删除传播只写 `deleted_items` 墓碑，**trash 无行** → 该设备回收站为空，用户无法得知「X 已在别处被删除」。
- 这不违反铁律 D（D 只依赖删除发起设备的 trash，§4.8 已声明），但**是 UX 缺口**：用户以为笔记「神秘消失」。建议：回收站 UI 补充展示「来自 deleted_items 的删除记录（无内容，注明已删除）」；或至少文档明确此行为。
- `trash_notes.title/description NOT NULL` 与「无明文可拷」分支需对应调整（该分支不写 trash 行，不冲突，但文档应显式写出）。

### 3.5 R6 补充：`_hasEffectiveChange` 需比较 deleted 集合

现有 `_hasEffectiveChange`（`sync_engine.dart:2164-2215`）比较：epoch、actions、remote==null、header 关键字段、items。**未比较 `merged.deleted` 与 `remote.deleted`**。新方案下建议增加：
```
if (merged.deleted.length != remote.deleted.length) return true;
for (final k in merged.deleted.keys) { if (merged.deleted[k] != remote.deleted[k]) return true; }
```
虽多数删除场景被 items 差异覆盖（本地删 → safe_notes 无行 → items 键集变），但「远端 deleted 被回滚且 items 恰好一致」等场景依赖此比较才能触发修正 PUT。

---

## 4. 协议文档修订面扩大（§12.4 低估）

`docs/sync-protocol-spec.md` 中除 §12.4 提到的 §5.2、§8.3 外，以下章节同样描述旧语义，需一并修订：

| 章节 | 内容 | 修订点 |
|---|---|---|
| §3 存储模型 | 第 72 行「服务端不清理孤儿 blob、不删除墓碑」 | 补「blob 永不删除（G-Set）」语义 |
| §5 JSON 示例 | 第 184-203 行 items 内嵌 `deleted:true/false`、无 deleted map | 改 `contentHash`/`createdBy`，增独立 `deleted` map 示例 |
| §5.1 items 字段说明 | 第 213 行「包含墓碑」 | 改为「不含墓碑，已删除项在独立 deleted map」 |
| §5.2 ManifestItem 字段表 | 第 217-222 行仅 hash/deleted/updatedAt | 完整重写：去 deleted、hash→contentHash、增 createdBy/contentSize/blobKeyEpoch |
| §5.3 加密说明 | 仅描述 items 加密 | 补「加密体含 items + deleted」 |
| §8.1 主流程 | 未含 G-Set 删除前置步骤 | 补三步算法 |
| §8.3 墓碑处理 | 第 348-354 行整体 | 替换为 G-Set 删除集合语义 |
| §12.1 测试描述 | 第 408 行「覆盖 LWW/墓碑/乐观锁」 | 改为 LWW/G-Set 删除 |
| （新增） | schemaVersion、deleted map / DeletedMeta | 协议文档目前完全缺失，需新增描述 |

`server-api-spec.md` **无需修订**（服务端零知识，不解析 manifest），其 12.2 节测试场景「墓碑传播」属客户端行为描述，可保留或移到客户端协议文档。

---

## 5. 测试影响面补充

### 5.1 文档 §12.3 清单之外需注意的断言

- `sync_engine_test.dart` 等文件的 `result.deleted` 断言属于 `SyncResult.deleted`（**保留项**），此类用例**不应删除**，应核对语义后保留。
- `journal_test.dart:773` `syncGcOrphan` wire 断言删除 —— 已列入，确认准确。

### 5.2 建议新增测试（补文档 §10 未覆盖的）

| # | 测试 | 对应缺口 |
|---|---|---|
| T1 | schemaVersion=1 旧 manifest → 同步报错中断、零变更 | R2 |
| T2 | 熔断 → 点「确认应用」→ 下次同步放行并应用 | R3 |
| T3 | 同一 uuid 跨设备重复删除 → `deleted_by` 保留首次删除者 | R4 |
| T4 | 删除传播到从未持有该笔记的设备 → trash 无行、deleted_items 有墓碑、回收站 UI 正确提示 | R6 |
| T5 | E17 复活窗口内用户编辑 → 内容进 trash 不丢 | W2 |
| T6 | 远端 deleted 回滚且 items 一致 → 触发修正 PUT | R6 |

---

## 6. 设计权衡提示（非阻断）

| # | 权衡 | 说明 |
|---|---|---|
| W1 | **G-Set 让「彻底删除」不可能** | 恢复强制发新 uuid + 墓碑永久 → 用户无法「清除删除痕迹」。对安全笔记类应用属隐私权衡，需用户知情（删 = 归档）。文档已隐含此意（§5.4），建议在 README/UI 注明 |
| W2 | **E17 是唯一有损场景** | 「短暂复活后自愈」，逻辑正确但需测试覆盖复活窗口内的编辑不丢 |
| W3 | `readAllNotes` vs `readActiveNotes` 语义重复 | 两者在 G-Set 下都读全部活跃行，建议只留一个，减少混淆 |
| W4 | manifest.deleted 全量序列化 | 删除量大时 manifest 加密体膨胀（10 万条删除 ≈ 12MB/设备）。P3 接受，但 `_hasEffectiveChange` 需避免无谓 PUT 放大 |
| W5 | 熔断「状态完全未变」断言 | 严格不成立：被熔断 uuid 若本地被编辑，其 `updatedAt`/hash 会变。文档表述宜限定为「未触碰时不变」 |

---

## 7. 结论与建议

**总体判断**：以 G-Set 只增集合替换墓碑 + GC + purged 的复杂机制，是正确且克制的一步。三条铁律论证可信、与 base-hash 冲突修复衔接正确、服务端零影响、blob 内容寻址 + AAD=contentHash 的既有设计天然兼容恢复发新 uuid。**方案值得实施。**

**开工前必修（阻塞）**：
1. 统一 §12.1 与 §4.2/§4.4 的 `deleted` 列 / `WHERE deleted = 0` 矛盾（R1）
2. 将 schemaVersion=2 校验显式列入 §9 实施步骤（R2）
3. 设计熔断放行标记的持久化与读取（R3）
4. 定义 D 集合元数据合并优先级（R4）

**开工前应补（重要）**：回收站空壳 UX 与 `_hasEffectiveChange` deleted 比较（R5/R6）、§12.3 测试清单补 `lastModifiedBy`/`item.hash`/`readAllNotesIncludingDeleted` 引用、`database_handler.dart:594` 日志字段、协议文档 §3/§5/§8 修订面。

**验证充分性**：文档 §10 的 20 条测试清单方向正确，按上表 T1–T6 补充后即可覆盖新增缺口。
