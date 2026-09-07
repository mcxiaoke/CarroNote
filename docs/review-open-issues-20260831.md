# SafeNotes 代码评审遗留问题汇总（合并权威版）

* 汇总日期：2026-08-31 (GMT+8)

* **本文件取代并合并以下 6 份旧文档（已删除）**：

  * `docs/code-review-20260829.md`（原全量评审）

  * `docs/code-review-20260829-verification.md`

  * `docs/code-review-20260829-checkbyds.md`

  * `docs/code-review-20260829-audit-msf.md`

  * `docs/fix-plan-20260829.md`

  * `docs/code-review-20260831.md`

* 核实方法：4 路并行子代理对 `packages/core` + `lib/` 全文通读，并追溯关联调用链（非仅问题附近几行）；关键项由主审回源码复核。行号基于 2026-08-31 当前磁盘代码。

***

## 一、总体结论

`code-review-20260829` 所列问题中，**第一批（A1–A7）与第二批 B6 已修复，P1-9 已由三方合并抵消，P1-18 经核实现无风险**；P0-1 为误导报；P0-2 / P0-6 / P0-4 / P1-8 / P1-10 属既有设计取舍或已搁置。

**全部 issue 已于 2026-08-31 收口为三类，无遗留 open：**

| 状态    | 范围                                                                                       |
| ----- | ---------------------------------------------------------------------------------------- |
| ✅ 已修复 | H-1、H-2、H-4、H-6；M-3、M-5、M-6；L-1、L-3、L-8、L-10、L-11、L-22、L-23、L-31（另见第五节 A1–A7 / B6 等）     |
| ⏸ 搁置  | H-3、H-5；M-4；L-21（触及同步核心迁移/恢复/取消，触发前提窄，理由见第二/三/四节与第六节）                                    |
| ⚪ 忽略  | M-1、M-2、M-7、M-8、M-9、M-10、M-11、M-12；L-2、L-4、L-5、L-6、L-7、L-9、L-12–L-20、L-24–L-30、L-32–L-41 |

> 上述已修复 / 搁置 / 忽略均已逐节点名标注，见对应章节标题与表格中的 `〔状态〕` 标记。
> 误报 / 设计取舍项见第六节（不属待办）。

***

## 二、🔴 高优先 —— 数据 / 安全，建议尽早修复

> 触发概率 × 影响综合最高。多数为小改动。注：H-1/H-2/H-4/H-6 已修复（H-4 于 2026-08-31 第四批；
> **H-3/H-5 决定搁置**（触及同步核心迁移/损坏恢复，触发前提窄，与先前 B5/C1/C2 的有意搁置一致），详见第七节。

### H-1. WebDAV `listJournalObjects` 路径遍历（原 M-1）〔✅ 已修复〕

* **位置**：`packages/core/lib/src/sync/backends/webdav_backend.dart:794-799`

* **现状**：仍仅 `decoded.endsWith('.json')` 无白名单；恶意/共享 WebDAV 返回 `%2E%2E%2Fsecret.json` 可逃逸 journal 目录，客户端向该路径发带认证头 GET。

* **建议**：与 SafeServer（`safe_server_backend.dart:759-765`）对齐，加 `^[A-Za-z0-9._-]+$` + 禁 `..`。改动 3 行。

### H-2. `getPendingReuploadUuids` JSON 损坏静默返回空 + 漏捕 TypeError（原 M-3 / P2-17）〔✅ 已修复〕

* **位置**：`packages/core/lib/src/db/database_handler.dart:2328-2338`

* **现状**：仍 `on Exception catch {...; return {};}`；且 `jsonDecode as List` 后元素 `as String` 的类型错抛 `TypeError`（Error）逃逸，未与 `_parseUuidList`（L1792-1799 抛 `FormatException`）对齐。损坏时系统认为"无需重传"，**旧 key 的 blob 永久残留远端，其它设备用新 dataKey 无法解密**。

* **建议**：改为损坏即 `throw FormatException`，并对齐类型校验。

