/*
* Copyright (C) Keshav Priyadarshi and others - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
*
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*
* See https://safenotes.dev for support or download.
*/

// Dart imports:
import 'dart:async';

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:easy_localization/easy_localization.dart';
import 'package:local_session_timeout/local_session_timeout.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

// Project imports:
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/dialogs/backup_import.dart';
import 'package:safenotes/models/app_theme.dart';
import 'package:safenotes/models/session.dart';
import 'package:safenotes/sync/sync_config.dart';
import 'package:safenotes/utils/build_info.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/utils/url_launcher.dart';
import 'package:safenotes/views/settings/theme_setting.dart';
import 'package:safenotes/widgets/shad_settings_tiles.dart';

class SettingsScreen extends StatefulWidget {
  final StreamController<SessionState> sessionStateStream;

  const SettingsScreen({super.key, required this.sessionStateStream});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    // 主题切换时重建本页
    Provider.of<ThemeProvider>(context);

    return Scaffold(
      appBar: AppBar(
        title: Text('Settings'.tr(), style: appBarTitle),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: _settingsGroups(context),
      ),
    );
  }

  /// 各设置分区：分区标题 + 卡片（内含若干 tile，行间用分隔线）。
  List<Widget> _settingsGroups(BuildContext context) {
    final groups = <Widget>[
      shadSectionTitle(context, 'General'.tr()),
      shadSettingsCard([
        shadNavigationTile(
          context,
          icon: LucideIcons.cloudUpload,
          title: 'Backup'.tr(),
          value: PreferencesStorage.isBackupOn ? 'On'.tr() : 'Off'.tr(),
          onTap: () async {
            await Navigator.pushNamed(context, '/backup');
            setState(() {});
          },
        ),
        shadNavigationTile(
          context,
          icon: LucideIcons.download,
          title: 'Import Backup'.tr(),
          onTap: () async {
            await showImportDialog(context);
          },
        ),
        shadNavigationTile(
          context,
          icon: LucideIcons.languages,
          title: 'Language'.tr(),
          value: SafeNotesConfig.mapLocaleName[context.locale.toString()]!,
          subtitle:
              context.locale.toString() != 'en_US' ? 'Language'.tr() : null,
          onTap: () async {
            await Navigator.pushNamed(context, '/chooseLanguageSettings');
            setState(() {});
          },
        ),
      ]),
      shadSectionTitle(context, 'Style'.tr()),
      shadSettingsCard([
        shadSwitchTile(
          context,
          icon: LucideIcons.shrink,
          title: 'Compact Notes'.tr(),
          value: PreferencesStorage.isCompactPreview,
          onChanged: (v) {
            PreferencesStorage.setIsCompactPreview(v);
            setState(() {});
          },
        ),
        shadSwitchTile(
          context,
          icon: LucideIcons.clock,
          title: 'Relative Time'.tr(),
          description:
              'Show note timestamps as relative (e.g. 5 minutes ago). '
                      'Off shows absolute dates.'
                  .tr(),
          value: PreferencesStorage.isRelativeTime,
          onChanged: (v) {
            PreferencesStorage.setIsRelativeTime(v);
            setState(() {});
          },
        ),
        shadSwitchTile(
          context,
          icon: LucideIcons.arrowUpDown,
          title: 'Sort by Modified Date'.tr(),
          description: 'Sort notes by last modified time. '
                  'Off sorts by creation time.'
              .tr(),
          value: PreferencesStorage.isSortByModified,
          onChanged: (v) {
            PreferencesStorage.setIsSortByModified(v);
            setState(() {});
          },
        ),
        shadNavigationTile(
          context,
          icon: LucideIcons.moon,
          title: 'Dark Mode'.tr(),
          value: !PreferencesStorage.isThemeDark ? 'Off'.tr() : 'On'.tr(),
          onTap: () {
            showThemeBottomSheet(context);
            setState(() {});
          },
        ),
        shadSwitchTile(
          context,
          icon: LucideIcons.rotateCw,
          title: 'Auto Rotate'.tr(),
          description: 'Close and open app for change to take effect'.tr(),
          value: PreferencesStorage.isAutoRotate,
          onChanged: (v) {
            PreferencesStorage.setIsAutoRotate(v);
            setState(() {});
          },
        ),
        shadNavigationTile(
          context,
          icon: LucideIcons.palette,
          title: 'Notes Color'.tr(),
          value: !PreferencesStorage.isColorful ? 'Off'.tr() : 'On'.tr(),
          onTap: () async {
            await Navigator.pushNamed(context, '/chooseColorSettings');
            setState(() {});
          },
        ),
        shadSwitchTile(
          context,
          icon: LucideIcons.type,
          title: 'Markdown'.tr(),
          description:
              'Format note preview with Markdown. Off shows plain text.'.tr(),
          value: PreferencesStorage.isMarkdownEnabled,
          onChanged: (v) {
            PreferencesStorage.setIsMarkdownEnabled(v);
            setState(() {});
          },
        ),
      ]),
      shadSectionTitle(context, 'Security'.tr()),
      shadSettingsCard([
        shadNavigationTile(
          context,
          icon: LucideIcons.fingerprint,
          title: 'Biometric'.tr(),
          value: PreferencesStorage.isBiometricAuthEnabled
              ? 'On'.tr()
              : 'Off'.tr(),
          onTap: () async {
            await Navigator.pushNamed(context, '/biometricSetting');
            setState(() {});
          },
        ),
        shadNavigationTile(
          context,
          icon: LucideIcons.smartphone,
          title: 'Logout on Inactivity'.tr(),
          value: inactivityTimeoutValue(),
          onTap: () async {
            await Navigator.pushNamed(context, '/inactivityTimerSettings');
            setState(() {});
          },
        ),
        shadSwitchTile(
          context,
          icon: LucideIcons.monitorOff,
          title: 'Secure Display'.tr(),
          description:
              'When turned on, the content on the screen is treated as secure, '
                      'blocking background snapshots and preventing it from '
                      'appearing in screenshots or from being viewed on '
                      'non-secure displays.'
                  .tr(),
          value: PreferencesStorage.isFlagSecure,
          onChanged: (v) {
            PreferencesStorage.setIsFlagSecure(v);
            setState(() {});
          },
        ),
        shadSwitchTile(
          context,
          icon: LucideIcons.eyeOff,
          title: 'Incognito Keyboard'.tr(),
          value: PreferencesStorage.keyboardIncognito,
          onChanged: (v) {
            PreferencesStorage.setKeyboardIncognito(v);
            setState(() {});
          },
        ),
        shadNavigationTile(
          context,
          icon: LucideIcons.lock,
          title: 'Change Passphrase'.tr(),
          onTap: () async {
            await Navigator.pushNamed(context, '/changepassphrase');
          },
        ),
        shadNavigationTile(
          context,
          icon: LucideIcons.logOut,
          title: 'Logout'.tr(),
          destructive: true,
          onTap: () async {
            // 顺序与 main.dart 超时退出 logout() 保持一致：
            // 1. 先停会话监听；2. 导航离开（不 await）；
            // 3. 导航落地、HomePage 卸载后再清敏感状态。
            widget.sessionStateStream.add(SessionState.stopListening);

            if (context.mounted) {
              Navigator.pushNamedAndRemoveUntil(
                context,
                '/login',
                (Route<dynamic> route) => false,
                arguments: SessionArguments(
                  sessionStream: widget.sessionStateStream,
                  isKeyboardFocused: false,
                ),
              );
            }

            await Session.logout();
          },
        ),
      ]),
      shadSectionTitle(context, 'Sync'.tr()),
      shadSettingsCard([
        shadNavigationTile(
          context,
          icon: LucideIcons.cloud,
          title: 'Sync Settings'.tr(),
          value: _syncStatusValue(),
          onTap: () async {
            await Navigator.pushNamed(context, '/syncSettings');
            setState(() {});
          },
        ),
      ]),
      shadSectionTitle(context, 'Miscellaneous'.tr()),
      shadSettingsCard([
        shadNavigationTile(
          context,
          icon: LucideIcons.star,
          title: 'Rate Us'.tr(),
          onTap: () => _launch(SafeNotesConfig.playStoreUrl),
        ),
        shadNavigationTile(
          context,
          icon: LucideIcons.helpCircle,
          title: 'FAQs'.tr(),
          onTap: () => _launch(SafeNotesConfig.faqsUrl),
        ),
        shadNavigationTile(
          context,
          icon: LucideIcons.code,
          title: 'Source Code'.tr(),
          onTap: () => _launch(SafeNotesConfig.githubUrl),
        ),
        shadNavigationTile(
          context,
          icon: LucideIcons.mail,
          title: 'Email'.tr(),
          onTap: () => _launch(SafeNotesConfig.mailToForFeedback),
        ),
        shadNavigationTile(
          context,
          icon: LucideIcons.fileText,
          title: 'Open Source license'.tr(),
          onTap: () => _launch(SafeNotesConfig.openSourceLicense),
        ),
      ]),
      const SizedBox(height: 12),
      // 版本号等版权信息：独立于设置项的最底部小字（非可点击 item）
      footer(context),
    ];

    return groups;
  }

  Future<void> _launch(String url) async {
    try {
      await launchUrlExternal(Uri.parse(url));
    } catch (_) {
      // 忽略无法打开的情况
    }
  }

  String inactivityTimeoutValue() {
    // 取值走 PreferencesStorage 的统一来源。
    final index = PreferencesStorage.inactivityTimeoutIndex;
    final seconds = PreferencesStorage.kInactivityTimeoutChoicesSeconds[index];
    if (seconds < 60) return '$seconds sec';
    return '${seconds ~/ 60} min';
  }

  /// 同步状态显示值（三态）。
  String _syncStatusValue() {
    if (!SyncConfig.isSyncEnabled) return 'Disabled'.tr();
    if (!SyncConfig.hasBackendConfig) return 'Not configured'.tr();
    return SyncConfig.backendDisplayName;
  }
}

/// 底部小字：仅版本号 + 构建日期·githash 两行。
Widget footer(BuildContext context) {
  final theme = ShadTheme.of(context);
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Version ${SafeNotesConfig.appVersion}',
          style: theme.textTheme.muted.copyWith(fontSize: 12),
        ),
        const SizedBox(height: 2),
        Text(
          '${BuildInfo.buildDateReadable} · ${BuildInfo.gitHashShort}',
          style: theme.textTheme.muted.copyWith(fontSize: 12),
        ),
      ],
    ),
  );
}
