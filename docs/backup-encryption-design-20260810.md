# 备份加密设计：B-KEY 派生密钥方案（2026-08-10）

> 状态：设计稿（待评审）
> 适用范围：`lib/models/file_handler.dart` 导出/导入、`packages/core` 加密原语、`bin/` CLI
> 配套：`docs/crypto-overview-20260810.md` §5.6（当前明文备份现状）、`docs/flutter-code-review-20260810.md` 高 1

---

## 1. 背景与现状

当前备份（`lib/models/file_handler.dart:39-49`）是**完全明文**的 JSON：

```json
{ "records": [...], "recordHandlerHash": "plaintext-v1", "total": N }
```

- `NotesDatabase.exportAll()` 输出已解密的笔记明文 JSON，直接拼入导出文件，可写入公共 Download 目录。
- `recordHandlerHash` 写死 `"plaintext-v1"`；导入不校验任何密码（`ImportEncryptionControl.setIsImportEncrypted(false)`）。
- `total` 用 `'{'.allMatches(record).length` 统计，算法错误（超出字符串里 `{` 的字面出现次数）。

本设计把「导出文件明文」这一安全缺口补上，同时不引入独立备份口令的记忆负担。
注意：导出明文不再被视为缺口本身——明文导出作为**数据可携性的一等公民选项**保留（§8），
加密是本设计的默认推荐路径而非强制。

## 2. 密钥选型：为什么是「密码派生独立备份密钥」（B-KEY）

候选方案对比：

| 方案 | 加密密钥 | 优点 | 缺点 | 结论 |
|---|---|---|---|---|
| 1. dataKey | 复用同步 dataKey | 实现最省事 | ①导入端拿不到旧 dataKey（换机/重装时新设备没有 dataKey，文件必须携带 encryptedDataKey，等价于绕回密码）；②dataKey 会随 scenario-c/d 迁移变化，旧备份锁死在旧 key 上；③备份与世界耦合 | **否** |
| 2. 密码派生独立密钥 | `B-KEY = PBKDF2(password, 独立备份salt)` | ①用户零记忆负担（用的就是已记住的登录口令）；②三层密钥（MK/dataKey/B-KEY）彻底分离；③每份备份独立 salt → 离线暴力破解逐个文件打满迭代；④导入端只需口令，天然跨设备 | 改登录口令后，`用旧口令导出的旧备份`需旧口令才能解（可接受的固有属性） | **首选** |
| 3. 独立备份口令 | 用户单独设的备份口令 | 信任级别最灵活；且是「忘记登录口令」时恢复备份的唯一逃生通道 | 用户要多记一个口令，导入/导出都要弹框 | **建议 CLI 与 GUI 均支持**（导出面板本就要做明文/密文选择与导出路径，顺带提供"用单独口令保护"入口） |

**核心设计原则（用户决策）**：密码只是一个**参数**，不要写死它的来源。

- 导出时可取「当前会话密码」（`PhraseHandler.getPass`），也可由用户输入任意口令（如高级导出时自定）。
- 导入时同样：默认先试当前会话密码自动解，失败后再让用户输入。
- 这样导出/导入的加密链路完全一致，只是密码来源不同——方案对 UI 层无绑定，天然兼容 CLI（CLI 每次独立进程，直接要求命令行/交互输入密码，不应假设有会话密码）。

## 3. 加密与解密参数

统一复用 `packages/core/lib/src/crypto/crypto.dart`（`SyncCrypto`）的既有原语族，不引入新算法：

