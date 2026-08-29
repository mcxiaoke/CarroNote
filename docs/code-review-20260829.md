# SafeNotes 全量代码评审报告

- 评审日期：2026-08-29 (GMT+8)
- 代码规模：`packages/core` 15,456 行（61 个 .dart）+ `lib/` 约 18,600 行（123 个 .dart）
- 测试规模：73 个测试文件 + 3 个集成测试文件
- 技术栈：Flutter 3.44.8 / Dart 3.12.2 / shadcn_ui 0.56.1 / provider 6.0.3
- 评审范围：加密层、数据持久化层、同步引擎、同步后端、App 状态与 UI/UX、工程化配置

---

## 一、总体结论

**这是一个工程质量明显高于平均水平的项目。** 加密原语选型正确（AES-256-GCM + Argon2id/PBKDF2，per-vault 随机 salt，内容寻址 blob，AAD 域分隔），文件头注释详尽到记录了每次事故的根因与取舍，不可信输入（远端 KDF 参数）做了上下界校验，`purgedUuids` 损坏时不静默返回空集等防御性设计都到位。

但**在"异常路径的收尾"上存在系统性缺口**：正常路径写得非常扎实，一旦进入并发、中途失败、部分成功的分支，就出现若干条**静默丢数据**的通路。7 个 P0 里有 5 个属于这一类——不是算法错，而是"某条分支忘了做某件事"。

严重级别分布：

| 级别 | 数量 | 性质 |
|---|---|---|
| **P0** | 7 | 可导致用户数据永久丢失或静默丢失，必须修复 |
| **P1** | 22 | 安全暴露面、崩溃、同步正确性、显著 UX 缺陷 |
| **P2** | 16 | 性能、健壮性、可维护性、无障碍 |

**建议修复顺序**：先修 P0-1 / P0-2 / P0-3（三条都会真实产生"用户数据消失且无提示"），再做 P1 中的安全项（keyring 泄露、路径穿越、凭据入日志），最后处理 UX 与工程化。

---

## 二、P0 — 会导致数据丢失，必须修复

### P0-1 墓碑 GC 未登记 purgedUuids：删除的笔记 30 天后从远端复活

- **位置**：`packages/core/lib/src/sync/sync_engine.dart:1690-1693`（配合 `:1674-1676` 的注释）
- **现象**：`_buildLocalManifest` 对软删除超 30 天的墓碑只做了 `hardDeleteByUuid` 后 `continue`：

  ```dart
  if (note.deleted && (now - note.updatedAt) > kTombstoneGcThresholdMs) {
    await database.hardDeleteByUuid(note.uuid);   // 只删本地
    continue;                                     // ← 没有 addPurgedUuids
  }
  ```

  但紧邻的注释（1674-1676）明确写着"硬删除本地记录**并加入 purgedUuids**，让 `_mergeAndTransfer` 的 M1 逻辑阻止其从远端复活"。整个 `_buildLocalManifest` 里不存在 `purgedUuids` 集合，也没有任何 `addPurgedUuids` 调用。**注释描述的实现与代码不符，写漏了。**
- **风险**：**删除意图静默丢失 + 隐私事故。** 本设备离线超过 30 天、或删除操作从未成功推送到远端时，本地墓碑被硬删掉了，远端仍是活条目；下一轮同步走 `:1813-1825` 的"仅远端有"分支，不在 purgedSet 中 → 照常 `_downloadNote` → **用户删除的笔记原样复活**。反向也成立：已同步的删除，其墓碑永远无法从远端 manifest 移除（`_mergeAndTransfer` 每轮把远端墓碑重新并入 merged 并 PUT），墓碑无限累积，已删笔记的 hash / 时间戳 / 正文大小永久留在服务端——**F1 墓碑 GC 功能整体失效**。
- **建议**：把过期 uuid 交给与用户硬删相同的通道：

  ```dart
  if (note.deleted && (now - note.updatedAt) > kTombstoneGcThresholdMs) {
    await database.addPurgedUuids(note.uuid);   // ← 补这一行
    await database.hardDeleteByUuid(note.uuid);
    continue;
  }
  ```
  `_updateLocalState:2863-2871` 已在 PUT 成功后清理 purgedUuids，无需新增清理逻辑。补一个回归测试：本地删除 → 推进 30 天 → 同步 → 断言笔记不复活且远端墓碑已移除。

---

### P0-2 读路径物理 DELETE 解密失败的行：单行损坏即静默删笔记，无备份无确认

- **位置**：`packages/core/lib/src/db/database_handler.dart:564-565`（阈值）、`572-596`（`_deleteBrokenRows`）、`643-660`（`_decryptRowWithGuard`）
- **现象**：**只读操作**里执行破坏性写：

  ```dart
  static bool _isMassDecryptionFailure(int broken, int total) =>
      broken >= 10 || (broken >= 3 && broken * 10 >= total) || broken == total;
  ```
  `_decryptRowsWithGuard`（603-636）在列表读取中把解不开的行 `txn.delete(...)` 物理删掉；`_decryptRowWithGuard`（643-660）**完全不判阈值**，单行读取解不开就删。
- **风险**：**用户静默永久丢笔记。** 判定阈值对小样本放行：一个 500 条的库里坏了 3 条 → `3 < 10`、`3 ≠ 500`、`3*10=30 < 500` → 判定为"隔离损坏" → 直接删行。注释（553-556）声称的自愈链是"云端仍持有 blob，下次同步拉回"，但**这条链对两类用户根本不存在**：(a) 未开启同步的纯本地用户；(b) 该笔记从未成功同步过。而且删除发生在**应用启动的缓存重建**里，用户没有任何干预机会，UI 侧只会看到 `readNote` 抛 `'ID $id not found'`。
  更要命的是 P0-3 的竞态会持续产出这种"错 key 的孤立行"，本条把它变成真实的数据销毁。
- **建议**：读路径绝不做破坏性写。改为隔离 + 保留密文：

  ```dart
  // 1) ALTER TABLE safe_notes ADD COLUMN broken INTEGER NOT NULL DEFAULT 0
  // 2) 所有业务查询加 'AND broken = 0'
  await txn.update(tableNotes, {NoteFields.broken: 1},
      where: '${NoteFields.uuid} = ?', whereArgs: [uuid]);
  ```
  隔离行保留原始密文信封，用户换回正确密码 / 从备份恢复后可一键还原。同时把 `broken >= 10` 收紧为 `broken >= 3`，并让 `_decryptRowWithGuard` 走同一阈值判定而非无条件删。若暂不做隔离列，**最低限度**是删除前把原始信封 base64 落盘到 `temp/recovered-<uuid>.bin` 并弹一次用户可见提示。

---

### P0-3 迁移守卫是 TOCTOU 空转：迁移窗口内写入的笔记用旧 key 加密，随后被 P0-2 删掉

- **位置**：守卫 `database_handler.dart:467-470`（定义）、调用点 `:953 / 985 / 1077 / 1095 / 1117 / 1138 / 1154 / 1169 / 1263 / 1322 / 1360 / 1401 / 1429 / 1457`；迁移窗口 `:1997` / `:2001` / `:2007-2020`；**未加守卫的写路径**：`:2539 upsertNoteMeta`、`:1543 softDelete`、`:1588 hardDelete`、`:1790 restoreNote`、`:2130/2147/2165/2235 markSynced*`
- **现象**：`reEncryptAllNotesAtomically` 在 2001 行把 `_dataKey` 换成 `oldKey`，然后在 2007/2012/2017 三次 `await` 里读取并解密**整库**（notes + note_meta + note_versions），到 2020 行才换成 `newKey`——这段窗口是**秒级**的。而写路径的守卫形同虚设：

  ```dart
  Future<SafeNote> storeNote(SafeNote note) async {
    _checkNotMigrating();                     // 953：此刻检查
    final db = await instance.database;       // 954：await 让出
    final id = await db.insert(tableNotes,
        await _toEncryptedRow(note));         // 956：此刻才读 _dataKey
  ```
  守卫在 `await` **之前**、`_dataKey` 的读取在 `await` **之后**，检查与真正加密之间隔了 2 个 await 点，迁移随时可以插入。此外 `upsertNoteMeta`（2539）等 8 处写路径**一行守卫都没有**。
