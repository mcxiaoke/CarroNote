# SafeNotes 加密解密总览（参数与流程）

> 生成时间：2026-08-10 09:52 (GMT+8)
> 最后更新：2026-08-11（KDF 默认迁移 Argon2id + 生物识别凭据登录时刷新，见 §2.2 / §5.5 / §6.x）
> 覆盖范围：Flutter App 侧（`lib/`）+ 纯 Dart 核心包（`packages/core/`）+ CLI（`bin/`）
> 相关规范：`docs/spec-blob.md`、`docs/spec-manifest.md`、`docs/spec-journal.md`、
> `docs/manifest-reliability-design.md`、`docs/simplified-sync-design.md`

---

## 1. 总览

SafeNotes 采用**两层密钥 + 单一算法族**设计：所有对称加密统一为 AES-256-GCM，
所有哈希/指纹统一为 SHA-256，口令派生**默认 Argon2id**、存量 PBKDF2 按 header
算法字段自动回退（详见 §2.2）。

```
用户密码 password
   │  Argon2id(salt=per-vault 随机 16B, m=32MiB, t=3, p=2, out=32B)   ← 默认（2026-08-11 起）
   │  （存量 vault / 老备份按 manifest/snbak 头中 algorithm 字段回退到
   │    PBKDF2-HMAC-SHA256(salt, iter=200000)，不重加密数据）
   ▼
  MK (Master Key, 32B)          ← 改密码时变化；只用来包裹 dataKey，不直接加密任何业务数据
   │  AES-256-GCM(AAD='datakey-wrap')
   ▼
 encryptedDataKey (60B → base64)  ← 持久化到本地 keyring 账本 + 远端 manifest 明文头
   │  解包
   ▼
 dataKey (32B, 随机)            ← 真正加密一切业务数据；仅 scenario-c/d 迁移时变化
   ├── 本地 SQLite 的 title / description 字段
   ├── 远端 blob（笔记正文）
   ├── 远端 manifest 的 items 段
   └── 远端 journal 副本
```

**关键不变量**

| 不变量 | 说明 |
|---|---|
| 改密码不重加密数据 | 只用新 MK 重新包裹 dataKey（O(1)，60 字节），`keyVersion+1`，`dataKeyEpoch` 不变 |
| dataKey 永不无故变化 | 仅「加入他人 vault」（scenario-c/d）时才切换，切换必须全库重加密且与账本写入同事务 |
| 服务端零知识 | 服务端只见密文 blob、密文 items、密文 journal，以及明文 manifest header（含包裹态密钥与 KDF 参数） |
| 密钥永不落盘明文 | `dataKey` / `mk` 只是 `Keyring` 的运行时字段，logout 随实例丢弃 |

**核心代码入口**

| 职责 | 文件 |
|---|---|
| 密码学原语（唯一出口） | `packages/core/lib/src/crypto/crypto.dart` |
| 密钥环 / 账本 / 改密码 / 迁移 | `packages/core/lib/src/sync/keyring.dart` |
| 本地库字段级加解密 | `packages/core/lib/src/db/database_handler.dart` |
| manifest 容器序列化 | `packages/core/lib/src/sync/sync_models.dart`（`ManifestCrypto`） |
| journal 远端密文副本 | `packages/core/lib/src/sync/journal.dart` |
| blob 封/解封与同步编排 | `packages/core/lib/src/sync/sync_engine.dart` |
| 生物识别凭据包裹 | `lib/models/biometric_auth.dart` |
| 登录 / 改密码 UI 流程 | `lib/views/authentication/login.dart`、`lib/views/change_passphrase.dart` |

---

## 2. 密码学原语与参数

全部集中在 `packages/core/lib/src/crypto/crypto.dart` 的 `SyncCrypto`（静态无状态类）。

### 2.1 参数常量表

| 常量 | 值 | 位置 | 说明 |
|---|---|---|---|
| `_keyLength` | 32 B | crypto.dart:48 | AES-256 密钥长度，MK / dataKey 均为 32 字节 |
| `_nonceLength` | 12 B | crypto.dart:46 | AES-GCM 推荐 nonce 长度 |
| `_tagLength` | 16 B | crypto.dart:47 | GCM 认证标签长度 |
| `kSaltLength` / `_saltLength` | 16 B | crypto.dart:49,70 | per-vault 随机 salt（Argon2id 与 PBKDF2 共用） |
| `kPbkdf2Iterations` | 200000 | crypto.dart:63 | **仅 PBKDF2 回退分支**使用的迭代次数（存量 vault） |
| `kPbkdf2Algorithm` | `"PBKDF2-HMAC-SHA256"` | crypto.dart | PBKDF2 算法标识（header 算法字段取值之一） |
| `kArgon2idAlgorithm` | `"ARGON2ID"` | crypto.dart | Argon2id 算法标识（新 vault 默认取值） |
| `kMkKdfAlgorithm` | `"ARGON2ID"` | crypto.dart:73 | 新 vault / 新 keyring 的默认 KDF，写入 manifest header |
| `kArgon2idMemoryKib` | 32768 (32 MiB) | crypto.dart | Argon2id 内存硬度（m） |
| `kArgon2idIterations` | 3 | crypto.dart | Argon2id 迭代轮数（t，对应 KdfParams.iterations） |
| `kArgon2idParallelism` | 2 | crypto.dart | Argon2id 并行度（p） |
| `kBackupKdfAlgorithm` | `"ARGON2ID"` | crypto.dart | 加密 .snbak 备份 B-KEY 派生默认 KDF |
| `kDataKeyWrapAlgorithm` | `"AES-256-GCM"` | crypto.dart:76 | 写入 manifest header |

