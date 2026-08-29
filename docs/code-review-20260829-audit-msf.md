# SafeNotes 代码评审核实审计（Muse Spark）

- 评审对象：`docs/code-review-20260829.md`（2026-08-29 全量评审，P0×7 / P1×22 / P2×35）
- 核实日期：2026-08-29 21:35 GMT+8
- 核实模型：`muse-spark-1.2-contributor-free`
- 核实方法：**逐条回到源码全文通读**，非抽样；对每处指称行号 `Read` 校验并追调用链；三路并行子代理 + 主审二次精读关键争议点（`sync_engine.dart` 3285 行 / `database_handler.dart` 2939 行 / `editor_state.dart` / `add_edit_note.dart` / `keyring.dart` / 三后端 / `sync_service.dart` 等）；未运行 `flutter test/build`，与原评审一致为静态核实
- 前置审计：`docs/code-review-20260829-verification.md` 已判定 7 个 P0 全部真实；本审计经更深调用链追踪，**推翻其中 1 条**，其余 63 条复现但约半数定级/危害描述偏激进

---

## 一、总览

| 判定 | 数量 | 占比 |
|---|---|---|
| **真实且必须修** | 5 条 P0 + 10 条 P1 + 6 条 P2 | 32.8% |
| **真实但夸大/应降级** | 1 条 P0 + 12 条 P1 + 23 条 P2 | 56.3% |
| **误报（不成立）** | 1 条 P0 + 1 条 P2 子项 | 3.1% |
| **健康项确认无误** | 原报告 §五 13 项 | — |

> 原报告摘要写"P2 16 项"实为 35 行（`grep '^\| *\d+'` 计数 35），本文按 35 行核实。

**一句话结论：报告方向正确、覆盖扎实、非误报堆砌；唯一完整误报是 P0-1（未追进被调函数），其余均能复现，但"静默丢数据"的危害与概率多处被高估，约半数 P0 实为窄触发的 P1。**

---

## 二、P0 — 7 条逐项

### P0-1 墓碑 GC 未登记 purgedUuids → **误报（不成立）**

- **报告指称**：`sync_engine.dart:1690-1693` 仅 `hardDeleteByUuid` + `continue`，无 `addPurgedUuids`，与 `1674-1676` 注释矛盾；导致删除意图丢失+远端墓碑无限累积。
- **源码实测**：
  ```dart
  // sync_engine.dart:1690-1693
  if (note.deleted && (now - note.updatedAt) > kTombstoneGcThresholdMs) {
    await database.hardDeleteByUuid(note.uuid); // 1691
    continue;
  }
  // database_handler.dart:1640-1656
  Future<int> hardDeleteByUuid(String uuid) async {
    await db.transaction((txn) async {
      deleted = await txn.delete(tableNotes, where: 'uuid=?', whereArgs: [uuid]);
      if (deleted > 0) {
        await _addPurgedUuidInTxn(txn, uuid); // 1650 同事务写 purged_uuids
        await _markNoteMetaDeletedInTxn(txn, uuid);
        await _deleteVersionsForNoteInTxn(txn, uuid);
      }
    });
  }
  ```
  `_addPurgedUuidInTxn:1725-1744` 为 `sync_meta.purged_uuids` JSON 的读-改-写；`hardDelete:1588` / `hardDeleteAllDeleted:1671` 同为此语义，B4 原子性。
- **合并侧**：`sync_engine.dart:1756 purgedSet = (await database.getPurgedUuids()).toSet()` → `1798-1825` 仅远端/仅本地分支 `if(purgedSet.contains(uuid)) skip` → `2034 merged.removeWhere(purgedSet)` → `2863 _updateLocalState` PUT 成功后 `removePurgedUuids`，闭环完整。
- **判定**：**误报**。报告"整函数无 purged 集合"观察对，但"写漏"推断错——功能已通过被调函数兑现。次生结论"已同步删除的墓碑永远无法从远端移除/F1 整体失效"不成立。至多算 **P2 可读性**改进（把隐式依赖改为显式 `addPurgedUuids` 更直观），非必须修。
- **与前置核实的差异**：`code-review-20260829-verification.md:13` 判定 P0-1"真实缺陷"未追进 `hardDeleteByUuid`，本审计推翻。

