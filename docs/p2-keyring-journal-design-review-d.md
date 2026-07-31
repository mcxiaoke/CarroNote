# P2 Keyring + Journal 设计文档独立审查报告

> 审查时间：2026-07-31
> 审查对象：`docs/p2-keyring-journal-design.md`（草案）
> 代码基线：`lib/sync/vault.dart`、`lib/sync/sync_models.dart`、`lib/sync/crypto.dart`、`lib/sync/sync_engine.dart`、`lib/data/database_handler.dart`
> 审查人：opencode (独立视角，未参考 docs/ 下其他 review 文档)

---

## 1. 总体评价

**结论：设计方向正确，架构分层清晰，解决了 P0/P1 遗留的核心痛点（密钥态分散、无操作日志），迁移路径可行。但存在若干实现细节与现有代码的不一致、风险点需在实现前对齐。**

| 维度 | 评价 |
|------|------|
| 设计完整性 | ⭐⭐⭐⭐⭐ 涵盖模型、流程、迁移、安全、测试、风险，闭环度高 |
| 代码一致性 | ⭐⭐⭐ 部分字段映射、命名与现有实现有出入（详见 §3） |
| 向后兼容 | ⭐⭐⭐⭐ 分阶段双写策略合理，旧客户端互通无阻断 |
| 实现风险 | ⭐⭐⭐ 中等：Keyring 持久化格式、Journal 存储后端、元数据明文开关需落地确认 |

---

## 2. 逐节对照审查

### 2.1 Keyring 密钥环模型（§2）

#### ✅ 设计与代码一致的部分
| 设计要点 | 代码现状 | 一致性 |
|----------|----------|--------|
| 单一真相源 | `Vault` 类已持有 `vaultId/dataKey/encryptedDataKey/keyFingerprint/keyVersion/dataKeyEpoch/kdf/createdAt/mk` | ✅ |
| `KeyringEntry` 字段 | 对应 `Vault` 的非 final 字段 + `history` 归档表 | ✅ |
| `changePassword` 压栈历史 | `vault.changePassword()` 已调用 `appendDataKeyHistory` | ✅ |
| `migrateToRemote` 迁移逻辑 | `Vault.migrateToRemote()` 含 `markAllForBlobReupload` + `dataKeyEpoch+1` | ✅ |
| `adoptRemoteEpoch` 整体采用 | `Vault.adoptRemoteEpoch()` 已实现（含 `dataKeyEpoch`） | ✅ |

#### ⚠️ 需对齐的差异

| 设计文档 | 实际代码 | 影响 | 建议 |
|----------|----------|------|------|
| `KeyringEntry.wrappedByHint: String?` | 无对应字段；历史归档表用 `keyFingerprint` 指示 MK | 低 | 设计文档可删去 `wrappedByHint`，直接复用 `keyFingerprint` |
| `KeyringEntry.reason: 'create' \| 'changePassword' \| 'migrateVault' \| 'scenario-d'` | `database.appendDataKeyHistory` 仅存 `keyVersion/wrappedDataKey/keyFingerprint` | 中 | 实现时需扩展归档表结构，或复用 `keyVersion` 语义区分场景 |
| `Keyring.persist()` 写单个 `keyring` 键 | 现为分散写 `vault_id/encrypted_data_key/...` 多键 | 高 | 阶段 1 双写期需新增 `keyring` JSON 键，阶段 5 清理旧键 |
| `Keyring.fromRemoteHeader()` 工厂 | 现为 `Vault.unlockFromRemoteManifest()` 静态方法 | 低 | 重构时迁移为工厂构造器 |
| `Keyring.toRemoteHeader()` 投影 | 现为 `SyncEngine._buildLocalManifest()` 内联构造 `ManifestHeader` | 中 | 建议在 `Keyring` 类上实现 `toManifestHeader()`，消除重复构造逻辑 |

