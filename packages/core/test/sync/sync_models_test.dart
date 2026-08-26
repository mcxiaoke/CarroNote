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
import 'package:crypto/crypto.dart' show sha256;
import 'package:test/test.dart';

void main() {
  group('ManifestCrypto - v5 容器正向与负向测试', () {
    late Uint8List dataKey;
    late Uint8List wrongDataKey;
    late Manifest sampleManifest;

    setUp(() {
      dataKey = SyncCrypto.generateDataKey();
      wrongDataKey = SyncCrypto.generateDataKey();
      sampleManifest = Manifest(
        header: ManifestHeader(
          schemaVersion: kManifestSchemaVersion,
          version: 10,
          vaultId: 'vault-uuid-1234',
          createdAt: 1700000000000,
          updatedAt: 1700001000000,
          keyFingerprint: 'mock-mk-fingerprint',
          keyVersion: 2,
          encryptedDataKey: base64Encode(Uint8List(60)..fillRange(0, 60, 0x11)),
          kdf: KdfParams.create(salt: SyncCrypto.generateSalt()),
          dataKeyWrap: 'AES-256-GCM',
          lastModifiedBy: 'device-test-1',
          dataKeyFingerprint: 'dfp-1234567890',
          dataKeyCreatedAt: 1700000000000,
          dataKeyCreatedBy: 'device-creator',
        ),
        items: {
          'note-1': const ManifestItem(
            hash:
                'abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234',
            deleted: false,
            updatedAt: 1700001000000,
            updatedBy: 'device-test-1',
            createdAt: 1700000000000,
            contentSize: 1024,
            blobKeyEpoch: 2,
            dataKeyFingerprint: 'dfp-1234567890',
            createdBy: 'device-creator',
            dataKeyCreatedAt: 1700000000000,
            dataKeyCreatedBy: 'device-creator',
          ),
          'note-2': const ManifestItem(
            hash:
                '5678ef015678ef015678ef015678ef015678ef015678ef015678ef015678ef01',
            deleted: true,
            updatedAt: 1700002000000,
            updatedBy: 'device-test-2',
            createdAt: 1700000500000,
            deletedAt: 1700002000000,
            contentSize: 0,
            blobKeyEpoch: 2,
          ),
        },
      );
    });

    test('正常序列化与反序列化 round-trip 一致', () async {
      final bytes = await ManifestCrypto.serialize(dataKey, sampleManifest);
      final restored = await ManifestCrypto.deserialize(dataKey, bytes);

      expect(restored.header.schemaVersion, equals(kManifestSchemaVersion));
      expect(restored.header.version, equals(10));
      expect(restored.header.vaultId, equals('vault-uuid-1234'));
      expect(restored.header.keyFingerprint, equals('mock-mk-fingerprint'));
      expect(restored.header.dataKeyFingerprint, equals('dfp-1234567890'));
      expect(restored.items.length, equals(2));
      expect(
        restored.items['note-1']?.hash,
        equals(sampleManifest.items['note-1']?.hash),
      );
      expect(restored.items['note-2']?.deleted, isTrue);
      expect(restored.items['note-2']?.deletedAt, equals(1700002000000));
    });

    test('空 items 容器 round-trip 返回空 items map', () async {
      final emptyItemsManifest = Manifest(
        header: sampleManifest.header,
        items: {},
      );
      final bytes = await ManifestCrypto.serialize(dataKey, emptyItemsManifest);
      final restored = await ManifestCrypto.deserialize(dataKey, bytes);

      expect(restored.items, isEmpty);
      expect(restored.header.vaultId, equals(sampleManifest.header.vaultId));
    });

    test('deserializeHeaderOnly 不需要 dataKey 且能正确解析 header', () async {
      final bytes = await ManifestCrypto.serialize(dataKey, sampleManifest);
      final headerOnly = ManifestCrypto.deserializeHeaderOnly(bytes);

      expect(
        headerOnly.schemaVersion,
        equals(sampleManifest.header.schemaVersion),
      );
      expect(headerOnly.vaultId, equals(sampleManifest.header.vaultId));
      expect(headerOnly.version, equals(sampleManifest.header.version));
      expect(
        headerOnly.keyFingerprint,
        equals(sampleManifest.header.keyFingerprint),
      );
    });

    test(
      'pubHash 校验通过但 dataKey 错误时精确抛出 ManifestKeyMismatchException',
      () async {
        final bytes = await ManifestCrypto.serialize(dataKey, sampleManifest);

        // 用 wrongDataKey 进行反序列化
        expect(
          () async => await ManifestCrypto.deserialize(wrongDataKey, bytes),
          throwsA(
            isA<ManifestKeyMismatchException>().having(
              (e) => e.cause,
              'cause is SyncDecryptionException',
              isA<SyncDecryptionException>(),
            ),
          ),
        );
      },
    );

    test('负向分支 1：输入数据过短 (< 44 字节) 抛 FormatException', () async {
      final shortBytes = Uint8List(43);
      expect(
        () => ManifestCrypto.deserializeHeaderOnly(shortBytes),
        throwsA(isA<FormatException>()),
      );
      expect(
        () async => await ManifestCrypto.deserialize(dataKey, shortBytes),
        throwsA(isA<FormatException>()),
      );
    });

    test('负向分支 2：magic 错误 抛 ManifestAuthException', () async {
      final bytes = await ManifestCrypto.serialize(dataKey, sampleManifest);
      final corrupted = Uint8List.fromList(bytes);
      corrupted[0] = corrupted[0] ^ 0xFF; // 破坏 magic 第一个字节

      expect(
        () => ManifestCrypto.deserializeHeaderOnly(corrupted),
        throwsA(
          isA<ManifestAuthException>().having(
            (e) => e.message,
            'message',
            contains('magic 不匹配'),
          ),
        ),
      );
      expect(
        () async => await ManifestCrypto.deserialize(dataKey, corrupted),
        throwsA(isA<ManifestAuthException>()),
      );
    });

    test('负向分支 3：fileVer 错误 抛 ManifestAuthException', () async {
      final bytes = await ManifestCrypto.serialize(dataKey, sampleManifest);
      final corrupted = Uint8List.fromList(bytes);
      // bytes[4..5] 是 fileVer (uint16 big-endian = 1)
      corrupted[4] = 0x00;
      corrupted[5] = 0x02; // fileVer = 2

      expect(
        () => ManifestCrypto.deserializeHeaderOnly(corrupted),
        throwsA(
          isA<ManifestAuthException>().having(
            (e) => e.message,
            'message',
            contains('不支持的容器布局版本'),
          ),
        ),
      );
    });

    test('负向分支 4：headerLen 越界 抛 ManifestAuthException', () async {
      final bytes = await ManifestCrypto.serialize(dataKey, sampleManifest);
      final corrupted = Uint8List.fromList(bytes);
      // bytes[8..11] 是 headerLen (uint32 big-endian)
      corrupted[8] = 0x7F;
      corrupted[9] = 0xFF;
      corrupted[10] = 0xFF;
      corrupted[11] = 0xFF; // headerLen 极大

      expect(
        () => ManifestCrypto.deserializeHeaderOnly(corrupted),
        throwsA(
          isA<ManifestAuthException>().having(
            (e) => e.message,
            'message',
            contains('headerLen 越界'),
          ),
        ),
      );
    });

    test('负向分支 5：pubHash 位翻转/篡改 抛 ManifestAuthException', () async {
      final bytes = await ManifestCrypto.serialize(dataKey, sampleManifest);
      final corrupted = Uint8List.fromList(bytes);
      // 破坏最后 32 字节中的某一位（pubHash）
      corrupted[corrupted.length - 1] ^= 0x01;

      expect(
        () => ManifestCrypto.deserializeHeaderOnly(corrupted),
        throwsA(
          isA<ManifestAuthException>().having(
            (e) => e.message,
            'message',
            contains('pubHash 校验失败'),
          ),
        ),
      );
      expect(
        () async => await ManifestCrypto.deserialize(dataKey, corrupted),
        throwsA(
          isA<ManifestAuthException>().having(
            (e) => e.message,
            'message',
            contains('pubHash 校验失败'),
          ),
        ),
      );
    });

    test('负向分支 5b：内容被篡改但 pubHash 未重算 抛 ManifestAuthException', () async {
      final bytes = await ManifestCrypto.serialize(dataKey, sampleManifest);
      final corrupted = Uint8List.fromList(bytes);
      // 篡改 header 区域某字节（例如第 15 个字节）
      corrupted[15] ^= 0x5A;

      expect(
        () => ManifestCrypto.deserializeHeaderOnly(corrupted),
        throwsA(
          isA<ManifestAuthException>().having(
            (e) => e.message,
            'message',
            contains('pubHash 校验失败'),
          ),
        ),
      );
    });

    test(
      '负向分支 6：固定头 schemaV 与 header.schemaVersion 不一致 抛 ManifestAuthException',
      () async {
        final bytes = await ManifestCrypto.serialize(dataKey, sampleManifest);
        final corrupted = Uint8List.fromList(bytes);
        // bytes[6..7] 是 fixedHeader 的 schemaV (uint16)
        corrupted[6] = 0x00;
        corrupted[7] = 0x04; // fixed schemaV = 4，而 header JSON 内是 5

        // 为了绕过 pubHash 校验以测试步骤 8 的 schemaVersion 一致性校验：
        // 重新计算 pubHash 赋给尾部
        final prefix = corrupted.sublist(0, corrupted.length - 32);
        final newPubHash = Uint8List.fromList(sha256.convert(prefix).bytes);
        corrupted.setRange(corrupted.length - 32, corrupted.length, newPubHash);

        expect(
          () => ManifestCrypto.deserializeHeaderOnly(corrupted),
          throwsA(
            isA<ManifestAuthException>().having(
              (e) => e.message,
              'message',
              contains('schemaVersion 不一致'),
            ),
          ),
        );
      },
    );
  });

  group('ManifestItem 模型与缺省值测试', () {
    test('完整字段 toJson 与 fromJson round-trip', () {
      const item = ManifestItem(
        hash: 'hash1234',
        deleted: true,
        updatedAt: 1700000000000,
        updatedBy: 'dev-1',
        createdAt: 1699990000000,
        deletedAt: 1700000000000,
        contentSize: 2048,
        blobKeyEpoch: 3,
        dataKeyFingerprint: 'dfp-abc',
        createdBy: 'creator-1',
        dataKeyCreatedAt: 1699990000000,
        dataKeyCreatedBy: 'creator-1',
      );

      final json = item.toJson();
      final restored = ManifestItem.fromJson(json);

      expect(restored, equals(item));
      expect(restored.hashCode, equals(item.hashCode));
      expect(restored.toString(), contains('hash=hash1234'));
      expect(restored.toString(), contains('deleted=true'));
    });

    test('fromJson 缺省字段回退与默认值', () {
      final minJson = <String, dynamic>{
        'hash': 'minhash',
        'deleted': false,
        'updatedAt': 1700000000000,
      };

      final item = ManifestItem.fromJson(minJson);
      expect(
        item.createdAt,
        equals(1700000000000),
        reason: 'createdAt 缺省回退为 updatedAt',
      );
      expect(
        item.blobKeyEpoch,
        equals(0),
        reason: 'fromJson 缺省 blobKeyEpoch 为 0',
      );
      expect(item.contentSize, equals(0));
      expect(item.updatedBy, equals(''));
      expect(item.dataKeyFingerprint, equals(''));
      expect(item.createdBy, equals(''));
      expect(item.deletedAt, isNull);
      expect(item.dataKeyCreatedAt, isNull);
      expect(item.dataKeyCreatedBy, isNull);
    });

    test('copyWith 针对单字段修改与保留未改字段', () {
      const item = ManifestItem(
        hash: 'h1',
        deleted: false,
        updatedAt: 100,
        updatedBy: 'u1',
        createdAt: 50,
      );

      final modified = item.copyWith(
        deleted: true,
        deletedAt: 120,
        updatedAt: 120,
        contentSize: 500,
      );

      expect(modified.hash, equals('h1'));
      expect(modified.deleted, isTrue);
      expect(modified.deletedAt, equals(120));
      expect(modified.updatedAt, equals(120));
      expect(modified.contentSize, equals(500));
      expect(modified.updatedBy, equals('u1'));
    });
  });

  group('ManifestHeader 模型与旧协议缺省测试', () {
    test('完整字段 toJson 与 fromJson round-trip', () {
      final header = ManifestHeader(
        schemaVersion: 5,
        version: 42,
        vaultId: 'vault-uuid-777',
        createdAt: 1700000000000,
        updatedAt: 1700005000000,
        keyFingerprint: 'mk-fp',
        keyVersion: 3,
        encryptedDataKey: 'base64-edk',
        kdf: KdfParams.create(salt: Uint8List.fromList(List.filled(16, 1))),
        dataKeyWrap: 'AES-256-GCM',
        lastModifiedBy: 'device-x',
        dataKeyFingerprint: 'dk-fp',
        dataKeyCreatedAt: 1700000000000,
        dataKeyCreatedBy: 'creator-x',
      );

      final json = header.toJson();
      final restored = ManifestHeader.fromJson(json);

      expect(restored.schemaVersion, equals(5));
      expect(restored.version, equals(42));
      expect(restored.vaultId, equals('vault-uuid-777'));
      expect(restored.keyFingerprint, equals('mk-fp'));
      expect(restored.keyVersion, equals(3));
      expect(restored.encryptedDataKey, equals('base64-edk'));
      expect(restored.dataKeyWrap, equals('AES-256-GCM'));
      expect(restored.lastModifiedBy, equals('device-x'));
      expect(restored.dataKeyFingerprint, equals('dk-fp'));
      expect(restored.toString(), contains('ManifestHeader(schemaVersion=5'));
    });

    test('fromJson 缺省字段回退', () {
      final oldJson = <String, dynamic>{
        'version': 1,
        'vaultId': 'old-vault',
        'updatedAt': 1700000000000,
        'keyFingerprint': 'fp',
        'encryptedDataKey': 'edk',
        'kdf': {
          'algorithm': 'PBKDF2-HMAC-SHA256',
          'salt': 'salt-base64',
          'iterations': 200000,
        },
        'dataKeyWrap': 'AES-256-GCM',
        'lastModifiedBy': 'old-device',
      };

      final header = ManifestHeader.fromJson(oldJson);
      expect(header.schemaVersion, equals(1), reason: '缺省 schemaVersion 为 1');
      expect(header.keyVersion, equals(1), reason: '缺省 keyVersion 为 1');
      expect(header.dataKeyWrap, equals('AES-256-GCM'));
      expect(
        header.createdAt,
        equals(1700000000000),
        reason: '缺省 createdAt 回退 updatedAt',
      );
      expect(header.lastModifiedBy, equals('old-device'));
      expect(header.dataKeyFingerprint, equals(''));
      expect(header.dataKeyCreatedBy, isNull);
    });

    test('copyWith 正确修改并生成新实例', () {
      final header = ManifestHeader(
        schemaVersion: 5,
        version: 1,
        vaultId: 'v1',
        createdAt: 100,
        updatedAt: 100,
        keyFingerprint: 'fp',
        keyVersion: 1,
        encryptedDataKey: 'edk',
        kdf: KdfParams(
          algorithm: 'PBKDF2-HMAC-SHA256',
          salt: 'salt',
          iterations: 200000,
        ),
        dataKeyWrap: 'AES-256-GCM',
        lastModifiedBy: 'dev1',
      );

      final next = header.copyWith(
        version: 2,
        updatedAt: 200,
        lastModifiedBy: 'dev2',
      );

      expect(next.version, equals(2));
      expect(next.updatedAt, equals(200));
      expect(next.lastModifiedBy, equals('dev2'));
      expect(next.vaultId, equals('v1'));
      expect(next.schemaVersion, equals(5));
    });
  });

  group('SyncEngine.rejectOldSchemaVersion 边界测试', () {
    test('schemaVersion < kManifestSchemaVersion 时返回拒绝提示', () {
      final headerV4 = ManifestHeader(
        schemaVersion: 4,
        version: 1,
        vaultId: 'v',
        createdAt: 0,
        updatedAt: 0,
        keyFingerprint: 'f',
        keyVersion: 1,
        encryptedDataKey: 'e',
        kdf: KdfParams(
          algorithm: 'PBKDF2-HMAC-SHA256',
          salt: 's',
          iterations: 200000,
        ),
        dataKeyWrap: 'AES-256-GCM',
        lastModifiedBy: 'd',
      );
      final reason = SyncEngine.rejectOldSchemaVersion(headerV4);
      expect(reason, isNotNull);
      expect(reason, contains('schema v4'));
      expect(reason, contains('当前 v5'));

      final headerV1 = headerV4.copyWith(schemaVersion: 1);
      expect(
        SyncEngine.rejectOldSchemaVersion(headerV1),
        contains('schema v1'),
      );
    });

    test('schemaVersion >= kManifestSchemaVersion 时返回 null (允许继续)', () {
      final headerV5 = ManifestHeader(
        schemaVersion: 5,
        version: 1,
        vaultId: 'v',
        createdAt: 0,
        updatedAt: 0,
        keyFingerprint: 'f',
        keyVersion: 1,
        encryptedDataKey: 'e',
        kdf: KdfParams.create(salt: SyncCrypto.generateSalt()),
        dataKeyWrap: 'AES-256-GCM',
        lastModifiedBy: 'd',
      );
      expect(SyncEngine.rejectOldSchemaVersion(headerV5), isNull);

      final headerV6 = headerV5.copyWith(schemaVersion: 6);
      expect(SyncEngine.rejectOldSchemaVersion(headerV6), isNull);
    });
  });

  group('KdfParams 模型与工厂方法测试', () {
    test('KdfParams.create 默认使用 Argon2id 参数与 toJson/fromJson', () {
      final salt = SyncCrypto.generateSalt();
      final kdf = KdfParams.create(salt: salt);
      expect(kdf.algorithm, equals(kMkKdfAlgorithm));
      expect(kdf.salt, equals(base64Encode(salt)));
      expect(kdf.iterations, equals(kArgon2idIterations));
      expect(kdf.memoryKiB, equals(kArgon2idMemoryKib));
      expect(kdf.parallelism, equals(kArgon2idParallelism));

      final json = kdf.toJson();
      expect(json['memoryKiB'], equals(kArgon2idMemoryKib));
      expect(json['parallelism'], equals(kArgon2idParallelism));

      final restored = KdfParams.fromJson(json);
      expect(restored.algorithm, equals(kdf.algorithm));
      expect(restored.salt, equals(kdf.salt));
      expect(restored.iterations, equals(kdf.iterations));
      expect(restored.memoryKiB, equals(kdf.memoryKiB));
      expect(restored.parallelism, equals(kdf.parallelism));
      expect(restored.saltBytes, equals(salt));
    });

    test('KdfParams PBKDF2 参数与 toJson/fromJson (无 memoryKiB/parallelism)', () {
      final salt = SyncCrypto.generateSalt();
      final kdf = KdfParams(
        algorithm: 'PBKDF2-HMAC-SHA256',
        salt: base64Encode(salt),
        iterations: 200000,
      );
      expect(kdf.algorithm, equals('PBKDF2-HMAC-SHA256'));
      expect(kdf.iterations, equals(200000));
      expect(kdf.memoryKiB, isNull);
      expect(kdf.parallelism, isNull);

      final json = kdf.toJson();
      expect(json.containsKey('memoryKiB'), isFalse);
      expect(json.containsKey('parallelism'), isFalse);

      final restored = KdfParams.fromJson(json);
      expect(restored.algorithm, equals(kdf.algorithm));
      expect(restored.memoryKiB, isNull);
      expect(restored.parallelism, isNull);
    });
  });

  group('KdfParams.fromJson 恶意输入校验（H5：防弱化/DoS）', () {
    Map<String, dynamic> validArgon2Json() => KdfParams(
      algorithm: kArgon2idAlgorithm,
      salt: base64Encode(SyncCrypto.generateSalt()),
      iterations: kArgon2idIterations,
      memoryKiB: kArgon2idMemoryKib,
      parallelism: kArgon2idParallelism,
    ).toJson();

    Map<String, dynamic> validPbkdf2Json() => KdfParams(
      algorithm: kPbkdf2Algorithm,
      salt: base64Encode(SyncCrypto.generateSalt()),
      iterations: kPbkdf2Iterations,
    ).toJson();

    void expectThrows(Map<String, dynamic> json, String reason) {
      expect(
        () => KdfParams.fromJson(json),
        throwsFormatException,
        reason: reason,
      );
    }

    test('合法参数（Argon2id/PBKDF2 默认）解析通过', () {
      expect(KdfParams.fromJson(validArgon2Json()), isA<KdfParams>());
      expect(KdfParams.fromJson(validPbkdf2Json()), isA<KdfParams>());
    });

    test('未知算法 fail-closed', () {
      final json = validArgon2Json()..['algorithm'] = 'SOME-WEAK-KDF';
      expectThrows(json, '恶意端不能注入不受支持的弱算法');
    });

    test('PBKDF2 迭代次数下限（防弱化）与上限（防 DoS）', () {
      final weak = validPbkdf2Json()..['iterations'] = 9999;
      expectThrows(weak, 'iterations=9999 弱化攻击应被拒绝');
      final dos = validPbkdf2Json()..['iterations'] = 1000000000;
      expectThrows(dos, 'iterations=10^9 派生挂死应被拒绝');
    });

    test('Argon2id 参数越界被拒绝', () {
      final highT = validArgon2Json()..['iterations'] = 6;
      expectThrows(highT, 't=6 超上限');
      final lowMem = validArgon2Json()..['memoryKiB'] = 1024;
      expectThrows(lowMem, 'memory=1MiB 弱化应被拒绝');
      final hugeMem = validArgon2Json()..['memoryKiB'] = 4 * 1024 * 1024;
      expectThrows(hugeMem, 'memory=4GiB DoS 应被拒绝');
      final badP = validArgon2Json()..['parallelism'] = 64;
      expectThrows(badP, 'p=64 超上限');
    });

    test('缺失字段 / 非整数类型被拒绝', () {
      final noSalt = validArgon2Json()..remove('salt');
      expectThrows(noSalt, '缺 salt');
      final strIter = validArgon2Json()..['iterations'] = '3';
      expectThrows(strIter, '字符串迭代数');
    });
  });

  group('SyncResult & SyncAction 模型测试', () {
    test('SyncResult success & failure 构造与属性', () {
      final success = SyncResult.success(
        uploaded: 2,
        downloaded: 3,
        conflicts: 1,
        actions: [
          const SyncAction(
            type: SyncActionType.conflict,
            uuid: 'conflict-note-1',
            message: 'LWW resolved',
          ),
        ],
      );
      expect(success.success, isTrue);
      expect(success.uploaded, equals(2));
      expect(success.downloaded, equals(3));
      expect(success.conflicts, equals(1));
      expect(success.hasChanges, isTrue);
      expect(success.hasConflicts, isTrue);
      expect(success.conflictMessage, contains('conflict-note-1'));
      expect(success.errorMessage, isNull);

      final failure = SyncResult.failure(
        'Network timeout',
        requiresRelogin: true,
      );
      expect(failure.success, isFalse);
      expect(failure.requiresRelogin, isTrue);
      expect(failure.errorMessage, equals('Network timeout'));
      expect(failure.hasChanges, isFalse);
    });

    test('SyncAction 构造与 toString', () {
      const action = SyncAction(
        type: SyncActionType.upload,
        uuid: 'uuid-123',
        hash: 'hash-abc',
        message: 'Uploading note blob',
      );
      expect(action.type, equals(SyncActionType.upload));
      expect(action.uuid, equals('uuid-123'));
      expect(action.hash, equals('hash-abc'));
      expect(action.message, equals('Uploading note blob'));
      expect(action.displayMessage, equals('Uploading note blob'));
      expect(
        action.toString(),
        contains('SyncAction(SyncActionType.upload, uuid=uuid-123'),
      );
    });
  });
}