- **风险**：**用户刚写的笔记凭空消失，且无任何提示。** 完整链路：
  1. 迁移在 2007 行完成 `SELECT`；
  2. 用户此时新建/编辑笔记，`storeNote` 用 `oldKey` 加密并 INSERT；
  3. 迁移事务按 uuid 逐行 UPDATE——这条新行不在 `encryptedRows` 里，躲过重加密；
  4. `:2107` 把 `_dataKey` 换成 `newKey`；
  5. 下次全量读解不开这一行 → 落到 P0-2 → **直接 DELETE**。

  同理 `upsertNoteMeta` 在窗口内写 payload 会用 `oldKey`，导致该笔记标签永久不可解。
- **建议**：把"抛异常式"守卫换成"闸门式"互斥。引入可重入异步串行锁（可用 `package:synchronized` 的 `Lock(reentrant: true)`），迁移整段包进锁内，`storeNote` / `updateNote` / `upsertNoteMeta` / `saveVersion` / `restoreVersion` / `softDelete` / `hardDelete` 全部包进锁内，然后删掉 `_checkNotMigrating` 的前置检查。**过渡期的最小修复**：至少给 `upsertNoteMeta` 补上守卫。

---

### P0-4 dataKey 迁移静默跳过解密失败的行，却报告成功

- **位置**：`packages/core/lib/src/db/database_handler.dart:2814-2834`（`_readMetaPayloadsPlain`）、`2844-2868`（`_readAllVersionsPlain`）；调用点 `:2012` / `:2017`
- **现象**：两个方法都用 `on Object catch` 吞掉解密异常，只打一条 W 日志然后 `continue`：

  ```dart
  try { out[uuid] = await _decryptField(_metaAad(uuid), encrypted); }
  on Object catch (e) {
    Log.db.w('note_meta payload 解密失败，迁移时跳过该行: uuid=$uuid ($e)');
  }
  ```
  被跳过的行**不会**进入 `encryptedMeta` / `encryptedVersions`，迁移事务（2081-2101）根本不碰它们——它们的列值仍是 `oldKey` 密文。事务照常提交，`:2110` 照常打印"原子化迁移完成"。
- **风险**：**用户永久丢失这部分数据，且系统告诉他成功了。** 迁移后 `_dataKey = newKey`，这些 payload / 历史版本再也解不开。后续读取 payload 时会走 `_decodeMetaRow`（2524）再次降级为空，再被下一次 `upsertNoteMeta` 覆盖成 NULL（见 P1-4），连原始密文都没了。历史版本同理，`readVersions`（1413）会为每条失败行抛异常，导致整个版本列表打不开。
  注释说"避免用新 key 覆盖出二次损坏"——这个取舍可以接受，但**缺少"失败即中止"的兜底**：迁移是 all-or-nothing 场景，任一行解不开就意味着 `oldKey` 可能不对，继续下去只会产出半迁移状态。
- **建议**：跳过即失败。让两个方法把跳过的 id/uuid 收集起来返回，迁移在开事务前判定：

  ```dart
  final (payloads, skippedMeta)     = await _readMetaPayloadsPlain(db);
  final (versions, skippedVersions) = await _readAllVersionsPlain(db);
  if (skippedMeta.isNotEmpty || skippedVersions.isNotEmpty) {
    throw StateError('迁移中止：${skippedMeta.length} 条元数据 / '
        '${skippedVersions.length} 条历史版本无法用 oldKey 解密，oldKey 可能不正确');
  }
  ```
  由 `:2116` 的 catch 恢复 `_dataKey = originalDataKey` 并 rethrow，上层提示用户从备份恢复。

---

### P0-5 远端 manifest 损坏 → 本地重建会丢弃"仅远端有"的条目，并 GC 掉他端 blob

- **位置**：`packages/core/lib/src/sync/sync_engine.dart:684-688` → `:1769-1788` → `:694-698` → `:1172`（`_gcOrphanBlobs`）
- **现象**：`_recoverFromCorruptRemoteManifest` 在 re-GET 与全部 bak 均不可用时，用 `recoveredManifest = null` 走合并；`_mergeAndTransfer` 的 `remote == null` 分支直接以 `local.items` 为 merged，随后 `:694-698` 用空 etag 覆盖 PUT。远端 manifest 中"本设备没有、其他设备独有"的条目（含本设备因 `corrupt`/`uploadFailed` 从未成功下载、但被 D3 修复刻意保留在 merged 里的条目）全部消失。紧接的 `_gcOrphanBlobs` 把这些 blob 视为孤儿，经两阶段候选后 `deleteBlobSoft` 隔离。
- **风险**：**不可逆数据丢失**——不是"本次同步失败"，而是把其他设备的数据从索引里删除，并在 2 轮同步后物理隔离其 blob。讽刺的是这条路径正是为"防单点故障"设计的，结果执行了最激进的清理动作。
- **建议**：本地重建分支必须保留未知条目。最小改法：`remote == null` 且处于"损坏重建"上下文时**不要 PUT 纯本地快照**——返回 `SyncResult.failure` 并提示用户从 bak / 其他设备恢复；或让 `_recoverFromCorruptRemoteManifest` 传入一个"保留集"（从 `manifest-backup/` 或上一次本地缓存的远端 items 中提取 uuid+hash），在 merged 中原样保留并跳过本轮 GC（沿用已有的 `skipGc` 语义）。

---

### P0-6 LWW 完全依赖对端本地时钟，删除场景下连冲突副本都不留

- **位置**：`packages/core/lib/src/sync/sync_engine.dart:2272-2277`（`_resolveConflict`）、`:2438-2444`（墓碑应用）、`:2573`（下载写入）、`:1701/1722`（本地侧用 `DateTime.now()`）
- **现象**：冲突裁决唯一判据是 `updatedAt` 数值大小，而该字段来自**写入方设备的本地时钟**且完全由远端 manifest 携带；本地侧取本机时钟。没有服务器时间戳、逻辑计数器或版本向量参与。墓碑分支更直接：`:2441` 把本地行的 `updatedAt` 无条件改写为远端墓碑时间。
- **风险**：**丢数据。** 具体链路：设备 B 时钟快 20 分钟（手动改过时间、NTP 未同步的安卓/iOS 设备很常见），B 在 T 删除/修改笔记并上传（`updatedAt = T+20min`）；设备 A 在 T+5min 编辑同一笔记；A 同步时 `remote.updatedAt > local.updatedAt` → 远端胜 → **A 的新编辑被覆盖/删除**，而 `shouldPreserveCopy`（`:1968-1973`）要求"两端都非删除"才保留副本，删除场景下**连副本都不留**。反向（A 时钟快）表现为 A 的旧内容覆盖 B 的新内容。
- **建议**（三条，按性价比排序）：
  1. **硬规则**：本地存在未推送的编辑（`synced == 0` 且内容偏离 base）时，永不静默丢弃——放宽 `:1971-1972` 的 `!deleted` 约束，删除侧也保留一份"已删除副本"。
  2. **HLC**：本地写笔记时维护 `updatedAt = max(now, maxSeenRemoteUpdatedAt + 1)`，至少保证因果序。
  3. 墓碑分支不要覆盖本地 `updatedAt`，改用 `max(local.updatedAt, item.updatedAt)`。

---

### P0-7 编辑页退出保存被"防重入返回 null"误判为成功 → 静默丢弃用户改动

- **位置**：`lib/views/add_edit_note.dart:335-375`（`_performAutoSave`）、`:298-325`（`_onPopInvoked`）；`lib/models/editor_state.dart:68-75`
- **现象**：`addOrUpdateNote` 在**两**种情况下返回 `null`：

  ```dart
  // editor_state.dart:71-74
  if (_isSaving) {                     // 静态守卫已置位 → 一行都没写库
    Log.note.d('笔记保存已在进行中, 本次调用跳过 ...');
    return null;
  }
  ...
  if (original!.title != title || ...) { saved = await updateNote(); }
  else { Log.note.d('笔记内容未变化, 跳过保存 ...'); }   // 内容未变 → 也返回 null
  ```
  而 `_performAutoSave` 把 `null` 统一映射成 `failed: false`（`:362`），`_onPopInvoked:319` 只看 `outcome.failed`，`false` 就直接 `await _closePage()` 关页。
