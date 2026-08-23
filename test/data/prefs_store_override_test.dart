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

import 'package:safenotes/data/prefs_store_override.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late File prefsFile;
  late FilePreferencesStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('prefs_store_test_');
    prefsFile = File('${tempDir.path}/nested/preferences.json');
    store = FilePreferencesStore(prefsFile);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('FilePreferencesStore 基本读写与前缀过滤', () {
    test('初始空文件读取返回空 map', () async {
      final all = await store.getAll();
      expect(all, isEmpty);
    });

    test('setValue 自动创建父目录并持久化 JSON', () async {
      final ok1 = await store.setValue('String', 'flutter.username', 'alice');
      final ok2 = await store.setValue('Int', 'flutter.age', 25);
      final ok3 = await store.setValue('Bool', 'custom.flag', true);

      expect(ok1, isTrue);
      expect(ok2, isTrue);
      expect(ok3, isTrue);
      expect(prefsFile.existsSync(), isTrue);

      final fileContent =
          jsonDecode(await prefsFile.readAsString()) as Map<String, dynamic>;
      expect(fileContent['flutter.username'], 'alice');
      expect(fileContent['flutter.age'], 25);
      expect(fileContent['custom.flag'], true);
    });

    test('getAll 默认按 flutter. 前缀过滤', () async {
      await store.setValue('String', 'flutter.key1', 'v1');
      await store.setValue('String', 'flutter.key2', 'v2');
      await store.setValue('String', 'other.key3', 'v3');

      final flutterEntries = await store.getAll();
      expect(flutterEntries.length, 2);
      expect(flutterEntries['flutter.key1'], 'v1');
      expect(flutterEntries['flutter.key2'], 'v2');
      expect(flutterEntries.containsKey('other.key3'), isFalse);
    });

    test('getAllWithPrefix 支持任意前缀', () async {
      await store.setValue('String', 'app.setting.theme', 'dark');
      await store.setValue('String', 'app.setting.font', 'sans');
      await store.setValue('String', 'user.profile.name', 'bob');

      final appSettings = await store.getAllWithPrefix('app.setting.');
      expect(appSettings.length, 2);
      expect(appSettings['app.setting.theme'], 'dark');
      expect(appSettings['app.setting.font'], 'sans');
    });

    test('remove 删除指定键并落盘', () async {
      await store.setValue('String', 'flutter.k1', 'v1');
      await store.setValue('String', 'flutter.k2', 'v2');

      final removed = await store.remove('flutter.k1');
      expect(removed, isTrue);

      final all = await store.getAll();
      expect(all.length, 1);
      expect(all['flutter.k2'], 'v2');
      expect(all.containsKey('flutter.k1'), isFalse);

      final fileContent =
          jsonDecode(await prefsFile.readAsString()) as Map<String, dynamic>;
      expect(fileContent.containsKey('flutter.k1'), isFalse);
      expect(fileContent['flutter.k2'], 'v2');
    });

    test('clear 清空全部数据并持久化', () async {
      await store.setValue('String', 'flutter.k1', 'v1');
      await store.setValue('String', 'other.k2', 'v2');

      final cleared = await store.clear();
      expect(cleared, isTrue);

      final allFlutter = await store.getAll();
      final allOther = await store.getAllWithPrefix('other.');
      expect(allFlutter, isEmpty);
      expect(allOther, isEmpty);

      final fileContent =
          jsonDecode(await prefsFile.readAsString()) as Map<String, dynamic>;
      expect(fileContent, isEmpty);
    });
  });

  group('FilePreferencesStore 容错与异常防护', () {
    test('JSON 语法损坏时安全降级为空 store 且不崩溃', () async {
      await prefsFile.parent.create(recursive: true);
      await prefsFile.writeAsString('{ invalid json syntax ::');

      final all = await store.getAll();
      expect(all, isEmpty);

      // 写入新值后正常恢复
      await store.setValue('String', 'flutter.recovered', 'yes');
      final allAfter = await store.getAll();
      expect(allAfter['flutter.recovered'], 'yes');
    });

    test('JSON 内容为非 Map 类型（如数组/字符串）时安全降级为空 store', () async {
      await prefsFile.parent.create(recursive: true);
      await prefsFile.writeAsString('[1, 2, 3, "array instead of map"]');

      final all = await store.getAll();
      expect(all, isEmpty);
    });
  });
}
