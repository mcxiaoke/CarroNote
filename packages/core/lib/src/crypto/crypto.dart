/*
 * 同步功能核心加密层
 *
 * 两层密钥架构：
 *   MK (Master Key) = PBKDF2(password, per-vault-salt, 200k)  ← 改密码时变化，只用来加密 dataKey
 *   dataKey = 随机 32 字节                                     ← 永不变化，真正加密笔记内容
 *
 * 多端一致性关键：
 *   per-vault 随机 salt 在 keyring 首次创建时生成，写入 manifest header 随密文一起传播。
 *   新设备加入时从远端 manifest 读取 salt，保证相同密码 + 相同 salt 派生出相同 MK。
 *   跨用户使用不同 salt，使预计算的彩虹表失效（比全全局固定 salt 更安全）。
 *
 * 历史演进：
 *   v0 用 vaultId 作为 salt，但 vaultId 在新设备加入前无法获得，且不同设备初始
 *   vaultId 不同导致 MK 不一致。v1 改用全局固定 salt 'safenotes-v1'。v2 改为
 *   per-vault 随机 salt（当前实现），兼顾跨设备一致性与跨用户隔离。
 *
 * 信封格式：nonce(12) ‖ ciphertext ‖ tag(16)
 *   = AES-256-GCM(dataKey, nonce, AAD=id, plaintext)
 *
 * 实现演进（2026-08-02，性能优化）：
 *   pointycastle（纯 Dart，无硬件加速）→ cryptography + cryptography_flutter：
 *     - Android/iOS/macOS：`FlutterCryptography.enable()` 后 AES-256-GCM 走平台原生
 *       （CryptoKit / Android JCE），快 ~50 倍；PBKDF2 在 Android 走原生实现。
 *     - Windows/Linux：自动回退 BackgroundAesGcm / BackgroundPbkdf2（后台 isolate），
 *       不阻塞 UI，纯 Dart 性能与原先相当。
 *     - 信封格式（nonce12 ‖ ct ‖ tag16）与 PBKDF2 输出均与旧实现互操作，存量数据零重加密迁移。
 */

// Dart 原生导入
import 'dart:convert';
import 'dart:math' show Random;
import 'dart:typed_data';

// 第三方加密库（cryptography 2.x 全部为异步 API）
// 仅取用所需符号，避免命名冲突（Mac / Hmac / SecretKey 等）。
import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart' show
    AesGcm, Argon2id, Hmac, Mac, Pbkdf2, SecretBox, SecretKey;

// 项目导入
import 'package:core/src/sync/sync_error.dart';
import 'package:core/src/sync/sync_models.dart';
import 'package:core/src/logger/app_logger.dart';

// 信封各部分的固定长度
const int _nonceLength = 12; // AES-GCM 推荐 12 字节 nonce
const int _tagLength = 16; // AES-GCM 认证标签 16 字节
const int _keyLength = 32; // AES-256 密钥 32 字节
const int _saltLength = 16; // PBKDF2 salt 16 字节

/// PBKDF2 迭代次数（200,000 次）
///
/// 仅作为 PBKDF2 回退分支（存量老 vault / 老备份）的默认迭代次数，
/// 以及单元测试低迭代加速用。新 vault 默认改用 Argon2id（见下方常量）。
///
/// 选型依据（历史）：
///   - OWASP 2023 推荐 600,000 次，但实测在手机端纯 Dart 实现耗时 4-5 秒，
///     严重影响登录体验。
///   - 200,000 次在手机端约 1-1.5 秒，配合 Isolate 后台线程 UI 不卡顿。
///   - 安全性：RTX 4090 约 6,000 H/s，8 位混合密码理论破解需 ~1,153 年。
///   - 个人笔记场景无需对抗 GPU 集群攻击，需要高强度保护的用户应设置强密码。
///   - 配合 Isolate 后台派生，UI 线程不阻塞。
///   - 迁移 cryptography_flutter 后 Android 走原生 PBKDF2，同等迭代耗时大幅下降。
///
/// 公开为常量供 manifest header 写入 KDF 参数（算法透明性）。
const int kPbkdf2Iterations = 200000;

