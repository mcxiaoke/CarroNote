# Safe Notes Flutter 全面审查报告（cds4f）

> 审查日期：2026-08-08（GMT+8）
> 审查范围：Flutter App 侧（`lib/`，约 9,200 行）+ 纯 Dart 核心包（`packages/core/lib`，约 7,700 行）+ 测试代码（`packages/core/test`、`test/`）
> 审查维度（按用户要求）：**同步（sync）｜分支（branches）｜数据（data）｜边缘情况处理（edge cases）｜性能（performance）**
> 方法：全量源码精读（含工作区未提交的 v5 可靠性改动 diff）+ 静态分析 + 全量测试验证 + 与 `docs/code-review-comprehensive-20260808.md`、`docs/code-review-comprehensive-20260805.md` 交叉比对

---

## 一、结论速览

| 维度 | 评分 | 一句话结论 |
|------|------|-----------|
| 同步 | 8.8/10 | 五步对账 + 乐观锁 + 自愈 + Journal 第二数据源架构扎实，但**损坏恢复路径与三个生产后端存在一处交互缺陷**（恢复 PUT 必然触发乐观锁冲突，re-GET 成功时还会把好 manifest 移走） |
| 分支 | 9.0/10 | 三方合并 + fast-forward 三分流 + 场景 a/b/c/d 密钥分支正确，个别防御性缺口（同 MK 不同 dataKey 未比较） |
| 数据 | 9.0/10 | 字段级加密、原子迁移、purged 防复活、两阶段 GC、白名单 markSynced 均正确；输入校验与异常兜底有小缺口 |
| 边缘情况 | 8.2/10 | 覆盖极广（断网重连、同步期写入、坏纪元、串库、journal 损坏），但存在「Error 漏网」「配置热更新失效」「远程 journal 上传水位虚进」等具体问题 |
| 性能 | 7.5/10 | 缓存与硬件加速已解决主要卡顿；但同步循环仍有多处 N+1 读库、每轮 3~4 次远端全量扫描、journal 全量重写等可优化点 |

**本次新增问题统计**（与 08-08 报告不重复的部分）：

| 严重度 | 数量 | 摘要 |
|--------|------|------|
| P1（高） | 2 | ①损坏恢复路径 `backupCorruptManifest` + `putManifest(原 etag)` 在三后端必然冲突，re-GET 成功路径被 LocalFS 把好文件移走；②同步设置页改配置/关同步不生效（`switchBackend` 从未被调用） |
| P2（中） | 5 | ①Journal 远端上传不校验 HTTP 状态，水位虚进导致副本缺失永不重传；②v5 新异常/恢复编排无直接单测；③分支 1 未比较 remoteDataKey；④冲突副本条目缺 v5 自描述字段；⑤远程 manifest 无大小上限 |
| P3（低） | 6 | 配置枚举越界、`fromJson` TypeError 漏网、SafeServer 列表 hash 未校验、`on Exception` 兜底缺口、时钟偏差 LWW、UI 搜索/摘要细节 |

**验证结果**：`flutter analyze lib test` 与 `dart analyze packages/core` 均 0 告警；核心单测 121 个全通过；多设备/混沌/长期存续 27 个全通过（含 3 个 seed 共 125s 混沌）；App 侧 `flutter test` 9 个全通过。

---

## 二、同步（Sync）

### 2.1 架构与既有设计（确认无误）

- 五步同步流程（GET header → 构建本地 manifest → 逐条比对 → PUT 乐观锁 → 更新本地状态）与 `simplified-sync-design.md` 一致。
- **v5 容器**（未提交改动）：magic/fileVer/schemaV 固定头 + 明文 header + AES-GCM items + 无密钥 pubHash。异常分流契约（`ManifestAuthException` → §7 恢复编排；`ManifestKeyMismatchException` → scenario-b 强制重登）方向正确，`_syncOnce` 与 `repairRemote` 均按契约分流。
- **两阶段孤儿 GC**（候选观察 → 连续两次仍孤儿才隔离 → 30 天保留后 purge）能覆盖「他端刚 putBlob 尚未 putManifest」的并发窗口；`listBlobs` 为空时跳过 GC 保守不删。
- **P1-A 白名单 markSynced** 正确解决同步期写入竞态（只标记当前状态 == merged 的 uuid）。
- **B1 原子迁移**（重加密 + keyring 账本 + 重传标记同一事务）正确，无「重加密成功但账本未更新」崩溃窗口。
- `_withBlobRetry` 只对 `BackendUnavailableException` 做 200ms/400ms 退避，不吞逻辑错误，语义正确。

