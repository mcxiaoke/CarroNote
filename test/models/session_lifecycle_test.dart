/*
 * Copyright (C) mcxiaoke 2026 - All Rights Reserved.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 * You may use, distribute and modify this code under the
 * terms of the GPL-3.0+ license.
 */

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:core/core.dart';
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

    test('Session.onPasswordSet 密码变更后同步刷新会话与 PIN/生物识别凭据', () async {
      PhraseHandler.initPass('old-p');
      await PinAuth.setPin('1234');

      Session.onPasswordSet('changed-password-3');
      expect(PhraseHandler.getPass, 'changed-password-3');

      // 等待 Session.onPasswordSet 内部触发的异步凭据刷新完成
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final pinResult = await PinAuth.verifyPin('1234');
      expect(pinResult, 'changed-password-3');
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
