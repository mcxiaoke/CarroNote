# P2 设计文档（修订版 v2）：Keyring 密钥环模型 + Journal 操作日志

> 状态：**修订版 v2（方案 B + Journal 可恢复）**，基于 `docs/p2-keyring-journal-design.md`（草案）、四份评审报告（`p2-keyring-journal-design-review-a/b/c/d.md`），并结合用户复核放开两个约束后重写。
> 范围：仅设计层。实现阶段**不触碰 blob 层、不改动加密信封格式**（与 P0/P1 的约束一致）。
> 关联文档：`docs/server-api-spec.md` v2.2（resources API）、`docs/sync-protocol-spec.md`、`docs/sync-feature-design.md`、`docs/server-implementation.md` v2.2、`docs/p2-keyring-complexity-analysis.md`（本版决策过程）。
> 代码基线：`lib/sync/vault.dart`(890 行)、`lib/sync/sync_models.dart`(782 行)、`lib/sync/sync_engine.dart`(1847 行)、`lib/sync/crypto.dart`、`lib/data/database_handler.dart`(902 行)。
> 修订来源：草案经四份独立评审，汇总出 **2 个致命缺陷（C1/C2）、3 个高优遗漏（H1/H2/P1#2/#3）、1 个角色错位（M2）** 及若干改进项。**每一个相对草案的改动都以"附录 A 逐条修正对照表"给出代码证据与理由**，不在正文空谈。

---

## 0. 背景与动机

P0/P1 已落地并全绿（重建跳过 GC、repairRemote/下载 blob 缺失兜底、manifest 代际环形备份、GC 软删除隔离区、混沌 blob 破坏自愈）。接下来要解决的，是**协议长期可维护性与可恢复性**问题，集中在两点：

1. **密钥态分散**——当前密钥/纪元信息散落在三处，靠手动双向同步：
   - `Vault`（内存态 + `sync_meta` 表）：`vaultId / dataKey / encryptedDataKey / keyFingerprint / keyVersion / dataKeyEpoch / kdf / createdAt / mk`
   - `ManifestHeader`（远端明文头部）：上述字段的投影 + `schemaVersion / version / updatedAt / lastModifiedBy / dataKeyWrap`
   - `DataKeyHistory`（`sync_meta.data_key_history`）：旧 `wrappedDataKey` 列表，供 scenario-d 修复
   - 三处靠 `adoptRemoteEpoch()` / `updateEncryptedDataKey()` / `appendDataKeyHistory()` 互相回写，是历史上 `BUG-3`（远端纪元被本地回滚）、`H1`（sync 时需回写远端值）等问题的根源。
2. **缺可恢复的操作日志**——`reEncryptAllNotes` / `_gcOrphanBlobs` 跨边界部分写无兜底；冲突、自愈、密钥变更无审计轨迹；本地库被清/服务端 manifest 单点无第二数据源；`P0-2`（blob 自描述）被降级为 P2，而 journal 是它更优雅的归宿。

> **本期约束变更（用户复核 2026-07-31，详见 `p2-keyring-complexity-analysis.md`）**：
> - **不再要求向后兼容**：开发阶段可干净切断旧数据/旧代码，原"为不动 SyncEngine 而选方案 A"的前提撤销 → 改采**方案 B（Keyring 直接取代 Vault，见 §2.1）**，删除 `Vault` 类。
> - **Journal 恢复角色恢复**：草案原意即"防单点故障/可恢复数据"（G2 崩溃安全、§3.5 崩溃恢复、manifest 单点故障），此前因与 SQLite 事务重叠被过度降级为"审计-only"；现恢复为**"可恢复 + 审计"双角色**（见 §3.1/§3.6）。进程内崩溃原子性仍归 SQLite（不替代）。
> - **元数据明文化**：仍降级为独立 P3（与兼容性无关——旧客户端不查 `schemaVersion` 的风险依旧，见 §4）。

---

## 1. 设计目标

| # | 目标 | 说明 |
|---|---|---|
| G1 | 密钥单一真相源 | 所有密钥/纪元/历史收敛到一个 `Keyring` 账本（取代 Vault），消除 Vault↔Header 双向同步 bug。 |
| G2 | 可恢复 + 可审计（双角色） | 每次密钥事件、每条笔记的近期变更、每次自愈都有留痕（审计）；并作为可重放运维日志 + 离线/远端第二数据源，覆盖 SQLite 与单 manifest 覆盖不了的失效模式（数据丢失/服务端单点/坏纪元污染）。**进程内崩溃原子性由 SQLite 事务负责，Journal 不替代它（见 §3.6）。** |
| G3 | 可诊断 | 冲突、自愈、纪元采用有事件序列可查（而非单点快照）。 |
| G4 | 逻辑简化 | 元数据不再二次加密（降级为 P3）；纪元判断集中化，减少调用方散落的 `if`。 |
| G5 | 干净切断（不兼容旧版） | 本期不保留旧 `Vault`/旧 `sync_meta` 多键的兼容镜像；旧用户重 onboard 或一次性 `fromLegacyMeta` 转换（不进长期代码）。 |
| G6 | 不碰加密格式 | blob 信封、AAD、KDF 全部不变；只重组"密钥与事件的容器"。 |

---

## 2. Keyring 密钥环模型

### 2.1 职责边界：Keyring 直接取代 Vault（方案 B，解决 C1）

**草案缺陷（评审 C1 / 审查 B-C1 / 审查 A-P0#1 / 审查 C-问题1、2）**：草案称"Keyring 取代 Vault 成为 SyncEngine 持有的钥匙对象"，但 `Keyring` 只含**包裹态元数据**，不含运行时明文 `dataKey`（`Uint8List`，真正加解密的钥匙）和 `mk`（`Uint8List?`，会话派生的主密钥）。若照搬草案，`SyncEngine` 将无处取得 `dataKey`，无法进行任何加解密；且 `fromRemoteHeader(mk)` 收到的 `mk` 也无处存放。

**方案 B 如何让 Keyring 真正取代 Vault（C1 在方案 B 下自然解决）**：把 `dataKey`/`mk` 作为 **Keyring 的运行时字段（不持久化）** 加入。`Keyring` 既持有持久化账本（`current`/`history`/`vaultId`/`kdf`/`createdAt`），也持有会话期运行时 key（`dataKey`/`mk`）。`SyncEngine` 持有的对象从 `Vault` 变为 `Keyring`，`vault.dataKey`→`keyring.dataKey`、`vault.adoptRemoteEpoch`→`keyring.adoptRemoteEpoch`。**删除 `Vault` 类**，其有状态会话方法（`derive/unwrap/seal/open/verifyPassword`）并入 `Keyring` 或保留在 `SyncEngine`/辅助类；`Keyring` 成为唯一密钥真相源。