### H-3. scenario-d 自动整库迁移无确认、无 vaultId 校验（原 P1-2 / C2）〔搁置〕

* **位置**：`sync_engine.dart:1009-1031` → `_executeMigrationVault`（L1587-1666）

* **现状**：指纹不同 + 本地 MK 解不开远端包裹时，直接整库改嫁远端 vault，无二次确认、无 vaultId 去重。

* **建议**：迁移前弹确认（展示远端 vaultId/创建时间 + 强制备份）；校验远端 vaultId 不等于本地任何历史 vaultId。

### H-4. `unlockFromRemoteManifest` 切 dataKey 零重加密（原 P1-1 / C1）〔✅ 已修复〕

* **位置**：`keyring.dart:554-589`，调用链 `login.dart:599-618`

* **修复（2026-08-31）**：`unlockFromRemoteManifest` 在 `persist` 前先 `database.verifyDataKey(dataKey)`
  抽样校验本地密文能否用远端 key 解：库空或能解（正常多设备/新设备）放行；解不开（本地账本与 notes
  密钥不一致）则抛 `LocalVaultKeyMismatchException` 拒绝覆盖，login 层提示"从备份恢复"。新增
  `verifyDataKey`（不改内部 dataKey）与 2 个回归测试。

* **建议**：切换前后校验 local 库可解性；dataKey 不同则走重加密。

### H-5. 远端 manifest 损坏 → 本地重建丢弃"仅远端有"条目（原 P0-5）〔搁置〕

* **位置**：`sync_engine.dart:572-734` 的 `remote==null` 分支（L1768-1787）＋空 etag PUT（L694-698）

* **现状**：reGET + 全部 bak 不可用时，以纯本地 items 合并并覆盖远端，其他设备独有条目丢失，后续 GC 会隔离其 blob。触发前提极严（远端彻底不可恢复）。

* **建议**：本地重建分支不 PUT 纯本地快照，或传入"保留集"跳过本轮 GC。

### H-6. `_checkNotMigrating` 守卫遗漏 5 处写路径（原 P0-3 残留）〔✅ 已修复〕

* **位置**：A2 已给 8 处补守卫；**下列仍缺失**：`hardDeleteAllDeleted`（database\_handler.dart:1694）、`mergeRemoteNoteMetas`（L2714）、`markNoteMetasSynced`（L2765）、`purgeReportedNoteMetaTombstones`（L2801）、`markAllForBlobReupload`（L2315）

* **现状**：迁移窗口内这些写操作可用旧 key 加密，迁移后不可解。其中 `mergeRemoteNoteMetas` 与迁移事务均会改写的行，风险最贴近 A2 场景。

* **建议**：与既有守卫口径一致补 `_checkNotMigrating()`；根治仍建议异步互斥锁（`package:synchronized`）串行化迁移与全部写路径。

***

## 三、🟠 中优先 —— 崩溃 / 同步正确性 / 显著 UX

> 状态：✅ 已修复 = M-3、M-5、M-6；⏸ 搁置 = M-4；⚪ 忽略 = M-1、M-2、M-7、M-8、M-9、M-10、M-11、M-12。

### M-1. manifest 段新旧协议降级覆盖（原 P2-2）〔忽略〕

* **位置**：`sync_engine.dart:3249-3255` `rejectOldSchemaVersion` 仅拒旧，对 `schemaVersion >` 本地未来协议无拦截；`_syncNoteMeta`（L239-245）已防空，manifest 段未对齐。

* **建议**：manifest 段同样拒绝高于本地的 schema，避免新协议被旧客户端降级覆盖。

### M-2. ManifestKeyMismatchException 主路径 5 处未接管（原 P2-3）〔忽略〕

* **位置**：`sync_engine.dart:835/860/925/976/1024`

* **建议**：至少给 `:925` 加 `catch` 转明确 failure（触发迁移/重登录语义），其余视同通用错误。