- **风险**：**用户写了几百字，退出后笔记是旧的，且没有任何提示。** 触发窗口：页面的本地 `_isSaving` 为 false，但 `NoteEditorState` 的**静态** `_isSaving` 被另一条并发路径持有——周期自动保存（30s Timer）、切后台保存、或会话超时 `handleUngracefulNoteExit()`。此时在途保存已把 `title/description` 快照到 `T1`，用户继续敲到 `T2` 按返回 → 本次保存被跳过 → 页面关闭 → `T1..T2` 的内容永久丢失。这是笔记应用最坏的一类缺陷。
- **建议**：`addOrUpdateNote` 区分返回语义，改为返回 `({SafeNote? saved, bool skipped, bool failed})`；`_performAutoSave` 在 `skipped` 时先 `await` 在途保存完成再重试一次；`_onPopInvoked` 仅当明确"无改动 / 已成功落库"时才 `_closePage()`。同时把页面本地 `_isSaving` 与 `NoteEditorState._isSaving` 合并为单一守卫（把静态守卫暴露为 getter）。

---

## 三、P1 — 安全暴露面、崩溃、同步正确性、显著 UX 缺陷

### 加密 / 密钥管理

#### P1-1 `unlockFromRemoteManifest` 切换账本到远端 dataKey，但零重加密

- **位置**：`packages/core/lib/src/sync/keyring.dart:554-595` → 调用点 `lib/views/authentication/login.dart:599-618`
- **现象**：登录流程第 2 步（本地 `initKeyringFromPassword` 失败即走远端验证）用远端 header 重建 keyring 并 `persist`，**完全不调用 `reEncryptAllNotesAtomically`**，随后 login.dart:614-618 再 `unlockLocal` + `setDataKey`。`reEncryptAllNotesAtomically` 的生产调用点只有 `keyring.dart:727` 和 `:828` 两处。
- **风险**：**全库不可解 = 数据丢失。** 设计意图（见 `test/sync/change_password_multi_client_test.dart:38-40` 注释）是"dataKey 不变"，这在"他端改密码"场景下成立。但本地账本被旧备份回滚 / 只恢复了 notes 表 / 账本 JSON 损坏时，本地 notes 是用另一个 dataKey 加密的，这条路径会静默把 `_dataKey` 换成远端 key → 全库解不开 → 落到 P0-2 被逐条删除。且无用户确认、无 journal `key.migrate` 留痕、无回滚。
- **建议**：`unlockFromRemoteManifest` 增加 `oldDataKey` 参数（或先读现有账本）：若新旧 dataKey 不同，必须走与 `migrateToRemoteVault` 相同的 `reEncryptAllNotesAtomically(oldKey, newKey, keyringJson, markBlobReupload: true)`，失败则拒绝写入新账本并提示从备份恢复。登录 UI 在此分支必须弹二次确认。

#### P1-2 scenario-d 自动整库迁移缺少用户确认，判别输入全部来自未认证的明文 header

- **位置**：`sync_engine.dart:994-1031` → `keyring.dart:747-776`、`:782-842`
- **现象**：v5 容器的 `pubHash` 只是无密钥的 SHA-256，只能验损坏、不能验来源；header 是明文且不被 dataKey 认证（新设备 onboarding 的必需设计）。分支 2 在"指纹不同 + 本地 MK 解不开远端包裹"时，用**远端提供的 kdf/salt** 派生 MK，与**远端提供的 keyFingerprint** 比对，一致就无条件执行整库迁移。
- **风险**：**一次密码猜测 = 全库泄露。** 恶意服务端可构造"猜测密码 P'"的三元组（salt=S、keyFingerprint=H(MK(P',S))、encryptedDataKey=wrap(MK(P',S), K_attacker)）；客户端一旦命中（用户密码 == P'），就把整库用攻击者已知的 K_attacker 重加密并 PUT 全部 blob。KDF 上下界校验（`sync_models.dart:359-397`）只挡住了弱参数，挡不住这个方向。合法场景下"两台设备各自 createNew、密码相同"被自动改嫁到对端 vault，用户完全无感知。
- **建议**：① scenario-d 迁移前必须弹确认，展示远端 vaultId/创建时间并强制先备份；② 迁移前校验远端 vaultId 不等于本地已知的任何历史 vaultId，避免"改嫁"循环；③ UI 层对"新设备首次加入"与"运行中自动迁移"分流，后者默认关闭。

#### P1-3 DB Inspector 会原样吐出 keyring JSON，且与 `inspectMetadata` 的脱敏策略自相矛盾

- **位置**：`packages/core/lib/src/db/database_handler.dart:58`（`_inspectorHiddenColumns`）、`:233-246`（`queryTableRows`）；对照 `:309-316`（`inspectMetadata` 只列 key 名）；暴露面 `lib/src/logger/log_webserver_io.dart:368`
- **现象**：`_inspectorHiddenColumns = {'title', 'description', 'payload'}`，只藏了笔记密文列。`queryTableRows` 对 `sync_meta` 执行 `SELECT *`，`value` 列**不在隐藏名单里**，因此 `MetaKeys.keyring` 的完整 JSON（`encryptedDataKey` + KDF salt + iterations + keyFingerprint）被完整返回。而同类的 `inspectMetadata` 明确写了"sync_meta 的敏感 value（如 keyring JSON）不展开，仅列出 key 名"——**两条路径口径相反**。
- **风险**：**encryptedDataKey 泄露 = 交出可离线爆破的密码哈希。** 这份 JSON 同时含 salt 与 iterations，攻击者拿到后无需再碰设备。暴露面是 `log_webserver_io.dart` 的 LAN 日志服务（绑定 `0.0.0.0`），同一 WiFi 下可达；且 `/api/download/db` 可直接下载整个数据库文件。
- **建议**：`const Set<String> _inspectorHiddenColumns = {'title', 'description', 'payload', 'value'};` 或更彻底——`queryTableRows` 对 `sync_meta` 直接抛 `ArgumentError`，敏感表只允许通过 `inspectMetadata` 看 key 名清单。

#### P1-4 `note_meta` payload 解密失败降级为空后，任意元数据写操作会用 NULL 覆盖，标签永久丢失

- **位置**：`database_handler.dart:2524-2528`（降级）、`2539-2562`（`upsertNoteMeta` 写回）；配合 `note_meta.dart:228-234`、`:273-284`
- **现象**：`_decodeMetaRow` 解密失败时把 `plaintext` 置 null → `NoteMeta` 得到 `tags: []`。随后任何一次元数据编辑都走 `getNoteMeta(uuid) ?? defaults(uuid)` → `upsertNoteMeta(current.copyWith(pinned: ...))`，而 `encodePayload()` 对空内容返回 `null` → **payload 列被写成 NULL**，原始（解不开但完好的）密文就此消失。
- **风险**：**用户标签静默永久丢失。** 只需一次瞬时解密失败（dataKey 竞态、单行 bit rot、P0-4 残留）+ 一次点星标，标签就没了，且日志里 `tags=0` 看起来完全正常。
- **建议**：让降级可辨识，并在写路径拦截：`setNotePinned/setNoteTags/setNoteColor/setNoteLocked` 前校验 payload 是否可解，不可解则抛 `StateError` 拒绝覆盖；或让 `upsertNoteMeta` 在传入 plaintext 为 null 且 DB 中原有 payload 非 NULL 时，UPDATE 不带 payload 列（保留原值）。

### 数据层

#### P1-5 `_onUpgrade` 非幂等 + 无 `onDowngrade` → 降级再升级导致启动即崩

