# 加密算法与参数清单（SafeNotes 当前实现）

> 梳理时间：2026-08-02 16:43
> 目的：枚举 app 当前**实际在用的**全部密码学原语与参数，定位性能瓶颈，为后续优化（原生 crypto / 单信封 / 懒加载 / isolate 并行）提供基线。
> 范围：仅含运行时代码路径；已废弃的死代码单独列出，不计入当前加密栈。

## 一、依赖的密码学库

| 库 | 性质 | 用途 |
|---|---|---|
| `pointycastle` | **纯 Dart**，无原生 / AES-NI 加速 | AESEngine / GCMBlockCipher / CBCBlockCipher / PBKDF2KeyDerivator / Pbkdf2Parameters / HMac / SHA256Digest / AEADParameters / KeyParameter / ParametersWithIV |
| `crypto`（Dart 包） | 纯 Dart | `sha256` |
| `dart:math` `Random.secure()` | 平台 CSPRNG | 所有随机数（dataKey / salt / nonce） |
| — | — | **无** `cryptography` / `cryptography_flutter`（即无原生 AES-NI 路径）；**无** RSA / ECDH / 数字签名；**无** Argon2 / scrypt |

**关键结论**：所有对称加密均为**纯 Dart 实现**，没有任何硬件 AES-NI 加速路径——这是"算法很慢"的根因。

## 二、两层密钥体系

- **MK（主密钥）** = `PBKDF2-HMAC-SHA256`
  - salt：16 字节 / per-vault 随机（`SyncCrypto.generateSalt`），随 manifest header 传播，保证跨设备派生一致
  - iterations：**200,000**（`kPbkdf2Iterations`，`crypto.dart:58`）
  - 输出：32 字节（256-bit）；HMAC 块长 64（SHA-256 的 block size）
  - 用途：只加密 dataKey（wrap）；改密码时变化
  - 派生**已在后台 Isolate** 执行（`deriveMasterKeyAsync` via `compute`，`crypto.dart:109`）
- **dataKey（数据密钥）** = 随机 32 字节（256-bit），首次启用同步生成一次、**永不变化**
  - 用途：真正加密笔记字段 / blob / manifest items / journal
  - 持久化：`AES-256-GCM(MK, AAD='datakey-wrap')` → `encryptedDataKey`，存 manifest header（`keyring.dart:460`）
- **指纹**
  - `keyFingerprint = SHA-256(MK)`（hex）：检测他端改密码
  - `dataKeyFingerprint = SHA-256(dataKey)`（hex）：标识 blob 加密身份，解密失败时区分"旧密钥"与"真损坏"

## 三、数据加密（信封统一格式 `nonce(12) ‖ ct ‖ tag(16)` = AES-256-GCM）

GCM 参数全局统一（`crypto.dart:42-44`）：`key=32B`、`nonce=12B 随机`、`tag=16B`、`AEADParameters(KeyParameter(key), 128, nonce, aad)`。

| 用途 | 密钥 | AAD | 实现位置 |
|---|---|---|---|
| **笔记字段级**（title + description **各一次**） | dataKey | `note.uuid` | `database_handler._encryptField` `:258` / `_decryptField` `:298` |
| blob（内容寻址） | dataKey | content hash | `crypto.seal/open` `:229` / `:243` |
| manifest items（整个 items JSON 作为一个信封） | dataKey | `'manifest-items'` | `sync_models.dart:836` |
| journal | dataKey | `'journal-aad'` | `journal.dart` |
| dataKey wrap | MK | `'datakey-wrap'` | `crypto.wrapDataKey` `:188` |

> ⚠️ **性能关键发现**：笔记是**字段级拆分**——每条笔记的 title 和 description **各自做一次 GCM**。41 条笔记的列表加载 = **82 次 GCM 解密** + 82 次 base64 解码 + 一遍 `SafeNote.fromJson`。这正是运行日志中"41 条解密 ~2s"的主因之一。并且这些 `seal/open` 调用**全部在主 isolate 同步执行**（同步引擎也在主 isolate 跑），没有任何后台化——MK 派生已后台化，但笔记加解密没有。

## 四、哈希

