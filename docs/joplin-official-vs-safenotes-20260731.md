# Joplin 官方同步方案 vs SafeNotes 同步协议（基于官方源码）

> 调研对象：`C:\Home\Projects\joplin-secure\packages\`（Joplin 官方 monorepo fork，同步与 E2EE 代码经 blame 核对均来自上游官方提交，syncVersion 3，Server v3.7.1）
> 对比基准：SafeNotes 同步协议 v2（`docs/sync-protocol-spec.md`，`lib/sync/` 约 5900 行 Dart，167 测试含混沌测试）
> 本文档**取代**先前基于非官方库 `joplin-sync-lib` 的对比结论（`joplin-vs-safenotes-sync-20260731.md`），其中两条建议需修正，见 §六。

---

## 〇、三个颠覆先前结论的发现

1. **官方已全局关闭同步锁**。`LockHandler.ts:152` 的 `enabled_ = false`，每个方法开头 `if (this.enabled) throw new Error(...)` —— 整套 Sync/Exclusive 锁是死代码，上游 PR **#11377 "Remove the need for sync locks"** 移除。官方现今靠「冲突检测 + fail-safe + 幂等重放」保证一致性。**我们的无锁 ETag 方案与官方演进方向一致**，先前"借鉴 Exclusive 锁"的建议应撤回。
2. **删除 fail-safe 对我们价值远低于预期**。它防的是 Joplin 特有的「差集推断删除」——`basicDelta` 用本地 id 与远端 id 做差集来判断删除（`file-api.ts:629-638`），远端目录一旦掉线返回空列表就会误删全库。我们用**显式墓碑 + 并集合并**（`sync_engine.dart:884` `allUuids = {...local.keys, ...remote.keys}`），远端 manifest 变空只会导致本地条目被当作"仅本地有"重新上传，**架构上天然免疫**。
3. **官方自认的两个未修缺陷，我们恰好没有**：`sync_time` 毫秒粒度导致同毫秒二次修改丢失（`Synchronizer.ts:827-839` 注释建议改用 etag，正是我们的做法）；E2EE 下 `parent_id`/`updated_time` 等元数据仍明文上传。

---

## 一、同步算法对比

| 维度 | Joplin 官方 | SafeNotes |
|------|------------|-----------|
| 阶段 | DELETE_REMOTE → UPLOAD → DELTA（`Synchronizer.ts:592/616/893`） | 单趟：GET manifest → 三方合并 → 传输 → PUT manifest（ETag） |
| 变更判定 | `sync_items.sync_time < items.updated_time`（严格小于，`BaseItem.ts:800`） | manifest 内 `hash` 比对，与时间无关 |
| 增量 | `delta()` 游标；无原生 delta 的后端用 `basicDelta` 全量列举 + 时间戳排序 + `filesAtTimestamp` 补偿同毫秒边界 | 无增量：manifest 即全量状态快照 |
| 删除 | **差集推断**（危险，需 fail-safe 兜底） | **显式墓碑**（`deleted: true`） |
| 并发 | 已废弃锁；Server 端无 ETag，条目级 LWW，锁冲突 409 | ETag `If-Match`，412 重拉重试 |
| 冲突判定 | 下载远端**完整内容**反序列化后比 `updated_time > local.sync_time`——明确不信任文件系统时间戳（`Synchronizer.ts:685-698`） | manifest 内 hash + updatedAt，无需下载正文 |
| 断点 | 游标只在 `!hasCancelled` 时落盘（`:1145-1160`），重复处理幂等 | manifest 未 PUT 成功即整体回滚，blob 内容寻址幂等 |

**评价**：Joplin 的复杂度几乎全部来自「没有全局索引」这一个决策——为了避免每次列举全库，才需要 delta 游标；为了游标正确才需要时间戳排序和同毫秒补偿；为了推断删除才需要 fail-safe。我们用一个加密 manifest 换掉了这整条链路。代价是 manifest 随笔记数线性增长（当前 10KB 级，万条时约 MB 级）。

---

## 二、E2EE 对比（官方真实实现）

| 维度 | Joplin 官方 | SafeNotes |
|------|------------|-----------|
| 密钥材料 | `shim.randomBytes(256)` → hex（`EncryptionService.ts:298-317`） | 32 字节随机 dataKey |
| **KDF 分层** | **口令→MK：PBKDF2-SHA512 220000 轮；MK→数据：仅 3 轮**（输入已高熵，PBKDF2 只作 KDF） | 口令→MK：PBKDF2-SHA256 200000 轮；MK 直接 AES-GCM 包裹 dataKey，无二次派生 |
| 当前算法 | KeyV1/FileV1/StringV1 = **AES-256-GCM**，authTag 16B（早期 SJCL 系列 AES-CCM/OCB2 仅作兼容） | AES-256-GCM 全程 |
| nonce | 36 字节初始随机，**每 block 递增**（`crypto.increaseNonce`）；salt = `sha256(nonce)`；IV 独立随机 96bit | 每信封独立随机 12 字节 nonce |
| AAD | 目前为空 | **AAD 绑定内容 hash + dataKey 纪元**（Layer 3） |
| 明文元数据 | `id, parent_id, updated_time, share_id, type_, deleted_time…`（`BaseItem.ts:556-569`） | **无**：manifest 整体加密 |
| 改密码 | 只重包 MK，不重加密笔记（`e2ee/utils.ts:248-292`），先全部算完再落盘 | 同：只重包 dataKey，`keyVersion+1` |
| 多密钥 | 多 MK 并存，`activeMasterKeyId` 只决定新数据；密文头带 `masterKeyId`；非 active 惰性解密 | `keyVersion`/`dataKeyEpoch`/`blobKeyEpoch` 三级纪元 + dataKeyHistory 归档 + repair 通道 |

**我们更强的地方**：零知识（无明文元数据）、AAD 绑定（防密文替换攻击，官方 AAD 为空）。
**官方更强的地方**：`nonce 逐 block 递增` 的严谨性；**KDF 分层思想**（用高迭代保护口令、低迭代处理高熵密钥）；惰性解密避免启动时跑 N 次 220k PBKDF2。

---

## 三、Joplin Server vs 我们的 Go 服务

| | Joplin Server | SafeNotes Server |
|---|---|---|
| 规模 | 243 个 TS 文件、约 2.7 万行、25 张表、52 个迁移 | 约 400 行 Go，无数据库 |
| 依赖 | 41 个运行时依赖（pg、knex、koa、stripe、samlify、ldapts、S3 SDK、nodemailer、otplib…） | 标准库为主 |
| 配置 | 90+ 环境变量、16 个 cron 后台任务 | 少量 |
| 零知识 | **否**：`ItemModel.saveFromRawContent` 解析 `.md`，把 id/parent_id/type_/updated_time 提为数据库列，目录结构与笔记-资源关联全部可见 | **是**：只存密文文件 |
| 并发 | 无 ETag，条目级 LWW + 3 分钟 TTL 悲观锁 | ETag 乐观锁 |
| 超需求功能占比 | 多用户配额、Stripe 订阅、分享协作、发布、SAML/LDAP/2FA、管理后台 ≈ **60%+**；纯同步核心仅 3-4 千行 | 0 |

结论：Joplin Server 的壁垒在**协作与托管运营**，不在同步本身。个人加密同步场景用它，是为 15% 的功能承担 100% 的运维面。

---

## 四、官方值得借鉴的防御性设计（重新评估）

按对我们的**实际**价值排序：

### ⭐⭐⭐ 1. 远端时间戳上限截断（真实缺陷，建议修）

Joplin `BaseItem.ts:1068-1071` 的 `remoteItemSyncTime` 把远端时间**截断到本地 now**，抵抗时钟漂移。

我们 `sync_engine.dart:1158-1163` 的 LWW：
```dart
if (remote.updatedAt > local.updatedAt) return remote;
```
**纯比大小，无上限保护**。若某设备时钟严重超前（用户手动改时间、时区/NTP 故障），它写的笔记 `updatedAt` 会永久压制其他设备——其他端每次修改后同步，远端旧版本又赢回来，表现为"改了保存不了"。这是**可复现的真实故障模式**，且混沌测试覆盖不到（我们所有客户端共享同一系统时钟）。

建议：合并时对 `remote.updatedAt` 做 `min(remote.updatedAt, now + 容差)` 截断，容差取几分钟。

### ⭐⭐ 2. `mustHandleConflict` 语义化冲突过滤

Joplin `models/Note.ts:1036-1048`：只有 **title/body 实质不同**才算真冲突，`todo_completed` 等次要字段差异直接取远端，避免冲突副本泛滥。

我们目前 hash 一变就可能触发冲突副本（`kConflictPreserveThresholdMs` 5 分钟阈值已部分缓解）。若未来给笔记加"次要字段"（置顶、标签、排序），需要引入同样的语义分级，否则改个置顶状态就生成冲突副本。

### ⭐⭐ 3. 坏条目隔离持久化（`sync_disabled`）

Joplin 把反复失败的单个 item 标记 `sync_disabled=1`（`BaseItem.ts:916-919`）并记录原因，**从同步集合中永久排除**，不阻塞整体。我们有 `SyncActionType.skip/corrupt`，但**是每次同步的临时判定**——一个永久损坏的 blob 会在每次同步重试、重复报错。建议给 manifest item 或本地表加持久化的 `syncDisabled` + `failReason`，并在 UI 暴露"N 条笔记同步异常"。

### ⭐ 4. 同步目标存在性校验（我们的变体）

官方每轮 delta 后重新检查 `info.json` 是否还在（`syncInfoUtils.ts:144-166`），防"同步途中目录被换掉/网盘掉线"。

我们的对应场景在 `sync_engine.dart:871`：`remote == null` 时走「首次上传」路径，把本地全量推上去。方向上不丢数据（反而是恢复），但如果是**网盘临时故障返回 404**，会造成一次全量重传。建议：若本地存在有效的 base manifest（即"我们之前明明同步过"）却突然 `remote == null`，应中止并提示用户确认，而非静默全量重传。

### ⭐ 5. KDF 分层思想（可选优化）

我们 200k PBKDF2 只在解锁时跑一次，dataKey 直接用于 AES-GCM，没有性能问题。此项**无需改动**，仅作为设计参考记录。

### 不适用 / 已具备
- Exclusive 锁 —— 官方已废弃，我们不需要。
- 删除 fail-safe（90% 阈值）—— 我们显式墓碑 + 并集合并，架构免疫。
- `deleteChildren: false` —— 我们无层级结构，N/A。
- 冲突副本用新 id + 反向引用 —— 我们 `_preserveConflictCopy` 已具备等价机制。

---

## 五、我们的协议有没有漏洞？

对照官方十年沉淀，逐条检查：

| 官方防御 | 我们的状况 |
|---|---|
| 删除误判保护 | ✅ 架构免疫（显式墓碑） |
| 不信任远端时间戳 | ⚠️ **缺：LWW 无时钟上限截断**（§四.1） |
| 断点续传/游标幂等 | ✅ ETag 全或无 + 内容寻址幂等 |
| 坏条目隔离 | ⚠️ 有临时 skip，**缺持久化标记** |
| 冲突副本 | ✅ 已有（5 分钟阈值） |
| 冲突语义过滤 | ⚠️ 当前字段少不构成问题，扩展字段时需补 |
| 改密码低成本 | ✅ 与官方同策略，且我们纪元模型更细 |
| 密钥轮换/多密钥并存 | ✅ 三级纪元 + history + repair，强于官方 |
| 元数据隐私 | ✅ 强于官方（官方明文泄露结构） |
| 同步目标失效检测 | ⚠️ 404 静默走首次上传（§四.4） |

**结论：没有致命漏洞，三个中低危改进点**（时钟截断 > 坏项持久化隔离 > 404 保护）。

---

## 六、对先前报告的修正

`joplin-vs-safenotes-sync-20260731.md` 基于非官方库得出的两条建议需修正：

| 先前建议 | 修正后 |
|---|---|
| ⭐ 立刻加删除 fail-safe | **撤回**。那是 Joplin 差集删除模型的补丁，我们显式墓碑架构不需要 |
| ⭐ 借鉴 Exclusive 锁用于 dataKey 轮换 | **撤回**。官方已于 #11377 全局废弃锁；我们 ETag + 纪元协调已是更优解 |
| 直接用 Joplin 不可行（语言/E2EE/耦合） | **维持**。官方 E2EE 虽是真实现（AES-256-GCM），但仍是 TypeScript，且 Server 非零知识 |

**新的头号建议**：修 LWW 的时钟漂移保护（§四.1）——这是本轮调研发现的唯一真实故障模式。