**代码证据**：
- `lib/sync/vault.dart:139` `final Uint8List dataKey;`（32 字节，真正加密笔记与 blob 的钥匙，不持久化）——方案 B 下移入 `Keyring` 运行时字段
- `lib/sync/vault.dart:194` `final Uint8List? mk;`（当前会话派生 MK，仅内存缓存，logout 清零）——同上
- `lib/sync/sync_engine.dart:114` `get _dataKey => vault.dataKey;` → 方案 B 改为 `get _dataKey => keyring.dataKey;`
- `lib/data/database_handler.dart:103,117,628` `_requireDataKey` / `setDataKey` / `reEncryptAllNotes` 全部依赖这个 raw dataKey——方案 B 下由 `keyring.dataKey` 提供
- 全仓 `vault.` 引用共 **56 处**，分布在 **6 个文件**（`sync_engine / sync_service / login / set_passphrase / change_passphrase / main`），绝大多数是 `vault.dataKey`/`vault.dataKeyEpoch`/`vault.mk` 这类**只读运行时字段**，属**机械重命名**为 `keyring.xxx`，不触及 merge/GC/自愈的编排逻辑

```dart
/// SyncEngine 持有的唯一密钥对象（方案 B：取代 Vault）
class Keyring {
  // —— 持久化账本 ——
  final String vaultId;
  final KdfParams kdf;
  final int createdAt;
  final KeyringEntry current;            // 当前生效密钥（包裹态）
  final List<KeyringEntry> history;      // 历史条目，local-only & best-effort，<=20 条

  // —— 运行时字段（不持久化，方案 B 新增以取代 Vault）——
  final Uint8List dataKey;               // 真正加解密的钥匙（原 Vault.dataKey）
  final Uint8List? mk;                   // 会话派生 MK 缓存（原 Vault.mk，logout 清零）

  // —— 便捷访问器（语义不变，原 vault.xxx 调用点改名即兼容）——
  String get encryptedDataKey => current.encryptedDataKey;
  String get keyFingerprint    => current.keyFingerprint;
  int    get keyVersion        => current.keyVersion;
  int    get dataKeyEpoch      => current.dataKeyEpoch;

  // —— 会话方法（原 Vault 职责并入）——
  // createNew / unlockLocal / unlockFromRemoteManifest /
  // verifyPassword / changePassword / migrateToRemote /
  // migrateToRemoteVault / adoptRemoteEpoch / checkMigrationNeeded
}
```

> **为何弃用方案 A（Vault 持 Keyring 子对象 + 委托访问器）**：fixed v1 为"不动 SyncEngine 的 56 处引用"选了方案 A，代价是保留 `Vault` 类 + 委托桥 + 双写镜像，多一层间接。放开兼容性后，这 56 处仅是 `vault.`→`keyring.` 的机械重命名、编排逻辑不变，**方案 A 的"不动 SyncEngine"前提已消失**；方案 B 无委托桥、无双写、密钥层代码更少（详见 `p2-keyring-complexity-analysis.md` §2/§3）。故采用方案 B。

### 2.2 核心结构 `KeyringEntry`

```dart
/// 单个密钥条目（一次密钥状态快照，包裹态，可持久化）
class KeyringEntry {
  final String keyFingerprint;    // H(MK)，跨设备一致，标识"哪个 MK 能解"
  final String encryptedDataKey;  // AES-GCM(MK, dataKey)，base64（包裹态）
  final int keyVersion;           // 改密码 +1（dataKey 值不变）
  final int dataKeyEpoch;         // 当前 dataKey 纪元（dataKey 值真变 +1）
  final int archivedAt;           // Unix 毫秒，归档时间；legacy 迁移项填 0
  final String? reason;           // 见下方枚举

  // reason 枚举（解决评审 A-P2#9 / 审查 C-问题4 枚举遗漏）：
  //   'create'          新建 vault
  //   'changePassword'   改密码（dataKey 不变，keyVersion+1）
  //   'adoptRemoteEpoch' 采用远端纪元（H1 场景，dataKey 不变）
  //   'migrateDataKey'   迁移到不同 dataKey（scenario-d + scenario-c，epoch+1）
  //   'unknown'          legacy 数据迁移默认值（无来源字段）

  KeyringEntry copyWith({
    String? encryptedDataKey,
    String? keyFingerprint,
    int? keyVersion,
    int? dataKeyEpoch,
    int? archivedAt,
    String? reason,
  });
}
```

**相对草案的修正**：
- **删除 `wrappedByHint`（解决评审 A-P2#8 / 审查 B-L2 / 审查 C-问题4）**：其语义"提示用哪个 MK 解"已由 `keyFingerprint`（=H(MK)）覆盖——`repairRemote` 正是用 `keyFingerprint` 匹配旧密码派生 MK（`sync_engine.dart:562-585`）。额外的自由文本 hint 既冗余又有本地化歧义（"当前密码派生"多语言问题）。
- **`reason` 枚举补全（解决评审 A-P2#9）**：把原 `'migrateVault' | 'scenario-d'` 合并为 `'migrateDataKey'`（二者都是 dataKey 真变、epoch+1）；新增 `'adoptRemoteEpoch'`（H1 场景）；新增 `'unknown'` 作为 legacy 迁移默认值。
- **`archivedAt` 允许 0**：legacy `data_key_history` 仅有 `{keyVersion, wrappedDataKey, keyFingerprint}`（`database_handler.dart:770-783`），无时间字段，迁移时 `archivedAt=0`（评审 B-L1）。

### 2.3 核心结构 `Keyring`（持久化与投影）

