// 临时诊断：校验 118 副本源数据自身的一致性（blob 内容 hash vs manifest hash）。用完即删。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:safenotes/data/database_handler.dart';
import 'package:safenotes/models/safenote.dart';
import 'package:safenotes/sync/keyring.dart';
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

    final keyring = await Keyring.unlockFromRemoteManifest(
      password: 'testpwd.2222',
      remoteVaultId: header.vaultId,
      remoteEncryptedDataKey: header.encryptedDataKey,
      remoteKdf: header.kdf,
      remoteKeyFingerprint: header.keyFingerprint,
      remoteKeyVersion: header.keyVersion,
      remoteDataKeyEpoch: header.dataKeyEpoch,
      remoteCreatedAt: header.createdAt,
      database: NotesDatabase.instance,
    );

    final manifest = ManifestCrypto.deserialize(keyring.dataKey, resp.ciphertext);
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
        // blob 纯化 v4：与引擎一致的单格式解密（AAD=hash，无 epoch）
        final plain = SyncCrypto.open(keyring.dataKey, item.hash, blob);
        final content = SafeNote.fromContentBytes(plain);
        final actual = SafeNote.computeHash(content.title, content.description);
        if (actual != item.hash) {
          mismatch++;
          print('MISMATCH uuid=$uuid manifestHash=${item.hash.substring(0, 10)} '
              'actualHash=${actual.substring(0, 10)} epoch=${item.blobKeyEpoch} '
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
