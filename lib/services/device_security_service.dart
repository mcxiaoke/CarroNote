/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*
*/

import 'package:flutter/foundation.dart';

import 'package:safe_device/safe_device.dart';

import 'package:safenotes/utils/platform_ui.dart';

/// 安全风险等级
enum SecurityRiskLevel {
  /// 正常/安全
  normal,

  /// 中度提示（黄色：USB 调试、开发者选项、外置存储、模拟位置）
  warning,

  /// 严重高危（红色：Root/越狱、模拟器运行）
  critical,
}

/// 具体触发的风险项
class SecurityRiskItem {
  final String id;
  final String title;
  final String description;
  final SecurityRiskLevel level;

  const SecurityRiskItem({
    required this.id,
    required this.title,
    required this.description,
    required this.level,
  });
}

/// 设备安全环境检测结果快照
class DeviceSecurityStatus {
  final bool isJailBroken;
  final bool isRealDevice;
  final bool isUsbDebuggingEnabled;
  final bool isDevelopmentModeEnable;
  final bool isOnExternalStorage;
  final bool isMockLocation;
  final bool isSupportedPlatform;
  final DateTime checkTime;
  final Map<String, dynamic> extraDetails;

  const DeviceSecurityStatus({
    required this.isJailBroken,
    required this.isRealDevice,
    required this.isUsbDebuggingEnabled,
    required this.isDevelopmentModeEnable,
    required this.isOnExternalStorage,
    required this.isMockLocation,
    required this.isSupportedPlatform,
    required this.checkTime,
    this.extraDetails = const {},
  });

  /// 默认安全状态（用于不支持平台或异常回退）
  factory DeviceSecurityStatus.safe({bool isSupportedPlatform = false}) {
    return DeviceSecurityStatus(
      isJailBroken: false,
      isRealDevice: true,
      isUsbDebuggingEnabled: false,
      isDevelopmentModeEnable: false,
      isOnExternalStorage: false,
      isMockLocation: false,
      isSupportedPlatform: isSupportedPlatform,
      checkTime: DateTime.now(),
    );
  }

  /// 综合安全等级评定
  SecurityRiskLevel get riskLevel {
    if (!isSupportedPlatform) return SecurityRiskLevel.normal;
    // 红色高危：Root / 越狱，或非物理真机（模拟器/虚拟机环境）
    if (isJailBroken || !isRealDevice) {
      return SecurityRiskLevel.critical;
    }
    // 黄色提示：USB 调试、开发者模式、外置存储或模拟位置
    if (isUsbDebuggingEnabled ||
        isDevelopmentModeEnable ||
        isOnExternalStorage ||
        isMockLocation) {
      return SecurityRiskLevel.warning;
    }
    return SecurityRiskLevel.normal;
  }

  bool get isCritical => riskLevel == SecurityRiskLevel.critical;
  bool get isWarning => riskLevel == SecurityRiskLevel.warning;
  bool get isNormal => riskLevel == SecurityRiskLevel.normal;

  /// 获取当前命中的具体风险清单
  List<SecurityRiskItem> get triggeredRisks {
    if (!isSupportedPlatform) return const [];
    final risks = <SecurityRiskItem>[];

    if (isJailBroken) {
      risks.add(
        const SecurityRiskItem(
          id: 'jailbroken',
          title: 'Root / Jailbreak Detected',
          description:
              'System root privileges have been granted. Sandboxing may be compromised.',
          level: SecurityRiskLevel.critical,
        ),
      );
    }
    if (!isRealDevice) {
      risks.add(
        const SecurityRiskItem(
          id: 'emulator',
          title: 'Emulator Environment Detected',
          description:
              'The app is running in a virtual machine or emulator, not a physical device.',
          level: SecurityRiskLevel.critical,
        ),
      );
    }
    if (isUsbDebuggingEnabled) {
      risks.add(
        const SecurityRiskItem(
          id: 'usb_debugging',
          title: 'USB Debugging Enabled',
          description:
              'Connecting to untrusted computers may allow external commands or data extraction via ADB.',
          level: SecurityRiskLevel.warning,
        ),
      );
    }
    if (isDevelopmentModeEnable) {
      risks.add(
        const SecurityRiskItem(
          id: 'dev_mode',
          title: 'Developer Options Enabled',
          description:
              'Developer options are enabled on this device, which may lower system security restrictions.',
          level: SecurityRiskLevel.warning,
        ),
      );
    }
    if (isOnExternalStorage) {
      risks.add(
        const SecurityRiskItem(
          id: 'external_storage',
          title: 'Installed on External Storage',
          description:
              'App is installed on an external SD card, which can be physically accessed or modified.',
          level: SecurityRiskLevel.warning,
        ),
      );
    }
    if (isMockLocation) {
      risks.add(
        const SecurityRiskItem(
          id: 'mock_location',
          title: 'Mock Location Detected',
          description:
              'Mock location provider is active or available on this device.',
          level: SecurityRiskLevel.warning,
        ),
      );
    }

    return risks;
  }
}