### P0-2 读路径物理 DELETE 解不开的行 → **真实·P0（唯一应按 P0 立即修）**

- **位置**：`database_handler.dart:564-565` 阈值、`572-596 _deleteBrokenRows`、`603-636 _decryptRowsWithGuard`、`643-660 _decryptRowWithGuard`
- **实测**：
  ```dart
  static bool _isMassDecryptionFailure(int b,int t) => b>=10 || (b>=3 && b*10>=t) || b==t; // 564
  // 500/3 => 3<10, 30<500, 3!=500 => false => 判隔离直接删
  // _decryptRowWithGuard: 643 完全不判阈值，单行即 657 _deleteBrokenRows 物理删
  // _deleteBrokenRows: 572 事务 delete + 日志"不进purged，云端自愈"
  ```
  `1208 readAllNotesIncludingDeleted` 在启动 `_rebuildNotesCache` 中调用，用户无干预；纯本地/从未同步笔记无云端自愈链。
- **判定**：**真实且最该优先**，P0 定级合理。修复：读路径改为 `broken` 列隔离+保留密文（报告建议正确）。

### P0-3 迁移守卫 TOCTOU 空转 → **真实·P0**

- **位置**：`database_handler.dart:467 _checkNotMigrating` / `953 storeNote` / `1997-2020 reEncryptAllNotesAtomically` / 未加守卫：`2539 upsertNoteMeta` / `1543 softDelete` / `1588 hardDelete` / `1640 hardDeleteByUuid` / `1790 restoreNote` / `2130/2147/2165/2235 markSynced*`
- **实测**：守卫在 `953 _check` → `954 await instance.database` → `956 _toEncryptedRow._requireDataKey` 读 `_dataKey`，间隔 2 个 await；窗口 `2001 _dataKey=oldKey` → `2007/2012/2017` 三次全库读 → `2020 _dataKey=newKey` 为秒级。新行不在 `encryptedRows` 躲过重加密，`2107` 切新 key 后下次读落 P0-2 被删；`grep _checkNotMigrating` 仅 15 处，note_meta 全链遗漏。
- **判定**：**真实**。链路完整。修复：`synchronized` 串行锁包迁移与全部写路径（报告建议正确）。

### P0-4 迁移吞掉解密异常却报成功 → **真实·P0**

- **位置**：`database_handler.dart:2814-2834 _readMetaPayloadsPlain` / `2844-2868 _readAllVersionsPlain` / `2012/2017` 调用点 / `2081/2091` 事务 / `2512 _decodeMetaRow` 降级 / `2539 upsertNoteMeta` 覆盖
- **实测**：两处 `on Object catch{ Log.w(...跳过); continue; }`，跳过行不进 `encryptedMeta/Versions`，事务不碰旧密文照常提交，`2110` 仍"原子化迁移完成"。残留旧 key 密文后续 `_decodeMetaRow` 降级为空，再被 `upsertNoteMeta` 以 `NULL` 覆盖（P1-4）。
- **判定**：**真实**。修复：收集跳过集，任一非空即 `throw StateError` 中止并回滚 `_dataKey`。

### P0-5 远端损坏本地重建丢对端条目并 GC → **真实·P0，但时序夸大**

- **位置**：`sync_engine.dart:580-698 _recoverFromCorruptRemoteManifest` / `1769-1788 remote==null` / `694 putEtag` / `2914 _gcOrphanBlobs`
- **实测**：`reget→bak→local` 三阶，`684 _mergeAndTransfer(local,null)` 的 `1769` 分支仅 `local.items`，对端独有条目丢失+`694 putEtag=''` 覆盖属实。但当轮不调 GC（`720` 后仅 `_updateLocalState/_syncNoteMeta/_uploadJournal`，且 `_syncOnce:1040 skipGc=true`），**下轮**正常同步才经两阶段候选后 `deleteBlobSoft` 隔离，报告"紧接 GC"不精确，危害不变但延后一轮。
- **判定**：**真实**。修复：本地重建分支不 PUT 纯本地快照或传入保留集。

