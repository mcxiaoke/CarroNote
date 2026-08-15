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
import 'package:safenotes/models/theme_seeds.g.dart';
import 'package:safenotes/sync/sync_config.dart';
import 'package:safenotes/utils/platform_ui.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/views/settings/backup_setting.dart';
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
      appBar: AppBar(title: Text('Settings'.tr(), style: appBarTitle)),
      body: shadSettingsList(_settingsGroups(context)),
    );
  }

  /// 各设置分区：分区标题 + 卡片（内含若干 tile，行间用分隔线）。
  ///
  /// 分组信息架构（IA 重构，见 docs/settings-sidebar-ia-design-20260815.md）：
  /// 按「使用频率 × 重要性」降序排列为 6 组：
  /// 外观（Appearance）→ 数据（Data）→ 安全（Security）→ 账户（Account）
  /// → 通用（General）→ 关于（About）。
  List<Widget> _settingsGroups(BuildContext context) {
    final groups = <Widget>[
      shadSectionTitle(context, 'Appearance'.tr()),
      shadSettingsCard([
        // 主题/配色在前（视觉类最高频）
        shadNavigationTile(
          context,
          icon: LucideIcons.moon,
          title: 'Dark mode'.tr(),
          value: !PreferencesStorage.isThemeDark ? 'Off'.tr() : 'On'.tr(),
          onTap: () {
            showThemeBottomSheet(context);
            setState(() {});
          },
        ),
        shadNavigationTile(
          context,
          icon: LucideIcons.paintbrush,
          title: 'Theme color'.tr(),
          value: _currentThemeColorName(context),
          onTap: () async {
            await Navigator.pushNamed(context, '/themeColorSettings');
            setState(() {});
          },
        ),
        shadNavigationTile(
          context,
          icon: LucideIcons.brush,
          title: 'Notes Color'.tr(),
          value: !PreferencesStorage.isColorful ? 'Off'.tr() : 'On'.tr(),
          onTap: () async {
            await Navigator.pushNamed(context, '/chooseColorSettings');
            setState(() {});
          },
        ),
        // 排版（紧凑/Markdown）居中
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
        // 时间与排序（信息呈现方式）靠后
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
          description:
              'Sort notes by last modified time. '
                      'Off sorts by creation time.'
                  .tr(),
          value: PreferencesStorage.isSortByModified,
          onChanged: (v) {
            PreferencesStorage.setIsSortByModified(v);
            setState(() {});
          },
        ),
      ]),
      shadSectionTitle(context, 'Data'.tr()),
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
          icon: LucideIcons.fileOutput,
          title: 'Export Backup'.tr(),
          onTap: () async {
            await startExportNotes(context);
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
      ]),
      shadSectionTitle(context, 'General'.tr()),
      shadSettingsCard([
        shadNavigationTile(
          context,
          icon: LucideIcons.languages,
          title: 'Language'.tr(),
          value: SafeNotesConfig.mapLocaleName[context.locale.toString()]!,
          subtitle: context.locale.toString() != 'en_US'
              ? 'Language'.tr()
              : null,
          onTap: () async {
            await Navigator.pushNamed(context, '/chooseLanguageSettings');
            setState(() {});
          },
        ),
        // Auto Rotate 为纯移动端选项，桌面/Web 隐藏该行（IA 方案 §3.3）
        if (!isDesktopPlatform)
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
        // 关于：低频信息页入口（源码 / 开源许可 / 反馈均在 About 页内）
        shadNavigationTile(
          context,
          icon: LucideIcons.info,
          title: 'About'.tr(),
          onTap: () async {
            await Navigator.pushNamed(context, '/about');
            setState(() {});
          },
        ),
      ]),
    ];

    return groups;
  }

  /// 当前主题色的语言化显示名（中文用中文名，其他语言用英文名）。
  String _currentThemeColorName(BuildContext context) {
    final isZh = context.locale.languageCode == 'zh';
    final seed = AppThemeSeeds.itemByIndex(
      PreferencesStorage.themeGroupIndex,
      PreferencesStorage.themeColorIndex,
    );
    return isZh ? seed.name : seed.nameEn;
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
