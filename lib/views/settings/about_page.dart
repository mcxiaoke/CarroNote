/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

/*
 * 关于页面
 *
 * 承载应用标识（LOGO + 应用名 + 版本号 + 构建时间 + Git 提交信息），
 * 以及源码 / 开源许可 / 反馈等低频信息链接（承接原设置页 Miscellaneous 组，
 * 见 docs/settings-sidebar-ia-design-20260815.md §4.2）。
 */

import 'package:flutter/material.dart';

import 'package:core/core.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/generated/build_info.g.dart';
import 'package:safenotes/utils/dev_mode.dart';
import 'package:safenotes/utils/platform_ui.dart';
import 'package:safenotes/utils/snack_message.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/utils/text_styles.dart';
import 'package:safenotes/utils/url_launcher.dart';
import 'package:safenotes/widgets/shad_settings_tiles.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text('About'.tr(), style: appBarTitle)),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // LOGO（连点开启 dev 模式）
                const _DevModeTapLogo(),
                const SizedBox(height: 16),
                // 应用名 + 标语
                Text(
                  SafeNotesConfig.appName,
                  style: TextStyle(
                    fontFamily: uiFontFamily,
                    fontFamilyFallback: uiFontFamilyFallback,
                    fontWeight: FontWeight.bold,
                    fontSize: AppTextSize.s20,
                  ),
                ),
                const SizedBox(height: 6),
                Text(SafeNotesConfig.appSlogan, style: theme.textTheme.muted),
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
                const SizedBox(height: 12),
                // 低频信息链接：源码 / 开源许可 / 反馈（承接原 Miscellaneous 组）
                shadSettingsCard([
                  shadNavigationTile(
                    context,
                    icon: LucideIcons.code,
                    title: 'Source Code'.tr(),
                    onTap: () => _launch(SafeNotesConfig.sourceCodeUrl),
                  ),
                  shadNavigationTile(
                    context,
                    icon: LucideIcons.fileText,
                    title: 'Open Source license'.tr(),
                    onTap: () => _launch(SafeNotesConfig.openSourceLicense),
                  ),
                  shadNavigationTile(
                    context,
                    icon: LucideIcons.messagesSquare,
                    title: 'Help and Feedback'.tr(),
                    onTap: () => _launch(SafeNotesConfig.mailToForFeedback),
                  ),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _launch(String url) async {
    try {
      await launchUrlExternal(Uri.parse(url));
    } catch (_) {
      // 忽略无法打开的情况
    }
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
          Text(
            label,
            style: theme.textTheme.p.copyWith(
              color: theme.colorScheme.mutedForeground,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
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

/// About 页大 LOGO：连点 [DevMode.tapThreshold] 次（5 次）开启 dev 模式。
///
/// 隐藏入口原在设置页底部版本号区域，设置页版本信息已移至 drawer / 侧栏底部
/// 后，此入口改挂在 About 页大图标上（见 docs/settings-sidebar-ia-design-20260815.md）。
/// debug 构建恒为 dev 模式，连点无附加效果。
class _DevModeTapLogo extends StatefulWidget {
  const _DevModeTapLogo();

  @override
  State<_DevModeTapLogo> createState() => _DevModeTapLogoState();
}

class _DevModeTapLogoState extends State<_DevModeTapLogo> {
  int _tapCount = 0;
  DateTime? _lastTap;

  /// 连点计数：两次点击间隔超过 3 秒则重置，避免误触累计。
  void _handleTap() {
    final now = DateTime.now();
    if (_lastTap != null && now.difference(_lastTap!).inSeconds > 3) {
      _tapCount = 0;
    }
    _lastTap = now;
    _tapCount++;
    if (_tapCount >= DevMode.tapThreshold) {
      _tapCount = 0;
      _enableDevMode();
    }
  }

  Future<void> _enableDevMode() async {
    final wasActive = DevMode.isActive;
    final changed = await DevMode.enable();
    if (!mounted) return;
    showSnackBarMessage(
      context,
      changed
          ? 'Developer mode enabled'.tr()
          : 'Already in developer mode'.tr(),
    );
    if (!wasActive) {
      Log.settings.i('关于页连点 ${DevMode.tapThreshold} 次开启 dev 模式');
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _handleTap,
      child: SizedBox(
        width: 96,
        height: 96,
        child: Image.asset(
          SafeNotesConfig.appLogoPath,
          fit: BoxFit.contain,
          semanticLabel: SafeNotesConfig.appName,
        ),
      ),
    );
  }
}