#### 🔴 关键风险点
1. **`dataKeyEpoch` 双重来源**：设计文档 §2.1 `KeyringEntry.dataKeyEpoch`，但代码中 `Vault.dataKeyEpoch` 与 `ManifestHeader.dataKeyEpoch` 同步；迁移时 `migrateToRemote()` 会在 `!_sameKey` 时 `dataKeyEpoch+1` 并写 meta。需确认 Keyring 持久化时 `dataKeyEpoch` 以哪处为准（建议：以 `Keyring.current.dataKeyEpoch` 为单一真相源，`ManifestHeader` 仅投影）。
2. **`keyVersion` 语义差异**：设计文档称 `keyVersion` 仅在 changePassword 时 +1；代码中 `migrateToRemoteVault()` 会把 `remoteKeyVersion` 写入本地（不同 vault 合并场景）。需明确：跨 vault 迁移时是否应保留远端 `keyVersion` 还是重置为 1？
3. **`createdAt` 不变性**：设计文档称 `createdAt` "首次 createNew 时设置，后续不变"；但 `migrateToRemoteVault()` 会用 `remoteCreatedAt` 覆盖。需决策：vault 合并时是否保留原创建时间？（建议：保留远端 `createdAt`，因 vaultId 已变更，实质是新 vault）。

---

### 2.2 Journal 操作日志（§3）

#### ✅ 设计合理之处
- 复用 v2.2 resources API（`/api/v2/resources/journal/log.json`）与三后端能力对齐，无新增端点依赖
- Per-device 本地 journal + 可选远端归档，避免了多设备合并 journal 的冲突复杂度
- 与 manifest 的 "checkpoint vs event stream" 关系定义清晰

#### ⚠️ 需落地确认的细节

| 问题 | 现状 | 建议 |
|------|------|------|
| **Journal 条目 schema 版本** | 设计文档写死 `"schemaVersion": 1` | 预留字段，实现时定义 `JournalSchemaVersion` 常量 |
| **滚动归档触发条件** | D5 待决策：条目上限 / 体积上限 | 参考 manifest 代际备份（N 份），建议：单文件 1000 条或 100KB 触发归档 |
| **`dataKeyEpoch` 记录时机** | 设计文档示例含 `dataKeyEpoch` 字段 | 仅在涉及 blob 操作（upsert/delete/heal/reupload/migrate/gc）的条目中记录；纯元数据操作（sync.start/complete）可省略 |
| **远端归档时机** | "可选远端归档"，无具体触发 | 建议：同步成功后，若本地 journal 文件数 > 1（已有归档），把最旧的归档文件 `move` 到远端 `journal/archive-<seq>.json` |
| **崩溃恢复逻辑** | §3.5 仅给草例 | 需补充：`key.migrate(start)` 后若无 `done`，重启时比对 `vault.dataKeyEpoch` 与 journal 记录的 epoch，决定重放还是回滚 |

#### 🔴 与现有代码的集成点
- `SyncEngine.sync()`、`repairRemote()`、`_gcOrphanBlobs()` 均需插入 `journal.append()` 调用
- `database.reEncryptAllNotes()` 已是事务保护，Journal 提供跨进程可观测层，**不应**在事务内写 journal（避免事务回滚导致 journal 与 DB 不一致），建议：**事务提交后**异步 flush journal
- `SyncEngine._mergeAndTransfer()` 中的 upload/download/heal/gc 都需记录对应类型条目

---

### 2.3 元数据明文化评估（§4）

#### 现状核对
| 设计文档描述 | 代码实际 |
|--------------|----------|
| "manifest items 用 `AES-GCM(dataKey, AAD='manifest-items', itemsJSON)` 加密" | ✅ `ManifestCrypto.serialize()` 第 712 行确认 |
| "header 明文 + items 加密，两步解析" | ✅ `deserializeHeaderOnly()` + `deserialize()` 两阶段 |
| "笔记内容仍在 blob 加密" | ✅ blob 独立 AES-GCM(dataKey, AAD=id\|epoch) |

