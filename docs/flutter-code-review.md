# SafeNotes 全面代码审查报告（2026-08-10）

审查范围：`lib/`（约 1.4 万行）+ `packages/core/`（约 1.1 万行）。核心发现均已逐条核实源码。

## 总体评价

- **packages/core 质量很高**：MK/dataKey 双层密钥、AES-256-GCM + AAD 绑定、原子化迁移事务、两阶段孤儿 GC、manifest pubHash 损坏/密钥不匹配正交分流，设计成熟、留痕优秀。
- **问题集中在 lib/ 应用层**：数据安全链（备份明文、假备份）、并发原语（手写布尔锁）、build 副作用、i18n 双轨是四大系统性短板。

---

## 【高】安全与数据正确性

1. **备份是明文，违背加密承诺** — `lib/models/file_handler.dart:39-49`：`encryptedOutputBackupContent()` 名为加密实为明文 JSON（`recordHandlerHash` 写死 `"plaintext-v1"`，注释自认 TODO），且可写入公共 Download 目录。→ 用 dataKey 或独立备份口令派生密钥加密备份；`total` 计数用 `'{'.allMatches` 统计也是错的，应解析后取数组长度。
2. **桌面端"假备份"** — `lib/utils/scheduled_task.dart:58-67`：非移动平台 `unitBackupAttempt()` 直接 `return true`，改密码前的 `forceBackup()` 在桌面端报告成功但实际未写文件。→ 桌面端实现真实备份或返回 false 让上层阻断。 **[已修复 20260810]**：桌面端不再假报成功，返回 false + 写明 `lastBackupError`。
3. **登录锁定倒计时可被无限重置** — `lib/views/authentication/login.dart:232-273`：`_buildTimeOut()` 在 build 里 `_startTimer()` + 清空输入框，锁定期内任何 setState 都把倒计时重置回满值。→ Timer 只在进入锁定那一刻启动一次，build 只读 stream。 **[已修复 20260810]**：`_buildTimeOut` 只读 stream，`_startLockoutTimer` 仅在锁定瞬间启动。
4. **锁定逻辑 off-by-one + 双份实现** — `login.dart:296-311`：validator 在剩最后 1 次尝试时就拦截，**密码正确也进不了 `_login`**；validator 内调 setState 属反模式。→ validator 只做非空校验，锁定统一收口到 `_onLoginFailure`。 **[已修复 20260810]**。
5. **drawer 三个入口全指向 GitHub** — `lib/widgets/drawer.dart:148-180`（已核实）：Rate Us / FAQs / Help 都打开 `SafeNotesConfig.githubUrl`，且 `catch (_) {}` 空捕获；`home_navigation_rail.dart:191-205` 同样问题。→ 分别接 playStoreUrl / faqsUrl / githubUrl。 **[已修复 20260810]**：两处均已改为分别接 playStoreUrl / faqsUrl / githubUrl。
6. **sync() 互斥锁 check-then-act 竞态** — `lib/sync/sync_service.dart:427-465`（已核实）：`await backend.init()` 在 `_syncInProgress` 检查之前，两个并发 sync() 可同时通过检查。→ 入口第一行抢锁，或改用 `Mutex`（`switchBackend` 同理）。 **[已修复 20260810]**：sync() 与 repairRemote() 互斥锁移入口第一行。
7. **远端验证路径资源泄漏 + 异常误分类** — `login.dart:532-595`：`backend.close()` 不在 finally；`on Exception` 一律算网络不可达（不扣次数），而远端无 manifest 时直接判密码错误（扣次数），从未同步过的用户会被误锁。 **[已修复 20260810]**：close 移入 finally；远端无 manifest 改判 unreachable 不扣次数。
8. **明文口令/凭据长期驻留内存** — `preference_and_config.dart:386-406`、`sync_config.dart:186-211`：Dart String 无法清零，secure storage 凭据又全程镜像到静态缓存。→ 口令持 `Uint8List` 用毕覆零；凭据用时现读。 **[未处理]**（需大规模改造，暂搁置）。

## 【中】可靠性与逻辑

