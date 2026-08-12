/*
 * 设备 ID 工具
 *
 * 用途：
 *   - 为 manifest header.lastModifiedBy 提供设备标识
 *   - 用于多设备同步冲突诊断（哪个设备最后修改了 manifest）
 *
 * 格式：<platform>-<id>
 *   - android-<androidId>
 *   - ios-<identifierForVendor>
 *   - windows-<deviceId>
 *   - macos-<platformUUID>
 *   - linux-<machineId>
 *
 * 注意：device_id 仅用于诊断和调试，不参与加密或权限控制。
 *   - Android: androidId（重装系统会变，重装 app 不变）
 *   - iOS: identifierForVendor（卸载重装会变）
 *   - 桌面端：使用系统级 UUID，相对稳定
 *
 * 测试支持：通过 [DeviceIdProvider.overrideForTesting] 可注入 mock 值。
 */

// Dart 原生导入
import 'dart:io' show Platform;
import 'package:safenotes/utils/platform_ui.dart';

// Package 导入
import 'package:device_info_plus/device_info_plus.dart';

/// 设备 ID 提供者
///
/// 单例模式，首次调用时缓存结果，避免重复查询系统 API。
class DeviceIdProvider {
  static final DeviceIdProvider instance = DeviceIdProvider._();

  DeviceIdProvider._();

  /// 缓存的设备 ID（首次调用后填充）
  String? _cachedDeviceId;

  /// 测试用 override（非 null 时直接返回此值）
  String? _overrideForTesting;

  /// 测试专用：注入 mock 设备 ID
  ///
  /// 用法：
  /// ```dart
  /// setUp(() {
  ///   DeviceIdProvider.instance.overrideForTesting('test-device-1');
  /// });
  /// tearDown(() {
  ///   DeviceIdProvider.instance.clearTestingOverride();
  /// });
  /// ```
  void overrideForTesting(String deviceId) {
    _overrideForTesting = deviceId;
    _cachedDeviceId = deviceId;
  }

  /// 测试专用：清除 mock 设备 ID
  void clearTestingOverride() {
    _overrideForTesting = null;
    _cachedDeviceId = null;
  }

  /// 获取设备 ID（格式：`<platform>-<id>`）
  ///
  /// 首次调用会查询系统 API（异步），后续调用返回缓存（同步）。
  /// 测试环境若调用了 [overrideForTesting]，直接返回 mock 值。
  Future<String> getDeviceId() async {
    // 测试 override 优先
    final override = _overrideForTesting;
    if (override != null) return override;

    // 缓存命中
    final cached = _cachedDeviceId;
    if (cached != null) return cached;

    // 首次查询系统 API
    final deviceId = await _queryDeviceId();
    _cachedDeviceId = deviceId;
    return deviceId;
  }

  /// 同步获取已缓存的设备 ID（未缓存时返回 null）
  ///
  /// 用于已初始化后的场景（如 sync 时）。
  /// 若未缓存，需先调用 [getDeviceId] 异步初始化。
  String? get cachedDeviceId => _cachedDeviceId;

  /// 查询系统 API 获取设备 ID
  Future<String> _queryDeviceId() async {
    final deviceInfo = DeviceInfoPlugin();

    if (isAndroid) {
      final info = await deviceInfo.androidInfo;
      return 'android-${info.id}';
    }

    if (isIOS) {
      final info = await deviceInfo.iosInfo;
      return 'ios-${info.identifierForVendor}';
    }

    if (Platform.isWindows) {
      final info = await deviceInfo.windowsInfo;
      return 'windows-${info.deviceId}';
    }

    if (Platform.isMacOS) {
      final info = await deviceInfo.macOsInfo;
      // systemGUID 可能为 null，兜底用 computerName + model
      final guid = info.systemGUID;
      if (guid != null && guid.isNotEmpty) {
        return 'macos-$guid';
      }
      return 'macos-${info.computerName}-${info.model}';
    }

    if (Platform.isLinux) {
      final info = await deviceInfo.linuxInfo;
      return 'linux-${info.machineId}';
    }

    // 兜底：未知平台
    return 'unknown-${DateTime.now().millisecondsSinceEpoch}';
  }
}
