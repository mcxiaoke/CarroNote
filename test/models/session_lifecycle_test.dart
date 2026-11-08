/*
 * Copyright (C) mcxiaoke 2026 - All Rights Reserved.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 * You may use, distribute and modify this code under the
 * terms of the GPL-3.0+ license.
 */

import 'package:core/core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/biometric_auth.dart';
import 'package:safenotes/models/pin_auth.dart';
import 'package:safenotes/models/session.dart';
import 'package:safenotes/sync/sync_service.dart';
import '../test_helpers.dart';

void main() {
  setUpAll(() async {
    await initFullEnv();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PreferencesStorage.init();
    await prepareUnlockedVault(password: 'login-pass-1');
  });

  tearDown(() async {
    PhraseHandler.destroy();
    await PinAuth.disable();
    await BiometricAuth.disable();
    await disposeVault();
  });

  group('Session 生命周期与认证联动', () {
    test('Session.login 初始化 PhraseHandler 并联动刷新凭据', () async {
      await PreferencesStorage.setIsBiometricAuthEnabled(true);

      Session.login('new-login-pass-2');
      expect(PhraseHandler.getPass, 'new-login-pass-2');

      // 等待 Session.login 内部触发的异步凭据刷新完成
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await BiometricAuth.authKey, 'new-login-pass-2');
    });

    test('Session.onPasswordSet 密码变更后刷新会话并销毁 PIN 凭据（方案 B）', () async {
      PhraseHandler.initPass('old-p');
      await PinAuth.setPin('1234');
      expect(PreferencesStorage.isPinAuthEnabled, isTrue);

      await Session.onPasswordSet('changed-password-3');
      expect(PhraseHandler.getPass, 'changed-password-3');

      // 方案 B（docs/pin-lock-design.md §4）：主密码变更即销毁 PIN 凭据，
      // 旧 PIN 不得再能解出任何密码。此前本用例断言的是"PIN 跟随新密码刷新"，
      // 与实现和设计文档相反，属于 2026-10-12 加固后遗留的过期断言。
      expect(PreferencesStorage.isPinAuthEnabled, isFalse);
      expect(await PinAuth.verifyPin('1234'), isEmpty);
    });

    test('Session.logout 清空内存 dataKey、PhraseHandler 并登出同步服务', () async {
      PhraseHandler.initPass('login-pass-1');
      await PreferencesStorage.setIsBackupOn(false); // 避免测试触发真实备份IO

      // 登出前 dataKey 与密码均存在
      expect(PhraseHandler.getPass, isNotEmpty);
      expect(NotesDatabase.instance.isEncryptionEnabled, isTrue);

      await Session.logout();

      // 登出后内存敏感数据已全部清除
      expect(PhraseHandler.getPass, isEmpty);
      expect(NotesDatabase.instance.isEncryptionEnabled, isFalse);
      expect(SyncService.instance.state.status, SyncStatus.uninitialized);
    });
  });
}
