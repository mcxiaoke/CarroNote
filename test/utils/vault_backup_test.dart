/*
 * Copyright (C) mcxiaoke 2026 - All Rights Reserved.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 * You may use, distribute and modify this code under the
 * terms of the GPL-3.0+ license.
 */

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:core/core.dart';
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/utils/vault_backup.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRootDir;
  late _FakePathProvider fakePathProvider;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  setUp(() async {
    tempRootDir = await Directory.systemTemp.createTemp('vault_backup_test_');
    fakePathProvider = _FakePathProvider(tempRootDir.path);
    PathProviderPlatform.instance = fakePathProvider;
    NotesDatabase.dbPathOverride = tempRootDir.path;

    SharedPreferences.setMockInitialValues({
      'themeColorIndex': 2,
      'isFlagSecure': true,
    });
    await PreferencesStorage.init();
  });

  tearDown(() async {
    NotesDatabase.dbPathOverride = null;
    try {
      await NotesDatabase.instance.close();
    } catch (_) {}
    if (await tempRootDir.exists()) {
      await tempRootDir.delete(recursive: true);
    }
  });

  group('vault_backup backupVaultBeforeReset', () {
    test('数据库文件不存在时抛出明确异常', () async {
      // 未创建真实 DB 文件
      final dbFile = File(p.join(tempRootDir.path, 'safenotes_sync.db'));
      if (await dbFile.exists()) await dbFile.delete();

      expect(
        () => backupVaultBeforeReset(),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('database file not found'),
          ),
        ),
      );
    });

    test('数据库文件存在时成功创建包含 DB 副本与 preferences.json 的快照', () async {
      final realDbFile = File(p.join(tempRootDir.path, 'safenotes_sync.db'));
      await realDbFile.writeAsString('mock-encrypted-sqlite-binary-content');

      final backupDir = await backupVaultBeforeReset();

      expect(await backupDir.exists(), isTrue);
      expect(p.basename(backupDir.path).startsWith('pre-reset-'), isTrue);

      final dbCopy = File(p.join(backupDir.path, 'safenotes_sync.db'));
      expect(await dbCopy.exists(), isTrue);
      expect(
        await dbCopy.readAsString(),
        'mock-encrypted-sqlite-binary-content',
      );

      final prefsDump = File(p.join(backupDir.path, 'preferences.json'));
      expect(await prefsDump.exists(), isTrue);
      final prefsJson =
          jsonDecode(await prefsDump.readAsString()) as Map<String, dynamic>;
      expect(prefsJson['themeColorIndex'], 2);
      expect(prefsJson['isFlagSecure'], true);
    });

    test('备份超出 5 份时自动修剪并删除最旧快照', () async {
      final appSupportDir = Directory(
        await fakePathProvider.getApplicationSupportPath() ?? '',
      );
      final backupRoot = Directory(p.join(appSupportDir.path, 'backups'));
      await backupRoot.create(recursive: true);

      // 预先创建 6 份历史快照
      final oldDirs = <Directory>[];
      for (var i = 1; i <= 6; i++) {
        final d = Directory(
          p.join(backupRoot.path, 'pre-reset-20260101_00000$i'),
        );
        await d.create();
        oldDirs.add(d);
      }

      // 创建真实 DB 文件
      final realDbFile = File(p.join(tempRootDir.path, 'safenotes_sync.db'));
      await realDbFile.writeAsString('db-content');

      // 执行一次重置前快照
      final newBackupDir = await backupVaultBeforeReset();
      expect(await newBackupDir.exists(), isTrue);

      // 检查当前快照总数不超过 maxKeptBackups (5 份)
      final remaining =
          (await backupRoot.list().toList())
              .whereType<Directory>()
              .where((d) => p.basename(d.path).startsWith('pre-reset-'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));

      expect(remaining.length, maxKeptBackups);

      // 最旧的两份（000001 和 000002）应该已被删除
      expect(await oldDirs[0].exists(), isFalse);
      expect(await oldDirs[1].exists(), isFalse);

      // 最新的历史快照（000006 等）与新生成的快照仍保留
      expect(await oldDirs[5].exists(), isTrue);
    });
  });
}
