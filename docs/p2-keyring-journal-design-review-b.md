# P2 设计文档审查报告：Keyring 密钥环模型 + Journal 操作日志

> 审查对象：`docs/p2-keyring-journal-design.md`（草案）
> 审查基线代码：`lib/sync/vault.dart`、`lib/sync/sync_models.dart`、`lib/sync/crypto.dart`、`lib/sync/sync_engine.dart`、`lib/data/database_handler.dart`、`docs/server-api-spec.md`
> 审查结论：**方向正确、目标合理，但存在 2 个致命（Critical）缺陷 + 2 个高优（High）缺陷，需在进入实现前修正**；否则 `Keyring 取代 Vault` 无法落地，且会重新引入其声称要修复的纪元回滚 bug。
> 审查方法：逐节对照设计描述与现行代码实现，逐条核验"声称的映射/收益/流程"是否成立。

---

## 0. 总体评价

| 维度 | 评价 |
|---|---|
| 问题诊断（G1 密钥态分散） | ✅ 准确。现行 `Vault`（内存+`sync_meta`）、`ManifestHeader`（远端投影）、`DataKeyHistory`（`sync_meta.data_key_history`）三处确实靠 `adoptRemoteEpoch`/`updateEncryptedDataKey`/`appendDataKeyHistory` 互相同步，历史 bug（BUG-3/H1/B1-2）的根因描述与代码注释一致。 |
| G1 统一为 Keyring | ✅ 方向正确，收益真实。 |
| Keyring 结构本身 | ❌ **致命遗漏**：缺少运行时明文 `dataKey` 与 `mk` 的承载，且 `fromRemoteHeader` 收了 `mk` 却无处存放。 |
| `adoptRemoteEpoch` 简化 | ❌ **致命缺陷**：`current = KeyringEntry.from(remote)` 会抹掉内存态 raw dataKey，与修复目标相悖。 |
| 重构范围 | ❌ 高优遗漏：`sync_engine.dart`、`database_handler.dart` 是 Vault 的真正消费方，设计未列入重构范围。 |
| Journal 存储与定位 | ⚠️ 高优：本地存储机制未定义；"远端 `journal/` 目录"与"本地先落地"主次表述矛盾。 |
| 元数据明文化（§4） | ⚠️ 中等：两个候选方案自相矛盾，表述需澄清。 |
| 测试/兼容性 | ⚠️ 中等：现有 Vault 测试与双写期权威性的描述存在不一致。 |

---

## 1. 致命问题（Critical — 必须修正）

### C1. `Keyring` 模型不承载内存态的明文 `dataKey` 与 `mk`，"取代 Vault" 后无法加解密

**设计原文（§2.1）**：`Keyring` 仅含 `vaultId / kdf / createdAt / current / history`；`KeyringEntry` 仅含 `keyFingerprint / encryptedDataKey / keyVersion / dataKeyEpoch / wrappedByHint / archivedAt / reason`。`fromRemoteHeader(ManifestHeader h, {Uint8List? mk})` 把 `mk` 作为参数传入。

**现行代码事实**：
- `Vault` 持有两个**内存态、不持久化**的关键密钥：`dataKey`（`Uint8List`，32 字节，真正加解密笔记与 blob 的钥匙，`vault.dart:139`）、`mk`（`Uint8List?`，当前会话派生的主密钥，`vault.dart:194`）。
- `SyncEngine` 通过 `get _dataKey => vault.dataKey`（`sync_engine.dart:114`）取得 raw dataKey，喂给 `SyncCrypto.seal/open` 与 `database.reEncryptAllNotes`。
- `database_handler.dart` 的 `_requireDataKey`、`setDataKey`、`reEncryptAllNotes`（`database_handler.dart:103,117,628`）全部依赖这个 raw dataKey。
- 远端的 `ManifestHeader` **只含 `encryptedDataKey`（被 MK 包裹的密文），不含 raw dataKey**。raw dataKey 只能在本地用 `mk` 解开 `encryptedDataKey` 后获得。