**默认 KDF：Argon2id（2026-08-11 起）**。参数 `m=32MiB, t=3, p=2`，本机 Windows 实测约
200–330ms，比 PBKDF2 200k（约 788ms）更快且内存硬化、对 GPU/ASIC 暴力破解抗性远强。
Argon2id 随现有 `cryptography` 包内置（`Argon2id` 类），**零新增依赖**。
**迭代次数 200k 仅存量 PBKDF2 回退使用**：OWASP 2023 推荐 600k，但纯 Dart 在手机端需
4-5 秒；200k 约 1-1.5 秒，定位为个人笔记场景，不对抗 GPU 集群。

### 2.2 密钥派生（Argon2id 默认 + PBKDF2 回退）

统一入口 `deriveKeyFromKdf(password, {required KdfParams kdf})` 按 `kdf.algorithm`
派发：

```dart
// 新 vault / 新备份（默认）
SyncCrypto.deriveKeyFromKdf(password, kdf: KdfParams(
    algorithm: 'ARGON2ID', salt: <16B>, iterations: 3,
    memoryKiB: 32768, parallelism: 2))
// = Argon2id(parallelism: 2, memory: 32768, iterations: 3, hashLength: 32)
//     .deriveKey(secretKey: SecretKey(password.codeUnits), nonce: salt)

// 存量 PBKDF2 vault / 老备份（按 header 算法字段回退）
SyncCrypto.deriveMasterKey(password, salt: <16B>, iterations: 200000)
// = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 200000, bits: 256)
//     .deriveKeyFromPassword(password: password, nonce: salt)
```

- `deriveMasterKeyAsync` / `deriveBackupKey` 现均经 `deriveKeyFromKdf` 派发，带计时
  日志（`Log.crypto`）用于登录卡顿定位。
- **salt 是 per-vault 随机 16 字节**，在 keyring 首次创建时生成，写入本地账本
  与远端 manifest header 的 `kdf.salt`（base64）。新设备从 header 读取 salt，
  保证「相同密码 + 相同 salt → 相同 MK」。Argon2id 与 PBKDF2 共用同一 salt。
- 历史演进（crypto.dart:13-16）：v0 用 `vaultId` 作 salt（新设备拿不到）→
  v1 全局固定 salt `'safenotes-v1'` → v2（当前）per-vault 随机 salt。
- **兼容性**：存量 PBKDF2 老 vault / 老备份按 manifest/snbak 头中 `algorithm` 字段
  自动回退到 PBKDF2，**存量数据零重加密迁移**；改密码时若仍为 PBKDF2 则自动升级为
  Argon2id（沿用同 salt、不重加密笔记），已是 Argon2id 则沿用。
- ⚠️ **平台加速差异（移动端）**：`cryptography_flutter` 仅加速 AES-GCM 与 PBKDF2
  （原生 JCE / CryptoKit / 后台 isolate），**不加速 Argon2id（纯 Dart）**。移动端
  Argon2id 派生耗时可能高于桌面；按决策沿用现有 `deriveMasterKeyAsync` 异步模式，
  未额外加 `compute()` 隔离（见 §9 弱点 #3 已解决）。

### 2.3 对称加密 AES-256-GCM

统一信封格式（**所有密文都是这一种布局，无 magic、无版本头**）：

```
┌────────────┬─────────────────────┬──────────┐
│ nonce 12B  │     ciphertext      │  tag 16B │
└────────────┴─────────────────────┴──────────┘
最小长度 = 12 + 16 = 28 字节
```

- 实例：`AesGcm.with256bits()`（`_gcm`，crypto.dart:290）。
- 加密：`_aesGcmEncrypt(key, nonce, aad, plaintext)` → `nonce ‖ ct ‖ tag`。
- 解密：`_aesGcmDecrypt(key, aad, envelope)`，先做**长度下限校验**（< 28 直接抛
  `SyncDecryptionException`，避免 `RangeError` 这类 `Error` 逃出 `on Exception` 捕获，
  见 crypto.dart:325-336 评审 #9）；GCM 校验失败统一 `wrapDecryptionError` 包装为
  `SyncDecryptionException`。
- nonce 恒为 `Random.secure()` 生成的 12 字节，不复用、不计数器化。

### 2.4 哈希与指纹（SHA-256）

| 方法 | 定义 | 用途 |
|---|---|---|
| `computeKeyFingerprint(mk)` | hex(SHA-256(MK)) | manifest header 明文字段 `keyFingerprint`，检测他端改密码、远端密码校验 |
| `computeDataKeyFingerprint(dataKey)` | hex(SHA-256(dataKey)) | header/item 的 `dataKeyFingerprint`，区分「旧密钥数据」与「真损坏」 |
| `sha256Hex(bytes)` | hex(SHA-256(bytes)) | 通用哈希原语，不承载协议语义 |
| `hashString(text)` | `sha256Hex(utf8(text))` | `SafeNote.computeHash` 的底层实现 |

