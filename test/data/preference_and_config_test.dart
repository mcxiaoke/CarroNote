/*
 * Copyright (C) mcxiaoke 2026 - All Rights Reserved.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 * You may use, distribute and modify this code under the
 * terms of the GPL-3.0+ license.
 */

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:safenotes/data/preference_and_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PreferencesStorage.init();
  });

  group('PreferencesStorage managedTags 标签池管理', () {
    test('初始未设置时返回默认标签池', () {
      expect(
        PreferencesStorage.managedTags,
        PreferencesStorage.kDefaultManagedTags,
      );
    });

    test('setManagedTags 归一化与去重', () async {
      await PreferencesStorage.setManagedTags([' 标签A ', '标签B', '标签A', '']);
      final tags = PreferencesStorage.managedTags;
      expect(tags, ['标签A', '标签B']);
    });

    test('addManagedTag 仅追加不存在的非空标签', () async {
      await PreferencesStorage.setManagedTags(['工作']);
      await PreferencesStorage.addManagedTag('生活');
      await PreferencesStorage.addManagedTag('工作'); // 重复应忽略
      await PreferencesStorage.addManagedTag('   '); // 空白应忽略

      expect(PreferencesStorage.managedTags, ['工作', '生活']);
    });

    test('removeManagedTag 移除指定标签', () async {
      await PreferencesStorage.setManagedTags(['工作', '生活', '学习']);
      await PreferencesStorage.removeManagedTag('生活');
      await PreferencesStorage.removeManagedTag('不存在的标签'); // 忽略

      expect(PreferencesStorage.managedTags, ['工作', '学习']);
    });
  });

  group('PreferencesStorage inactivityTimeout 自动锁定时长与越界容错', () {
    test('初始默认值为索引 3（180 秒）', () {
      expect(
        PreferencesStorage.inactivityTimeoutIndex,
        PreferencesStorage.kDefaultInactivityTimeoutIndex,
      );
      expect(PreferencesStorage.inactivityTimeout, 180);
      expect(PreferencesStorage.focusTimeout, 180);
    });

    test('设置有效索引正确更新秒数', () async {
      await PreferencesStorage.setInactivityTimeoutIndex(index: 0);
      expect(PreferencesStorage.inactivityTimeoutIndex, 0);
      expect(PreferencesStorage.inactivityTimeout, 30);

      await PreferencesStorage.setInactivityTimeoutIndex(index: 4);
      expect(PreferencesStorage.inactivityTimeoutIndex, 4);
      expect(PreferencesStorage.inactivityTimeout, 300);
    });

    test('索引越界（负数或超出范围）安全回退到默认 180s', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('inactivityTimeout', -1);
      expect(
        PreferencesStorage.inactivityTimeoutIndex,
        PreferencesStorage.kDefaultInactivityTimeoutIndex,
      );
      expect(PreferencesStorage.inactivityTimeout, 180);

      await prefs.setInt('inactivityTimeout', 99);
      expect(
        PreferencesStorage.inactivityTimeoutIndex,
        PreferencesStorage.kDefaultInactivityTimeoutIndex,
      );
      expect(PreferencesStorage.inactivityTimeout, 180);
    });
  });

  group('SafeNotesConfig 备份与导出文件名生成', () {
    test('backupFileName 冗余计数为 0 时无数字后缀，递增后带数字后缀', () async {
      expect(PreferencesStorage.backupRedundancyCounter, 0);
      expect(SafeNotesConfig.backupFileName, 'secure_notes_backup.snbak');

      await PreferencesStorage.incrementBackupRedundancyCounter();
      expect(PreferencesStorage.backupRedundancyCounter, 1);
      expect(SafeNotesConfig.backupFileName, 'secure_notes_backup1.snbak');

      await PreferencesStorage.incrementBackupRedundancyCounter();
      expect(PreferencesStorage.backupRedundancyCounter, 2);
      expect(SafeNotesConfig.backupFileName, 'secure_notes_backup2.snbak');
    });

    test('manualBackupFileName 包含时间戳且格式合法', () {
      final fileName = SafeNotesConfig.manualBackupFileName;
      expect(
        RegExp(r'^secure_notes_backup_\d{8}_\d{6}\.snbak$').hasMatch(fileName),
        isTrue,
        reason: '实际文件名: $fileName',
      );
    });

    test('exportFileNameFor 加密与明文导出格式正确且带时间戳', () {
      final encryptedName = SafeNotesConfig.exportFileNameFor(encrypted: true);
      expect(
        RegExp(r'^safenotes_\d{8}_\d{6}\.snbak$').hasMatch(encryptedName),
        isTrue,
        reason: '实际加密导出名: $encryptedName',
      );

      final plaintextName = SafeNotesConfig.exportFileNameFor(encrypted: false);
      expect(
        RegExp(r'^safenotes_\d{8}_\d{6}\.json$').hasMatch(plaintextName),
        isTrue,
        reason: '实际明文导出名: $plaintextName',
      );
    });
  });

  group('PreferencesStorage clearVaultRelatedKeys 逃生通道清理', () {
    test('彻底清理保险库相关偏好键', () async {
      await PreferencesStorage.setIsBiometricAuthEnabled(true);
      await PreferencesStorage.setIsPinAuthEnabled(true);

      expect(PreferencesStorage.isBiometricAuthEnabled, isTrue);
      expect(PreferencesStorage.isPinAuthEnabled, isTrue);

      await PreferencesStorage.clearVaultRelatedKeys();

      expect(PreferencesStorage.isBiometricAuthEnabled, isFalse);
      expect(PreferencesStorage.isPinAuthEnabled, isFalse);
      expect(PreferencesStorage.pinFailedCount, 0);
    });
  });
}