### 2.2 🔴 P1：损坏恢复路径与三个生产后端的交互缺陷（`sync_engine.dart` `_recoverFromCorruptRemoteManifest`）

**现象**（代码级推演，测试未覆盖，故现有测试全绿）：

1. `_recoverFromCorruptRemoteManifest` 在 re-GET 之后、PUT 之前**无条件**调用 `backend.backupCorruptManifest(remoteResponse.ciphertext)`（`sync_engine.dart:353`）。
2. 三个生产后端该方法的语义都是「把 manifest 从端点移除」：
   - LocalFS：`manifest.json` rename 为 `.corrupt-<ts>`（`local_fs_backend.dart:186-196`）；
   - WebDAV：DELETE manifest（`webdav_backend.dart:575-594`）；
   - SafeServer：move 到 `.corrupt-<ts>`（`safe_server_backend.dart:253-275`）。
3. 随后 `putManifest(newCiphertext, putEtag)` 携带的是**移除前**的 etag：
   - LocalFS：`file.exists()` 为 false → 直接抛 `ConflictException`（`local_fs_backend.dart:80-83`）；
   - WebDAV/SafeServer：If-Match 打到已不存在的资源 → 412 → `ConflictException`。
4. `sync()` 捕获 `ConflictException` 后重试：第二次 `getManifest` 返回空 → 走「远端为空」首次同步路径 → **只用本地数据重建 manifest（version 归 1）**。

**更严重的叠加**：当 re-GET 成功（远端其实是好的，仅瞬时损坏）时，`backupCorruptManifest` 的入参虽传的是原始损坏密文，但 LocalFS 实现不读入参、直接对当前 `manifest.json` 做 rename——**把 re-GET 拿到的好 manifest 移走了**。随后 PUT 同样冲突 → 重试 → 远端为空 → 本地重建。re-GET 保护机制被完全击穿。

**数据影响**：重建后的 manifest 只含本端笔记。若远端 manifest 中还有「本端从未持有/尚未同步」的条目（例如刚加入尚未同步的新设备），这些条目会被丢弃；其 blob 在后续 GC 中成为孤儿 → 30 天后被 purge，若唯一持有明文的新设备始终未同步成功，即演变为**永久丢失**。

**根因**：恢复流程按「备份 = 移除」的后端语义编写，却仍用原 etag 做乐观锁；且 re-GET 成功后不应再执行 backupCorruptManifest。

**修复建议**（任选其一，推荐组合）：
1. re-GET 成功时跳过 `backupCorruptManifest`，直接用 `recoveredResponse.etag` PUT；
2. 确实需要备份时，备份后 PUT 改用**空 etag（If-None-Match: \*）**，与「远端已无 manifest」的事实一致；
3. 或把三个后端的 `backupCorruptManifest` 语义改为「复制保留 + 不移除端点」（LocalFS 用 copy 而非 rename，WebDAV 用 COPY，SafeServer 用资源层 copy），PUT 仍用原 etag。
4. 补测试：用「会真实移除文件的 fake backend」覆盖 `sync_engine` 损坏恢复路径，断言一次同步内成功、re-GET 成功时远端完好数据被保留。

### 2.3 🟠 P2：Journal 远端副本上传不校验 HTTP 状态，水位虚进（`journal.dart` + 两后端）

- `Journal.syncToRemote` 逐个上传归档后即 `_uploadedSeq = seq`（`journal.dart:777-789`）；
- 但 `WebDavBackend.putJournalObject`（`webdav_backend.dart:495-515`）与 `SafeServerBackend.putJournalObject`（`safe_server_backend.dart:442-455`）**不检查响应状态码**，401/500 也算成功；
- 后果：归档上传失败却推进水位 → 失败对象**永不重传**，远端 journal 出现空洞，削弱「manifest 单点故障第二数据源」的承诺（LocalFS 正常，写失败会抛异常）。

**建议**：两个后端对非 2xx 抛异常（或返回 bool），`syncToRemote` 仅在成功后推进水位。

### 2.4 🟠 P2：v5 新代码无直接单测

