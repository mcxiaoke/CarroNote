/*
 * Copyright (C) mcxiaoke 2026 - All Rights Reserved.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 * You may use, distribute and modify this code under the
 * terms of the GPL-3.0+ license.
 */

import 'dart:io';

import 'package:flutter/services.dart';

import 'package:core/core.dart';
import 'package:flutter_test/flutter_test.dart';

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
    // 重置去重指纹，避免上一个测试写入的指纹让本测试被「无变化跳过」
    await PreferencesStorage.setLastBackupFingerprint('');
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

    test('isBackupNeeded == false 时仍执行自动备份（R1 回归：标记失效不再阻断）', () async {
      await PreferencesStorage.setIsBackupNeeded(false);
      PhraseHandler.initPass('test.password.123');

      await ScheduledTask.backup();

      final files = tempBackupDir.listSync().whereType<File>().toList();
      expect(
        files.length,
        1,
        reason:
            '自动备份不能因 isBackupNeeded=false 被跳过，'
            '否则首次成功后所有自动备份永久失效',
      );
    });

    test('开关开启且待备份时成功生成加密备份并更新状态', () async {
      PhraseHandler.initPass('test.password.123');

      await ScheduledTask.backup();

      final files = tempBackupDir.listSync().whereType<File>().toList();
      expect(files.length, 1);
      expect(
        files.first.path.contains('carronote_auto_'),
        isTrue,
        reason: '自动备份文件名应为 carronote_auto_<ts>.snbak',
      );

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

    test('去重：数据无变化时再次备份不产生新文件', () async {
      PhraseHandler.initPass('test.password.123');

      // 第一次：数据未变，应生成 1 个文件并写入指纹
      await ScheduledTask.backup();
      expect(
        tempBackupDir.listSync().whereType<File>().length,
        1,
        reason: '首次备份应落盘',
      );

      // 第二次：数据完全相同，去重跳过，不再产生新文件
      await ScheduledTask.backup();
      expect(
        tempBackupDir.listSync().whereType<File>().length,
        1,
        reason: '数据无变化时应由指纹去重跳过，不新增文件',
      );
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

      // 场景化文件名：carronote_manual_<ts>.snbak
      final ok = await ScheduledTask.forceBackup(scene: BackupScene.manual);
      expect(ok, isTrue);

      final backups = tempBackupDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.snbak'))
          .toList();
      expect(
        backups,
        isNotEmpty,
        reason: 'forceBackup 应生成 carronote_manual_*.snbak',
      );
      final targetFile = backups.first;
      expect(
        targetFile.path.contains('carronote_manual_'),
        isTrue,
        reason: '文件名应含场景后缀 manual（carronote_<scene>_<ts>.snbak）',
      );

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
