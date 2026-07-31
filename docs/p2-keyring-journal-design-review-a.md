# P2 Keyring / Journal 设计方案审查报告（对照代码基线）

> 审查日期：2026-07-31 14:46:40  
> 审查基线：`lib/sync/vault.dart` (891行)、`lib/sync/sync_models.dart` (783行)、`lib/sync/crypto.dart` (313行)、`lib/data/database_handler.dart` (902行)、`lib/sync/sync_engine.dart` (1843行)  
> 审查人：mcxiaoke（对照代码自动审查）

---

## 总体评价

设计方案方向正确，Keyring 统一密钥真相源 + Journal 操作日志的组合能有效解决 P2 的双目标（密钥态分散 + 可观测性缺失）。方案对现有架构的理解基本准确，**但存在 7 个需要修正的问题和 4 个需要明确的改进建议**。其中 **P0（关键缺陷）1 个**、**P1（重要遗漏）3 个**、**P2（改进建议）7 个**。

---

## P0 — 关键缺陷

### 1. Keyring 缺少 `dataKey` 与 `mk`，无法取代 Vault

**问题**：设计方案声称 "Keyring 取代 Vault 成为 SyncEngine 持有的钥匙对象"（§2.2），但 `Keyring` 只包含**密钥元数据**（`encryptedDataKey`、`keyFingerprint`、`keyVersion`、`dataKeyEpoch` 等），**不包含解密后的 `dataKey`（`Uint8List`）和内存中缓存的 `mk`（`Uint8List?`）**。

**代码证据**：
```dart
// vault.dart:134-195 — Vault 持有两个核心密钥
final Uint8List dataKey;       // 真正加密笔记的 32 字节密钥
final Uint8List? mk;           // 内存缓存的 Master Key
// 而 Keyring 设计（§2.1）中没有这两个字段
```

> 直接影响：
> - `SyncEngine` 的加密/解密操作需要 `vault.dataKey`（`_buildLocalManifest`、`_uploadNote`、`BlobCrypto` 等多处引用）
> - `database.setDataKey(dataKey)` 需要 Vault 注入 dataKey（`database_handler.dart:562`）
> - `changePassword` 需要旧 MK 验证 + 新 MK 重写（`vault.dart:732-784`）

**修正建议**：`Keyring` 应明确定位为 **"密钥元数据容器 + 持久化层"**，而不是 Vault 的完整替代品。推荐两种方案：

- **方案 A（推荐）**：保持 Vault 作为运行时会话对象（持有 `dataKey` / `mk`），Keyring 作为它的**元数据子对象**和**持久化入口**：
  ```dart
  class Vault {
    Keyring keyring;       // 密钥元数据（取代散字段）
    Uint8List dataKey;     // 运行时 dataKey
    Uint8List? mk;         // 运行时 MK 缓存
    // ...
  }
  ```
- **方案 B**：Keyring 也持有 `dataKey`，但必须标注 `dataKey` 不持久化（仅内存），且需更新 `fromRemoteHeader` 的签名。

**更倾向于方案 A**，因为 Vault 与 Keyring 的职责本就不同：Vault 是密钥**运行时**（derive/unwrap/seal/open），Keyring 是密钥**账本**（记录版本历史、持久化、投影）。

---

## P1 — 重要遗漏

### 2. `Keyring.fromRemoteHeader()` 无法重建 `history`

**问题**：设计方案 §2.1 的 `Keyring.fromRemoteHeader(ManifestHeader h, {Uint8List? mk})` 声称可以从远端 header 重建 Keyring，但 `ManifestHeader` **只包含当前密钥三元组，不包含历史归档**（`sync_models.dart:259-338`）。

```dart
// ManifestHeader 的 key 相关字段：
final String keyFingerprint;
final int keyVersion;
final String encryptedDataKey;
// 没有 history / 历史条目
```

**直接后果**：新设备从远端加入时，`fromRemoteHeader()` 只能填充 `current` 条目，`history: []` 始终为空。这意味着：
- 新设备无法用旧密码执行 `repairRemote`（因为缺少历史 `wrappedDataKey` 和旧 `keyFingerprint`）
- 与设计目标 G2 "修复路径更稳" 矛盾

