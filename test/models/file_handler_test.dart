/*
 * Copyright (C) mcxiaoke 2026 - All Rights Reserved.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 * You may use, distribute and modify this code under the
 * terms of the GPL-3.0+ license.
 */

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/file_handler.dart';
import 'package:safenotes/utils/platform_ui.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this._root);
  final String _root;

  @override
  Future<String?> getApplicationDocumentsPath() async =>
      p.join(_root, 'documents');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRootDir;
  late PathProviderPlatform originalPlatform;

  setUpAll(() {
    originalPlatform = PathProviderPlatform.instance;
  });

  tearDownAll(() {
    PathProviderPlatform.instance = originalPlatform;
  });

  setUp(() async {
    tempRootDir = await Directory.systemTemp.createTemp('file_handler_test_');
    PathProviderPlatform.instance = _FakePathProvider(tempRootDir.path);
    SharedPreferences.setMockInitialValues({});
    await PreferencesStorage.init();
  });

  tearDown(() async {
    if (await tempRootDir.exists()) {
      await tempRootDir.delete(recursive: true);
    }
  });

  group('FileHandler.defaultBackupDirectory 桌面端子目录测试', () {
    test('桌面平台默认备份路径包含 CarroNote 子目录且自动创建', () async {
      final defaultDir = await FileHandler.defaultBackupDirectory();

      if (isDesktopPlatform) {
        final expectedDocDir = p.join(tempRootDir.path, 'documents');
        final expectedDir = p.join(
          expectedDocDir,
          SafeNotesConfig.desktopBackupSubdirectory,
        );
        expect(defaultDir, expectedDir);
        expect(Directory(defaultDir).existsSync(), isTrue);
      }
    });
  });
}