### M-3. 无 onConfigure（WAL/busy\_timeout）+ 无 onDowngrade + 幂等 ALTER（原 P1-5 / P1-6 / C5）〔✅ 已随第二批修复〕

* **位置**：`database_handler.dart:711-730` `OpenDatabaseOptions` 原无 `onConfigure` / `onDowngrade`；`_onUpgrade` 的 `ALTER ADD COLUMN` 原无 `IF NOT EXISTS` 守卫。

* **修复**：`_initDB` 补 `onConfigure`（`journal_mode=WAL`、`busy_timeout=5000`、`synchronous=NORMAL`，best-effort 静默降级）与 `onDowngrade`（非破坏仅记日志）；新增 `_columnExists` 使 `_onUpgrade` 两个 `ALTER ADD COLUMN` 幂等。

### M-4. 在途同步无取消 / 10s 后硬关 backend（原 P1-15）〔搁置〕

* **位置**：`sync_service.dart:830-837` `waitForSyncCompletion` 固定 10s；`dispose`/`logout` 超时后仍 `_backend?.close()`；`initialize`（L188）与 `updateKeyring`（L306）无 `_syncInProgress` 互斥。

* **建议**：`sync()` 走 `CancelableOperation`/`Completer`，`logout/dispose` "请求取消 + 等待"；`initialize/updateKeyring` 开头检查 `_syncInProgress`。

### M-5. Ctrl+N 快捷新建竞态崩溃（原 M-6）〔✅ 已修复〕

* **位置**：`add_edit_note.dart:488-497` 仍 `unawaited(_performAutoSave)` 后立即 `pushNamed('/addnote')`。

* **建议**：改为 `await _performAutoSave(keepEditing: true)` 完成后再导航。

### M-6. 两个认证页滚动动画缺 try/catch（原 M-4）〔✅ 已修复〕

* **位置**：`set_passphrase.dart:191-200`、`change_passphrase.dart:106-115` 无 try/catch；`login.dart:222-233` 有。build 内首帧可能抛 `StateError`。

* **建议**：与 login 对齐加 `try{...}catch(_){}`（可抽共享 mixin 统一）。

### M-7. updateNote 整行覆盖 `synced_hash`（DB 层，原 P2-12 残留）〔忽略〕

* **位置**：`database_handler.dart:1300-1305`（updateNote）、`1360`（updateNoteByUuid）仍 `_toEncryptedRow` 整行覆盖；`editor_state.draw:166-208` 编辑路径已修复，但 DB 层下载/孪生路径仍覆写 base。

* **建议**：DB 层 update 场景剔除 base 两列，所有权收口到同步引擎。

### M-8. note\_meta 降级为空后 payload 被 NULL 覆盖（原 P1-4 / B3）〔忽略〕

* **位置**：`database_handler.dart:2540-2559` `_decodeMetaRow` 失败置 null；`upsertNoteMeta`(L2567-2595) 整行 REPLACE 覆盖。标签可能在瞬时解密失败后永久丢失。

* **建议**：写路径校验原 payload 是否可解，不可解则抛 `StateError` 拒绝覆盖（或 UPDATE 不带 payload 列保留原值）。

### M-9. 改密码页禁粘贴（原 P1-19）〔忽略〕

* **位置**：`change_passphrase.dart:177/207/245` `enableInteractiveSelection:false`，`login.dart` 无此设置。

* **建议**：删除三处禁粘贴，保留 `enableIMEPersonalizedLearning:false`。

### M-10. 同步完成闪骨架屏 + 滚动重置（原 P1-16 / C4）〔忽略〕

* **位置**：`home.dart:233-236` 每次 `success/error` 调 `refreshNotes()`，`refreshNotes` L310-312 无条件 `isLoading=true` 整块替换列表。

* **建议**：区分首载与增量刷新；增量用细进度条，不卸载 ListView。

### M-11. `backupCorruptManifest` 的 `ciphertext` 入参死参（原 P1-14 残留）〔忽略〕

