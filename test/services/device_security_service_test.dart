/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*
*/

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:safenotes/services/device_security_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DeviceSecurityStatus Risk Level Classification', () {
    test('Default safe status returns normal level', () {
      final status = DeviceSecurityStatus.safe(isSupportedPlatform: true);
      expect(status.riskLevel, SecurityRiskLevel.normal);
      expect(status.isNormal, isTrue);
      expect(status.isWarning, isFalse);
      expect(status.isCritical, isFalse);
      expect(status.triggeredRisks, isEmpty);
    });

    test('Unsupported platform always returns normal level', () {
      final status = DeviceSecurityStatus(
        isJailBroken: true,
        isRealDevice: false,
        isUsbDebuggingEnabled: true,
        isDevelopmentModeEnable: true,
        isOnExternalStorage: true,
        isMockLocation: true,
        isSupportedPlatform: false,
        checkTime: DateTime.now(),
      );
      expect(status.riskLevel, SecurityRiskLevel.normal);
      expect(status.isNormal, isTrue);
      expect(status.triggeredRisks, isEmpty);
    });

    test('Root / Jailbreak marks status as critical', () {
      final status = DeviceSecurityStatus(
        isJailBroken: true,
        isRealDevice: true,
        isUsbDebuggingEnabled: false,
        isDevelopmentModeEnable: false,
        isOnExternalStorage: false,
        isMockLocation: false,
        isSupportedPlatform: true,
        checkTime: DateTime.now(),
      );
      expect(status.riskLevel, SecurityRiskLevel.critical);
      expect(status.isCritical, isTrue);
      expect(status.triggeredRisks.any((r) => r.id == 'jailbroken'), isTrue);
    });

    test('Emulator environment marks status as critical', () {
      final status = DeviceSecurityStatus(
        isJailBroken: false,
        isRealDevice: false,
        isUsbDebuggingEnabled: false,
        isDevelopmentModeEnable: false,
        isOnExternalStorage: false,
        isMockLocation: false,
        isSupportedPlatform: true,
        checkTime: DateTime.now(),
      );
      expect(status.riskLevel, SecurityRiskLevel.critical);
      expect(status.isCritical, isTrue);
      expect(status.triggeredRisks.any((r) => r.id == 'emulator'), isTrue);
    });

    test('USB debugging marks status as warning', () {
      final status = DeviceSecurityStatus(
        isJailBroken: false,
        isRealDevice: true,
        isUsbDebuggingEnabled: true,
        isDevelopmentModeEnable: false,
        isOnExternalStorage: false,
        isMockLocation: false,
        isSupportedPlatform: true,
        checkTime: DateTime.now(),
      );
      expect(status.riskLevel, SecurityRiskLevel.warning);
      expect(status.isWarning, isTrue);
      expect(status.isCritical, isFalse);
      expect(status.triggeredRisks.any((r) => r.id == 'usb_debugging'), isTrue);
    });

    test('Developer options enabled marks status as warning', () {
      final status = DeviceSecurityStatus(
        isJailBroken: false,
        isRealDevice: true,
        isUsbDebuggingEnabled: false,
        isDevelopmentModeEnable: true,
        isOnExternalStorage: false,
        isMockLocation: false,
        isSupportedPlatform: true,
        checkTime: DateTime.now(),
      );
      expect(status.riskLevel, SecurityRiskLevel.warning);
      expect(status.isWarning, isTrue);
      expect(status.triggeredRisks.any((r) => r.id == 'dev_mode'), isTrue);
    });

    test('External storage installation marks status as warning', () {
      final status = DeviceSecurityStatus(
        isJailBroken: false,
        isRealDevice: true,
        isUsbDebuggingEnabled: false,
        isDevelopmentModeEnable: false,
        isOnExternalStorage: true,
        isMockLocation: false,
        isSupportedPlatform: true,
        checkTime: DateTime.now(),
      );
      expect(status.riskLevel, SecurityRiskLevel.warning);
      expect(status.isWarning, isTrue);
      expect(
        status.triggeredRisks.any((r) => r.id == 'external_storage'),
        isTrue,
      );
    });

    test('Mock location marks status as warning', () {
      final status = DeviceSecurityStatus(
        isJailBroken: false,
        isRealDevice: true,
        isUsbDebuggingEnabled: false,
        isDevelopmentModeEnable: false,
        isOnExternalStorage: false,
        isMockLocation: true,
        isSupportedPlatform: true,
        checkTime: DateTime.now(),
      );
      expect(status.riskLevel, SecurityRiskLevel.warning);
      expect(status.isWarning, isTrue);
      expect(status.triggeredRisks.any((r) => r.id == 'mock_location'), isTrue);
    });

    test(
      'Multiple mixed risks lists all triggered items and prioritizes critical',
      () {
        final status = DeviceSecurityStatus(
          isJailBroken: true,
          isRealDevice: false,
          isUsbDebuggingEnabled: true,
          isDevelopmentModeEnable: true,
          isOnExternalStorage: true,
          isMockLocation: true,
          isSupportedPlatform: true,
          checkTime: DateTime.now(),
        );
        expect(status.riskLevel, SecurityRiskLevel.critical);
        expect(status.isCritical, isTrue);
        expect(status.triggeredRisks.length, 6);
      },
    );
  });

  group('DeviceSecurityService Session Lifecycle and Platform Execution', () {
    setUp(() {
      DeviceSecurityService.instance.resetSessionPrompt();
      DeviceSecurityService.instance.cachedStatusForTesting = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('safe_device'), (
            MethodCall call,
          ) async {
            switch (call.method) {
              case 'isRealDevice':
                return true;
              case 'isJailBroken':
                return false;
              case 'usbDebuggingCheck':
                return false;
              case 'isDevelopmentModeEnable':
                return false;
              case 'isOnExternalStorage':
                return false;
              case 'isMockLocation':
                return false;
              default:
                return null;
            }
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('safe_device'), null);
      debugDefaultTargetPlatformOverride = null;
    });

    test('Session prompt tracking toggles correctly', () {
      final service = DeviceSecurityService.instance;
      expect(service.hasPromptedThisSession, isFalse);

      service.markPromptedThisSession();
      expect(service.hasPromptedThisSession, isTrue);

      service.resetSessionPrompt();
      expect(service.hasPromptedThisSession, isFalse);
    });

    test(
      'Desktop environment returns safe status without calling plugin',
      () async {
        final service = DeviceSecurityService.instance;
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        final status = await service.checkSecurity(forceRefresh: true);
        expect(status.isSupportedPlatform, isFalse);
        expect(status.riskLevel, SecurityRiskLevel.normal);
        expect(service.cachedStatus, isNotNull);
      },
    );

    test(
      'Mobile environment queries plugin and returns verified normal status',
      () async {
        final service = DeviceSecurityService.instance;
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final status = await service.checkSecurity(forceRefresh: true);
        expect(status.isSupportedPlatform, isTrue);
        expect(status.isRealDevice, isTrue);
        expect(status.isJailBroken, isFalse);
        expect(status.isUsbDebuggingEnabled, isFalse);
        expect(status.riskLevel, SecurityRiskLevel.normal);
        expect(service.cachedStatus, isNotNull);
      },
    );
  });
}
