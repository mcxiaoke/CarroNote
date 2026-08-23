/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*
*/

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:core/core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';

import 'sync_test_support.dart';

SafeNote _makeNote({
  required String uuid,
  required String title,
  String description = 'desc',
  bool deleted = false,
  int? updatedAt,
  String? syncedHash,
  bool synced = false,
}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return SafeNote(
    uuid: uuid,
    title: title,
    description: description,
    contentHash: SafeNote.computeHash(title, description),
    deleted: deleted,
    createdTime: DateTime.now(),
    updatedAt: updatedAt ?? now,
    synced: synced,
    syncedHash: syncedHash,
  );
}

/// 具有高级故障注入能力的 FakeBackend
class AdvFakeBackend with FakeJournalStore implements SyncBackend {
  Uint8List? manifestCiphertext;
  String etag = '';
  final Map<String, Uint8List> blobs = {};
  final List<String> putManifestHistory = [];
  final Map<String, Uint8List> backups = {};
  int getManifestFailures = 0;
  int getBlobFailures = 0;
  bool corruptManifestBackup = false;

  @override
  String get displayName => 'AdvFakeBackend';

  @override
  String get providerKey => 'adv-fake-backend';

  @override
  Future<void> init() async {}

  @override
  Future<({Uint8List ciphertext, String etag})> getManifest() async {
    if (getManifestFailures > 0) {
      getManifestFailures--;
      throw BackendUnavailableException('Simulated GET manifest failure');
    }
    if (manifestCiphertext == null) {
      return (ciphertext: Uint8List(0), etag: '');
    }
    return (ciphertext: manifestCiphertext!, etag: etag);
  }

  @override
  Future<String> putManifest(Uint8List ciphertext, String expectedEtag) async {
    if (expectedEtag.isEmpty) {
      if (manifestCiphertext != null && etag.isNotEmpty) {
        throw ConflictException('Manifest already exists');
      }
    } else if (etag != expectedEtag) {
      throw ConflictException('ETag mismatch: expected , got ');
    }
    manifestCiphertext = ciphertext;
    etag = 'etag-';
    putManifestHistory.add(etag);
    return etag;
  }

  @override
  Future<Uint8List?> getBlob(String hash) async {
    if (getBlobFailures > 0) {
      getBlobFailures--;
      throw BackendUnavailableException('Simulated GET blob failure');
    }
    return blobs[hash];
  }

  @override
  Future<void> putBlob(String hash, Uint8List data) async {
    blobs[hash] = data;
  }

  @override
  Future<void> deleteBlob(String hash) async {
    blobs.remove(hash);
  }

  @override
  Future<List<String>> listBlobs() async => blobs.keys.toList();

  @override
  Future<void> deleteBlobSoft(String hash) async {
    blobs.remove(hash);
  }

  @override
  Future<List<String>> listOrphanBlobs() async => [];

  @override
  Future<void> purgeOrphans(Duration retention) async {}

  @override
  Future<void> backupCorruptManifest(Uint8List ciphertext) async {
    corruptManifestBackup = true;
  }

  @override
  Future<void> backupManifest([Uint8List? currentManifestBytes]) async {
    if (currentManifestBytes != null) {
      backups['manifest.bak-'] = currentManifestBytes;
    }
  }

  @override
  Future<List<String>> listManifestBackups() async =>
      backups.keys.toList()..sort();

  @override
  Future<Uint8List?> readManifestBackup(String name) async => backups[name];

  @override
  Future<void> close() async {}