* **位置**：`safe_server_backend.dart:425` `ciphertext` 未使用（move 直接搬移远端文件，未写损坏备份）。

* **建议**：真正 PUT 一份 `.corrupt-<ts>` 备份再动原文件。

### M-12. repair 路径 echo 远端 `dataKeyWrap`（原 P2-13）〔忽略〕

* **位置**：`sync_engine.dart:1463-1471` 把远端 `dataKeyWrap` 原样回传 PUT。已核验 echo 的仅为**算法字符串**（非密钥），实际风险低。

* **建议**：改为 `kDataKeyWrapAlgorithm`，统一"只读解密不 echo"。

***

## 四、🟡 低优先 —— 防御纵深 / 性能 / 工程质量

> 均为原 P2 / L 级。状态：✅ 已修复 = L-1、L-3、L-8、L-10、L-11、L-22、L-23、L-31；
> ⏸ 搁置 = L-21；⚪ 忽略 = L-2、L-4、L-5、L-6、L-7、L-9、L-12、L-13、L-14、L-15、L-16、
> L-17、L-18、L-19、L-20、L-24、L-25、L-26、L-27、L-28、L-29、L-30、L-32、L-33、L-34、
> L-35、L-36、L-37、L-38、L-39、L-40、L-41。

| 编号   | 问题                                                                                            | 位置                                                                          | 备注                                    |
| ---- | --------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- | ------------------------------------- |
| L-1  | LocalFS `listJournalObjects` 无白名单（原 M-2）〔✅已修复〕                                                | `local_fs_backend.dart:395-399`                                             | 纵深防御，本地目录风险低                          |
| L-2  | `' '` 占位符致回收站标题显示空白（原 M-5）                                                                    | `editor_state.dart:104-105`、`deleted_notes.dart:313`                        | 改 `.trim().isEmpty` 或模型层归一            |
| L-3  | `_decryptField` 裸 `catch` 捕获 Error（原 M-7）〔✅已修复〕                                               | `database_handler.dart:535`                                                 | 收窄 `on Exception`                     |
| L-4  | fromJson `as String/as int` 抛 TypeError 逃逸（原 P2-4）                                            | `sync_models.dart:236-248, 577-595`                                         | header/items 强转无类型防护                  |
| L-5  | 每键 setState 重建整页（原 P1-17）                                                                     | `add_edit_note.dart:153-154,555-569`                                        | 性能，长笔记输入延迟                            |
| L-6  | i18n 15 语种缺 \~183 键；hi/bn/it 未注册（原 P1-20）                                                     | `assets/translations/*.json`、`preference_and_config.dart:753-769`           | `_locales` 补 `hi/bn/it` 或删文件          |
| L-7  | FLAG\_SECURE 仅 Android（原 P1-21）                                                               | `android/.../MainActivity.kt:50-72`                                         | 其它平台无防截屏                              |
| L-8  | `_sortAndStoreNotes()` 两处裸调无 catch（原 P1-22）〔✅已修复〕                                             | `home.dart:660/671`                                                         | 切排序异常落 Zone                           |
| L-9  | LocalFS manifest CAS 固定 tmp 无 lock（原 P2-5）                                                    | `local_fs_backend.dart:100-135`                                             | tmp 名加时间戳 + lock                      |
| L-10 | LocalFS `getManifest` 无大小上限（原 P2-6）〔✅已修复〕                                                     | `local_fs_backend.dart:88-97`                                               | 传 `kRemoteManifestMaxBytes`           |
| L-11 | LocalFS `deleteBlobSoft` 退化硬删（原 P2-7）〔✅已修复〕                                                   | `local_fs_backend.dart:226-252`                                             | 与 WebDAV H9 不对齐，丢 30 天恢复窗             |
| L-12 | 响应体超限/超时未 drain 归还连接（原 P2-8）                                                                  | `http_util.dart:127-162`                                                    | catch 路径 `drain().catchError`         |
| L-13 | manifest/journal 路径把整段响应体塞异常文案（原 P2-9 部分残留）                                                   | `webdav_backend.dart:319/390`、`safe_server_backend.dart:209/275/474`        | 截断 200 字符；blob 路径已修                   |
| L-14 | 无 `PRAGMA secure_delete`（原 P2-10）                                                             | `database_handler.dart`                                                     | 取证风险，硬删路径临时开启                         |
| L-15 | `storeNotesInTransaction` 去重 SELECT 在事务外（原 P2-11）                                             | `database_handler.dart:1020/1037`                                           | 导入并发极小 TOCTOU                         |
| L-16 | 同步性能：多次全量读库 + N+1（原 P2-15）                                                                    | `sync_engine.dart:1682/2822/1842` 等                                         | 万条笔记时耗时                               |
| L-17 | `mergeRemoteNoteMetas` 事务内 await 加密且无守卫（原 P2-16）                                              | `database_handler.dart:2717-2733`                                           | 持锁期间其它操作排队                            |
| L-18 | 无盐标题 SHA-256 前 8 位（原 P2-18）                                                                   | `database_handler.dart:199-202`                                             | 隐私口径，可删或加盐                            |
| L-19 | 非原子/公开 API 未加标注（原 P2-19）                                                                      | `database_handler.dart:1870/2172/2191/2262`                                 | 加 `@Deprecated`/`@visibleForTesting`  |
| L-20 | PIN 失败计数存明文 prefs（原 P2-20）                                                                    | `pin_auth.dart`、`preference_and_config.dart:451-455`                        | 已有上限 5，建议计数入 secure storage           |
| L-21 | 复制全文不清剪贴板（原 P2-21）〔搁置〕                                                                        | `add_edit_note.dart:720-736`                                                | 60s 后写空串                              |
| L-22 | 删除/恢复/清空回收站无异常兜底（原 P2-23）〔✅已修复〕                                                               | `deleted_notes.dart:170-244`                                                | 已加成功提示，异常仍裸奔                          |
| L-23 | `setPin` 抛异常后 `_busy` 卡死（原 P2-24）〔✅已修复〕                                                       | `pin_setting.dart:502-509`                                                  | try/catch 后复位 `_busy`                 |
| L-24 | 路由 `'/'` 未关闭 StreamController + 多 public State 类（原 P2-25 / L-16）                              | `route_generator.dart:66-70`、各 `State`                                      | 泄漏 + 封装                               |
| L-25 | build 内滚动动画副作用（原 P2-26）                                                                       | `change_passphrase.dart:77-79`、`set_passphrase.dart:91-93`                  | `addPostFrameCallback` + `hasClients` |
| L-26 | 主页整树 watch NotesColor（原 P2-27）                                                                | `home.dart:390`                                                             | 移 NoteCardWidget 内 watch              |
| L-27 | 无障碍近似为零（原 P2-28）                                                                              | 全 lib 仅 `search_widget.dart:144` 一处 `Semantics`                             | PIN 键/图标按钮补语义                         |
| L-28 | `analysis_options.yaml` 过松（原 P2-29）                                                           | `analysis_options.yaml:28-30`                                               | 启 `strict-casts`/`unawaited_futures`  |
| L-29 | `rename` 在 dependencies 且无任何 import（原 P2-31）                                                  | `pubspec.yaml:48`                                                           | 移 dev\_dependencies 或删除               |
| L-30 | LAN 日志服务器 token 在 query、`/api/download/db` 无 debug 门（原 P2-32）                                 | `lib/src/logger/log_webserver_io.dart`                                      | token 改 header、download/db 限 debug    |
| L-31 | 批量删除 `firstWhere` 无 orElse（原 P2-33 / L-11）〔✅已修复〕                                              | `home.dart:1355-1356`                                                       | 预建 Map                                |
| L-32 | `close()` 不清 `_dataKey`（原 P2-35）                                                              | `database_handler.dart:2919-2926`                                           | 语义一致化                                 |
| L-33 | `getGcOrphanCandidates` 损坏静默空（原 L-14）                                                         | `database_handler.dart:2386-2395`                                           | 仅 GC 效率，可接受，提升日志级别                    |
| L-34 | `AppLogBuffer` `removeAt(0)` O(n)（原 L-4）                                                      | `app_logger.dart:190-196`                                                   | 改 `Queue`                             |
| L-35 | log webserver：token 描述失配（原 L-5）、非常数时间比较（L-6）、CORS `*`（L-7）                                    | `log_webserver_io.dart`                                                     | 128-bit 已实现，改文案/常数比较/去 `*`            |
| L-36 | `dumpAll()` 无敏感键过滤（原 L-8）                                                                     | `preference_and_config.dart:666-674`                                        | 加黑名单                                  |
| L-37 | `prefs_store_override` 读写竞态（原 L-9）                                                            | `lib/data/prefs_store_override.dart`                                        | 仅测试用，`_ensureLoad`                    |
| L-38 | `onAppUpdate` 未 await 版本号（原 L-10）                                                             | `main.dart:249/525`                                                         | `await`                               |
| L-39 | 魔法数字 5 不一致（原 L-1）                                                                             | `login.dart:887`                                                            | 抽常量                                   |
| L-40 | 死代码：`note_widget.dart` 死参数+注释、`styles.dart` `Style` 类、`parse_import.dart` 缺校验（原 L-2/L-3/L-13） | `note_widget.dart:28,146-173`、`styles.dart:20-24`、`parse_import.dart:31-39` | 清理                                    |
| L-41 | journal 本地读无大小检查（原 L-15）                                                                      | `journal.dart:1008/1018`                                                    | 低风险加固                                 |

