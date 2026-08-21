# SafeNotes 全面代码审查报告（2026-08-21）

审查范围：`lib/`（约 2.25 万行，91 文件）+ `packages/core/`（约 1.39 万行，39 文件）+ 测试（约 2.86 万行，77 文件）。所有发现均经子代理逐文件精读 + 交叉验证。

---

## 总体评价

- **packages/core 核心层质量持续提升**：B-H1（HTTP 重定向数据丢失）——旧报告最重要的搁置项——已通过 `http_util.dart` 统一重定向策略彻底修复。加密协议（双层密钥、GCM+AAD、常数时间比较）、同步引擎（三方合并、两阶段 GC、原子化迁移）设计成熟。
- **lib/ 应用层显著改善**：旧报告高 2/3/4/5/6/7 全部修复，中 9–18 全部修复。i18n 双轨问题已全面收敛，所有 UI 文案均走 `.tr()`。备份已从明文改为真加密。
- **本次新发现 6 项高优先级问题**：Argon2id 密码编码 bug（非 ASCII 密码熵损失）、原子迁移遗漏 payload（标签永久丢失）、destroyImportCredentials 字符串 "null" bug、iOS 备份无异常捕获、日志服务器无认证暴露数据库、登录密码无暴力破解防护。
- **搁置项**：高 8（明文口令驻留内存）、B-M3（401 与 5xx 混为一谈）仍维持原状。

---

## 一、旧报告问题追踪

### 仍未修复

| 编号 | 旧问题 | 当前状态 |
|------|--------|----------|
| 高8 | 明文口令驻留内存 | **搁置** — `PhraseHandler._passphrase` 仍为静态 String，架构性改造暂搁置 |
| B-M3 | 401 与 5xx 混为一谈 | **仍存在** — 401 仍抛 `BackendUnavailableException`，未新增 `AuthenticationException` |
| B-M5 | 非 manifest 响应无大小上限 | **部分改善** — manifest/journal 已加 `checkRemoteReadSize`；`getBlob` 仍未加 |
| B-H2 | WebDAV purgeOrphans 路径校验不一致 | **仍存在** — `purgeOrphans` 用 `length == 64` 宽松校验，`listOrphanBlobs` 用 `^[a-f0-9]{64}\.` 严格正则 |
| 低 | safenote.dart 头注释"本地存储为明文" | **仍存在** — `safenote.dart:15` 注释过时 |
| 低 | SafeNote.toString() 含 title 明文 | **仍存在** — `safenote.dart:297-300` |
| 低 | passphrase_util Zxcvbnm 每次新建 | **仍存在** — `passphrase_util.dart:33` |
| 低 | device_id 未知平台用时间戳 | **仍存在** — `device_id.dart:138` |
| 低 | note_widget.dart 死参数+死代码 | **仍存在** — `sessionStateStream` 死参数、`computeMaxLine` 注释死代码 |
| 低 | route_generator.dart argsType 文案错误 | **仍存在** — 4 处错误 |

---

## 二、新发现 — 高优先级

### H-01 Argon2id 密钥派生使用 UTF-16 codeUnits 导致非 ASCII 密码熵严重损失

`packages/core/lib/src/crypto/crypto.dart:212`

```dart
final key = await algo.deriveKey(
  secretKey: SecretKey(password.codeUnits),  // ← UTF-16 codeUnits
  nonce: salt,
);
```

`String.codeUnits` 返回 UTF-16 编码单元（0–65535），传入 `SecretKey` 后 `extractBytes()` 通过 `Uint8List.fromList()` 将每个值截断为低 8 位。对于非 ASCII 密码（中文场景常见），每个中文字符从 3 字节（24 bit）熵降为 1 字节（8 bit），且不同字符可能碰撞到同一截断值。

以密码 `'密码'` 为例：`codeUnits` = `[23494, 30721]` → 截断为 `[0x26, 0x61]`（仅 2 字节），而正确的 UTF-8 编码应为 6 字节。

**影响**：非 ASCII 密码暴力破解难度大幅降低；不同密码可能碰撞到相同截断序列；不符合 Argon2 规范（RFC 9106）；跨平台互操作风险。

