/*
 * 关于页面
 *
 * 当前为占位实现：仅展示 LOGO + 应用名 + 版本号 + 构建时间 + Git 提交信息，
 * 后续再逐步补充开源许可、贡献者、隐私说明等更多内容。
 */

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:easy_localization/easy_localization.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

// Project imports:
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/generated/build_info.g.dart';
import 'package:safenotes/utils/platform_ui.dart';
import 'package:safenotes/utils/styles.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text('About'.tr(), style: appBarTitle)),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // LOGO
                SizedBox(
                  width: 96,
                  height: 96,
                  child: Image.asset(SafeNotesConfig.appLogoPath),
                ),
                const SizedBox(height: 16),
                // 应用名 + 标语
                Text(
                  SafeNotesConfig.appName.tr(),
                  style: TextStyle(
                    fontFamily: uiFontFamily,
                    fontFamilyFallback: uiFontFamilyFallback,
                    fontWeight: FontWeight.bold,
                    fontSize: 22,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  SafeNotesConfig.appSlogan.tr(),
                  style: theme.textTheme.muted,
                ),
                const SizedBox(height: 24),
                // 版本 / 构建 / Git 信息
                ShadCard(
                  backgroundColor: theme.colorScheme.card,
                  border: ShadBorder.all(
                    color: theme.colorScheme.border,
                    width: 1,
                  ),
                  radius: BorderRadius.circular(12),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 18,
                  ),
                  child: Column(
                    children: [
                      _InfoRow(
                        label: 'Version'.tr(),
                        value: SafeNotesConfig.appVersion,
                      ),
                      _InfoRow(
                        label: 'Build'.tr(),
                        value: BuildInfo.buildDateReadable,
                      ),
                      _InfoRow(
                        label: 'Git Commit'.tr(),
                        value: BuildInfo.gitHashShort,
                      ),
                      _InfoRow(
                        label: 'Branch'.tr(),
                        value: BuildInfo.gitBranch,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 关于页信息行：左侧标签、右侧值（超出省略）。
class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.p.copyWith(
                color: theme.colorScheme.mutedForeground,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.p.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