> `sha256Hex` 在 2026-08-10 前名为 `contentHash`，与 `SafeNote.contentHash`
> 字段、DB 列 `content_hash` 三者重名而语义不同，已更名消歧。

指纹是单向的，只泄露「密钥身份」不泄露密钥本身；`keyFingerprint` 与
`encryptedDataKey` 的离线可验证性等价，因此明文存放不额外降低安全性。

### 2.5 随机数与常数时间比较

- `_secureRandom(n)`：`Random.secure()`，底层走平台 CSPRNG（`/dev/urandom` /
  `BCryptGenRandom`）。用于 dataKey(32B)、salt(16B)、nonce(12B)、vaultId(16B)。
- `bytesEqual(a, b)`：异或累加的常数时间比较，用于 dataKey / MK 比较（评审 #16
  统一入口，已删除 keyring 里非常数时间的 `_sameKey`）。
- `ManifestCrypto._constTimeEquals`：pubHash 比较（虽无密钥，保持习惯）。

### 2.6 平台加速路径

依赖 `cryptography ^2.9.0` + `cryptography_flutter ^2.3.4`，由 Flutter
plugin registrant 自动 `FlutterCryptography.registerWith()`（`.dart_tool/flutter_build/
dart_plugin_registrant.dart`），无需业务代码显式 enable：

| 平台 | AES-GCM | PBKDF2 |
|---|---|---|
| Android | FlutterAesGcm（JCE 原生，约 50x） | FlutterPbkdf2（Java 原生） |
| iOS / macOS | FlutterAesGcm（CryptoKit） | BackgroundPbkdf2（后台 isolate） |
| Windows / Linux | BackgroundAesGcm（后台 isolate） | BackgroundPbkdf2 |
| 测试 / 纯 Dart（CLI） | DartAesGcm | DartPbkdf2 |

信封格式与 PBKDF2 输出与旧 pointycastle 实现**逐字节互操作**，存量数据零重加密迁移。

---

## 3. AAD（附加认证数据）总表

AAD 决定「这个信封只能用在这个位置」，是防止密文搬移/替换的关键。

| 数据面 | AAD | 密钥 | 代码位置 |
|---|---|---|---|
| dataKey 包裹 | 固定串 `"datakey-wrap"` | **MK** | crypto.dart:325, 337 |
| 远端 blob（笔记正文） | `contentHash`（SHA-256 hex，即 blob 文件名） | dataKey | crypto.dart:232（`_blobAad`）、sync_engine.dart:1955 |
| 本地 DB 字段（title/description） | 笔记 `uuid` | dataKey | database_handler.dart:276, 290 |
| manifest items 段 | 固定串 `"manifest-items"` | dataKey | sync_models.dart:856, 937, 985 |
| journal 远端副本 | 固定串 `"journal-archive"`（`kJournalAad`） | dataKey | journal.dart:81, 913, 923, 970 |
| 生物识别凭据 | 固定串 `"biometric-auth"` | 独立随机 32B 包裹密钥 | biometric_auth.dart:71, 122 |

**blob AAD 纯化（v4 epoch 消除）**：blob 的 AAD 恒为裸 `id`（内容哈希），
**不再是 `'<epoch>|<hash>'`**。解密只回答「dataKey 对不对」；把 epoch 塞进 AAD 会让
「同 key 却解不开」的假性失败放大成翻转事故（crypto.dart:220-231，
`epoch-elimination-design-20260801.md` §4.2 —— 该设计文档已不在 `docs/`，
仅存于代码注释引用）。

---

## 4. 密钥体系与 Keyring 账本

代码：`packages/core/lib/src/sync/keyring.dart`

### 4.1 三个对象

| 对象 | 是否持久化 | 内容 |
|---|---|---|
| `KeyringEntry` | 是（包裹态） | `keyFingerprint` / `encryptedDataKey` / `keyVersion` / `dataKeyEpoch` / `archivedAt` / `reason` |
| `KeyringLedger` | 是 | `schemaVersion=1` / `vaultId` / `kdf` / `createdAt` / `current`(Entry) |
| `Keyring` | 账本部分持久化，`dataKey` / `mk` **仅内存** | 账本 + 运行时明文密钥 |

**存储位置**：本地 SQLite `sync_meta` 表的**单键** `keyring`，值为 `KeyringLedger` 的
JSON。单键 `setMeta` 天然原子，杜绝旧实现「7 次 setMeta 双写不一致」。

### 4.2 字段语义

| 字段 | 变化时机 | 说明 |
|---|---|---|
| `vaultId` | 创建时生成；scenario-d 迁移时整体切换 | UUIDv4（`Random.secure()` + RFC 4122 version/variant 位修正），**仅作同步组标识，不再作 salt** |
| `kdf` | 创建时固定；scenario-d 时采用远端；改密码若为 PBKDF2 则自动升级为 Argon2id | `{algorithm, salt(base64), iterations, memoryKiB?, parallelism?}`（Argon2id 带 memoryKiB/parallelism，PBKDF2 仅前三项） |
| `keyFingerprint` | 改密码时变 | `H(MK)` |
| `encryptedDataKey` | 改密码 / 迁移时变 | `base64(AES-GCM(MK, AAD='datakey-wrap', dataKey))`，固定 60 字节明文长度 |
| `keyVersion` | 改密码 +1 | 防止旧密码设备回滚新包裹 |
| `dataKeyEpoch` | **仅 dataKey 值真变时 +1** | v4 后不再驱动同步，纯审计标签 |
| `reason` | 每次更新 | `create` / `changePassword` / `adoptRemoteEpoch` / `migrateDataKey` |

