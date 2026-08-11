// 备份文件 v1 格式的统一编解码（明文 plaintext + 加密 snbak）。
//
// 设计文档：docs/backup-encryption-design-20260810.md §4 / §8
//   - 明文：{ records: [...], recordHandlerHash: "plaintext-v1", total: N }
//   - 加密（snbak v1）：{ format, formatVersion, enc, salt, createdAt,
//     total, payload }，payload 为 AES-GCM 信封，解密后即明文格式的
//     `records` 值（两格式的笔记内容零差异）。
//   - 密码是「登录口令原文」或用户自定义备份口令，KDF 参数随每份文件头
//     独立写入，导入端按文件参数派生 B-KEY。
//
// 本编解码逻辑同时被 App（lib/models/file_handler.dart）与 CLI
// （bin/cli_commands.dart）复用，保证两边导出/导入互操作。

// Dart 原生导入
import 'dart:convert';
import 'dart:typed_data';

// 项目导入
import 'package:core/src/models/parse_import.dart';
import 'package:core/src/crypto/crypto.dart';
import 'package:core/src/sync/sync_models.dart';

/// 明文备份格式的 `recordHandlerHash` 标识
const String kPlaintextBackupHandler = 'plaintext-v1';

/// 解析后的备份文件（App / CLI 导入分流用）
sealed class BackupFile {
  /// 备份内笔记条数（明文为 records 长度；加密为文件头 total）
  final int total;

  BackupFile(this.total);
}

/// 明文备份文件：records 为解析后的笔记 JSON 数组
class BackupFilePlaintext extends BackupFile {
  final List<dynamic> records;
  BackupFilePlaintext(this.records) : super(records.length);
}

/// 加密备份文件：仅含文件头，密文导入时再按密码解密
class BackupFileEncrypted extends BackupFile {
  final BackupHeader header;
  BackupFileEncrypted(this.header) : super(header.total);
}

/// 备份文件编解码工具（v1：明文 + 加密 snbak）
class BackupFileCodec {
  BackupFileCodec._();

  /// 组装明文备份文件内容（JSON 字符串，与旧格式全兼容）
  ///
  /// [records] 为笔记数据数组（SafeNote.toJson()），`total` 直接用数组长度
  /// （修复原 `'{'.allMatches` 计数 bug）。
  static String encodePlaintext(List<Map<String, dynamic>> records) {
    return jsonEncode({
      'records': records,
      'recordHandlerHash': kPlaintextBackupHandler,
      'total': records.length,
    });
  }

  /// 组装加密备份文件内容（JSON 字符串，snbak v1）
  ///
  /// [password] 是「登录口令原文」或用户自定义备份口令；每份导出随机生成
  /// 独立 salt，密钥派生与密文封装见 crypto.dart（B-KEY）。
  /// [kdf] 自定义 KDF 参数（用于测试加速，如小内存 + 低迭代）；为 null 时
  /// 用当前 Argon2id 默认参数（[kBackupKdfAlgorithm] / [kArgon2idMemoryKib] /
  /// [kArgon2idIterations] / [kArgon2idParallelism]）。传入的 [kdf] 的 salt
  /// 会被忽略——salt 始终由本方法随机生成并写入文件头，保证每份备份独立。
  /// [iterations] 仅在使用默认 KDF 时生效（覆盖 Argon2id 的 t）。
  static Future<String> encodeEncrypted({
    required String password,
    required List<Map<String, dynamic>> records,
    KdfParams? kdf,
    int iterations = kArgon2idIterations,
  }) async {
    final salt = SyncCrypto.generateSalt();
    final effectiveKdf = kdf == null
        ? KdfParams(
            algorithm: kBackupKdfAlgorithm,
            salt: base64Encode(salt),
            iterations: iterations,
            memoryKiB: kArgon2idMemoryKib,
            parallelism: kArgon2idParallelism,
          )
        : KdfParams(
            algorithm: kdf.algorithm,
            salt: base64Encode(salt),
            iterations: kdf.iterations,
            memoryKiB: kdf.memoryKiB,
            parallelism: kdf.parallelism,
          );
    final backupKey = await SyncCrypto.deriveBackupKey(password, kdf: effectiveKdf);
    final plaintext = Uint8List.fromList(utf8.encode(jsonEncode(records)));
    final payload = await SyncCrypto.sealBackup(backupKey, plaintext);

    return jsonEncode({
      'format': kBackupFormat,
      'formatVersion': kBackupFormatVersion,
      'enc': {
        'algorithm': kBackupEncAlgorithm,
        'kdf': {
          'algorithm': effectiveKdf.algorithm,
          'iterations': effectiveKdf.iterations,
          if (effectiveKdf.memoryKiB != null) 'memoryKiB': effectiveKdf.memoryKiB,
          if (effectiveKdf.parallelism != null) 'parallelism': effectiveKdf.parallelism,
        },
      },
      'salt': base64Encode(salt),
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'total': records.length,
      'payload': base64Encode(payload),
    });
  }

  /// 解析备份文件内容并识别格式（不负责解密）
  ///
  /// - 顶层有 `format == "snbak"` → [BackupFileEncrypted]（加密导入）
  /// - 顶层为 `records` 根键且 `recordHandlerHash == "plaintext-v1"`
  ///   → [BackupFilePlaintext]（明文导入，无密码）
  /// - 其它 → [FormatException]
  static BackupFile parse(String content) {
    final Object? decoded;
    try {
      decoded = jsonDecode(content);
    } on FormatException {
      throw const FormatException('备份文件不是有效的 JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('备份文件格式错误：顶层不是对象');
    }

    if (decoded['format'] == kBackupFormat) {
      return BackupFileEncrypted(BackupHeader.fromJson(decoded));
    }
    if (decoded['records'] is List &&
        decoded['recordHandlerHash'] == kPlaintextBackupHandler) {
      return BackupFilePlaintext(decoded['records'] as List<dynamic>);
    }
    throw const FormatException('无法识别的备份文件格式');
  }

  /// 解密加密备份文件 → 笔记数据数组
  ///
  /// 密码 / salt / iterations 不符时抛 [SyncDecryptionException]
  /// （由 crypto._aesGcmDecrypt 底层包装），调用方根据它区分
  /// 「密码错误/文件损坏」与其它失败。
  static Future<List<dynamic>> decryptEncrypted(
    BackupFileEncrypted file,
    String password,
  ) async {
    final header = file.header;
    final backupKey = await SyncCrypto.deriveBackupKey(
      password,
      kdf: header.kdfParams,
    );
    final plaintext = await SyncCrypto.openBackup(backupKey, header.payload);
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(plaintext));
    } on FormatException {
      throw const FormatException('备份 payload 解密后不是有效的 JSON');
    }
    if (decoded is! List) {
      throw const FormatException('备份 payload 解密后不是数组');
    }
    return decoded;
  }
}