→ **改为 `SecretKey(utf8.encode(password))`**，与 PBKDF2 路径的编码方式统一。

### H-02 reEncryptAllNotesAtomically 未迁移 note_meta.payload

`packages/core/lib/src/db/database_handler.dart:1453-1530`

原子化迁移方法 `reEncryptAllNotesAtomically` 在事务内重加密了 notes 表的 title/description，但**完全遗漏了 note_meta.payload 的重加密**。对比非原子版本 `reEncryptAllNotes`（行 1369-1413）完整处理了 payload 迁移。

迁移完成后 `_dataKey` 更新为 `newKey`（行 1518），但 note_meta.payload 仍为 oldKey 加密的密文。后续读取时 `_decodeMetaRow` 用 newKey 解密失败，降级为空 payload，**用户所有标签永久丢失**。

→ 在事务内补入 `_readMetaPayloadsPlain` + `_encryptField(newKey)` + `txn.update(note_meta, ...)` 三步，与非原子版本保持一致。

### H-03 destroyImportCredentials() 将密码设为字符串 "null"

`lib/models/file_handler.dart:181-184`

```dart
void destroyImportCredentials() {
  ImportPassPhraseHandler.setImportPassPhrase("null");
  ImportPassPhraseHandler.setImportPassPhraseHash(null);
}
```

`setImportPassPhrase` 签名为 `String imPhrase`（非 `String?`），开发者用字符串 `"null"` 作为变通。后续代码若以 `importPassPhrase != null` 或 `isNotEmpty` 判断是否有导入密码，会误判为存在。`importPassPhraseHash` 被正确设为 `null`，印证 `"null"` 是疏漏。

→ 将 `setImportPassPhrase` 签名改为 `String?` 并传 `null`；或传空字符串 `''`。

### H-04 iOS 备份无 try-catch，异常会中断登出流程

`lib/utils/scheduled_task.dart:211-234`

`iosBackup()` 缺少异常捕获，若 `writeAsStringSync` 或 `encryptedOutputBackupContent` 抛异常，异常穿透 `unitBackupAttempt()` → `backup()` → `Session.logout()`，导致用户无法登出。对比 `androidBackup` 和 `desktopBackup` 均有完整 try-catch。此外空目录时仍返回 `true`，使 `backup()` 误认为成功。

→ 包裹 try-catch 并在异常时返回 `false`；空目录时返回 `false`。

### H-05 日志服务器无认证暴露数据库与偏好

`lib/src/logger/log_webserver.dart:148,529-576`

服务器绑定 `0.0.0.0`（局域网可访问），以下端点**无任何认证**即可访问：

- `/api/download/db`：下载完整加密数据库文件（可离线暴力破解）
- `/api/db?table=X`：查看任意表结构和行数据
- `/api/download/sp`：下载全部 SharedPreferences
- `/api/prefs`：JSON 格式偏好数据
- `/diagnostics`：完整同步诊断快照

文件头注释声称"不含敏感凭据"，但数据库下载端点直接暴露了加密数据库文件。

→ Release 模式下默认禁用所有 `/api/download/*` 和 `/api/db?table=` 端点；或加 token 认证（启动时生成一次性 token）。

### H-06 wrapDecryptionError 引用错误异常类型（B-M1 升级）

`packages/core/lib/src/sync/sync_error.dart:340-347` + `crypto.dart:485,549-556`

旧报告标记为中，本次验证后**上调为高**。项目使用 `package:cryptography` 而非 pointycastle，GCM 认证失败时抛 `SecretBoxAuthenticationError`（继承自 `Error`），而非 `wrapDecryptionError` 中检查的 `InvalidTag`（pointycastle 的异常类）。

```dart
// 检查的是 pointycastle 的类名
if (typeName == 'InvalidTag' || error.toString().contains('InvalidTag')) {
```

两个检查在**所有构建模式**下均不匹配，`if` 分支是死代码。所有 GCM 认证失败都走 fallback 分支，丢失了"GCM 认证标签验证失败"这一关键分类信息。文档注释声称的"pointycastle 的 InvalidTag"与实际不符。