**矛盾**：
1. 提议的 `KeyringEntry` 只有 `encryptedDataKey`（包裹态），**没有任何字段放 raw `dataKey`**。因此 `SyncEngine` 没有等价 `vault.dataKey` 的访问来源——设计里 `Keyring 取代 Vault 成为 SyncEngine 持有的钥匙对象` 之后，引擎将**无法加解密任何笔记/blo**。
2. `fromRemoteHeader` 虽然收了 `Uint8List? mk` 参数，但 `Keyring` 类**没有 `mk` 字段**来保存它——即便传进来也无处安放，更无法用它解出 raw dataKey 暂存。
3. `persist(NotesDatabase db)` 持久化的是包裹态（与 Vault 现状一致：raw dataKey 不落盘），这本身没问题；但设计**完全没有说明 raw dataKey / mk 在运行时的归属**，而这两者恰恰是 Vault 存在的根本理由。

**必须修订**：在 `Keyring`（或显式持有的 `SessionKey`）中增加**非持久化**的运行时字段：
```dart
class Keyring {
  // 持久化部分（写 sync_meta 的单个 keyring 键）
  final String vaultId;
  final KdfParams kdf;
  final int createdAt;
  final KeyringEntry current;        // 包裹态
  final List<KeyringEntry> history;  // 包裹态归档

  // 运行时部分（unlock 时由 mk 解开 current.encryptedDataKey 得到，登出清空，不落盘）
  final Uint8List dataKey;           // ← 设计缺失：加解密笔记/blo 的唯一钥匙
  final Uint8List? mk;               // ← 设计缺失（即使 fromRemoteHeader 已收参却无处存）
  ...
}
```
并明确：`persist` 只写包裹态；`fromRemoteHeader`/`unlockLocal` 在构造后必须用 `mk` 解开 `current.encryptedDataKey` 把 `dataKey` 填上。否则 §2.2/§2.3 的所有 `createNew/changePassword/migrate/adoptRemoteEpoch` 都没有可操作的密钥对象。

---

### C2. `adoptRemoteEpoch → current = KeyringEntry.from(remote)` 会丢失 raw dataKey，重新引入纪元回滚 bug

**设计原文（§2.2 / §2.3）**：
- 映射表：`Vault.adoptRemoteEpoch()` → `直接 current = KeyringEntry.from(remote)`。
- §2.3：「`adoptRemoteEpoch`：单行 `current = ...`，杜绝 BUG-3」。

**现行代码事实**（`vault.dart:820-837`）：`adoptRemoteEpoch` 只更新**包裹态三元组 + 纪元**——`encryptedDataKey / keyFingerprint / keyVersion / dataKeyEpoch`——**刻意不碰 raw `dataKey`**（注释明确：dataKey 不变，只 wrap 它的 MK 变了）。因为此时本地已经用新密码登录、`mk` 能解开远端 `encryptedDataKey`、且 `dataKey` 本就与远端一致（H1 分支）。

**矛盾**：`KeyringEntry.from(remote)` 只能产出**包裹态**条目（远端 header 无 raw dataKey）。若 `current = KeyringEntry.from(remote)`，新 `current` 的 raw dataKey 为空 → `SyncEngine._dataKey` 取不到值 → 后续所有笔记加解密失败；更严重的是，在没有 C1 修复的前提下，这种"整条目替换"恰恰丢掉了本地唯一的 raw dataKey。这与设计"杜绝 BUG-3"的承诺**直接冲突**——BUG-3 的根因正是"本地 keyVersion 落后导致每次同步误报他端改密码 + 构建 header 时回滚远端纪元"，而正确的修复（现状代码已做到）是**只更新包裹/纪元字段、保留 raw dataKey**，而非整条目替换。

**必须修订**：`adoptRemoteEpoch` 的等价实现应为**字段级更新**而非整条目替换：
```dart
// 仅更新包裹态与纪元，保留内存态 dataKey / mk 不变
current = current.copyWith(
  encryptedDataKey: remote.encryptedDataKey,
  keyFingerprint: remote.keyFingerprint,
  keyVersion: remote.keyVersion,
  dataKeyEpoch: remote.dataKeyEpoch,
);
// dataKey / mk 保持原值（改密码场景 dataKey 值未变）
```
并删除 §2.2/§2.3 中"`current = KeyringEntry.from(remote)`"的表述，改为"更新 current 的包裹/纪元字段，保留内存 dataKey 与 mk"。

---

## 2. 高优问题（High — 实现前需澄清）

