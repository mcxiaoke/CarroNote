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
 */

// Dart 原生导入
import 'dart:convert';
import 'dart:math' show Random;
import 'dart:typed_data';

// Flutter 导入
import 'package:flutter/foundation.dart' show compute;

// 第三方加密库
import 'package:crypto/crypto.dart' show sha256;
// pointycastle 的 export.dart 导出全部加密原语：
// AESEngine / GCMBlockCipher / PBKDF2KeyDerivator / Pbkdf2Parameters /
// HMac / SHA256Digest / AEADParameters / KeyParameter / FortunaRandom
import 'package:pointycastle/export.dart';

// 项目导入
import 'package:safenotes/sync/sync_error.dart';
import 'package:safenotes/utils/app_logger.dart';

// 信封各部分的固定长度
const int _nonceLength = 12; // AES-GCM 推荐 12 字节 nonce
const int _tagLength = 16; // AES-GCM 认证标签 16 字节
const int _keyLength = 32; // AES-256 密钥 32 字节
const int _saltLength = 16; // PBKDF2 salt 16 字节

/// PBKDF2 迭代次数（200,000 次）
///
/// 选型依据：
///   - OWASP 2023 推荐 600,000 次，但实测在手机端纯 Dart 实现耗时 4-5 秒，
///     严重影响登录体验。
///   - 200,000 次在手机端约 1-1.5 秒，配合 Isolate 后台线程 UI 不卡顿。
///   - 安全性：RTX 4090 约 6,000 H/s，8 位混合密码理论破解需 ~1,153 年。
///   - 个人笔记场景无需对抗 GPU 集群攻击，需要高强度保护的用户应设置强密码。
///   - 配合 Isolate 后台派生，UI 线程不阻塞。
///
/// 公开为常量供 manifest header 写入 KDF 参数（算法透明性）。
const int kPbkdf2Iterations = 200000;

/// per-vault 随机 salt 长度（字节）
///
/// 每个 keyring 创建时生成独立的随机 salt，写入 manifest header。
/// 相同密码 + 不同 salt → 不同 MK，跨用户预计算彩虹表直接失效。
/// 多端一致性：salt 随 manifest header 传播，新设备按 header 中的 salt 派生 MK。
const int kSaltLength = 16;

/// MK 派生算法名称（写入 manifest header 供未来算法迁移）
const String kMkKdfAlgorithm = 'PBKDF2-HMAC-SHA256';

/// dataKey 包装算法名称（写入 manifest header 供未来算法迁移）
const String kDataKeyWrapAlgorithm = 'AES-256-GCM';

/// 同步加密工具类
///
/// 所有方法均为静态，无状态，可在任意线程调用。
/// 随机数源使用 FortunaRandom（密码学安全）。
class SyncCrypto {
  SyncCrypto._();

  // ──────────────────────────────────────────────
  // 密钥派生
  // ──────────────────────────────────────────────

