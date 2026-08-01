# 密钥纪元消除设计（epoch 自愈 → item 自描述 + 只读解密）

日期：2026-08-01（v4.1，blob 纯化 + item 自描述指纹 + 删自动改写 + 全局可靠性审查）
状态：设计评审（未实现）
关联事故：`docs/CHANGES-20260801.md`（真实数据：8 条 manifest 声称 epoch2、blob 实为 epoch1 的脏数据）
演进基线：git `100cffa`（P6/P7 修复 + 设计转向文档）、`cb1eef0`（Q&A 补充）
合并来源：`docs/aad-epoch-removal-design-20260801.md`（blob AAD 去 epoch 的考古/致命点/自愈保留修订）+ `docs/sync-global-simplification-design-20260801.md`（P3 指纹判定、P4a 错误处理统一）；两文档为平行「改进替代」方案，可吸收项已并入本篇对应小节

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

> **致命点（吸收 aad-epoch-removal §1.1 精确还原）**：整个过程里 dataKey 值**相同**，blob 本来能正常解密。是 heal 分支的 `!=` 比较制造了「假性不兼容」——epoch 数字不同但 key 相同，本不该触发任何动作，却触发了覆盖。epoch 进 AAD（`'$epoch|$id'`）是放大器：标签一变，同 key 也解不开，逼出 probe/heal 兜底。

### 1.2 结构性根因

epoch 被当成**全局状态机**（两端必须收敛到同一数值），由此衍生「谁对谁错」判定 → 自动重写 → 方向错即翻转。但 epoch 本质只是**加密参数的版本标签**，不该驱动任何「纠正」行为。

### 1.3 epoch 引入的历史（为什么会堆成这样）

- **原始问题（07-28）**：多端改密码时 `encryptedDataKey` 互相覆盖（翻转战争），因 header 缺密钥纪元字段，无法区分「我密码错」还是「他端改了密码」。
- **第一层修复**：header 加 `keyFingerprint` + `keyVersion` + 引擎纪元守卫（远端 keyVersion 更高时不回滚远端包裹）。
- **第二层（07-29 Layer 3）**：拆出 `dataKeyEpoch`（dataKey 值真变才 +1）与 `ManifestItem.blobKeyEpoch`，下载侧检测旧纪元 blob 就**用当前纪元重传**（heal）。
- **失控点**：epoch 从「防翻转」工具变成「自动现代化」触发器，而 heal 用 `!=` 无方向守卫——在 epoch 分裂时（本方案正是要处理这种分裂）把翻转战争从 header 层搬到 blob 层。

**代码考古（吸收 aad-epoch-removal §1.3，证明本方案是回归原始设计）**：

| 时间 | 事件 | AAD 格式 |
|------|------|---------|
| 07-29 21:54 | v2：AAD 从 uuid 改为 content hash | `hash`（**无 epoch**） |
| 07-29 22:40 | Layer 3 引入 `blobKeyEpoch`，设计明确「blob 信封不写 epoch」 | `hash`（无 epoch） |
| 07-30 09:56 | 代码注释说明「不持久化 blobKeyEpoch 到 DB」 | `hash`（无 epoch） |
| ~08-01 | `_uploadNote` 开始传 `epoch: keyring.dataKeyEpoch` → epoch 进 AAD | `epoch\|hash` |
| 08-01 15:19 | 移除 v1/epoch=0 兼容路径，epoch-in-AAD 成唯一格式 | `epoch\|hash` |
| 08-01 18:36 | P6：`_probeBlobEpoch`（epoch 在 AAD → 声明与实际不符 → 需 probe） | `epoch\|hash` |
| 08-01 19:14 | P7：`adoptRemoteEpoch` 加 `markAllForBlobReupload`（epoch 变了必须重传） | `epoch\|hash` |

07-29 的原始设计就是 AAD=hash（无 epoch）。epoch 进 AAD 是后来引入的，且它引入的问题（P6 probe、P7 全量重传、翻转事故）比它解决的多。**本方案本质是回归原始 AAD 设计**，并在此基础上删掉 heal。

## 2. 关键概念澄清（避免混淆）

### 2.1 改密码 ≠ 迁移（epoch 语义）

| 动作 | keyVersion | dataKeyEpoch | dataKey 值 |
|---|---|---|---|
| 改密码 | +1 | **不变** | 不变（只重 wrap） |
| scenario-d 迁移 | 采用远端值 | +1（dataKey 真变时） | 变（采用远端 dataKey） |
| 新设备加入 | 采用远端值 | 跟随远端，**不 +1** | 变（采用同一 dataKey） |

改密码不重加密数据（dataKey 没变）；epoch 只在 dataKey 值真变时递增。改密码后 server 上同步的只有 header 包裹层，blob 零改动（日志实证：15:48:04 Windows 改密码后 `uploaded=0`）。