### H1. 重构范围遗漏真正的 Vault 消费方：`sync_engine.dart` 与 `database_handler.dart`

**设计原文（§0 代码基线）**：仅列 `lib/sync/vault.dart`、`lib/sync/sync_models.dart`、`lib/sync/crypto.dart`。

**事实**：Vault 的**编排与消费**几乎全部在 `sync_engine.dart` 与 `database_handler.dart`：
- `sync_engine.dart` 持有 `Vault vault`（`sync_engine.dart:66`），并通过 `vault.dataKey / vault.keyVersion / vault.adoptRemoteEpoch / vault.changePassword / vault.migrateToRemote / vault.migrateToRemoteVault / vault.checkMigrationNeeded / vault.kdf` 等大量调用（例如 `:114,256,266,358,375,761,788`）。
- `database_handler.dart` 维护 `Uint8List? _dataKey`（`:103`）、`setDataKey`（`:117`）、`reEncryptAllNotes`（`:628`）、`appendDataKeyHistory`/`getDataKeyHistory`（`:770,786`）、以及 `MetaKeys`（`:73-92`）中一整套 `vault_id/encrypted_data_key/kdf_salt/.../data_key_history` 键。
- `migrateToRemote` 返回新 `Vault` 后，引擎必须 `vault = await vault.migrateToRemote(...)`（`:761`）替换引用；`changePassword` 同样返回新实例，调用方必须更新持有的 Keyring 引用——设计未说明。

**修订建议**：§0 代码基线补充 `lib/sync/sync_engine.dart`、`lib/data/database_handler.dart`；§5 迁移阶段补一条"`SyncService`/引擎中对 `vault.xxx` 的全部引用改为 `keyring.xxx`，并在 `changePassword`/`migrate*` 后更新持有引用"。

### H2. Journal 本地存储机制未定义；"远端目录"与"本地先落地"主次矛盾

**设计原文（§3.3）**：
- 开头：「落后端子目录 `journal/`（与 `manifest-backup/`、`blobs-orphan/` 同源，统一由 v2.2 `/api/v2/resources/<path>` 的 `move/mkdir/propfind` 管理）」。
- 随后：「先实现**每设备本地 journal**，远端仅作可选归档副本」「首版采用 per-device 本地 journal + 可选远端归档」。

**事实核对**：
- 远端 `journal/` 目录方案**技术上可行**——`server-api-spec.md §5.10` 确实提供 `resources/<path>` 的 `move/mkdir/copy/propfind`，且 `blobs-orphan/`、`manifest-backup/` 已落地（`local_fs_backend.dart:200,269` / `safe_server_backend.dart:409,562` / `webdav_backend.dart:437,568`），journal 走同机制无障碍。
- 但"**本地** journal"的存储载体**完全未指定**。三个 backend（LocalFS/WebDAV/SafeServer）都是**远端**后端；本地 journal 应落在设备自身。可选载体有：①新建 `sync_meta` 键（如 `journal_log`，但 JSON 大文件不适合单键频繁 append）；②新增一张本地 SQLite 表；③`path_provider` 指向的 App 沙盒文件（与 `blobs-orphan` 本地落盘思路一致）。设计未做选择，也未说明滚动阈值（D5 虽列为开放问题，但载体选择应先行）。

**修订建议**：
1. 明确"本地优先、远端可选"为唯一主线，删去 §3.3 开头把 `journal/` 远端目录作为默认落点的表述，避免与后文矛盾。
2. 明确本地载体（建议：App 沙盒下的 `journal/log.json`，复用 `path_provider`，与现有 blob 本地物化一致；或新增本地表）。
3. 给出首版滚动阈值（D5 的临时默认值，如单文件 4096 条或 1MB）。

---

## 3. 中等问题（Medium）