**修正建议**：
- 承认新设备 `history` 为空是合理的设计约束（旧设备本地才有历史），在文档中明确说明
- 如需远端共享历史，需在 `Keyring.toRemoteHeader()` 中新增 `history` 投影字段（增加 manifest header 大小）
- 或者将 `history` 标记为 **local-only & best-effort** 字段

### 3. `Keyring.toRemoteHeader()` 缺少 `schemaVersion`、`dataKeyWrap` 字段

**问题**：设计签名 `toRemoteHeader({int version, int updatedAt, String lastModifiedBy})` 省略了两个必需字段：

| 缺失字段 | 在 ManifestHeader 中 | 来源 |
|---|---|---|
| `schemaVersion` | ✅ 必填 | `sync_models.dart:263`，固定为 1，未来协议迁移时递增 |
| `dataKeyWrap` | ✅ 必填 | `sync_models.dart:308`，固定为 `'AES-256-GCM'` |

**修正建议**：补充完整签名：
```dart
ManifestHeader toRemoteHeader({
  int schemaVersion = 1,
  int version,
  int updatedAt,
  String lastModifiedBy,
  String dataKeyWrap = 'AES-256-GCM',
});
```

### 4. Journal 崩溃恢复与现有 SQLite 事务安全存在职责重叠

**问题**：设计 §3.5 通过 journal 的 `key.migrate(start/done)` 标记实现崩溃重放。但 `reEncryptAllNotes` **已经具有 SQLite 事务级 crash 安全**（`database_handler.dart:628-688`）：

```dart
// 已有的事务安全分析（database_handler.dart:620-624）：
// 如果在步骤 3 crash：SQLite 事务回滚，数据库仍为旧密文
// 如果在步骤 4 crash：数据库已更新为新密文，但 _dataKey 还是 oldKey，
//   下次登录时 Vault.unlockLocal 会用密码重新派生 dataKey，状态恢复一致
```

**问题分析**：
- Journal 和 SQLite 事务提供了两套 crash recovery 机制，复杂度叠加
- 如果两套机制不一致（journal 说 `start` 但事务已回滚），会产生误判
- `reEncryptAllNotes` 是唯一有批量状态的场景，现有保护已足够

**修正建议**：降低 journal 在 P2 阶段的 crash recovery 预期：
- Journal 的 core value 在 P2 是**审计/可观测性**（G3），不是 crash recovery
- 可以保留 `key.migrate(start/done)` 作为审计事件（知道"什么时候开始了迁移、什么时候完成了"），但不需要把 journal 当作 crash recovery 的触发源
- Crash recovery 仍然依赖 SQLite 事务 + Vault 重新初始化

---

## P2 — 改进建议

### 5. 元数据明文化（D1）与 Keyring 方案事实上解耦，建议拆分为独立 P3

**问题**：元数据明文化（§4）与 Keyring/Journal 没有技术依赖关系。它改动的是 manifest 的 `ManifestCrypto.serialize/deserialize` 序列化格式，影响的是所有设备间的 manifest 互通协议。而 Keyring 只影响客户端内部的密钥记账方式。

与 P0/P1 的关联也不同：Keyring 解决的是客户端 bug 根源；元数据明文化解决的是 UX（无需 dataKey 即可浏览笔记列表）和可靠性（少一层解密失败面）。

**建议**：将 D1 从 P2 中拆分，作为独立评估项。P2 聚焦 Keyring + Journal。

### 6. `dataKeyEpoch` 的语义一致性存在隐藏分歧

**问题**：`dataKeyEpoch` 出现在 3 个地方，设计文档对它们的精度要求不一致：

| 位置 | 当前语义 | 设计文档要求 |
|---|---|---|
| `KeyringEntry.dataKeyEpoch` (§2.1) | dataKey 值真变 +1 | ✅ 与代码一致 |
| `ManifestHeader.dataKeyEpoch` (§2.1 投影) | 从 current 投影 | ✅ |
| Journal entry `dataKeyEpoch` (§3.2) | 每条事件附加 | ⚠️ 设计未明确是否校验变化 |