```dart
/// 统一密钥账本 + 运行时会话（取代 Vault）
class Keyring {
  final String vaultId;
  final KdfParams kdf;            // per-vault salt / iterations / algorithm
  final int createdAt;

  final KeyringEntry current;     // 当前生效密钥（等价于旧的 Vault 主字段）
  final List<KeyringEntry> history; // 历史条目，local-only & best-effort，<=20 条

  // —— 运行时字段（不持久化）——
  final Uint8List dataKey;        // 真正加解密的钥匙
  final Uint8List? mk;            // 会话派生 MK 缓存

  /// 本地持久化（写入 sync_meta 的单个 `keyring` 键）
  /// 只写包裹态 JSON（current + history + vaultId/kdf/createdAt），
  /// 不含 dataKey/mk（二者本就不在持久化内）。
  /// 明文存储不泄露 dataKey：encryptedDataKey 仍是 MK 包裹；
  /// keyFingerprint/keyVersion/dataKeyEpoch/kdf 本就非密。
  Future<void> persist(NotesDatabase db);

  /// 从旧 meta 字段一次性转换（升级路径：meta 无 `keyring` 键时）
  /// 读取 MetaKeys.* 旧字段 + 旧 data_key_history，构造 Keyring 并 persist。
  factory Keyring.fromLegacyMeta(NotesDatabase db);

  /// 从远端 ManifestHeader 重建 current；history 必然为空（设计约束，见 §2.5）
  factory Keyring.fromRemoteHeader(ManifestHeader h);

  /// 投影回远端头部（字段完整，解决评审 A-P1#3 / 审查 B-L3）
  ManifestHeader toManifestHeader({
    int schemaVersion = 1,
    required int version,
    required int updatedAt,
    required String lastModifiedBy,
    String dataKeyWrap = 'AES-256-GCM',   // 常量 kDataKeyWrapAlgorithm
  });
  // 注：createdAt / kdf 从 Keyring 自身取，无需调用方传入

  /// 仅更新 current 的包裹/纪元字段（保留运行时 dataKey/mk 不变）
  Keyring copyWithCurrent({
    required String encryptedDataKey,
    required String keyFingerprint,
    required int keyVersion,
    required int dataKeyEpoch,
  });
}
```

**相对草案的修正**：
- **补全 `toManifestHeader` 字段（解决评审 A-P1#3 / 审查 B-L3）**：草案签名只收 `version/updatedAt/lastModifiedBy`，但 `ManifestHeader` 构造还需 `schemaVersion`（`sync_models.dart:263`）、`createdAt`（`:279`，取 Keyring.createdAt）、`kdf`（`:305`，取 Keyring.kdf）、`dataKeyWrap`（`:308`，常量 `'AES-256-GCM'`）。缺这些字段生成的 header 不完整，会破坏远端 manifest。
- **新增 `fromLegacyMeta`**：草案称"从 meta 旧字段重建 Keyring"但无此逻辑（评审 D-升级路径缺口）。明确为工厂方法，读 `MetaKeys.vault_id/encrypted_data_key/kdf_salt/key_fingerprint/key_version/vault_created_at/data_key_epoch/data_key_history` 重建。
- **持久化只写包裹态**：`dataKey`/`mk` 是运行时字段，不在 `persist` 范围内，无泄露面（方案 B 下 dataKey/mk 在 Keyring 上，但 persist 天然不含）。

### 2.4 与现有代码映射（扩展到真正消费方，解决 H1）

**草案缺陷（评审 B-H1）**：§0 基线只列 `vault.dart/sync_models.dart/crypto.dart`，遗漏 `Vault` 的真正编排与消费方 `sync_engine.dart` 与 `database_handler.dart`，导致迁移方案无法落地。

| 现有 | 落到 Keyring（方案 B） |
|---|---|
| `Vault.dataKey/encryptedDataKey/keyFingerprint/keyVersion/dataKeyEpoch/kdf/vaultId/createdAt` | `Keyring` 字段（运行时 dataKey/mk + 包裹态 current/顶层） |
| `Vault.mk` | `Keyring.mk`（运行时，persist 不含） |
| `ManifestHeader` 的 key 部分 | `Keyring.toManifestHeader()` 投影（消除 `_buildLocalManifest` 内联构造，`sync_engine.dart:823`） |
| `database.appendDataKeyHistory(...)` | `keyring.history.add(...)` + 去重（每次 changePassword/migrate 前归档旧 `current`） |
| `Vault.adoptRemoteEpoch()` | `keyring = keyring.copyWithCurrent(...)`（**字段级更新，保留 dataKey/mk**，见 §2.5） |
| `Vault.updateEncryptedDataKey()` | `keyring.current.encryptedDataKey = ...` + persist |
| `database_handler.MetaKeys.*`（8+ 键） | 阶段 1 起新增单键 `keyring`；旧键由 `fromLegacyMeta` 一次性转换，**不镜像写入**（G5 干净切断） |
| `SyncEngine` 对 `vault.xxx` 的全部引用（56 处） | 机械重命名为 `keyring.xxx`；`changePassword/migrate*` 后**更新持有的 keyring 引用** |

> `SyncEngine` 关键调用点（已核实，方案 B 下改名）：`keyring.dataKey`(:114)、`keyring.adoptRemoteEpoch`(:358)、`keyring.migrateToRemote`(:766)、`keyring.migrateToRemoteVault`(:793)、`_buildLocalManifest`(:823)、`_mergeAndTransfer`(:902)、`_gcOrphanBlobs`(:1689)。编排逻辑（merge/GC/自愈）不变，仅对象名替换。

### 2.5 关键流程的简化与修正

- **createNew**：生成 `current` 条目（`reason='create'`），`history = []`，写入 `keyring` 单键；返回持有 `dataKey/mk` 的 `Keyring`。
- **changePassword**：把 `current` 压入 `history`（`reason='changePassword'`、`archivedAt=now`），生成新 `current`（keyVersion+1、dataKeyEpoch 不变、dataKey 值不变）；**`mk` 更新为新派生 MK**（解决评审 B-M3）——返回新 `Keyring`（持有 newMk/newDataKey），`SyncEngine` 必须 `keyring = await keyring.changePassword(...)` 替换引用（`vault.dart:732-785` 逻辑不变，仅归档改走 `keyring.history`）。
- **migrateToRemote / migrateToRemoteVault**：旧 `current` 压入 `history`（`reason='migrateDataKey`），采用远端为 `current`；仅当 `!_sameKey(dataKey, remoteDataKey)` 时 dataKeyEpoch+1（`vault.dart:542-547,651-657`）。新 `Keyring` 持有 `remoteMk`/`remoteDataKey`，调用方替换引用。
- **unlockLocal / unlockFromRemoteManifest**：从 meta（优先 `keyring` 单键，缺失回退 `fromLegacyMeta`）/ 远端 header（`fromRemoteHeader`）重建 `Keyring` 账本，再用 `mk` 解开 `current.encryptedDataKey` 得到 `dataKey` 填回运行时字段。
- **adoptRemoteEpoch（重点修正，解决 C2 / 审查 B-C2）**：

  **草案错误写法**：`current = KeyringEntry.from(remote)`（整条目替换）。
  **问题**：`KeyringEntry.from(remote)` 只能产出包裹态条目（远端 header 无 raw dataKey）。整条目替换会**抹掉本地内存态 raw dataKey** → `SyncEngine._dataKey` 取不到 → 后续所有笔记加解密失败；更严重的是，在没有 C1 修复的前提下，这种"整条目替换"恰恰丢掉了本地唯一的 raw dataKey，与"杜绝 BUG-3"的承诺直接冲突。

  **代码证据**：`vault.dart:808-837` `adoptRemoteEpoch` 注释明确——"dataKey 不变，不触碰任何笔记；内存 + 本地 meta 同步更新"。BUG-3 根因是"本地 keyVersion 落后导致每轮误报他端改密码 + 构建 header 时回滚远端纪元"，正确修复（现状已落地）是**只更新包裹/纪元字段、保留 raw dataKey**。

  **修正写法（字段级更新，保留 dataKey/mk，方案 B 下对象即 Keyring）**：
  ```dart
  // 仅更新包裹态与纪元，保留运行时 dataKey / mk 不变（改密码场景 dataKey 值未变）
  keyring = keyring.copyWithCurrent(
    encryptedDataKey: remoteEncryptedDataKey,
    keyFingerprint:   remoteKeyFingerprint,
    keyVersion:       remoteKeyVersion,
    dataKeyEpoch:     remoteDataKeyEpoch,
  );
  await keyring.persist(database);   // 同步落盘（等价于原 4 次 setMeta）
  // keyring.dataKey / keyring.mk 保持原值，绝不被触碰
  ```

