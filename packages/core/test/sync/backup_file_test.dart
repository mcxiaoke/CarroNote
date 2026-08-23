/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

// 备份文件编解码测试（明文 plaintext-v1 + 加密 snbak v1）
//
// 验证：格式编解码往返、错误密码/篡改 salt/篡改 iterations 失败、
//       明文旧格式兼容、未知格式拒绝、版本保护、B-KEY 原语往返。
// 纯 Dart 可跑，使用低迭代（1000）加速测试。

import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:core/core.dart';

/// 测试用轻量 Argon2id 参数（128KiB, p=1）：保留较大 t 以验证头字段往返，
/// 但用极小内存保证 t=1000 也在 30s 测试超时内完成。salt 由 encodeEncrypted
/// 内部随机生成，这里给占位值即可。
KdfParams _lightBackupKdf(int iterations) => KdfParams(
  algorithm: kBackupKdfAlgorithm,
  salt: base64Encode(List.filled(16, 0)),
  iterations: iterations,
  memoryKiB: 128,
  parallelism: 1,
);

void main() {
  // 测试用的笔记 JSON 数组（与 SafeNote.toJson 字段一致）
  List<Map<String, dynamic>> sampleRecords() => [
    {
      'uuid': '11111111-1111-4111-8111-111111111111',
      'title': '标题一',
      'description': '正文一',
      'content_hash':
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'deleted': 0,
      'created_at': '2026-08-10T09:00:00.000',
      'updated_at': 1723000000000,
      'synced': 0,
      'synced_hash': null,
      'synced_deleted': 0,
    },
    {
      'uuid': '22222222-2222-4222-8222-222222222222',
      'title': '标题二',
      'description': '正文二',
      'content_hash':
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      'deleted': 1,
      'created_at': '2026-08-10T10:00:00.000',
      'updated_at': 1723001000000,
      'synced': 1,
      'synced_hash':
          'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
      'synced_deleted': 0,
    },
  ];

  const testPassword = 'test-pass-口令-123';
  const lowIterations = 2;
  const lowPbkdf2Iterations = 1000;

  group('BackupFileCodec - 明文导出 (plaintext-v1)', () {
    test('encodePlaintext → parse：records 往返一致且 total=长度', () {
      final records = sampleRecords();
      final content = BackupFileCodec.encodePlaintext(records);

      final decoded = jsonDecode(content) as Map<String, dynamic>;
      expect(decoded['recordHandlerHash'], kPlaintextBackupHandler);
      expect(decoded['total'], records.length);

      final parsed = BackupFileCodec.parse(content);
      expect(parsed, isA<BackupFilePlaintext>());
      final plain = parsed as BackupFilePlaintext;
      expect(plain.total, records.length);
      expect(plain.records, records);

      // 明文可直接经 ImportParser 消费
      final parsedImport = ImportParser.fromDecryptedPlaintext(
        plain.records,
        expectedTotal: plain.total,
      );
      expect(parsedImport.totalNotes, records.length);
      expect(parsedImport.isNoteCountMissmatched, isFalse);
      expect(parsedImport.getAllNotes().first.title, '标题一');
    });

    test('历史旧明文格式（records 根键）可识别', () {
      final oldContent = jsonEncode({
        'records': sampleRecords(),
        'recordHandlerHash': 'plaintext-v1',
        'total': 2,
      });
      final parsed = BackupFileCodec.parse(oldContent);
      expect(parsed, isA<BackupFilePlaintext>());
      expect(parsed.total, 2);
    });
  });

  group('BackupFileCodec - 加密导出 (snbak v1)', () {
    test('encodeEncrypted → parse → decryptEncrypted 往返', () async {
      final records = sampleRecords();
      final content = await BackupFileCodec.encodeEncrypted(
        password: testPassword,
        records: records,
        kdf: _lightBackupKdf(lowIterations),
      );

      final decoded = jsonDecode(content) as Map<String, dynamic>;
      expect(decoded['format'], kBackupFormat);
      expect(decoded['formatVersion'], kBackupFormatVersion);
      expect(decoded['enc']['algorithm'], kBackupEncAlgorithm);
      expect(decoded['enc']['kdf']['algorithm'], kBackupKdfAlgorithm);
      expect(decoded['enc']['kdf']['iterations'], lowIterations);
      expect(decoded['total'], records.length);
      // 密文 payload 里绝对不允许出现笔记明文
      expect(content.contains('标题一'), isFalse);
      expect(content.contains('正文一'), isFalse);

      final parsed = BackupFileCodec.parse(content);
      expect(parsed, isA<BackupFileEncrypted>());
      final encrypted = parsed as BackupFileEncrypted;
      expect(encrypted.header.salt.length, kSaltLength);
      expect(encrypted.header.iterations, lowIterations);
      expect(encrypted.header.total, records.length);

      final decrypted = await BackupFileCodec.decryptEncrypted(
        encrypted,
        testPassword,
      );
      expect(decrypted, records);

      // 解密结果可直接经 ImportParser 消费
      final parsedImport = ImportParser.fromDecryptedPlaintext(
        decrypted,
        expectedTotal: encrypted.header.total,
      );
      expect(parsedImport.totalNotes, records.length);
      expect(parsedImport.isNoteCountMissmatched, isFalse);
    });

    test('错误密码解密抛 SyncDecryptionException（不误报损坏）', () async {
      final content = await BackupFileCodec.encodeEncrypted(
        password: testPassword,
        records: sampleRecords(),
        kdf: _lightBackupKdf(lowIterations),
      );
      final encrypted = BackupFileCodec.parse(content) as BackupFileEncrypted;
      await expectLater(
        BackupFileCodec.decryptEncrypted(encrypted, 'wrong-password'),
        throwsA(isA<SyncDecryptionException>()),
      );
    });

    test('篡改文件头 salt → 派生密钥不同 → 解密失败', () async {
      final content = await BackupFileCodec.encodeEncrypted(
        password: testPassword,
        records: sampleRecords(),
        kdf: _lightBackupKdf(lowIterations),
      );
      // 篡改 salt 后仍可解析（头合法），但密钥派生结果不同必失败
      final decoded = jsonDecode(content) as Map<String, dynamic>;
      final originalSalt = decoded['salt'] as String;
      decoded['salt'] = base64Encode(List.filled(16, 0xAB));
      expect(decoded['salt'], isNot(originalSalt));
      final tampered = BackupFileCodec.parse(jsonEncode(decoded));
      await expectLater(
        BackupFileCodec.decryptEncrypted(
          tampered as BackupFileEncrypted,
          testPassword,
        ),
        throwsA(isA<SyncDecryptionException>()),
      );
    });

    test('篡改文件头 iterations → 派生密钥不同 → 解密失败', () async {
      final content = await BackupFileCodec.encodeEncrypted(
        password: testPassword,
        records: sampleRecords(),
        kdf: _lightBackupKdf(lowIterations),
      );
      final decoded = jsonDecode(content) as Map<String, dynamic>;
      ((decoded['enc'] as Map<String, dynamic>)['kdf']
              as Map<String, dynamic>)['iterations'] =
          lowIterations + 1;
      final tampered = BackupFileCodec.parse(jsonEncode(decoded));
      await expectLater(
        BackupFileCodec.decryptEncrypted(
          tampered as BackupFileEncrypted,
          testPassword,
        ),
        throwsA(isA<SyncDecryptionException>()),
      );
    });

    test('格式版本过高 → 明确报"版本过高"', () async {
      final content = await BackupFileCodec.encodeEncrypted(
        password: testPassword,
        records: sampleRecords(),
        kdf: _lightBackupKdf(lowIterations),
      );
      final decoded = jsonDecode(content) as Map<String, dynamic>;
      decoded['formatVersion'] = 99;
      expect(
        () => BackupFileCodec.parse(jsonEncode(decoded)),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('版本过高'),
          ),
        ),
      );
    });

    test('不支持的加密/免KDF 算法 → 拒绝', () async {
      final content = await BackupFileCodec.encodeEncrypted(
        password: testPassword,
        records: sampleRecords(),
        kdf: _lightBackupKdf(lowIterations),
      );
      final decoded = jsonDecode(content) as Map<String, dynamic>;
      (decoded['enc'] as Map<String, dynamic>)['algorithm'] = 'RC4';
      expect(
        () => BackupFileCodec.parse(jsonEncode(decoded)),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('BackupFileCodec - 格式识别', () {
    test('未知格式抛 FormatException', () {
      expect(
        () => BackupFileCodec.parse('{"foo": "bar"}'),
        throwsA(isA<FormatException>()),
      );
    });

    test('非法 JSON 抛 FormatException', () {
      expect(
        () => BackupFileCodec.parse('not-json-at-all{{{'),
        throwsA(isA<FormatException>()),
      );
    });

    test('顶层非对象抛 FormatException', () {
      expect(
        () => BackupFileCodec.parse('[1,2,3]'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('SyncCrypto - B-KEY 备份原语', () {
    test('sealBackup/openBackup 往返（相同 B-KEY）', () async {
      final salt = SyncCrypto.generateSalt();
      final kdf = KdfParams(
        algorithm: kPbkdf2Algorithm,
        salt: base64Encode(salt),
        iterations: lowPbkdf2Iterations,
      );
      final key1 = await SyncCrypto.deriveBackupKey(testPassword, kdf: kdf);
      final key2 = await SyncCrypto.deriveBackupKey(testPassword, kdf: kdf);
      expect(key1, equals(key2)); // 相同密码+salt → 相同 B-KEY（多端一致）

      final plaintext = Uint8List.fromList(
        utf8.encode(jsonEncode(sampleRecords())),
      );
      final envelope = await SyncCrypto.sealBackup(key1, plaintext);
      expect(envelope.length, 12 + plaintext.length + 16); // nonce‖ct‖tag

      final opened = await SyncCrypto.openBackup(key2, envelope);
      expect(utf8.decode(opened), utf8.decode(plaintext));
    });

    test('错误密码派生不同 B-KEY → openBackup 抛 SyncDecryptionException', () async {
      final salt = SyncCrypto.generateSalt();
      final kdf = KdfParams(
        algorithm: kPbkdf2Algorithm,
        salt: base64Encode(salt),
        iterations: lowPbkdf2Iterations,
      );
      final correct = await SyncCrypto.deriveBackupKey(testPassword, kdf: kdf);
      final wrong = await SyncCrypto.deriveBackupKey(
        'wrong-password',
        kdf: kdf,
      );
      final envelope = await SyncCrypto.sealBackup(
        correct,
        Uint8List.fromList(utf8.encode('secret')),
      );
      await expectLater(
        SyncCrypto.openBackup(wrong, envelope),
        throwsA(isA<SyncDecryptionException>()),
      );
    });

    test('每次导出 salt 独立 → B-KEY 不同', () async {
      final a = await SyncCrypto.deriveBackupKey(
        testPassword,
        kdf: KdfParams(
          algorithm: kPbkdf2Algorithm,
          salt: base64Encode(SyncCrypto.generateSalt()),
          iterations: lowPbkdf2Iterations,
        ),
      );
      final b = await SyncCrypto.deriveBackupKey(
        testPassword,
        kdf: KdfParams(
          algorithm: kPbkdf2Algorithm,
          salt: base64Encode(SyncCrypto.generateSalt()),
          iterations: lowPbkdf2Iterations,
        ),
      );
      expect(a, isNot(equals(b)));
    });

    test('解析超出安全限制的 KDF 参数抛 FormatException', () {
      final badPbkdf2 = jsonEncode({
        'format': kBackupFormat,
        'formatVersion': 1,
        'enc': {
          'algorithm': kBackupEncAlgorithm,
          'kdf': {
            'algorithm': kPbkdf2Algorithm,
            'iterations': 1000000, // > 600,000
          },
        },
        'salt': base64Encode(List.filled(16, 0)),
        'payload': base64Encode(List.filled(32, 0)),
        'total': 0,
      });
      expect(
        () => BackupFileCodec.parse(badPbkdf2),
        throwsA(isA<FormatException>()),
      );

      final badArgon2 = jsonEncode({
        'format': kBackupFormat,
        'formatVersion': 1,
        'enc': {
          'algorithm': kBackupEncAlgorithm,
          'kdf': {
            'algorithm': kArgon2idAlgorithm,
            'iterations': 10, // > 5
            'memoryKiB': 1024,
            'parallelism': 1,
          },
        },
        'salt': base64Encode(List.filled(16, 0)),
        'payload': base64Encode(List.filled(32, 0)),
        'total': 0,
      });
      expect(
        () => BackupFileCodec.parse(badArgon2),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