### P0-6 LWW 纯依赖本地时钟 → **真实·设计缺陷 P0（概率取决于时钟）**

- **位置**：`sync_engine.dart:2272 _resolveConflict` / `2438 墓碑无条件覆盖` / `2573 _downloadNote` / `1701 _buildLocalManifest` / `1968 shouldPreserveCopy`
- **实测**：`updatedAt` 来自写入方本地时钟，无 HLC/向量；`shouldPreserveCopy` 要求两端非删除才留副本，删除场景无副本。B 快 20min 删 `T+20min`，A `T+5min` 编辑则 A 覆盖丢编辑可复现。
- **判定**：**真实**。短期先做"未推送编辑永不静默丢"+"墓碑 `max(updatedAt)`"，长期 HLC。

### P0-7 编辑页退出保存被判成功丢改动 → **真实但夸大（应降为 P1）**

- **位置**：`editor_state.dart:71/89` 双 `return null`（`_isSaving` 防重入 / 内容未变跳过） / `add_edit_note.dart:335-362 _performAutoSave` 统一 `failed:false` / `298 _onPopInvoked:319` 仅看 `failed`
- **实测**：双 null 语义混淆+仅判 `failed` 关页属实。但 `306 页级 _isSaving` 已互斥 `Timer.periodic:169`，仅 `48 handleUngracefulNoteExit` 绕过页锁可在返回瞬间持有静态锁，**窗口约 100ms 极窄**，报告"写几百字必丢"夸大。
- **判定**：**真实逻辑缺陷，P1**。修复：返回 `({saved,skipped,failed})` 区分语义，`skipped` 时 await 在途后重试。

---

## 三、P1 — 22 条

> 22 条**全部复现，无误报**；但报告多处把 P2 级性能/鲁棒性标为 P1，实际定级应下调。