9. **信封过短抛未包装异常** — `packages/core/lib/src/crypto/crypto.dart:325-330`：长度校验在 try 块外，`sublist` 抛 `RangeError` 而非 `SyncDecryptionException`。→ 解密前先校验 `envelope.length >= 28`。 **[已修复 20260810]**：`_aesGcmDecrypt` 在任何 sublist/SecretBox 构造前先校验长度。
10. **导入无事务无上限** — `file_handler.dart:137-169`：`readAsStringSync` 主线程读任意大文件、逐条 await 插入无事务，中途崩留半库数据。→ 异步读 + 大小上限 + 事务包裹。 **[已修复 20260810]**：改为 `readAsString` 异步读 + 256MB 上限 + 新增 `storeNotesInTransaction` 单事务批量写入。
11. **重试 50 次无退避；logout 被备份阻塞** — `scheduled_task.dart:42-50`、`models/session.dart:39`。→ 指数退避 + 总超时。 **[已修复 20260810]**：backup/forceBackup 加总超时预算（30s）+ 指数退避（200ms 起步、5s 封顶）。
12. **dispose 后仍向已关闭 controller 发事件** — `sync_service.dart:896-899`；autoSync `.then` 链未兜 `Error`（只 catch `Exception`），`_syncInProgress` 可能卡死。→ 加 `isClosed` 判断、改 `on Object`。 **[已修复 20260810]**：`_updateState` 加 `_stateController.isClosed` 守卫；autoSync `.then` 补 `onError:`。
13. **编辑器全局静态态 + 双写竞态** — `models/editor_state.dart`：静态字段多入口共享，`handleUngracefulNoteExit` 与正常保存无互斥；变更检测 `add_edit_note.dart:155-157` 把"清空标题"判为未变更，退出丢改动。 **[已修复 20260810]**：`addOrUpdateNote` 加 `_isSaving` 防重入；变更检测改为直接对 `widget.note` 逐字段比较。
14. **set_passphrase 时序错误** — `set_passphrase.dart:321-325`：先提示成功再 `_initKeyring`，keyring 失败时已误报成功。 **[已修复 20260810]**：成功提示与 startListening 移入 `_initKeyring` 成功与 `Session.onPasswordSet` 之后。
15. **build 副作用多处** — `change_passphrase.dart:83-91`、`main.dart:254-268`（每次 build 重建会话订阅、重置超时基准）；`main.dart:282` `navigatorKey.currentContext!` 强解包可崩。 **[已修复 20260810]**：change_passphrase 仅在键盘从无到有时滚动；main.dart 订阅仅在超时配置变化时重建 + currentContext 判空。
16. **核心包小问题**：
    - `sync_engine.dart` `sync()` 文档称网络错误返回 failure 实际直接抛出（上层有兜底，改文档即可）； **[已修复 20260810]**：文档修正，注明 BackendUnavailableException 直接抛出。
    - `_openBlobEnvelope` 的 `uuid` 死参数； **[已修复 20260810]**：死参数已删除。
    - `_gcOrphanBlobs` 用 `on Exception` 漏 `Error`，与全文 `on Object` 不一致； **[已修复 20260810]**：整体 GC 外层改 `on Object`。
    - `keyring.dart:47` `_sameKey` 非常数时间，与 `sync_engine.dart:2834` `_bytesEqual` 重复且语义不一，应统一； **[已修复 20260810]**：统一收敛为 `SyncCrypto.bytesEqual`（常数时间），两处调用点一并替换。
    - `database_handler.dart:1304` `int.parse` 在 meta 损坏时抛异常； **[已修复 20260810]**：改 `int.tryParse` + 日志降级为 0。
    - `_parseUuidList:830` 解析失败静默返回空列表，purged 列表损坏会导致硬删除笔记从远端复活。 **[已修复 20260810]**：解析失败改抛 `FormatException` 显式中止，不再静默返回空。
17. **诊断端点泄露基础设施信息** — `sync_service.dart:789-842`：snapshot 含 webdavUrl/用户名，经 LogWebServer 局域网可达。→ URL 脱敏。 **[已修复 20260810]**：URL 经 `_redactUrl`（掩 userinfo/query），用户名经 `_maskUsername`。
18. **配置双默认值/双数据源** — `preference_and_config.dart:253-266` inactivityTimeout 越界回退 300s、缺失默认 180s；`settings.dart:345-350` 魔法数组与 inactivity_setting.dart 双份硬编码；`settings.dart:226` onToggle 忽略入参违反契约。 **[已修复 20260810]**：统一缺省索引 3（180s）、抽取 `kInactivityTimeoutChoicesSeconds` 唯一数据源、settings.getItem onToggle 用入参、inactivity_setting 从常量派生列表。

## 【低】质量与可维护性