→ 在 `crypto.dart` catch 处直接判断 `e is SecretBoxAuthenticationError` 并传入 `bool isTagError` 参数，彻底消除字符串匹配。

### H-07 登录密码无暴力破解防护

`lib/views/authentication/login.dart`

旧登录锁定机制（高3/高4）被整体移除后，passphrase 登录路径不再有任何尝试次数限制或冷却机制。`_login()` 失败仅 `_showError`，攻击者可脚本化连续尝试（PBKDF2/Argon2id 每次约 1-2 秒，约 1800 次/小时）。对比 PIN 路径仍有 `kPinMaxFailedAttempts = 5` 保护。

→ 引入轻量级速率限制：连续失败 N 次后加指数退避冷却（3s → 10s → 30s），无需恢复旧的计时器倒计时方案。

---

## 三、新发现 — 中优先级

### M-01 _decryptField 异常类型错误

`packages/core/lib/src/db/database_handler.dart:468-480`

dataKey 已设置但不匹配时，`_aesGcmDecrypt` 抛出的 `SyncDecryptionException` 被捕获后包装为 `DataKeyNotSetException`。语义错误：`DataKeyNotSetException` 含义是"dataKey 未注入"，应触发登录流程；实际含义是"key 不匹配或数据损坏"，应提示数据修复。UI 层会误导向用户显示"请重新登录"。

→ 新增 `DecryptionFailedException` 或直接 rethrow `SyncDecryptionException`。

### M-02 storeNotesInTransaction 缓存条目缺少 id

`packages/core/lib/src/db/database_handler.dart:799-801`

事务内插入返回的自增 id 未回填到缓存条目。`entry.note` 的 `id == null`，后续 `readNote(id)` / `softDelete(id)` 会因 `id == null` 失败。对比单条插入 `storeNote`（行 743）正确使用 `copyWith(id: id)`。

→ 在事务内捕获 insert 返回的 id 并 `copyWith(id: id)`，或事务后 `_invalidateCache()`。

### M-03 readAllNotesIncludingDeleted 缓存重建竞态

`packages/core/lib/src/db/database_handler.dart:982-992`

在 `await db.query` 和 `await Future.wait` 的 yield 窗口内，若 `storeNote`/`updateNote` 等写操作的事件被调度执行，它们调用 `_upsertCacheEntry` 时看到 `_notesCache == null` 直接 return。随后 `_notesCache = notes` 覆盖写入不含这些新变更的快照。Dart 单线程事件循环下这是真实竞态。

→ 引入 `_cacheRebuilding` 标志或 `Completer` 互斥。

### M-04 getPendingReuploadUuids 解析失败静默返回空集合

`packages/core/lib/src/db/database_handler.dart:1645-1653`

JSON 损坏时静默返回空集合，同步引擎会认为"无待重传 blob"，跳过用新密钥覆盖服务器旧 blob 的步骤，导致旧密钥 blob 永久残留。与已修复的 `_parseUuidList`（现在抛异常）形成不一致策略。`getGcOrphanCandidates`（行 1705-1710）同类问题。

→ 改为抛异常或至少 `Log.db.w` 警告。

### M-05 SyncConfig._preloadCredentials() 空 catch 吞异常无日志

`lib/sync/sync_config.dart:206-218`

`flutter_secure_storage` 读取失败时凭据被静默设为空串，用户表现为"明明配好了同步却连不上"，日志中无任何线索。与全项目统一使用 `Log.sync.w` 的风格不一致。

→ 在 catch 中添加 `Log.sync.w('预加载凭据失败', error: e)`。

### M-06 getFileAsString() 过宽 catch 吞掉编程错误

`lib/models/file_handler.dart:396-398`

裸 `catch (e)` 捕获所有异常（含 `StateError`、`TypeError` 等编程错误），统一返回 `"unrecognized"`，开发者无法从日志定位根因。

→ 分两层：`on FileSystemException` 返回 `"unrecognized"`；`on Object catch (e, st)` 记录日志后返回。