- **`fromRemoteHeader` 的 history 约束（解决评审 A-P1#2）**：`ManifestHeader` 只含当前密钥三元组（`sync_models.dart:259-338`），**不含历史**。新设备从远端加入时 `fromRemoteHeader` 只能填充 `current`，`history` 必然为空。这是**真实设计约束，不是 bug**：
  - 新设备本就没有旧密码的 MK，无法用"旧密码"执行 `repairRemote`（缺旧 `wrappedDataKey`）——这与现状一致（现状新设备同样无 `DataKeyHistory`）。
  - `history` 标记为 **local-only & best-effort**：仅老设备本地有，远端不投影（避免扩大 manifest header 体积，且新设备缺旧密码用不上）。
  - 如需跨设备共享历史，未来可加独立远端归档，但**本期不做**（与 D2 一致）。旧密码 repair 仍由本机 `history` 支持。

### 2.6 `history` 上限与去重（解决评审 A-P2#10 / D3）

- **去重**：按 `keyVersion` 去重，沿用 `appendDataKeyHistory` 的 `if (list.any((e) => e['keyVersion'] == keyVersion)) return;`（`database_handler.dart:776`）。
- **上限**：保留最近 **N=20 条**（按 keyVersion 降序），超限滚动删除最旧。理由：对应约 20 次改密码/迁移，足够 scenario-d 恢复；避免测试/开发阶段频繁改密码导致无限增长（评审 D 建议 20 条，与"约 20 次恢复窗口"匹配）。
- **local-only**：`history` 不投影到远端 header，不写入跨设备同步。

### 2.7 持久化格式（干净切断，无双写，解决评审 A-P2#7 / 审查 B-M4 / 审查 C-问题8）

**草案矛盾**：§5 说"双写 keyring JSON（同时保留旧字段）"，§9 却说"旧字段仅读不写"——两者冲突。方案 A（fixed v1）用"镜像写入"调和，但仍保留旧键。

**方案 B 修正（干净切断，无双写）**：
- **阶段 1 起即以 `keyring` 单键为唯一权威写入**；旧 `MetaKeys.*` 多键**不再写入**（G5）。旧数据通过 `fromLegacyMeta` 在 `unlock` 时**一次性转换**为 `keyring` 单键并 persist，转换后旧键可废弃（阶段 5 直接删除旧键读取分支，不保留读兼容）。
- **原子性**：`sync_meta` 多键当前无事务（`database_handler.dart:73-92`）。方案 B 只写 `keyring` 单键（`setMeta` 单键原子），天然无"双写不一致"问题——这正是相对方案 A 的进一步简化。
- 旧客户端互通问题在本期**不 cared**（G5）：旧客户端读不到新 `keyring` 单键即视为需升级，不做跨版本 manifest 互通。

---

## 3. Journal 操作日志

### 3.1 动机与定位（双角色：可恢复 + 审计，修正 M2 过度降级）

- **审计/可观测（G2/G3）**：保留每笔记最近 N 次变更时间线（updatedBy/updatedAt 已在 item，journal 给"事件序列"而非单点快照）；冲突/自愈可诊断；可展示"这条笔记 3 天前被设备 B 修改并同步"。
- **P0-2 的优雅替代**：blob 自描述会污染 blob 格式；journal 在外部记录"谁/何时/用哪个 dataKey 纪元写"，自愈时查 journal 即可，无需改 blob。
- **可恢复（G2 双角色核心，恢复草案原意）**：草案明确把 Journal 设计为可恢复层——`G2 崩溃安全`（关键批量操作有可重放/回滚记录）、`§3.5 崩溃恢复`（reEncryptAllNotes 前写 `key.migrate(start)`、完成后 `done`，崩溃重启重放/回滚）、`manifest 单点故障`（单一 `manifest.json` 密文是同步脆弱点）、`P0-2 优雅替代`（外部记录自愈信息）。**先前 fixed v1 因 `reEncryptAllNotes` 已被 SQLite 事务保护（`database_handler.dart:628-688`）而将 Journal 整体降级为"审计-only"，属过度修正**——把"进程内崩溃原子性"（SQLite 已覆盖）与"数据丢失/损坏/服务端单点"（SQLite 覆盖不了）混为一谈，把后者也一起扔了。
- **边界（关键）**：**进程内崩溃原子性由 SQLite 事务负责，Journal 不替代它**；但**跨边界部分写 / 本地库被清 / 服务端 manifest 单点 / 坏纪元污染 key history** 是 SQLite 与单 manifest 覆盖不了的失效模式，正是 Journal"可恢复"角色的职责（详见 §3.6）。

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