#### 评估结论
**折中方案（保留信封仅 items 明文）可行，彻底明文+HMAC 需额外实现 HMAC 校验。**

- **保留信封仅 items 明文**：只需修改 `ManifestCrypto.serialize/deserialize` 中 items 部分不再加密，header 仍用 `dataKey` 做信封（或改用 `HKDF(dataKey, "manifest-envelope")` 派生专用密钥）。**优势**：零协议变更，旧客户端仍能解析 header 拿到 `encryptedDataKey`；新客户端跳过 items 解密。**风险**：服务端仍存密文，无法直接审计 items 结构。
- **彻底明文+HMAC**：需在 header 增加 `itemsHmac: base64(HMAC(dataKey, itemsJSON))`，解析时先验 HMAC。**优势**：服务端可直接读 items（便于调试/审计）；**劣势**：破坏 header 明文语义，旧客户端无法验证 HMAC 会报错。

**建议**：先实现"保留信封仅 items 明文"作为 D1 默认选项，HMAC 方案作为后续可选增强（由 `ManifestHeader.schemaVersion=2` 区分）。

---

### 2.4 迁移方案（§5）

| 阶段 | 设计内容 | 代码现状 | 可行性 | 备注 |
|------|----------|----------|--------|------|
| 1 | 引入 `Keyring` 类，双写 `keyring` JSON + 旧字段 | 无 `Keyring` 类，旧字段分散 | ✅ 可行 | 需新建 `lib/sync/keyring.dart`，`Vault` 内部委托 |
| 2 | `ManifestHeader` 改为 `keyring.current` 投影 | `_buildLocalManifest()` 内联构造 | ✅ 可行 | 迁移后 `_buildLocalManifest` 调用 `keyring.toManifestHeader()` |
| 3 | 引入 `Journal` 本地落地 | 无 journal 机制 | ✅ 可行 | 新建 `lib/sync/journal.dart`，复用 `database.setMeta` 或独立文件 |
| 4 | 元数据明文化（可选开关） | 现全加密 | ✅ 可行 | 由 `schemaVersion` 区分解析路径 |
| 5 | 移除旧字段 / `DataKeyHistory` 表 | 仍在使用 | ⚠️ 需等所有客户端升级 | 建议保留 `DataKeyHistory` 至下个大版本，仅停止写入 |

#### 升级路径测试缺口
设计文档 §5 提到"旧 vault 首次被新客户端打开 → 从 meta 旧字段 / 远端 header 重建 `Keyring`"，**但现有代码无此重建逻辑**。实现时需在 `Vault.unlockLocal()` 和 `unlockFromRemoteManifest()` 中增加：若 meta 无 `keyring` 键，则从旧字段构造 `Keyring` 并持久化。

---

### 2.5 安全分析（§6）

| 设计声明 | 代码验证 | 结论 |
|----------|----------|------|
| "Keyring 本地存储：敏感字段已是 MK 包裹，明文 meta 不泄露 dataKey" | ✅ `encryptedDataKey` = `AES-GCM(MK, dataKey)`，`keyFingerprint/keyVersion/dataKeyEpoch/kdf` 非密 | 正确 |
| "Keyring.history 含旧 wrappedDataKey，需旧密码才能解" | ✅ `database.appendDataKeyHistory` 存 `wrappedDataKey` + `keyFingerprint` | 正确 |
| "Journal 泄露：含 uuid/hash/操作类型/设备/时间，与 manifest items 同量级" | ⚠️ Journal 新增 `dataKeyEpoch`、`note` 字段 | 可接受，但建议 journal 整体可选加密（后续） |
| "威胁模型：恶意/故障服务端已由 P0/P1 覆盖" | ✅ 代际备份、软删除隔离、自愈已落地 | 正确 |

---

### 2.6 开放问题（§7）建议决策