### M-07 onAppUpdate() 异步函数未 await

`lib/main.dart:260,431-451`

`onAppUpdate()` 以 fire-and-forget 方式调用。若应用在 `setAppVersionCodeToCurrent()` 完成前被系统杀死，下次启动会重复执行升级逻辑（冗余备份）。

→ 先同步写入版本号，再做异步备份。

### M-08 logout 与在途保存的竞态

`lib/main.dart:414-427` + `session.dart:51-71` + `editor_state.dart:63-99`

登出流程中 `Session.logout()` 执行 `ScheduledTask.backup()`（await，让出事件循环）时，原始 `addOrUpdateNote()` 可能恢复执行。若 `backup()` 先完成，`clearDataKey()` 被调用，`storeNote()` 在无 dataKey 状态下加密失败。概率低但理论存在数据丢失风险。

→ 在 `clearDataKey()` 之前等待"编辑器空闲"信号。

### M-09 journal.dart _writeLogFile 使用固定 .tmp 文件名

`packages/core/lib/src/sync/journal.dart:666`

与 `local_fs_backend.dart` 的 putManifest/putJournalObject 同类问题。跨进程场景（用户同时打开两个应用实例指向同一目录）会产生临时文件竞争。

→ 统一使用微秒时间戳后缀：`'$_logPath.tmp-${DateTime.now().microsecondsSinceEpoch}'`。

### M-10 生物识别 localizedReason 未走 i18n

`lib/views/authentication/login.dart:845`

```dart
localizedReason: 'Login using your biometric credential',
```

该字符串传递给系统生物识别弹窗展示给用户，未使用 `.tr()`。对比 `biometric_setting.dart:80` 同一参数已正确使用 `.tr()`。

→ 改为 `'Login using your biometric credential'.tr()`。

### M-11 route_generator.dart 4 处 argsType 文案错误

`lib/routes/route_generator.dart:67,82,97,131`

`/login`、`/signup`、`/authwall` 路由检查 `args is SessionArguments`，但错误文案写 `argsType: 'StreamController<SessionState>'`；`/editnote` 路由检查 `args is AddEditNoteArguments`，但文案写 `argsType: 'SafeNotes'`。用户看到的报错信息会误导排查。

→ 修正 argsType 文案为实际类型名。

### M-12 note_card_body.dart 紧凑模式标题判断脆弱

`lib/widgets/note_card_body.dart:165`

```dart
note.title == ' '
```

用单个空格判断"无标题"。如果标题是空字符串 `''` 或多个空格 `'  '`，此判断不成立，会显示空标题而非摘要。

→ 改为 `note.title.trim().isEmpty`。

### M-13 死代码：Style.buttonTextStyle / launchUrlInapp / 公开 State 类

- `lib/utils/styles.dart:20-24`：`Style.buttonTextStyle` 全项目无调用。
- `lib/utils/url_launcher.dart:22-26`：`launchUrlInapp` 全项目无调用。
- `lib/widgets/drawer.dart:62`：`HomeDrawerState` 公开但无外部引用。
- `lib/dialogs/export_backup_dialog.dart:78`：`ExportBackupDialogState` 同上。
- `lib/widgets/search_widget.dart:35`：`SearchWidgetState` 同上。

→ 删除死代码；公开 State 类改为 private（`_` 前缀）。

### M-14 nav_list.dart / drawer.dart 空回调

- `lib/widgets/nav_list.dart:166-168`：`onTagSelected` 为 null 时传入空回调 `() {}` 而非 `null`，使该项看起来可点击但无效果。
- `lib/widgets/drawer.dart:136`：Drawer header 的 `InkWell` 绑定空回调 `() {}`，点击有水波纹但无效果。

→ 传 `null` 让 InkWell 自然禁用；或移除 InkWell 改为 Container。

---

## 四、新发现 — 低优先级

### 安全与正确性