**相对草案的修正**：
- **新增 `schemaVersion` 字段（评审 D-§2.2）**：预留 `JournalSchemaVersion` 常量，避免未来格式迁移无版本号。
- **`dataKeyEpoch` 语义澄清（解决评审 A-P2#6）**：该字段**仅记录"事件发生时用的纪元"**，不参与 journal 内部时序判断。纪元变化判定仍以 `key.changePassword` / `key.migrate` / `key.adoptEpoch` 事件类型的顺序为准（代码 `vault.dart:542-547,651-657` 仅在 `!_sameKey` 时递增）。`note.upsert` 等纯 blob 操作附加的 `dataKeyEpoch` 只是"当时用的是哪个纪元的 dataKey"，供自愈查表，不参与比对。
- **`seq` 单调递增（评审 C-待澄清3）**：单设备内全局单调递增（跨归档文件连续），便于排序与去重，不 per-file 重置。
- **记录时机（评审 D）**：`dataKeyEpoch` 仅在涉及 blob 操作（upsert/delete/heal/reupload/migrate/gc）的条目中记录；纯元数据操作可省略。

### 3.3 存储：本地优先、明确载体与滚动（解决 H2 / 审查 B-H2 / 审查 C-问题6、7）

**草案矛盾**：§3.3 开头把远端 `journal/` 目录当默认落点，随后又说"先实现每设备本地 journal"——主次矛盾，且本地载体完全未指定。

**修正**：
1. **主线统一为"本地优先、远端副本"**：删除把远端 `journal/` 目录作为默认落点的表述。远端 `journal/` 目录方案技术上可行（v2.2 resources API 的 `move/mkdir/propfind`，与 `manifest-backup/`、`blobs-orphan/` 同源），且在本期**上升为防单点的第二数据源**（见 §3.6 D2），非仅可选冷备。
2. **本地载体（首版决策）**：App 沙盒文件 `journal/log.json`，复用 `path_provider`，与现有 blob 本地物化（`local_fs_backend` 沙盒）思路一致。**不采用单 `sync_meta` 键**——journal 是频繁 append 的大 JSON，单键频繁整体读写不适合（评审 C-问题7）。
3. **滚动阈值 D5（首版默认值，解决评审 A-P2#11/D5）**：单文件 **1000 条或 100KB**（取先到者），参考 manifest 代际备份 N 份；归档为 `journal/log-<seq>.json`，**保留最近 3 个归档**。
4. **远端副本（防单点，本期默认开启或设置可开）**：同步成功后，把最新归档 `move` 到远端 `journal/archive-<seq>.json`（复用 v2.2 resources API）。整体 `AES-GCM(dataKey)` 加密（复用 `ManifestCrypto` 思路），不写明文。

### 3.4 与 manifest 的关系

- **manifest = 一致性快照（checkpoint）**；**journal = 增量事件流 + 可恢复日志**。
- 同步成功 → manifest `version` 推进；本次同步的动作（upload/download/heal/migrate/gc）追加 journal 条目。
- `_gcOrphanBlobs`：软删除时 journal 记录被隔离的 `hash` + 时间（`sync.gcOrphan(isolated)`）；`purgeOrphans` 超期结算时再追加 `sync.gcOrphan(purged)`。自愈闭环可审计、可重放。

### 3.5 集成点：注入 `SyncEngine`（解决评审 A-P2#11）

**草案缺陷**：只描述记录哪些事件，未说明 journal 如何接入 `SyncEngine`。

**修正**：`Journal` 作为 `SyncEngine` 构造依赖（P2 阶段必填）：
```dart
SyncEngine({
  // ...existing fields
  required Journal journal,   // 操作日志（P2 阶段必填，不可为空）
});
```
**注入点（已核实调用位置）**：
| SyncEngine 位置 | journal 条目 |
|---|---|
| `_mergeAndTransfer` (`:902`) | `note.upsert` / `note.delete` |
| `_repairBlob` / `_healBlob` | `note.heal` / `blob.reupload` |
| `_executeMigration` (`:755`) / `_executeScenarioDMigration` (`:776`) | `key.migrate` |
| `adoptRemoteEpoch` (`:358`) | `key.adoptEpoch` |
| `_gcOrphanBlobs` (`:1689`) | `sync.gcOrphan(isolated)` / `sync.gcOrphan(purged)` |
| `changePassword`（经 Keyring） | `key.changePassword` |

### 3.6 恢复流程：可重放 + 第二数据源（双角色落地，修正 M2 过度降级）

**草案原意（§3.5 崩溃恢复）**：`reEncryptAllNotes` 前写 `key.migrate(start)`，分批完成后写 `key.migrate(done)`；崩溃重启扫描未完成条目重放/回滚。此前 fixed v1 把此整段判为"与 SQLite 事务重叠"而删除——**过度修正**。正确处理是**划清两层职责**：

**(a) 进程内崩溃原子性 = SQLite 事务（不替代）**
- `reEncryptAllNotes` 已是 SQLite 单事务写回（`database_handler.dart:628-688`，step 5 单事务 `:663`）。事务内崩溃 → 回滚 → DB 仍为旧密文；事务后、更新 `_dataKey` 前崩溃 → 下次登录 `Keyring.unlockLocal` 用密码重派生 dataKey，状态一致。**这部分 Journal 不参与。**

**(b) 可重放运维日志（跨边界部分写兜底）**
- 记录 `key.migrate(start/done)`、`note.heal`、`blob.reupload`、`sync.gcOrphan` 等**带副作用跨步事件**。
- 对"事务提交后、跨步协调未完成"的边界状态（如 blob 已重写但 manifest item 未更新、gc 隔离区已写但 purge 未完成），SQLite 单事务管不到跨步边界；Journal 提供事件序列供**有限重放/诊断**，把系统拉回一致点。
- **写入约束（评审 D-§2.2/§5）**：Journal **不在 DB 事务内写**（避免事务回滚导致 journal 与 DB 不一致）；改为"记录意图(start) → DB 事务提交后记录完成(done)"，恢复以 DB 状态为准。实现上用**内存环形缓冲 + 批量异步 flush**（每 100ms 或累积 50 条），不阻塞同步主流程。

**(c) 离线/远端副本（防单点故障 SPOF，恢复草案 manifest 单点原意）**
- **本地库被清 / 设备丢失**：本地 journal 文件随 App 沙盒保留（除非 App 卸载），作为本机重建 key state 与近期变更的来源。
- **服务端 manifest 单点**：D2 升级——远端 `journal/archive-<seq>.json` 作为**一等公民第二数据源**。当本地库与本地 journal 均丢失（如重装 App）且服务端 `manifest.json` 损坏/不可信时，可从远端 journal 副本重建 key state 与 recent 变更序列。
- **坏纪元污染 key history**：若 `keyring.current` 被坏纪元覆盖，用 journal 的 `key.adoptEpoch`/`key.migrate` 事件序列 replay 出正确 key state（需配合本地 history 的旧 `wrappedDataKey`）。