### 4.3 可变性约定（易踩坑）

- `current` 为**可变字段 + 原地更新**（`adoptRemoteEpoch` / `updateEncryptedDataKey`），
  因为 `SyncService` 与 `SyncEngine` 共享同一 `Keyring` 实例；返回新实例会让一方持有
  旧引用（历史 BUG-3「本地纪元落后」）。
- `changePassword` / `migrateToRemote` / `migrateToRemoteVault` 因 dataKey 或 kdf 变化
  **返回新实例**，调用方必须替换引用。

### 4.4 异常约定

| 异常 | 触发 |
|---|---|
| `WrongPasswordException` | MK 解不开 `encryptedDataKey`（GCM tag 校验失败） |
| `KeyringNotInitializedException` | 本地无 `keyring` 键（含 JSON 损坏，按未初始化处理） |
| `SyncDecryptionException` | 任意 AES-GCM 解密失败（含长度不足） |
| `DataKeyNotSetException` | 未注入 dataKey 就读写笔记；或字段解密失败 |
| `MigrationInProgressException` | 全库重加密期间 UI 读笔记 |
| `ManifestAuthException` | manifest 容器结构 / pubHash 校验失败 → **数据损坏** |
| `ManifestKeyMismatchException` | pubHash 通过但 items GCM 失败 → **密钥不匹配** |

---

## 5. 各数据面的加解密流程

### 5.1 本地 SQLite 字段级加密

代码：`database_handler.dart:267-319`

```dart
// 写
row['title']       = base64( AES-GCM(dataKey, AAD=note.uuid, utf8(title)) )
row['description'] = base64( AES-GCM(dataKey, AAD=note.uuid, utf8(description)) )
// 读：反向；失败抛 DataKeyNotSetException（不静默返回原值）
```

要点：

- **只加密 `title` / `description` 两列**；`content_hash` / `deleted` / `created_at` /
  `updated_at` / `synced` / `synced_hash` / `synced_deleted` 是明文元数据（同步比对需要）。
- 空字符串短路不加密（`if (plaintext.isEmpty) return plaintext`）。
- AAD 用 `uuid` 绑定行身份，防止把 A 笔记的密文搬到 B 笔记行。
- dataKey 由登录流程 `setDataKey()` 注入，`clearDataKey()` 清除并使解密缓存失效。
- 存在**明文解密缓存** `_notesCache`（内存，含墓碑全量），避免每次列表刷新全量
  AES 解密（曾导致主线程冻结约 2s）；logout / 换库 / 重加密时整体失效。

### 5.2 远端 blob（笔记正文）

代码：`sync_engine.dart:1955`（封）、`sync_engine.dart:2039`（解）；规范 `docs/spec-blob.md`

```
id = contentHash = SHA-256_hex( title + "\n" + description )     ← SafeNote.computeHash
payload = utf8( {"v":2,"title":"...","description":"..."} )      ← SafeNote.toContentBytes
blob 文件内容 = AES-256-GCM(dataKey, nonce=random12, AAD=id, payload)
              = nonce(12) ‖ ciphertext ‖ tag(16)
远端路径     = <vault 根>/blobs/<id>
```

- **内容寻址 + 天然去重**：相同明文 → 相同 hash → 同一个 blob（nonce 不同不影响寻址）。
- 下载后强制校验 `SafeNote.computeHash(解密出的 title, description) == manifest 记录的 hash`
  （sync_engine.dart:2150-2156），防止服务端返回「uuid 对得上但内容不同」的合法信封。
- ⚠️ **易踩点（当前实现无此缺陷，是防退化提示）**：`SafeNote.computeHash`
  （`title\ndescription` 文本）与 `SyncCrypto.sha256Hex(payloadBytes)`（JSON 字节）
  **不是同一个值**。blob 的 id/AAD/manifest.hash 三者**一致地**只用前者
  （`sync_engine.dart:1955/1962/1367`、`2039/2091/2154`），`sha256Hex` 在生产代码里
  没有任何 blob 寻址调用点。若日后有人把身份口径改成对 payload 字节求哈希，全部存量
  blob 会立刻不可寻址，且**不产生编译错误**——该不变量已由
  `packages/core/test/sync/blob_addressing_test.dart` 锁定（经变异验证会红灯）。
- payload 带 `"v":2` 版本字段，身份（hash）与 payload 解耦：未来加字段不影响已寻址 blob。

### 5.3 manifest v5 容器

代码：`sync_models.dart:824-1050`（`ManifestCrypto`）；规范 `docs/spec-manifest.md`、
`docs/manifest-reliability-design.md` §5