当前代码中 `dataKeyEpoch` 的递增逻辑在 `migrateToRemote` / `migrateToRemoteVault` 中（`vault.dart:542-547`、`vault.dart:651-657`），仅当 `!_sameKey(dataKey, remoteDataKey)` 时才递增。Journal 的 `note.upsert` 事件附加的 `dataKeyEpoch` 不应参与比对——它只是记录"当时用的是哪个纪元的 dataKey"。

**建议**：在 §3.2 的 journal entry schema 说明中补充：
> `dataKeyEpoch` 仅记录，不参与 journal 内部时序判断。纪元变化判定仍以 `key.changePassword` / `key.migrate` / `key.adoptEpoch` 事件类型的顺序为准。

### 7. 阶段 1 双写的一致性问题

**问题**：设计 §5 阶段 1 提出 "sync_meta 写 keyring JSON（同时保留旧字段，双写）"。当前 `sync_meta` 表有 8 个独立 key-value 条目（`vault_id`、`encrypted_data_key`、`kdf_salt`、`key_fingerprint`、`key_version`、`data_key_epoch`、`vault_created_at`、`data_key_history`），没有原子性保障。

双写时如果部分写入成功、部分失败，会导致 meta 不一致。

**建议**：
- 阶段 1 先只写 `keyring` JSON，**读时兼容旧字段**（旧字段存在则用于构建 Keyring，keyring JSON 存在则优先用 keyring）
- 阶段 5 真正移除旧字段
- 或者将双写放入 SQLite 事务中（但 sync_meta 表操作目前不在事务中）

### 8. `KeyringEntry.wrappedByHint` 字段语义模糊

**问题**：设计 §2.1 中 `wrappedByHint` 注释为 "提示用哪个 MK 解（默认'当前密码派生'，旧条目存旧 fingerprint）"。但 `keyFingerprint` 本身就是 H(MK)，旧条目的 `keyFingerprint` 已经能标识是哪个 MK。

额外增加一个 hint 字段会带来：
- `wrappedByHint` 与 `keyFingerprint` 信息冗余
- "默认'当前密码派生'"是多语言问题（用户可能用英文界面）

**建议**：去掉 `wrappedByHint`，用 `keyFingerprint` 作为 MK 唯一标识。或者换成更明确的枚举类型（如 `KeyringChangeReason`），但不要用自由文本。

### 9. `KeyringEntry.reason` 枚举值遗漏 `changePassword` 下 dataKey 不变的场景

**问题**：reason 枚举 `'create' | 'changePassword' | 'migrateVault' | 'scenario-d'` 将两设备独立 createNew 的场景标记为 `scenario-d`。但：
- `changePassword` 时 dataKey **不变**，keyVersion +1
- `migrateVault` 时 dataKey **变化**（因为远端是不同 dataKey），dataKeyEpoch +1

当前代码中，`migrateToRemote` 和 `migrateToRemoteVault` 都追加了 `appendDataKeyHistory`。建议 reason 增加区分度：

```dart
// 建议的 reason 枚举
'create'            // 新建 vault
'changePassword'    // 改密码（dataKey 不变，keyVersion+1）
'adoptRemoteEpoch'  // 采用远端纪元（dataKey 不变，H1 场景）
'migrateDataKey'    // 迁移到不同 dataKey（scenario-d + scenario-c）
```

### 10. Keyring `history` 没有容量上限

**问题**：设计 §7 D3 提出了 "保留上限" 的开放问题但未明确。当前 `DataKeyHistory` 在 `database_handler.dart:776` 中通过 `if (list.any((e) => e['keyVersion'] == keyVersion)) return;` 仅去重，不限制数量。

如果用户频繁改密码（如测试/开发阶段），`history` 会无限增长。

