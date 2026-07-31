# P2 设计文档：Keyring 密钥环模型 + Journal 操作日志

> 状态：**草案（Draft）**，待评审确认后进入实现。
> 范围：仅设计层。实现阶段**不触碰 blob 层、不改动加密信封格式**（与 P0/P1 的约束一致）。
> 关联文档：`docs/server-api-spec.md` v2.2（resources API）、`docs/sync-protocol-spec.md`、`docs/sync-feature-design.md`。
> 代码基线：`lib/sync/vault.dart`、`lib/sync/sync_models.dart`、`lib/sync/crypto.dart`。

---

## 0. 背景与动机

P0/P1 已落地并全绿（重建跳过 GC、repairRemote/下载 blob 缺失兜底、manifest 代际环形备份、GC 软删除隔离区、混沌 blob 破坏自愈）。
接下来要解决的，是**协议长期可维护性与可观测性**问题，集中在两点：

1. **密钥态分散**——当前密钥/纪元信息散落在三处，靠手动双向同步：
   - `Vault`（内存态 + `sync_meta` 表）：`vaultId / dataKey / encryptedDataKey / keyFingerprint / keyVersion / dataKeyEpoch / kdf / createdAt / mk`
   - `ManifestHeader`（远端明文头部）：上述字段的投影 + `version / updatedAt / lastModifiedBy`
   - `DataKeyHistory`（`sync_meta` 归档表）：旧 `wrappedDataKey` 列表，供 scenario-d 修复
   - 三处靠 `adoptRemoteEpoch()` / `updateEncryptedDataKey()` 互相回写，是历史上 `BUG-3`（远端纪元被本地回滚）、`H1`（sync 时需回写远端值）等问题的根源。
2. **缺可观测的操作日志**——`reEncryptAllNotes` / `_gcOrphanBlobs` 中途崩溃无重放保障；冲突、自愈、密钥变更无审计轨迹；`P0-2`（blob 自描述）被降级为 P2，而 journal 是它更优雅的归宿。

另外，用户此前提出两个待评估命题，本文一并给出结论：
- **元数据明文化**：把 manifest items 由 `AES-GCM(dataKey, ...)` 改为明文，换取客户端逻辑简化与可靠性提升。
- **manifest 单点故障**：单一 `manifest.json` 密文是同步的脆弱点（已用 P1-1 代际备份 + P0-1 重建跳过 GC 缓解，但仍可进一步加强）。

---

## 1. 设计目标

| # | 目标 | 说明 |
|---|---|---|
| G1 | 密钥单一真相源 | 所有密钥/纪元/历史收敛到一个 `Keyring` 结构，消除 Vault↔Header 双向同步 bug。 |
| G2 | 崩溃安全 | 关键批量操作（重加密、GC）有可重放/回滚的记录。 |
| G3 | 可审计可诊断 | 每次密钥事件、每条笔记的近期变更、每次自愈都有留痕。 |
| G4 | 逻辑简化 | 元数据不再二次加密；纪元判断集中化，减少调用方散落的 `if`。 |
| G5 | 向后兼容 | 旧客户端（无 keyring/journal）能与新 manifest 互通；升级路径平滑。 |
| G6 | 不碰加密格式 | blob 信封、AAD、KDF 全部不变；只重组"密钥与事件的容器"。 |

---

## 2. Keyring 密钥环模型

### 2.1 核心结构