| 参数 | 值 | 说明 |
|---|---|---|
| KDF | `PBKDF2-HMAC-SHA256` | 与登录 MK 派生同族（`kMkKdfAlgorithm`） |
| 备份 salt | 随机 16B（`SyncCrypto.generateSalt`） | **每份备份导出时重新生成**，写入文件头；跨备份 salt 独立 |
| 迭代次数 | `kPbkdf2Iterations = 200000` | 与登录一致，纳入文件头供未来调整 |
| 备份密钥 | 派生 32B `B-KEY` | `deriveMasterKey(password, salt: backupSalt, iterations)` |
| 对称加密 | `AES-256-GCM` | 信封格式 `nonce(12) ‖ ciphertext ‖ tag(16)` |
| nonce | 每次导出随机 12B | `SyncCrypto.generateNonce` |
| AAD | 固定常量 `backup-v1` | 仅作**域分隔符**（domain separator），防止备份密文被其它 GCM 消费方误用；不绑定任何明文/头字段（详见 §5） |
| 密钥封装 | 明文经 B-KEY 直接加密 | 不分装（不像 dataKey wrap MK），B-KEY 仅存在于导出/导入进程中 |

> 注意：B-KEY 与 MK/dataKey 完全分离——不写 `encryptedDataKey`、不写 keyFingerprint，导出文件里不得包含任何可关联登录 keyring 的敏感字段。

**新增 SyncCrypto API（核心包，纯 Dart）**：

```dart
// 导出备份密钥（恒等封装：B-KEY = PBKDF2(password, salt, iterations)）
// 注意：password 必须是「登录口令原文」（与登录派生 MK 同一字符串），
// 不是 MK 也不是其它派生值——否则跨设备派生出的 B-KEY 不一致，备份解不开。
static Future<Uint8List> deriveBackupKey(
  String password, {
  required Uint8List salt,
  int iterations = kPbkdf2Iterations,   // 从文件头读取，按文件参数派生
}) =>
    deriveMasterKey(password, salt: salt, iterations: iterations);

// 加密整份备份明文（一次性，返回信封字节）
// AAD 仅固定域常量，不绑定长度/头字段（防篡改由 GCM tag 天然覆盖，本设计不额外做）
static Future<Uint8List> sealBackup(
  Uint8List backupKey,
  Uint8List plaintext, {
  Uint8List? nonce,               // 缺省随机
  String aadHeader = kBackupAad,  // 'backup-v1'，仅域分隔符
}) async {
  final aad = Uint8List.fromList(utf8.encode(aadHeader));
  return _aesGcmEncrypt(backupKey, nonce ?? generateNonce(), aad, plaintext);
}

// 解密整份备份（一次性）；密码/盐/迭代不符时抛 SyncDecryptionException
static Future<Uint8List> openBackup(
  Uint8List backupKey,
  Uint8List envelope, {
  String aadHeader = kBackupAad,
}) async {
  final aad = Uint8List.fromList(utf8.encode(aadHeader));
  return _aesGcmDecrypt(backupKey, aad, envelope);
}
```

`SyncDecryptionException` 已是现成异常（见 `crypto.dart`），导入侧据此区分「密码错误/文件损坏」与其它失败。

## 4. 导出文件格式规范（v1，加密导出）

加密导出文件为单个 JSON 文本（UTF-8），扩展名 `.snbak`（与明文导出的 `.json` 区分；`SafeNotesConfig.importFileExtension` 需扩展为同时允许 `json`/`snbak`）。**整体结构 = 明文头 + 单块密文 `payload`**：头字段全部可读，用于定位/校验/派生密钥；只有笔记内容进密文。`payload` 解密后是纯数据数组（字段明细见 §4.1），外层文件本身不含任何笔记明文。

```json
{
  "format": "snbak",
  "formatVersion": 1,
  "enc": {
    "algorithm": "AES-256-GCM",
    "kdf": {
      "algorithm": "PBKDF2-HMAC-SHA256",
      "iterations": 200000
    }
  },
  "salt": "<base64 16B，每份导出随机>",
  "createdAt": 1700000000000,
  "total": 42,
  "payload": "<base64：nonce(12)‖ct‖tag(16)，明文为笔记 JSON 数组>"
}
```

