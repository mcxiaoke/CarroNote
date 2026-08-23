/*
 * Copyright (C) mcxiaoke 2026 - All Rights Reserved.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 * You may use, distribute and modify this code under the
 * terms of the GPL-3.0+ license.
 */

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/biometric_auth.dart';
import 'package:safenotes/models/pin_auth.dart';
import '../test_helpers.dart';

void main() {
  setUpAll(() async {
    await initFullEnv();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PreferencesStorage.init();
    PhraseHandler.destroy();
  });

  tearDown(() async {
    PhraseHandler.destroy();
    await PinAuth.disable();
    await BiometricAuth.disable();
    await disposeVault();
  });

  group('PinAuth 认证与两层信封加密机制', () {
    test('设置并验证正确 PIN 能解封出原始会话密码，错误 PIN 返回空串', () async {
      PhraseHandler.initPass('vault-secret-pwd-123');

      await PinAuth.setPin('123456');
      expect(PreferencesStorage.isPinAuthEnabled, isTrue);
      expect(PreferencesStorage.pinLength, 6);
      expect(PreferencesStorage.pinFailedCount, 0);

      // 正确 PIN 验证
      final recovered = await PinAuth.verifyPin('123456');
      expect(recovered, 'vault-secret-pwd-123');
      expect(PreferencesStorage.pinFailedCount, 0);

      // 错误 PIN 验证
      final failed = await PinAuth.verifyPin('999999');
      expect(failed, isEmpty);
    });

    test('凭据缺失时 verifyPin 返回空串且不崩溃', () async {
      final res = await PinAuth.verifyPin('123456');
      expect(res, isEmpty);
    });

    test('连续 5 次错误 PIN 达到阈值自动禁用 PIN 锁定并重置状态', () async {
      PhraseHandler.initPass('pass-123');
      await PinAuth.setPin('1122');
      expect(PreferencesStorage.isPinAuthEnabled, isTrue);

      // 1 ~ 4 次失败
      for (var i = 1; i <= 4; i++) {
        final locked = await PinAuth.onPinFailed();
        expect(locked, isFalse);
        expect(PreferencesStorage.pinFailedCount, i);
        expect(PreferencesStorage.isPinAuthEnabled, isTrue);
      }

      // 第 5 次失败触发自动锁定禁用
      final locked = await PinAuth.onPinFailed();
      expect(locked, isTrue);
      expect(PreferencesStorage.isPinAuthEnabled, isFalse);
      expect(PreferencesStorage.pinFailedCount, 0);
    });

    test('disable 彻底清除全部 4 个安全存储键', () async {
      PhraseHandler.initPass('pass-123');
      await PinAuth.setPin('1234');
      const storage = FlutterSecureStorage();

      await PinAuth.disable();

      expect(PreferencesStorage.isPinAuthEnabled, isFalse);
      expect(PreferencesStorage.pinFailedCount, 0);
      expect(await storage.read(key: '_securePinKdfKey'), isNull);
      expect(await storage.read(key: '_securePinEnvelopeKey'), isNull);
      expect(await storage.read(key: '_securePinWrapKey'), isNull);
      expect(await storage.read(key: '_securePinAuthKey'), isNull);
    });

    test('refreshCredential 联动刷新密码信封（无需重新输入 PIN）', () async {
      PhraseHandler.initPass('old-password');
      await PinAuth.setPin('654321');

      // 模拟修改密码后刷新
      PhraseHandler.initPass('new-password-789');
      await PinAuth.refreshCredential();

      // 使用原 PIN 应能解出新密码
      final pass = await PinAuth.verifyPin('654321');
      expect(pass, 'new-password-789');
    });

    test('wrapKey 缺失或会话密码为空时 refreshCredential 安全跳过', () async {
      const storage = FlutterSecureStorage();
      await storage.delete(key: '_securePinWrapKey');

      // 不应抛出任何异常
      await PinAuth.refreshCredential();
    });
  });

  group('BiometricAuth 凭据安全与旧版兼容', () {
    test('setAuthKey 使用随机包裹密钥加密存储，authKey 成功解包', () async {
      PhraseHandler.initPass('my-bio-password');

      await BiometricAuth.enable();
      expect(PreferencesStorage.isBiometricAuthEnabled, isTrue);

      const storage = FlutterSecureStorage();
      final authVal = await storage.read(key: '_secureBiometricAuthKey');
      expect(authVal, isNotNull);
      expect(authVal!.startsWith('v1:'), isTrue);

      final recovered = await BiometricAuth.authKey;
      expect(recovered, 'my-bio-password');
    });

    test('读取旧版明文格式凭据（无 v1: 前缀）保持兼容', () async {
      const storage = FlutterSecureStorage();
      await storage.write(
        key: '_secureBiometricAuthKey',
        value: 'legacy-unencrypted-password',
      );

      final res = await BiometricAuth.authKey;
      expect(res, 'legacy-unencrypted-password');
    });

    test('包裹密钥缺失或解密异常时 authKey 返回空串（防泄漏）', () async {
      const storage = FlutterSecureStorage();
      // 写入损坏的 v1 密文
      await storage.write(
        key: '_secureBiometricAuthKey',
        value: 'v1:corrupted_base64_payload',
      );
      await storage.delete(key: '_secureBiometricWrapKey');

      final res = await BiometricAuth.authKey;
      expect(res, isEmpty);
    });

    test('disable 清除密文与包裹密钥', () async {
      PhraseHandler.initPass('test-pass');
      await BiometricAuth.enable();
      const storage = FlutterSecureStorage();

      await BiometricAuth.disable();

      expect(PreferencesStorage.isBiometricAuthEnabled, isFalse);
      expect(await storage.read(key: '_secureBiometricAuthKey'), isNull);
      expect(await storage.read(key: '_secureBiometricWrapKey'), isNull);
    });
  });
}
