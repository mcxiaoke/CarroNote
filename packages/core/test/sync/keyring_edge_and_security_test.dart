/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*
*/

import 'dart:convert';

import 'package:core/core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';

import 'sync_test_support.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late NotesDatabase database;

  setUp(() async {
    final db = await openDatabase(
      ':memory:',
      version: 2,
      onCreate: NotesDatabase.createDBForTesting,
    );
    NotesDatabase.setDatabaseForTesting(db);
    database = NotesDatabase.instance;
  });

  tearDown(() async {
    await database.close();
  });

  group('Keyring 顺序保护与坏数据分流', () {
    test('unlockFromRemoteManifest 密码错误或坏数据时零落盘', () async {
      final validDataKey = SyncCrypto.generateDataKey();
      final validMk = SyncCrypto.generateDataKey();
      final validEnc = base64Encode(
        await SyncCrypto.wrapDataKey(validMk, validDataKey),
      );
      final kdf = KdfParams.create(salt: SyncCrypto.generateSalt());

      // 1. 错误密码尝试从远端 manifest 解锁
      await expectLater(
        Keyring.unlockFromRemoteManifest(
          password: 'wrong-password',
          remoteVaultId: 'vault-123',
          remoteEncryptedDataKey: validEnc,
          remoteKdf: kdf,
          remoteKeyFingerprint: 'fp-1',
          remoteKeyVersion: 1,
          remoteCreatedAt: 1000,
          database: database,
        ),
        throwsA(isA<WrongPasswordException>()),
      );
      expect(
        await Keyring.isInitialized(database),
        isFalse,
        reason: '密码错误时不得写入本地数据库',
      );

      // 2. 坏 base64 字符串
      await expectLater(
        Keyring.unlockFromRemoteManifest(
          password: 'any-password',
          remoteVaultId: 'vault-123',
          remoteEncryptedDataKey: '!!!not-valid-base64!!!',
          remoteKdf: kdf,
          remoteKeyFingerprint: 'fp-1',
          remoteKeyVersion: 1,
          remoteCreatedAt: 1000,
          database: database,
        ),
        throwsA(isA<KeyringCorruptedException>()),
      );
      expect(await Keyring.isInitialized(database), isFalse);
    });

    test('KeyringLedger 损坏时的异常防御', () async {
      // 1. 写入数组型 JSON
      await database.setMeta(MetaKeys.keyring, jsonEncode([1, 2, 3]));
      expect(
        () => KeyringLedger.load(database),
        throwsA(isA<KeyringCorruptedException>()),
      );

      // 2. 写入语法损坏 JSON
      await database.setMeta(MetaKeys.keyring, '{ bad json syntax');
      expect(
        () => KeyringLedger.load(database),
        throwsA(isA<KeyringCorruptedException>()),
      );
    });
  });

  group('checkMigrationNeeded 状态矩阵', () {
    test('MK 为 null 时返回 failed (needsMigration=true, success=false)', () async {
      final keyringNoMk = makeTestKeyring(mk: null);
      final res = await keyringNoMk.checkMigrationNeeded('anyEnc');
      expect(res.needsMigration, isTrue);
      expect(res.success, isFalse);
      expect(res.error, contains('MK 未缓存'));
    });

    test('包裹字符串完全相同时 needsMigration = false', () async {
      final keyring = makeTestKeyring();
      final res = await keyring.checkMigrationNeeded(keyring.encryptedDataKey);
      expect(res.needsMigration, isFalse);
      expect(res.success, isTrue);
    });

    test('同密码不同 dataKey 时 needsMigration = true', () async {
      final localDataKey = SyncCrypto.generateDataKey();
      final remoteDataKey = SyncCrypto.generateDataKey();
      final mk = SyncCrypto.generateDataKey();
      final keyring = makeTestKeyring(dataKey: localDataKey, mk: mk);

      // 远端使用相同 mk 但不同 dataKey
      final remoteEnc = base64Encode(
        await SyncCrypto.wrapDataKey(mk, remoteDataKey),
      );
      final res = await keyring.checkMigrationNeeded(
        remoteEnc,
        remoteVaultId: 'remote-vault',
      );
      expect(res.needsMigration, isTrue);
      expect(res.success, isTrue);
      expect(res.remoteVaultId, equals('remote-vault'));
      expect(SyncCrypto.bytesEqual(res.remoteDataKey!, remoteDataKey), isTrue);
    });
  });
}