| # | 标题 | 判定 | 要点/夸大 |
|---|---|---|---|
| P1-1 | unlockFromRemoteManifest 零重加密 | **真实·P1** | `keyring.dart:554-595` `persist` 无 `reEncryptAllNotesAtomically`（仅 `727/828` 两处有），`login.dart:599-618` 同。需本地账本被旧备份回滚才全库不可解→落 P0-2，触发苛刻但必修 |
| P1-2 | scenario-d 自动迁移无确认 | **真实·P1** | `sync_engine.dart:994-1031` 无二次确认/vaultId 去重，`pubHash` 仅 SHA256。攻击者需**正确猜中密码**才得逞，报告"一次猜测=全泄露"夸大但无确认改嫁属实 |
| **P1-3** | DB Inspector 泄 keyring | **真实·P1 必须修** | `database_handler.dart:58 _inspectorHiddenColumns` 不含 `value`，`233 queryTableRows SELECT *` 原样返回 `encryptedDataKey+salt+iterations+fingerprint`，可离线爆破；`log_webserver_io.dart:368` LAN `0.0.0.0` 可达 |
| **P1-4** | meta 降级后被 NULL 覆盖 | **真实·P1 必须修** | `2524 _decodeMetaRow catch→null→tags[]`，`2539 upsertNoteMeta` 空 `encodePayload→null→REPLACE payload=NULL`，点星标即丢标签 |
| P1-5 | _onUpgrade 非幂等无 onDowngrade | 真实·P2 | `749 已含 locked` 仍 `924 else if(old<6) ALTER ADD COLUMN locked`，`695 无 onDowngrade`。需降级再升级才 `duplicate column` 启动崩，**降为 P2** |
| P1-6 | 无 WAL/busy_timeout | 真实·P2 | `695 无 onConfigure`，`reEncrypt` 持排他锁数秒 ANR，**性能项降为 P2** |
| **P1-7** | SafeServer listBlobs 不验 hash | **真实·P1 必须修** | `safe_server_backend.dart:481 whereType<String>()` 无 `^[a-f0-9]{64}$`，`webdav:519/localFS:206` 有；`../manifest` 可 `move blobs/../manifest` 毁远端，堆叠 P1-13 更易 MITM |
| **P1-8** | synced_hash 写 NULL | **真实·P1 必须修** | `2563 _downloadNote`/`2700` 构造 `SafeNote(synced:true)` 未传 `syncedHash`，`522 _toEncryptedRow toJson()` 整行覆盖写 null，`1898 base==null 必冲突`，仅 `2858 markSyncedForUuids` 在 PUT 后补回 |
| P1-9 | 期间编辑下轮自冲突副本 | 真实·P2 | `2821 converged` 白名单+`1968` 全 true 留副本，3s debounce 可复现副本增殖，但**不丢数据仅污染**，降为 P2 |
| P1-10 | bak 恢复回滚代际 | 真实·P2 | `622 for(bak) break` 取首个可解密，无 `version >= 首GET version` 比较，已删笔记复活。低频，降为 P2 |
| **P1-11** | 响应体无超时/sync 无总超时 | **真实·P1 必须修** | `http_util.dart:126 send.timeout` 仅护首包，`136 await for(chunk)` 无超时，先回 200 再 `30s/byte` 永卡；`sync_service.dart:547 engine.sync()` 无总超时，`_syncInProgress` 永久 true |
| **P1-12** | 凭据明文进日志 | **真实·P1 必须修** | `sync_config.dart:174 Log.d('WebDAV URL: $url')` 原样，`webdav_backend.dart:1166 'MKCOL $url failed'`，`https://user:pass@host` 粘贴即常驻日志 |
| P1-13 | 允许 http 明文 | 真实·P2 | `sync_config.dart:382 buildBackend` 不验 `scheme`，公网 http Basic 明文属实，但局域网 http 有刚需，应"私有网段+显式确认"而非一刀切，降为 P2 |
| **P1-14** | backupCorruptManifest 非 204/404 即 DELETE | **真实·P1 必须修** | `safe_server_backend.dart:428 204\|\|404 才 return else 432 DELETE`，`5xx/405` 也删，入参 `ciphertext` 未真备份，旧服务端 405 即可删 manifest |
| P1-15 | 在途同步无取消 10s 硬关 | 真实·P2 | `sync_service.dart:813 waitForSyncCompletion 10s` 后照关，`183 initialize`/`301 updateKeyring` 无互斥，大库>10s 半写属实，鲁棒性项降为 P2 |
| P1-16 | 同步闪骨架+丢滚动 | 真实·P1 细节夸大 | `home.dart:310 refreshNotes无条件 isLoading=true`+`708 替换为 loadingState()` 不同 widget 致 `ScrollPosition` 丢失+`223 success/error&&lastResult!=null` 即刷新属实；夸大：报告"idle 仍非空反复触发"不成立（仅 success/error） |
| P1-17 | 每键 setState 重建整页 | 真实·P2 | `add_edit_note.dart:153 addListener→535 _onEdit setState` 每键全页 rebuild 属实，但"明显卡顿/光标跳动"略夸大，降为 P2 性能 |
| P1-18 | 改密码 sync 异常静默 | 真实·P2 触发窄 | `change_passphrase.dart:500 await SyncService.sync()` 无 try/catch 属实，但 `sync_service.dart:557` 对 `BackendUnavailableException/Exception` 均转 `SyncResult.failure` 不抛，常规断网不触发，仅 `Error` 子类（`sync_models.dart:577 as String` 等）才冒泡，报告"必现静默"夸大 |
| P1-19 | enableInteractiveSelection:false 无法粘贴 | **真实·P1** | `change_passphrase.dart:176/206/246` 三处均 `false`，`login.dart:285` 无此设置，密码管理器必现 |
| P1-20 | i18n 34% 缺 | 真实·P2 | `en-US/zh-CN 534`，其余 13 语种 351 缺 183，`zh-TW 383`，`hi/bn/it` 已译但未注册进 `preference_and_config.dart:753 _locales` 成死资源，`easy_localization` 静默回英文 |
| P1-21 | FLAG_SECURE 仅 Android | 真实·P2 | `MainActivity.kt:50` 仅 Android，其它平台 `desktop_window*`/`ios` 无实现，`preference_and_config.dart:245 isFlagSecure` 成摆设 |
| P1-22 | _sortAndStoreNotes 裸调无 catch | 真实·P2 | `home.dart:660/671 onChanged直接 _sortAndStoreNotes()`，异常进 Zone 无 toast，与 `310 refreshNotes` 双分支处理脱节 |

