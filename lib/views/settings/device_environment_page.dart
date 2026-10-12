/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*
*/

import 'package:flutter/material.dart';

import 'package:easy_localization/easy_localization.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/services/device_security_service.dart';
import 'package:safenotes/utils/platform_ui.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/utils/text_styles.dart';
import 'package:safenotes/widgets/shad_settings_tiles.dart';

class DeviceEnvironmentPage extends StatefulWidget {
  const DeviceEnvironmentPage({super.key});

  @override
  State<DeviceEnvironmentPage> createState() => _DeviceEnvironmentPageState();
}

class _DeviceEnvironmentPageState extends State<DeviceEnvironmentPage> {
  bool _isLoading = false;
  DeviceSecurityStatus? _status;

  @override
  void initState() {
    super.initState();
    _loadStatus(forceRefresh: false);
  }

  Future<void> _loadStatus({bool forceRefresh = false}) async {
    setState(() => _isLoading = true);
    final status = await DeviceSecurityService.instance.checkSecurity(
      forceRefresh: forceRefresh,
    );
    if (!mounted) return;
    setState(() {
      _status = status;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text('Device Environment'.tr(), style: appBarTitle),
        actions: [
          IconButton(
            icon: _isLoading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(LucideIcons.refreshCw, size: 20),
            tooltip: 'Recheck'.tr(),
            onPressed: _isLoading
                ? null
                : () => _loadStatus(forceRefresh: true),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: !isMobilePlatform
          ? _buildUnsupportedPlatform(context)
          : _isLoading && _status == null
          ? const Center(child: CircularProgressIndicator())
          : _buildContent(context, theme, scheme),
    );
  }

  Widget _buildUnsupportedPlatform(BuildContext context) {
    final theme = ShadTheme.of(context);
    return shadSettingsList([
      shadSettingsCard([
        Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                LucideIcons.info,
                size: 40,
                color: theme.colorScheme.mutedForeground,
              ),
              const SizedBox(height: 16),
              Text(
                'Device environment diagnostics are only available on Android and iOS.'
                    .tr(),
                textAlign: TextAlign.center,
                style: theme.textTheme.p,
              ),
            ],
          ),
        ),
      ]),
    ]);
  }

  Widget _buildContent(
    BuildContext context,
    ShadThemeData theme,
    ColorScheme scheme,
  ) {
    final status = _status ?? DeviceSecurityStatus.safe();
    final isCritical = status.isCritical;
    final isWarning = status.isWarning;

    final Color statusColor = isCritical
        ? scheme.error
        : isWarning
        ? const Color(0xFFD97706)
        : const Color(0xFF10B981);

    final IconData statusIcon = isCritical
        ? LucideIcons.shieldAlert
        : isWarning
        ? LucideIcons.triangleAlert
        : LucideIcons.shieldCheck;

    final String statusTitle = isCritical
        ? 'High-Risk Environment'.tr()
        : isWarning
        ? 'Potential Debugging Risk'.tr()
        : 'Device Environment Secure'.tr();

    final String statusDesc = isCritical
        ? 'Device is rooted or running in an emulator. Application sandbox isolation is compromised.'
              .tr()
        : isWarning
        ? 'System developer options or USB debugging are enabled. Disable them when not needed.'
              .tr()
        : 'No root, emulator, or insecure debugging configurations detected.'
              .tr();

    final formattedTime = DateFormat(
      'yyyy-MM-dd HH:mm:ss',
    ).format(status.checkTime);

    return shadSettingsList([
      // 顶部综合评估卡片
      ShadCard(
        padding: const EdgeInsets.all(18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(statusIcon, color: statusColor, size: 28),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    statusTitle,
                    style: theme.textTheme.h4.copyWith(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: isCritical
                          ? scheme.error
                          : isWarning
                          ? const Color(0xFFD97706)
                          : null,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    statusDesc,
                    style: theme.textTheme.muted.copyWith(
                      fontSize: AppTextSize.s12,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${'Last checked:'.tr()} $formattedTime',
                    style: theme.textTheme.muted.copyWith(
                      fontSize: 11,
                      color: theme.colorScheme.mutedForeground.withValues(
                        alpha: 0.8,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),

      // 检测项清单
      shadSectionTitle(context, 'Diagnostics Details'.tr()),
      shadSettingsCard([
        _buildItemTile(
          context,
          icon: LucideIcons.smartphone,
          title: 'Real Device'.tr(),
          description: status.isRealDevice
              ? 'Physical hardware device'.tr()
              : 'Emulator or virtual device detected'.tr(),
          badgeText: status.isRealDevice ? 'Pass'.tr() : 'Emulator'.tr(),
          badgeColor: status.isRealDevice
              ? const Color(0xFF10B981)
              : scheme.error,
        ),
        _buildItemTile(
          context,
          icon: LucideIcons.shieldOff,
          title: 'Root / Jailbreak'.tr(),
          description: status.isJailBroken
              ? 'Root / Jailbreak privileges detected'.tr()
              : 'No root privileges detected'.tr(),
          badgeText: status.isJailBroken ? 'Detected'.tr() : 'Secure'.tr(),
          badgeColor: status.isJailBroken
              ? scheme.error
              : const Color(0xFF10B981),
        ),
        _buildItemTile(
          context,
          icon: LucideIcons.cable,
          title: 'USB Debugging'.tr(),
          description: status.isUsbDebuggingEnabled
              ? 'ADB debugging is active'.tr()
              : 'USB debugging is turned off'.tr(),
          badgeText: status.isUsbDebuggingEnabled
              ? 'Enabled'.tr()
              : 'Disabled'.tr(),
          badgeColor: status.isUsbDebuggingEnabled
              ? const Color(0xFFD97706)
              : const Color(0xFF10B981),
        ),
        _buildItemTile(
          context,
          icon: LucideIcons.terminal,
          title: 'Developer Options'.tr(),
          description: status.isDevelopmentModeEnable
              ? 'System developer options are enabled'.tr()
              : 'Developer options are turned off'.tr(),
          badgeText: status.isDevelopmentModeEnable
              ? 'Enabled'.tr()
              : 'Disabled'.tr(),
          badgeColor: status.isDevelopmentModeEnable
              ? const Color(0xFFD97706)
              : const Color(0xFF10B981),
        ),
        _buildItemTile(
          context,
          icon: LucideIcons.hardDrive,
          title: 'External Storage'.tr(),
          description: status.isOnExternalStorage
              ? 'Installed on external SD card'.tr()
              : 'Installed on internal storage'.tr(),
          badgeText: status.isOnExternalStorage
              ? 'External'.tr()
              : 'Internal'.tr(),
          badgeColor: status.isOnExternalStorage
              ? const Color(0xFFD97706)
              : const Color(0xFF10B981),
        ),
        _buildItemTile(
          context,
          icon: LucideIcons.mapPinOff,
          title: 'Mock Location'.tr(),
          description: status.isMockLocation
              ? 'Mock location is enabled'.tr()
              : 'No mock location detected'.tr(),
          badgeText: status.isMockLocation ? 'Enabled'.tr() : 'Normal'.tr(),
          badgeColor: status.isMockLocation
              ? const Color(0xFFD97706)
              : const Color(0xFF10B981),
        ),
      ]),
      const SizedBox(height: 16),

      // 底部说明
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(
          'Automatic security warning dialogs are only triggered in Release builds. This page provides a real-time diagnostics dashboard for device security parameters.'
              .tr(),
          style: theme.textTheme.muted.copyWith(
            fontSize: AppTextSize.s12,
            height: 1.45,
          ),
        ),
      ),
      const SizedBox(height: 16),
    ]);
  }

  Widget _buildItemTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String description,
    required String badgeText,
    required Color badgeColor,
  }) {
    final theme = ShadTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.muted.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 20, color: theme.colorScheme.foreground),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.p.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: theme.textTheme.muted.copyWith(
                    fontSize: AppTextSize.s12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: badgeColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: badgeColor.withValues(alpha: 0.25),
                width: 1,
              ),
            ),
            child: Text(
              badgeText,
              style: TextStyle(
                color: badgeColor,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