### 2.2 dataKey 是随机生成的

即使两端同密码初始化，dataKey 也不同（随机 32 字节）。dataKey 在**首次启用同步**时生成（`keyring.dart createNew` L425，`SyncCrypto.generateDataKey()`）；同步是**设置页手动开启**（初始化界面无同步设置），因此启用同步时本地可能已有笔记。

「新设备 join」分两种情况（修正 v3「必然迁移」的过强表述）：

- **空设备**（本地无笔记，`database_handler.readAllNotes().isEmpty`）：纯下载。本地 MK（同密码 + 同 salt → 同 MK）解开远端 encryptedDataKey → 得到**同一个 dataKey** → 解密远端 blob。零重加密、零重传。**不是迁移**。
- **离线先写设备**（启用同步前已创建笔记）：本地笔记用本机随机 dataKey 加密 → 加入时需 scenario-d 迁移（§5.3）。

结论：只有「离线先写」的设备才迁移；空设备 join 是纯下载路径。迁移检查（`checkMigrationNeeded`）应区分「本地是否已有 dataKey 加密的数据」。

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
6. **item/密钥自描述元数据（SN keyParams 借鉴，待落地 §7.1）** —— SN 的 itemsKey authenticated_data 自描述 keyParams，多端 key 不一致解密失败时能提示「用 X 日密码解锁」而非干巴巴报错。safenotes 对应对策：item 与 header 携带创建时间/创建者等明文元数据（`createdBy`、`dataKeyCreatedAt`、`dataKeyCreatedBy`），解密失败提示更精确（区分「哪段数据、由谁、何时加密」），仍**只读、不触发动作**。

### 3.3 明确不采纳项

| 机制 | 为何不采纳 |
|---|---|
| CRDT（AppFlowy/Notion） | 单用户单端写、整条笔记 blob 粒度，LWW（updatedAt）+ item 自描述已足够；CRDT 的字段级合并、tombstone、GC 对 32 字节级 blob 是纯负担 |
| 服务端权威（Notion/Outline） | 与 E2EE（服务端不可信）直接冲突 |
| 增量 / delta 同步（Joplin delta） | 数据量小（KB 级），全量 manifest 对比即可；delta 徒增服务端复杂度 |
| 文件级文本合并（Obsidian diff-match-patch） | blob 是整条密文，无法做文本级合并；合并不适用于单 blob |
| 多 key 并存 | 单用户单 vault 场景下，多 key 唯一价值是「旧密码数据渐进可读」；safenotes 采用一次性迁移 + 不兼容策略，无需多 key 复杂度 |

### 3.4 调研新增发现（补充 §8 审查）

**[G] 协议降级拒绝（新发现）**：业界对旧协议一致「拒绝而非兼容」。方案 §7.1 已定协议 v3→v4，但未明确下载侧行为。补充：`_downloadManifest` 校验 `header.schemaVersion`，`< kManifestSchemaVersion`（v4 常量）→ 抛 `_IncompatibleVersionException`（提示升级），**不解读、不迁移、不覆盖**。同时堵住「老客户端写覆盖新协议」的最后窗口（§0 的执行细节）。**实现前置**：schemaVersion 目前从不被真实写入（默认 1，§7.1「真值化」），须先落地版本常量与写入，否则本判定恒不触发。

**[H] `manifest-backup/` 代际备份定位（确认）**：调研确认版本历史是防覆盖类事故的标准兜底。safenotes 的 `manifest-backup/` 代际备份保留，其定位升级为「防覆盖事故的版本历史」——即使未来再有错误覆盖，可从代际备份恢复。

**核心差异小结**：safenotes 的 L3 heal「自动用当前纪元重传覆盖他人数据」违反第 1 条业界共识，是事故的制度性根源；本方案删自动改写、保留 item 自描述 + 只读解密，正与 Joplin/Standard Notes 对齐。

## 4. 根本方案：blob 纯数据 + item 自描述 + 只读解密

0. **blob 是纯数据**：`AES-GCM(dataKey, AAD=hash, plaintext)`，AAD **不含 epoch**（§4.2 论证）。解密只问「dataKey 对不对」——本地只有一把 dataKey，对就解开，解不开就是「非当前 key 或损坏」。epoch 不参与解密。
1. **`dataKeyFingerprint` 是 item 自描述属性**：标记「加密该 blob 的 dataKey 身份」（本地构建时恒为当前指纹，§4.1），解密端不推断、不比较、不纠正。
2. **解密端是纯函数**：用本地 dataKey 解密 → 能解就物化显示 → 解不开就报「缺 key / 密钥不符」。
3. **解不开时提示用户**（输旧密码 / 手动 `repairRemote()`），**不做任何自动重传**。

