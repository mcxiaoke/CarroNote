// 临时诊断：校验 118 副本源数据自身的一致性（blob 内容 hash vs manifest hash）。用完即删。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:safenotes/data/database_handler.dart';
import 'package:safenotes/models/safenote.dart';
import 'package:safenotes/sync/vault.dart';
import 'package:safenotes/sync/crypto.dart';
import 'package:safenotes/sync/sync_models.dart';
import 'package:safenotes/sync/local_fs_backend.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('118 副本基线完整性校验', () async {
    final vaultDir = p.join(Directory.current.path, 'temp', 'safenotes-vault');
    final backend = LocalFsBackend(rootPath: vaultDir);
    await backend.init();
    final resp = await backend.getManifest();
    final header = ManifestCrypto.deserializeHeaderOnly(resp.ciphertext);

    final db = await openDatabase(
      p.join(Directory.systemTemp.path,
          'diag-integrity-${DateTime.now().millisecondsSinceEpoch}.db'),
      version: 2,
      onCreate: NotesDatabase.createDBForTesting,
    );
    NotesDatabase.setDatabaseForTesting(db);

    final vault = await Vault.unlockFromRemoteManifest(
      password: 'hello.5555',
      remoteVaultId: header.vaultId,
      remoteEncryptedDataKey: header.encryptedDataKey,
      remoteKdf: header.kdf,
      remoteKeyFingerprint: header.keyFingerprint,
      remoteKeyVersion: header.keyVersion,
      remoteDataKeyEpoch: header.dataKeyEpoch,
      remoteCreatedAt: header.createdAt,
      database: NotesDatabase.instance,
    );

    final manifest = ManifestCrypto.deserialize(vault.dataKey, resp.ciphertext);
    print('baseline items=${manifest.items.length} '
        'kv=${header.keyVersion} epoch=${header.dataKeyEpoch}');

    var ok = 0, mismatch = 0, missing = 0, undecryptable = 0, tombstone = 0;
    // hash → 使用它的 uuid 列表（检测共享 blob）
    final hashUse = <String, List<String>>{};
    for (final e in manifest.items.entries) {
      final uuid = e.key;
      final item = e.value;
      if (item.deleted) {
        tombstone++;
        continue;
      }
      hashUse.putIfAbsent(item.hash, () => []).add(uuid);
      final blob = await backend.getBlob(item.hash);
      if (blob == null) {
        missing++;
        print('MISSING  uuid=$uuid hash=${item.hash.substring(0, 10)} '
            'epoch=${item.blobKeyEpoch}');
        continue;
      }
      try {
        // 与引擎相同的三重兼容解密（epoch AAD → v2 AAD=hash → v1 AAD=uuid）
        Uint8List plain;
        var via = 'v2-hash';
        try {
          if (item.blobKeyEpoch > 0) {
            plain = SyncCrypto.open(vault.dataKey, item.hash, blob,
                epoch: item.blobKeyEpoch);
            via = 'epoch';
          } else {
            plain = SyncCrypto.open(vault.dataKey, item.hash, blob);
          }
        } on Object {
          try {
            plain = SyncCrypto.open(vault.dataKey, item.hash, blob);
            via = 'v2-hash';
          } on Object {
            plain = SyncCrypto.open(vault.dataKey, uuid, blob);
            via = 'v1-uuid';
          }
        }
        final content = SafeNote.fromContentBytes(plain);
        final actual = SafeNote.computeHash(content.title, content.description);
        if (actual != item.hash) {
          mismatch++;
          print('MISMATCH uuid=$uuid manifestHash=${item.hash.substring(0, 10)} '
              'actualHash=${actual.substring(0, 10)} epoch=${item.blobKeyEpoch} '
              'via=$via '
              'title=${content.title.substring(0, content.title.length > 20 ? 20 : content.title.length)}');
        } else {
          ok++;
        }
      } on Object catch (err) {
        undecryptable++;
        print('UNDECRYPTABLE uuid=$uuid hash=${item.hash.substring(0, 10)} '
            'epoch=${item.blobKeyEpoch} err=${err.runtimeType}');
      }
    }
    // 共享 blob（同 hash 多 uuid）
    for (final e in hashUse.entries) {
      if (e.value.length > 1) {
        print('SHARED blob hash=${e.key.substring(0, 10)} uuids=${e.value}');
      }
    }
    print('SUMMARY ok=$ok mismatch=$mismatch missing=$missing '
        'undecryptable=$undecryptable tombstone=$tombstone');
    await db.close();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