`ManifestAuthException` / `ManifestKeyMismatchException` / pubHash 校验 / `_recoverFromCorruptRemoteManifest` 在 `packages/core/test` 中**均无直接引用**（现有混沌「远端 manifest 损坏」用例用的是 no-op `backupCorruptManifest` 的 fake backend，正好躲过了 §2.2 的缺陷）。建议新增：
- 容器 round-trip、pubHash 位翻转、截断、magic 错误、headerLen 越界 → 断言异常类型正确分流；
- pubHash 通过 + items 密文篡改 → `ManifestKeyMismatchException`；
- 损坏恢复：re-GET 成功 / 失败两条路径，断言最终 manifest 内容与 etag 语义。

### 2.5 其它同步级发现

- **无 manifest 大小上限**（P3）：WebDAV/SafeServer 直接 `res.bodyBytes` 全量入内存，恶意/异常服务端可打爆内存；建议 GET 时校验 Content-Length 或设上限（如 20MB）。
- **迁移重试共用循环**（已有 08-08 报告 P1-4，确认属实）：`sync()` 中 `_MigrationRequiredException` 与乐观锁冲突共用 `for attempt`，若迁移发生在第 3 次尝试会直接失败；建议迁移独立计数。
- **bak 循环未实现**（已有 08-08 报告 P1-3，确认属实）：`sync_engine.dart:345-349` TODO，持久性损坏目前只能本地重建；§2.2 缺陷修复前，bak 读取是唯一能避免数据丢失的兜底，应优先实现。

---

## 三、分支（Branches）

### 3.1 密钥场景分支（确认正确）

| 分支 | 判定依据 | 行为 | 结论 |
|------|---------|------|------|
| 正常同步 | dataKey 指纹相同 + 包裹相同 | 正常对账 | ✅ |
| 同 MK 重新 wrap | 指纹相同、包裹不同、本地 MK 能解开 | 只读解密，不 echo（§0） | ✅ |
| 本端改密码未推送 | MK 解不开远端包裹 + 远端 keyVersion 更低 | 正常同步并用本地新包裹推送 | ✅ |
| 他端改密码（scenario-b） | MK 解不开 + 远端 keyVersion ≥ 本地 | 中止 + `requiresRelogin` 强制重登，零写入 | ✅（含 UI 强制弹窗） |
| scenario-c（密码不同） | 远端指纹判别不匹配 | 失败 + 强制重登 | ✅ |
| scenario-d（同密码不同 salt） | 远端指纹匹配 + 远端 dataKey 可解 | 整库迁移到远端 vault | ✅ |

### 3.2 🟠 P2：分支 1「MK 能解开远端包裹」未比较解出的 dataKey（`sync_engine.dart:490-500`）

`remoteDk != null` 时直接认为「两端同 MK = 同 dataKey」并 `deserialize(_dataKey, ...)`。若未来出现「同 MK 重新 wrap 了一把不同 dataKey」的合法路径（当前设计不会发生，但分支 2 有 `_bytesEqual` 防御而这里没有），会抛未捕获的 `ManifestKeyMismatchException` 一路逃到 `SyncService` 变成通用「同步异常」。建议与分支 2 对称：解出 `remoteDk` 后先与 `_dataKey` 比较，不同则走迁移路径。

### 3.3 合并分支（确认正确）

- 三方合并 base = `(syncedHash, syncedDeleted)`；`base==null` 保守退化为真冲突并保留副本，不丢数据。
- fast-forward 三分流（localChanged/remoteChanged）正确，单边删除/编辑不再误报 conflict。
- `shouldPreserveCopy` 四条判据（双方偏离 base、双方活跃、内容不同）正确切断「删除复活 / 副本链式增殖」；冲突副本标题带设备前缀 + 序号探测，防 hash 碰撞链。
- 一个小不一致（P3）：`_preserveConflictCopy` 写入 merged 的 `ManifestItem` 未带 v5 自描述字段（`dataKeyFingerprint`/`createdBy`/`dataKeyCreatedAt`/`dataKeyCreatedBy`），而 heal 路径（§6.3 修订 3）已补全。冲突副本将来若解密失败，无法按 §5.3 归因「旧 key vs 真损坏」。建议与 heal 路径一致补全。
- **时钟偏差**（P3，设计说明）：LWW 用各设备墙钟 `updatedAt`，时钟快/慢的设备可长期占据胜者；文档未提供时钟同步或容差机制。可接受但建议在协议文档中注明风险，或未来引入单调版本向量。

---

## 四、数据（Data）

### 4.1 确认正确的数据设计