```
0        4       6       8        12
┌────────┬───────┬───────┬────────┬───────────┬─────────────┬──────────┐
│ magic  │fileVer│schemaV│headerLn│  header   │    items    │ pubHash  │
│ 'SMNT' │  2B   │  2B   │  4B BE │ 明文 JSON │ AES-GCM 密文 │ SHA-256  │
│  4B    │  = 1  │  = 5  │        │           │             │   32B    │
└────────┴───────┴───────┴────────┴───────────┴─────────────┴──────────┘
items   = AES-256-GCM(dataKey, AAD='manifest-items', utf8(jsonEncode({"items":{...}})))
pubHash = SHA-256( 容器 [0, pubHash 起始) 的全部字节 )      ← 无密钥损坏校验
最小长度 = 12 + 32 = 44
```

**header 明文字段**（新设备无 dataKey 也能读）：

`schemaVersion`(=5) / `version` / `vaultId` / `createdAt` / `updatedAt` /
`keyFingerprint` / `keyVersion` / `encryptedDataKey` / `kdf{algorithm,salt,iterations,memoryKiB?,parallelism?}` /
`dataKeyWrap` / `dataKeyEpoch` / `dataKeyFingerprint` / `dataKeyCreatedAt` /
`dataKeyCreatedBy` / `lastModifiedBy`

**三阶段验证矩阵**（一次性区分损坏与密钥问题，这是 v5 的核心价值）：

| 阶段 | 失败结果 | 抛出 |
|---|---|---|
| 1. 结构：magic / fileVer / headerLen | 结构损坏 | `ManifestAuthException`（过短则 `FormatException`） |
| 2. `pubHash` 比对（常数时间） | 数据损坏（位翻转/截断/半写） | `ManifestAuthException` |
| 3. items GCM 解密 | 密钥不匹配 / 旧密钥数据 | `ManifestKeyMismatchException` |

历史教训：v4 之前「items GCM 失败一律按密钥问题处理」，导致**磁盘损坏被误判为
他端改密码（scenario-b），强制用户重登录**。

**为什么 header 是明文**：新设备加入时手上只有密码，必须先无密钥读到 `kdf.salt` 与
`encryptedDataKey` 才能派生 MK → 解出 dataKey → 再解 items。这是多端 join 的前提。
**为什么 items 要加密**：条目本身不含正文，但会泄露笔记数量与更新节奏。

### 5.4 journal 远端密文副本

代码：`journal.dart:878-980`；规范 `docs/spec-journal.md`

- 本地 `<baseDir>/journal/log.json` 与归档 `log-<seq>.json` 是**明文 JSON**，
  但条目只含 `uuid` / `contentHash` / 纪元号 / 设备号 / 时间戳，**不含笔记正文**；
  `key.*` 条目可携带包裹态 `encryptedDataKey`（暴露面与本地 `keyring` 键、
  远端 manifest header 完全一致，不引入新泄露面）。
- 上传远端前整文件加密：`AES-GCM(dataKey, AAD='journal-archive', 文件字节)`，
  写到 `<vault 根>/journal/<deviceId>-archive-<seq>.json` 与 `<deviceId>-current.json`。
  **远端永不落明文。**
- `fetchRemoteEntries` 拉全部设备副本解密合并，解密失败的对象**静默跳过**
  （可能属于别的 vault 或旧 dataKey 纪元）。
- 整个远端副本流程「绝不抛异常」，失败降级为本地-only。

### 5.5 生物识别凭据包裹（F-C01）

代码：`lib/models/biometric_auth.dart`

```
包裹密钥 KEY = 随机 32B（SyncCrypto.generateDataKey），存 secure storage 键
               "_secureBiometricWrapKey"（base64）
凭据密文     = "v1:" + base64( AES-GCM(KEY, AAD='biometric-auth', utf8(password)) )
               存 secure storage 键 "_secureBiometricAuthKey"
```

- 目的：把 vault 密码从「明文长期驻留 secure storage」降级为「包裹态」，
  secure storage 被部分导出时泄漏的是密文。
- ⚠️ **注意这不是真正的密钥隔离**：KEY 与密文存在同一个 secure storage 里，
  同时拿到两者即可还原明文密码。它降低的是「部分泄漏」风险，不是「完全泄漏」风险。
- 兼容：无 `v1:` 前缀的旧值按明文密码原样返回，下次写入自动升级为 v1。
- 关闭生物识别时两个键都删除；重新开启时**先删 KEY 再生成新的**，防止开关周期内密钥复用。
- 解包失败一律返回空串（指纹登录走失败分支），**绝不回退明文**。
- **凭据刷新时机（2026-08-11 修正）**：生物识别包裹凭据须与当前有效密码保持一致，
  刷新点有两处：
  1. `Session.login(passphrase)` —— **所有密码登录成功的唯一汇聚点**（本地解锁 /
     远端 fingerprint 比对通过），在 `isBiometricAuthEnabled` 时调用
     `BiometricAuth.setAuthKey()`。覆盖「他端改密码后本端用新密码重新登录」「普通
     密码登录」「生物识别登录自身（用解出的当前密码重新包裹，幂等）」；
  2. `Session.onPasswordSet(newPassword)` —— 本地改密码页 `change_passphrase.dart:408`
     调用，覆盖本地显式改密码。
  二者幂等：写入的密码必为已验证正确的当前密码，secure storage 写入为包裹态不存明文。
  **历史坑**：此前仅 `onPasswordSet` 刷新，导致他端改密后本端用旧密码指纹登录失败、
  改用新密码重登却未刷新 biometric，下次指纹登录即报密码错误。

### 5.6 备份导出 / 导入（手动与自动备份均为加密 .snbak）