- **位置**：`database_handler.dart:924-936`（升级分支）、`:749`（`_createNoteMetaTable` 已含 `locked` 列）、`:695-710`（`OpenDatabaseOptions` 无 `onDowngrade`）
- **现象**：`_createNoteMetaTable` 建表时**已经包含** `locked` 列；`_onUpgrade` 的 `else if (oldVersion < 6)` 分支又会 `ALTER TABLE ... ADD COLUMN locked`。`OpenDatabaseOptions` 只有 `version/onCreate/onUpgrade`，`onDowngrade == null` 时 sqflite **不删库但会把 `user_version` 回写成更低的版本号**。
- **风险**：**用户所有本地笔记打不开，只能走"忘记密码"删库。** 复现：装 v7 → 降级到 v5 构建（beta/旧渠道包）→ `user_version` 被写成 5 但表结构不变 → 再升级回 v7 → `_onUpgrade(5,7)` 走 `else if` 分支 → `duplicate column name` → 异常从 `onUpgrade` 抛出 → 启动即崩。
- **建议**：加列前先查 `PRAGMA table_info`；并给 `onDowngrade` 一个非破坏实现（只记日志、保留表结构），不要让 sqflite 静默回写版本号。

#### P1-6 未配置 WAL / busy_timeout，长迁移事务冻结所有未加守卫的读路径

- **位置**：`database_handler.dart:695-710`（无 `onConfigure`）
- **现象**：从不执行 `PRAGMA journal_mode=WAL` / `busy_timeout` / `foreign_keys`，SQLite 默认走 rollback journal。`reEncryptAllNotesAtomically` 的迁移事务在循环里逐行 `txn.update`，3000 条笔记就是 3000+ 次 UPDATE 包在一个写事务里，持续数秒到数十秒。
- **风险**：**UI 冻结/ANR，多连接场景直接 SQLITE_BUSY。** rollback journal 下写事务持排他锁，所有读全部阻塞；而 `readUnsyncedNotes`、`readAllNotesIncludingDeleted`、`readAllNoteMeta`、`upsertNoteMeta`、`exportAll` 等**没有** `_checkNotMigrating`，不会快速失败而是排队等待 → 主线程卡死。桌面端 FFI / Web WASM / 移动端原生插件是三条不同连接实现，一旦出现两个 `Database` 对象指向同一文件，无 `busy_timeout` 会立刻抛错而非等待。
- **建议**：

  ```dart
  onConfigure: (db) async {
    await db.execute('PRAGMA journal_mode = WAL');
    await db.execute('PRAGMA busy_timeout = 5000');
    await db.execute('PRAGMA synchronous = NORMAL');
  },
  ```
  另外把迁移事务里的逐行 UPDATE 换成 `Batch` 提交，能把持锁时间降低一个数量级。

### 同步引擎

#### P1-7 SafeServer `listBlobs` 不校验 hash 格式，GC 用服务端返回串拼资源路径

- **位置**：`packages/core/lib/src/sync/backends/safe_server_backend.dart:481-484`（`hashes.whereType<String>().toList()`，无格式校验）→ `sync_engine.dart:2929` → `:2971 deleteBlobSoft` → `safe_server_backend.dart:497-505` / `:369-376`
- **现象**：WebDAV（`webdav_backend.dart:519-530`）与 LocalFS（`local_fs_backend.dart:206-216`）都用 `RegExp(r'^[a-f0-9]{64}$')` 过滤了枚举结果，**唯独 SafeServer 没有**。`listJournalObjects`（`:735/751-757`）的服务端名字同样直接进 `_getResource('journal/$name')`。
- **风险**：**远端数据被毁。** 服务端（或被 MITM 劫持的 HTTP 连接）在 `GET /api/v2/blobs` 里返回 `"../manifest"`，客户端就会发出 `move blobs/../manifest → blobs-orphan/...`（服务端规范化即 `manifest`），把用户的 manifest 移进隔离区；后续 `purgeOrphans` 还会真删。注意 Dart 的 `Uri.parse` **不做 dot-segment 归一化**。
- **建议**：三后端统一加 `_isValidHash(h)` 与 `_isSafeName(n)`（仅 `[A-Za-z0-9._-]`、不含 `..` 与路径分隔符），在 `getBlob/putBlob/deleteBlob/deleteBlobSoft/getJournalObject/putJournalObject` 入口校验，不合法直接抛 `BackendUnavailableException`；并在 `_gcOrphanBlobs`（`sync_engine.dart:2929`）做统一兜底校验，避免后端实现不一致时遗漏。

#### P1-8 下载/孪生物化路径把 `synced_hash` 写成 NULL，PUT 失败后合并 base 永久丢失

- **位置**：`sync_engine.dart:2563-2575`、`:2700-2717`（构造 `SafeNote` 时未传 `syncedHash`）→ `database_handler.dart:522-530`（`_toEncryptedRow` 用 `note.toJson()` 整行覆盖，`syncedHash` 被写为 null）
- **现象**：三方合并的 base 取自 `localNote.syncedHash`（`:1893`）。下载成功写入本地时该列被清空，只有后续 `_updateLocalState → markSyncedForUuids`（`:2858`）在 **PUT 成功之后**才补回。若下载成功但 PUT 失败/崩溃，本地 `synced_hash` 就是 NULL；而 `:1898-1905` 的逻辑是 `base == null` ⇒ `localChanged && remoteChanged` 全为 true ⇒ **必然判为"真冲突"**并走 LWW。
- **风险**：把每条下载过的笔记从"永不误判"降级为"下次必判冲突"，冲突计数虚高、UI 误报；更糟的是此时 LWW 真正参与裁决，叠加 P0-6 的时钟问题就会真丢数据。
- **建议**：下载时保留 base——`SafeNote(... syncedHash: existing?.syncedHash ?? item.hash ...)`；更稳妥的是让 `_downloadNote` 走"只改内容列 + 单独维护 synced 三列"的更新（`updateNoteContentOnly`），而不是整行覆盖。

#### P1-9 同步期间被编辑的笔记不刷新 base，下一轮生成"自己上一版本"的冲突副本

- **位置**：`sync_engine.dart:2821-2833`（`converged` 白名单判定）与 `:1898-1906`、`:1968-1983`
- **现象**：白名单要求"当前 (hash, deleted) == merged 项"才 `markSynced`。若笔记在 `_buildLocalManifest` 与 `_updateLocalState` 之间被用户再次编辑，本轮上传成功（远端已是 H1）但不进 `converged`，`syncedHash` 仍停在 H0。下一轮：local=H2、remote=H1、base=H0 ⇒ 判冲突；LWW 本地胜，但 `shouldPreserveCopy` 四项也全为 true ⇒ `_preserveConflictCopy` 把"远端败方"另存新笔记——而那个败方正是**本设备上一轮自己上传的 H1**。
- **风险**：副本增殖（`:2240-2252` 专门修过的老问题经此路径复发）。用户连续打字 + 3 秒 debounce 自动同步即可触发，表现为笔记列表里凭空多出"（冲突副本 1·设备）"。不丢数据，但污染数据且需用户手动清理。
- **建议**：把"base 刷新"与"synced 标记"解耦——本轮成功上传/下载的 uuid，即使当前内容已变，也应把 `syncedHash/syncedDeleted` 刷新为 merged 项的值（远端确实处于该状态），仅保持 `synced=0` 以便下轮继续上传。

#### P1-10 从 bak 恢复 manifest 会回滚代际，可复活已被硬删的笔记

- **位置**：`sync_engine.dart:622-643`（取到第一份能解开的 bak 即 `break`）→ `:684-698`（与本地合并后 PUT）
- **现象**：没有与当前代际做"不得更旧"的比较，merged 结果直接 PUT 覆盖当前远端。
- **风险**：**删除复活 + 覆盖回滚。** 已被硬删（进 purgedUuids 并从 manifest 移除）的笔记，在旧 bak 中仍是活条目且 blob 仍在远端 → 恢复后重新出现在所有设备；同时旧 bak 中较旧的 item 会参与 LWW，若其 `updatedAt` 更大（同设备早先写入且时钟更快）会反过来覆盖新内容。
- **建议**：bak 循环里记录每份的 `header.version`，只接受 `version >= 首次 GET 观测到的 version` 的备份；恢复前先把待恢复 manifest 中"本地 purgedUuids 内的 uuid"剔除。

### 同步后端与网络