### 4.1 关键设计要点：无需 DB 持久化 key 身份（乐观声明的隐患源已消失）

旧设计 `_buildLocalManifest`（L1038-1058）**不持久化** blobKeyEpoch，乐观声明 `blobKeyEpoch = keyring.dataKeyEpoch`，靠 `markAllForBlobReupload` → `pendingReupload` → `_mergeAndTransfer` 强制重传的闭环让「声明」与「实际 blob」对齐。这套闭环正是要删的。

删掉闭环后**不需要补 DB 列**，理由：

1. 本地所有 blob 恒用当前 dataKey 加密——迁移（scenario-d/c）由 `reEncryptAllNotes` **单事务全量重加密**（§8.2[E]，crash 安全），改密码不换 dataKey（只重 wrap）。故本地不存在「实际是旧 key 的 blob」。
2. 因此 `_buildLocalManifest` 构建 item 时 `dataKeyFingerprint = 当前 dataKey 指纹`，恒等、与事实相符——不是乐观声明（乐观声明的坑是「声称与实际不符」，这里实际就是当前 key）。
3. 远端 item 的 `dataKeyFingerprint` 来自远端声明，用于 [D] 判定「旧 key vs 损坏」，不需要本地 DB 持久化。

**推论：schema v4 无需新增任何 DB 列**（`blob_key_epoch` / `data_key_fingerprint` 都不加），[A]（DB 默认值问题）随之作废（§8.2[A]）。若未来引入「多 dataKey 并存」，再恢复持久化。

**07-30 注释的 crash 顾虑在 blob 纯化后同时消解（吸收 aad-epoch-removal §1.4）**：`sync_engine.dart` L1051-1057 注释给出「不持久化 blobKeyEpoch 到 DB」的两条理由——老数据迁移默认值回滚 → `isOldKey` 判定失效 → 旧密钥 blob 无法 heal → 永久 corrupt；upload 成功但字段更新失败 → manifest 与 blob 实际纪元不一致 → 不可自愈的 corrupt。**这两条顾虑的前提都是「epoch 在 AAD 中」**（blob 可解密性依赖 epoch）。AAD 移除后：blob 用 dataKey + AAD=hash 加密，与 epoch 无关 → DB 列值不影响解密、「回滚为旧纪元」无害。§4.1「无需 DB 列」的结论由此得到独立佐证。

### 4.2 为什么 blob 必须是纯数据（epoch 无用且有害）

**历史**：Layer 3（git `db82c09`）把 epoch 拼进 blob AAD（`'$epoch|$id'`，`crypto.dart _blobAad` L190-195），`b382839` 收敛为唯一格式。动机注释两条：「让下载方显式判断 blob 是否被非当前 dataKey 加密」「避免把 dataKey 秘密泄露给半可信服务器」。

**两条动机都不成立**：
- 判断「是否非当前 dataKey」——解密本身就能判断：能解开=当前 key，解不开=非当前或损坏。不需要 epoch 标记。
- 「防泄露」——epoch 进 AAD 与泄露 dataKey 无关；真需要标记就用 `dataKeyFingerprint`（H(dataKey)，SHA-256 单向，不泄露）。

**epoch 是 dataKey 的冗余别名**：`dataKeyEpoch` 仅在 dataKey 真变时 +1，同 dataKey 恒同 epoch。epoch 进 AAD 信息量 = 0，唯一效果是把「密钥正确性」一个判定维度，人为拆成「dataKey 对 AND epoch 标签对」。

**密码学视角（吸收 aad-epoch-removal §3.2）**：epoch 在 AAD 中的唯一「作用」是区分不同 epoch 的 dataKey，但同一 dataKey 值的不同 epoch（如 adoptRemoteEpoch 场景）在密码学上是**等价**的——AES-256-GCM tag 只认 key + AAD，不认「epoch 标签」。把 epoch 放进 AAD，是用一个密码学等价的东西制造密码学不等价。移除后 blob 认证链三层均不依赖 epoch：**密钥认证**（GCM tag，dataKey 正确才通过）→ **AAD 认证**（AAD=hash 必须匹配）→ **内容认证**（解密后明文 SHA-256 == manifest hash）。

**后果（有害）**：AAD 绑 epoch 意味着解密端必须复现同一标签才能打开——「本地有正确 dataKey 却因标签不一致解不开」的虚假失败由此产生。这是历史事故的放大器：blob AAD 实为 epoch1、manifest 声称 epoch2 → 解密失败 → heal 用低纪元重传覆盖 → 翻转。`_probeBlobEpoch`（L1639-1642）循环试 epoch 1..N 正是为绕开「标签不对解不开」而生的 hack；blob 纯化后它连同存在理由一起消失。

