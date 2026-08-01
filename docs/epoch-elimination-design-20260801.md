# 密钥纪元消除设计（epoch 自愈 → item 自描述 + 只读解密）

日期：2026-08-01（v3.1，不兼容策略 + 业界机制调研）
状态：设计评审（未实现）
关联事故：`docs/CHANGES-20260801.md`（真实数据：8 条 manifest 声称 epoch2、blob 实为 epoch1 的脏数据）
演进基线：git `100cffa`（P6/P7 修复 + 设计转向文档）、`cb1eef0`（Q&A 补充）

## 0. 兼容性策略（v3 明确，全篇约束）

**本方案不做任何旧版本/旧数据兼容。** 直接删、直接改：

- 不保留 v1 uuid-AAD、epoch=0、旧密钥 blob 的只读解码路径。
- 不保留老客户端共存逻辑（老客户端读不懂/写覆盖由「全量升级」处理，不做渐进兼容）。
- 存量数据直接按新语义迁移（DB schema v4 一刀切），不留回退分支。
- 与上一批「移除迁移/兼容/fallback 代码」的决策一致（见 git `b382839`）。

以下各节所有「保留只读兼容」「兼容回退」「老设备升级期」表述一律作废，按此策略执行。

## 1. 问题回顾

### 1.1 事故根因（真实数据还原）

- 两端用同一密码初始化，但 **dataKey 随机生成 → 各自不同**（设计使然）。
- Android 首次同步触发 scenario-d 迁移（旧 journal seq=1/2），采用远端 dataKey、epoch 1→2、keyVersion 采用远端值。
- 迁移后 **epoch 分裂**：Android=2（已迁移）、Windows=1（未迁移，改密码不碰 epoch）。
- 分裂期间 Windows 下载到 Android 的 epoch-2 blob，`_downloadNote` 的 heal 分支用 `!=`（L1783）判断方向，**2≠1 即触发** → 用本地低纪元 1 重传覆盖服务器高纪元 blob → 翻转开始。
- 双方反复互相覆盖，最终 8 条 manifest 声称 epoch2、blob 实为 epoch1。

### 1.2 结构性根因

epoch 被当成**全局状态机**（两端必须收敛到同一数值），由此衍生「谁对谁错」判定 → 自动重写 → 方向错即翻转。但 epoch 本质只是**加密参数的版本标签**，不该驱动任何「纠正」行为。

### 1.3 epoch 引入的历史（为什么会堆成这样）

- **原始问题（07-28）**：多端改密码时 `encryptedDataKey` 互相覆盖（翻转战争），因 header 缺密钥纪元字段，无法区分「我密码错」还是「他端改了密码」。
- **第一层修复**：header 加 `keyFingerprint` + `keyVersion` + 引擎纪元守卫（远端 keyVersion 更高时不回滚远端包裹）。
- **第二层（07-29 Layer 3）**：拆出 `dataKeyEpoch`（dataKey 值真变才 +1）与 `ManifestItem.blobKeyEpoch`，下载侧检测旧纪元 blob 就**用当前纪元重传**（heal）。
- **失控点**：epoch 从「防翻转」工具变成「自动现代化」触发器，而 heal 用 `!=` 无方向守卫——在 epoch 分裂时（本方案正是要处理这种分裂）把翻转战争从 header 层搬到 blob 层。

## 2. 关键概念澄清（避免混淆）

### 2.1 改密码 ≠ 迁移（epoch 语义）

| 动作 | keyVersion | dataKeyEpoch | dataKey 值 |
|---|---|---|---|
| 改密码 | +1 | **不变** | 不变（只重 wrap） |
| scenario-d 迁移 | 采用远端值 | +1（dataKey 真变时） | 变（采用远端 dataKey） |
| 新设备加入 | 采用远端值 | 跟随远端，**不 +1** | 变（采用同一 dataKey） |

改密码不重加密数据（dataKey 没变）；epoch 只在 dataKey 值真变时递增。改密码后 server 上同步的只有 header 包裹层，blob 零改动（日志实证：15:48:04 Windows 改密码后 `uploaded=0`）。

### 2.2 dataKey 是随机生成的

即使两端同密码初始化，dataKey 也不同（随机 32 字节）。因此**任何新设备首次 join 必然经历一次 scenario-d 迁移**（采用远端 dataKey），这是设计使然、不可规避。

