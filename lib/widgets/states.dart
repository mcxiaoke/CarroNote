/*
* Copyright (C) Keshav Priyadarshi and others - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*
* You should have received a copy of the GNU General Public License v3.0 with
* this file. If not, please visit https://www.gnu.org/licenses/gpl-3.0.html
*
* See https://safenotes.dev for support or download.
*/

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:easy_localization/easy_localization.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

// Project imports:
import 'package:safenotes/utils/spacing.dart';

/// 状态三件套（P0-5 / P3-11）：空 / 加载 / 错误。
///
/// 替代散落的 `Center(child: Text(...))` 与 `CircularProgressIndicator()`。

/// 空状态：图标 + 文案 + 可选 CTA。
Widget emptyState({
  required IconData icon,
  required String text,
  String? cta,
  VoidCallback? onCta,
}) {
  return Builder(
    builder: (context) {
      final colorScheme = Theme.of(context).colorScheme;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 48, color: colorScheme.onSurfaceVariant),
              const SizedBox(height: AppSpace.md),
              Text(
                text,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              if (cta != null && onCta != null) ...[
                const SizedBox(height: AppSpace.lg),
                ShadButton.outline(onPressed: onCta, child: Text(cta)),
              ],
            ],
          ),
        ),
      );
    },
  );
}

/// 加载态：骨架占位卡片（count 个），替代生硬转圈。
Widget loadingState({int count = 3}) {
  return Builder(
    builder: (context) {
      final colorScheme = Theme.of(context).colorScheme;
      return ListView.separated(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AppSpace.lg),
        itemCount: count,
        separatorBuilder: (_, _) => const SizedBox(height: AppSpace.md),
        itemBuilder: (context, index) => Container(
          height: 88,
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(AppShape.cardRadius),
          ),
        ),
      );
    },
  );
}

/// 错误态：图标 + 错误信息 + 可选重试。
Widget errorState({required String error, VoidCallback? onRetry}) {
  return Builder(
    builder: (context) {
      final colorScheme = Theme.of(context).colorScheme;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // P1-22：错误色统一走 shad destructive。
              Icon(
                LucideIcons.circleAlert,
                size: 48,
                color: ShadTheme.of(context).colorScheme.destructive,
              ),
              const SizedBox(height: AppSpace.md),
              Text(
                error,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              if (onRetry != null) ...[
                const SizedBox(height: AppSpace.lg),
                ShadButton.outline(
                  onPressed: onRetry,
                  child: Text('Retry'.tr()),
                ),
              ],
            ],
          ),
        ),
      );
    },
  );
}