```dart
/// 单个密钥条目（一次密钥状态快照）
class KeyringEntry {
  final String keyFingerprint;    // H(MK)，跨设备一致
  final String encryptedDataKey;  // AES-GCM(MK, dataKey)，base64
  final int keyVersion;           // 改密码 +1（dataKey 值不变）
  final int dataKeyEpoch;         // 当前 dataKey 纪元（dataKey 值真变 +1）
  final String? wrappedByHint;    // 提示用哪个 MK 解（默认"当前密码派生"，旧条目存旧 fingerprint）
  final int archivedAt;           // Unix 毫秒，归档时间
  final String? reason;           // 'create' | 'changePassword' | 'migrateVault' | 'scenario-d'
}

/// 统一密钥环：Vault + ManifestHeader(key 部分) + DataKeyHistory 的合体
class Keyring {
  final String vaultId;
  final KdfParams kdf;            // per-vault salt / iterations / algorithm
  final int createdAt;

  final KeyringEntry current;     // 当前生效密钥（等价于旧的 Vault 主字段）
  final List<KeyringEntry> history; // 历史条目，按 keyVersion 倒序；供旧密码 repair

  // 便捷访问器（语义不变）
  String get encryptedDataKey => current.encryptedDataKey;
  String get keyFingerprint => current.keyFingerprint;
  int get keyVersion => current.keyVersion;
  int get dataKeyEpoch => current.dataKeyEpoch;

  /// 本地持久化（写入 sync_meta 的单个 `keyring` 键）
  /// 敏感字段已是 MK 包裹，明文存储不泄露 dataKey；
  /// keyFingerprint/keyVersion/dataKeyEpoch/kdf 本就非密。
  Future<void> persist(NotesDatabase db);

  /// 从远端 ManifestHeader 重建（新设备加入 / 同步拉取）
  factory Keyring.fromRemoteHeader(ManifestHeader h, {Uint8List? mk});

  /// 投影回远端头部（发布 manifest 时）
  ManifestHeader toRemoteHeader({int version, int updatedAt, String lastModifiedBy});
}
```

### 2.2 与现有代码的映射

| 现有 | 落到 Keyring |
|---|---|
| `Vault.dataKey / encryptedDataKey / keyFingerprint / keyVersion / dataKeyEpoch` | `current` 条目字段 |
| `Vault.kdf / vaultId / createdAt` | `Keyring` 顶层字段 |
| `ManifestHeader` 的 key 部分 | `Keyring.toRemoteHeader()` 投影 |
| `database.appendDataKeyHistory(...)` | `history.add(...)`（每次 changePassword / migrate 前归档旧 `current`） |
| `Vault.adoptRemoteEpoch()` | 直接 `current = KeyringEntry.from(remote)` |
| `Vault.updateEncryptedDataKey()` | `current.encryptedDataKey = ...` |

`Keyring` 取代 `Vault` 成为 `SyncEngine` 持有的钥匙对象；`Vault` 可保留为薄封装或逐步废弃。

### 2.3 关键流程的简化

- **createNew**：生成 `current` 条目，`history = []`。
- **changePassword**：把 `current` 压入 `history`，生成新 `current`（keyVersion+1，dataKeyEpoch 不变，dataKey 值不变）。不再需要 `appendDataKeyHistory` 单独调用。
- **migrateToRemote / migrateToRemoteVault**：旧 `current` 压入 `history`，采用远端为 `current`；仅当 dataKey 值真变时 dataKeyEpoch+1（与现状 `migrateToRemote` 的 Layer 3 逻辑一致）。
- **unlockLocal / unlockFromRemoteManifest**：从 meta / 远端 header 重建 `Keyring`；若 meta 缺失则按旧 `DataKeyHistory` 兼容读取。
- **adoptRemoteEpoch**：单行 `current = ...`，杜绝"本地 keyVersion 落后导致每轮误报他端改密码"的 `BUG-3`。

### 2.4 收益

- **G1 达成**：密钥真相源唯一，调用方只读 `keyring.current`；远端只是投影。
- **修复路径更稳**：`history` 自带旧 `wrappedDataKey` + 旧 `keyFingerprint`（即"哪个 MK 能解"），旧密码用户在 scenario-d 恢复时无需再猜。
- **为密钥轮换铺路**：`Keyring` 天然支持 periodic dataKey rotation（未来可选特性），只需在 `history` 留锚点。

---

## 3. Journal 操作日志

### 3.1 动机（对应 G2/G3）