### 2.3 「怎么检测 dataKey 不同」

dataKey 从不在线比较（只在本地）。通过「本地 MK 能否解开远端 encryptedDataKey」间接判断（`keyring.dart checkMigrationNeeded` L531-560）：

```
比较本地/远端 encryptedDataKey
  ├─ 完全相同 → 无需迁移（同 vault）
  └─ 不同 → 用本地 MK（密码派生）解远端 encryptedDataKey
           ├─ 解开 → 密码相同，直接采用远端 dataKey（迁移）
           └─ 解不开 → 密码不同(scenario-c) 或 salt 不同(scenario-d)
```

## 3. 业界机制调研（2026-08-01，8 款产品对照）

目的：验证「item 自描述 + 只读解密 + 删自动改写」是否为业界主流做法，提取可借鉴机制并对照本方案缺口。

### 3.1 产品机制一览

| 产品 | 同步模型 | 冲突处理 | 增量同步 | 版本历史 | 密钥 / 加密模型 | 对本方案启示 |
|---|---|---|---|---|---|---|
| Joplin | 服务端 relay（全量 JSON manifest 对比） | 冲突副本（conflict note） | delta（字段级 diff） | 有（revision） | **多 master key 并存**：item 记录自己用的 master_key_id，解密按 key id 选 key；改密码只重 wrap，数据零重加密；旧 key 数据提示输旧密码 → **渐进式**重加密（不自动覆盖） | item 自描述 key 标识 = 主流标准（已采纳 §4） |
| Standard Notes | 服务端 relay（items + sync token） | 冲突副本 | 有 | 有 | rootKey（密码派生）包裹 itemsKey，itemsKey **immutable**；改密码只重包裹；渐进式重加密 | 同 Joplin：key 标识跟 item 走，绝不自动改写 |
| Obsidian Sync | 文件级（md 逐文件 receive/send） | markdown 用 diff-match-patch 自动合并；非文本 LWW 或冲突副本 | 逐文件 | 有（version history） | 文件 E2EE；元数据（设备/时间戳/路径映射）明文 | 文本合并不适用于整条 blob；版本历史是「删自动覆盖」后的安全网 |
| Logseq | 本地文件 + 官方/第三方文件同步（git/WebDAV） | 文件级 LWW + git 冲突 | 文件级 | git 历史 | 可选加密插件 | 单用户文件级 LWW 足够 |
| AppFlowy | 本地优先 + CRDT（yrs，CollabKVDB）+ 服务器 relay | CRDT 字段级自动合并 | CRDT 增量 | 有 | 服务器不可见明文 | CRDT 对「整条笔记 blob」过重，不采纳 |
| Notion | 云优先 CRDT，服务端权威 | CRDT 合并 | CRDT 增量 | 有 | 服务端权威，非 E2EE | 服务端权威与 E2EE 冲突，不采纳 |
| Outline | 服务端权威（WebSocket 实时协作） | 服务端权威 | 实时 | 有 | 非 E2EE | 不采纳（无本地优先、无 E2EE） |
| Trilium | 本地 SQLite + 自托管服务器，树 diff | 树级冲突（LWW/冲突页） | 树 diff | 有 | 非 E2EE | 树结构不符 |

### 3.2 业界共识（可借鉴点）

1. **item 自描述 key 标识 + 解密按 item 选 key，绝不自动改写** —— Joplin / Standard Notes 一致。safenotes 采纳为核心方案（§4）。这是消除「epoch 翻转」的制度性关键。
2. **改密码只重包裹 key，数据零重加密** —— Joplin / Standard Notes 一致。safenotes 已做对（§2.1）。
3. **重加密是「用户主动 / 显式迁移触发」，不是同步引擎隐式动作** —— Joplin 渐进式重加密（每编辑一条才换新 key）、Standard Notes itemsKey immutable。safenotes 采用一次性显式迁移（§5.3），更简单且数据量小。关键：**绝不把「重加密 / 重写」挂在下载路径上**——这正是 heal 的错误。
4. **收到更旧协议 → 拒绝（防降级）** —— Joplin 对旧协议版本拒绝。safenotes 应在下载侧校验 `manifest.header.schemaVersion`，低于当前版本直接拒绝并提示「请升级」，不做兼容解读。这补全了不兼容策略 §0 的执行细节（见 §3.4[G]）。
5. **版本历史 / 冲突副本是「删除自动覆盖」后的安全网** —— Obsidian version history、Joplin conflict note。safenotes 已有 `manifest-backup/` 代际备份应对覆盖类事故（见 §3.4[H]）；冲突副本可作后续可选增强（LWW 丢弃失败方内容前先存副本）。