#### P1-11 响应体读取无超时 + `sync()` 无总超时 → 同步可永久卡死，互斥锁再不释放

- **位置**：`packages/core/lib/src/sync/backends/http_util.dart:126`、`:136-145`；`lib/sync/sync_service.dart:547`、`:474` / `:584`
- **现象**：`await client.send(req).timeout(timeout)` 只给"收到响应头"加超时；随后 `await for (final chunk in streamed.stream)` **完全没有超时**。服务端只要先回 200 头再以每 30s 一字节的速度吐数据，这个 `await for` 永不结束。上层 `await engine.sync()` 也无总超时。
- **风险**：`_syncInProgress` 永久为 true → 之后所有 `sync()` 在 `sync_service.dart:470` 直接 return null → **笔记从此不再上传且不可自愈**，只能杀进程。UI 停在 `SyncStatus.syncing` 无任何错误提示。同时 `dispose()/logout()` 的 `waitForSyncCompletion`（10s）超时后关闭 backend/journal，在途引擎继续跑在已关闭的 HttpClient 上。
- **建议**：① `http_util.dart:136` 的读取循环整体包一层 `.timeout(timeout)`；② `sync_service.dart:547` 给 `engine.sync()` 加总超时（如 5 分钟）并在超时时强制复位 `_syncInProgress` 与状态；③ 引入 `CancelableOperation`/`_syncGeneration` 主动作废在途 future。

#### P1-12 用户把凭据贴在 URL 里时，密码会明文写进持久化日志与诊断快照

- **位置**：`lib/sync/sync_config.dart:174-177`（`Log.sync.d('WebDAV URL 已设置: $url')`）；`webdav_backend.dart:1166`（`'MKCOL $url failed: ...'`）；`lib/sync/sync_service.dart:558/572`
- **现象**：诊断快照里专门写了 `_redactUrl` 并注释"webdavUrl 可能内嵌 user:pass@"（`sync_service.dart:1010-1012`），说明作者知道这个风险；但**写入路径没有任何一处清洗**：`setWebdavUrl` 原样打日志，`WebDavBackend` 从不剥离 userinfo，`MKCOL` 失败时把整个 URL 拼进异常 message，最终以 ERROR 级写入 `AppLogFile`。
- **风险**：`https://user:pass@dav.example.com/...` 这种常见粘贴格式下，一旦后端配置有误导致 MKCOL 非 201/405（**错误配置是常态**），密码就明文常驻日志文件；用户按设计"导出诊断+日志"发给支持人员/贴到 issue 时即完整泄露网盘账号，H3 的 secure_storage 改造被完全绕过。
- **建议**：① 在 `SyncBackendDraft.normalized()`/`buildBackend()` 里统一把 URL 中的 userinfo 抽出来填 username/password 并从 URL 剥离（同时避免 dart:io 与 `_authHeaders()` 双写 Authorization）；② `setWebdavUrl` 一律走 `_redactUrl`；③ 异常 message 只拼 `uri.scheme://uri.host:port`。

#### P1-13 允许 `http://` 明文传输 Basic Auth / Bearer Token，且 URL 无任何合法性校验

- **位置**：`lib/sync/sync_config.dart:382-404`（`buildBackend` 只判空）；`webdav_backend.dart:136-140`（注释以 `http://192.168.1.118:2025/...` 为正常示例）；`safe_server_backend.dart:99-101`
- **现象**：两个远端后端都不限制 scheme，`file://`、`ftp://`、任意 host 都能存进去；`http://` 下 `Authorization: Basic base64(user:pass)` 与 `Bearer <token>` 全程明文。
- **风险**：公网 http WebDAV 配置下账号密码可被链路中间人直接读取（base64 等同明文）；SafeServer token 一旦泄露即完全控制该金库。畸形 URL 要等到第一次请求才 `Uri.parse` 抛 FormatException，报错时机错位。
- **建议**：`buildBackend()` 校验 `Uri.parse(url).scheme` 必须是 `https`；本机/局域网 `http://` 需用户对勾显式确认，且仅当 host 属于私有网段（10/172.16/192.168/127）时放行；UI 对 http + 公网 host 直接拒绝保存。

#### P1-14 SafeServer `backupCorruptManifest`：move 只要不是 204/404 就 DELETE 远端 manifest

- **位置**：`packages/core/lib/src/sync/backends/safe_server_backend.dart:419-445`（判据 `:428`，兜底删除 `:432-437`）
- **现象**：`_postResource('manifest','move',...)` 返回 400/401/403/405/5xx 时不作区分，直接 `DELETE /api/v2/manifest`；且入参 `ciphertext` 根本没被使用（损坏副本没有真正备份，只被 move 一次）。
- **风险**：任意一个瞬时 500 或旧版服务端返回 405，都会把远端 manifest **物理删除**，而此时"损坏副本"已经不在了，只能靠客户端本地重建——若本机数据更旧，等于全端数据回退。
- **建议**：只有 `404`（本就不存在）和 `204` 视为成功；其余状态码（尤其 5xx/401/403）直接抛 `BackendUnavailableException` 让上层中止修复，绝不删。同时把 `ciphertext` PUT 到 `manifest-backup/.corrupt-<ts>` 真正留一份再动原文件。

#### P1-15 在途同步没有取消机制，10s 等待超时后照样拆后端

- **位置**：`lib/sync/sync_service.dart:813-820`（`waitForSyncCompletion` 固定 10s）、`:381-384` 与 `:425-428`（超时后照样 close）、`:183-198`（`initialize` 无 `_syncInProgress` 检查）、`:301-363`（`updateKeyring` 直接换 `_engine`）
- **现象**：`logout()/dispose()` 只轮询等 10s，超时即继续关闭；`switchBackend` 有互斥（`:838`）但 `initialize` 与 `updateKeyring` 没有。
- **风险**：同步跑过 10s（大库/慢网很常见）时，后台把 HTTP client 和 journal 关掉，在途的 PUT manifest/blob 拿到 "Client is closed"/文件句柄失效，产生半写状态或永久重试失败；`updateKeyring` 并发换引擎则可能出现旧引擎继续往远端写。
- **建议**：`sync()` 返回 `CancelableOperation` 或在 service 里保存 `Completer`，`logout/dispose` 走"请求取消 + 等待"而不是"等 10s 就硬关"；`initialize()/updateKeyring()` 开头与 `switchBackend` 一样检查 `_syncInProgress`。

### UI / UX

#### P1-16 主页每次同步完成都全屏闪骨架屏，且滚动位置被重置到顶部

- **位置**：`lib/views/home.dart:223-249`（`_onSyncStateChanged`）、`:310-352`（`refreshNotes`）、`:708-737`
- **现象**：`refreshNotes()` 无条件 `setState(() => isLoading = true)`；`isLoading` 为真时列表区整块替换为 `loadingState()`（**不同 widget 类型**）。`_onSyncStateChanged` 对每个 `success/error 且 lastResult != null` 的状态都调 `refreshNotes()`，而 `lastResult` 在 `idle` 态仍非空，自动同步（编辑后 debounce 3s、改密码后、回前台时）会反复触发。
- **风险**：**用户在列表中部阅读时，后台同步一完成，整屏笔记瞬间变成 3 个灰骨架条并跳回顶部。** 自动同步期间几乎不可用；`_notesListScroll`/`_notesGridScroll` 因 ListView 被卸载而丢失 offset。
- **建议**：区分"首次加载"与"增量刷新"——只有 `allnotes` 尚为空时才走 `isLoading` 骨架；增量刷新用顶部细进度条 / `_syncStatusButton` 的旋转图标。且不要在 `isLoading` 分支里替换掉 ListView（改用 `Opacity`/`Stack` 叠加），保住 ScrollController 的 position。

#### P1-17 编辑器每次按键 `setState` 重建整个页面

