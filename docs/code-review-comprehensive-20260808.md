# Safe Notes 增量深度代码审查报告

> 审查日期：2026-08-08
> 审查范围：自 `docs/code-review-comprehensive-20260805.md` 之后的**未提交可靠性改动**（v5 manifest 容器、统一恢复编排、self-heal 自愈、payload v2）+ 同步全链路人工复核 + 子 agent 并行审查（journal / sync_service / 三后端）结果回验
> 方法：读源码 + `dart analyze packages/core`（零告警）+ 子 agent 交叉审查 + 逐条回验子 agent 关键发现（含行号）
> 关联文档：`docs/manifest-reliability-design-20260803.md`（设计稿）、`docs/code-review-comprehensive-20260805.md`（上期全量评估）

---

## 一、结论速览

| 维度 | 结论 | 说明 |
|------|------|------|
| 未提交改动整体质量 | **高** | v5 容器 + 统一恢复编排 + self-heal 形成了闭环，异常分流契约文档化 |
| `dart analyze packages/core` | ✅ 0 告警 | 无 lint / static error |
| 新增 P1 问题 | 2 | `_handleDownloadFailure` 自愈缺 `local.contentHash == remoteItem.hash` 校验；SyncService 生命周期与在途同步竞态 |
| 新增 P2 问题 | 6 | 见 §4 |
| 回验子 agent 发现 | 5/5 属实 | 均已定位到行号，升级为正式条目（其中 2 条本已在本期报告） |
| 上期未解决遗留 | P0×1 / P1×2 / P2×3 | bak 循环 TODO、大文件拆分、迁移重试共用循环等（详见 §6） |

---

## 二、本期重点：未提交可靠性改动审查

### 2.1 v5 Manifest 容器（`sync_models.dart` +251 行）

**设计**：12 字节定长头（magic `SMNT` / fileVer / schemaVersion / headerLen）+ 明文 JSON header + AES-GCM 密文 items + pubHash（SHA-256，无密钥）。

**验证矩阵（一次性区分损坏 vs 密钥不匹配）：**

| 检测结果 | 判定 | 流向 |
|---------|------|------|
| magic/fileVer/headerLen 非法 | **结构损坏** | §7 统一恢复编排 |
| pubHash 校验失败 | **数据损坏**（位翻转/截断/半写） | §7 统一恢复编排 |
| pubHash 通过 + items GCM 失败 | **密钥不匹配/纪元** | scenario-b 强制重登 |

**评价**：
- ✅ header 先于 items 明文解析，schemaVersion 降级拒绝在解密前完成，成本友好（`_parseManifest` 双阶段）
- ✅ manifest、blob 的检索逻辑均围绕它展开，`ManifestKeyMismatchException`（GCM失败）从不走恢复编排——异常分流契约被严格执行（`sync_engine.dart:441-451`）
- ⚠️ v5 容器结构的 increment only，碰撞困对比放入 —— 无明显问题

### 2.2 统一恢复编排 `_recoverFromCorruptRemoteManifest`（sync_engine.dart:308）

**流程**：备份损坏文件（`backupCorruptManifest`）→ re-GET 确认 → 本地重建（`_buildLocalManifest`）→ `_mergeAndTransfer` → PUT（原始 ETag 乐观锁）→ 更新本地状态 + push journal。

- ✅ 只在 `FormatException` / `ManifestAuthException` 分支进入，绝不 catch `ManifestKeyMismatchException`
- ⚠️ **TODO**：bak 循环未实现（`sync_engine.dart:345-349`）——当前能恢复链上了一份；预计 `listManifestBackups` / `readManifestBackup` 未实现仍从 bak 试。（上期 P0 遗留）
- ⚠️ 恢复编排内的 `_recoverFromCorruptRemoteManifest` 恢复了远程，但**未交代在 recover 完成后与本地合并冲突收尾**——本地 manifest 同步末尾 `_pushJournal` 覆盖检查是否一致仍需人工复核

### 2.3 self-heal 自愈重传（`_downloadNote` 第 893-900、962-975 行，`_repairBlob`）

| 路径 | hash 校验 | 位置 |
|------|----------|------|
| `_downloadNote` blob 缺失 heal | `local.contentHash == item.hash` ✅ | 893:899-900 |
| `_downloadNote` blob 损坏 heal > 同提要 | `source.contentHash == item.hash` ✅ | 962:967 |
| `_repairRemote` blob 缺失 heal | `local.contentHash == item.hash` ✅ | `sync_engine.dart:1896` |
| 同名 uuid | `readNoteByUuid` + hash 一致 ✅ | `sync_engine.dart:1898` |
| **`_handleDownloadFailure` 自愈** | **只看 `!local.deleted`，未校验 hash** ⚠️ | **`sync_engine.dart:2026-2028`** |