### 3.3 明确不采纳项

| 机制 | 为何不采纳 |
|---|---|
| CRDT（AppFlowy/Notion） | 单用户单端写、整条笔记 blob 粒度，LWW（updatedAt）+ item 自描述已足够；CRDT 的字段级合并、tombstone、GC 对 32 字节级 blob 是纯负担 |
| 服务端权威（Notion/Outline） | 与 E2EE（服务端不可信）直接冲突 |
| 增量 / delta 同步（Joplin delta） | 数据量小（KB 级），全量 manifest 对比即可；delta 徒增服务端复杂度 |
| 文件级文本合并（Obsidian diff-match-patch） | blob 是整条密文，无法做文本级合并；合并不适用于单 blob |
| 多 key 并存 | 单用户单 vault 场景下，多 key 唯一价值是「旧密码数据渐进可读」；safenotes 采用一次性迁移 + 不兼容策略，无需多 key 复杂度 |

### 3.4 调研新增发现（补充 §8 审查）

**[G] 协议降级拒绝（新发现）**：业界对旧协议一致「拒绝而非兼容」。方案 §7.1 已定协议 v3→v4，但未明确下载侧行为。补充：`_downloadManifest` 校验 `header.schemaVersion`，`< v4` → 抛 `_IncompatibleVersionException`（提示升级），**不解读、不迁移、不覆盖**。同时堵住「老客户端写覆盖新协议」的最后窗口（§0 的执行细节）。

**[H] `manifest-backup/` 代际备份定位（确认）**：调研确认版本历史是防覆盖类事故的标准兜底。safenotes 的 `manifest-backup/` 代际备份保留，其定位升级为「防覆盖事故的版本历史」——即使未来再有错误覆盖，可从代际备份恢复。

**核心差异小结**：safenotes 的 L3 heal「自动用当前纪元重传覆盖他人数据」违反第 1 条业界共识，是事故的制度性根源；本方案删自动改写、保留 item 自描述 + 只读解密，正与 Joplin/Standard Notes 对齐。

## 4. 根本方案：item 自描述 + 只读解密

1. **`blobKeyEpoch` 是 item 写死的自描述属性**：谁加密谁定，解密端不推断、不比较、不纠正。
2. **解密端是纯函数**：用 item 声明的 epoch 解密 → 能解就物化显示 → 解不开就报「缺 key / 密钥不符」。
3. **解不开时提示用户**（输旧密码 / 手动 `repairRemote()`），**不做任何自动重传**。

### 4.1 关键设计要点：用「DB 持久化真实 epoch」取代「乐观声明 + 重传闭环」

现状 `_buildLocalManifest`（L1038-1058）**不持久化** blobKeyEpoch，而是乐观声明 `blobKeyEpoch = keyring.dataKeyEpoch`，靠 `markAllForBlobReupload` → `pendingReupload` → `_mergeAndTransfer` 强制重传的闭环让「声明」与「实际 blob」对齐。这套闭环正是要删的。

**删掉闭环后必须补**：DB 持久化每条笔记的真实 epoch，否则声明成空头支票：

1. `safe_notes` 表新增 `blob_key_epoch` 列（schema v3→v4 迁移）。
2. `_uploadNote` 加密时把实际用的 epoch 写入该列。
3. `_buildLocalManifest` 直接读该列（删乐观声明）。
4. 迁移（scenario-d / scenario-c）时 `reEncryptAllNotes` 一次性更新该列；远端 blob 由**一次性重传**更新（取代常驻 pendingReupload 闭环）。

## 5. 数据流（改后各场景）

### 5.1 正常多端同步（无密钥变更）
```
A 写笔记 → blob(epoch=N) + DB 记 N + manifest item(blobKeyEpoch=N)
B 同步   → 下载 item → 用 item 声明的 N 解密 → 能解 → 物化
          （不比较、不推断、不重传）
```

### 5.2 改密码（keyVersion+1，dataKey 不变）
```
A 改密码 → 重 wrap dataKey，只更新 header；blob 与 item 全不动
B 同步   → 本地 dataKey 不变 → 能解所有 blob → 正常对账
```