- **崩溃安全**：`reEncryptAllNotes` 前写 `key.migrate(start)`，分批完成后写 `key.migrate(done)`；崩溃重启扫描未完成条目重放/回滚（`database.reEncryptAllNotes` 已是事务保护，journal 提供跨进程可观测层）。
- **冲突/自愈诊断**：保留每笔记最近 N 次变更时间线（updatedBy/updatedAt 已在 item，journal 给"事件序列"而非单点快照）。
- **P0-2 的优雅替代**：blob 自描述（在 blob 内嵌"谁/何时/用哪个 dataKey 纪元写"）会污染 blob 格式；journal 在外部记录同样信息，自愈时查 journal 即可，无需改 blob。
- **审计 & 用户可见变更历史**：可展示"这条笔记 3 天前被设备 B 修改并同步"。

### 3.2 条目结构

```json
{
  "schemaVersion": 1,
  "vaultId": "uuid-xxx",
  "entries": [
    {
      "seq": 1,
      "ts": 1719470000000,
      "type": "note.upsert | note.delete | note.heal | blob.reupload | key.changePassword | key.migrate | key.adoptEpoch | sync.gcOrphan",
      "uuid": "note-uuid",
      "hash": "blob-sha256",
      "dataKeyEpoch": 3,
      "by": "android-xxx",
      "note": "可选人类可读说明"
    }
  ]
}
```

### 3.3 存储（复用 v2.2 resources API，三 backend 一致）

- 落后端子目录 `journal/`（与 `manifest-backup/`、`blobs-orphan/` 同源，统一由 v2.2 `/api/v2/resources/<path>` 的 `move/mkdir/propfind` 管理）。
- 形态初选：**单一 `journal/log.json` + 滚动**（参考 manifest 代际环形备份：达到容量阈值后整体归档为 `journal/log-<seq>.json` 并开新文件）。先实现**每设备本地 journal**，远端仅作可选归档副本。
- 取舍：global 合并 journal（多设备事件汇入同一时间线）信息更全但冲突合并复杂；**首版采用 per-device 本地 journal + 可选远端归档**，降低复杂度（契合 G4）。

### 3.4 与 manifest 的关系

- **manifest = 一致性快照（checkpoint）**；**journal = 增量事件流**。
- 同步成功 → manifest `version` 推进；本次同步的动作（upload/download/heal/migrate/gc）追加 journal 条目。
- `_gcOrphanBlobs`：软删除时 journal 记录被隔离的 `hash` + 时间；`purgeOrphans` 超期结算时再追加 `sync.gcOrphan(purged)`。自愈闭环可审计。

### 3.5 崩溃恢复（草例）

```
reEncryptAllNotes 启动
  -> journal.append(key.migrate(start), epoch=old)
  -> for batch in notes: reEncrypt(batch)
  -> journal.append(key.migrate(done), epoch=new)
崩溃重启：
  -> 找最近未 done 的 key.migrate(start)
  -> 若存在：比对本地 dataKey 纪元，重放剩余批次或整体回滚到 migrate 前快照
```

---

## 4. 元数据明文化评估（用户命题）

**现状**：manifest items 用 `AES-GCM(dataKey, AAD='manifest-items', itemsJSON)` 加密。

| 维度 | 保留加密 | 改为明文 |
|---|---|---|
| 客户端复杂度 | 解析 manifest 必须先有 dataKey（header 明文 + items 加密，两步） | 有 header 即可读笔记清单（内容仍在 blob 加密）；省一层 GCM |
| 可靠性 | items 解密失败 → 整个 manifest 解析失败（单点放大） | 仅依赖 header；items 解析失败不影响结构 |
| 泄露面 | hash（内容侧信道，已暴露）、updatedAt/updatedBy/createdAt/deleted/contentSize（同量级） | 相同量级的元数据；**笔记内容仍在 blob，保持加密** |
| 抗篡改 | GCM tag 自带完整性 | 需另加 header 内嵌 HMAC 防篡改（低成本） |

**结论与推荐**：
- 元数据加密**收益有限、成本可见**（多一层失败面、多一步解析）。多数用户不依赖"笔记数量/更新模式"保密。
- **推荐折中**：manifest items 改明文 JSON，但整体 manifest 仍由 dataKey 做一次信封（即保留现有 `[头长][header][AES-GCM(...)]` 外壳，仅把 items 内部从"加密体"改为"明文体"），或彻底明文 + header 内嵌 HMAC-SHA256 防篡改。**二选一待用户拍板**（决策点 D1）。
- 该改动**不碰 blob 格式、不碰 KDF**，满足 G6；且让"新设备无需先派生 MK 即可浏览笔记列表"成为可能（UX 优化）。