- **L-01** `safenote.dart:15,186,229`：头注释"本地存储为明文"已过时（实为字段级加密），多处注释误导。→ 更新注释。
- **L-02** `safenote.dart:297-300`：`SafeNote.toString()` 含 `title="$title"` 明文，违反日志隐私红线。→ 改为 `title="<redacted>"`。
- **L-03** `crypto.dart:130`：`kBackupAad` 常量值 `backup-v1` 与注释"v2 起改为 backup-v2"表述容易误解。→ 改注释为"未来 v2 版本可改为"。
- **L-04** `database_handler.dart:2042-2047`：`exportAll` 不导出墓碑，重新导入后删除状态无法恢复；`.toString()` 冗余。→ 如需保留墓碑改用 `readAllNotesIncludingDeleted()`。
- **L-05** `database_handler.dart:157-173`：`cachedNoteSummaries` 返回解密标题明文，供 WebServer 使用。→ 确认 WebServer 有鉴权或改为返回标题长度。
- **L-06** `sync_models.dart:1063`：`headerLen < 0` 不可达条件（uint32 解码非负）。→ 移除死分支。
- **L-07** `keyring.dart:711`：指纹比较用 `!=` 而非常数时间比较，与代码库约定不一致。→ 使用 `SyncCrypto.bytesEqual`。
- **L-08** `sync_engine.dart:1907-1912`：LWW 冲突解决依赖设备本地时间，时钟不准确时可能选错胜者。→ 同步诊断面板增加时钟偏差检测。
- **L-09** `journal.dart:975-984`：`fetchRemoteEntries` 对远端对象名无格式校验。→ 用正则过滤。
- **L-10** `journal.dart:919,929`：`syncToRemote` 读取本地文件无大小限制。→ 读取前检查 `file.length()`。
- **L-11** `url_launcher.dart:18,24`：抛裸字符串而非 Exception 对象。→ 改为 `throw Exception(...)`。
- **L-12** `url_launcher.dart:16-26`：无 URI scheme 校验。→ 显式校验 scheme 白名单。
- **L-13** `cache_manager.dart:21-22`：`dir.deleteSync(recursive: true)` 后立即 `dir.create()`，非原子操作且可能影响其他组件。→ 遍历目录内文件逐个删除。

### 代码质量与可维护性

- **L-14** `passphrase_util.dart:33`：`Zxcvbnm` 每次调用新建实例，加载整本字典，键入即卡。→ 缓存单例。
- **L-15** `device_id.dart:138`：未知平台用时间戳当 deviceId，每次启动都变。→ 生成随机 UUID 并持久化。
- **L-16** `app_logger.dart:190-191`：`List.removeAt(0)` 触发 O(n) 元素移动。→ 改用 `Queue` 或环形缓冲。
- **L-17** `env_config.dart:80`：使用 `print()` 而非 `Log` 系统。→ 替换为 `Log.app.w`。
- **L-18** `biometric_auth.dart:46-48`：日志三元表达式存在死分支（`value.isEmpty` 在前面已 return）。→ 简化日志。
- **L-19** `editor_state.dart:20-23`：`original`/`title`/`description` 为静态字段，无法支持多窗口/分屏编辑。→ 长期迁移为 Provider 实例。
- **L-20** `note_widget.dart`：`sessionStateStream` 死参数（声明 required 但从未使用）；`computeMaxLine` 28 行注释死代码。→ 删除。
- **L-21** `note_widget.dart:76,114`：`title!` / `description!` 强制解包可空参数。→ 改为 `title ?? ''` 或类型改 `String`。
- **L-22** `time_utils.dart:30-32 vs 38-42`：文档说"为 true 时一律显示相对时间"，实际 7 天内相对、超过绝对。→ 修正文档。
- **L-23** `snack_message.dart:21 vs 45`：文档说"错误类 6 秒"，实际 3 秒。→ 统一。
- **L-24** `search_widget.dart:145,110`：注释掉的代码残留。→ 删除。
- **L-25** `note_widget.dart:73`：`autofocus: true` 在编辑已有笔记时也自动聚焦标题框。→ 作为参数传入。
- **L-26** `sync_diagnostics_page.dart:934`：硬编码字体族 `Consolas`（Windows 专属）。→ 改为 `monospace`。
- **L-27** `sync_diagnostics_page.dart`：`_buildKVRow` 三处近似重复（:229/:505/:670）。→ 提取共享 Widget。
- **L-28** `login.dart:865`：魔法数字 `5` 控制生物识别挑战间隔。→ 提取为命名常量。
- **L-29** `login.dart:220` / `set_passphrase.dart:191` / `change_passphrase.dart:106`：`scrollToBottomIfOnScreenKeyboard` 三处重复。→ 提取为 mixin。
- **L-30** `login.dart:871-878`：`isPassphraseRememberChallenge()` 为顶层函数，无命名空间。→ 移入 `PreferencesStorage`。
- **L-31** `prefs_store_override.dart:69-74`：并发写入可能丢失更新（仅测试用）。→ 加 Future 互斥锁。
- **L-32** `export_backup_dialog.dart:212`：`minHeight: 122` 魔法数字。→ 提取为常量。
- **L-33** `preference_and_config.dart:688-703`：`_githubUrl`/`_faqsUrl`/`_playStorUrl` 均指向同一 GitHub 地址，可能是占位符。→ 发布前更新为真实链接。