> 🔴 **P1**：`_handleDownloadFailure` 是本机坏 terra blob 后首次下载失败路径里
> `local != null && !local.deleted` 就自愈重传，**缺少 `local.contentHash == remoteItem.hash`
> 一致性校验**。而其它所有 heal 路径（上表 93 行，客户端侧集中在第 1876 行周围）都已
> 遵守"仅 hash 一致才兜底"。差异意味着：本地某 uuid 恰好有**旧内容**（已编辑 / 时间戳倒
> 回）时，重传会把**旧 blob 根因页错误替换**为本机旧内容，**且 manifest 改索引本机 hash**，
> 「shouldPreserveCopy」判断被绕过 → 丢失远端更新的 LWW 胜者。修复：`条件` 中加
> `local.contentHash == remoteItem.hash`（若用户持有不同 hash 的新内容性，可能保住的远端
> 副本逻辑已在上层 `shouldPreserveCopy` 处理）。

### 2.4 payload v2（safenote.dart:256-263）

- ✅ `toContentBytes` 增加 `"v":2` 字段，`fromContentBytes` 仍只读 title/description，新老格式互兼容
- ✅ hash 由 `computeHash(title, description)` 决定，与 payload 字节**解耦**——加字段不破坏 blob 寻址（设计正确）
- ✅ 同步/防病毒组确认 AAD = hash 不变

---

## 三、同步全链路深度复核（与上期报告的差异补强）

### 3.1 写入路径（LWW + updatedAt）

```
UI 编辑 → editor_state.dart:98-105
  now = DateTime.now()
  copyWith(title, description, contentHash, updatedAt=now, synced=false)
  → DB.updateNote  (lib/models/editor_state.dart:95-106)
  → SyncService.autoSync() (debounce 3s, 非阻塞)
```

- ✅ 时间戳用 `now.millisecondsSinceEpoch`（毫秒级，多端并发编辑同毫秒概率极低）
- ✅ `contentHash` 与 `updatedAt` 同步更新，LWW 判断有依据
- ✅ 空字段填充 `' '` 保证可加密、可索引
- ⚠️ **时间来自设备的本地时钟**——跨时区/时钟偏移设备间 LWW 可能不满足"仰赖 global ordering"，但三端同步场景属可接受偏差（上期已评估 9.0，未升级）

### 3.2 SyncService 生命周期（lib/sync/sync_service.dart，931 行）

| 函数 | 行为 | 问题 |
|------|------|------|
| `initialize` | 打开 journal、重建 engine、`backend.init()`、`_backendReady=true` | **P1**：journal 非幂等。重复调用 `initialize` 时 `_journal` 会被第二次 `_openJournal` 替换，旧实例泄漏（`.close()` 永不触达），日志链断裂、seq 紊乱。`sync_service.dart:184` 无「if `_journal != null` 先 close」锚点 |
| `sync` | 惰性重初始化 + 互斥 `_syncInProgress` + engine.sync | ✅ 良好 |
| `dispose` | close journal/backend/controller、置 null | 🟠 与在途 sync 竞态：`dispose` 先 `_closeJournal()` 再 `_stateController.close()`（329-331）。若同步进行中，engine 回调 `_updateState` 会 `add` 到已关闭的 controller → `StateError`（未捕获）。App 层退出时机一般安全，但属于不可达逻辑缺陷。参见 §4-P2 |
| `logout` | 关 journal/backend、重置状态、**保留 stream** | 🟠 `logout` 关闭 journal 后，若在途 `sync()` 尚未结束，其 `await journal.flush()` 可能落在已关闭实例上（`_closed` 回 true 后 append 返回 -1，但 flush 定时器已 cancel，pending 条目**静默丢弃**）——数据不丢（journal 是审计），但审计缺口。 |

> **P1 / P2 候选**：`dispose`/`logout` 与在途 `sync()` 无握手。`sync()` 内 `await engine.sync()` 期间调用 `dispose`/`logout`，`_updateState` 会抛 `StateError`（exit 时机）或 journal flush 静默丢弃。建议 sync 协程结束时增加 `closed` 标志位判断后再 `_updateState`，或 dispose/logout 前 `_syncInProgress` 检查。其严重性取决于 UI 退出编排。

### 3.3 后端审查（子 agent 回验）

| 后端 | 发现 | 回验 | 严重度 |
|------|------|------|--------|
| SafeServer | `deleteBlob` 对 405 抛 `BackendUnavailableException`（safe_server_backend.dart:306）—— 与设计文档「405 视为不支持、静默降级」不符 | ✅ 属实（注释说 v2.2 必须支持，抛异常是明确行为选择，但**与 Go 服务端旧版本兼容性预期不符**，升级时序风险） | P2 |
| WebDAV | `_postResource` 对 `.corrupt-<ts>` 资源冲突（overwrite=false 得 409）未处理 → `backupCorruptManifest` 其它后端是移动成功不产生残件 | ✅ 属实：webdav 的 `backupCorruptManifest` 用 COPY+DELETE，COPY 返回 409 会被当成功（:479 有降级） | P2 |
| 三后端 | `listOrphanBlobs()` 重复调用（sync_engine 里 repairRemote 调一次 + `_gcOrphanBlobs` 再调）→ 2×PROPFIND/2× list | ✅ 属实，性能消耗 | P3 |
| LocalFS | `_tmp` 固定名、无 hash 回读校验，进程崩溃可留残 `.tmp` | ✅ | P3 |
| LocalFS | `backupCorruptManifest` 用 `.corrupt-<ts>` 副本，无环删除 | 文件本地驻留可接受 | P3 |