**代价（诚实）**：重放正确性须严格单测 + 混沌验证（重放语义有 bug 会让"恢复"变"二次损坏"）；远端 journal 副本整体 `AES-GCM(dataKey)` 加密，不写明文。

---

## 4. 元数据明文化（降级为独立 P3，不在本期范围）

**草案缺陷（评审 A-P2#5 / 审查 B-M1 / 审查 C-问题9）**：元数据明文化（§4）与 Keyring/Journal **无技术依赖**——它改动的是 `ManifestCrypto.serialize/deserialize` 的 manifest 序列化格式，影响所有设备间的 manifest 互通协议；而 Keyring 只影响客户端内部密钥记账。两者强行捆绑会增加本期风险且无收益。

**更严重的兼容性风险（评审 C-问题9）**：旧客户端的 `ManifestCrypto.deserializeHeaderOnly`（`sync_models.dart:767`）**不检查 `schemaVersion`**。若旧客户端拿到"彻底明文+HMAC"格式的 manifest，会尝试用 dataKey 解密 items——但 items 已是明文，解密必失败。本期（G5）已不兼容旧客户端，但该风险仍意味着**元数据明文化须独立评估、按 `schemaVersion=2` 推行**，不能夹在 Keyring 重构里。

**结论**：本期（P2）**不做**元数据明文化，列为**独立 P3** 评估。若未来实施，须先澄清草案 §4 的自相矛盾：

- **排除草案原"保留信封仅 items 明文"**：`ManifestCrypto.serialize`（`sync_models.dart:701-719`）当前是 `[4字节头长][header明文][AES-GCM(dataKey, items)]`——"AES-GCM 信封"本身即对 items 加密，"把 items 内部改为明文体"与"保留 AES-GCM 外壳"互斥，草案表述自相矛盾（审查 B-M1）。
- **未来仅两个真实选项**（由 `schemaVersion=2` 区分解析路径）：
  - **选项 B（默认不动）**：items 保持 AES-GCM 加密（现状），收益为 0，仅作记录。
  - **选项 C**：body 改为明文 JSON，header 内嵌 `itemsHmac = HMAC-SHA256(dataKey, itemsJSON)`，解析时先验 HMAC；**需所有客户端先升级到支持 schemaVersion=2 的版本**，旧客户端在升级前仍是加密格式——这是唯一安全的推行路径。
- 该改动不碰 blob 格式、不碰 KDF，满足 G6。

---

## 5. 迁移方案（方案 B：干净切断 + 一次性转换，无双写）

| 阶段 | 内容 | 兼容策略 |
|---|---|---|
| 1 | 新增 `Keyring` 类（**取代 Vault**，持 dataKey/mk + 账本）；删除 `Vault` 类；全仓 56 处 `vault.` 机械重命名为 `keyring.`；`sync_meta` 写 `keyring` JSON 为唯一权威 | G5 干净切断：不镜像旧键；旧数据经 `fromLegacyMeta` 一次性转换 |
| 2 | `ManifestHeader` 改为 `keyring.toManifestHeader()` 投影（消除 `_buildLocalManifest` 内联构造）；`SyncEngine` 拉远端 header → 重建 `Keyring`（`fromRemoteHeader`，history 为空=设计约束） | header 字段完整（schemaVersion/dataKeyWrap/createdAt/kdf），新客户端互通 |
| 3 | 引入 `Journal`（本地沙盒文件先落地）；`SyncEngine` 关键节点 `append`（§3.5）；落地恢复流程（§3.6 的可重放 + 远端副本） | journal 本地，无网络开销；远端副本防单点 |
| 4 | （P3 项，本期不做）元数据明文化由 `schemaVersion` 控制 | — |
| 5 | 移除旧 `Vault` 散字段 / `DataKeyHistory` 表读取分支（转换后旧键废弃）；清理一次性转换遗留 | 仅在所有客户端升到阶段 2+ 后 |

**一次性转换逻辑（补评审 D 缺口，方案 B 下即升级路径）**：现有代码**无**"旧 vault 首次被新客户端打开 → 从 meta 旧字段重建 Keyring"的实现。阶段 1 须在 `Keyring.unlockLocal()` / `unlockFromRemoteManifest()` 中增加：若 meta 无 `keyring` 键，则 `Keyring.fromLegacyMeta(db)` 构造并 `persist`，随后按正常路径用 `mk` 解开 `current.encryptedDataKey` 得 `dataKey`。**转换是一次性、不进长期代码**（G5）。

**持有引用替换（补评审 B-H1 / M3）**：`SyncEngine` 对 `keyring.changePassword / migrateToRemote / migrateToRemoteVault` 的调用**均返回新 Keyring 实例**，必须 `keyring = await keyring.xxx(...)` 更新持有的 `keyring` 引用（`:765,793`），`mk`/`dataKey` 不持久化，仅随新 Keyring 在会话内更新。

---

## 6. 安全分析

- **Keyring 本地存储**：敏感字段（`encryptedDataKey`）已是 MK 包裹，明文 meta 不泄露 dataKey；`keyFingerprint/keyVersion/dataKeyEpoch/kdf` 非密。与现状等价。
- **Keyring.history**：含旧 `wrappedDataKey`，需旧密码（旧 MK）才能解——与现状 `DataKeyHistory` 等价，合理；且为 local-only，不上远端。
- **Journal 泄露面（补评审 C-问题10）**：journal 记录的是**操作序列**（"3 分钟前改了笔记 X、5 分钟前删了笔记 Y"），比静态 manifest items 更敏感——操作序列可推断用户行为模式。缓解：
  - 默认**本地沙盒存储**（仅本机，与本地数据库明文等价；DB 本身已是明文）；不强制上远端。
  - journal **不记录笔记内容**，仅元数据事件（uuid/hash/操作类型/设备/时间）。
  - 远端副本整体 `AES-GCM(dataKey)` 加密（复用 `ManifestCrypto` 思路），不写明文到易被导出的位置。
- **威胁模型**：恶意/故障服务端已由 P0/P1 覆盖（代际备份、软删除隔离、自愈）；keyring/journal 不引入新攻击面。

---

## 7. 决策记录（原开放问题 D1–D5 + 方案/角色两项）