- **i18n 双轨**：home/change_passphrase/deleted_notes/sync_settings/sync_diagnostics 大量硬编码中文不走 `.tr()`。
- `safenote.dart:6` 头注释"本地存储为明文"已过时（实为字段级加密），误导；`SafeNote.toString()` 含 title 明文，是隐私红线踩雷点，建议移除。
- `passphrase_util.dart:35` 每次评估新建 Zxcvbnm 加载整本字典，键入即卡 → 缓存单例。
- `note_widget.dart` 死参数 + 大段注释死代码；`route_generator.dart:86-115` 报错文案参数类型写错，误导排障；`note_card.dart` 固定显示 createdTime 与排序设置不一致、`getMaxLine` default 分支不可达。
- `file_handler.dart:419-428` ImportPassPhraseHandler 已无用途的死代码；`device_id.dart:125` 未知平台用时间戳当 deviceId 每次启动都变。

---

## 附：核心同步层专项审查（packages/core，2026-08-10 补充）

精读范围：crypto / sync_engine / keyring / database_handler / journal / sync_models（v5 容器）/ sync_error / sync_backend 契约 / 三个后端实现。

### 【高】

- **B-H1 HTTP 重定向导致写操作静默失效 + 凭据跨站泄露**（已核实）— `webdav_backend.dart:296`（putManifest）、`:352`（putBlob）、`:475/489`（DELETE）、`safe_server_backend.dart:191/262/692`。package:http 默认 followRedirects，且 301/302/303 会把非 GET 降级为 GET：WebDAV 服务器做 301（http→https、补尾斜杠，坚果云/Nextcloud 常见）→ PUT manifest 变 GET → 返回 200 → putManifest 误判成功 → **manifest 实际未写入、ETag 错乱，数据静默丢失**；同时 Authorization 头会被带到重定向目标 host，Basic/Bearer 凭据可泄露给第三方域名。→ 所有请求 `followRedirects=false`，显式处理 3xx：仅 307/308 且同源时手工重发。
- **B-H2 WebDAV purgeOrphans 路径校验不一致**（已核实，可利用性受限）— `webdav_backend.dart:567-577`：`name` 来自服务端 PROPFIND href，仅校验「首个 `.` 前恰好 64 字符」，未校验 hex、未排除 `/`/`..`；而同文件 `listOrphanBlobs:519` 用严格 `^[a-f0-9]{64}\.` 正则——两处不一致即为隐患。注：实际利用受 `int.tryParse(时间戳段)` 限制（含 `/` 的 payload 无法通过解析），现实风险低，但应统一为 `RegExp(r'^[a-f0-9]{64}\.\d+$')` 全名匹配做纵深防御；`safe_server_backend.dart:485` 同型拼接一并加严。

### 【中】

- **B-M1 wrapDecryptionError 是死分类逻辑** — `sync_error.dart:337-353`：靠 `toString().contains('InvalidTag')` 识别 pointycastle 异常，但项目已迁移到 cryptography 包（抛 `SecretBoxAuthenticationError`），第一分支永远走不到，注释与实现脱节。
- **B-M2 ManifestCrypto.deserialize 异常契约泄漏** — `sync_models.dart:967-982`：只捕 `SyncDecryptionException`，items 段过短时 `SyncCrypto.open` 抛 `RangeError`（根因是 crypto.dart:325 长度校验在 try 块外）、jsonDecode/cast 错误均原样逃逸，与文档承诺的三分支分流不符。修好 crypto.dart 长度校验后大半消解。
- **B-M3 401 与 5xx 混为一谈** — webdav/safe_server 对 401（凭据失效，需用户介入）与网络抖动同抛 `BackendUnavailableException`，引擎无法区分「提示用户重新配置」与「等下次同步」。→ 新增 AuthenticationException 或给异常加 retryable 标志。
- **B-M4 ETag 退化路径可致永久 412** — `webdav_backend.dart:271-273 vs 317-318`：getManifest 用服务端 ETag，putManifest 无响应 ETag 时回退内容 hash；若代理剥头导致两种语义错位，If-Match 永远不匹配 → ConflictException 无限重试。且 `_etagSupported`（:93）探测后从未被读取改变行为，探测形同虚设。
- **B-M5 非 manifest 响应无大小上限** — webdav `getBlob:327`、listBlobs/listOrphanBlobs/listManifestBackups、safe_server listBlobs 等均全量读入内存，无 `checkRemoteReadSize`（F-M04 只护了 manifest/journal）。恶意服务端可用超大响应打爆内存。
- **B-M6 SafeServer 隔离区方法异常出口不统一** — `safe_server_backend.dart:444/472`：`_postResource` 裸调用未包装，TimeoutException/SocketException 原始上抛，且缺 `_ensureInitialized()`（backupManifest:517 同漏）→ 引擎的重试/降级策略失效。
- **B-M7 WebDAV backupCorruptManifest 直接 DELETE** — `webdav_backend.dart:853-869`：入参 ciphertext 被丢弃、直接删远端文件，损坏证据灭失（LocalFS 落 `.corrupt-{ts}`、SafeServer 用 move，语义不一致）。→ 先 COPY 再 DELETE。
- **B-M8 checkRemoteReadSize 错误分类不当** — `sync_backend.dart:270-277`：响应超限是确定性错误却抛可重试语义的 BackendUnavailableException，触发 `_withBlobRetry` 无意义重试 3 次。
- **B-M9 manifest header 无密码学绑定** — v5 容器 pubHash 是无密钥 SHA-256，明文 header 与加密 items 间无认证关联。恶意服务端可篡改 header（DoS/回滚级，无法解密数据）。属设计取舍，建议在设计文档显式声明威胁模型。
- **B-M10 环形备份 index+bak 两步写非原子** — webdav:737-757 / safe_server:545-549：先写 index 再写 bak，中途失败 index 指向旧槽位。建议先写 bak 再写 index。

