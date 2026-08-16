// 契约测试：SharedPreferencesPreferencesRepository 的 key/默认值/语义
//
// 背景：P2 重构把视图层从静态 `PreferencesStorage` 迁移到注入的
// `SharedPreferencesPreferencesRepository`。本测试把「repository 读写的 key、
// 默认值、以及 isThemeDark/inactivityTimeout 等易错语义」锁成契约，
// 防止 repository 与真实 PreferencesStorage 的 key 漂移（一眼看不出的行为差异）。
//
// 注意：key 字符串刻意**硬编码**在这里（而非复用常量），因为契约测试的目的
// 就是锁定「repository 使用的 key == 真实持久化 key」这一事实；若将来改了
// key，本测试会先行变红。

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/data/preference_repository.dart';

Future<SharedPreferencesPreferencesRepository> _repoWith(
  Map<String, Object> values,
) async {
  SharedPreferences.setMockInitialValues(values);
  final prefs = await SharedPreferences.getInstance();
  return SharedPreferencesPreferencesRepository(prefs: prefs);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('默认值（未写入任何偏好时）', () {
    test('bool 偏好默认值', () async {
      final repo = await _repoWith({});
      expect(repo.isDimTheme, true, reason: 'isDimTheme 默认 true');
      expect(repo.isLocalDarkSwitchEnabled, false);
      expect(repo.isSystemDarkLightSwitchEnabled, true);
      expect(repo.isGridView, true);
      expect(repo.isNewFirst, true);
      expect(repo.isCompactPreview, false);
      expect(repo.isMarkdownEnabled, true);
      expect(repo.isRelativeTime, false);
      expect(repo.isSortByModified, true);
      expect(repo.isColorful, true);
      expect(repo.isFlagSecure, true);
      expect(repo.isBiometricAuthEnabled, false);
      expect(repo.keyboardIncognito, true);
      expect(repo.isInactivityTimeoutOn, true);
      expect(repo.isBackupOn, false);
      expect(repo.isBackupNeeded, true);
      expect(repo.isDevMode, false);
      expect(repo.isAutoRotate, false);
    });

    test('int 偏好默认值', () async {
      final repo = await _repoWith({});
      expect(repo.appVersionCode, 1);
      expect(repo.themeGroupIndex, 0);
      expect(repo.themeColorIndex, 0);
      expect(repo.colorfulNotesColorIndex, 0);
      expect(repo.biometricAttemptAllTimeCount, 0);
      expect(repo.inactivityTimeoutIndex, 3, reason: '缺省索引 3（3 分钟）');
      expect(repo.inactivityTimeout, 180, reason: '缺省 3 分钟 = 180s');
      expect(repo.focusTimeout, 180, reason: 'focus 默认同 inactivity（180s）');
      expect(repo.preInactivityLogoutCounter, 15);
      expect(repo.noOfLogginAttemptAllowed, 4);
      expect(repo.bruteforceLockOutTime, 30);
      expect(repo.maxBackupRetryAttempts, 50);
      expect(repo.backupRedundancyCounter, 0);
      expect(repo.noOfLoginsBeforeNextPassphraseRememberChallenge, 5);
    });

    test('String 偏好默认值', () async {
      final repo = await _repoWith({});
      expect(repo.lastBackupTime, '');
      expect(repo.backupDirectory, '');
    });
  });

  group('setter 写入正确的 SharedPreferences key', () {
    test('bool setter', () async {
      final repo = await _repoWith({});
      final prefs = await SharedPreferences.getInstance();

      await repo.setIsThemeDark(true);
      expect(prefs.getBool('isthemedark'), true);

      await repo.setIsDimTheme(true);
      expect(prefs.getBool('isDimTheme'), true);

      await repo.setLocalDarkSwitchEnabled(true);
      expect(prefs.getBool('isLocalDarkSwitchEnabled'), true);

      await repo.setSystemDarkLightSwitchEnabled(false);
      expect(prefs.getBool('isSystemDarkLightSwitchEnabled'), false);

      await repo.setIsGridView(false);
      expect(prefs.getBool('isGridView'), false);

      await repo.setIsNewFirst(false);
      expect(prefs.getBool('isNewFirst'), false);

      await repo.setIsCompactPreview(true);
      expect(prefs.getBool('isCompactPreview'), true);

      await repo.setIsMarkdownEnabled(false);
      expect(prefs.getBool('isMarkdownEnabled'), false);

      await repo.setIsRelativeTime(true);
      expect(prefs.getBool('isRelativeTime'), true);

      await repo.setIsSortByModified(false);
      expect(prefs.getBool('isSortByModified'), false);

      await repo.setIsColorful(false);
      expect(prefs.getBool('isColorful'), false);

      await repo.setIsFlagSecure(false);
      expect(prefs.getBool('isFlagSecure'), false);

      await repo.setIsBiometricAuthEnabled(true);
      expect(prefs.getBool('isBiometricAuthEnabled'), true);

      await repo.setKeyboardIncognito(false);
      expect(
        prefs.getBool('keyboardIcognito'),
        false,
        reason: '保留原拼写 keyboardIcognito，与 PreferencesStorage 一致',
      );

      await repo.setIsInactivityTimeoutOn(false);
      expect(prefs.getBool('isInactivityTimeoutOn'), false);

      await repo.setIsBackupOn(true);
      expect(prefs.getBool('isBackupOn'), true);

      await repo.setIsBackupNeeded(false);
      expect(prefs.getBool('isBackupNeeded'), false);

      await repo.setDevMode(true);
      expect(prefs.getBool('devModeEnabled'), true);

      await repo.setIsAutoRotate(true);
      expect(prefs.getBool('isAutoRotate'), true);
    });

    test('int setter', () async {
      final repo = await _repoWith({});
      final prefs = await SharedPreferences.getInstance();

      await repo.setThemeGroupIndex(2);
      expect(prefs.getInt('themeGroupIndex'), 2);

      await repo.setThemeColorIndex(3);
      expect(prefs.getInt('themeColorIndex'), 3);

      await repo.setDarkThemeEnum(index: 1);
      expect(prefs.getInt('isDarkThemeEnum'), 1);

      await repo.setColorfulNotesColorIndex(4);
      expect(prefs.getInt('colorfulNotesColorIndex'), 4);

      await repo.setInactivityTimeoutIndex(index: 1);
      expect(prefs.getInt('inactivityTimeout'), 1);

      await repo.incrementBiometricAttemptAllTimeCount();
      expect(prefs.getInt('biometricAttemptAllTimeCount'), 1);
      await repo.incrementBiometricAttemptAllTimeCount();
      expect(prefs.getInt('biometricAttemptAllTimeCount'), 2);

      await repo.incrementBackupRedundancyCounter();
      expect(prefs.getInt('backupRedundancyCounter'), 1);
    });

    test('String setter', () async {
      final repo = await _repoWith({});
      final prefs = await SharedPreferences.getInstance();

      await repo.setLastBackupTime();
      expect(prefs.getString('lastBackupTime'), isNotEmpty);

      await repo.setBackupDirectory('/tmp/backup');
      expect(prefs.getString('backupDirectory'), '/tmp/backup');
    });
  });

  group('isThemeDark 语义', () {
    test('显式深色 + 关闭跟随系统 → true', () async {
      final repo = await _repoWith({
        'isthemedark': true,
        'isSystemDarkLightSwitchEnabled': false,
      });
      expect(repo.isThemeDark, true);
    });

    test('显式浅色 + 关闭跟随系统 → false', () async {
      final repo = await _repoWith({
        'isthemedark': false,
        'isSystemDarkLightSwitchEnabled': false,
      });
      expect(repo.isThemeDark, false);
    });

    test('跟随系统开启 → 返回系统亮度（忽略显式值）', () async {
      final repo = await _repoWith({
        'isthemedark': true,
        'isSystemDarkLightSwitchEnabled': true,
      });
      final systemDark =
          WidgetsBinding.instance.platformDispatcher.platformBrightness ==
          Brightness.dark;
      expect(repo.isThemeDark, systemDark);
    });

    test('未显式设置 + 跟随系统开启 → 返回系统亮度', () async {
      final repo = await _repoWith({});
      final systemDark =
          WidgetsBinding.instance.platformDispatcher.platformBrightness ==
          Brightness.dark;
      expect(repo.isThemeDark, systemDark);
    });
  });

  group('inactivityTimeout 语义', () {
    test('索引越界/非法回退缺省 3', () async {
      final repoHigh = await _repoWith({'inactivityTimeout': 99});
      expect(repoHigh.inactivityTimeoutIndex, 3);

      final repoNeg = await _repoWith({'inactivityTimeout': -1});
      expect(repoNeg.inactivityTimeoutIndex, 3);
    });

    test('合法索引直接返回', () async {
      final repo = await _repoWith({'inactivityTimeout': 0});
      expect(repo.inactivityTimeoutIndex, 0);
      expect(repo.inactivityTimeout, 30);

      final repo5 = await _repoWith({'inactivityTimeout': 5});
      expect(repo5.inactivityTimeoutIndex, 5);
      expect(repo5.inactivityTimeout, 600);
    });
  });

  group('版本号与逃生通道', () {
    test('setAppVersionCodeToCurrent 写入当前应用版本号', () async {
      final repo = await _repoWith({});
      await repo.setAppVersionCodeToCurrent();
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getInt('appVersionCode'),
        SafeNotesConfig.appVersionCode,
        reason: '必须写 SafeNotesConfig.appVersionCode，禁止硬编码',
      );
    });

    test('clearVaultRelatedKeys 删除 passphrasehash', () async {
      final repo = await _repoWith({'passphrasehash': 'stale-hash'});
      await repo.clearVaultRelatedKeys();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('passphrasehash'), isFalse);
    });
  });
}
