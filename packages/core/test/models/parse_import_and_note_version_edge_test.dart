/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*
*/

import 'dart:convert';
import 'dart:typed_data';

import 'package:core/core.dart';
import 'package:test/test.dart';

void main() {
  group('BackupHeader 表驱动防御与解析测试', () {
    Map<String, dynamic> makeValidHeaderJson({
      String format = 'snbak',
      int formatVersion = 1,
      String encAlgorithm = 'AES-256-GCM',
      String kdfAlgorithm = 'ARGON2ID',
      int iterations = 3,
      int memoryKiB = 65536,
      int parallelism = 4,
      String? saltB64,
      String? payloadB64,
      int total = 10,
    }) {
      final salt = saltB64 ?? base64Encode(Uint8List(16));
      final payload = payloadB64 ?? base64Encode(Uint8List(32));
      return {
        'format': format,
        'formatVersion': formatVersion,
        'enc': {
          'algorithm': encAlgorithm,
          'kdf': {
            'algorithm': kdfAlgorithm,
            'iterations': iterations,
            if (kdfAlgorithm == 'ARGON2ID') 'memoryKiB': memoryKiB,
            if (kdfAlgorithm == 'ARGON2ID') 'parallelism': parallelism,
          },
        },
        'salt': salt,
        'payload': payload,
        'createdAt': 1700000000000,
        'total': total,
      };
    }

    test('合法 Argon2id 与 PBKDF2 备份头解析与 kdfParams 构造', () {
      // 1. Argon2id 头
      final argonJson = makeValidHeaderJson();
      final argonHeader = BackupHeader.fromJson(argonJson);
      expect(argonHeader.format, equals('snbak'));
      expect(argonHeader.formatVersion, equals(1));
      expect(argonHeader.kdfAlgorithm, equals('ARGON2ID'));
      expect(argonHeader.memoryKiB, equals(65536));
      expect(argonHeader.parallelism, equals(4));
      expect(argonHeader.total, equals(10));
      expect(argonHeader.kdfParams.algorithm, equals('ARGON2ID'));
      expect(argonHeader.kdfParams.memoryKiB, equals(65536));

      // 2. PBKDF2 头
      final pbkdf2Json = makeValidHeaderJson(
        kdfAlgorithm: 'PBKDF2-HMAC-SHA256',
        iterations: 100000,
      );
      final pbkdf2Header = BackupHeader.fromJson(pbkdf2Json);
      expect(pbkdf2Header.kdfAlgorithm, equals('PBKDF2-HMAC-SHA256'));
      expect(pbkdf2Header.iterations, equals(100000));
      expect(pbkdf2Header.kdfParams.memoryKiB, isNull);
    });

    test('格式识别错误抛 FormatException', () {
      final json = makeValidHeaderJson(format: 'invalid_format');
      expect(() => BackupHeader.fromJson(json), throwsFormatException);
    });

    test('版本过高或过低抛 FormatException', () {
      expect(
        () => BackupHeader.fromJson(makeValidHeaderJson(formatVersion: 99)),
        throwsFormatException,
      );
      expect(
        () => BackupHeader.fromJson(makeValidHeaderJson(formatVersion: 0)),
        throwsFormatException,
      );
    });

    test('不支持的加密或 KDF 算法抛 FormatException', () {
      expect(
        () =>
            BackupHeader.fromJson(makeValidHeaderJson(encAlgorithm: 'DES-CBC')),
        throwsFormatException,
      );
      expect(
        () => BackupHeader.fromJson(makeValidHeaderJson(kdfAlgorithm: 'MD5')),
        throwsFormatException,
      );
    });

    test('KDF 安全上限防护（防恶意极端参数消耗 CPU/内存）', () {
      // PBKDF2 超过 600,000
      final highPbkdf2 = makeValidHeaderJson(
        kdfAlgorithm: 'PBKDF2-HMAC-SHA256',
        iterations: 600001,
      );
      expect(() => BackupHeader.fromJson(highPbkdf2), throwsFormatException);

      // Argon2id 超过 5 iterations
      final highArgonIter = makeValidHeaderJson(iterations: 6);
      expect(() => BackupHeader.fromJson(highArgonIter), throwsFormatException);

      // Argon2id 超过 256MB 内存
      final highArgonMem = makeValidHeaderJson(memoryKiB: 256 * 1024 + 1);
      expect(() => BackupHeader.fromJson(highArgonMem), throwsFormatException);

      // Argon2id 超过 8 并行度
      final highArgonPar = makeValidHeaderJson(parallelism: 9);
      expect(() => BackupHeader.fromJson(highArgonPar), throwsFormatException);
    });

    test('坏 base64 / 长度不合规 salt 与 payload 校验', () {
      // 坏 base64
      expect(
        () =>
            BackupHeader.fromJson(makeValidHeaderJson(saltB64: '!!not_b64!!')),
        throwsFormatException,
      );

      // salt 长度不足 16 字节
      final shortSalt = base64Encode(Uint8List(8));
      expect(
        () => BackupHeader.fromJson(makeValidHeaderJson(saltB64: shortSalt)),
        throwsFormatException,
      );

      // payload 小于 28 字节 (12 nonce + 16 tag)
      final shortPayload = base64Encode(Uint8List(20));
      expect(
        () => BackupHeader.fromJson(
          makeValidHeaderJson(payloadB64: shortPayload),
        ),
        throwsFormatException,
      );
    });
  });

  group('ImportParser 解析模型测试', () {
    test('fromDecryptedPlaintext 解析明文笔记数组与总数比对', () {
      final now = DateTime.now();
      final records = [
        SafeNote(
          uuid: 'note-1',
          title: 'Title 1',
          description: 'Desc 1',
          contentHash: 'hash-1',
          deleted: false,
          createdTime: now,
          updatedAt: now.millisecondsSinceEpoch,
          synced: true,
        ).toJson(),
        SafeNote(
          uuid: 'note-2',
          title: 'Title 2',
          description: 'Desc 2',
          contentHash: 'hash-2',
          deleted: false,
          createdTime: now,
          updatedAt: now.millisecondsSinceEpoch,
          synced: true,
        ).toJson(),
      ];

      // 1. 预期总数一致
      final parser1 = ImportParser.fromDecryptedPlaintext(
        records,
        expectedTotal: 2,
      );
      expect(parser1.getTotalNotes(), equals(2));
      expect(parser1.getAllNotes().length, equals(2));
      expect(parser1.isNoteCountMissmatched, isFalse);
      expect(parser1.importHandlerPhrase, equals('plaintext-v1'));

      // 2. 预期总数不一致（警告标记）
      final parser2 = ImportParser.fromDecryptedPlaintext(
        records,
        expectedTotal: 5,
      );
      expect(parser2.getTotalNotes(), equals(2));
      expect(parser2.isNoteCountMissmatched, isTrue);
    });

    test('fromJson 解析传统备份结构', () {
      final now = DateTime.now();
      final json = {
        'recordHandlerHash': 'phrase-abc',
        'total': 1,
        'records': [
          SafeNote(
            uuid: 'note-legacy',
            title: 'Legacy Title',
            description: 'Legacy Desc',
            contentHash: 'legacy-hash',
            deleted: false,
            createdTime: now,
            updatedAt: now.millisecondsSinceEpoch,
            synced: true,
          ).toJson(),
        ],
      };

      final parser = ImportParser.fromJson(json);
      expect(parser.importHandlerPhrase, equals('phrase-abc'));
      expect(parser.getTotalNotes(), equals(1));
      expect(parser.isNoteCountMissmatched, isFalse);
      expect(parser.parsedNotes.first.uuid, equals('note-legacy'));
    });
  });

  group('NoteVersion 模型与脱敏测试', () {
    test('NoteVersion 基础字段、savedTime 与 copyWith', () {
      const version = NoteVersion(
        id: 10,
        noteUuid: 'ver-uuid-1',
        title: 'Secret Title',
        description: 'Secret Body',
        contentHash: 'hash123',
        savedAt: 1700000000000,
      );

      expect(version.id, equals(10));
      expect(version.savedTime.millisecondsSinceEpoch, equals(1700000000000));

      final updated = version.copyWith(title: 'New Title');
      expect(updated.id, equals(10));
      expect(updated.title, equals('New Title'));
      expect(updated.description, equals('Secret Body'));
    });

    test('NoteVersion toJson / fromJson 序列化往返', () {
      const version = NoteVersion(
        id: 5,
        noteUuid: 'uuid-abc',
        title: 'Title ABC',
        description: 'Body ABC',
        contentHash: 'hash-abc',
        savedAt: 123456789,
      );

      final map = version.toJson();
      expect(map[NoteVersionFields.noteUuid], equals('uuid-abc'));
      expect(map[NoteVersionFields.title], equals('Title ABC'));

      final fromMap = NoteVersion.fromJson({...map, NoteVersionFields.id: 5});
      expect(fromMap.id, equals(5));
      expect(fromMap.noteUuid, equals('uuid-abc'));
      expect(fromMap.contentHash, equals('hash-abc'));
    });

    test('NoteVersion.toString() 严格脱敏敏感内容', () {
      const version = NoteVersion(
        id: 1,
        noteUuid: 'uuid-sensitive',
        title: 'My Super Secret Note Title',
        description: 'My Super Secret Body Content',
        contentHash: 'hash-safe',
        savedAt: 123456789,
      );

      final str = version.toString();
      expect(str, contains('title=<redacted>'));
      expect(str, isNot(contains('My Super Secret Note Title')));
      expect(str, isNot(contains('My Super Secret Body Content')));
      expect(str, contains('uuid-sensitive'));
      expect(str, contains('hash-safe'));
    });
  });
}