**结论**：blob 是纯数据，epoch 不该参与。解密只问「dataKey 对不对」。

## 5. 数据流（改后各场景）

### 5.1 正常多端同步（无密钥变更）
```
A 写笔记 → blob(纯数据: dataKey + AAD=hash) + manifest item(dataKeyFingerprint=当前)
B 同步   → 下载 item → 本地 dataKey 直接解密 → 能解 → 物化
          （不比较、不推断、不重传；解密不看 item 声明）
```

### 5.2 改密码（keyVersion+1，dataKey 不变）
```
A 改密码 → 重 wrap dataKey，只更新 header；blob 与 item 全不动
B 同步   → 本地 dataKey 不变 → 能解所有 blob → 正常对账
```

### 5.3 scenario-d 迁移（dataKey 真变，epoch+1）

**仅离线先写设备触发**（空设备走 §5.3a 纯下载）：
```
B 离线先写 → 启用同步 → checkMigrationNeeded 检测 dataKey 不同 → migrateToRemoteVault（一次性）
           → reEncryptAllNotes：本地全部用新 dataKey 重加密（单事务原子，无旧 blob 残留）
           → 一次性重传本地 blob（新 dataKey 密文）+ manifest item 自描述新指纹
           → 之后两端 item 自描述同一指纹，纯内容级对账
```

### 5.3a 空设备 join（纯下载，非迁移）