**建议**：在 Keyring 中明确 `history` 上限：
- 保留最近 N 条（建议 N=10）
- 或按时间滚动（如保留 1 年内的条目）

### 11. Journal 与 `SyncEngine` 的注入点需要明确

**问题**：设计描述了 journal 应记录哪些事件，但没有说明 journal 如何注入到 `SyncEngine` 中。当前 `SyncEngine` 构造函数签名：
```dart
// sync_engine.dart:54-80
SyncEngine({
  required NotesDatabase database,
  required SyncBackend backend,
  required String deviceId,
  required Vault vault,
  // ...
});
```

Journal 需要从 `SyncEngine` 内部的多处调用：
- `_mergeAndTransfer` → `note.upsert` / `note.delete`
- `_repairBlob` / `_healBlob` → `note.heal` / `blob.reupload`
- `_executeMigration` / `_executeScenarioDMigration` → `key.migrate`
- `adoptRemoteEpoch` → `key.adoptEpoch`
- `_gcOrphanBlobs` → `sync.gcOrphan`

**建议**：在 §3.4 后增加 "集成点" 小节，明确 journal 作为 `SyncEngine` 的构造依赖：

```dart
SyncEngine({
  // ...existing fields
  required Journal journal,  // 操作日志（可选？至少 P2 阶段必填）
});
```

---

## 审查确认项（方案中正确的部分）

以下方面与代码基线一致，设计方案合理：

| # | 确认项 | 代码证据 |
|---|---|---|
| ✅ | Vault 三层信息散落诊断准确 | vaultId/dataKey/encryptedDataKey/keyFingerprint/keyVersion/dataKeyEpoch 在 `vault.dart:134-186`（内存）+ `database_handler.dart:73-92`（meta 表）+ `sync_models.dart:259-338`（header） |
| ✅ | `adoptRemoteEpoch`/`updateEncryptedDataKey` 的双向回写根源诊断正确 | `vault.dart:808-837`（adoptRemoteEpoch 整体采用三元组）、`vault.dart:787-806`（updateEncryptedDataKey 只更新单字段） |
| ✅ | `DataKeyHistory` 归档格式与 KeyringEntry 兼容 | `database_handler.dart:770-783`：`{keyVersion, wrappedDataKey, keyFingerprint}` → 可映射到 `KeyringEntry` |
| ✅ | `ManifestHeader` 明文字段与 Keyring 投影对应关系正确 | header 的 `vaultId/kdf/createdAt/encryptedDataKey/keyFingerprint/keyVersion/dataKeyEpoch` 均可从 Keyring 投影 |
| ✅ | Journal 与 manifest 的快照/事件流关系比喻准确 | manifest 是 checkpoint（5 步同步的结果），journal 是增量事件流 |
| ✅ | G6 "不碰加密格式" 的承诺在 Keyring 设计中落实 | 无一处涉及 blob 信封/AAD/KDF 改动 |
| ✅ | per-device journal 的复杂度评估合理 | 避免了全局合并 journal 的冲突合并复杂性 |
| ✅ | 5 阶段迁移路径向后兼容 | 双写 + SchemaVersion 区分新旧解析路径 |

---

## 审查结论

**方案总体可行**，但必须处理 **P0 缺陷（Keyring 无法独立取代 Vault）** 后才能进入实现阶段。P1 的三个遗漏在实现时会造成设计-实现脱节，建议在修订设计文档后一并解决。P2 的改进建议属于优化级，可在实现阶段逐步细化。

### 修订优先级

1. **P0（阻塞）**：明确 Keyring 与 Vault 的职责边界 → 推荐方案 A（Vault 持有 Keyring 子对象）
2. **P1（实现前必解决）**：补充 `fromRemoteHeader` 的 history 约束说明、补全 `toRemoteHeader` 缺失字段、重新定位 journal 的 crash recovery 角色
3. **P2（优化）**：D1 拆分、epoch 语义澄清、双写策略、hint 字段、reason 枚举、history 上限、journal 注入点

---

*审查基于 safenotes v2.3.0+10 代码基线，未覆盖测试代码和 server/ 目录。*