| 问题 | 结论 | 理由 |
|---|---|---|
| **方案选择 A vs B** | **方案 B：Keyring 取代 Vault** | 放开兼容性后，56 处 `vault.` 仅机械重命名、编排逻辑不变；方案 B 无委托桥/双写/旧键镜像，密钥层代码更少、架构更清晰（详见 `p2-keyring-complexity-analysis.md` §2/§3） |
| **Journal 角色** | **可恢复 + 审计（双角色）** | 恢复草案原意（G2 崩溃安全/§3.5/manifest 单点）；进程内原子性归 SQLite，跨边界部分写/数据丢失/服务端单点由 Journal 负责 |
| **D1 元数据明文化** | **本期不做，降级为独立 P3**（§4） | 与 Keyring/Journal 无技术依赖；旧客户端不检查 schemaVersion，明文 manifest 会导致解密失败（评审 C-问题9）；应独立评估、按 schemaVersion=2 推行 |
| **D2 Journal 上远端 / 全局合并** | **per-device 本地 + 远端副本作为一等公民第二数据源（防单点）**；首版不做全局合并 | 降低冲突合并复杂度（契合 G4）；远端副本是 SPOF 兜底（§3.3/§3.6），非仅冷备 |
| **D3 Keyring.history 上限** | **最近 20 条（按 keyVersion 去重）**，local-only | 约 20 次改密码/迁移的恢复窗口足够；避免无限增长（§2.6） |
| **D4 Periodic dataKey rotation** | **P2 之外单列**，本期不做 | Keyring 结构已支持（history 留锚点），但属新特性，独立规划 |
| **D5 journal 滚动阈值** | **单文件 1000 条或 100KB**，归档保留最近 3 个 | 参考 manifest 代际备份；平衡 IO 与内存（§3.3） |

---

## 8. 测试策略（实现阶段）

- **Keyring 单测**（`test/sync/keyring_test.dart`）：`createNew` / `changePassword`（history 压栈、keyVersion+1、dataKeyEpoch 不变、mk 更新）/ `migrate`（dataKeyEpoch+1、history 含旧条目）/ `adoptRemoteEpoch`（**字段级更新、dataKey/mk 保留**，等价性单测覆盖，防止回归 C2）/ 旧密码 repair（从 history 取旧 wrappedDataKey）/ `fromLegacyMeta` 重建往返 / `toManifestHeader` 字段完整性。
- **Journal 单测**（`test/sync/journal_test.dart`）：`append` / 滚动归档（1000 条/100KB 触发）/ `seq` 单调递增 / **恢复流程**（模拟 migrate 未完成重启，断言跨边界部分写可被重放拉回一致点；模拟本地库+本地 journal 均丢失，断言可从远端 journal 副本重建 key state）/ 远端副本加密往返。
- **兼容/迁移**（`test/sync/migrate_test.dart`）：旧 vault 一次性 `fromLegacyMeta` 转换（转换后旧键可废弃）；全仓 `vault.`→`keyring.` 重命名后 `flutter analyze` 零告警。
- **现有 Vault 测试迁移（补评审 B-L4）**：`test/` 下既有 Vault 测试（如 `vault_test.dart`、`change_password_multi_client_test.dart`）随重构改写，断言 Keyring 字段与 `current` 一致；新增"无 `keyring` 键时从旧 meta 重建"测试。
- **混沌**：随机翻转 keyring/journal 落盘文件、随机杀掉同步进程，断言同步仍收敛、跨边界部分写可被 journal 重放修复、不静默丢失（沿用 P0/P1 混沌框架）。

---

## 9. 风险与缓解

| 风险 | 缓解 |
|---|---|
| 阶段 2 投影写错导致远端纪元回滚 | `Keyring.toManifestHeader()` 为唯一出口；单测覆盖 `adoptRemoteEpoch` 等价性（字段级更新） |
| journal 写入拖累同步性能 | 内存环形缓冲 + 批量异步 flush（每 100ms 或 50 条）；本地文件，无网络开销 |
| 跨边界部分写导致不一致 | Journal 记录"意图→提交后完成"，恢复以 DB 为准 + 有限重放（§3.6b） |
| 重放正确性（二次损坏风险） | 严格单测 + 混沌验证重放语义（§3.6 代价，§8 混沌项） |
| 服务端 manifest 单点 | 远端 journal 副本作为第二数据源（§3.3/§3.6c） |
| Keyring.history 无上限增长 | D3：最近 20 条 + 按 keyVersion 去重 |
| 旧字段清理（G5） | 阶段 5 删除旧键读取分支；转换逻辑一次性、不进长期代码 |

---

## 附录 A：逐条修正对照表（相对草案）

> 每条均标注：草案问题 → 对应评审编号�� → 代码证据 → 修正动作。评审编号：A=`review-a`(mcxiaoke)、B=`review-b`(C1/C2 独立审查)、C=`review-c`、D=`review-d`(opencode)。