- **本地字段级加密**：AAD=uuid 绑定，`_encryptField`/`_decryptField` 路径统一；解密失败抛异常而非静默返回明文。
- **缓存一致性**：全部写路径收口到 4 个私有方法（`_upsertCacheEntry` / `_removeCacheEntry` / `_applySyncedToCache` / `_invalidateCache`），缓存是 DB 的强一致镜像；`readAllNotesIncludingDeleted` 返回副本避免遍历时并发修改。
- **purged 防复活**：`hardDelete*` 删行 + 写 purged 同一事务（B4）；墓碑 GC（F1）同样走 purged，测试覆盖「超 30 天墓碑不再复活」。
- **payload v2**：`toContentBytes` 加 `"v"` 字段，与内容身份 hash 解耦，未来加字段不破坏 blob 寻址；`computeHash` 非单射问题已在注释中明示并接受。

### 4.2 🟠 P2/P3：输入校验缺口

| 位置 | 问题 | 严重度 |
|------|------|--------|
| `ManifestHeader.fromJson`（`sync_models.dart:470-490`） | `vaultId as String` / `updatedAt as int` 等必填字段缺失时抛 **TypeError（Error 子类）**，不是 `FormatException`/`ManifestAuthException`；`_syncOnce` 的 catch 子句只覆盖后者 → 漏网逃到 Zone 兜底，同步无干净结果。pubHash 保证「写者必是客户端」，但未来 v6 写者改了必填字段就会触发 | P3（低概率，建议把解析包一层 try→转 `ManifestAuthException`） |
| `ManifestCrypto.deserialize` | items JSON 反序列化（`jsonDecode`/`fromJson`）异常未包装，只有 GCM 失败被转成 `ManifestKeyMismatchException` | P3（同上，建议统一包装） |
| `SyncConfig.backendType`（`sync_config.dart:96-99`） | `SyncBackendType.values[index]` 在 SharedPreferences 索引损坏/越界时抛 RangeError，应用启动即崩；建议 try + clamp 兜底 | P3 |
| `NotesDatabase.getManifestVersion` | `int.parse(value)` 对损坏 meta 无保护 | P3 |
| SafeServer `listBlobs`（`safe_server_backend.dart:320-330`） | 仅 `whereType<String>()`，不校验 64 位 hex；恶意/异常服务端可返回任意名字并被 `deleteBlob`/`deleteBlobSoft` 使用（另两个后端都有正则过滤）。建议统一 64-hex 校验 | P3 |

### 4.3 其它数据注意点

- `_decryptField` 把所有解密失败包装成 `DataKeyNotSetException`，消息可含原始异常；对用户展示略误导，但不会泄露明文（P4，可不改）。
- `getPendingReuploadUuids` 的 `jsonDecode(raw) as List<dynamic>` 若 meta 损坏抛 TypeError（仅 `on Exception` 捕获）→ 同步崩溃；建议 `on Object`（P3）。

---

## 五、边缘情况处理（Edge Cases）

### 5.1 已覆盖得好的边缘（确认）

- 断网 → 后端初始化失败 → `_backendReady` 惰性重试，联网自动恢复（Bug A 修复）；
- 远端为空 / 远端被清空 → 首次同步路径 + 跳过 GC（P0-1 防误删他端 blob）；
- 同步期间用户编辑 → 白名单不误标 synced，base 不被污染；
- 坏纪元污染 keyring.current → journal `replayKeyState` 可取真；
- journal 本地损坏 / 整体被删 / 串库 → 隔离取证、空日志继续、不阻断同步；
- manifest 半写/位翻转 → v5 pubHash 一次性区分损坏与密钥不匹配；
- 单条 blob 坏 → Layer 1 容错 + 本地明文/孪生自愈，单条失败不炸整次同步。

### 5.2 🟠 P2（新增）：同步设置页改配置/关闭同步不生效

- `switchBackend` 定义于 `sync_service.dart:634`，全项目**无任何调用点**；
- `sync_settings.dart` 的 `_selectBackendType`、`_editWebdavUrl`/`_editWebdavPassword` 等只写 `SyncConfig`，不重建 engine/backend；
- 后果：① 用户改 WebDAV 密码/URL 后，内存中的旧 backend（旧凭据）继续用于 autoSync，配置形同虚设，直到重登/重启；② 用户选择「不同步（none）」后，`SyncService._engine` 仍非空，autoSync 继续向旧后端同步，**关闭同步功能不生效**；
- **建议**：在配置变更点调用 `switchBackend`（后端类型/URL/凭据任一变化），或在 `autoSync`/`sync` 前检查 `SyncConfig.isSyncEnabled` 并置空 engine；并补一条 UI 级测试。

