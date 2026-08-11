/*
* Copyright (C) Keshav Priyadarshi and others - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*
* You should have received a copy of the GNU General Public License v3.0 with
* this file. If not, please visit https://www.gnu.org/licenses/gpl-3.0.html
*
* See https://safenotes.dev for support or download.
*/

// Project imports:
import 'dart:convert';
import 'dart:typed_data';

import 'package:core/src/crypto/crypto.dart';
import 'package:core/src/models/safenote.dart';
import 'package:core/src/sync/sync_models.dart';

class ImportParser {
  final List<SafeNote> parsedNotes;
  final String importHandlerPhrase;
  final int totalNotes;
  final bool isNoteCountMissmatched;

  ImportParser({
    required this.parsedNotes,
    required this.importHandlerPhrase,
    required this.totalNotes,
    required this.isNoteCountMissmatched,
  });

  factory ImportParser.fromJson(Map<String, dynamic> json) {
    Iterable list = json['records'];
    List<SafeNote> notes = list.map((i) => SafeNote.fromJson(i)).toList();

    return ImportParser(
      parsedNotes: notes,
      importHandlerPhrase: json['recordHandlerHash'] as String,
      totalNotes: notes.length,
      isNoteCountMissmatched: json['total'] as int != notes.length,
    );
  }

  /// 从「解密后的裸数组」构建解析结果（加密 snbak 与明文 records 共用）
  ///
  /// [records] 是备份中笔记 JSON 数组（字段与 [SafeNote.toJson] 一致，
  /// 见 docs/backup-encryption-design-20260810.md §4.1）。
  /// [expectedTotal] 来自文件头 `total`（加密）或明文 `total`；与解析结果
  /// 不一致仅警告不阻断（解析结果为准）。缺省则不做比对。
  factory ImportParser.fromDecryptedPlaintext(
    List<dynamic> records, {
    int? expectedTotal,
  }) {
    List<SafeNote> notes =
        records.map((i) => SafeNote.fromJson(i)).toList();
    return ImportParser(
      parsedNotes: notes,
      importHandlerPhrase: 'plaintext-v1',
      totalNotes: notes.length,
      isNoteCountMissmatched:
          expectedTotal != null && expectedTotal != notes.length,
    );
  }

  List<SafeNote> getAllNotes() {
    return parsedNotes;
  }

  int getTotalNotes() {
    return totalNotes;
  }
}

/// 加密备份文件头模型（snbak v1，见 docs/backup-encryption-design-20260810.md §4）
///
/// 只负责**解析并校验文件头**，不负责解密（解密由调用方先按头参数派生
/// B-KEY 再 `SyncCrypto.openBackup`）。文件头字段全部可读：用于定位、校验
/// 与派生密钥；只有笔记内容在 `payload` 里，外层文件不含任何笔记明文。
class BackupHeader {
  /// 格式标识，恒为 [kBackupFormat]（"snbak"）
  final String format;

  /// 格式版本（当前 [kBackupFormatVersion] = 1）
  final int formatVersion;

  /// 对称加密算法（"AES-256-GCM"）
  final String encAlgorithm;

  /// KDF 算法（"ARGON2ID" 或 "PBKDF2-HMAC-SHA256"）
  final String kdfAlgorithm;

  /// KDF 迭代次数（PBKDF2 的 iterations；Argon2id 的 t）
  final int iterations;

  /// Argon2id 内存占用（KiB）。PBKDF2 备份为 null。
  final int? memoryKiB;

  /// Argon2id 并行度（lane 数）。PBKDF2 备份为 null。
  final int? parallelism;

  /// 备份 salt（16B，每份导出随机）
  final Uint8List salt;

  /// 导出时刻（Unix 毫秒）
  final int createdAt;

  /// 笔记条数（明文 JSON 数组长度）
  final int total;

  /// base64 解码后的 AES-GCM 信封：nonce(12) ‖ ct ‖ tag(16)
  final Uint8List payload;

  BackupHeader({
    required this.format,
    required this.formatVersion,
    required this.encAlgorithm,
    required this.kdfAlgorithm,
    required this.iterations,
    this.memoryKiB,
    this.parallelism,
    required this.salt,
    required this.createdAt,
    required this.total,
    required this.payload,
  });

  /// 解析并校验文件头；格式损坏/算法不支持/版本过高抛 [FormatException]
  factory BackupHeader.fromJson(Map<String, dynamic> json) {
    // format 判断放外层（BackupFileCodec.parse）：这里只校验字段合法性
    final format = json['format'] as String?;
    if (format != kBackupFormat) {
      throw const FormatException('无法识别的备份文件格式');
    }

    final formatVersion = json['formatVersion'] as int?;
    if (formatVersion == null || formatVersion > kBackupFormatVersion) {
      throw FormatException('备份格式版本过高（$formatVersion），请升级应用');
    }
    if (formatVersion < 1) {
      throw FormatException('备份格式版本过旧（$formatVersion），无法导入');
    }

    final enc = json['enc'] as Map<String, dynamic>?;
    final kdf = enc?['kdf'] as Map<String, dynamic>?;
    final encAlgorithm = enc?['algorithm'] as String?;
    final kdfAlgorithm = kdf?['algorithm'] as String?;
    if (encAlgorithm != kBackupEncAlgorithm ||
        !const {kPbkdf2Algorithm, kArgon2idAlgorithm}.contains(kdfAlgorithm)) {
      throw FormatException('不支持的备份加密算法'
          '（enc=$encAlgorithm kdf=$kdfAlgorithm）');
    }

    final iterations = kdf?['iterations'] as int?;
    if (iterations == null || iterations <= 0) {
      throw const FormatException('备份 KDF 迭代次数非法');
    }

    // Argon2id 参数（PBKDF2 备份无此字段，为 null）
    final memoryKiB = kdf?['memoryKiB'] as int?;
    final parallelism = kdf?['parallelism'] as int?;

    final saltB64 = json['salt'] as String?;
    final payloadB64 = json['payload'] as String?;
    if (saltB64 == null || payloadB64 == null) {
      throw const FormatException('备份文件头缺少 salt/payload 字段');
    }

    final Uint8List salt;
    final Uint8List payload;
    try {
      salt = base64Decode(saltB64);
      payload = base64Decode(payloadB64);
    } on FormatException {
      throw const FormatException('备份文件头 base64 编码非法');
    }
    if (salt.length != kSaltLength) {
      throw FormatException('备份 salt 长度非法（${salt.length} 字节）');
    }

    return BackupHeader(
      format: format!,
      formatVersion: formatVersion,
      encAlgorithm: encAlgorithm!,
      kdfAlgorithm: kdfAlgorithm!,
      iterations: iterations,
      memoryKiB: memoryKiB,
      parallelism: parallelism,
      salt: salt,
      createdAt: json['createdAt'] as int? ?? 0,
      total: json['total'] as int? ?? 0,
      payload: payload,
    );
  }

  /// 把文件头字段组装成 [KdfParams]，供 [SyncCrypto.deriveBackupKey] 按文件
  /// 参数派发（Argon2id 用 memory/parallelism，PBKDF2 忽略）。salt 重新
  /// base64 编码为 KdfParams 所需的字符串形式。
  KdfParams get kdfParams => KdfParams(
        algorithm: kdfAlgorithm,
        salt: base64Encode(salt),
        iterations: iterations,
        memoryKiB: memoryKiB,
        parallelism: parallelism,
      );
}