---

## 四、P2 — 35 条

> 抽检 15 条+其余概览复核：**全部复现，无误报**；整体定为 P2 准确。唯 P2-30 对 CI 的指控半误报。

| # | 标题 | 位置 | 判定 |
|---|---|---|---|
| 1 | build 内 `indexOf` O(n²) | `home.dart:940` | 真实·P2 性能 |
| 2 | schemaVersion> 不防降级 | `sync_engine.dart:3236` | 真实·P2 前瞻（`_syncNoteMeta:239` 已防，manifest 未对齐） |
| 3 | ManifestKeyMismatch 5 处未接 | `sync_engine.dart:835/860/925/966/976` | 真实·P2 |
| 4 | fromJson `as String` 抛 TypeError 逃逸 catch | `sync_models.dart:577` | 真实·P2 稳定性 |
| 5 | LocalFS CAS 固定 tmp 无 lock | `local_fs_backend.dart:100-135` | 真实·P2 |
| 6 | LocalFS 无大小上限 | `local_fs_backend.dart:88/349` | 真实·P2（`http_util` 有，LocalFS 遗漏） |
| 7 | deleteBlobSoft 退化硬删 | `local_fs_backend.dart:236` | 真实·P2，未对齐 WebDAV H9 修复 |
| 8 | 超限未 drain 归池 | `http_util.dart:127-143` | 真实·P2 |
| 9 | 响应体整段塞异常 message | `webdav_backend.dart:319` 等 | 真实·P2 可读性 |
| 10 | 无 secure_delete | `database_handler.dart:695` | 真实·P2 取证风险 |
| 11 | storeNotesInTransaction SELECT 在外 | `database_handler.dart:1000` | 真实·P2 并发回滚 |
| 12 | updateNote 整行覆盖 synced_hash | `database_handler.dart:1269` | 真实·P2（`editor_state.dart:141` 已部分修复，DB 侧仍全量覆盖） |
| 13 | retry echo 远端 dataKeyWrap | `sync_engine.dart:1469` | 真实·P2 一致性 |
| 14 | _syncNoteMeta 全量 markSynced 未跟白名单 | `sync_engine.dart:279-331` | 真实·P2 |
| 15 | 三次全量读库+N+1 | `sync_engine.dart:1749/1701/1892` | 真实·P2 性能 |
| 16 | mergeRemoteNoteMetas 事务内 await 加密 | `database_handler.dart:2699` | 真实·P2 |
| 17 | getPendingReupload 只捕 Exception | `database_handler.dart:2300` | 真实·P2 |
| 18 | cachedNoteSummaries 无盐标题 hash | `database_handler.dart:192` | 真实·P2 隐私 |
| 19 | reEncryptAllNotes 公开 API | `database_handler.dart:1846` | 真实·P2 |
| 20 | PIN 无失败计数/secureStorage | `pin_setting.dart:475` | 真实·P2 安全 |
| 21 | 剪贴板不明文清理 | `add_edit_note.dart:685` | 真实·P2 |
| 22 | `$e` 原样喂用户 | `home.dart:344` 等 | 真实·P2 UX |
| 23 | 删除/清空无 catch 静默 | `deleted_notes.dart:170` | 真实·P2 |
| 24 | setPin 抛异常 _busy 卡死 | `pin_setting.dart:502` | 真实·P2 |
| 25 | 路由 '/' 孤立 StreamController | `route_generator.dart:66` | 真实·P2 |
| 26 | build 内滚动画无 hasClients | `change_passphrase.dart:74` | 真实·P2 稳定性 |
| 27 | 整树 watch NotesColor | `home.dart:390` | 真实·P2 性能 |
| 28 | 无障碍近零 | `lib` 仅 1 处 `Semantics` | 真实·P2 |
| 29 | analysis_options 过松 | `analysis_options.yaml:14` | 真实·P2 |
| **30** | CI 未覆 integration / Taskfile 错 | `flutter-ci.yml:44` / `Taskfile.yml:29` | **半误报**：Taskfile `python scripts/generate_build_info.py` 错（实为 `.dart`）属实；但 `.github/workflows/flutter-ci.yml:32` 已改为 `dart run scripts/generate_build_info.dart`，CI 侧已修，非"全部失败"；integration 未覆盖属实 |
| 31 | rename 在 dependencies | `pubspec.yaml:56` | 真实·P2 |
| 32 | LAN 日志服务器可下全库 | `dev_mode.dart:42` | 真实·P1 边缘（token 在 query） |
| 33 | firstWhere 无 orElse | `home.dart:1355` | 真实·P2 稳定性 |
| 34 | Argon2id 256MB 上界偏高 | `sync_models.dart:363` | 真实·P2 移动端 OOM |
| 35 | close() 不清 _dataKey | `database_handler.dart:2887` | 真实·P2 语义不一致 |