***

## 五、✅ 已修复（记录，避免重复排查）

| 原编号            | 问题                                                           | 位置/验证                                                                                                                                         |
| -------------- | ------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------- |
| P1-3 / A1      | DB Inspector 隐藏 `sync_meta.value`                            | `database_handler.dart:60-65` 已含 `value`                                                                                                      |
| P0-3 / A2（8 处） | 迁移守卫 TOCTOU——8 处点名写路径已补 `_checkNotMigrating`                 | `upsertNoteMeta`/`softDelete`/`hardDelete`/`hardDeleteByUuid`/`restoreNote`/`markSynced`/`markAllSynced`/`markSyncedForUuids`（另有 5 处残留，见 H-6） |
| P0-7 / A3      | 编辑页退出保存区分 `skipped`/`failed`                                 | `editor_state.dart:88` 返回 `({saved, skipped})`；`add_edit_note.dart` 跳过时 `waitForSave()` 重试                                                    |
| P1-11 / A4     | 响应体读取超时 + sync 总超时                                           | `http_util.dart:140-152`；`sync_service.dart:558-602`                                                                                          |
| P1-14 / A5     | SafeServer backupCorruptManifest 只认 204/404、不 DELET          | `safe_server_backend.dart:425-442`（残留 ciphertext 死参见 M-11）                                                                                    |
| P1-12 / A6     | URL userinfo 剥离 + 日志脱敏 + `_mkcol` 截断                         | `sync_config.dart:178/251/369-398`、`webdav_backend.dart:1165-1183`                                                                            |
| P2-30 / A7     | Taskfile + CI 改用 `dart run scripts/generate_build_info.dart` | `Taskfile.yml:26-31`、`flutter-ci.yml:31-32`                                                                                                   |
| P1-7 / B6      | SafeServer/引擎侧 hash 白名单                                      | `safe_server_backend.dart:485-486`、`sync_engine.dart:2923-2925`、`webdav_backend.dart:519`                                                     |
| P1-9 / B1      | 同步期间编辑产生"自冲突"副本                                              | 三方合并（base 追踪 + fast-forward）已抵消，不复现                                                                                                           |
| P1-18          | 改密码前置同步异常静默                                                  | `sync_service.dart` 已把 `BackendUnavailableException`/`Exception`/`TimeoutException` 全转 `SyncResult.failure`，不向调用方抛，无风险                        |