### 5.3 🟡 P3：`on Exception` 兜底缺口

多个关键 catch 使用 `on Exception` 而 Dart 里 `Error` 子类（RangeError/TypeError/StateError）会漏网，最终落到 `runZonedGuarded` 打 FATAL 日志、UI 无感知：

- `SyncService.sync/repairRemote` 的 `on Exception`（`sync_service.dart:460-486/560-578`）；
- `refreshNotes` 的 `on Exception`（`home.dart:185`）；
- `_gcOrphanBlobs` 内三层 `on Exception`（`sync_engine.dart:2455-2555` 附近）；
- `login._tryVerifyPassphraseViaRemote` 的 `on Exception`（把 TypeError 漏给 Zone）。

对「单条坏数据」路径建议统一 `on Object` + 日志，对「编程错误」路径至少保证 UI 能拿到干净失败结果而非静默崩溃。

### 5.4 🟡 P3：其余边缘

- `SafeNote.abstractText` 用 `substring(0, 200)` 截断，可能切断 UTF-16 代理对（emoji）产生残缺字符；建议按 code point 截断。
- 首页 `_searchNote` 每次按键全量扫描 + 两次 `toLowerCase` 分配，无 debounce；大库下键盘卡顿。
- `onAppUpdate` 中 `PreferencesStorage.setAppVersionCodeToCurrent()` 未 await（fire-and-forget，P4）。
- `main._shutdown` 不关闭 SyncService/Journal；Windows 桌面退出瞬间最后 100ms 内的 journal 缓冲可能未落盘（P4）。
- 登录页把「远端 manifest 损坏」判为 `unreachable`（不扣尝试次数）——行为安全，但诊断信息不准确（P4，可提示用户去修复）。

---

## 六、性能（Performance）

### 6.1 已解决

- `cryptography_flutter` 硬件加速（AES-GCM/PBKDF2），Android/iOS/macOS 快约 50 倍；
- `_notesCache` 全量明文缓存，列表刷新/同步免重复解密；缓存维护收口单一；
- 冲突副本标题探测、同步统计等次要热点已做聚合/降噪。

### 6.2 仍可优化（按收益排序）

1. **同步循环 N+1 读库**：`_mergeAndTransfer` 对每个 uuid 调 `readNoteByUuid`（冲突路径两次）；加上 `_buildLocalManifest` 与 `_updateLocalState` 各自全量读，一次同步对 DB 的查询约为 3×N + N。建议构建一次 `Map<uuid, SafeNote>` 快照复用。
2. **每轮同步 3~4 次远端全量扫描**：`_gcOrphanBlobs` 每轮 `listBlobs()`（PROPFIND/GET blobs）+ `listOrphanBlobs()` + `purgeOrphans()`；WebDAV 每轮至少 3 个深度 1 的 PROPFIND。建议 GC 降频（如每日一次或每 10 次同步一次），并合并 listOrphan 与 purge 为单次 propfind。
3. **Journal 全量重写**：`_writeLogFile` 每次 flush 重写整个 log.json（上限 100KB × 最多 10 次/秒）；建议追加式写入或增大滚动阈值。
4. **manifest 全量重加密**：每次 PUT 对全部 items JSON 做 AES-GCM 加密（O(N)，不可完全避免）；若 N 很大可考虑分片，但当前规模可接受，仅记录。
5. **blob 顺序传输**：单设备同步时 blob 上传/下载逐条串行；可加有界并发（如 4~8）并用 `Future.wait`，网络往返可显著缩短（注意保持单条失败隔离语义）。
6. **UI**：搜索加 debounce + 预小写化索引；`readDeletedNotes` 每次全量解密可加缓存；`readAllNotes` 已在 DB 层排序，home 再排一次属重复。

---

## 七、测试与验证结果

| 项目 | 命令 | 结果 |
|------|------|------|
| App 静态分析 | `flutter analyze lib test` | ✅ 0 issues |
| 核心包静态分析 | `dart analyze packages/core` | ✅ 0 issues |
| 核心单元测试 | `dart test ...sync_engine/journal/keyring/local_fs/p0p1` | ✅ 121 通过 |
| 多设备/混沌/长期存续 | `dart test ...multi_device/chaos/longrun` | ✅ 27 通过（混沌 3 seed × 125s，longrun 复用 212 代真实数据） |
| App 侧测试 | `flutter test` | ✅ 9 通过（change_password 多端 / 真实库生成 / Bug A 恢复） |

