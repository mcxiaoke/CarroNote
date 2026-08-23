/*
 * Copyright (C) mcxiaoke 2026 - All Rights Reserved.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 * You may use, distribute and modify this code under the
 * terms of the GPL-3.0+ license.
 */

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:core/core.dart';
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/utils/scheduled_task.dart';
import '../test_helpers.dart';

void main() {
  late Directory tempBackupDir;
  const mediaScannerChannel = MethodChannel('media_scanner');

  setUpAll(() async {
    await initFullEnv();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          mediaScannerChannel,
          (call) async => 'success',
        );
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(mediaScannerChannel, null);
  });

  setUp(() async {
    tempBackupDir = await Directory.systemTemp.createTemp(
      'scheduled_task_test_',
    );
    await prepareUnlockedVault(
      password: 'test.password.123',
      seeds: [(title: '秘密笔记', description: '绝密内容123456')],
    );
    await PreferencesStorage.setBackupDirectory(tempBackupDir.path);
    await PreferencesStorage.setIsBackupOn(true);
    await PreferencesStorage.setIsBackupNeeded(true);
    ScheduledTask.lastBackupError = null;
  });

  tearDown(() async {
    PhraseHandler.destroy();
    await disposeVault();
    if (await tempBackupDir.exists()) {
      await tempBackupDir.delete(recursive: true);
    }
  });

  group('ScheduledTask 自动备份开关与触发条件', () {
    test('isBackupOn == false 时跳过自动备份且不产生文件', () async {
      await PreferencesStorage.setIsBackupOn(false);
      PhraseHandler.initPass('test.password.123');

      await ScheduledTask.backup();

      final files = tempBackupDir.listSync();
      expect(files, isEmpty);
    });

    test('isBackupNeeded == false 时跳过自动备份且不产生文件', () async {
      await PreferencesStorage.setIsBackupNeeded(false);
      PhraseHandler.initPass('test.password.123');

      await ScheduledTask.backup();

      final files = tempBackupDir.listSync();
      expect(files, isEmpty);
    });

    test('开关开启且待备份时成功生成加密备份并更新状态', () async {
      PhraseHandler.initPass('test.password.123');

      await ScheduledTask.backup();

      final files = tempBackupDir.listSync().whereType<File>().toList();
      expect(files.length, 1);
      expect(files.first.path.endsWith(SafeNotesConfig.backupFileName), isTrue);

      expect(PreferencesStorage.isBackupNeeded, isFalse);
      expect(PreferencesStorage.lastBackupTime, isNotNull);

      // 验证备份内容为有效加密备份并能解出原始笔记
      final backupStr = files.first.readAsStringSync();
      final parsed = BackupFileCodec.parse(backupStr);
      expect(parsed, isA<BackupFileEncrypted>());
      final decoded = await BackupFileCodec.decryptEncrypted(
        parsed as BackupFileEncrypted,
        'test.password.123',
      );
      expect(decoded.length, 1);
      expect((decoded.first as Map)['title'], '秘密笔记');
      expect((decoded.first as Map)['description'], '绝密内容123456');
    });
  });

  group('ScheduledTask 禁止明文备份安全红线', () {
    test('会话密码为空时 unitBackupAttempt 必须返回 false 且记录错误', () async {
      PhraseHandler.destroy();
      expect(PhraseHandler.getPass, isEmpty);

      final result = await ScheduledTask.unitBackupAttempt();
      expect(result, isFalse);
      expect(ScheduledTask.lastBackupError, contains('会话密码不可用'));

      final files = tempBackupDir.listSync();
      expect(files, isEmpty, reason: '绝不能产生明文备份');
    });
  });

  group('ScheduledTask forceBackup 强制备份', () {
    test('forceBackup 绕过开关强制生成带指定文件名的备份', () async {
      await PreferencesStorage.setIsBackupOn(false);
      await PreferencesStorage.setIsBackupNeeded(false);
      PhraseHandler.initPass('test.password.123');

      final customName = 'forced_backup_test.snbak';
      final ok = await ScheduledTask.forceBackup(fileName: customName);

      expect(ok, isTrue);
      final targetFile = File('${tempBackupDir.path}/$customName');
      expect(targetFile.existsSync(), isTrue);

      final backupStr = targetFile.readAsStringSync();
      final parsed = BackupFileCodec.parse(backupStr);
      final decoded = await BackupFileCodec.decryptEncrypted(
        parsed as BackupFileEncrypted,
        'test.password.123',
      );
      expect((decoded.first as Map)['title'], '秘密笔记');
    });
  });
}