### 5.3 scenario-d 迁移（dataKey 真变，epoch+1）
```
B 首次加入 → checkMigrationNeeded 检测到 dataKey 不同 → migrateToRemoteVault（一次性）
           → reEncryptAllNotes：本地全部用新 dataKey 重加密 + DB 记新 epoch
           → 一次性重传本地 blob（新纪元密文）+ manifest item 自描述新 epoch
           → 之后两端 item 自描述同一 epoch，纯内容级对账
```

### 5.4 密钥错乱/损坏（改后与现状的关键区别）
```
B 下载 item(epoch=2) 但本地没有 epoch2 的 key（或解不开）
  改前：heal 用本地 epoch=1 重传覆盖 → 翻转（事故）
  改后：只解密 → 失败 → 报「缺 key / 密钥不符」→ 提示输旧密码或 repairRemote
       （绝不自动写任何东西）
```

## 6. 复杂度评估（改前 vs 改后）

判据：**改后代码量（含新机制）> 改前 → 方案不合格，弃用**。

### 6.1 改前：与 epoch 自动重写相关的代码（`lib/sync/sync_engine.dart`）

| 函数 / 机制 | 位置 | 行数 | 命运 |
|---|---|---|---|
| `repairRemote`（全量修复） | L631-880 | ~250 | **保留**（用户主动路径） |
| `_buildLocalManifest`（乐观声明 epoch + override 三元组） | L1013-1077 | ~65 | 瘦身 |
| `_mergeAndTransfer`（含 pendingReupload 重传分支） | L1091-1313 | ~223 | 瘦身 |
| `_probeBlobEpoch`（探测实际纪元） | L1634-1670 | ~37 | **删除** |
| `_downloadNote`（含 Layer3 heal「纪元不符→当前纪元重传」） | L1671-1913 | ~243 | 瘦身（删 heal） |
| `_handleDownloadFailure`（本机明文/孪生自愈重传） | L1914-2010 | ~97 | 瘦身 |
| `adoptRemoteEpoch` 调用 + `epochMismatch` 状态机 + override 三元组 + 引擎内 `markAllForBlobReupload` 调用 | 全文件散落 | ~100（估） | **删除**（DB 方法保留） |
| **改前小计** | | **~1015 行** | |

### 6.2 改后：保留的 + 新增的

| 项 | 行数 | 说明 |
|---|---|---|
| `repairRemote` | ~250 | 保留不变 |
| `_buildLocalManifest` | ~50 | 删 override/乐观声明，`blobKeyEpoch` 直接读 DB 持久化值 |
| `_mergeAndTransfer` | ~180 | 删 pendingReupload 分支 |
| `_downloadNote` | ~160 | 删 heal 重传分支；解密失败直接报 `corrupt` |
| `_handleDownloadFailure` | ~30 | 仅剩「记录失败 + 提示 repair」，删两层自动自愈重传 |
| 新增：`_blobMissingKeyError`（解密失败提示） | ~15 | 明确报「缺 key」而非猜测 |
| 新增：DB schema v4 `blob_key_epoch` 列 + 迁移 | ~20 | 持久化真实 epoch（§4.1 关键要点） |
| **改后小计** | | **~705 行** |

> **备注（v2 审查修正）**：`markAllForBlobReupload` / `pendingReupload` / `clear|removePendingReuploadUuids`
> 这套 **DB 基建保留**（迁移重传的可靠执行机制，见 §8.2[D2]），删除的是引擎内常驻分支
> （`_mergeAndTransfer` 的强制重传分支、`_buildLocalManifest` 乐观声明）与 `adoptRemoteEpoch`
> 的调用。故 §6.1 中「`markAllForBlobReupload` 删除」表述修正为「**引擎内调用删除，DB 方法保留**」，
> 删除行数相应下调（约 -50 而非 -100）。

### 6.3 结论

- **净减约 -310 行（约 -30%）**，删的是最危险、最难测的分支（自动重写、探测、双向翻转），保留一次性显式迁移与用户主动修复。
- 删掉 3 个状态变量与常驻分支（`epochMismatch`/`overrideXxx`/`pendingReupload` 强制重传分支），分支复杂度显著下降；`markAllForBlobReupload` 等 DB 方法保留作迁移重传基建（§8.2[D2]）。
- `keyring.dart` 侧：`adoptRemoteEpoch`、`markAllForBlobReupload` 删除（约 -50 行），`migrateToRemoteVault`（显式迁移）保留。
- 满足判据：改后代码量下降，方案合格。