  @override
  Future<bool> ping() async => true;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tempDir;
  late NotesDatabase database;
  late AdvFakeBackend backend;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sync_engine_adv_test_');
    NotesDatabase.dbPathOverride = tempDir.path;
    database = NotesDatabase.instance;
    backend = AdvFakeBackend();
  });

  tearDown(() async {
    await database.close();
    NotesDatabase.dbPathOverride = null;
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('SyncEngine 密钥判定矩阵 (Key Decision Matrix)', () {
    test('本端改密码未推送 (remote keyVersion < local)：正常 PUT 新包裹', () async {
      final localDataKey = SyncCrypto.generateDataKey();
      final localMk = SyncCrypto.generateDataKey();
      final oldMk = SyncCrypto.generateDataKey();

      final localKeyring = makeTestKeyring(
        dataKey: localDataKey,
        keyVersion: 2,
        mk: localMk,
        keyFingerprint: 'mk-fp-2',
      );
      database.setDataKey(localDataKey);
      await persistTestKeyring(
        database,
        encryptedDataKey: localKeyring.current.encryptedDataKey,
        keyVersion: 2,
        keyFingerprint: 'mk-fp-2',
      );

      // 准备远端旧 keyVersion=1 的 manifest
      final remoteManifest = Manifest(
        header: ManifestHeader(
          schemaVersion: kManifestSchemaVersion,
          version: 1,
          vaultId: localKeyring.vaultId,
          createdAt: 1000,
          updatedAt: 1000,
          keyFingerprint: 'mk-fp-1',
          keyVersion: 1,
          encryptedDataKey: base64Encode(
            await SyncCrypto.seal(oldMk, 'test-keyring-id', localDataKey),
          ),
          kdf: KdfParams.create(salt: SyncCrypto.generateSalt()),
          dataKeyWrap: 'AES-256-GCM',
          lastModifiedBy: 'device-old',
        ),
        items: {},
      );
      backend.manifestCiphertext = await ManifestCrypto.serialize(
        localDataKey,
        remoteManifest,
      );
      backend.etag = 'etag-v1';

      final engine = SyncEngine(
        backend: backend,
        database: database,
        keyring: localKeyring,
        deviceId: 'device-local',
        journal: makeTestJournal(vaultId: localKeyring.vaultId),
      );

      final result = await engine.sync();
      expect(result.success, isTrue);
      expect(
        backend.putManifestHistory.isNotEmpty,
        isTrue,
        reason: '应该触发 PUT 将远端 keyVersion 升级',
      );

      final updatedHeader = ManifestCrypto.deserializeHeaderOnly(
        backend.manifestCiphertext!,
      );
      expect(updatedHeader.keyVersion, equals(2));
      expect(updatedHeader.keyFingerprint, equals('mk-fp-2'));
    });

    test(
      '他端改密码后本端同步 (remote keyVersion > local)：requiresRelogin=true 且零 PUT 写入',
      () async {
        final localDataKey = SyncCrypto.generateDataKey();
        final localMk = SyncCrypto.generateDataKey();
        final localKeyring = makeTestKeyring(
          dataKey: localDataKey,
          keyVersion: 1,
          keyFingerprint: 'mk-fp-1',
          mk: localMk,
        );
        database.setDataKey(localDataKey);
        await persistTestKeyring(
          database,
          encryptedDataKey: localKeyring.current.encryptedDataKey,
          keyVersion: 1,
          keyFingerprint: 'mk-fp-1',
        );

        // 远端 keyVersion=2（他端改了密码）
        final remoteDataKey = SyncCrypto.generateDataKey();
        final remoteMk = SyncCrypto.generateDataKey();
        final remoteManifest = Manifest(
          header: ManifestHeader(
            schemaVersion: kManifestSchemaVersion,
            version: 5,
            vaultId: localKeyring.vaultId,
            createdAt: 1000,
            updatedAt: 2000,
            keyFingerprint: 'mk-fp-2',
            keyVersion: 2,
            encryptedDataKey: base64Encode(
              await SyncCrypto.seal(remoteMk, 'test-keyring-id', remoteDataKey),
            ),
            kdf: KdfParams.create(salt: SyncCrypto.generateSalt()),
            dataKeyWrap: 'AES-256-GCM',
            lastModifiedBy: 'device-other',
          ),
          items: {},
        );
        backend.manifestCiphertext = await ManifestCrypto.serialize(
          remoteDataKey,
          remoteManifest,
        );
        backend.etag = 'etag-remote-v5';

        final engine = SyncEngine(
          backend: backend,
          database: database,
          keyring: localKeyring,
          deviceId: 'device-local',
          journal: makeTestJournal(vaultId: localKeyring.vaultId),
        );

        final result = await engine.sync();
        expect(result.success, isFalse);
        expect(result.requiresRelogin, isTrue, reason: '他端改密码本端必须提示重新登录');
        expect(backend.putManifestHistory, isEmpty, reason: '零写入红线：绝不得向远端 PUT');
      },
    );

    test('MK 为 null 但本地 dataKey 能解远端 items 时保守继续', () async {
      final sharedDataKey = SyncCrypto.generateDataKey();
      final localKeyring = makeTestKeyring(
        dataKey: sharedDataKey,
        keyVersion: 1,
        keyFingerprint: 'fp-1',
        mk: null, // 未注入 MK
      );
      database.setDataKey(sharedDataKey);
      await persistTestKeyring(
        database,
        encryptedDataKey: localKeyring.current.encryptedDataKey,
        keyVersion: 1,
        keyFingerprint: 'fp-1',
      );

      // 远端使用相同 dataKey
      final note = _makeNote(uuid: 'remote-note-1', title: 'Remote Note');
      final payload = utf8.encode(jsonEncode(note.toJson()));
      final encBlob = await SyncCrypto.seal(
        sharedDataKey,
        note.contentHash,
        Uint8List.fromList(payload),
      );
      backend.blobs[note.contentHash] = encBlob;

      final remoteManifest = Manifest(
        header: ManifestHeader(
          schemaVersion: kManifestSchemaVersion,
          version: 1,
          vaultId: localKeyring.vaultId,
          createdAt: 1000,
          updatedAt: 1000,
          keyFingerprint: 'fp-1',
          keyVersion: 1,
          encryptedDataKey: localKeyring.current.encryptedDataKey,
          kdf: KdfParams.create(salt: SyncCrypto.generateSalt()),
          dataKeyWrap: 'AES-256-GCM',
          lastModifiedBy: 'device-1',
        ),
        items: {
          note.uuid: ManifestItem(
            hash: note.contentHash,
            deleted: false,
            updatedAt: 1000,
            updatedBy: 'device-1',
            createdAt: 1000,
          ),
        },
      );
      backend.manifestCiphertext = await ManifestCrypto.serialize(
        sharedDataKey,
        remoteManifest,
      );
      backend.etag = 'etag-1';

      final engine = SyncEngine(
        backend: backend,
        database: database,
        keyring: localKeyring,
        deviceId: 'device-local',
        journal: makeTestJournal(vaultId: localKeyring.vaultId),
      );

      final result = await engine.sync();
      expect(result.success, isTrue);
      expect(result.downloaded, equals(1));
    });
  });

  group('远端 Manifest 损坏恢复编排 (§7.1)', () {
    test('re-GET 成功时直接合并且不调用 backupCorruptManifest', () async {
      final sharedDataKey = SyncCrypto.generateDataKey();
      final localKeyring = makeTestKeyring(dataKey: sharedDataKey);
      database.setDataKey(sharedDataKey);
      await persistTestKeyring(
        database,
        encryptedDataKey: localKeyring.current.encryptedDataKey,
      );

      final manifest = Manifest(
        header: ManifestHeader(
          schemaVersion: kManifestSchemaVersion,
          version: 2,
          vaultId: localKeyring.vaultId,
          createdAt: 1000,
          updatedAt: 1000,
          keyFingerprint: 'fp',
          keyVersion: 1,
          encryptedDataKey: localKeyring.current.encryptedDataKey,
          kdf: KdfParams.create(salt: SyncCrypto.generateSalt()),
          dataKeyWrap: 'AES-256-GCM',
          lastModifiedBy: 'device-1',
        ),
        items: {},
      );
      final validBytes = await ManifestCrypto.serialize(
        sharedDataKey,
        manifest,
      );

      // 首次获取返回损坏字节（4 字节短包），触发损坏恢复编排
      final corruptBytes = Uint8List.fromList([1, 2, 3, 4]);
      backend.manifestCiphertext = corruptBytes;
      backend.etag = 'etag-corrupt';

      // 注入 re-GET 成功逻辑：第二次 getManifest 返回正常数据
      final customBackend = _RegetBackend(
        firstCiphertext: corruptBytes,
        secondCiphertext: validBytes,
      );

      final engine = SyncEngine(
        backend: customBackend,
        database: database,
        keyring: localKeyring,
        deviceId: 'device-local',
        journal: makeTestJournal(vaultId: localKeyring.vaultId),
      );

      final result = await engine.sync();
      expect(result.success, isTrue);
      expect(
        customBackend.corruptManifestBackup,
        isFalse,
        reason: 'reget 成功不得备份损坏 manifest',
      );
    });

    test('Manifest 损坏且 reget 失败时自动从完好备份恢复', () async {
      final sharedDataKey = SyncCrypto.generateDataKey();
      final localKeyring = makeTestKeyring(dataKey: sharedDataKey);
      database.setDataKey(sharedDataKey);
      await persistTestKeyring(
        database,
        encryptedDataKey: localKeyring.current.encryptedDataKey,
      );

      final validManifest = Manifest(
        header: ManifestHeader(
          schemaVersion: kManifestSchemaVersion,
          version: 1,
          vaultId: localKeyring.vaultId,
          createdAt: 1000,
          updatedAt: 1000,
          keyFingerprint: 'fp',
          keyVersion: 1,
          encryptedDataKey: localKeyring.current.encryptedDataKey,
          kdf: KdfParams.create(salt: SyncCrypto.generateSalt()),
          dataKeyWrap: 'AES-256-GCM',
          lastModifiedBy: 'device-1',
        ),
        items: {},
      );
      final validBytes = await ManifestCrypto.serialize(
        sharedDataKey,
        validManifest,
      );

      // 主 manifest 完全损坏 (非合法 magic)
      backend.manifestCiphertext = Uint8List.fromList([
        0,
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        8,
        9,
        10,
        11,
        12,
        13,
        14,
        15,
      ]);
      backend.etag = 'etag-corrupt';

      // 注入备份：bak-0 是损坏的，bak-1 是完好的
      backend.backups['manifest.bak-0'] = Uint8List.fromList([99, 99, 99, 99]);
      backend.backups['manifest.bak-1'] = validBytes;

      final engine = SyncEngine(
        backend: backend,
        database: database,
        keyring: localKeyring,
        deviceId: 'device-local',
        journal: makeTestJournal(vaultId: localKeyring.vaultId),
      );

      final result = await engine.sync();
      expect(result.success, isTrue);
    });
  });

  group('LWW 仲裁与 M7 Hash 错位', () {
    test('LWW 时间戳相同时字典序小的 hash 胜出', () async {
      final dataKey = SyncCrypto.generateDataKey();
      final keyring = makeTestKeyring(dataKey: dataKey);
      database.setDataKey(dataKey);
      await persistTestKeyring(
        database,
        encryptedDataKey: keyring.current.encryptedDataKey,
      );

      // 本地笔记
      final localNote = _makeNote(
        uuid: 'uuid-lww-tie',
        title: 'Title B',
        updatedAt: 5000,
      );
      await database.storeNote(localNote);

      // 远端笔记拥有相同 updatedAt 但不同内容 (假设 hash 小于本地)
      final remoteNote = _makeNote(
        uuid: 'uuid-lww-tie',
        title: 'Title A',
        updatedAt: 5000,
      );

      final remotePayload = utf8.encode(jsonEncode(remoteNote.toJson()));
      final encRemoteBlob = await SyncCrypto.seal(
        dataKey,
        remoteNote.contentHash,
        Uint8List.fromList(remotePayload),
      );
      backend.blobs[remoteNote.contentHash] = encRemoteBlob;

      final remoteManifest = Manifest(
        header: ManifestHeader(
          schemaVersion: kManifestSchemaVersion,
          version: 1,
          vaultId: keyring.vaultId,
          createdAt: 1000,
          updatedAt: 5000,
          keyFingerprint: 'fp',
          keyVersion: 1,
          encryptedDataKey: keyring.current.encryptedDataKey,
          kdf: KdfParams.create(salt: SyncCrypto.generateSalt()),
          dataKeyWrap: 'AES-256-GCM',
          lastModifiedBy: 'device-remote',
        ),
        items: {
          'uuid-lww-tie': ManifestItem(
            hash: remoteNote.contentHash,
            deleted: false,
            updatedAt: 5000,
            updatedBy: 'device-remote',
            createdAt: 1000,
          ),
        },
      );
      backend.manifestCiphertext = await ManifestCrypto.serialize(
        dataKey,
        remoteManifest,
      );
      backend.etag = 'etag-tie';

      final engine = SyncEngine(
        backend: backend,
        database: database,
        keyring: keyring,
        deviceId: 'device-local',
        journal: makeTestJournal(vaultId: keyring.vaultId),
      );

      final result = await engine.sync();
      expect(result.success, isTrue);

      final expectedWinnerHash =
          localNote.contentHash.compareTo(remoteNote.contentHash) <= 0
          ? localNote.contentHash
          : remoteNote.contentHash;

      final finalNote = await database.readNoteByUuid('uuid-lww-tie');
      expect(finalNote?.contentHash, equals(expectedWinnerHash));
    });

    test('getBlob 瞬态异常时重试成功', () async {
      final dataKey = SyncCrypto.generateDataKey();
      final keyring = makeTestKeyring(dataKey: dataKey);
      database.setDataKey(dataKey);
      await persistTestKeyring(
        database,
        encryptedDataKey: keyring.current.encryptedDataKey,
      );

      final note = _makeNote(uuid: 'uuid-retry-1', title: 'Retry Note');
      final payload = utf8.encode(jsonEncode(note.toJson()));
      final encBlob = await SyncCrypto.seal(
        dataKey,
        note.contentHash,
        Uint8List.fromList(payload),
      );
      backend.blobs[note.contentHash] = encBlob;

      final remoteManifest = Manifest(
        header: ManifestHeader(
          schemaVersion: kManifestSchemaVersion,
          version: 1,
          vaultId: keyring.vaultId,
          createdAt: 1000,
          updatedAt: 1000,
          keyFingerprint: 'fp',
          keyVersion: 1,
          encryptedDataKey: keyring.current.encryptedDataKey,
          kdf: KdfParams.create(salt: SyncCrypto.generateSalt()),
          dataKeyWrap: 'AES-256-GCM',
          lastModifiedBy: 'device-remote',
        ),
        items: {
          note.uuid: ManifestItem(
            hash: note.contentHash,
            deleted: false,
            updatedAt: 1000,
            updatedBy: 'device-remote',
            createdAt: 1000,
          ),
        },
      );
      backend.manifestCiphertext = await ManifestCrypto.serialize(
        dataKey,
        remoteManifest,
      );
      backend.etag = 'etag-blob-retry';
      backend.getBlobFailures = 2; // 前 2 次抛 BackendUnavailableException，第 3 次成功

      final engine = SyncEngine(
        backend: backend,
        database: database,
        keyring: keyring,
        deviceId: 'device-local',
        journal: makeTestJournal(vaultId: keyring.vaultId),
      );

      final result = await engine.sync();
      expect(result.success, isTrue);
      expect(result.downloaded, equals(1));
    });
  });
}

class _RegetBackend with FakeJournalStore implements SyncBackend {
  final Uint8List firstCiphertext;
  final Uint8List secondCiphertext;
  int _getCalls = 0;
  bool corruptManifestBackup = false;

  _RegetBackend({
    required this.firstCiphertext,
    required this.secondCiphertext,
  });

  @override
  String get displayName => 'RegetBackend';

  @override
  String get providerKey => 'reget-backend';

  @override
  Future<void> init() async {}

  @override
  Future<({Uint8List ciphertext, String etag})> getManifest() async {
    _getCalls++;
    if (_getCalls == 1) {
      return (ciphertext: firstCiphertext, etag: 'etag-first');
    }
    return (ciphertext: secondCiphertext, etag: 'etag-second');
  }

  @override
  Future<String> putManifest(Uint8List ciphertext, String expectedEtag) async =>
      'etag-put';

  @override
  Future<Uint8List?> getBlob(String hash) async => null;

  @override
  Future<void> putBlob(String hash, Uint8List data) async {}

  @override
  Future<void> deleteBlob(String hash) async {}

  @override
  Future<List<String>> listBlobs() async => [];

  @override
  Future<void> deleteBlobSoft(String hash) async {}

  @override
  Future<List<String>> listOrphanBlobs() async => [];

  @override
  Future<void> purgeOrphans(Duration retention) async {}

  @override
  Future<void> backupCorruptManifest(Uint8List ciphertext) async {
    corruptManifestBackup = true;
  }

  @override
  Future<void> backupManifest([Uint8List? currentManifestBytes]) async {}

  @override
  Future<List<String>> listManifestBackups() async => [];

  @override
  Future<Uint8List?> readManifestBackup(String name) async => null;

  @override
  Future<void> close() async {}

  @override
  Future<bool> ping() async => true;
}