字段语义：

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `format` | string | 是 | 固定 `"snbak"`，判文件类型（无此字段且为 `records` 根键的即明文格式，见 §8） |
| `formatVersion` | int | 是 | 当前 `1`；升格式时新老版本导入均支持 |
| `enc.algorithm` | string | 是 | `"AES-256-GCM"` |
| `enc.kdf.algorithm` | string | 是 | `"PBKDF2-HMAC-SHA256"` |
| `enc.kdf.iterations` | int | 是 | 当前 `200000`；写入头以便未来调参时按文件参数派生 |
| `salt` | string | 是 | base64 编码的备份 salt（16B） |
| `createdAt` | int | 是 | Unix 毫秒，导出时刻 |
| `total` | int | 是 | 笔记条数（明文 JSON 数组长度）。**修复原 `'{'.allMatches` 计数 bug** |
| `payload` | string | 是 | base64(AES-GCM 信封)。**解密后 = 笔记 JSON 数组**（即明文格式老文件的 `records` 值，字段明细见 §4.1） |

**不含**：keyFingerprint / vaultId / encryptedDataKey / 任何与同步 keyring 相关的字段——保持备份与同步域解耦、零关联。

### 4.1 records 数组元素（笔记字段规范）

`payload` 解密后得到的顶层 JSON 是一个**数组**，元素为笔记对象，字段与 `SafeNote.toJson()` 一致（`packages/core/lib/src/models/safenote.dart:221-234`），每个元素：

```json
{
  "uuid": "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx",
  "title": "标题明文",
  "description": "正文明文",
  "content_hash": "sha256hex(title\\ndescription)",
  "deleted": 0,
  "created_at": "2026-08-10T09:00:00.000",
  "updated_at": 1723000000000,
  "synced": 0,
  "synced_hash": null,
  "synced_deleted": 0
}
```

字段语义（`_id` 不入备份——主键是本机概念，`SafeNote.toJson` 本就不序列化 `id`，导入时由 `storeNotesInTransaction` 重新分配）：

| 字段 | 类型 | 说明 |
|---|---|---|
| `uuid` | string | 笔记唯一标识（UUIDv4）；导入时用于去重，已存在同 uuid 需决定跳过或覆盖 |
| `title` | string | 标题明文（备份内不加密，整包靠 payload 外层加密保护） |
| `description` | string | 正文明文 |
| `content_hash` | string | `SHA-256(title\\ndescription)` 十六进制定长 64，同步内容寻址用 |
| `deleted` | int | 软删除墓碑标记（0/1），恢复/回收站状态随备份保留 |
| `created_at` | string | ISO-8601 创建时间（`DateTime.toIso8601String`） |
| `updated_at` | int | 最后修改时间（Unix 毫秒） |
| `synced` | int | 是否已同步（0/1），跨设备迁移时保留同步状态语义 |
| `synced_hash` | string/null | 上次同步收敛时的 `content_hash`（共同祖先 base）；旧备份可缺省 → null |
| `synced_deleted` | int | 上次同步收敛时的 `deleted`（0/1），与 `synced_hash` 配套 |

兼容性：`ImportParser`/`SafeNote.fromJson` 已对缺省字段做补全（缺 `uuid`→生成、缺 `content_hash`→重算、缺时间→当前时间），故**第 1 版 v1 格式按要求全字段写入**，未来新增可选字段也不破坏老文件导入。

## 5. AAD 策略（仅域分隔符，不做防篡改绑定）

AES-256-GCM 的认证标签（tag）已天然保证密文完整性——任何对 `payload` 的篡改都会导致解密失败。因此本设计**不额外做"防篡改"绑定**（不把明文长度/头字段塞进 AAD）。

AAD 仅取一个**固定常量** `backup-v1` 作为域分隔符（domain separator），目的是避免备份密文被其它 GCM 消费方（如同步 blob 解密逻辑）误用，与安全强度无关。