代码：`lib/models/file_handler.dart`、`lib/dialogs/export_backup_dialog.dart`、`lib/utils/scheduled_task.dart`

```
明文导出（可选历史行为）: { "records": [...], "recordHandlerHash": "plaintext-v1", "total": N }
加密导出（snbak v1）     : 明文内容整体 AES-GCM 加密，密文随附件打包为 .snbak
```

- **手动导出面板**（`ExportBackupDialog`，设置页「导出」入口）二选一：
  - **加密 `.snbak`（推荐）**：`FileHandler.encryptedOutputBackupContent(password:)`，
    用面板输入口令派生密钥加密后落盘，任何持有文件的人无口令无法读取；
  - **明文 `.json`**：`plainOutputBackupContent()`，等同旧行为，UI 明确警示「文件未加密」。
- **自动备份**（`ScheduledTask.backup`）**同样走加密 `.snbak` 导出**：`unitBackupAttempt()`
  用会话内存密码（`PhraseHandler.getPass`）派生 B-KEY 加密，密码为空时如实失败（绝不写明文备份）。
  （早期版本自动备份为明文 `.json` 的遗留 TODO 已落地。）
- `recordHandlerHash` 写死为 `"plaintext-v1"`；旧版的 `passPhraseHash` 密码指纹已移除，
  明文导入时**不做任何密码校验**（`ImportEncryptionControl.setIsImportEncrypted(false)`）。
- 导入自动识别：顶层 `format=="snbak"` 走解密导入（需要导出时使用的口令）；
  否则按明文 `.json` 导入。
- 导入体积上限 256MB，整体单事务写入（任一条失败整体回滚）。

---

## 6. 关键流程时序

### 6.1 首次设置密码（`Keyring.createNew`）

代码：`keyring.dart:442-477`，UI 入口 `lib/views/authentication/set_passphrase.dart`

```
1. vaultId  = UUIDv4(Random.secure)
2. dataKey  = random 32B
3. salt     = random 16B → kdf = {ARGON2ID, base64(salt), iterations=3, memoryKiB=32768, parallelism=2}
4. MK       = Argon2id(password, salt, m=32MiB, t=3, p=2)   ← 默认；存量 PBKDF2 vault 用 deriveKeyFromKdf 回退
5. keyFingerprint   = hex(SHA-256(MK))
6. encryptedDataKey = base64(AES-GCM(MK, 'datakey-wrap', dataKey))
7. 写 sync_meta['keyring'] = ledger JSON   （keyVersion=1, dataKeyEpoch=1, reason=create）
8. database.setDataKey(dataKey)
```

安全守卫（评审 ds4p P1）：`set_passphrase.dart:390-396` 若检测到 keyring 已初始化，
**拒绝 createNew**，避免覆盖已有账本导致全库不可解。

### 6.2 本地登录（`Keyring.unlockLocal`）

代码：`keyring.dart:482-510`，UI `login.dart:396-442`

```
1. ledger = 读 sync_meta['keyring']；无 → KeyringNotInitializedException
2. MK      = deriveKeyFromKdf(password, ledger.kdf)   ← 按 ledger.kdf.algorithm 派发：
            新 vault 默认 Argon2id(m=32MiB, t=3, p=2)；存量老 vault 回退 PBKDF2-HMAC-SHA256(200k)
3. dataKey = AES-GCM-open(MK, 'datakey-wrap', base64d(ledger.current.encryptedDataKey))
             失败 → WrongPasswordException（即「密码错误」的唯一判定方式）
4. database.setDataKey(dataKey) → Session.login(password)（明文密码进 PhraseHandler 内存；
   若生物识别已启用，同时刷新 biometric 包裹凭据，见 §5.5）
```

**登录即验证**：没有独立的密码哈希表，「能解开 dataKey」就是密码正确。
UI 侧 `_isLoggingIn` 防重入（派生 MK 需 1-2s，防连点），失败递减
`_noOfAllowedAttempts` 并在归零后进入锁定倒计时。

### 6.3 新设备加入 / 本地账本失效 → 远端验证登录

代码：`login.dart:535-605`（`_tryVerifyPassphraseViaRemote`）+
`keyring.dart:516-553`（`unlockFromRemoteManifest`）

```
1. GET manifest → ManifestCrypto.deserializeHeaderOnly(bytes)   ← 无需 dataKey
2. MK_try = deriveKeyFromKdf(password, header.kdf)   ← 按 header.kdf.algorithm 派发（Argon2id / PBKDF2）
3. hex(SHA-256(MK_try)) == header.keyFingerprint ?
     否 → wrongPassword（扣尝试次数）
     是 → 密码正确
4. unlockFromRemoteManifest：用 MK 解 header.encryptedDataKey 得 dataKey
     ★ 先验证再持久化：密码错误时绝不写本地，避免错误密码污染本地状态
5. 落盘 keyring 账本（reason=adoptRemoteEpoch）→ 再 unlockLocal 拿 dataKey → setDataKey
```

三态返回 `verified / wrongPassword / unreachable`：网络不可达或**远端无 manifest**
一律 `unreachable`，**不扣尝试次数**（评审 #7：否则从未同步过的用户会被误锁）。
仅在 `SyncConfig.isSyncReady` 时才走远端验证，避免无条件触网带来的隐私泄露与
离线暴力放大（评审 kk27c P1）。