- **位置**：`lib/views/add_edit_note.dart:153-154`（监听器注册）、`:535-549`（`_onEdit`）
- **现象**：两个 TextEditingController 的监听器对**每一次文本变化（含光标移动、IME 组合中）**调用 `setState`，重建整棵子树：`Scaffold → AppBar → _buildEditorLayout → MarkdownToolbar → NoteFormWidget(两个 TextField)`。
- **风险**：长笔记（数万字）输入时每次按键触发全页 rebuild + 两个 `EditableText` 重建，出现明显输入延迟、光标跳动、安卓输入法组合词卡顿。真正需要重建的只有 `_canUndo/_canRedo` 两个布尔值。
- **建议**：`_onEdit` 里只做赋值与历史入栈，用 `ValueNotifier<bool>` 驱动 undo/redo 按钮（`ValueListenableBuilder` 包住 `_undoRedoButtons`）；两个 TextField 抽成 `const`/`RepaintBoundary` 子组件。

#### P1-18 改密码：前置检查中的同步异常被静默吞掉，用户点完确认后什么都没发生

- **位置**：`lib/views/change_passphrase.dart:500-502`（`await SyncService.instance.sync()` 无 try/catch）、`:382-386`、`:450-453`
- **现象**：`_preChangeCheck` 在 `if (online)` 分支直接 `await SyncService.instance.sync()`；异常冒泡到 `_finalSubmitChange`，其外层只有 `try…finally`，`finally` 只复位 `_isChanging`，异常最终落到 Zone 日志。UI 上：确认框关闭 → "Processing..." 变回 "Confirm" → 无任何提示。其他步骤（备份、ping）都有 try/catch，**唯独这一步漏了**。
- **风险**：用户以为改密码失败/正在进行，反复点击；更糟的是可能以为已改成功。另外该 `finally` 里若未 mounted 就不复位，页面重建后按钮可能永久禁用。
- **建议**：给 `sync()` 加 `try/on Exception`，失败时走与"备份失败"同构的 `_showWarningDialog` 让用户选择继续/取消；`finally` 中把 `_isChanging` 复位与 mounted 解耦。

#### P1-19 改密码页密码框禁用 `enableInteractiveSelection` → 无法粘贴，密码管理器用户被拒之门外

- **位置**：`lib/views/change_passphrase.dart:176-177`、`:206-207`、`:246-247`
- **现象**：三个 `ShadInputFormField` 均设 `enableInteractiveSelection: false`，同时设了 `autofillHints: [password]`。**登录页的同款输入框（`login.dart:285-291`）没有这个设置，两处行为不一致。**
- **风险**：改密码时用户无法从 Bitwarden/1Password 粘贴新密码（长按无"粘贴"菜单、Ctrl+V 被禁），只能手打 20+ 位随机串 → **用户倾向改成弱密码**。autofill 填充后的文本同样不可编辑纠正。
- **建议**：删除这三处 `enableInteractiveSelection: false`。保留 `enableIMEPersonalizedLearning: false`（中文输入法不学习密码）即可。

#### P1-20 i18n 严重不完整：15 个语种中 13 个缺 183 条（约 34%）

- **位置**：`assets/translations/*.json`（基准 `en-US.json` = 534 条）
- **现象**：`cs/de/es/fr/id/nb-NO/pl/pt/pt-BR/ru/tr/uk/bn/hi/it` 均只有 351 条，`zh-TW.json` 383 条；只有 `en-US` 与 `zh-CN` 完整。easy_localization 缺键时静默回落英文。另：`hi.json`/`bn.json`/`it.json` 已翻译好但**未注册**进 `SafeNotesConfig._locales`（`lib/data/preference_and_config.dart:753-769`），属死资源。
- **风险**：非中英用户在一个界面里看到中英混杂文案；且缺失的多是后加的功能文案（PIN Lock、标签、Markdown、同步后端配置），恰好是用户最需要读懂的新功能。
- **建议**：跑 `scripts/i18n_audit.py` 产出缺口清单后补齐；把 `hi/bn/it` 补进 `_locales`（或删掉文件避免误以为已支持）；CI 加"各语种键数 == en-US 键数"门禁。

#### P1-21 仅 Android 有 FLAG_SECURE，其它平台无防截屏与最近任务预览保护

- **位置**：`android/app/src/main/kotlin/com/mcxiaoke/snotes/MainActivity.kt:50-72`（Android 唯一实现）；`lib/data/preference_and_config.dart:245-252`（`isFlagSecure` 开关）；`lib/utils/desktop_window*.dart`、`ios/` 内无任何对应实现
- **现象**：`updateSecureDisplaySetting()` 只在 Android 设置 `FLAG_SECURE`；`isFlagSecure` 这个"防截屏"开关在其它平台是**纯摆设**（有 UI 开关、无任何效果）。
- **风险**：iOS 上用户截屏会把已解密笔记正文存进相册；Windows/macOS 的截图工具、录屏、远程桌面可完整捕获笔记内容。对以"端到端加密隐私"为核心卖点的应用，这是承诺与实现的落差。
- **建议**：iOS 在 `applicationWillResignActive` 时盖一层 blur view、`applicationDidBecomeActive` 移除；桌面端在失焦时叠加遮罩层（可复用 `lib/utils/desktop_window_callback.dart` 已有回调）；Web 端无法阻止，应移除该开关避免错觉。

#### P1-22 `_sortAndStoreNotes()` 两处裸调用，异常无捕获

- **位置**：`lib/views/home.dart:660`（Newest first 开关）、`:671`（Sort by Modified Date 开关）
- **现象**：两处 `onChanged` 直接调用 `_sortAndStoreNotes()`（返回 `Future<void>`），既不 `await` 也不 `catch`。而 `refreshNotes()` 里同一函数是带 `MassDecryptionFailureException` / `Exception` 双分支处理的。
- **风险**：切换排序时若整库解密系统性失败（密码错/库损坏），异常直落 Zone：列表不更新、无全屏阻塞错误态、无 toast，用户只看到"点了没反应"。与 `home.dart:318-346` 精心设计的 M1 强提示路径完全脱节。
- **建议**：两处改为 `unawaited(refreshNotes())`，复用统一异常处理。

---

## 四、P2 — 性能、健壮性、可维护性