- 版本演进：v2 起把常量改为 `backup-v2` 即可防止 v1 密文被 v2 解密逻辑误处理；该常量随代码演进硬编码，无需写入文件头（文件已有 `formatVersion` 供导入端分流）。
- 不绑定 `plaintextBytes` / `salt` / `iterations` 等头字段：改 `salt` 或 `iterations` 会直接让密钥派生结果不同 → 解密失败（fail closed），无需 AAD 额外兜底；这些字段的"正确性"由密码本身保证。本方案只需**防暴力破解**（依赖强 KDF + 每文件随机 salt + 口令强度），不追求密文级防篡改。

## 6. 导出流程

导出前弹出**导出选项对话框**，用户二选一：

| 选项 | 产物格式 | 是否需密码 |
|---|---|---|
| **加密导出（推荐）** | `snbak`（§4） | 是：输入/确认密码（默认预填会话密码） |
| **明文导出** | `{records, recordHandlerHash, total}`（§8，与旧格式全兼容） | 否 |

> 明文导出**必须保留**：用户可能换用其它笔记软件或弃用 SafeNotes，
> 需要能把自己的数据明文下载带走（与 Google Takeout / Bitwarden / Twitter 数据
> 下载同属数据可携性要求）。明文导出路径保持现状格式（`ImportParser` 直接可用），
> 仅 UI 明确提示"该文件不加密，请妥善保管"。

```
导出(用户选择 plaintext | encrypted；encrypted 需 password)：
  1. notes = await NotesDatabase.instance.exportAll()   // SafeNote.toJson() 数组字符串（含 uuid/时间戳等全部字段，§4.1）
  2. 两条路径共用一个数据源：明文/加密的区别仅在是否加密，records 内容完全一致
  3. 若选择明文导出：
       组装 { "records": <jsonDecode(notes)>, "recordHandlerHash": "plaintext-v1",
               "total": <数组长度> } → jsonEncode → 返回（现状不变，含评审 #1 计数修正：total 用数组长度）
  4. 若选择加密导出：
      salt = SyncCrypto.generateSalt()                  // 每份随机
      iterations = kPbkdf2Iterations                    // 当前 200000，写入头供未来调参
      backupKey = SyncCrypto.deriveBackupKey(password, salt, iterations: iterations)
      envelope = SyncCrypto.sealBackup(backupKey, utf8(notes))
      组装头（§4）→ jsonEncode → 返回
  5. 由调用方写盘（Android/iOS 现有 writeAsStringSync 路径不变）
```

- `password` 参数来源由调用方决定（当前会话密码 or 用户输入），加密函数不关心。
- 写文件前的 `total`/日志保留现有的「条数 + 字节数」记录，字节数以明文长度（或信封长度 + 头开销）记录。

**密码来源的三个落地入口**：

- 自动备份/登出前备份（`ScheduledTask.backup()`）：固定走加密导出，用 `PhraseHandler.getPass`（会话内存密码）派生。
- 手动导出（`backup_setting.dart`）：弹出选项框，选加密时默认预填 `PhraseHandler.getPass`，允许用户改动；为空则要求输入。
- CLI：`export` 带 `--format plaintext|encrypted`；encrypted 用 `--password` 或交互式输入（无会话态，见 §2）。

## 7. 导入流程

```
导入(密码来源参数 password，或主试/备试两段)：
  1. jsonDecode 文件 → 判格式：
       - 顶层有 format=="snbak" → 走加密导入（本方案）
       - 顶层有 records && recordHandlerHash=="plaintext-v1" → 走明文导入（§8）
  2. 校验格式号/算法常量（未知格式号 → 明确报"备份格式版本过高，请升级应用"）
  3. retry { password 候选 }：
       backupKey = deriveBackupKey(password, salt 从文件头读, iterations: 从文件头读)
       plaintext = SyncCrypto.openBackup(backupKey, envelope)
     on SyncDecryptionException：
       若还有候选密码则换下一个重试；否则报"密码错误或备份文件损坏"
  4. records = jsonDecode(plaintext)            // 裸数组（与明文导出 records 值一致）
  5. 核对 records.length == total（不一致 → 警告但不阻断，以解析结果为准）
  6. ImportParser.fromDecryptedPlaintext(records) → insertNotes（现有单事务写入，评审 #10 已落地）
```