### 6.4 改密码（`Keyring.changePassword`，O(1)）

代码：`keyring.dart:790-839`，UI `lib/views/change_passphrase.dart:340-430`

```
salt 不变（沿用 kdf.saltBytes）
1. oldMK = deriveKeyFromKdf(oldPassword, kdf) → 解 encryptedDataKey 验证；失败 → WrongPasswordException
2. newMK = deriveKeyFromKdf(newPassword, newKdf)；若为 PBKDF2 vault 改密码则 newKdf 自动升级为
   Argon2id（沿用同 salt，不重加密笔记），已是 Argon2id 则沿用
3. newEncryptedDataKey = base64(AES-GCM(newMK, 'datakey-wrap', dataKey))   ← dataKey 原样
4. newKeyFingerprint   = hex(SHA-256(newMK))
5. keyVersion + 1；dataKeyEpoch 不变；reason=changePassword；一次 persist
6. Session.onPasswordSet → PhraseHandler 更新 + 刷新生物识别包裹凭据（另见 §5.5：所有密码登录
   成功的 Session.login 也会刷新 biometric，覆盖他端改密后重登场景）
```

**改密码不触碰任何笔记、不重传任何 blob**（只改 60 字节的包裹）。
UI 用 `verifyPassword()` 先只验不写，通过后才做备份/同步/ping 前置检查，
最后才 `changePassword()` 持久化——避免「先备份半天再发现旧密码错」。

### 6.5 dataKey 迁移（加入他人 vault：scenario-c / scenario-d）

| 场景 | 判据 | 处理 |
|---|---|---|
| 无需迁移 | 远端 `encryptedDataKey` == 本地 | 直接返回 |
| 同 vault 换 dataKey | 本地 MK 能解开远端包裹，但解出的 dataKey 与本地不同 | `migrateToRemote` |
| scenario-d（不同 vault，密码相同） | `hex(SHA-256(deriveKeyFromKdf(password, 远端 kdf))) == 远端 keyFingerprint` | `migrateToRemoteVault`（连 kdf/salt/vaultId 一起换） |
| scenario-c（密码不同） | 上式不成立 | `tryDeriveRemoteDataKey` 返回 null，不迁移 |

迁移的原子性（B1 修复，epoch 消除 P0 五项）：

```dart
await database.reEncryptAllNotesAtomically(
  oldKey: dataKey, newKey: remoteDataKey,
  keyringJson: jsonEncode(migrated.ledger.toJson()),
  markBlobReupload: keyChanged,      // 仅 dataKey 真变时才标记全量 blob 重传
);
database.setDataKey(remoteDataKey);  // 事务成功后才切换运行时 key
```

「全库重加密 + 写新账本 + 标记重传」在**同一个 SQLite 事务**内完成，消除
「重加密成功但账本未更新 → 崩溃后全库不可解」的窗口。
重加密期间 `_isMigrating = true`，UI 读路径抛 `MigrationInProgressException`；
失败时 `_dataKey` 回滚为原值。

### 6.6 登出（`Session.logout`）

```
ScheduledTask.backup() → SyncService.logout()（释放 keyring 实例，dataKey/mk 随之丢弃）
→ NotesDatabase.clearDataKey()（同时废弃明文解密缓存）
→ PhraseHandler.destroy()（清内存明文密码）
```

顺序约束：UI 先导航到 `/authwall` 卸载 HomePage，再清密钥，避免在途的
`refreshNotes` 因 dataKey 被清而抛异常。

---

## 7. 传输层与后端认证

**注意：这一层与端到端加密无关，只是运输通道的访问控制。数据在离开设备前已是密文。**

| 后端 | 认证方式 | 代码 |
|---|---|---|
| SafeServer | `Authorization: Bearer <token>`（部署时配置的固定 token） | `safe_server_backend.dart:743-745` |
| WebDAV | `Authorization: Basic base64(user:password)`（坚果云需应用专用密码） | `webdav_backend.dart:904-907` |
| LocalFS | 无（本地目录） | `local_fs_backend.dart` |

**凭据存储**（`lib/sync/sync_config.dart`）：

- 敏感项 → `flutter_secure_storage`：`sync_webdav_password`、`sync_safeserver_token`
  （H3 修复，此前明文存 SharedPreferences）。
- 非敏感配置（URL / 用户名 / 开关 / 间隔）→ SharedPreferences。
- 内存缓存 `_webdavPasswordCache` / `_safeServerTokenCache` 提供同步 getter。
- 后端实例复用键用 `password.hashCode` 参与拼接，避免把密码写进日志/键名。

**ETag（乐观锁）**：WebDAV 服务器不返回 ETag 头时用
`SHA-256(内容字节)` 兜底（`webdav_backend.dart:933`）；LocalFS 直接用
`SHA-256(文件字节)` 作强 ETag（`local_fs_backend.dart:405`）。这是完整性/并发控制
用途，**不是加密**。

---

## 8. 远端数据布局与泄露面

```
<vault 根>/
├── manifest.json          ← v5 容器：明文 header + 密文 items + pubHash
├── blobs/<contentHash>    ← 纯 AES-GCM 信封（nonce‖ct‖tag），文件名即 SHA-256
├── blobs-orphan/          ← 孤儿 blob 隔离区（两阶段 GC）
└── journal/<deviceId>-*   ← AES-GCM 密文 journal 副本
```