/// MK 派生算法名称（新 vault 默认使用 Argon2id）
///
/// 存量 vault 按 manifest header 中存储的 `algorithm` 字段自动回退到
/// PBKDF2-HMAC-SHA256，实现无缝兼容（见 [deriveKeyFromKdf]）。
const String kMkKdfAlgorithm = 'ARGON2ID';

/// PBKDF2 算法标识（存量数据 / 回退分支）
const String kPbkdf2Algorithm = 'PBKDF2-HMAC-SHA256';

/// Argon2id 算法标识（新 vault / 新备份默认）
///
/// 内存硬化（memory-hard）KDF，对 GPU/ASIC 暴力破解的抗性远强于 PBKDF2。
/// 本包 `cryptography` 已内置（调试面板 KDF 基准已验证），零新增依赖。
/// 注意：`cryptography_flutter` 不加速 Argon2id（仅加速 AES-GCM/PBKDF2），
/// 移动端为纯 Dart 实现，派生耗时可能高于桌面。
const String kArgon2idAlgorithm = 'ARGON2ID';

/// Argon2id 默认参数（新 vault / 新备份）
///
/// memory = 32 MiB，t = 3，p = 2，hashLength = 32。
/// Windows 实测约 200–330ms，比 PBKDF2 200k（788ms）更快且更抗破解。
const int kArgon2idMemoryKib = 32768; // 32 MiB
const int kArgon2idIterations = 3;
const int kArgon2idParallelism = 2;

/// per-vault 随机 salt 长度（字节）
///
/// 每个 keyring 创建时生成独立的随机 salt，写入 manifest header。
/// 相同密码 + 不同 salt → 不同 MK，跨用户预计算彩虹表直接失效。
/// 多端一致性：salt 随 manifest header 传播，新设备按 header 中的 salt 派生 MK。
const int kSaltLength = 16;

/// dataKey 包装算法名称（写入 manifest header 供未来算法迁移）
const String kDataKeyWrapAlgorithm = 'AES-256-GCM';

/// 备份文件格式标识（写入 snbak 文件头的 `format` 字段）
///
/// 加密导出文件扩展名为 `.snbak`（与明文 `.json` 区分，见 docs/
/// backup-encryption-design-20260810.md §4）。无此字段且为 `records`
/// 根键的文件即明文格式（plaintext-v1）。
const String kBackupFormat = 'snbak';

/// 备份文件格式版本（当前 1）
const int kBackupFormatVersion = 1;

/// 备份 AAD 域分隔常量（domain separator）
///
/// 仅用于分隔「备份密文」与其它 GCM 消费方（如同步 blob），**不做防篡改
/// 绑定**（GCM tag 天然覆盖完整性）。v2 起改为 `backup-v2` 即可防止 v1
/// 密文被误用，常量随代码演进硬编码，无需写入文件头。
const String kBackupAad = 'backup-v1';

/// 备份 KDF 算法名称（写入 snbak 文件头的 `enc.kdf.algorithm` 字段）
///
/// 新备份默认 Argon2id；老 PBKDF2 备份仍可导入（[BackupHeader.fromJson]
/// 同时接受两种算法）。
const String kBackupKdfAlgorithm = 'ARGON2ID';

/// 备份对称加密算法名称（写入 snbak 文件头的 `enc.algorithm` 字段）
const String kBackupEncAlgorithm = 'AES-256-GCM';

/// 同步加密工具类
///
/// 所有方法均为静态、无状态，可在任意线程调用。
/// 加密/解密/派生方法为异步（cryptography 2.x 异步 API）；
/// 哈希、指纹、随机数生成保持同步。
class SyncCrypto {
  SyncCrypto._();

  // ──────────────────────────────────────────────
  // 密钥派生
  // ──────────────────────────────────────────────