### M1. §4 元数据明文化的两个候选方案自相矛盾
§4 结论写道：「manifest items 改明文 JSON，但**整体 manifest 仍由 dataKey 做一次信封（即保留现有 `[头长][header][AES-GCM(...)]` 外壳，仅把 items 内部从"加密体"改为"明文体"**），或彻底明文 + header 内嵌 HMAC-SHA256」。
这两者互斥：「AES-GCM 信封」本身就是对 body 的加密，"把 items 内部改为明文体"与"保留 AES-GCM 外壳"无法同时成立。现行 `ManifestCrypto.serialize`（`sync_models.dart:701-719`）是 `[4字节头长][header明文][AES-GCM(dataKey, items)]`。
**建议**：把两个方案拆清楚——方案 A：body 仍 AES-GCM，只是把"AAD/封装结构"调整（等于现状，无收益，应排除）；方案 B：body 改明文 JSON，保留 `[头长][header][body]` 框，完整性由 header 内 HMAC 或整体信封保证；方案 C：彻底明文 + header HMAC。让 D1 在 B/C 间二选一，删除自相矛盾的描述。

### M2. `reEncryptAllNotes` 的 journal 角色被夸大
§3.1/§3.5 把 journal 描述为 `reEncryptAllNotes` 崩溃安全的"重放/回滚"层。但现行 `reEncryptAllNotes`（`database_handler.dart:628-688`）已在**单个 SQLite 事务**内一次性写回（`db.transaction(...)`，`:663`），崩溃即整体回滚，DB 始终一致；即便中途崩溃，重跑也只是用当前 DB 明文重新加密一遍（幂等）。journal 此处**仅是诊断/可观测层**，并非安全保障。
**建议**：§3.5 把"重放剩余批次或整体回滚"改为"崩溃重启后 journal 仅用于诊断：扫描未完成 `key.migrate(start)` 条目以告警/审计，实际安全由事务回滚保证"，避免夸大并误导实现优先级。

### M3. `mk` 生命周期与改密码后引用更新未说明（叠加 C1）
`Vault.changePassword`（`vault.dart:732-785`）返回的新 Vault 持有**新 `mk`（newMk）**；`migrateToRemoteVault` 持有 `remoteMk`。设计在 §2.3 changePassword 只说"生成新 current（keyVersion+1…）"，**未提 `mk` 必须随之更新**，也未提调用方需替换持有的 Keyring 实例。结合 C1，若 Keyring 增加 `mk` 字段，则 changePassword 必须更新该字段，且 `SyncService` 需更新引用。
**建议**：在 §2.3 changePassword 与迁移流程中明确 `mk` 更新点，并在 §5 增加"持有方引用替换"步骤。

### M4. §5 双写期权威性与 §9 风险描述不一致
§5 阶段1：「`sync_meta` 写 `keyring` JSON（**同时保留旧字段，双写**）」。§9 风险「双写期 meta 不一致」却说：「阶段 5 清理前**以 keyring 为权威，旧字段仅读不写**」。两者冲突：双写意味着旧字段也要写；又一处说旧字段仅读不写。
**建议**：统一为——双写阶段"写 keyring 为权威写入，旧字段为兼容**镜像写入（由 keyring 派生）**；阶段5清理前以 keyring 为唯一权威读取源，旧字段不再作为独立写入入口"。

---

## 4. 轻微问题（Low）

- **L1 — 新字段在 legacy 数据无来源**：`KeyringEntry.reason / archivedAt / wrappedByHint` 在现行 `appendDataKeyHistory`（仅存 `keyVersion/wrappedDataKey/keyFingerprint`，`database_handler.dart:770-783`）中无对应。迁移旧 `data_key_history` 到 `Keyring.history` 时，这些字段需给默认值（`reason='unknown'`、`archivedAt=0`、`wrappedByHint=null`）。设计应补充迁移默认值。
- **L2 — `wrappedByHint` 冗余**：其语义（"提示用哪个 MK 解"）已由历史条目的 `keyFingerprint` 覆盖（`repairRemote` 正是用 `keyFingerprint` 匹配旧密码派生 MK，`sync_engine.dart:562-585`）。可省去 `wrappedByHint`，复用 `keyFingerprint`。
- **L3 — `toRemoteHeader` 参数缺失**：签名只收 `version/updatedAt/lastModifiedBy`，但 `ManifestHeader` 还需 `createdAt`（`Keyring.createdAt`）、`kdf`（`Keyring.kdf`）、`dataKeyWrap`（常量 `kDataKeyWrapAlgorithm`）。投影时应从 Keyring 取这些字段，否则生成 header 不完整。
- **L4 — 测试迁移未提**：§8 列了 Keyring/Journal 单测，但现有 Vault 测试（如 `test/` 下）需随重构改写；且 `fromRemoteHeader`/`unlockLocal` 的 keyring 重建路径需新增兼容旧 `sync_meta` 字段的测试。建议 §8 补"现有 Vault 测试迁移计划"。
- **L5 — §4 表述夸大**：「items 解密失败 → 整个 manifest 解析失败（单点放大）」——实际上 `deserialize` 先解 header 明文、后解 items（`sync_models.dart:728-759`），items 解密失败仅发生在"dataKey 错误"的异常场景（如 repair 用错密码），并非日常单点失败。建议改为"仅当 dataKey 错误时 items 解析失败，属预期内的鉴权失败，非日常单点放大"。

