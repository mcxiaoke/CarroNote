/*
 * Copyright (C) mcxiaoke 2026 - All Rights Reserved.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 * You may use, distribute and modify this code under the
 * terms of the GPL-3.0+ license.
 */

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/biometric_auth.dart';
import 'package:safenotes/models/pin_auth.dart';
import 'package:safenotes/models/session.dart';
import '../test_helpers.dart';

void main() {
  setUpAll(() async {
    await initFullEnv();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PreferencesStorage.init();
    PhraseHandler.destroy();
    PinAuth.testDevicePepperOverride = 'test-device-uuid-1';
  });

  tearDown(() async {
    PinAuth.testDevicePepperOverride = null;
    PhraseHandler.destroy();
    await PinAuth.disable();
    await BiometricAuth.disable();
    await disposeVault();
  });

  group('PinAuth 安全加固认证（单层信封、无明文wrapKey、设备绑定）', () {
    test('设置并验证正确 PIN 能解封出原始会话密码，且不存储明文 wrapKey', () async {
      PhraseHandler.initPass('vault-secret-pwd-123');

      await PinAuth.setPin('123456');
      expect(PreferencesStorage.isPinAuthEnabled, isTrue);
      expect(PreferencesStorage.pinLength, 6);
      expect(PreferencesStorage.pinFailedCount, 0);

      // 验证单层信封直接存储，且彻底不存在 _securePinWrapKey 和 _securePinEnvelopeKey
      const storage = FlutterSecureStorage();
      expect(await storage.read(key: '_securePinWrapKey'), isNull);
      expect(await storage.read(key: '_securePinEnvelopeKey'), isNull);
      final authKey = await storage.read(key: '_securePinAuthKey');
      expect(authKey, isNotNull);
      expect(authKey!.startsWith('v1:'), isTrue);

      // 检查桌面端 KDF 参数提升为 128MB / t=4 / p=4
      final kdfJson = await storage.read(key: '_securePinKdfKey');
      expect(kdfJson, isNotNull);
      final kdfMap = jsonDecode(kdfJson!) as Map<String, dynamic>;
      expect(kdfMap['memoryKiB'], equals(PinAuth.kDesktopArgon2idMemoryKib));
      expect(kdfMap['iterations'], equals(PinAuth.kDesktopArgon2idIterations));
      expect(
        kdfMap['parallelism'],
        equals(PinAuth.kDesktopArgon2idParallelism),
      );

      // 正确 PIN 验证
      final recovered = await PinAuth.verifyPin('123456');
      expect(recovered, 'vault-secret-pwd-123');
      expect(PreferencesStorage.pinFailedCount, 0);

      // 错误 PIN 验证
      final failed = await PinAuth.verifyPin('999999');
      expect(failed, isEmpty);
    });

    test('设备绑定（Device Binding）：在设备 B 上即使 PIN 正确也解密失败', () async {
      PhraseHandler.initPass('secret-pass-456');
      PinAuth.testDevicePepperOverride = 'device-hardware-pc-A';
      await PinAuth.setPin('888888');

      // 模拟数据被拷贝到设备 B（设备指纹改变）
      PinAuth.testDevicePepperOverride = 'device-hardware-pc-B';
      final res = await PinAuth.verifyPin('888888');
      expect(res, isEmpty, reason: '在不同硬件设备上离线解密必须失败');

      // 换回原设备 A 可以正常解密
      PinAuth.testDevicePepperOverride = 'device-hardware-pc-A';
      final ok = await PinAuth.verifyPin('888888');
      expect(ok, 'secret-pass-456');
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

    test('disable 彻底清除全部安全存储键与计数', () async {
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

    test('方案 B：修改主密码（Session.onPasswordSet）自动关闭 PIN 锁并销毁凭据', () async {
      PhraseHandler.initPass('initial-pwd');
      await PinAuth.setPin('123456');
      expect(PreferencesStorage.isPinAuthEnabled, isTrue);

      // 模拟修改主密码触发 onPasswordSet
      await Session.onPasswordSet('brand-new-password');

      // 验证 PIN 锁已被自动关闭，凭据已被清除
      expect(PreferencesStorage.isPinAuthEnabled, isFalse);
      expect(PreferencesStorage.pinFailedCount, 0);
      const storage = FlutterSecureStorage();
      expect(await storage.read(key: '_securePinAuthKey'), isNull);
      expect(await storage.read(key: '_securePinKdfKey'), isNull);
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