/// 移动端设备安全环境检测服务（单例）
class DeviceSecurityService {
  DeviceSecurityService._();
  static final DeviceSecurityService instance = DeviceSecurityService._();

  DeviceSecurityStatus? _cachedStatus;
  DeviceSecurityStatus? get cachedStatus => _cachedStatus;

  /// 本次 App 运行会话内是否已经弹窗告警过
  bool _hasPromptedThisSession = false;
  bool get hasPromptedThisSession => _hasPromptedThisSession;

  /// 标记本次会话已告警
  void markPromptedThisSession() {
    _hasPromptedThisSession = true;
  }

  /// 重置会话告警标记（主要用于测试）
  @visibleForTesting
  void resetSessionPrompt() {
    _hasPromptedThisSession = false;
  }

  /// 注入测试状态（主要用于单元测试）
  @visibleForTesting
  set cachedStatusForTesting(DeviceSecurityStatus? status) {
    _cachedStatus = status;
  }

  /// 异步执行环境安全检测
  Future<DeviceSecurityStatus> checkSecurity({
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _cachedStatus != null) {
      return _cachedStatus!;
    }

    // 桌面端或 Web 端不调用 safe_device，避免 MissingPluginException
    if (!isMobilePlatform) {
      final safeStatus = DeviceSecurityStatus.safe(isSupportedPlatform: false);
      _cachedStatus = safeStatus;
      return safeStatus;
    }

    try {
      final isJailBroken = await SafeDevice.isJailBroken;
      final isRealDevice = await SafeDevice.isRealDevice;
      final isUsbDebuggingEnabled = isAndroid
          ? await SafeDevice.isUsbDebuggingEnabled
          : false;
      final isDevelopmentModeEnable = isAndroid
          ? await SafeDevice.isDevelopmentModeEnable
          : false;
      final isOnExternalStorage = isAndroid
          ? await SafeDevice.isOnExternalStorage
          : false;
      final isMockLocation = await SafeDevice.isMockLocation;

      Map<String, dynamic> extraDetails = {};
      try {
        if (isAndroid) {
          extraDetails = await SafeDevice.rootDetectionDetails;
        } else if (isIOS) {
          extraDetails = await SafeDevice.jailbreakDetails;
        }
      } catch (_) {
        // 忽略非关键调试信息提取异常
      }

      final status = DeviceSecurityStatus(
        isJailBroken: isJailBroken,
        isRealDevice: isRealDevice,
        isUsbDebuggingEnabled: isUsbDebuggingEnabled,
        isDevelopmentModeEnable: isDevelopmentModeEnable,
        isOnExternalStorage: isOnExternalStorage,
        isMockLocation: isMockLocation,
        isSupportedPlatform: true,
        checkTime: DateTime.now(),
        extraDetails: extraDetails,
      );
      _cachedStatus = status;
      return status;
    } catch (_) {
      // 容错降级
      final fallback = DeviceSecurityStatus.safe(isSupportedPlatform: true);
      _cachedStatus = fallback;
      return fallback;
    }
  }
}