| # | 问题 | 位置 | 风险与建议 |
|---|---|---|---|
| 1 | 主页每个 item 在 build 里做 `allnotes.indexOf(note)` → O(n²) | `home.dart:940` | 5000 条时滚动掉帧。预建 `Map<String,int> _stableIndex`，O(1) 查表 |
| 2 | 协议降级只防旧不防新：`schemaVersion >` 本地时不处理，照常覆盖写低版本 | `sync_engine.dart:3236-3243` | 新协议数据被旧客户端降级覆盖。meta 段（`_syncNoteMeta:239-245`）做对了，manifest 段没做 |
| 3 | `ManifestKeyMismatchException` 在主路径 5 处全部未接管 | `sync_engine.dart:835/860/925/966/976` | 本应触发迁移/重登录的密钥不一致，被降级成含糊的通用错误。至少给 `:925` 加 catch 转明确 failure |
| 4 | `ManifestHeader.fromJson` 对不可信 header 直接 `as String`/`as int`，类型不符抛 `TypeError`（Error 子类）逃逸全部 catch | `sync_models.dart:577-595` | 同步静默失败；给服务端一个稳定的 DoS 开关。改为 `as String?` + 显式校验 |
| 5 | LocalFS manifest CAS 是"先读后写"且 tmp 名固定 | `local_fs_backend.dart:100-135` | 并发下丢失更新 = 笔记从索引整体消失。tmp 名加微秒时间戳 + `RandomAccessFile.lock()` 包住 read-compare-rename。另：文件头注释说只用于测试，UI 却暴露给用户，语义矛盾 |
| 6 | LocalFS `getManifest` 无大小上限；`readManifestBackup` 三个后端均无上限 | `local_fs_backend.dart:88-97` 等 | 恶意/损坏的 GB 级 manifest 被整读进内存。统一传 `kRemoteManifestMaxBytes` + `checkRemoteReadSize` |
| 7 | LocalFS `deleteBlobSoft` 重命名失败退化为硬删除 | `local_fs_backend.dart:236-252` | WebDAV 侧 H9 修复明确"COPY 失败不再硬删除"，LocalFS 未对齐，丢 30 天恢复窗口 |
| 8 | 响应体超限时/超时后未 drain，连接无法归还 | `http_util.dart:127-143` | socket 不释放回连接池。catch 路径统一 `await streamed.stream.drain<void>().catchError((_) {})` |
| 9 | 把服务端响应体整段塞进异常 message，再进用户可见文案 | `webdav_backend.dart:319/390/450/483`、`safe_server_backend.dart:209/275/477` | 错误信息不可读（HTML 直接弹给用户）、日志体积爆炸。只保留前 200 字符，按 statusCode 映射本地化文案 |
| 10 | 无 `PRAGMA secure_delete`，已删笔记的密文残留在 freelist 页 | `database_handler.dart:695-710` | 取证风险，与"永久删除不可恢复"的承诺不符。`secure_delete=ON`（可只对显式删除路径临时开启） |
| 11 | `storeNotesInTransaction` 的幂等去重 SELECT 在事务外，与 INSERT 间隔一次全量加密 | `database_handler.dart:1000` → `:1017` | 并发导入同一备份会撞 UNIQUE 整体回滚。把 SELECT 挪进事务或用 `INSERT OR IGNORE` |
| 12 | `updateNote` 整行覆盖会把 UI 持有的 `synced_hash` 写回旧值 | `database_handler.dart:1269-1300` | 下次同步误判"双方都偏离 base"→ 生成冲突副本。`_toEncryptedRow` 对 update 场景剔除 base 两列，所有权收口到同步引擎 |
| 13 | `retry`/恢复路径把远端 `dataKeyWrap` 原样 echo 回 PUT 的 header | `sync_engine.dart:1469` | 破坏"只读解密、不 echo 远端"的一致性。改为 `kDataKeyWrapAlgorithm` |
| 14 | `_syncNoteMeta` 用全量 `markNoteMetasSynced(all.values)`，未跟随正文侧白名单修复 | `sync_engine.dart:279-331` | 上传期间被修改的 meta 被误标 synced → 星标/置顶/标签变更永久不同步 |
| 15 | 同步性能：三次全量读库 + 每条笔记全量序列化 + 日志参数里无条件 `await DB` + N+1 `readNoteByUuid` | `sync_engine.dart:1749-1754`、`:1701`、`:1842/1892/2640/2696` | 万条笔记时单次同步显著耗时。日志改用已有 `purgedSet.length`；contentSize 缓存到 DB 列；合并为一次性建 Map |
| 16 | `mergeRemoteNoteMetas` 在事务内 `await` 加密操作 | `database_handler.dart:2685-2712`（`:2699`） | 持锁期间其它 DB 操作排队。与原子迁移同构，事务外预加密 |
| 17 | `getPendingReuploadUuids` 只捕获 `Exception`，`e as String` 抛 `TypeError` 逃逸 | `database_handler.dart:2300-2310` | 同步链路直接崩溃。改 `on Object catch`，并对齐 purgedUuids 策略（损坏不静默返回空集） |
| 18 | `cachedNoteSummaries()` 输出未加盐的标题 SHA-256 前 8 位 | `database_handler.dart:192-195` | 32 bit 无盐哈希可被秒级字典反查，绕过"日志中绝不允许出现笔记标题"的红线。直接删除该字段 |
| 19 | `reEncryptAllNotes`（非原子版）与 `markAllSynced*` 仍是公开 API | `database_handler.dart:1846-1969`、`:2147-2221` | "上膛的枪"——误用即回到 B1 全库不可解 / P1-A 丢数据事故。加 `@Deprecated` + `@visibleForTesting` |
| 20 | 修改 PIN 流程无失败计数、无尝试上限；计数存于未加密 SharedPreferences | `lib/views/settings/pin_setting.dart:475-489`；`lib/data/preference_and_config.dart:451-457` | 5 次锁定策略在设置路径上形同虚设；root 后可直接改计数为 0。把失败计数移入 secure storage 并做指数退避 |
| 21 | 复制全文把明文写入系统剪贴板且从不清理 | `lib/views/add_edit_note.dart:685-701` | 安卓 13+ 会弹剪贴板预览通知，等于把笔记推到通知栏。60s 后写入空串 |
| 22 | 错误信息把原始异常串 `$e` 直接喂给用户 | `home.dart:344/771`、`deleted_notes.dart:91/103`、`change_passphrase.dart` 多处 | 用户看到 `DataKeyNotSetException: instance of ...`；同时泄漏内部路径。按异常类型映射本地化文案 |
| 23 | 删除/恢复/清空回收站无异常兜底，失败时静默 | `lib/views/deleted_notes.dart:170-244` | 清空回收站是**不可恢复**操作，失败静默最危险。统一 try/catch + 失败保留列表 |
| 24 | PIN 设置流程 `PinAuth.setPin` 抛异常后 `_busy` 永久卡死 | `lib/views/settings/pin_setting.dart:502-509` | 用户已输入两遍 PIN 后失败 → 界面完全无响应，只能杀进程。try/catch 后复位 `_busy` |
| 25 | 路由 `'/'` 兜底分支创建孤立 StreamController 从不关闭 | `lib/routes/route_generator.dart:66-70` | 空闲锁定/失焦锁定在该会话内完全失效。复用全局 session 流 |
| 26 | build 内触发滚动动画（副作用），change_passphrase 版无 try/catch | `change_passphrase.dart:74-80/106-115`、`login.dart:172-177` | 控制器未 attach 时抛异常红屏。改 `addPostFrameCallback` + `hasClients` 守卫 |
| 27 | 主页整树依赖 `Provider.of<NotesColor>` | `home.dart:390` | 改笔记颜色时整个主页（可能数千 widget）重建。移到 `NoteCardWidget` 内 `context.watch` |
| 28 | 无障碍覆盖几乎为零 | 全 lib 仅 1 处 `Semantics(` | PIN 键盘对读屏用户只报数字；图标按钮缺 tooltip。PIN 键包 `Semantics(button:true, label:'PIN 键 $label')`，卡片用 `MergeSemantics` |
| 29 | `analysis_options.yaml` 过松 | `analysis_options.yaml:14-31` | 未启用 `strict-casts/strict-inference`，`unawaited_futures`、`use_build_context_synchronously` 未提为 error，导致 `Session.login` 的 fire-and-forget 调用异常静默丢失 |
| 30 | CI 未覆盖 integration_test；Taskfile 的 `gen-build-info` 引用不存在的 .py | `.github/workflows/flutter-ci.yml:44`；`Taskfile.yml:29-32` | 端到端路径零验证；`task get/run/build-apk` 全部失败（应为 `dart run scripts/generate_build_info.dart`） |
| 31 | 生产依赖混入构建期工具 `rename` | `pubspec.yaml:56` | 增大依赖图与 CVE 面。移到 `dev_dependencies` |
| 32 | release 构建可被用户连点 5 次开启 LAN 日志服务器 | `lib/utils/dev_mode.dart:42-45/65-88` | 整个保险库数据库文件在局域网可下载（token 在 URL query 中会被代理日志记录）。token 改 header 传递；`/api/download/db` 仅限 debug 构建 |
| 33 | 主页批量删除 `allnotes.firstWhere` 无 `orElse` | `home.dart:1355-1357` | 多选期间列表被同步刷新则抛 `StateError`，批量删除中断且无提示。预建 `Map<String, SafeNote>` |
| 34 | Argon2id `maxArgon2MemoryKiB = 256*1024`（256 MB）上界偏高 | `sync_models.dart:363` | 低端安卓设备派生时可能 OOM 崩溃。建议按平台收紧上界（移动端 ≤64 MB） |
| 35 | `close()` 不清 `_dataKey`，与 `clearDataKey()`/`deleteDbFile()` 语义不一致 | `database_handler.dart:2887-2894` | `main.dart:490` 用 `isEncryptionEnabled` 判断登录态，close 后仍返回 true 会误判 |

---

## 五、已检查且未发现问题的方面

这些是**确认过**的健康项，记录下来是为了说明覆盖面，也避免后续重复排查：

