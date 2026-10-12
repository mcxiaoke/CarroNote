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
import 'package:safenotes/widgets/app_dialogs.dart';

/// 对话框用户操作结果
enum DeviceSecurityDialogAction {
  /// 用户明确选择继续（自担风险 / 已知晓）
  continueAnyway,

  /// 退出应用
  exitApp,

  /// 前往系统设置
  openSettings,
}

/// 显示设备安全警报弹窗（红/黄分级）
Future<DeviceSecurityDialogAction?> showDeviceSecurityDialog(
  BuildContext context, {
  required DeviceSecurityStatus status,
}) {
  return showDialog<DeviceSecurityDialogAction>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      final theme = ShadTheme.of(ctx);
      final scheme = Theme.of(ctx).colorScheme;
      final isCritical = status.isCritical;
      final risks = status.triggeredRisks;

      final accentColor = isCritical ? scheme.error : const Color(0xFFD97706);
      final icon = isCritical
          ? LucideIcons.shieldAlert
          : LucideIcons.triangleAlert;
      final title = isCritical
          ? 'High-Risk Environment Warning'.tr()
          : 'Device Security Notice'.tr();
      final intro = isCritical
          ? 'A high-risk environment has been detected. Sandboxing may be compromised or running in an emulator. Entering credentials may expose your data.'
                .tr()
          : 'USB debugging or Developer Options are enabled. Connecting to untrusted computers may allow external inspection or data extraction.'
                .tr();

      return AlertDialog(
        constraints: kAppAlertConstraints,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: accentColor.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: accentColor, size: 24),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: theme.textTheme.h4.copyWith(
                  fontWeight: FontWeight.w600,
                  fontSize: 18,
                ),
              ),
            ),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 360),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  intro,
                  style: theme.textTheme.muted.copyWith(
                    fontSize: 13,
                    height: 1.45,
                    color: theme.colorScheme.foreground.withValues(alpha: 0.85),
                  ),
                ),
                if (risks.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Container(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.muted.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: accentColor.withValues(alpha: 0.25),
                      ),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: risks.map((risk) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(
                                  top: 5,
                                  right: 8,
                                ),
                                child: Container(
                                  width: 6,
                                  height: 6,
                                  decoration: BoxDecoration(
                                    color: accentColor,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      risk.title.tr(),
                                      style: theme.textTheme.small.copyWith(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      risk.description.tr(),
                                      style: theme.textTheme.muted.copyWith(
                                        fontSize: 12,
                                        height: 1.35,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          appDialogActions(
            ctx,
            isCritical
                ? [
                    OutlinedButton(
                      style: appDialogOutlineAction(),
                      onPressed: () => Navigator.of(
                        ctx,
                      ).pop(DeviceSecurityDialogAction.continueAnyway),
                      child: Text('Continue Anyway'.tr()),
                    ),
                    FilledButton(
                      style: appDialogFilledAction(
                        background: scheme.error,
                        foreground: scheme.onError,
                      ),
                      onPressed: () => Navigator.of(
                        ctx,
                      ).pop(DeviceSecurityDialogAction.exitApp),
                      child: Text('Exit App'.tr()),
                    ),
                  ]
                : [
                    OutlinedButton(
                      style: appDialogOutlineAction(),
                      onPressed: () => Navigator.of(
                        ctx,
                      ).pop(DeviceSecurityDialogAction.openSettings),
                      child: Text('System Settings'.tr()),
                    ),
                    FilledButton(
                      style: appDialogFilledAction(),
                      onPressed: () => Navigator.of(
                        ctx,
                      ).pop(DeviceSecurityDialogAction.continueAnyway),
                      child: Text('I Understand, Continue'.tr()),
                    ),
                  ],
          ),
        ],
      );
    },
  );
}
