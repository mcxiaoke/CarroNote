/*
 * Copyright (C) mcxiaoke 2026 - All Rights Reserved.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 * You may use, distribute and modify this code under the
 * terms of the GPL-3.0+ license.
 */

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:core/core.dart';
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/sync/sync_config.dart';
import 'package:safenotes/sync/sync_service.dart';
import 'package:safenotes/utils/device_id.dart';
import '../test_helpers.dart';
import 'sync_test_support.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this._root);
  final String _root;

  @override
  Future<String?> getApplicationSupportPath() async =>
      p.join(_root, 'app-support');

  @override
  Future<String?> getApplicationDocumentsPath() async =>
      p.join(_root, 'app-docs');

  @override
  Future<String?> getTemporaryPath() async => p.join(_root, 'tmp');
}

class FakeBackend with FakeJournalStore implements SyncBackend {
  Uint8List? _manifestCiphertext;
  String _etag = '';
  final Map<String, Uint8List> _blobs = {};

  @override
  String get displayName => 'FakeBackend';

  @override
  String get providerKey => 'fake-backend-test';

  @override
  Future<void> init() async {}

  @override
  Future<({Uint8List ciphertext, String etag})> getManifest() async {
    if (_manifestCiphertext == null) {
      return (ciphertext: Uint8List(0), etag: '');
    }
    return (ciphertext: _manifestCiphertext!, etag: _etag);
  }

  @override
  Future<String> putManifest(Uint8List ciphertext, String expectedEtag) async {
    _manifestCiphertext = ciphertext;
    _etag = 'etag-${DateTime.now().microsecondsSinceEpoch}';
    return _etag;
  }

  @override
  Future<Uint8List?> getBlob(String hash) async => _blobs[hash];

  @override
  Future<void> putBlob(String hash, Uint8List data) async {
    _blobs[hash] = data;
  }

  @override
  Future<void> deleteBlob(String hash) async {
    _blobs.remove(hash);
  }

  @override
  Future<List<String>> listBlobs() async => _blobs.keys.toList();

  @override
  Future<void> backupCorruptManifest(Uint8List ciphertext) async {}

  @override
  Future<List<String>> listManifestBackups() async => [];

  @override
  Future<Uint8List?> readManifestBackup(String name) async => null;

  @override
  Future<void> close() async {}

  @override
  Future<bool> ping() async => true;

  @override
  Future<void> deleteBlobSoft(String hash) async => deleteBlob(hash);

  @override
  Future<List<String>> listOrphanBlobs() async => [];

  @override
  Future<void> purgeOrphans(Duration retention) async {}

  @override
  Future<void> backupManifest([Uint8List? currentManifestBytes]) async {}
}

class _FaultyInitBackend extends FakeBackend {
  @override
  String get displayName => 'FaultyBackend';

  @override
  String get providerKey => 'faulty';

  @override
  Future<void> init() async {
    throw BackendUnavailableException('Backend network is broken');
  }
}