  /// 用 PBKDF2-HMAC-SHA256 从用户密码派生主密钥 MK（回退分支）
  ///
  /// [password] 用户输入的明文密码
  /// [salt] per-vault 随机 salt（必填，从 manifest header 或本地 meta 读取）
  /// 返回 32 字节的 MK
  ///
  /// 仅用于存量 PBKDF2 老 vault / 老备份的向后兼容派生，以及单元测试。
  /// 新 vault 默认走 Argon2id（见 [deriveKeyFromKdf]）。
  ///
  /// 多端一致性关键：相同密码 + 相同 salt → 相同 MK。
  /// salt 随 manifest header 传播，新设备按 header 中的 salt 派生 MK。
  ///
  /// 实现：cryptography 的 [Pbkdf2]。`FlutterCryptography.enable()` 后：
  ///   - Android → FlutterPbkdf2（Java 原生，快数倍）
  ///   - iOS/Windows/Linux → BackgroundPbkdf2（后台 isolate，不阻塞 UI）
  ///   - 测试环境 → 纯 Dart 实现（与 pointycastle 输出一致，已验证互操作）
  static Future<Uint8List> deriveMasterKey(
    String password, {
    required Uint8List salt,
    int iterations = kPbkdf2Iterations,
  }) async {
    final algo = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: _keyLength * 8,
    );
    final key = await algo.deriveKeyFromPassword(password: password, nonce: salt);
    return Uint8List.fromList(await key.extractBytes());
  }

  /// 用 Argon2id 从用户密码派生主密钥 MK
  ///
  /// [password] 用户输入的明文密码
  /// [salt] per-vault 随机 salt（必填，从 manifest header 或本地 meta 读取）
  /// [memoryKiB] 内存占用（KiB，如 32768 = 32 MiB）
  /// [parallelism] 并行度（lane 数）
  /// [iterations] 迭代次数（t）
  /// 返回 32 字节的 MK
  ///
  /// 内存硬化 KDF，对 GPU/ASIC 暴力破解抗性远强于 PBKDF2。
  /// 注意：`cryptography` 的 Argon2id 为纯 Dart 实现（无原生加速），
  /// 移动端派生耗时可能高于桌面，但本机实测 32MiB/t3/p2 仅约 200–330ms。
  static Future<Uint8List> _deriveArgon2id(
    String password, {
    required Uint8List salt,
    required int memoryKiB,
    required int parallelism,
    required int iterations,
  }) async {
    final algo = Argon2id(
      parallelism: parallelism,
      memory: memoryKiB,
      iterations: iterations,
      hashLength: _keyLength,
    );
    final key = await algo.deriveKey(
      secretKey: SecretKey(password.codeUnits),
      nonce: salt,
    );
    return Uint8List.fromList(await key.extractBytes());
  }

  /// 按 [KdfParams.algorithm] 选择派发算法，统一 KDF 入口
  ///
  /// - `algorithm == kArgon2idAlgorithm` → [_deriveArgon2id]
  ///   （用 [KdfParams.memoryKiB] / [KdfParams.parallelism] / [KdfParams.iterations]）
  /// - 其它（含存量 PBKDF2-HMAC-SHA256）→ [deriveMasterKey]
  ///
  /// 这是登录 MK 派生与备份 B-KEY 派生的唯一分发点，保证老数据按存储算法
  /// 回退、新数据走 Argon2id，两者无缝共存。
  static Future<Uint8List> deriveKeyFromKdf(
    String password, {
    required KdfParams kdf,
  }) async {
    if (kdf.algorithm == kArgon2idAlgorithm) {
      return _deriveArgon2id(
        password,
        salt: kdf.saltBytes,
        memoryKiB: kdf.memoryKiB ?? kArgon2idMemoryKib,
        parallelism: kdf.parallelism ?? kArgon2idParallelism,
        iterations: kdf.iterations,
      );
    }
    // 默认 / 存量数据：PBKDF2-HMAC-SHA256
    return deriveMasterKey(password, salt: kdf.saltBytes, iterations: kdf.iterations);
  }

  /// 异步派生 MK（不阻塞 UI 线程）
  ///
  /// 按 [kdf] 中记录的算法与参数派发（见 [deriveKeyFromKdf]）。
  /// cryptography 的 PBKDF2 在原生/Background 路径已负责后台化；Argon2id
  /// 为纯 Dart，这里保留计时日志便于定位登录卡顿。
  static Future<Uint8List> deriveMasterKeyAsync(
    String password, {
    required KdfParams kdf,
  }) async {
    final sw = Stopwatch()..start();
    Log.crypto.d('开始派生主密钥 MK: 算法=${kdf.algorithm} 迭代=${kdf.iterations} '
        'memory=${kdf.memoryKiB}KiB parallelism=${kdf.parallelism} '
        'salt=${kdf.saltBytes.length}字节');
    final result = await deriveKeyFromKdf(password, kdf: kdf);
    Log.crypto.i('主密钥 MK 派生完成: ${result.length} 字节, '
        '耗时 ${sw.elapsedMilliseconds}ms');
    return result;
  }

  /// 计算密钥指纹 = H(MK)
  ///
  /// 用于 manifest header 明文存储，检测他端改密码：
  ///   - 远端 fingerprint != 本地 fingerprint → 他端改了密码
  ///   - 安全性：与 encryptedDataKey 等价（都能离线验证密码），不降低安全性
  ///
  /// [masterKey] 32 字节的 MK
  /// 返回 SHA-256(MK) 的十六进制字符串
  static String computeKeyFingerprint(Uint8List masterKey) {
    return sha256Hex(masterKey);
  }

  /// 计算 dataKey 指纹 = H(dataKey)（v4 epoch 消除设计新增）
  ///
  /// 用途（item 自描述 + 只读解密，docs/epoch-elimination-design-20260801.md
  /// §4.1 / §8.2[D]）：
  ///   - 写入 [ManifestItem.dataKeyFingerprint]：标记「加密该 blob 的 dataKey
  ///     身份」，本地构建时恒为当前指纹，解密端不推断、不比较、不纠正。
  ///   - 解密失败时精确区分「旧 key 数据（可提示）」与「真损坏（不可修）」：
  ///     `item.dataKeyFingerprint == 当前指纹` 却解不开 → 真损坏；
  ///     不等 → 旧密钥数据，提示修复线索。
  ///
  /// 安全性：SHA-256 单向，仅泄露「dataKey 身份」不泄露 dataKey 本身；
  /// 是 epoch（dataKey 的冗余别名）的替代，作为自包含的密钥身份。
  ///
  /// [dataKey] 32 字节的数据主密钥
  /// 返回 SHA-256(dataKey) 的十六进制字符串
  static String computeDataKeyFingerprint(Uint8List dataKey) {
    return sha256Hex(dataKey);
  }

  /// SHA-256 十六进制摘要（统一指纹/哈希入口，替代 crypto 包散落调用）
  ///
  /// 这是一个**通用密码学原语**，不承载任何协议语义。特别注意：它不是
  /// blob 的身份。blob id / AAD 只由 `SafeNote.computeHash` 定义，见
  /// [hashString] 的说明。
  static String sha256Hex(Uint8List bytes) {
    return sha256.convert(bytes).toString();
  }

  /// 生成随机 32 字节的 dataKey（数据主密钥）
  ///
  /// dataKey 在首次启用同步时生成一次，之后永不变化。
  /// 所有笔记的 envelope 都用同一把 dataKey 加密。
  static Uint8List generateDataKey() => _secureRandom(_keyLength);

  /// 生成随机 16 字节 salt（用于 PBKDF2 或 vault_id）
  static Uint8List generateSalt() => _secureRandom(_saltLength);

  /// 生成随机 12 字节 nonce（用于 AES-GCM）
  static Uint8List generateNonce() => _secureRandom(_nonceLength);

  // ──────────────────────────────────────────────
  // dataKey wrap / unwrap（用 MK 加密 dataKey）
  // ──────────────────────────────────────────────

  /// 用 MK 包装 dataKey（用于持久化到 manifest）
  ///
  /// 改密码时：旧 MK 解开 dataKey → 新 MK 重新 wrap。
  /// 这是一个 O(1) 操作，只加密 32 字节的 dataKey。
  /// 返回信封：nonce(12) ‖ ciphertext(32) ‖ tag(16) = 60 字节
  static Future<Uint8List> wrapDataKey(
    Uint8List masterKey,
    Uint8List dataKey,
  ) async {
    // dataKey 的 AAD 为固定字符串，确保 dataKey 信封不可互换
    final aad = Uint8List.fromList(utf8.encode('datakey-wrap'));
    return _aesGcmEncrypt(
        masterKey, _secureRandom(_nonceLength), aad, dataKey);
  }

  /// 用 MK 解开 dataKey（从 manifest 中恢复 dataKey）
  ///
  /// [wrappedDataKey] 是 wrapDataKey 的返回值。
  /// 如果 MK 不正确（密码错误），GCM tag 验证会抛出异常。
  static Future<Uint8List> unwrapDataKey(
    Uint8List masterKey,
    Uint8List wrappedDataKey,
  ) async {
    final aad = Uint8List.fromList(utf8.encode('datakey-wrap'));
    return _aesGcmDecrypt(masterKey, aad, wrappedDataKey);
  }

  // ──────────────────────────────────────────────
  // 笔记内容加密/解密（用 dataKey）
  // ──────────────────────────────────────────────

  /// 构造信封的 AAD
  ///
  /// **blob 纯化（v4，epoch 消除设计）**：blob 信封是纯数据，AAD 恒为裸
  /// `id`（内容 hash / 固定常量），**不再携带 epoch**。解密只问「dataKey 对
  /// 不对」——能解开即当前 key，解不开即「非当前 key 或损坏」，epoch 不参与
  /// 判定。历史教训：epoch 进 AAD（`'$epoch|$id'`）会让「同 key 解不开」的
  /// 假性失败成为翻转事故的放大器（见 docs/epoch-elimination-design-20260801.md
  /// §4.2）。
  ///
  /// 各类信封的 AAD：
  ///   - blob：内容 hash（v2 起的内容寻址格式，回归 07-29 原始设计）
  ///   - manifest items / journal / 本地库字段：固定常量（`manifest-items` /
  ///     `journal-aad` / uuid），与 blob 协议无关
  static Uint8List _blobAad(String id) {
    return Uint8List.fromList(utf8.encode(id));
  }

  /// 用 dataKey 加密笔记内容，返回信封二进制
  ///
  /// [id] 笔记内容 hash（内容寻址，v2 起），作为 AAD 的一部分。
  /// [plaintext] 笔记明文（UTF-8 编码后的字节）
  /// 返回信封：nonce(12) ‖ ciphertext ‖ tag(16)
  static Future<Uint8List> seal(
    Uint8List dataKey,
    String id,
    Uint8List plaintext, {
    Uint8List? nonce,
  }) async {
    final aad = _blobAad(id);
    return _aesGcmEncrypt(
        dataKey, nonce ?? _secureRandom(_nonceLength), aad, plaintext);
  }

  /// 用 dataKey 解密笔记信封，返回明文字节
  ///
  /// [id] 必须与加密时一致（内容 hash）。
  static Future<Uint8List> open(
    Uint8List dataKey,
    String id,
    Uint8List envelope,
  ) async {
    final aad = _blobAad(id);
    return _aesGcmDecrypt(dataKey, aad, envelope);
  }

  // ──────────────────────────────────────────────
  // 备份加解密（B-KEY，读写 snbak 备份文件）
  // ──────────────────────────────────────────────

  /// 派生备份密钥 B-KEY（按备份文件头 KDF 参数派发）
  ///
  /// 恒等封装 [deriveKeyFromKdf]：与登录 MK 同族，但 salt 为每份备份独立
  /// 随机生成的备份 salt（与登录 keyring 的 salt 无关），实现导入端只需
  /// 口令 + 文件头参数即可跨设备派生同一 B-KEY。
  ///
  /// [password] 必须是「登录口令原文」或用户自定义备份口令——不是 MK 也不是
  /// 其它派生值，否则跨设备派生出的 B-KEY 不一致，备份解不开。
  /// [kdf] 来自备份文件头的 KDF 参数（algorithm/salt/iterations/memory/parallelism）。
  static Future<Uint8List> deriveBackupKey(
    String password, {
    required KdfParams kdf,
  }) {
    return deriveKeyFromKdf(password, kdf: kdf);
  }

  /// 加密整份备份明文（一次性），返回 AES-256-GCM 信封字节
  ///
  /// 信封格式：nonce(12) ‖ ciphertext ‖ tag(16)。
  /// [aadHeader] 仅作域分隔符（默认 [kBackupAad]），不绑定任何明文长度/头字段
  /// ——防篡改由 GCM tag 天然覆盖，本方案只聚焦防暴力破解。
  static Future<Uint8List> sealBackup(
    Uint8List backupKey,
    Uint8List plaintext, {
    Uint8List? nonce,
    String aadHeader = kBackupAad,
  }) async {
    final aad = Uint8List.fromList(utf8.encode(aadHeader));
    return _aesGcmEncrypt(
      backupKey,
      nonce ?? _secureRandom(_nonceLength),
      aad,
      plaintext,
    );
  }

  /// 解密整份备份信封（一次性），返回明文字节
  ///
  /// 密码 / salt / iterations 不符时 GCM tag 验证失败，抛出
  /// [SyncDecryptionException]（由 _aesGcmDecrypt 底层包装）。
  static Future<Uint8List> openBackup(
    Uint8List backupKey,
    Uint8List envelope, {
    String aadHeader = kBackupAad,
  }) async {
    final aad = Uint8List.fromList(utf8.encode(aadHeader));
    return _aesGcmDecrypt(backupKey, aad, envelope);
  }

  // ──────────────────────────────────────────────
  // 字符串哈希（通用原语）
  // ──────────────────────────────────────────────

  /// [sha256Hex] 的字符串输入形式：SHA-256(utf8(text)) 的十六进制。
  ///
  /// **命名域说明**（曾用名 `contentHash`，与 `SafeNote.contentHash` 字段和
  /// DB 列 `content_hash` 重名但语义不同，已于 2026-08-10 更名消歧）：
  /// 本函数只是通用哈希原语，调用方自行决定喂什么。blob 的身份（文件名 +
  /// GCM AAD）**只**由 `SafeNote.computeHash`（`title\ndescription` 文本）
  /// 定义，与 `SafeNote.toContentBytes` 的 JSON payload 字节哈希不是同一个
  /// 值——身份与 payload 编码刻意解耦，这样 payload 加字段不会让已寻址的
  /// blob 失效。不要用本函数对 payload 字节求哈希去当 blob id。
  /// 不变量由 `packages/core/test/sync/blob_addressing_test.dart` 锁定。
  static String hashString(String text) =>
      sha256Hex(Uint8List.fromList(utf8.encode(text)));

  // ──────────────────────────────────────────────
  // AES-256-GCM 内部实现（cryptography_flutter）
  // ──────────────────────────────────────────────

  /// AES-256-GCM 实例（with256bits：nonce=12B、mac=16B，与信封格式一致）
  ///
  /// `FlutterCryptography.enable()` 后各平台自动选择：
  ///   - Android/iOS/macOS → FlutterAesGcm（平台原生，硬件加速）
  ///   - Windows/Linux → BackgroundAesGcm（后台 isolate）
  ///   - 测试/默认 → DartAesGcm（纯 Dart，与 pointycastle 互操作）
  static final AesGcm _gcm = AesGcm.with256bits();

  /// AES-256-GCM 加密
  ///
  /// 返回信封：nonce(12) ‖ ciphertext ‖ tag(16)
  static Future<Uint8List> _aesGcmEncrypt(
    Uint8List key,
    Uint8List nonce,
    Uint8List aad,
    Uint8List plaintext,
  ) async {
    final box = await _gcm.encrypt(
      plaintext,
      secretKey: SecretKey(key),
      nonce: nonce,
      aad: aad,
    );
    // 拼接信封：nonce 在前，便于解密时分离（与旧 pointycastle 格式一致）
    return Uint8List.fromList(box.nonce + box.cipherText + box.mac.bytes);
  }

  /// AES-256-GCM 解密
  ///
  /// 输入信封：nonce(12) ‖ ciphertext ‖ tag(16)
  /// 如果密钥错误或 AAD 不匹配，GCM tag 验证失败会抛出 [SyncDecryptionException]。
  ///
  /// 注意：cryptography 的校验失败抛 `SecretBoxAuthenticationError`，
  /// 这里在底层捕获并包装为 `SyncDecryptionException`（实现 Exception），
  /// 让上层能用 `on SyncDecryptionException` 精确捕获。
  static Future<Uint8List> _aesGcmDecrypt(
    Uint8List key,
    Uint8List aad,
    Uint8List envelope,
  ) async {
    // 评审 #9：信封长度校验必须在任何 sublist / SecretBox 构造之前，
    // 否则过短输入会抛裸 RangeError（Error 而非 Exception），
    // 上层 `on SyncDecryptionException` 无法捕获，被误判为"未预期崩溃"。
    // 最小合法长度 = nonce(12) + tag(16) = 28。
    final minEnvelopeLength = _nonceLength + _tagLength;
    if (envelope.length < minEnvelopeLength) {
      Log.crypto.w('AES-GCM 解密失败: 信封长度不足 '
          '(${envelope.length} < $minEnvelopeLength)');
      throw SyncDecryptionException(
        '信封长度不足（${envelope.length} < $minEnvelopeLength）',
        aadId: aad.length <= 32 ? utf8.decode(aad, allowMalformed: true) : null,
      );
    }
    // 分离 nonce 和 ciphertext+tag
    final nonce = envelope.sublist(0, _nonceLength);
    final ctAndTag = envelope.sublist(_nonceLength);
    final box = SecretBox(
      ctAndTag.sublist(0, ctAndTag.length - _tagLength),
      nonce: nonce,
      mac: Mac(ctAndTag.sublist(ctAndTag.length - _tagLength)),
    );
    try {
      final plain = await _gcm.decrypt(box, secretKey: SecretKey(key), aad: aad);
      return Uint8List.fromList(plain);
    } on Object catch (e) {
      // 密钥不匹配/AAD 不符/数据损坏等，统一包装为可捕获的异常。
      // 用 debug 级别：批量解密失败时由上层聚合成 warning/error，此处避免刷屏
      Log.crypto.d('AES-GCM 解密失败: 信封 ${envelope.length} 字节, '
          'AAD ${aad.length} 字节 (密钥不匹配/AAD 不符/数据损坏): $e');
      throw wrapDecryptionError(e);
    }
  }

  // ──────────────────────────────────────────────
  // 安全随机数生成
  // ──────────────────────────────────────────────

  /// 密码学安全的随机数生成器
  ///
  /// 使用 Dart 内置的 Random.secure()，在所有 Flutter 平台上
  /// 底层调用平台原生 CSPRNG（/dev/urandom 或 BCryptGenRandom）。
  static Uint8List _secureRandom(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }

  // ──────────────────────────────────────────────
  // 常数时间比较
  // ──────────────────────────────────────────────

  /// 常数时间比较两个字节序列是否相等（评审 #16 统一入口）
  ///
  /// 用于比较 dataKey / MK，避免因第一处不匹配即可提前返回的时序攻击。
  /// 长度不同时直接返回 false——各比较对象（dataKey 等）长度固定，
  /// 长度信息本身不构成可用的侧信道。
  ///
  /// 来源：原 `sync_engine._bytesEqual`（常数时间）与 `keyring._sameKey`
  /// （非常数时间）语义重复，统一收敛为这里的唯一定义。
  static bool bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