`readAllNotes().isEmpty` 的空设备（§2.2）：
```
B 空设备  → 启用同步 → 下载 manifest → 本地 MK（同密码+同 salt）解远端 encryptedDataKey
           → 得同一 dataKey → 解密远端 items/blob → 物化
           （本地无数据，零重加密、零重传，不触发 migrateToRemoteVault）
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
| `_probeBlobEpoch`（循环试 epoch 1..N 探测实际纪元） | L1634-1670 | ~37 | **删除**（blob 纯化后无 probe 需要，§4.2） |
| `SyncCrypto.seal/open` epoch 参数 + `_blobAad`（AAD 绑 epoch） | crypto.dart L181-227 | ~45 | 删 epoch，`_blobAad` 恒用裸 id（§4.2） |
| `_downloadNote`（含 Layer3 heal「纪元不符→当前纪元重传」） | L1671-1913 | ~243 | 瘦身（删 heal） |
| `_handleDownloadFailure`（本机明文/孪生自愈重传） | L1914-2010 | ~97 | 瘦身（删 epoch 判定，**保留**本机明文/孪生自愈，见 §6.2 备注） |
| `adoptRemoteEpoch` 调用 + `epochMismatch` 状态机 + override 三元组 + 引擎内 `markAllForBlobReupload` 调用 | 全文件散落 | ~100（估） | **删除**（DB 方法保留） |
| **改前小计** | | **~1060 行** | |

### 6.2 改后：保留的 + 新增的

| 项 | 行数 | 说明 |
|---|---|---|
| `repairRemote` | ~250 | 保留不变 |
| `_buildLocalManifest` | ~50 | 删 override/乐观声明，item 声明恒为当前 dataKey 指纹（不读 DB，§4.1） |
| `_mergeAndTransfer` | ~180 | 删 pendingReupload 分支 |
| `_downloadNote` | ~160 | 删 heal 重传分支；解密失败直接报 `corrupt` |
| `_handleDownloadFailure` | ~70 | **保留本机明文自愈 + 孪生笔记自愈**（删 epoch 比较部分），仅失缺 key 判定的 epoch 依据改指纹（吸收 aad-epoch-removal §8.4 修订） |
| 新增：`_blobMissingKeyError`（解密失败提示） | ~15 | 明确报「缺 key」而非猜测 |
| ~~新增：DB schema v4 `blob_key_epoch` 列 + 迁移~~ | — | **作废**：blob 纯化后无需 DB 列（§4.1/[A]） |
| **改后小计** | | **~725 行** |

> **备注（v2 审查修正）**：`markAllForBlobReupload` / `pendingReupload` / `clear|removePendingReuploadUuids`
> 这套 **DB 基建保留**（迁移重传的可靠执行机制，见 §8.2[D2]），删除的是引擎内常驻分支
> （`_mergeAndTransfer` 的强制重传分支、`_buildLocalManifest` 乐观声明）与 `adoptRemoteEpoch`
> 的调用。故 §6.1 中「`markAllForBlobReupload` 删除」表述修正为「**引擎内调用删除，DB 方法保留**」，
> 删除行数相应下调（约 -50 而非 -100）。

### 6.3 结论

- **净减约 -335 行（约 -32%）**，删的是最危险、最难测的分支（自动重写、探测、双向翻转、AAD 绑 epoch），保留一次性显式迁移与用户主动修复。
- 删掉 3 个状态变量与常驻分支（`epochMismatch`/`overrideXxx`/`pendingReupload` 强制重传分支）及 blob AAD 的 epoch（§4.2），分支复杂度显著下降；`markAllForBlobReupload` 等 DB 方法保留作迁移重传基建（§8.2[D2]）。
- `keyring.dart` 侧：`adoptRemoteEpoch`、`markAllForBlobReupload` 删除（约 -50 行），`migrateToRemoteVault`（显式迁移）保留。
- **保留本机明文自愈 + 孪生笔记自愈**（约 40 行，吸收 aad-epoch-removal §8.4 v2 修订）：这两个机制不比较 epoch、不触发翻转，是「远端 blob 坏了 → 用本地同 uuid 明文 / 同 contentHash 孪生覆盖」的合理恢复路径（对应审查 P0 B5「半写脏 blob」的自动兜底）。**不为了行数指标而删**。v4 删的仅是 epoch 驱动的 heal/probe 与 isOldKey 的 epoch 比较部分。
- 满足判据：改后代码量下降，方案合格。

### 6.4 代价（接受项）

- 解密失败从「自动修复」变为「提示 + 手动 repair」——UX 略降。
- 迁移（scenario-d / scenario-c）仍是显式一次性动作，代码保留，不属本次删减范围。

## 7. 协议影响与架构权衡

### 7.1 协议字段

- **blob 信封 AAD 去 epoch（协议变更）**：`SyncCrypto.seal/open` 删 `epoch` 参数，`_blobAad` 恒用裸 id（`AAD=hash`）；旧 epoch-AAD blob 按 §0 不兼容，由迁移重加密覆盖（§4.2）。
- **`ManifestItem.blobKeyEpoch` 保留**（item 自描述），语义从「待现代化」变为「加密版本标签」；解密已不读它（blob 纯化），纯审计元数据。
- **`_semanticItemsEqual` 排除 `blobKeyEpoch`**（吸收 aad-epoch-removal §3.4）：当前实现（`sync_engine.dart:1331-1339`）把 `blobKeyEpoch` 纳入两端语义比较，导致两端声明不同 epoch 时每次同步判定「有变更」→ 无条件 PUT manifest（版本空涨 + ETag 竞争）。v4 从比较中排除 `blobKeyEpoch`，仅比对 hash / deleted / 时间戳 / contentSize——各端加密时用的 epoch 天然可能不同，那是「标签不同」，不是「内容有变更」。
- `ManifestHeader.dataKeyEpoch` 保留，仅作元数据，不再驱动同步行为。
- **新增自描述元数据（§3.2[6] 借鉴 SN keyParams）**：
  - `ManifestItem.dataKeyFingerprint`（加密该 blob 的 dataKey 的指纹，本地精确判定「缺 key vs 损坏」的依据，见 §8.2[D]）+ `ManifestItem.createdBy`（创建此笔记的设备 ID）+ `ManifestItem.dataKeyCreatedAt` / `dataKeyCreatedBy`（加密该 blob 的 dataKey 的创建时间/设备）。
  - `ManifestHeader.dataKeyFingerprint` / `dataKeyCreatedAt` / `dataKeyCreatedBy`（当前 dataKey 的指纹与创建信息）。
  - 均明文（items 在加密体内、header 明文），只读用于审计与解密失败提示，不驱动动作。
- **协议版本号须递增**（v3→v4）：`blobKeyEpoch` 语义已变（「待现代化」→「加密版本标签」）、`dataKeyEpoch` 不再驱动同步、新增上述元数据字段——旧客户端按不兼容策略 §0 不兼容。需同步更新 `docs/sync-protocol-spec.md`（§blobKeyEpoch 语义、新字段）与相关测试。
- **`schemaVersion` 真值化（v4 实现前置，搭车项）**：现状 `Manifest.empty` 写死 `1`（`sync_models.dart:472`）、`_buildLocalManifest` 用构造默认值 `1`、`repairRemote` 回显远端（`sync_engine.dart:850`），全库无版本常量——「v3→v4」仅是纸面版本。落地：新增 `kManifestSchemaVersion = 4` 常量，`Manifest.empty` / `_buildLocalManifest` 显式写入，`_downloadManifest` 降级拒绝（[G]）用该常量比较。否则 [G] 无实现基础、不可测。

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

**[A] DB 列默认值问题（作废：blob 纯化后无需 DB 列）**
原问题：存量数据没有 `blob_key_epoch` 列，schema 迁移时默认值取什么。
- **blob 纯化（§4.2）后本问题不存在**：item 的 key 身份恒为当前 dataKey 指纹（本地 blob 全部由迁移单事务重加密为当前 dataKey，§4.1），**schema v4 无需新增任何 DB 列**，无默认值问题。
- [A] 连同「DB 列 + 默认值」整套设计一起删除。

**[B] 老客户端升级期风险（不兼容策略下作废）**
（不兼容策略 §0 已取消「渐进兼容」：老版本不共存，无需兼容窗口，直接全量升级后生效。）

**[C] 删除 `_probeBlobEpoch` 后的只读兼容（不兼容策略下作废）**
（不兼容策略 §0 已取消旧格式 blob（epoch=0 / v1 uuid-AAD）的只读解码路径，直接删除。）

**[D] `_blobMissingKeyError` 与 corrupt 的判定边界（定案：item 加 dataKey 指纹字段）**
blob 纯化（§4.2）+ 删 probe 后，解密统一用本地 dataKey 直接 `open`（不传 epoch、不试多 epoch），失败即进入本判定。如何区分「缺 key（可修复，输旧密码）」与「真损坏（不可修）」？
- epoch 判定的缺陷：`item.blobKeyEpoch != keyring.dataKeyEpoch` 依赖两端纪元数值可比；且历史事故正是「item 声明 epoch2、blob 实为 epoch1」——item 声明本身可错，epoch 判定会误分类。纪元是需从 header/远端**学习**的序数，不是自包含的密钥身份。
- **定案：`ManifestItem` 新增 `dataKeyFingerprint` 字段**（加密该 blob 的 dataKey 的指纹，新增 `SyncCrypto.computeDataKeyFingerprint(dataKey)` = H(dataKey)；写入时与 `blobKeyEpoch` 同源，同取自 DB 持久化真实值 §4.1）。判定改为**本地精确匹配**：
  ```
  item.dataKeyFingerprint == 当前 dataKey 指纹
    ├─ 是 → 本应能解；解不开 = 真损坏 → 报 corrupt，提示 repairRemote（不可修）
    └─ 否 → 旧密钥数据 → 提示「该笔记由更早的密钥加密」（修复线索），不自动动作
  ```
- 这是 Joplin `master_key_id` 模式（§3.1）：item 自描述「用哪把 key 加密」，解密端按指纹选 key / 判定。指纹是数据派生身份，不依赖两端纪元历史一致，比 epoch 更强。**放 item 而非单独文件**：单独 key 索引文件会破坏单 manifest 原子性（§7.4），字段内嵌最简。
- **恢复路径边界（与 §0 / 多 key 不采纳一致）**：指纹只用于**区分与提示**，不承诺自动恢复。`KeyringLedger` 仅有 `current` 一条、**无归档数组**（旧 dataKey 不保留），故「输旧密码」本轮无法实际解开旧数据；提示引导走备份恢复。如需「输旧密码可恢复」再另立需求（归档旧条目，属 §3.3 不采纳项之外的可选增强），不在本轮范围。
- **提示精确化（§3.2[6] 新元数据）**：判定为「旧密钥」时，用 item/header 的 `dataKeyCreatedAt`/`dataKeyCreatedBy`（§7.1）给出精确提示（「该数据由 X 设备于某时间加密」），引导输旧密码或 repairRemote。**均只读提示，不触发任何自动重传**。

**[D2] `pendingReupload` 是持久化 meta，不是内存集合（v2 审查新发现）**
`blob_reupload_pending` 存于 DB meta（`database_handler.dart:89,834`），跨同步存活，且**失败重传保留标记**（`removePendingReuploadUuids` L869-879，P1 修复）。这对 §4.1「一次性重传取代常驻闭环」有直接影响：
- 若完全删除 `pendingReupload` 持久化，则「某次同步重传失败」后无标记可查，下次同步不会自动重试 → 旧密钥 blob 可能永久残留。
- **对策**：方案不要求删 `pendingReupload` 机制本身，而是删「乐观声明 + 常驻闭环」。迁移时「一次性重传」仍可利用该 meta 做失败重试——即：迁移触发时 `markAllForBlobReupload`（保留），成功清标记（保留），**删的只是 `_mergeAndTransfer` 里 `_itemsEqual && pendingReupload` 的强制重传分支与 `_buildLocalManifest` 的乐观声明**。重传行为在迁移流程内显式执行（对应 §4.1 第 4 点「一次性重传」），而非每次同步隐式兑现。
- 审查结论：**`markAllForBlobReupload`/`pendingReupload`/`clear/remove` 这套 DB 基建保留**（作为迁移重传的可靠执行机制），删的是引擎内常驻分支与乐观声明。账目修正见 §6.2 备注。

**[E] 迁移原子性（确认现有已满足）**
`reEncryptAllNotes` 单事务（crash 安全），`migrateToRemoteVault` 更新 keyring 后再 setDataKey。blob 纯化后**无 DB 列需同步更新**（§4.1），原子性要求简化为「全量重加密 + keyring 更新」同一事务。审查结论：实现时确认两者在同一事务内。

**[F] 并发迁移互斥（确认现有已满足）**
`sync()` 单飞（同一时刻一个同步），迁移后抛 `_MigrationRequiredException` 触发重试。删除 adopt 不影响此互斥。审查结论：无回归。

**[G] 协议降级拒绝（调研新增，见 §3.4）**
下载侧校验 `header.schemaVersion`，`< kManifestSchemaVersion`（v4 常量）直接拒绝并提示升级，不做兼容解读、不迁移、不覆盖。审查结论：补全不兼容策略 §0 的下载侧执行细节，与业界「拒绝旧协议防降级」一致，纳入实施；前提是先做 §7.1「schemaVersion 真值化」（版本常量 + 实际写入），否则判定恒不触发。

**[I] scenario-b 缺口（定案：失败 + 强制重登录；检测机制升级吸收 global-simplification §5 P3）**
v4 删 `epochMismatch` 状态机 + override 三元组 + `adoptRemoteEpoch` 后，**scenario-b（他端改密码，dataKey 未变）**不再自动兼容。
- **定案：选项 B（失败 + 强制重登录）**。彻底堵死 header 层翻转战争（B1/B1-2 当年修掉的问题）。
- **检测机制升级**：用 `header.dataKeyFingerprint`（§7.1）精确判定 dataKey 是否相同，替代旧「本地 MK 解不开 + items 能解」的间接信号。`_syncOnce` 判定从 4 分支收敛为 2 分支：
  ```
  header.dataKeyFingerprint == 本地 dataKey 指纹?
    ├─ YES（同一 dataKey）:
    │    remote.encryptedDataKey == 本地? → 正常同步
    │    不同 → 本地 MK 解不开远端包裹 → scenario-b：
    │          中止同步，报「他端改了密码，请重新输入密码」，不 PUT、不 echo
    └─ NO（dataKey 不同）:
         本地 MK 解远端包裹 → 成功 → 拿到远端 dataKey → 迁移（scenario-d）
         失败 → 用远端 KDF + 用户密码重派生 MK
               ├─ 能解 → 密码相同 salt 不同 → 完整迁移（scenario-c/d）
               └─ 不能解 → 密码不同 → 中止同步，提示重新输入密码
  ```
  连带删除 `keyVersion` 前置守卫 + `overrideEncryptedDataKey`/`overrideKeyFingerprint`/`overrideKeyVersion` 三元组 + `epochMismatch` 标志（与 v4 删除面重叠，P3 口径约 -110 行）。
- **不采纳 P3 的「同一 dataKey 不同 wrap → 采用远端 encryptedDataKey」分支**：那正是本定案排除的选项 A（echo 远端包裹）——保留「两端密码不同」的临时共存即保留翻转面，与 v4「只读解密、不自动改写」精神冲突。同一 dataKey 但 MK 解不开 = scenario-b，一律中止重登录。
- **连带项**：UI 的 `passwordEpochMismatch` 提示（`sync_engine.dart:176-188`）由本分支的 errorMessage 接管（删除依赖被删状态机的布尔标志）。

**[J] 错误处理统一（吸收 global-simplification §6.1 P4a，随 v4 顺手做）**
pointycastle 的 `InvalidTag`（GCM 认证失败）继承 `Error` 而非 `Exception`，`on Exception` 捕获不到 → 解密失败以 `Error` 穿出，落进 `on Object` 兜底丢类型，甚至卡死 `_state.status = syncing`（审查 P1 项）。
- **方案**：`crypto.dart` 新增 `DecryptionException implements Exception`（携带 context + cause），`SyncCrypto.open` 内部 `on Error` 包装为 `DecryptionException`；全库 `on Object` / `on SyncDecryptionException` → `on DecryptionException`；消灭静默 `catch {}`（至少 `Log.sync.w`）。成本低（约 ±50 行），是 v4 删除 heal 后「解密失败路径更常走」的必要配套——失败类型必须精确，否则 [D] 的「缺 key vs 损坏」分类无法落到异常语义上。

### 8.3 审查结论
方案逻辑自洽，核心方向（**blob 纯数据 + item 自描述 + 只读解密**）正确，与业界共识（§3.2）对齐，净减代码满足判据（约 -335 行）。关键简化：**blob AAD 去 epoch**（§4.2）消除了「有正确 dataKey 却因标签不一致解不开」的虚假失败与 `_probeBlobEpoch`，连带 [A] 作废（无需 DB 列）、解密降为「只问 dataKey」。[D] 以 `ManifestItem.dataKeyFingerprint` 本地精确判定（Joplin `master_key_id` 模式）闭合。[I] scenario-b 定案失败重登录，检测机制用 header 指纹精确判定（P3 口径，scenario 4 分支→2 分支，删 keyVersion 守卫 + override 三元组 + epochMismatch）。[J] 错误处理统一（DecryptionException）随 v4 实施。兼容类风险（[B]/[C]）按不兼容策略 §0 已直接排除；[G]（协议降级拒绝）已定案，纳入 §10。P0 可靠性五项（迁移原子性、`SyncService._keyring` 回写、HTTP 超时、`hardDelete` 事务化、LocalFS 原子写，B1-B5）随 v4 同期实施。
- **范围外（仅记关联，不吸进 v4）**：`sync-global-simplification-design` 的 P2（G-Set 删除架构）是独立的未来架构简化（删除建模为只增 uuid 集合，消除墓碑/GC/迁移分支），与 v4 正交，建议单独评审；P4b（sync_engine 拆 4 文件）/ P4c（journal 降级为审计-only）/ P4d（manifest 环形备份 5 份→1 份）属代码组织与数据安全取舍，列 backlog（审查文档 §三/§五）由用户决策。

## 9. 风险

- **不兼容策略风险（接受）**：旧版本客户端无法与新版本共存；旧数据（epoch=0 / v1 格式）一次性迁移，无回退。作为安全应用，全量升级是可控前提。
- **数据迁移风险（须做备份）**：blob AAD 去 epoch + 全量重加密是破坏性操作（旧 epoch-AAD blob 按 §0 不再兼容），实施前对生产 DB 做备份。
- 测试：删减的 heal/翻转分支对应测试改为「解密失败→corrupt+提示」断言。

## 10. 实施顺序建议

1. 生产 DB 备份（不兼容迁移为破坏性操作）。
2. **blob 纯化**：`SyncCrypto.seal/open` 删 `epoch` 参数、`_blobAad` 恒用裸 id；删 `_probeBlobEpoch`（连带唯一调用方）；存量 blob 由 `reEncryptAllNotes` 单事务重加密覆盖（§4.2）。
3. `SyncCrypto` 新增 `computeDataKeyFingerprint`；`ManifestItem`/`ManifestHeader` 加 `dataKeyFingerprint` 等自描述元数据字段（§7.1）；解密失败按指纹精确判定（[D]）；repair 判据一并改指纹；`_semanticItemsEqual` 排除 `blobKeyEpoch`（§7.1）。
4. **scenario-b 落地（[I]）**：`_syncOnce` 判定改用 `header.dataKeyFingerprint` 精确区分「同一 dataKey / dataKey 不同」（4 分支→2 分支，P3 口径），scenario-b → 中止 + 报「他端改了密码，请重新输入密码」；删 `keyVersion` 前置守卫 + override 三元组 + `epochMismatch` 标志；`passwordEpochMismatch` 提示由该 errorMessage 接管。
5. 删 heal/adopt/override 引擎常驻分支、`_downloadNote` 解密失败报 corrupt+提示（含删除 epoch=0 / v1 兼容解码路径）；**保留** `_handleDownloadFailure` 的本机明文自愈 + 孪生笔记自愈（仅删 epoch 比较部分，§6.3）；**迁移重传显式搬进** `_executeMigration`/`_executeMigrationVault`（A3）。
6. `_buildLocalManifest` 的 item 声明恒为当前 dataKey 指纹（无需 DB 列，§4.1）。
7. 协议版本 v3→v4：新增 `kManifestSchemaVersion = 4` 常量并写入 `Manifest.empty`/`_buildLocalManifest`（schemaVersion 真值化，§7.1）；`_downloadManifest` 增加 schemaVersion 降级拒绝（[G]）；更新 `docs/sync-protocol-spec.md`。
8. **P0 可靠性五项（随 v4 同期）**：
   - 迁移原子性：`reEncryptAllNotes` 与账本 `persist` 同一 SQLite 事务（或带恢复标记），消除「崩溃即全库不可解」窗口（B1）。
   - 迁移成功后把新 keyring 回写 `SyncService._keyring`（回调 / `updateKeyring`），消除「改密码回滚账本」致全库不可解（B2）。
   - 所有 HTTP 调用统一超时（15-30s），超时映射 `BackendUnavailableException`（B3）。
   - `hardDelete`/`hardDeleteByUuid` 的「删行 + 写 purgedUuid」同一 DB 事务，堵住「永久删除复活」（B4）。
   - LocalFS `putBlob` 改 tmp+fsync+rename 原子写，堵半写脏 blob（B5）。
   - 错误处理统一：`crypto.dart` 包装 `DecryptionException`（`open` 内 `on Error`），全库 `on Object` → `on DecryptionException`，消灭静默 `catch {}`（[J]/P4a）。
9. 全量测试 + `make valid`。
10. 更新 CHANGES。
11. 观察一轮真实多端同步确认无翻转回归。