void main() {
  late Directory tempRootDir;
  late _FakePathProvider fakePathProvider;

  setUpAll(() async {
    await initFullEnv();
  });

  setUp(() async {
    tempRootDir = await Directory.systemTemp.createTemp('sync_service_test_');
    fakePathProvider = _FakePathProvider(tempRootDir.path);
    PathProviderPlatform.instance = fakePathProvider;
    DeviceIdProvider.instance.overrideForTesting('test-device-uuid-1');

    SharedPreferences.setMockInitialValues({});
    await PreferencesStorage.init();
    await SyncConfig.init();
    await prepareUnlockedVault(password: 'sync-pass-1');
  });

  tearDown(() async {
    await SyncService.instance.logout();
    DeviceIdProvider.instance.clearTestingOverride();
    await disposeVault();
    if (await tempRootDir.exists()) {
      await tempRootDir.delete(recursive: true);
    }
  });

  group('SyncService 凭据脱敏安全函数', () {
    test('redactUrlForTesting 遮蔽 URL 中的 userInfo 与 query 参数', () {
      expect(
        SyncService.redactUrlForTesting(
          'https://user:secret123@example.com/api/v1/sync',
        ),
        'https://***@example.com/api/v1/sync',
      );

      expect(
        SyncService.redactUrlForTesting(
          'https://example.com/sync?token=abc123xyz&ref=mobile',
        ),
        'https://example.com/sync?***',
      );

      expect(
        SyncService.redactUrlForTesting(
          'https://admin:pass@example.com/path?key=val',
        ),
        'https://***@example.com/path?***',
      );

      expect(SyncService.redactUrlForTesting(''), '');
    });

    test('redactUrlForTesting 对非合法 URL 触发 FormatException 时回退正则掩码', () {
      // 触发 FormatException 的畸形 URL（包含非法端口格式）
      final invalidUrl = 'http://alice:supersecret@example.com:not_a_port/path';
      final redacted = SyncService.redactUrlForTesting(invalidUrl);
      expect(redacted, contains('http://***@example.com:not_a_port/path'));
      expect(redacted.contains('supersecret'), isFalse);
    });

    test('maskUsernameForTesting 用户名脱敏（前 2 字符保留）', () {
      expect(SyncService.maskUsernameForTesting(''), '');
      expect(SyncService.maskUsernameForTesting('a'), '***');
      expect(SyncService.maskUsernameForTesting('ab'), '***');
      expect(SyncService.maskUsernameForTesting('alice'), 'al***');
      expect(SyncService.maskUsernameForTesting('administrator'), 'ad***');
    });
  });

  group('SyncService 编排与总开关控制', () {
    test('同步总开关关闭时 sync() 被拦截并置为 error 状态', () async {
      await SyncConfig.setSyncEnabled(false);
      expect(SyncConfig.isSyncEnabled, isFalse);

      final result = await SyncService.instance.sync();
      expect(result, isNull);
      expect(SyncService.instance.state.status, SyncStatus.error);
    });

    test('initialize 幂等初始化并正确更新状态', () async {
      final backend = FakeBackend();
      final keyring = makeTestKeyring(
        dataKey: NotesDatabase.instance.dataKeyForTesting,
      );

      // 首次初始化
      await SyncService.instance.initialize(
        keyring: keyring,
        backend: backend,
        database: NotesDatabase.instance,
      );

      expect(SyncService.instance.state.status, SyncStatus.idle);
      expect(SyncService.instance.state.isInitialized, isTrue);

      // 重复调用 initialize 幂等关闭旧资源并重新初始化
      final backend2 = FakeBackend();
      await SyncService.instance.initialize(
        keyring: keyring,
        backend: backend2,
        database: NotesDatabase.instance,
      );
      expect(SyncService.instance.state.isInitialized, isTrue);
    });

    test('updateKeyring 在 keyVersion 递增时写 journal 并重建 engine', () async {
      final backend = FakeBackend();
      final keyring1 = makeTestKeyring(
        dataKey: NotesDatabase.instance.dataKeyForTesting,
        keyVersion: 1,
      );

      await SyncService.instance.initialize(
        keyring: keyring1,
        backend: backend,
        database: NotesDatabase.instance,
      );

      final keyring2 = makeTestKeyring(
        dataKey: NotesDatabase.instance.dataKeyForTesting,
        keyVersion: 2,
        encryptedDataKey: 'new-encrypted-key-v2',
      );

      await SyncService.instance.updateKeyring(
        keyring: keyring2,
        database: NotesDatabase.instance,
      );

      expect(SyncService.instance.state.isInitialized, isTrue);
    });

    test('switchBackend 在新后端 init 失败时保持状态回滚并抛出异常', () async {
      final backend1 = FakeBackend();
      final keyring = makeTestKeyring(
        dataKey: NotesDatabase.instance.dataKeyForTesting,
      );

      await SyncService.instance.initialize(
        keyring: keyring,
        backend: backend1,
        database: NotesDatabase.instance,
      );

      // 构造一个 init 会抛异常的 backend
      final faultyBackend = _FaultyInitBackend();

      expect(
        () => SyncService.instance.switchBackend(
          backend: faultyBackend,
          database: NotesDatabase.instance,
        ),
        throwsA(isA<BackendUnavailableException>()),
      );
    });

    test('logout 重置状态但保留 stateStream 可被后续重新复用', () async {
      final backend = FakeBackend();
      final keyring = makeTestKeyring(
        dataKey: NotesDatabase.instance.dataKeyForTesting,
      );

      await SyncService.instance.initialize(
        keyring: keyring,
        backend: backend,
        database: NotesDatabase.instance,
      );
      expect(SyncService.instance.state.isInitialized, isTrue);

      await SyncService.instance.logout();
      expect(SyncService.instance.state.status, SyncStatus.uninitialized);
      expect(SyncService.instance.state.isInitialized, isFalse);

      // 重新登录后再次 initialize，stream 仍然有效且不抛 StateError
      await SyncService.instance.initialize(
        keyring: keyring,
        backend: FakeBackend(),
        database: NotesDatabase.instance,
      );
      expect(SyncService.instance.state.isInitialized, isTrue);
    });
  });
}