另：`code-review-20260831` §一 的"已修复确认 18 项"（Argon2id utf8 编码、isTagError、缓存规避、`_parseUuidList` 抛异常、长度越界、常数时间指纹、i18n localizedReason、argsType 一致性、标题 trim、可空回调、journal tmp 时间戳、远端大小限制、冲突日志 hash、SafeServer 对象名白名单、url\_launcher 死代码、monospace、日志服务器 token 认证、冗余日志）均已核实修复，不再重复。

***

## 六、⛔ 误报 / 设计取舍 / 已搁置（不按"必须修"处理）

| 判定   | 条目                           | 依据                                                                                                 |
| ---- | ---------------------------- | -------------------------------------------------------------------------------------------------- |
| 误报   | P0-1 墓碑 GC 漏 purgedUuids     | `hardDeleteByUuid`（`database_handler.dart:1661-1686`）同事务已 `_addPurgedUuidInTxn`，注释与代码一致            |
| 误报   | P1-5 降级再升级启动即崩               | 主流 sqflite 缺 `onDowngrade` 默认抛异常而非静默降版，机理存疑且 v7→v5→v7 路径几乎不可达（onDowngrade/WAL 本身仍值得做，见 M-3）        |
| 设计取舍 | P0-2 读路径物理删坏行                | M1 既有决策（删坏行、不进 purged、靠云端/备份自愈）                                                                    |
| 设计取舍 | P0-6 LWW 依赖本地时钟              | 无 HLC/删除不留副本，属架构限制；可加时钟偏差日志告警（L-18 相关）                                                             |
| 已搁置  | P0-4 迁移吞 meta/version 解密异常   | 两条迁移路径先跑 `_readAllNotesStrict`（`database_handler.dart:1276`），oldKey 错即先行抛异常中止，吞异常分支不可达；"中止"反而阻碍改密码 |
| 已搁置  | P1-8 下载路径 `synced_hash` NULL | B2 核实可自愈：内容==merged→converged→`markSyncedForUuids` 补 base，hash 相等不产副本                              |
| 已搁置  | P1-10 从 bak 恢复回滚代际           | 本端硬删受 purgedSet 保护（`_mergeAndTransfer` skip + merged 剔除），不复活                                       |