| 问题 | 建议决策 | 理由 |
|------|----------|------|
| **D1: 元数据明文化采用哪种** | **保留信封仅 items 明文（默认开启）**，HMAC 方案留待 schemaVersion=2 | 零协议破坏，旧客户端兼容，实现成本最低 |
| **D2: Journal 上远端/全局合并** | **Per-device 本地 + 可选远端归档**，首版不做全局合并 | 降低复杂度，契合 G4；远端归档作为"冷备份"即可 |
| **D3: Keyring.history 保留上限** | **按条数保留最近 20 条**，超限滚动删除最旧 | 对应约 20 次改密码/迁移，足够场景 d 恢复；避免无限增长 |
| **D4: Periodic dataKey rotation** | **P2 之外单列**，不纳入本期 | Keyring 结构已支持，作为独立特性规划 |
| **D5: journal 滚动阈值** | **单文件 1000 条或 100KB**，参考 manifest 代际备份 | 平衡 IO 与内存，归档后单文件约 50-100KB |

---

## 3. 代码层面的具体改动建议

### 3.1 新增文件
| 文件 | 职责 | 关键接口 |
|------|------|----------|
| `lib/sync/keyring.dart` | Keyring 核心模型 | `KeyringEntry`、`Keyring`、`fromRemoteHeader`、`toManifestHeader`、`persist` |
| `lib/sync/journal.dart` | Journal 本地存储 + 远端归档 | `Journal.append()`、`rollover()`、`recover()`、`archiveToRemote()` |
| `lib/sync/keyring_journal_migration.dart` | 迁移辅助（阶段 1-5） | `migrateVaultToKeyring()`、`cleanupLegacyFields()` |

### 3.2 修改文件
| 文件 | 改动要点 |
|------|----------|
| `lib/sync/vault.dart` | 内部持有 `Keyring` 实例；`createNew/unlockLocal/unlockFromRemoteManifest/changePassword/migrateToRemote/adoptRemoteEpoch` 委托给 `Keyring`；保留现有公共 API 不变（向后兼容） |
| `lib/sync/sync_models.dart` | `ManifestHeader` 增加 `fromKeyring()` / `toKeyringEntry()`；`ManifestCrypto` 实现 items 明文化开关（受 `schemaVersion` 控制） |
| `lib/sync/sync_engine.dart` | 关键节点插入 `journal.append()`；`_buildLocalManifest()` 调用 `keyring.toManifestHeader()`；迁移/修复流程记录 journal |
| `lib/data/database_handler.dart` | 新增 `setMeta('keyring', json)` / `getMeta('keyring')`；`appendDataKeyHistory` 扩展存 `reason` 字段 |
| `lib/sync/crypto.dart` | 无破坏性改动；仅供 `ManifestCrypto` 调用 |

---

## 4. 测试策略补充（对照 §8）

| 测试类型 | 现有覆盖 | 需新增 |
|----------|----------|--------|
| Keyring 单测 | `vault_test.dart` 覆盖 Vault 核心流程 | `keyring_test.dart`：`createNew/changePassword/migrate/adoptRemoteEpoch/旧密码repair` + 持久化往返 |
| Journal 单测 | 无 | `journal_test.dart`：`append/rollover/crash重放(模拟migrate未完成重启)` |
| 向后兼容 | 无 | `compat_test.dart`：旧 vault 升级路径；旧客户端读新 manifest |
| 混沌测试 | `chaos_multi_client_test.dart`、`p0p1_self_heal_test.dart` | 扩展：随机翻转 `keyring`/`journal` 落盘文件，断言同步收敛 |

**建议**：复用现有 `FakeBackend` + `sqflite_ffi` in-memory 模式，单测在 Windows `flutter test` 秒级跑完。

---

## 5. 风险与缓解补充（对照 §9）