  /// 用 PBKDF2-HMAC-SHA256 从用户密码派生主密钥 MK
  ///
  /// [password] 用户输入的明文密码
  /// [salt] per-vault 随机 salt（必填，从 manifest header 或本地 meta 读取）
  /// 返回 32 字节的 MK
  ///
  /// 多端一致性关键：相同密码 + 相同 salt → 相同 MK。
  /// salt 随 manifest header 传播，新设备按 header 中的 salt 派生 MK。
  static Uint8List deriveMasterKey(
    String password, {
    required Uint8List salt,
    int iterations = kPbkdf2Iterations,
  }) {
    final pbkdf2 = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64));
    pbkdf2.init(Pbkdf2Parameters(salt, iterations, _keyLength));
    return pbkdf2.process(Uint8List.fromList(utf8.encode(password)));
  }

  /// 异步派生 MK（后台 Isolate 执行，不阻塞 UI 线程）
  ///
  /// 参数与 [deriveMasterKey] 一致，但通过 [compute] 在独立 Isolate 中执行。
  /// 用于登录/解锁/改密码等 UI 敏感场景。
  ///
  /// 注意：Isolate 间数据通过 SendPort 传递，参数和返回值都会被复制，
  /// 但 MK 只有 32 字节，复制开销可忽略。
  static Future<Uint8List> deriveMasterKeyAsync(
    String password, {
    required Uint8List salt,
    int iterations = kPbkdf2Iterations,
  }) async {
    // KDF 是低频高耗时操作（1-2 秒），记录耗时便于定位登录卡顿
    final sw = Stopwatch()..start();
    Log.crypto.d('开始派生主密钥 MK: 算法=$kMkKdfAlgorithm 迭代=$iterations '
        'salt=${salt.length}字节 (后台 Isolate)');
    final result = await compute(
      _deriveMasterKeyIsolate,
      _DeriveParams(password, salt, iterations),
    );
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
    return sha256.convert(masterKey).toString();
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
    return sha256.convert(dataKey).toString();
  }

  /// Isolate 入口函数：执行 PBKDF2 派生
  ///
  /// 必须是顶层函数或静态方法，不能捕获外部状态。
  static Uint8List _deriveMasterKeyIsolate(_DeriveParams params) {
    final pbkdf2 = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64));
    pbkdf2.init(Pbkdf2Parameters(params.salt, params.iterations, _keyLength));
    return pbkdf2.process(Uint8List.fromList(utf8.encode(params.password)));
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
  static Uint8List wrapDataKey(Uint8List masterKey, Uint8List dataKey) {
    // dataKey 的 AAD 为固定字符串，确保 dataKey 信封不可互换
    final aad = Uint8List.fromList(utf8.encode('datakey-wrap'));
    return _aesGcmEncrypt(masterKey, _secureRandom(_nonceLength), aad, dataKey);
  }

  /// 用 MK 解开 dataKey（从 manifest 中恢复 dataKey）
  ///
  /// [wrappedDataKey] 是 wrapDataKey 的返回值。
  /// 如果 MK 不正确（密码错误），GCM tag 验证会抛出异常。
  static Uint8List unwrapDataKey(Uint8List masterKey, Uint8List wrappedDataKey) {
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
  static Uint8List seal(
    Uint8List dataKey,
    String id,
    Uint8List plaintext, {
    Uint8List? nonce,
  }) {
    final aad = _blobAad(id);
    return _aesGcmEncrypt(
        dataKey, nonce ?? _secureRandom(_nonceLength), aad, plaintext);
  }

  /// 用 dataKey 解密笔记信封，返回明文字节
  ///
  /// [id] 必须与加密时一致（内容 hash）。
  static Uint8List open(
    Uint8List dataKey,
    String id,
    Uint8List envelope,
  ) {
    final aad = _blobAad(id);
    return _aesGcmDecrypt(dataKey, aad, envelope);
  }

  // ──────────────────────────────────────────────
  // 内容哈希（用于 manifest 比对和 blob 寻址）
  // ──────────────────────────────────────────────

  /// 计算明文内容的 SHA-256 哈希（十六进制字符串）
  ///
  /// 用于：
  /// 1. manifest 中记录每条笔记的 hash，比对本地/远端是否一致
  /// 2. blob 文件名/键名，实现内容寻址和天然去重
  /// 相同明文必定产生相同 hash，与 nonce 无关。
  static String contentHash(Uint8List plaintext) =>
      sha256.convert(plaintext).toString();

  /// 计算 SHA-256 哈希的简化别名（字符串输入）
  static String hashString(String text) =>
      contentHash(Uint8List.fromList(utf8.encode(text)));

  // ──────────────────────────────────────────────
  // AES-256-GCM 内部实现
  // ──────────────────────────────────────────────

  /// AES-256-GCM 加密
  ///
  /// 返回信封：nonce(12) ‖ ciphertext ‖ tag(16)
  /// pointycastle 的 GCMBlockCipher.process 返回 ciphertext+tag 拼接
  static Uint8List _aesGcmEncrypt(
    Uint8List key,
    Uint8List nonce,
    Uint8List aad,
    Uint8List plaintext,
  ) {
    final cipher = GCMBlockCipher(AESEngine());
    cipher.init(
      true,
      AEADParameters(KeyParameter(key), _tagLength * 8, nonce, aad),
    );
    final ctAndTag = cipher.process(plaintext);
    // 拼接信封：nonce 在前，便于解密时分离
    return Uint8List.fromList(nonce + ctAndTag);
  }

  /// AES-256-GCM 解密
  ///
  /// 输入信封：nonce(12) ‖ ciphertext ‖ tag(16)
  /// 如果密钥错误或 AAD 不匹配，GCM tag 验证失败会抛出 [SyncDecryptionException]。
  ///
  /// 注意：pointycastle 的 `InvalidTag` 继承自 `Error` 而非 `Exception`，
  /// 这里在底层捕获并包装为 `SyncDecryptionException`（实现 Exception），
  /// 让上层能用 `on SyncDecryptionException` 精确捕获，不再需要 `on Object` 兜底。
  static Uint8List _aesGcmDecrypt(
    Uint8List key,
    Uint8List aad,
    Uint8List envelope,
  ) {
    // 分离 nonce 和 ciphertext+tag
    final nonce = envelope.sublist(0, _nonceLength);
    final ctAndTag = envelope.sublist(_nonceLength);
    final cipher = GCMBlockCipher(AESEngine());
    cipher.init(
      false,
      AEADParameters(KeyParameter(key), _tagLength * 8, nonce, aad),
    );
    try {
      return cipher.process(ctAndTag);
    } on Object catch (e) {
      // pointycastle 的 InvalidTag（密钥错误/AAD 不匹配/数据篡改）
      // 包装为 Exception 子类，上层可用 on SyncDecryptionException 精确捕获。
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
}

/// Isolate 参数载体（必须可序列化以便跨 Isolate 传递）
///
/// 用于 [SyncCrypto.deriveMasterKeyAsync] 将 password/salt/iterations
/// 打包传递给后台 Isolate。
class _DeriveParams {
  final String password;
  final Uint8List salt;
  final int iterations;

  const _DeriveParams(this.password, this.salt, this.iterations);
}