---

## 5. 迁移方案（分阶段，全兼容）

| 阶段 | 内容 | 兼容策略 |
|---|---|---|
| 1 | 引入 `Keyring` 类，作为 `Vault` 的包装；`sync_meta` 写 `keyring` JSON（同时保留旧字段，**双写**） | 旧客户端读旧字段无影响 |
| 2 | `ManifestHeader` 改为 `keyring.current` 的投影；`sync_engine` 拉远端 header → 重建 `Keyring` | header 字段向后兼容，旧客户端照常读 |
| 3 | 引入 `Journal`（本地先落地）；`sync_engine` 关键节点 `append` | 不影响 manifest 结构 |
| 4 | 元数据明文化（可选开关，决策点 D1） | 由 `schemaVersion` 区分新旧解析路径 |
| 5 | 移除旧 `Vault` 散字段 / `DataKeyHistory` 表，清理双写 | 仅在所有客户端升到阶段 2+ 后 |

**升级路径测试**：旧 vault（无 keyring/journal）首次被新客户端打开 → 从 meta 旧字段 / 远端 header 重建 `Keyring`；旧客户端读新 manifest → 字段仍在，无碍。

---

## 6. 安全分析

- **Keyring 本地存储**：敏感字段（`encryptedDataKey`）已是 MK 包裹，明文 meta 不泄露 dataKey；`keyFingerprint/keyVersion/dataKeyEpoch/kdf` 非密。与现状等价。
- **Keyring.history**：含旧 `wrappedDataKey`，需旧密码（旧 MK）才能解——与现状 `DataKeyHistory` 等价，合理。
- **Journal 泄露**：含 uuid/hash/操作类型/设备/时间，与 manifest items 同量级，无新增敏感面；如需可整体加密（后续可选）。
- **威胁模型**：恶意/故障服务端已由 P0/P1 覆盖（代际备份、软删除隔离、自愈）；journal/keyring 不引入新攻击面。

---

## 7. 开放问题 / 待决策

- **D1**：元数据明文化采用哪种（保留信封仅 items 明文 / 彻底明文+HMAC）？还是本期不做？
- **D2**：Journal 是否上远端、global 合并还是 per-device？首版建议 per-device + 可选远端归档。
- **D3**：`Keyring.history` 保留上限（按条数 / 按时间滚动）？
- **D4**：是否启用 periodic dataKey rotation（keyring 已支持，但属新特性，建议 P2 之外单列）？
- **D5**：journal 滚动阈值（单文件条目上限 / 体积上限）？

---

## 8. 测试策略（实现阶段）

- **Keyring 单测**：createNew / changePassword（history 压栈、keyVersion+1、dataKeyEpoch 不变）/ migrate（dataKeyEpoch+1、history 含旧条目）/ adoptRemoteEpoch / 旧密码 repair（从 history 取旧 wrappedDataKey）。
- **Journal 单测**：append / 滚动归档 / 崩溃重放（模拟 migrate 未完成重启）。
- **向后兼容**：旧 vault 升级路径；旧客户端与新 manifest 互通。
- **混沌**：随机翻转 keyring/journal 落盘文件，断言同步仍收敛、不静默丢失（沿用 P0/P1 混沌框架）。

---

## 9. 风险与缓解

| 风险 | 缓解 |
|---|---|
| 阶段 2 投影写错导致远端纪元回滚 | `Keyring.toRemoteHeader` 为唯一出口；单测覆盖 `adoptRemoteEpoch` 等价性 |
| journal 写入拖累同步性能 | 内存缓冲 + 批量 flush；per-device 本地，无网络开销 |
| 元数据明文被服务端统计笔记数 | 决策点 D1 折中方案保留信封；如选彻底明文，接受该取舍 |
| 双写期 meta 不一致 | 阶段 5 清理前以 keyring 为权威，旧字段仅读不写 |