| 设计文档风险 | 补充风险 | 缓解措施 |
|--------------|----------|----------|
| 阶段 2 投影写错导致远端纪元回滚 | `Keyring.toManifestHeader()` 单测覆盖 `adoptRemoteEpoch` 等价性 | ✅ 已在设计文档 |
| journal 写入拖累同步性能 | journal 写入同步阻塞主流程 | **内存环形缓冲 + 批量异步 flush**（每 100ms 或累积 50 条） |
| 元数据明文被服务端统计笔记数 | D1 折中方案保留信封 | ✅ 已在设计文档 |
| 双写期 meta 不一致 | 阶段 1 双写时，`keyring` 为权威，旧字段仅读不写 | 需在 `Vault` 读取路径明确：优先读 `keyring`，缺失回退旧字段 |
| **新增**：Journal 与 DB 事务不一致 | 崩溃时 journal 已写、DB 事务回滚（或反向） | **Journal 记录"意图"（start），DB 事务提交后记录"完成"（done）**，恢复时以 DB 状态为准 |
| **新增**：Keyring.history 无上限增长 | 频繁改密码/迁移导致 meta 膨胀 | 实现 `D3` 保留最近 20 条，归档时自动裁剪 |

---

## 6. 实现优先级建议

| 优先级 | 任务 | 依赖 | 预估工作量 |
|--------|------|------|------------|
| P0 | 新建 `Keyring` 类，实现核心模型 + 持久化 + 从旧字段/远端 header 重建 | 无 | 2-3 天 |
| P0 | `Vault` 内部委托 `Keyring`，保持公共 API 不变 | Keyring 就绪 | 1-2 天 |
| P1 | `ManifestCrypto` 实现 items 明文化开关（`schemaVersion` 分支） | Keyring 就绪 | 1 天 |
| P1 | 新建 `Journal` 类，本地落地 + 滚动归档 | 无 | 2 天 |
| P1 | `SyncEngine` 关键节点插入 `journal.append()` | Journal 就绪 | 1-2 天 |
| P2 | 远端 journal 归档（复用 resources API `move/mkdir/propfind`） | Journal + v2.2 backend | 1 天 |
| P2 | 迁移脚本：阶段 1 双写 → 阶段 5 清理旧字段 | 全部核心就绪 | 1 天 |
| P3 | 单测 + 混沌测试扩展 | 实现完成 | 2-3 天 |

---

## 7. 结论

**设计文档整体扎实，架构决策合理，解决了核心痛点。主要工作集中在：**
1. **落地 `Keyring` 类**作为单一真相源，消除 `Vault`↔`ManifestHeader` 双向同步 bug
2. **实现 `Journal` 本地落地**，复用 v2.2 resources API，提供崩溃可观测性
3. **元数据明文化**采用"保留信封仅 items 明文"折中方案，零破坏兼容
4. **分阶段迁移**双写策略可行，需补齐"旧 vault 首次打开重建 Keyring"逻辑

**建议先确定 D1-D5 五个开放问题，再按 §6 优先级分步实施。**

---

## 附：需澄清的代码细节（给实现者）

1. `Vault.migrateToRemoteVault()` 中 `remoteKeyVersion` 直接采用远端值，是否应改为 `max(local, remote) + 1`？当前代码直接赋值，可能导致 keyVersion 回滚。
2. `ManifestHeader.dataKeyEpoch` 默认值 1，但遗留 vault 可能无此字段。`ManifestCrypto.deserializeHeaderOnly()` 已处理（`?? 1`），Keyring 重建时需保持一致。
3. `database.appendDataKeyHistory()` 当前不存 `reason`，扩展时注意 JSON 结构变更需向后兼容（旧条目无 `reason` 字段）。
4. `SyncEngine._gcOrphanBlobs()` 目前软删除时未记录 journal，需补齐 `sync.gcOrphan(isolated)` 条目；`purgeOrphans` 时记录 `sync.gcOrphan(purged)`。

---

*审查完成。如有分歧，欢迎针对具体条目讨论。*