### 6.4 代价（接受项）

- 解密失败从「自动修复」变为「提示 + 手动 repair」——UX 略降。
- 迁移（scenario-d / scenario-c）仍是显式一次性动作，代码保留，不属本次删减范围。

## 7. 协议影响与架构权衡

### 7.1 协议字段

- **`ManifestItem.blobKeyEpoch` 保留**（item 自描述），语义从「待现代化」变为「加密版本标签」。
- `ManifestHeader.dataKeyEpoch` 保留，仅作元数据，不再驱动同步行为。
- **字段结构不变，序列化格式沿用**；但 `blobKeyEpoch` 语义已变（「待现代化」→「加密版本标签」），`dataKeyEpoch` 不再驱动同步——**协议版本号须递增**（v3→v4），旧客户端按不兼容策略 §0 不兼容。需同步更新 `docs/sync-protocol-spec.md`（§blobKeyEpoch 语义）与相关测试。

### 7.2 关于「解密只认 item，header 纪元不参与」

下载解密链路唯一依据是 `item.blobKeyEpoch`；`header.dataKeyEpoch` 不参与。即使「header 声明 2、item 是 1」，解密层面完全无害（item 自描述，用它的 1 去解）。header 的 2 纯元数据。

### 7.3 关于「items 加密」

items 含 `hash`（可对已知明文做字典比对）、时间戳、contentSize、数量——全是元数据指纹。E2EE 威胁模型包含「服务端不可信」，items 必须加密（Joplin/Standard Notes 一致）。header 明文是**带外引导**：新设备无 dataKey 时唯一能拿到的引导信息（KDF 参数 + encryptedDataKey）；一旦用密码解开 dataKey，items 自然解锁。两者分工刻意，不是不一致。**不可删减**。

### 7.4 关于「manifest/items 拆两个文件」

**不拆**。现状单文件 `manifest.json` 内嵌 header(明文)+items(加密)，一次 PUT/GET、一个 ETag，**原子性**最强（header 与 items 永远同版本）。拆开会丢原子性（两个 ETag 无法原子提交）、乐观锁分裂（两个版本号协调）、版本错配风险——正是本方案要消除的那类不一致。省的那点下载量不抵复杂度。

## 8. 深入审查（v2 新增）

### 8.1 审查范围
对方案完整性、逻辑一致性、边界场景做对抗性检查，重点寻找「删除 heal/adopt 后是否会引入新的不一致」。

### 8.2 发现的问题与对策

**[A] DB 列默认值问题（开放，须定案）**
现有存量数据没有 `blob_key_epoch` 列。schema 迁移时默认值取什么？
- 取 `keyring.dataKeyEpoch`：如果实际 blob 是旧纪元加密（迁移前），声明又与实际不符 → 回到同款坑。
- 取 1 / null：老数据 item 声明旧纪元，可能与他端声明不一致。
- **对策建议**：迁移时默认值取当前 `dataKeyEpoch`，且**存量 blob 必须在迁移流程中一次性重传对齐**（与 scenario-d 迁移的 reEncryptAllNotes + 一次性重传合并执行）；对新设备，join 后的首次同步即视为「迁移」，走同一路径。审查结论：必须把「DB 迁移」与「blob 重传」绑定成同一原子动作，否则 [A] 不成立。

**[B] 老客户端升级期风险（不兼容策略下作废）**
（不兼容策略 §0 已取消「渐进兼容」：老版本不共存，无需兼容窗口，直接全量升级后生效。）

**[C] 删除 `_probeBlobEpoch` 后的只读兼容（不兼容策略下作废）**
（不兼容策略 §0 已取消旧格式 blob（epoch=0 / v1 uuid-AAD）的只读解码路径，直接删除。）

**[D] `_blobMissingKeyError` 与 corrupt 的判定边界（开放）**
删除 probe 后，解密失败统一报 corrupt。如何区分「缺 key（可修复，输旧密码）」与「真损坏（不可修）」？
- 现状靠 `item.blobKeyEpoch != keyring.dataKeyEpoch` 区分（isOldKey，L2008）。
- 改后建议：**保留这条只读判定**（区分提示文案），但不触发任何自动动作。审查结论：这是「保留判断、删除动作」，符合方案精神，需在 `_handleDownloadFailure` 中保留 isOldKey 计算。