---

## 5. 验证成立、设计正确的部分（可在评审中确认保留）

- **G1 三处密钥态分散的诊断正确**，且 `adoptRemoteEpoch`/`updateEncryptedDataKey` 的"包裹/纪元字段级更新、不动 raw dataKey"实现正是当前修复 BUG-3/H1/B1-2 的正确手法（见 `vault.dart:808-837` 注释），Keyring 应**继承**而非破坏这一不变量。
- **G4 元数据不再二次加密的逻辑可行**：`ManifestCrypto` 已是 `[header明文][body]`，改 body 为明文不影响 header 解析路径。
- **G6 不碰 blob 信封/AAD/KDF**：设计明确只重组"密钥与事件的容器"，与 `crypto.dart` 信封格式解耦，成立。
- **Journal 远端 `journal/` 目录方案技术上可行**（见 H2 核对），且"per-device 本地 + 可选远端归档"的取舍方向正确（降低合并冲突复杂度）。
- **迁移分阶段 + `schemaVersion` 区分新旧解析路径**的策略稳健，与现有 manifest 兼容性做法一致。

---

## 6. 修订清单（给作者的 actionable checklist）

- [ ] **C1**：在 `Keyring` 增加非持久化运行时字段 `dataKey`（Uint8List）与 `mk`（Uint8List?）；明确 `persist` 只写包裹态，`unlock*/fromRemoteHeader` 负责用 mk 解开 `current.encryptedDataKey` 填充 `dataKey`。
- [ ] **C2**：将 `adoptRemoteEpoch → current = KeyringEntry.from(remote)` 改为**字段级更新**包裹/纪元，保留 raw dataKey 与 mk；删除整条目替换表述。
- [ ] **H1**：§0 基线补 `sync_engine.dart`、`database_handler.dart`；§5 补"引擎/DB 对 vault 的全部引用改 keyring + 持有引用更新"步骤。
- [ ] **H2**：明确本地 journal 载体（沙盒文件/本地表）与首版滚动阈值；统一"本地优先"主线，修正 §3.3 开头把远端目录当默认落点的表述。
- [ ] **M1**：拆分 §4 两个互斥方案，删除自相矛盾句，让 D1 在"body 明文+HMAC"与"彻底明文+HMAC"间二选一。
- [ ] **M2**：§3.5 把 journal 在 `reEncryptAllNotes` 中的角色降为"诊断/可观测"，点明事务回滚才是安全保证。
- [ ] **M3**：§2.3 changePassword/迁移流程补 `mk` 更新点 + 持有方引用替换。
- [ ] **M4**：统一双写期"keyring 权威写入、旧字段镜像写入；清理前 keyring 唯一读源"的表述。
- [ ] **L1-L5**：补 legacy 字段默认值、去除冗余 `wrappedByHint`、补全 `toRemoteHeader` 字段、补测试迁移、修正 §4 单点失败表述。

---

## 7. 结论

方案**目标与方向值得推进**：统一密钥真相源（G1）、引入操作日志提升可观测与可审计（G2/G3）是真实收益，且"不碰 blob 格式/KDF"（G6）的约束把握准确。但当前草案在**最关键的密钥承载模型**上存在结构性缺陷——`Keyring` 没有运行时 raw `dataKey`/`mk` 的落点，且 `adoptRemoteEpoch` 的简化写法会抹掉 raw dataKey、重新制造其声称要消灭的纪元回滚 bug。这两点（C1/C2）不修正，`Keyring 取代 Vault` 在技术上无法成立。建议按第 6 节清单修订后再进入实现评审。