### 【低】

- `writeRingBackup`（sync_backend.dart:308）首轮从 bak-1 开始写，bak-0 首轮空缺。
- `local_fs_backend.dart:119/346` putManifest/putJournalObject 用固定 `.tmp` 名，并发写碰撞（putBlob:161 已用微秒时间戳），与接口「支持并发调用」契约不符。
- `local_fs_backend.dart:77-86` getManifest 无 64MB 上限检查（journal 有），防护不一致。
- `sync_models.dart:1036` `headerLen < 0` 不可达条件（uint32 解码非负）。
- 异常消息内嵌 `${res.body}`/`$url`（webdav:259/966）：baseUrl 内嵌 user:pass@ 或服务端回显时敏感信息进日志。
- `webdav deleteBlobSoft:475-477`：COPY 成功后 DELETE 不校验状态码，删除失败被静默吞掉。
- `safe_server_backend.dart:116`：health 判定 `res.body != 'ok'` 过严，尾随空白误判不可用。
- Journal 每次 flush 全量重写 log 文件（journal.dart:646-657），有滚动阈值兜底，规模可控但频繁同步下是 O(n) 重复写盘。

### 核心层结论

加密协议（双层密钥、GCM+AAD、pubHash 损坏分流）、同步引擎（三方合并、两阶段 GC、原子化迁移）、journal（串行写链、永不抛异常契约）设计与实现质量高。**主要缺陷集中在后端传输层**：H1（重定向）是唯一可导致静默数据丢失的问题，必须优先修；其余多为错误分类不统一与防护覆盖不全。

---

## 架构层面建议（优先级排序）

1. **先补备份加密 + 桌面端备份实现**（高 1/2）——用户数据安全的最大缺口。 **[高1 备份加密未处理**（用户指定暂缓）**；高2 桌面端假备份已修复](20260810)**。
2. **并发原语统一改造**：手写布尔锁 → `package:synchronized` 的 `Mutex`，覆盖 sync()/switchBackend/编辑器保存。 **[sync()/switchBackend/repairRemote 竞态已修复**(入口首行抢锁](20260810)**；编辑器保存已加防重入守卫**。
3. **登录流程重构**：锁定状态机线性化，消除 validator 副作用与 build 副作用。 **[已修复 20260810]**：validator 只做非空校验、锁定收口 `_onLoginFailure`、`_buildTimeOut` 只读 stream。
4. **core 包保持现状即可**，只需修中 9/16 的边缘问题；注释驱动修复文化值得保留。 **[9/16 已修复 20260810]**。
5. **i18n 收敛**：建 lint 规则或 CI grep 禁硬编码中文进 UI。（未处理）

## 修复进度总览（2026-08-10）

- **已修复**：高 2/3/4/5/6/7（仅高 1 明文备份与高 8 内存凭据搁置）；中 9–18 全部；架构建议 2/3/4 相关项。
- **搁置**：高 1（明文备份，用户指定暂不处理）、高 8（口令驻留内存，需大规模改造）、B-H1（HTTP 重定向数据丢失，需重做两个后端的 HTTP 客户端层）。
- **验证**：`dart analyze packages/core` / `flutter analyze lib` 均 0 issue；核心包 242 项测试、App 23 项（widget/change_password/generate_real_db）全部通过。