**[D2] `pendingReupload` 是持久化 meta，不是内存集合（v2 审查新发现）**
`blob_reupload_pending` 存于 DB meta（`database_handler.dart:89,834`），跨同步存活，且**失败重传保留标记**（`removePendingReuploadUuids` L869-879，P1 修复）。这对 §4.1「一次性重传取代常驻闭环」有直接影响：
- 若完全删除 `pendingReupload` 持久化，则「某次同步重传失败」后无标记可查，下次同步不会自动重试 → 旧密钥 blob 可能永久残留。
- **对策**：方案不要求删 `pendingReupload` 机制本身，而是删「乐观声明 + 常驻闭环」。迁移时「一次性重传」仍可利用该 meta 做失败重试——即：迁移触发时 `markAllForBlobReupload`（保留），成功清标记（保留），**删的只是 `_mergeAndTransfer` 里 `_itemsEqual && pendingReupload` 的强制重传分支与 `_buildLocalManifest` 的乐观声明**。重传行为在迁移流程内显式执行（对应 §4.1 第 4 点「一次性重传」），而非每次同步隐式兑现。
- 审查结论：**`markAllForBlobReupload`/`pendingReupload`/`clear/remove` 这套 DB 基建保留**（作为迁移重传的可靠执行机制），删的是引擎内常驻分支与乐观声明。账目修正见 §6.2 备注。

**[E] 迁移原子性（确认现有已满足）**
`reEncryptAllNotes` 单事务（crash 安全），`migrateToRemoteVault` 更新 keyring 后再 setDataKey。DB 列更新应与 reEncrypt 同事务。审查结论：实现时确认 `blob_key_epoch` 列更新在 `reEncryptAllNotes` 事务内完成。

**[F] 并发迁移互斥（确认现有已满足）**
`sync()` 单飞（同一时刻一个同步），迁移后抛 `_MigrationRequiredException` 触发重试。删除 adopt 不影响此互斥。审查结论：无回归。

**[G] 协议降级拒绝（调研新增，见 §3.4）**
下载侧校验 `header.schemaVersion`，`< v4` 直接拒绝并提示升级，不做兼容解读、不迁移、不覆盖。审查结论：补全不兼容策略 §0 的下载侧执行细节，与业界「拒绝旧协议防降级」一致，纳入实施。

### 8.3 审查结论
方案逻辑自洽，核心方向（item 自描述 + 只读解密 + 删自动重写）正确，与业界共识（§3.2）对齐，净减代码满足判据。**实现前必须定案 [A]（DB 默认值 + 迁移重传原子绑定）与 [D]（corrupt 判定保留只读 isOldKey）**，否则会有新不一致。兼容类风险（[B]/[C]）按不兼容策略 §0 已直接排除；[G]（协议降级拒绝）为新增实施项，纳入 §10。

## 9. 风险

- **不兼容策略风险（接受）**：旧版本客户端无法与新版本共存；旧数据（epoch=0 / v1 格式）一次性迁移，无回退。作为安全应用，全量升级是可控前提。
- **数据迁移风险（须做备份）**：schema v4 + blob 重传是破坏性操作，实施前对生产 DB 做备份。
- 测试：删减的 heal/翻转分支对应测试改为「解密失败→corrupt+提示」断言。

## 10. 实施顺序建议

1. **先定案 [A][D]**（见 §8.2），更新本设计后再动代码。
2. 生产 DB 备份（不兼容迁移为破坏性操作）。
3. DB schema v4（`blob_key_epoch` 列）迁移 + 存量 blob 一次性重传对齐（[A] 原子绑定）。
4. 删 heal/probe/adopt/override 引擎常驻分支、`_downloadNote` 解密失败报 corrupt+提示（含删除 epoch=0 / v1 兼容解码路径）。
5. `_buildLocalManifest` 读 DB 真实 epoch。
6. 协议版本 v3→v4，更新 `docs/sync-protocol-spec.md`；`_downloadManifest` 增加 schemaVersion 降级拒绝（[G]）。
7. 全量测试 + `make valid`。
8. 更新 CHANGES。
9. 观察一轮真实多端同步确认无翻转回归。