- **contentHash / blob 寻址 / manifest 比对** = `SHA-256(plaintext bytes)`，hex 字符串（`crypto.contentHash` `:262`）
- **`SafeNote.computeHash`** = `SHA-256(title + "\n" + description)`，hex（`safenote.dart:232`）——用于冲突判定 / 三方合并 base 比对
  - 注意：它与 blob 的 `SHA-256(content bytes)` 是**不同族**（前者拼接 `title\n+description` 字符串，后者是 `toContentBytes`）。二者不可混用。
- **ETag**（local_fs / webdav backend）= `SHA-256(file content)`，与 WebDAV 语义一致
- 指纹 = `SHA-256(MK)` / `SHA-256(dataKey)`

## 五、随机数

- `Random.secure()`（CSPRNG，底层 `/dev/urandom` / `BCryptGenRandom`）生成：
  - dataKey（32 字节）、salt（16 字节）、nonce（12 字节）
- 小瑕疵：`crypto.dart:76` 注释写"使用 FortunaRandom"，但实际实现 `:334` 用的是 `Random.secure()`——注释与实现不符，不影响正确性，仅文档问题。

## 六、已废弃（死代码，非当前加密栈）

- `lib/encryption/aes_encryption.dart`：
  - **AES-256-CBC + PKCS7** 加密
  - 密钥 / IV 通过自定义 SHA-256 循环派生（`deriveKeyAndIV`，OpenSSL EVP_BytesToKey 风格，**非标准 KDF、无盐/迭代**）
  - 信封格式：`randomString(8) ‖ salt(8) ‖ ciphertext`
- 状态：`sync-feature-design.md:308` 已标注"整体废弃"；全库**零调用**，仅测试引用（`test/encryption/aes_encryption_test.dart`）。
- 兼容性缺口：备份导入当前**不解密**旧 AES-CBC 密文（`temp/docs/login-refact-review-by-hy3.md:54`），如需兼容旧上游备份须显式走 `decryptAES` 路径——与本次性能主题无关，记录备查。

## 七、性能瓶颈定位与优化方向

### 根因
纯 Dart 的 pointycastle AES-256-GCM（无 AES-NI，GHASH 纯 Dart 计算慢） + **每笔记 2 次 GCM 运算** + **全部跑在主 isolate**。稳态滚动因明文缓存已不卡；首屏 / 缓存未命中 / 重加密 / 大库（400 条）仍会冻主线程。

### 可选优化（按性价比排序）
1. **算法实现换原生（最大杠杆）**：`cryptography_flutter` 在 Android / iOS 拿 AES-NI，快 10~100 倍；**Windows 桌面需 FFI 调 OpenSSL / CNG** 才有硬件加速，否则纯 Dart 仍慢。换信封格式 = 需全量重加密迁移（已有 `reEncryptAllNotesAtomically` + keyring ledger 机制兜底）。
2. **每笔记 2 次 GCM → 合并 1 次**（title + description 合一个信封）：GCM 次数直接减半，少一次 base64 / utf8 往返。低风险、跨平台、收益确定。
3. **列表只解 title，body 懒加载**：列表解密量再砍半，隐私不泄漏（title 仍加密）。最贴合"滚动卡顿"诉求。
4. **isolate 并行解密**：仅 400 条规模显著；40 条因 isolate 启动 / 消息拷贝固定开销，收益被吃掉。
5. **换 ChaCha20-Poly1305**：纯 Dart 下比 AES-GCM 快（无需 AES-NI），但仍是纯 Dart；作为"纯 Dart 还想再快"时的备选，不优先。

### 诊断建议
- 先用 DevTools **CPU profiler**（`flutter run --profile`）抓一次缓存未命中路径，确认 2s 里 `SyncCrypto.open`（GCM）与 `base64` / `utf8` / `SafeNote.fromJson` 的占比，再决定改算法还是改结构，避免盲目优化。
- 若需逐条耗时 / 离群检测 / CI 回归监控，再补一条**只记时长、不记内容**的 per-note 日志。

## 八、源码索引（快速定位）
- 核心加密层：`lib/sync/crypto.dart`（`SyncCrypto`：派生 / wrap / seal / open / 哈希 / RNG）
- 两层密钥与 KDF 参数：`lib/sync/keyring.dart`、`lib/sync/sync_models.dart`（`KdfParams` `:277`）
- 笔记字段级加解密：`lib/data/database_handler.dart`（`_encryptField` `:258` / `_decryptField` `:298`）
- manifest 序列化：`lib/sync/sync_models.dart:836`（items 信封）
- 已废弃备份加密：`lib/encryption/aes_encryption.dart`（死代码）