| # | 草案问题 | 评审 | 代码证据 | 修正（本文位置） |
|---|---|---|---|---|
| 1 | Keyring 无 `dataKey`/`mk`，"取代 Vault" 后无法加解密 | A-P0#1 / B-C1 / C-问题1,2 | `vault.dart:139,194`；`sync_engine.dart:114`；`database_handler.dart:103,117,628` | §2.1 **方案 B**：Keyring 持运行时 `dataKey`/`mk` + 账本，直接取代 Vault（56 处 `vault.` 机械重命名为 `keyring.`） |
| 2 | `adoptRemoteEpoch → current = KeyringEntry.from(remote)` 整条目替换 | B-C2 | `vault.dart:808-837`（注释"dataKey 不变"） | §2.5 改为 `copyWithCurrent` 字段级更新，保留 dataKey/mk，杜绝回归 BUG-3 |
| 3 | `toRemoteHeader` 缺 `schemaVersion/createdAt/kdf/dataKeyWrap` | A-P1#3 / B-L3 | `sync_models.dart:263,279,305,308` | §2.3 补全 `toManifestHeader` 字段 |
| 4 | `fromRemoteHeader` 无法重建 history | A-P1#2 | `sync_models.dart:259-338`（header 无 history） | §2.5 明确为 local-only & best-effort 设计约束，远端不投影 |
| 5 | Journal 被当作崩溃恢复层，与 SQLite 事务重叠（v1 过度降级为审计-only） | A-P1#4 / B-M2 / C-问题5 | `database_handler.dart:628-688`（step5 单事务） | §3.1/§3.6 **恢复双角色**：进程内原子性归 SQLite，跨边界部分写/数据丢失/服务端单点由 Journal 负责（草案 G2/§3.5/manifest 单点原意） |
| 6 | 重构范围遗漏 `sync_engine.dart`/`database_handler.dart` | B-H1 | `sync_engine.dart:54-80,358,766,793`；`database_handler.dart:73-92,770-783` | §2.4/§5 扩展映射与持有引用替换 |
| 7 | 本地 journal 载体/滚动未定义，远端目录表述矛盾 | B-H2 / C-问题6,7 | `local_fs_backend.dart` 沙盒物化；`server-api-spec.md §5.10` | §3.3 本地优先 + 沙盒文件 + 阈值 1000 条/100KB；远端副本上升为第二数据源 |
| 8 | 元数据明文化与 Keyring 耦合，且旧客户端兼容风险 | A-P2#5 / B-M1 / C-问题9 | `sync_models.dart:767`（旧客户端不查 schemaVersion） | §4 降级为独立 P3（G5 已不兼容旧版，但明文化须独立按 schemaVersion=2 推行） |
| 9 | `dataKeyEpoch` 在 journal 中语义不清 | A-P2#6 | `vault.dart:542-547,651-657`（`!_sameKey` 才 +1） | §3.2 明确仅记录、不参与时序判断 |
| 10 | 双写"既双写又仅读不写"矛盾 | A-P2#7 / B-M4 / C-问题8 | `database_handler.dart:73-92`（多键无事务） | §2.7 方案 B：keyring 单键唯一权威，旧键不镜像、一次性转换（无双写） |
| 11 | `wrappedByHint` 冗余 | A-P2#8 / B-L2 / C-问题4 | `sync_engine.dart:562-585`（用 keyFingerprint 匹配 MK） | §2.2 删除，复用 keyFingerprint |
| 12 | `reason` 枚举遗漏场景 | A-P2#9 | `vault.dart:732-785`（changePassword 返回新实例） | §2.2 枚举补 `adoptRemoteEpoch`/`migrateDataKey`/`unknown` |
| 13 | `history` 无上限 | A-P2#10 / D-D3 | `database_handler.dart:776`（仅去重） | §2.6 上限 20 条 + 按 keyVersion 去重 |
| 14 | Journal 注入点未定义 | A-P2#11 | `sync_engine.dart:358,755,776,902,1689` | §3.5 SyncEngine 构造依赖 + 注入点表 |
| 15 | `mk` 生命周期/引用替换未说明 | B-M3 | `vault.dart:732-785`；`sync_engine.dart:765,793` | §2.5/§5 changePassword/migrate 后更新持有 keyring 引用 |
| 16 | legacy 字段无来源默认值 | B-L1 | `database_handler.dart:770-783`（仅 3 字段） | §2.2 `archivedAt=0`/`reason='unknown'` |
| 17 | §4 "items 解密失败=单点放大" 夸大 | B-L5 | `sync_models.dart:728-759`（先解 header 后解 items） | §4 修正：仅 dataKey 错误时 items 失败，属预期鉴权失败 |
| 18 | §4 两候选方案自相矛盾 | B-M1 | `sync_models.dart:701-719`（AES-GCM 即加密 items） | §4 排除"保留信封仅 items 明文"，仅留 B/C 两真实选项 |
| 19 | Journal 与 DB 事务一致性风险 | D-§5 | `database_handler.dart:663` | §3.6 "意图→提交后完成"，journal 仅诊断/有限重放，不替代事务 |
| 20 | 升级路径"从旧字段重建 Keyring"无实现 | D-§2.4 | 现状无此逻辑 | §5 明确 `fromLegacyMeta` 在 unlock 中一次性落地（G5 不进长期代码） |
| 21 | 旧客户端读新 manifest 兼容性缺口 | D-§2.6/D1 | `sync_models.dart:767` | §4/§7 D1 本期不做；G5 已不兼容旧版 |
| 22 | journal 泄露面被低估 | C-问题10 | journal 含操作序列 | §6 补：本地优先、不记内容、远端副本加密 |

---

## 附录 B：代码证据索引（文件:行号）

| 文件:行号 | 印证事实 |
|---|---|
| `lib/sync/vault.dart:139` | `final Uint8List dataKey;`（运行时，不持久化）——方案 B 移入 Keyring |
| `lib/sync/vault.dart:194` | `final Uint8List? mk;`（运行时 MK 缓存）——方案 B 移入 Keyring |
| `lib/sync/vault.dart:208-215` | `copyWith`（保留 mk 缓存） |
| `lib/sync/vault.dart:732-785` | `changePassword` 返回新实例（dataKey 不变、mk=newMk） |
| `lib/sync/vault.dart:808-837` | `adoptRemoteEpoch` 仅更新包裹/纪元字段，dataKey 不变 |
| `lib/sync/sync_models.dart:259-338` | `ManifestHeader` 含 schemaVersion/createdAt/kdf/dataKeyWrap，无 history |
| `lib/sync/sync_models.dart:701-719` | `ManifestCrypto.serialize` = `[头长][header][AES-GCM(dataKey, items)]` |
| `lib/sync/sync_models.dart:728-759` | `deserialize` 两阶段：先 header 明文、后 items（dataKey 错误才失败） |
| `lib/sync/sync_engine.dart:114` | `get _dataKey => vault.dataKey;`（方案 B → `keyring.dataKey`） |
| `lib/sync/sync_engine.dart:358,755,766,776,793,823,902,1689` | adoptRemoteEpoch/_executeMigration/migrate/_buildLocalManifest/_mergeAndTransfer/_gcOrphanBlobs 调用点（方案 B 下对象名 `keyring`） |
| `lib/data/database_handler.dart:73-92` | `MetaKeys`：`vault_id/encrypted_data_key/kdf_salt/key_fingerprint/key_version/vault_created_at/data_key_epoch/data_key_history` |
| `lib/data/database_handler.dart:628-688` | `reEncryptAllNotes` 单事务写回（step5 `db.transaction`）——进程内原子性 |
| `lib/data/database_handler.dart:770-783` | `appendDataKeyHistory` 仅存 `{keyVersion, wrappedDataKey, keyFingerprint}`，按 keyVersion 去重 |
| `docs/server-api-spec.md §5.10` | v2.2 resources API（`move/mkdir/copy/propfind`）支持 journal 远端副本 |

---

*修订基于 safenotes 代码基线（vault.dart 890 / sync_models.dart 782 / sync_engine.dart 1847 / database_handler.dart 902 行），对照四份评审报告核实每处修正；v2 进一步放开兼容性约束，采用方案 B 并将 Journal 恢复为可恢复+审计双角色，决策过程见 `docs/p2-keyring-complexity-analysis.md`。*
