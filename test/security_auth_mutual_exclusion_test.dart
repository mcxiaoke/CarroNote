/*
 * Copyright (C) mcxiaoke 2026 - All Rights Reserved.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/biometric_auth.dart';
import 'package:safenotes/models/pin_auth.dart';
import 'test_helpers.dart';

void main() {
  setUpAll(() async {
    await initFullEnv();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PreferencesStorage.init();
  });

  tearDown(() async {
    await disposeVault();
  });

  test('isColorful 默认值为 false', () {
    expect(PreferencesStorage.isColorful, isFalse);
  });

  test('生物识别与 PIN 锁互斥：启用 PIN 自动关闭生物识别，启用生物识别自动关闭 PIN', () async {
    await prepareUnlockedVault(password: 'hello.1111');

    // 1. 初始状态：两者皆为关闭
    expect(PreferencesStorage.isBiometricAuthEnabled, isFalse);
    expect(PreferencesStorage.isPinAuthEnabled, isFalse);

    // 2. 启用生物识别
    await BiometricAuth.enable();
    expect(PreferencesStorage.isBiometricAuthEnabled, isTrue);
    expect(PreferencesStorage.isPinAuthEnabled, isFalse);

    // 3. 启用 PIN 锁 -> 自动关闭生物识别
    await PinAuth.setPin('1234');
    expect(PreferencesStorage.isPinAuthEnabled, isTrue);
    expect(PreferencesStorage.isBiometricAuthEnabled, isFalse);

    // 4. 再次启用生物识别 -> 自动关闭 PIN 锁
    await BiometricAuth.enable();
    expect(PreferencesStorage.isBiometricAuthEnabled, isTrue);
    expect(PreferencesStorage.isPinAuthEnabled, isFalse);
  });
}