**服务端能看到（明文）**：manifest header 全部字段（vaultId、keyFingerprint、
keyVersion、encryptedDataKey、kdf 参数、dataKeyFingerprint、lastModifiedBy 设备号、
时间戳）、blob 文件名（= 内容 SHA-256）、blob 大小、访问时间模式。

**服务端看不到**：笔记标题/正文、笔记条数（items 已加密）、笔记 uuid、
更新者与更新时间的逐条映射。

**已知侧信道**：blob 文件名是明文内容哈希，攻击者若能猜测明文可验证其存在
（字典/已知明文确认攻击）。这是内容寻址去重的固有代价，代码注释中已明确接受
（`sync_models.dart:105-108`）。

---

## 9. 已知弱点与改进建议

| # | 问题 | 位置 | 建议 |
|---|---|---|---|
| 1 | 备份导出/导入完全明文，无密码校验 | `file_handler.dart:39-49` | 用 MK 或独立口令封装为 AES-GCM 容器；至少 UI 强提示 |
| 2 | 生物识别包裹密钥与密文同处 secure storage | `biometric_auth.dart:103-113` | 移到平台 Keystore/Keychain 的硬件绑定密钥（`setUserAuthenticationRequired`） |
| 3 | ~~PBKDF2 200k 低于 OWASP 2023 的 600k~~ | `crypto.dart:63` | **已解决（2026-08-11）**：新 vault / 新备份默认 Argon2id（`m=32MiB, t=3, p=2`），存量 PBKDF2 按 header 算法字段回退并在改密码时自动升级；Argon2id 为纯 Dart 派生（无原生加速），移动端耗时较长（见 §2.2 / §2.6） |
| 4 | 会话明文密码常驻内存 `PhraseHandler._passphrase` | `preference_and_config.dart:409-429` | Dart 无法安全擦除 String；可改存派生的 MK 字节并在用后置零 |
| 5 | blob 文件名泄露内容哈希 | 设计固有 | 若要消除，需改用 `HMAC(dataKey, blobId)` 作对象名（牺牲跨 vault 去重） |
| 6 | ~~`SafeNote.computeHash` 与 `SyncCrypto.contentHash` 语义相近但不等价~~ | — | **已处理（2026-08-10）**：后者更名 `sha256Hex` + 补 `blob_addressing_test.dart` 锁定不变量 |
| 7 | `computeHash` 的 `title + "\n" + description` 编码非单射 | `safenote.dart:247` | `("A\nB","C")` 与 `("A","B\nC")` 碰撞。修复须改 hash 定义 → 全量 blob 重传 + `content_hash`/`synced_hash` 整表迁移 + 多端不可灰度，投入产出比低，暂留 |

---

## 10. 代码索引速查

| 想找什么 | 去哪里 |
|---|---|
| 迭代次数 / nonce 长度 / 算法名常量 | `packages/core/lib/src/crypto/crypto.dart:46-76` |
| AES-GCM 封/解封实现 | `crypto.dart:295-355` |
| KDF 派发（Argon2id / PBKDF2） | `crypto.dart`（`deriveKeyFromKdf` / `deriveMasterKey` / `_deriveArgon2id`） |
| 各类指纹计算 | `crypto.dart:144-170` |
| 密钥创建 / 解锁 / 改密码 / 迁移 | `packages/core/lib/src/sync/keyring.dart:442-839` |
| 本地字段加解密 | `packages/core/lib/src/db/database_handler.dart:267-319` |
| 全库重加密（事务原子） | `database_handler.dart:929-1110` |
| manifest 容器封/解 | `packages/core/lib/src/sync/sync_models.dart:910-1050` |
| KDF 参数与 header 字段定义 | `sync_models.dart:286-520` |
| blob 封/解 | `packages/core/lib/src/sync/sync_engine.dart:1955`、`:2039` |
| journal 密文副本 | `packages/core/lib/src/sync/journal.dart:893-980` |
| 登录密码验证（本地/远端） | `lib/views/authentication/login.dart:396-605` |
| 改密码 UI 流程 | `lib/views/change_passphrase.dart:340-430` |
| 生物识别凭据包裹 | `lib/models/biometric_auth.dart` |
| 后端凭据存储 | `lib/sync/sync_config.dart:183-240` |
| CLI 密钥装配 | `bin/cli_context.dart:167-195` |

**相关测试**（`dart test packages/core/test/sync/<file>`）：

| 文件 | 覆盖 |
|---|---|
| `crypto_test.dart` | PBKDF2 / Argon2id 派生与互异、AES-GCM 信封 / 指纹 / 常数时间比较等原语 |
| `keyring_test.dart` | 创建 / 解锁 / 改密码 / 迁移 / 账本持久化 |
| `journal_test.dart` | journal 写入、滚动、远端密文副本 |
| `multi_device_test.dart` | 多设备同密码/异密码 join（scenario-c/d） |
| `p0p1_self_heal_test.dart` | 解密失败自愈与 repair |
| `chaos_multi_client_test.dart` | 账本/manifest 损坏下的行为 |

App 侧 `flutter test`（含 change_password）；集成测试
`packages/core/test/sync/safe_server_integration_test.dart` 需先启动 SafeServer。
