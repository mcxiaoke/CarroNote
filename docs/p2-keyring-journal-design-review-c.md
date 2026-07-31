P2 设计文档审查报告

### 审查范围

- `docs/p2-keyring-journal-design.md`：Keyring 密钥环模型 + Journal 操作日志设计文档
- 对比代码：`lib/sync/vault.dart`、`lib/sync/sync_models.dart`、`lib/sync/crypto.dart`、`lib/sync/sync_engine.dart`

### 核心发现

#### 1. Keyring 设计问题

**问题 1：Keyring 定义缺少 `dataKey` 字段**
- 设计文档的 `KeyringEntry` 包含 `encryptedDataKey` 但不包含明文 `dataKey`
- 当前 `Vault` 类持有 `Uint8List dataKey`（`vault.dart:139`）供 `SyncEngine` 的 `_dataKey` getter 使用（`sync_engine.dart:114`）
- 建议：`Keyring` 或 `KeyringEntry` 应明确持有 `Uint8List dataKey`

**问题 2：`Keyring` 与 `Vault` 的职责边界不清**
- 文档说 `Vault` "可保留为薄封装或逐步废弃"，但 `Vault` 当前承担了：
  - 解锁逻辑（`createNew`/`unlockLocal`/`unlockFromRemoteManifest`）
  - 迁移逻辑（`migrateToRemote`/`migrateToRemoteVault`/`checkMigrationNeeded`）
  - 密码验证（`verifyPassword`）
  - `tryDeriveRemoteDataKey`（场景 d 判别）
- 这些都是有状态的异步操作，与 `Keyring` 的"纯数据容器"定位不同

**问题 3：`Keyring.fromRemoteHeader` 需要 `mk` 参数但文档未说明无 MK 场景**
- 新设备首次加入时没有 MK，`Keyring` 应该是什么状态？文档未说明

**问题 4：`wrappedByHint` 字段语义不够精确**
- `wrappedByHint` 描述为"提示用哪个 MK 解"，但 `keyFingerprint` 已经是 `H(MK)`
- 如果两者存储相同的值存在冗余；如果不同，文档未说明差异场景

#### 2. Journal 设计问题

**问题 5：Journal 条目结构缺少必要的错误恢复字段**
- `key.migrate(start)` 只记录 `dataKeyEpoch`，但崩溃恢复需要知道：
  - 哪些笔记已经重加密完成？
  - 原始 `oldDataKey` 和 `newDataKey` 是什么？
  - 已完成的批次最后一个 uuid 是什么？
- `reEncryptAllNotes` 已有数据库事务保护（`vault.dart:533`），journal 能提供的额外价值有限

**问题 6：Journal 滚动策略未定义**
- 未定义阈值是条目数还是文件大小
- 未定义旧 log 文件保留多少个
- 未定义远端归档副本的清理策略

**问题 7：per-device 本地 journal 的存储介质未明确**
- 存 SQLite？每次 append 需要 IO
- 存文件？需要新 IO 层
- 远端？与"本地先落地"矛盾

#### 3. 迁移方案问题

**问题 8：双写期的一致性保障不充分**
- 阶段1 说"双写"，但 `sync_engine.dart:191` 的 `_syncOnce` 中直接读 `vault.keyVersion`/`vault.adoptRemoteEpoch` 等方法
- 如果双写时 keyring 和旧字段不一致，manifest header 中的值会矛盾

**问题 9：旧客户端与新 manifest 的兼容性风险**
- 阶段4 元数据明文化说"由 `schemaVersion` 区分新旧解析路径"，但：
  - 旧客户端的 `ManifestCrypto.deserializeHeaderOnly`（`sync_models.dart:767`）不检查 `schemaVersion`
  - 如果旧客户端拿到"彻底明文+HMAC"格式的 manifest，它会尝试用 dataKey 解密 items——但 items 已经是明文了，解密必然失败

#### 4. 安全性问题

**问题 10：Journal 本地存储的泄露面被低估**
- manifest items 是加密存储的（`sync_models.dart:37`）
- journal 如果是本地明文存储，泄露的是**操作序列**（"3分钟前修改了笔记X，5分钟前删除了笔记Y"），这比静态的 manifest items 更有价值

### 与现有代码的不一致之处

| 设计文档描述 | 现有代码实际 | 不一致 |
|---|---|---|
| `Keyring` 取代 `Vault` 成为 `SyncEngine` 持有的钥匙对象 | `SyncEngine` 持有 `Vault vault` | `Keyring` 需要暴露等价的 getter |
| `Vault.adoptRemoteEpoch()` → "直接 `current = KeyringEntry.from(remote)`" | `adoptRemoteEpoch` 是异步方法，需要写6个 meta 字段 | `Keyring` 的 persist 是异步的 |
| `database.appendDataKeyHistory(...)` → "`history.add(...)`" | `appendDataKeyHistory` 去重逻辑：同 `keyVersion` 不重复 | `Keyring.history` 需要去重逻辑 |
| `Vault.dataKey` 是 `final` | `Vault` 通过 `copyWith` 创建新实例替换 dataKey | `Keyring.current` 需要是可替换的 |

### 建议的改进方向

1. **明确 Keyring 的 dataKey 持有策略**：要么 `KeyringEntry` 包含明文 `dataKey`，要么文档明确 `dataKey` 由 `SyncEngine` 从 `encryptedDataKey` + MK 解密后缓存。

2. **Journal 的 crash recovery 需要更具体的协议**：建议简化为"journal 只记录审计事件，不承担崩溃恢复职责"，崩溃恢复依赖数据库已有事务机制。

3. **元数据明文化应作为独立 P3 阶段**：迁移兼容性风险较高，建议与 Keyring/Journal 解耦，单独实施。

4. **Keyring.history 的去重和上限策略需要明确**：当前 DataKeyHistory 无上限，需明确保留策略。

5. **Journal 的存储介质需要明确**：建议直接用 SQLite 的一张新表，避免引入新的 IO 层。

### 需要进一步澄清的问题

1. `Keyring.fromRemoteHeader` 的无 MK 模式如何工作？
2. `Keyring` 的 `persist(db)` 是原子写入整个 JSON 还是逐字段写入？
3. Journal 条目的 `seq` 全局递增还是 per-file 递增？
4. 阶段1 的双写与阶段5 的清理之间的过渡策略？
5. 元数据明文化的 schemaVersion 升级路径？