### 可访问性

- **L-34** `search_widget.dart:140-147`：清除按钮缺少 `tooltip` 或 `Semantics`。→ 加 `tooltip`。
- **L-35** `nav_list.dart:231-271`：标签项缺少 `Semantics` 选中状态。→ 用 `Semantics(selected: active)` 包裹。
- **L-36** `states.dart:41`：空状态图标缺少 `semanticLabel`。→ 加 `semanticLabel: text`。

### i18n 残留

- **L-37** `footer.dart:38`：`'DEBUG'` 硬编码英文。→ 低优先级。
- **L-38** `log_webserver.dart:582-768`：内嵌 HTML 页面全中文，不支持多语言。→ 调试工具可接受。
- **L-39** `log_webserver.dart`：日志消息中英混用。→ 统一语言。

---

## 五、架构层面建议（优先级排序）

1. **立即修复 H-01 + H-02**（一行改动级）：Argon2id 编码 bug 影响所有非 ASCII 密码用户的安全强度；原子迁移遗漏 payload 会导致改密码后标签永久丢失。两项均为小改动、高收益。

2. **修复 H-03 + H-04**（数行改动级）：字符串 "null" bug 和 iOS 备份无 catch 都是低成本的确定性 bug，应立即修复。

3. **日志服务器安全加固（H-05）**：Release 模式禁用 `/api/download/*` 端点，或加 token 认证。这是唯一可能导致用户数据被局域网攻击者直接获取的漏洞。

4. **登录暴力破解防护（H-07）**：引入轻量级速率限制，恢复基本的安全姿态。无需恢复旧的全套锁定机制，只需指数退避冷却。

5. **异常分类体系完善**：统一 `wrapDecryptionError`（H-06）、`_decryptField` 异常类型（M-01）、401 与 5xx 分离（B-M3）。异常分类准确是同步引擎可靠重试的前提。

6. **缓存一致性修复**：`storeNotesInTransaction` 缺 id（M-02）+ 缓存重建竞态（M-03）+ `getPendingReuploadUuids` 静默失败（M-04），三者共同构成缓存层的数据一致性风险。

7. **死代码清理**：`note_widget.dart` 死参数/死代码、`Style.buttonTextStyle`/`launchUrlInapp` 死代码、公开 State 类改 private。降低维护成本。

8. **长期改造（维持搁置）**：明文口令驻留内存（高8）、编辑器静态态迁移为 Provider（L-19）。

---

## 六、测试覆盖评估

| 层级 | 文件数 | 覆盖评估 |
|------|--------|----------|
| core 单元测试 | 19 | 覆盖全面：crypto/sync_engine/journal/keyring/database/各后端均有测试，含 chaos 多客户端、P0P1 自愈、硬删除等复杂场景 |
| app 单元测试 | 19 | 覆盖关键路径：auth_flow/export_backup/home_drawer/note_actions/pin_keyboard/tag_editor/theme 等 |
| 集成测试 | 2 | `app_test.dart` + `first_run_test.dart`，覆盖首次启动和核心流程 |
| 测试支持 | 3 | `harness.dart`/`crypto.dart`/`asset_loader.dart` 提供测试基础设施 |