- **加密原语正确性**：AES-256-GCM（nonce 12B / tag 16B），`Random.secure()` 生成 nonce 与 salt，`dataKey` 为 32 字节 CSPRNG；AAD 域分隔正确（`datakey-wrap` / 内容 hash / `manifest-items` / `journal-aad` / uuid）；`bytesEqual` 为常数时间实现；`_aesGcmDecrypt` 在 sublist 前做信封长度校验，避免裸 `RangeError`（Error 子类）逃逸上层 `on SyncDecryptionException`。
- **KDF 参数边界校验**：`KdfParams.fromJson`（`sync_models.dart:343-407`）对远端**不可信** header 的 algorithm / iterations / memoryKiB / parallelism 做了上下界 fail-closed 校验，既防弱化攻击（`iterations=1`）也防 DoS（`iterations=10^9`）。
- **SQL 注入**：逐一核查全部 29 处 `rawQuery`/`rawUpdate`/`rawDelete`/`execute`。用户可控数据全部走 `?` 占位符或 `IN ($marks)` 动态占位符；SQL 文本里插值的标识符要么是 `const`，要么经 `_isSafeIdentifier` 正则白名单（`:249-250`）。**未发现注入点。**
- **密钥落盘与泄露**：全仓 grep 确认 `_dataKey` 只存在于 `database_handler.dart:162` 的实例字段，`setDataKey` 做防御性拷贝；`SafeNote.toString()` / `NoteMeta.toString()` / `NoteVersion.toString()` / `MassDecryptionFailureException.toString()` 均已脱敏；备份文件（snba）头不含 dataKey 或 encryptedDataKey；自动备份全部加密。
- **Basic Auth 实现**：两个远端后端均用 `Authorization` 头，**没有**把用户名密码拼进 URL。
- **重定向跟随**：`http_util.dart:78-88` 严格同源（scheme+host+port）才跟随，跨源/https→http 一律不跟随，headers 不会泄漏给第三方主机；写操作仅跟随 307/308，**不存在** PUT 被降级为 GET 的"假成功"。
- **重入保护**：`SyncService.sync()`/`repairRemote()` 的 `_syncInProgress` 检查都在任何 await 之前（Dart 单线程下无 check-then-act 竞态）；`Journal._writeChain` 串行化写盘；`Keyring._ledgerWriteQueue` 串行化账本写入。
- **blob 重试幂等性**：只对 `BackendUnavailableException` 且 `retryable` 重试；`putBlob` 内容寻址 + tmp/rename 覆盖写，重试安全。
- **journal 水位模型**：append-only，`syncToRemote` 只在成功后推进 `_uploadedSeq`，**不存在**"清了 journal 但推送失败"的丢数据路径。
- **PIN 的哈希加盐存储**：`pin_auth.dart:219-248` 用随机 salt + Argon2id 派生 + AES-GCM(`aad='pin-auth'`) 双层信封包裹 vault 密码，任何一步 GCM 校验失败都返回空串，无静默回退路径——实现正确。
- **生物识别启用鉴权**：`biometric_setting.dart:45-89` 启用前强制真实 `authenticate()`，失败不落凭据；与 PIN 互斥。
- **危险操作确认**：删除笔记、清空回收站、改密码（二次确认 + 前置备份/同步/ping 三道警告）、重置本地数据（两级确认 + 强制备份，失败即中止）、关闭 PIN、切换同步后端（需连接测试通过）——均已覆盖。
- **生命周期与资源释放**：`main.dart:332-342`、`home.dart:165-180`、`add_edit_note.dart:182-196`、`deleted_notes.dart:64-67` 的 StreamSubscription / Timer / Controller / FocusNode 均已完整 cancel/dispose；全库 `Timer` 仅 5 处且都有 cancel。
- **硬编码密钥 / 后门**：除 `SafeNotesConfig` 里的示例 URL（仅作 hint 文本）外，未发现硬编码密钥、内网地址或调试后门；`lib` 下 `print(` 零命中。

---

## 六、修复路线图建议

**第一批（阻断发布，目标：消灭静默丢数据）**
1. P0-1 墓碑 GC 补 `addPurgedUuids`
2. P0-2 读路径停止物理删除，改为 `broken` 标记隔离
3. P0-3 迁移与所有写路径串行化（异步互斥锁）
4. P0-7 编辑页退出保存区分 `skipped` 与 `failed`
5. P0-4 迁移遇解密失败即中止

**第二批（安全暴露面）**
6. P1-3 DB Inspector 隐藏 `sync_meta.value`
7. P1-7 SafeServer hash/name 白名单（三个后端统一）
8. P1-12 URL 内嵌凭据剥离 + 日志脱敏
9. P1-13 强制 https（局域网需显式确认）
10. P1-2 scenario-d 迁移前用户确认
11. P1-1 `unlockFromRemoteManifest` 切换 dataKey 时重加密

**第三批（同步正确性 / 健壮性）**
12. P0-5 损坏重建保留未知条目
13. P0-6 LWW 引入 HLC 与"未推送编辑永不静默丢弃"硬规则
14. P1-11 响应体读取超时 + `sync()` 总超时
15. P1-8 / P1-9 `synced_hash` 所有权与 base 刷新解耦
16. P1-14 / P1-15 / P1-10 后端删除类操作的保守化

**第四批（UX 与工程化）**
17. P1-16 ~ P1-22 的 UX 修复
18. P1-5 / P1-6 数据库配置（onDowngrade + WAL + busy_timeout）
19. `analysis_options.yaml` 收紧（启用 `strict-casts`、`unawaited_futures`、`use_build_context_synchronously`）
20. CI 覆盖 `integration_test`；修 `Taskfile.yml:31` 的脚本路径
21. i18n 补齐或裁剪语种

---

## 七、附：评审方法说明

- 核心包（`packages/core`）：`crypto.dart`、`keyring.dart`、`database_handler.dart`（2939 行）、`sync_engine.dart`（3285 行）、`journal.dart`、`sync_models.dart`、三个后端、全部 models 均为**全文通读**，非抽样。
- 应用层（`lib/`，123 个文件）：全文覆盖，重点精读 `main.dart`、`home.dart`、`add_edit_note.dart`、`change_passphrase.dart`、`deleted_notes.dart`、`pin_auth.dart`、`editor_state.dart`、`sync_service.dart`、`sync_config.dart`。
- 所有 P0 与关键 P1 结论均由主评审者**回到源码逐行复核**（`sync_engine.dart:1681-1780`、`database_handler.dart:520-660`、`sync_models.dart:300-407`、`add_edit_note.dart:290-390`、`editor_state.dart` 全文、`keyring.dart` 全文），并交叉验证调用链与测试代码中的设计意图注释。
- **已运行 `flutter analyze lib test packages/core`（本次评审时）**：`No issues found! (ran in 11.0s)`，0 个静态分析问题。这说明代码在现有 lint 规则下是干净的，**但也反证了 P2-29 的判断——`analysis_options.yaml` 过松，0 issue 并不等于 0 缺陷**（本报告 45 条问题中没有一条会被当前 lint 捕获）。
- 未运行 `flutter test` 与 `flutter build` 作为结论依据。

---

## 八、附：依赖健康度

`flutter pub get` 输出 `43 packages have newer versions incompatible with dependency constraints`。其中值得关注的**大版本跃迁**（不是补丁级，升级需要适配）：

| 包 | 当前 | 可用 | 说明 |
|---|---|---|---|
| `record_use` | 0.6.0 | 1.1.1 | 跨大版本，需评估 |
| `win32` | 5.15.0 | 6.4.0 | 跨大版本，桌面端 |
| `win32_registry` | 2.1.0 | 3.0.3 | 跨大版本，桌面端 |
| `permission_handler` | 12.0.3 | 13.0.1 | 跨大版本，Android 权限 API 有破坏性变更 |
| `package_config` | 2.2.0 | 3.0.0 | 跨大版本（传递依赖） |
| `vector_math` | 2.2.0 | 2.4.2 | 传递依赖 |
| `shadcn_ui` | 0.56.1 | 0.56.2 | 补丁级，可升 |

**建议**：补丁级可直接升；`permission_handler` 12→13 涉及 Android 权限 API 破坏性变更，建议单独排期并配真机回归。当前无已知高危 CVE，不构成紧急项，但 43 个约束不兼容说明依赖树已开始老化，建议每个季度做一次升级窗口。
