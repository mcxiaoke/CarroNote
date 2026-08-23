/*
 * Copyright (C) mcxiaoke 2026 - All Rights Reserved.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 * You may use, distribute and modify this code under the
 * terms of the GPL-3.0+ license.
 */

import 'package:device_info_plus/device_info_plus.dart';
// ignore: depend_on_referenced_packages
import 'package:device_info_plus_platform_interface/device_info_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:safenotes/utils/device_id.dart';

class MockDeviceInfoPlatform extends DeviceInfoPlatform {
  @override
  Future<BaseDeviceInfo> deviceInfo() async {
    return AndroidDeviceInfo.fromMap(<String, dynamic>{
      'id': 'mock-android-id-5678',
      'host': 'mock-host',
      'tags': 'mock-tags',
      'type': 'mock-type',
      'model': 'mock-model',
      'board': 'mock-board',
      'brand': 'mock-brand',
      'device': 'mock-device',
      'product': 'mock-product',
      'display': 'mock-display',
      'hardware': 'mock-hardware',
      'bootloader': 'mock-bootloader',
      'fingerprint': 'mock-fingerprint',
      'manufacturer': 'mock-manufacturer',
      'name': 'mock-name',
      'isPhysicalDevice': true,
      'isLowRamDevice': false,
      'freeDiskSize': 1024 * 1024 * 100,
      'totalDiskSize': 1024 * 1024 * 500,
      'physicalRamSize': 1024 * 1024 * 1024 * 4,
      'availableRamSize': 1024 * 1024 * 1024 * 2,
      'supportedAbis': <String>['arm64-v8a'],
      'supported32BitAbis': <String>[],
      'supported64BitAbis': <String>['arm64-v8a'],
      'systemFeatures': <String>[],
      'version': <String, dynamic>{
        'baseOS': '',
        'codename': 'REL',
        'incremental': '1',
        'previewSdkInt': 0,
        'release': '13',
        'sdkInt': 33,
        'securityPatch': '2026-01-01',
      },
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    DeviceIdProvider.instance.clearTestingOverride();
    DeviceInfoPlatform.instance = MockDeviceInfoPlatform();
  });

  tearDown(() {
    DeviceIdProvider.instance.clearTestingOverride();
  });

  group('DeviceIdProvider 单元测试', () {
    test('初始未注入未查询时 cachedDeviceId 为 null', () {
      expect(DeviceIdProvider.instance.cachedDeviceId, isNull);
    });

    test('overrideForTesting 优先返回注入的 mock 设备 ID', () async {
      DeviceIdProvider.instance.overrideForTesting('custom-mock-device-id-123');

      expect(
        DeviceIdProvider.instance.cachedDeviceId,
        'custom-mock-device-id-123',
      );
      final id = await DeviceIdProvider.instance.getDeviceId();
      expect(id, 'custom-mock-device-id-123');
    });

    test('clearTestingOverride 重置覆盖值与缓存', () async {
      DeviceIdProvider.instance.overrideForTesting('temp-id');
      expect(DeviceIdProvider.instance.cachedDeviceId, 'temp-id');

      DeviceIdProvider.instance.clearTestingOverride();
      expect(DeviceIdProvider.instance.cachedDeviceId, isNull);
    });

    test('查询真实平台设备 ID 格式合法且命中缓存', () async {
      final id1 = await DeviceIdProvider.instance.getDeviceId();
      expect(id1, isNotEmpty);
      expect(id1, contains('mock-android-id-5678'));
      expect(DeviceIdProvider.instance.cachedDeviceId, id1);

      // 第二次调用直接命中缓存
      final id2 = await DeviceIdProvider.instance.getDeviceId();
      expect(id2, id1);
    });
  });
}