**测试亮点**：core 包测试质量极高，`chaos_multi_client_test` 和 `p0p1_self_heal_test` 体现了对分布式一致性的深入验证。`backend_redirect_test` 验证了 B-H1 修复。

**测试缺口**：
- `reEncryptAllNotesAtomically`（H-02）无对应测试，否则 payload 遗漏会被发现
- `iosBackup`（H-04）无异常路径测试
- `destroyImportCredentials`（H-03）无测试
- 视图层仅覆盖部分页面，`sync_diagnostics_page` 等复杂页面无 widget 测试
- 集成测试仅 2 个，核心同步流程的端到端覆盖偏薄

---

## 七、依赖健康度

`flutter pub outdated` 显示 29 个包有更新版本，均为 minor/patch 升级，无 breaking change：

| 依赖 | 当前 | 最新 | 备注 |
|------|------|------|------|
| device_info_plus | 12.4.0 | 13.2.0 | major 升级，需验证 API 变更 |
| file_picker | 11.0.3 | 12.0.0 | major 升级，注释说明"12.x 仍为 beta" |
| flutter_secure_storage | 10.3.1 | 11.0.0 | major 升级 |
| permission_handler | 12.0.3 | 13.0.1 | major 升级 |
| window_manager | 0.5.1 | 0.5.2 | patch 升级，低风险 |

无已知安全漏洞的依赖。建议在下一个开发周期评估 major 升级。

---

## 八、发现汇总

| 严重程度 | 数量 | 编号 |
|----------|------|------|
| 高（新发现） | 7 | H-01 ~ H-07 |
| 中（新发现） | 14 | M-01 ~ M-14 |
| 低（新发现） | 39 | L-01 ~ L-39 |
| 旧报告仍未修复 | 10 | 高8、B-M3、B-M5、B-H2、低优先级 6 项 |

**最紧急的修复**（小改动、高收益）：
1. H-01：`crypto.dart:212` — `password.codeUnits` → `utf8.encode(password)`（一行）
2. H-02：`database_handler.dart:1453-1530` — 补入 payload 迁移（数十行）
3. H-03：`file_handler.dart:182` — `"null"` → `''` 或改签名（一行）
4. H-04：`scheduled_task.dart:211-234` — 加 try-catch（数行）
5. M-10：`login.dart:845` — 加 `.tr()`（一行）

---

## 九、设计亮点（正面确认）

以下设计经审查确认正确，值得保留：

1. **两层密钥架构**（MK → dataKey）：改密码只重加密 32 字节 dataKey（O(1)），dataKey 永不变化。
2. **AAD 域分隔**：blob/dataKey-wrap/note-meta/backup 四类信封 AAD 完全隔离，密文不可互换。
3. **常数时间比较** `SyncCrypto.bytesEqual`：XOR 累积实现正确。
4. **Nonce 随机生成**：每次加密调用 `_secureRandom` 生成全新 nonce，不复用。
5. **HTTP 重定向策略**（B-H1 修复）：`http_util.dart` 统一 `followRedirects=false` + 显式 3xx 决策，杜绝方法降级与凭据泄露。
6. **硬删除 + purged 列表同事务**：防止崩溃窗口导致墓碑从远端复活。
7. **迁移中守卫** `_isMigrating`：阻止 UI 在 dataKey 迁移期间并发读取。
8. **日志隐私红线**：`_hashBrief` 仅输出 hash 前 8 字符，`_inspectorHiddenColumns` 隐藏密文列。
9. **P1-15 卡片重构**：四个卡片外壳退化为薄透传层，统一由 `NoteCardBody` 渲染，消除重复代码。
10. **PIN 键盘**设计完善：shuffle 防偷窥、自适应尺寸、桌面硬件键盘支持。
11. **测试体系**：core 包 19 个测试文件含 chaos 多客户端、自愈、重定向等复杂场景验证。