***

## 七、推进状态与顺序

**已完成：**

1. **第一批（小改动、高收益）**：H-1（webdav 白名单）、H-2（pending uuid 抛异常）、H-6（补 5 处迁移守卫）、M-5（Ctrl+N）、M-6（滚动 try/catch）——2026-08-31 修复并提交（`92eccd1` / `dc63919`）。
2. **第二批（中）**：M-3（`onConfigure` WAL/busy\_timeout + `onDowngrade` + 幂等 ALTER）——2026-08-31 修复并提交（`f68bb52`）。
3. **第三批（防御/兜底）**：L-1、L-3、L-8、L-10、L-11、L-22、L-23、L-31（=M-2）——2026-08-31 修复并提交（`7d257d8`）。
4. **第四批（数据安全）**：H-4（`unlockFromRemoteManifest` 切 key 前 `verifyDataKey` 校验 + `LocalVaultKeyMismatchException`）——2026-08-31 修复（待提交）。

**已决定搁置（触及同步核心迁移/损坏恢复/取消路径，触发前提窄，与先前 B5/C1/C2 有意搁置一致）：**

* H-3（scenario-d 确认+vaultId）、H-5（损坏重建保留）、M-4（取消机制）、L-21（剪贴板明文清理）。

**其余全部标记忽略（2026-08-31 收口）：**

* M-1、M-2、M-7、M-8、M-9、M-10、M-11、M-12；L-2、L-4、L-5、L-6、L-7、L-9、L-12–L-20、L-24–L-30、L-32–L-41。

> 对搁置/忽略项如需推进，应单独立项并先补回归测试；`packages/core` 禁止引入 Flutter 依赖。