**覆盖缺口**（见 §2.4）：v5 容器异常矩阵、`_recoverFromCorruptRemoteManifest` 双路径、`switchBackend` 热更新、Journal 上传失败水位回退，均无测试。

---

## 八、问题清单汇总

| 编号 | 严重度 | 位置 | 问题 | 建议 |
|------|--------|------|------|------|
| C1 | **P1** | `sync_engine.dart:353-374` + 三后端 `backupCorruptManifest` | 损坏恢复备份「移除文件」后仍用原 etag PUT → 必然 ConflictException；re-GET 成功时 LocalFS 把好 manifest 移走；重试退化为本地重建，可能丢「仅远端有」条目 | re-GET 成功跳过备份；或备份后 PUT 用空 etag；或备份改复制不移除；补真实文件后端测试 |
| C2 | **P1** | `sync_settings.dart` 配置变更点 / `sync_service.dart:634` | `switchBackend` 无调用点：改配置/关同步不生效，autoSync 继续用旧后端 | 配置变更后调用 switchBackend；`isSyncEnabled==false` 时停 engine |
| C3 | P2 | `journal.dart:777-789` + webdav/safe_server `putJournalObject` | 远端上传不校验 HTTP 状态，水位虚进 → 失败归档永不重传 | 非 2xx 抛异常，仅成功后推进水位 |
| C4 | P2 | `packages/core/test` | v5 容器/恢复编排/热更新无直接测试 | 新增异常矩阵与恢复双路径单测 |
| C5 | P2 | `sync_engine.dart:490-500` | 分支 1 未比较 `remoteDk` 与 `_dataKey` | 与分支 2 对称补 `_bytesEqual` 防御 |
| C6 | P2 | `sync_engine.dart:1676-1690`（`_preserveConflictCopy`） | 冲突副本 ManifestItem 缺 v5 自描述字段 | 与 heal 路径一致补全 |
| C7 | P3 | `sync_models.dart` 解析 | 远端 manifest 无大小上限；`fromJson` TypeError 漏网 | 加大小上限 + 解析包装为 ManifestAuthException |
| C8 | P3 | `sync_config.dart:96-99` / `database_handler.dart` | 配置索引越界 RangeError；manifest version int.parse 无保护 | try + 默认值 |
| C9 | P3 | `safe_server_backend.dart:320-330` | listBlobs hash 未 64-hex 校验 | 统一校验后再进入删除路径 |
| C10 | P3 | 多个 `on Exception` catch | Error 子类漏网到 Zone 兜底 | 单条数据路径改 `on Object` |
| C11 | P3 | `_gcOrphanBlobs` / `_mergeAndTransfer` / `_buildLocalManifest` | 每轮 3~4 次远端扫描 + N+1 读库 | GC 降频、快照复用、并发上传 |
| C12 | P3 | `safenote.dart` / `home.dart` | abstractText 代理对截断、搜索无 debounce | code point 截断、搜索防抖 |
| C13 | P3 | 全引擎 | LWW 依赖设备墙钟，无时钟容差 | 文档注明 / 未来版本向量 |

（另：08-08 报告已列出的 P1-1 `_handleDownloadFailure` 自愈缺 hash 校验、P1-2 `initialize` 非幂等、P1-3 bak 循环、P1-4 迁移重试共用循环、P2-1 dispose/logout 与在途同步竞态等，本次复核均确认属实，不再重复展开。）

---

## 九、修复优先级建议

1. **立即**：C1（损坏恢复路径）——它是 v5 可靠性改动的核心入口，当前实现反而制造数据丢失风险；建议同时补 C4 的恢复路径测试。
2. **立即**：C2（配置热更新/关闭同步不生效）——用户可感知的行为缺陷。
3. **本轮**：C3（journal 水位）、C5（分支防御）、C6（冲突副本字段）。
4. **下轮**：C7~C13（健壮性与性能）。

---

## 十、总体评价

代码在同步对账、密钥场景、并发冲突、崩溃安全四个方向上都达到了很高的工程水准，测试体系（混沌/多设备/长期存续）在同量级项目中罕见地完整。本轮最值得警惕的不是「缺能力」，而是**两个「看似已实现、实则交互失效」的闭环**：损坏恢复路径（C1）与配置热更新（C2）。修掉这两项后，同步子系统可以认为是生产就绪的。