**UI 密码输入策略**：

- 首选「当前会话密码」`PhraseHandler.getPass` 自动尝试（无弹框），失败才弹输入框让用户手输。
- 弹框输入必须是显式动作：导入从不静默用错密码的后果（误判损坏）。
- CLI：直接要求 `--password` 或交互式输入（无会话态，见 §2）。

## 8. 明文导出格式（plaintext-v1）

明文导出是**一等公民格式**（数据可携性，§6），文件内容：

```json
{
  "records": [ { "uuid": "...", "title": "...", "description": "...", /* §4.1 全字段 */ } ],
  "recordHandlerHash": "plaintext-v1",
  "total": 42
}
```

- `records` 每个元素与加密 `snbak` 的 `payload` 解密内容**完全一致**：同为 `SafeNote.toJson()`（`packages/core/lib/src/models/safenote.dart:221-234`）数组，保留 `uuid`/`created_at`/`updated_at`/`content_hash` 等全部字段，导入端 `ImportParser`/`storeNotesInTransaction` 以完全相同的逻辑消费。**明文与加密仅是「是否加密」之差，导出内容零差异**。
- `total` 直接用 `records` 数组长度（**修复原 `'{'.allMatches` 计数 bug**，见评审 #1）。
- 无任何密码/密钥字段，文件即笔记明文。

**导出**：UI 二选一时选「明文导出」即生成此格式；加密导出可选仍是默认（更安全）。

**导入**：

- 顶层有 `format=="snbak"` → 加密导入（§7，需密码）。
- 顶层为 `records` 根键（`recordHandlerHash=="plaintext-v1"`）→ 明文导入，按现有 `ImportParser` 逻辑（无密码校验）。
- 明文文件导入时 UI 弹一次提示「本备份未加密，已按明文导入」——既兼容旧备份，也覆盖用户主动选的明文导出文件。

## 9. 安全边界与威胁模型

| 威胁 | 防护 | 残余风险 |
|---|---|---|
| 加密备份文件被窃取后明文泄露 | AES-256-GCM 加密 + 200k 迭代 PBKDF2 | 口令强度决定暴力破解成本（与登录同） |
| 离线字典/暴力破解对密文逐份破解 | 每份独立随机 salt → 攻击者须逐文件、逐口令重跑完整 KDF（200k 迭代/次） | 弱口令可在 62^8 ≈ 2×10¹⁴ 组合内被枚举；强口令（≥12 位混合）实际不可破 |
| 密文被篡改 | GCM tag 天然覆盖完整性，任何篡改即解密失败（本设计不额外做防篡改绑定） | 无（fail closed） |
| **忘记登录口令** | — | **全部加密备份（含自动备份）永久不可恢复**；属本方案最致命残余风险，需用户牢记口令或改用方案 3 独立备份口令作为逃生通道 |
| 改登录口令后旧备份打不开 | 设计使然（旧口令解锁旧备份） | 需用户保留旧口令记忆，属固有属性 |
| 备份与 keyring 关联 | 文件头不含 keyFingerprint/vaultId/encryptedDataKey | 无 |
| 用户主动明文导出后泄露 | UI 明示"未加密，妥善保管"；自动备份永走加密 | 用户自担（数据可携性权衡，法规要求） |

**明确不做**（演进方向，非本期）：

- 独立备份口令（方案 3）**本期建议 CLI 与 GUI 均支持**：导出面板本就要做明文/密文选择与导出路径（§6），顺带提供"用单独口令保护"入口即可，加密链路天然支持（只是换个 password 参数）。它是 §9 威胁模型中「忘记登录口令 → 全部加密备份永久不可恢复」的唯一逃生通道，优先级应高于普通进阶项。
- 备份文件的完整性元数据（如独立 MAC）——GCM tag 已覆盖。

## 10. 改动清单（实施参考）