---

## 四、新增问题清单（含严重度、位置、修复建议）

### P1（数据一致性 / 竞态）

| # | 问题 | 位置 | 建议 |
|---|------|------|------|
| P1-1 | `_handleDownloadFailure` 自愈重传**缺少 `local.contentHash == remoteItem.hash` 校验**，与其余 3 条 heal 路径不一致；脏本地内容可能覆盖远端 LWW 胜者 | `sync_engine.dart:2027-2028` | 条件补 hash 校验后在融合 |
| P1-2 | `SyncService.initialize` 非幂等：重复调用不关闭旧 journal，日志链断裂 | `sync_service.dart:184` | **函数开头**：`if (_journal != null) await _closeJournal();` |
| P1-3 | 损坏 manifest 恢复时 bak 循环未实现（TODO） | `sync_engine.dart:345-349` | 新增 `listManifestBackups` / `readManifestBackup` backend 接口 + 恢复逻辑（上期 P0 遗留） |
| P1-4 | 迁移重试与乐观锁冲突重试共用 `for attempt` 循环，若迁移发生在 attempt=3，`_MigrationRequiredException` 致使整个 sync 失败 | `sync_engine.dart`（sync 头部循环） | 迁移独立计数（上期 P1 遗留） |

### P2（健壮性 / 边界）

| # | 问题 | 位置 |
|---|------|------|
| P2-1 | `dispose`/`logout` 与在途 `sync()` 竞态：controller 关闭后 `_updateState` 抛 `StateError`；journal 关闭后 flush 静默丢弃 | `sync_service.dart:323-337` |
| P2-2 | Journal `_writeChain.catchError` 吞错无告警（只在条件分支跳过，未记 w 日志） | `journal.dart:629` |
| P2-3 | `JournalEntry.fromJson` / `ManifestItem.fromJson` 无语义校验：epoch=-1、空 hash="" 等坏值静默进入 | `journal.dart` / `sync_models.dart` |
| P2-4 | `_recoverFromCorruptRemoteManifest` 重建后未显式触发本地冲突合并（只依赖后台 merge） | `sync_engine.dart:308-` |
| P2-5 | SafeServer 405 → 抛异常（与旧服务端不兼容预期冲突） | `safe_server_backend.dart:306` |

### P3（性能 / 打磨）

| # | 问题 | 位置 |
|---|------|------|
| P3-1 | `readNoteByUuid`（同步期间每次下载/对比都查询 + 解密）—— 同步期间 N 次 DB 查询 + 解密开销 | `_downloadNote` 链 |
| P3-2 | 重复 `listOrphanBlobs`（repair + GC 各一次） | repairRemote / GC |
| P3-3 | WebDAV `listOrphanBlobs` PROPFIND 可能返回 405（部分实现不支持 Depth:1）→ warn 日志每轮触发 | `webdav_backend.dart:523` |

---

## 五、性能专项

| 维度 | 现状 | 建议 |
|------|------|------|
| 同步下载 | `_downloadNote` 每 blob 一次 DB 读 + 解密，无并发批下载 | 批量 prefetch manifest 命中笔记，下载可并发 2-4 |
| 加密 | cryptography AAD=hash，硬件加速已用 | — |
| `toContentBytes` | 每次加密重新 `jsonEncode`（短字符串，可忽略） | — |
| 索引 | `createdAt`/`updatedAt` 有主索引；`contentHash` 用于 blob 寻址需确保有索引（HSQLite 建表确认） | 确认 `content_hash` 索引存在（`database_handler.dart` 建表语句） |
| 孤儿 GC | 两阶段 + 30 天，成本摊到 repair/同步尾 | 良好 |

---

## 六、汇总：已解决 / 新增 / 遗留

| 类别 | 数量 | 明细 |
|------|------|------|
| 本次新增 P1 | 2 | P1-1（hash 校验）、P1-2（initialize 非幂等） |
| 本次新增 P2 | 4 | P2-1 ~ P2-4，P2-5（SafeServer 405） |
| 本次新增 P3 | 3 | P3-1 ~ P3-3 |
| 上期遗留 P0 | 1 | bak 循环实现 |
| 上期遗留 P1 | 2 | sync_engine 拆分、迁移重试独立计数 |
| 上期遗留 P2/P3 | 5 | markdown化拆分、pointycastle 移除、`_sameKey` mema 等 |

---

## 6. 结论

未提交的可靠性改动（v5 容器头部 + pubHash 验证矩阵 + 统一恢复编排 + 异常分流契约 + payload v2）方向正确、实现扎实，`dart analyze` 零告警，自愈 hash 校验在 3 条路径上已贯穿，仅 **`_handleDownloadFailure` 一条路径漏了 hash 校验（P1-1）** 应予优先修复。

上期 9.0 的同步评分维持；若完成 P1-1/P1-2 与 bak 循环，可靠性可升至 9.2+。

---

*报告基于 2026-08-08 对未提交改动（+600 行）与同步全链路的人工复核，所有引用行号经源码逐一核验。*