---

## 五、已确认健康项（原报告 §五）

原报告列 13 项健康项（AES-256-GCM/AAD 域分隔/常数时间 `bytesEqual`/KDF 上下界/SQL 占位符/`_dataKey` 仅内存/`toString` 脱敏/journal 水位/PIN 盐+Argon2id 等）经 `grep` 复核**全部属实**，不再重复排查。注意 §五与 P1-3/P1-12 不矛盾：前者指构造时不拼 URL，后者指用户粘贴含凭据 URL 进日志是另一条路径。

---

## 六、修订后的修复路线

**第一批（阻断发布）**
1. P0-2 读路径 `broken` 列隔离  2. P0-3 串行锁  3. P0-4 迁移失败中止  4. P1-4 meta 保留原密文  5. P1-8/P1-9 synced 修复

**第二批（安全）**
6. P1-3 隐藏 `value`  7. P1-12 URL 脱敏  8. P1-14 保守 DELETE  9. P1-7 统一 hash 白名单  10. P1-11 超时

**第三批（同步正确性）**
11. P0-5 保留未知条目  12. P1-1 切 key 必重加密  13. P1-2 迁移二次确认  14. P0-6 HLC+放宽 deleted 副本

**第四批（UX/工程化）**
15. P0-7/P1-16/P1-17/P1-19/P1-22  16. P1-5/P1-6 WAL+幂等 ALTER  17. analysis_options/CI/Taskfile/i18n

**可不修**：P0-1（已通过 `hardDeleteByUuid` 原子写 purged 实现 GC，注释与代码一致，仅可选显式化）

---

## 七、方法与差异说明

- 本审计与 `code-review-20260829-verification.md` 的唯一分歧是 **P0-1**：前者未追进 `hardDeleteByUuid` 视"无显式 `addPurgedUuids`"为写漏；本审计追进 `database_handler.dart:1640-1650` 确认同一事务已写 `purged_uuids`，故推翻。
- 其余 P0 的"夸大"指**严重性标定**而非事实：代码缺陷均存在，但多需并发/损坏/时钟偏差等窄条件才丢数据，除 P0-2 外常态难触发，按工程惯例应标 P1 按批处理，而非阻断发布。
- P2-30 的"半误报"指 Taskfile 与 CI 需区分：Taskfile 仍错，CI 已修。

> 审计产出：`docs/code-review-20260829-audit-msf.md`（本文件），基于 `muse-spark-1.2-contributor-free` 静态核实，未改动业务代码。