| 文件 | 改动 |
|---|---|
| `packages/core/lib/src/crypto/crypto.dart` | 新增 `deriveBackupKey(password,{salt,iterations})` / `sealBackup` / `openBackup` + `kBackupAad` 常量（固定域分隔符，无 `_backupAad` 长度绑定） |
| `packages/core/lib/src/models/parse_import.dart` | 新增加密文件头模型 `BackupHeader.fromJson`（format/salt/iterations/total 校验，不再含 plaintextBytes）；`ImportParser` 增加无密码的 `fromDecryptedPlaintext` 入口（消费裸数组） |
| `lib/models/file_handler.dart` | `encryptedOutputBackupContent()` → 真正加密（参 `password`），保留/改造明文导出路径 `plainOutputBackupContent()`；`selectFileAndImport` 加密码参数与弹框流程，按 format 分流（`snbak`→解密，`records`→明文）；`getFileAsString` 保持 256MB 上限 |
| `lib/views/settings/backup_setting.dart`（手动导出） | 导出前弹选项框（加密/明文二选一）；选加密则收集密码（默认当前会话密码，可改）；明文则仅二次确认 |
| `lib/utils/scheduled_task.dart`（自动/登出/改密前备份） | 固定加密导出，用 `PhraseHandler.getPass` 派生，异常时记日志并返回 false（评审 #2 语义保持） |
| `bin/safenotes_cli.dart` | `export` 增加 `--format plaintext|encrypted`（默认 encrypted），`import` 自动按格式分流；encrypted 用 `--password` 或交互输入 |
| `lib/data/preference_and_config.dart` | `importFileExtension` 支持 `json`/`snbak` 双扩展名；加密导出文件名用 `.snbak` |
| `docs/crypto-overview-20260810.md` | §5.6 更新为加密备份格式 |

## 11. 验证计划

1. `dart analyze packages/core` / `flutter analyze lib` 0 issue。
2. 核心包新增测试：
   - `seal/open` 成功往返（密码非空、长度一致）；
   - 错误密码 → `SyncDecryptionException`（不误报损坏）；
   - 头中 `salt`/`iterations` 被改 → 密钥派生结果不同 → 解密失败；
   - plaintext-v1 旧文件导入走兼容路径；
   - 明文导出文件导入（`records` 根键）走明文路径、无密码；
   - `json`/`snbak` 双扩展名的文件选择器均能识别。
3. `flutter test`：现有 widget/导入相关用例回归（文件解析、单事务写入不受影响）；手动导出选项框（加密/明文）widget 用例。
4. CLI 端到端：`export --format encrypted` → `import` 同机/他机可恢复；`--format plaintext` → 明文导出 → `import` 无密码即可恢复；旧明文文件仍可 import。

---

*变更记录：2026-08-10 初稿（B-KEY 方案，密码作为参数，导出/导入流程、加密参数、v1 文件格式规范）。2026-08-10 修订：格式标识 `safenotes-backup`→`snbak`；明文导出升级为一等公民格式（数据可携性），导出增加加密/明文二选一对话框，加密才要求输入密码。2026-08-10 修订 2：按评审精简——移除 AAD 明文长度绑定与文件头 `plaintextBytes` 字段（防篡改由 GCM tag 天然覆盖，本方案只聚焦防暴力破解）；`deriveBackupKey` 现转发头中 `iterations` 实现"按文件参数派生"；修正 `sealBackup`/`openBackup` 调用签名（去掉不存在的 `plaintextLength` 参数）；导入流程改用 `ImportParser.fromDecryptedPlaintext` 消费裸数组；威胁模型补充"忘记登录口令→全部加密备份永久不可恢复"这一最致命残余风险。2026-08-10 修订 3：方案 3「独立备份口令」由"后续可选"提升为**建议 CLI 与 GUI 均支持**——导出面板本就要做明文/密文选择与导出路径，顺带提供"用单独口令保护"入口；并明确它是「忘记登录口令」时恢复备份的唯一逃生通道，优先级高于普通进阶项。*