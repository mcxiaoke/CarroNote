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
import 'package:safenotes/data/preference_repository.dart';
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
  // 开关类偏好本地缓存：切换时 setState 只更新对应字段，避免用空 setState
  // 强制整页重建（原 17 处 `setState((){})` 空刷新模式，见 db 审查 P1-7）。
  late bool _isCompactPreview;
  late bool _isMarkdownEnabled;
  late bool _isRelativeTime;
  late bool _isSortByModified;
  late bool _isFlagSecure;
  late bool _keyboardIncognito;
  late bool _isAutoRotate;

  // 导航子页返回后需要刷新的展示值（value 列读 PreferencesStorage）。
  late String _themeColorName;
  late String _notesColorValue;
  late String _syncStatusValue;
  late String _backupValue;
  late String _biometricValue;
  late String _inactivityValue;
  late String _languageValue;

  @override
  void initState() {
    super.initState();
    _loadSwitchValues();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 展示值依赖 context.locale（easy_localization），需在依赖就绪后读取；
    // 语言切换等依赖变化时再次刷新（无需 setState，紧随其后的 build 会读到新值）。
    _loadDisplayValues();
  }

  /// 一次性从 PreferencesStorage 读入全部开关值（初始化用）。
  void _loadSwitchValues() {
    _isCompactPreview = context.read<PreferencesRepository>().isCompactPreview;
    _isMarkdownEnabled = context.read<PreferencesRepository>().isMarkdownEnabled;
    _isRelativeTime = context.read<PreferencesRepository>().isRelativeTime;
    _isSortByModified = context.read<PreferencesRepository>().isSortByModified;
    _isFlagSecure = context.read<PreferencesRepository>().isFlagSecure;
    _keyboardIncognito = context.read<PreferencesRepository>().keyboardIncognito;
    _isAutoRotate = context.read<PreferencesRepository>().isAutoRotate;
  }

  /// 读取展示值（value 列）；导航返回后调用以反映子页改动。
  void _loadDisplayValues() {
    _themeColorName = _currentThemeColorName(context);
    _notesColorValue = context.read<PreferencesRepository>().isColorful ? 'On'.tr() : 'Off'.tr();
    _syncStatusValue = _syncStatusValueString();
    _backupValue = context.read<PreferencesRepository>().isBackupOn ? 'On'.tr() : 'Off'.tr();
    _biometricValue = context.read<PreferencesRepository>().isBiometricAuthEnabled
        ? 'On'.tr()
        : 'Off'.tr();
    _inactivityValue = inactivityTimeoutValue();
    _languageValue = SafeNotesConfig.mapLocaleName[context.locale.toString()]!;
  }

  /// 导航返回后刷新展示值（非空 setState）。
  void _refreshDisplayValues() => setState(_loadDisplayValues);

  @override
  Widget build(BuildContext context) {
    // 主题切换时重建本页（Dark mode 弹层走 ThemeProvider 通知，无需手动 setState）
    Provider.of<ThemeProvider>(context);

    return Scaffold(
      key: const Key('ui-settings-screen'),
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
          key: const Key('ui-setting-item-darkmode'),
          icon: LucideIcons.moon,
          title: 'Dark mode'.tr(),
          // 值由 ThemeProvider 通知驱动重建，这里直接读偏好即可。
          value: !context.read<PreferencesRepository>().isThemeDark ? 'Off'.tr() : 'On'.tr(),
          onTap: () => showThemeBottomSheet(context),
        ),
        shadNavigationTile(
          context,
          key: const Key('ui-setting-item-themecolor'),
          icon: LucideIcons.paintbrush,
          title: 'Theme color'.tr(),
          value: _themeColorName,
          onTap: () async {
            await Navigator.pushNamed(context, '/themeColorSettings');
            _refreshDisplayValues();
          },
        ),
        shadNavigationTile(
          context,
          key: const Key('ui-setting-item-notescolor'),
          icon: LucideIcons.brush,
          title: 'Notes Color'.tr(),
          value: _notesColorValue,
          onTap: () async {
            await Navigator.pushNamed(context, '/chooseColorSettings');
            _refreshDisplayValues();
          },
        ),
        // 排版（紧凑/Markdown）居中
        shadSwitchTile(
          context,
          icon: LucideIcons.shrink,
          title: 'Compact Notes'.tr(),
          value: _isCompactPreview,
          onChanged: (v) {
            context.read<PreferencesRepository>().setIsCompactPreview(v);
            setState(() => _isCompactPreview = v);
          },
        ),
        shadSwitchTile(
          context,
          icon: LucideIcons.type,
          title: 'Markdown'.tr(),
          description:
              'Format note preview with Markdown. Off shows plain text.'.tr(),
          value: _isMarkdownEnabled,
          onChanged: (v) {
            context.read<PreferencesRepository>().setIsMarkdownEnabled(v);
            setState(() => _isMarkdownEnabled = v);
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
          value: _isRelativeTime,
          onChanged: (v) {
            context.read<PreferencesRepository>().setIsRelativeTime(v);
            setState(() => _isRelativeTime = v);
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
          value: _isSortByModified,
          onChanged: (v) {
            context.read<PreferencesRepository>().setIsSortByModified(v);
            setState(() => _isSortByModified = v);
          },
        ),
      ]),
      shadSectionTitle(context, 'Data'.tr()),
      shadSettingsCard([
        shadNavigationTile(
          context,
          key: const Key('ui-setting-item-sync'),
          icon: LucideIcons.cloud,
          title: 'Sync Settings'.tr(),
          value: _syncStatusValue,
          onTap: () async {
            await Navigator.pushNamed(context, '/syncSettings');
            _refreshDisplayValues();
          },
        ),
        shadNavigationTile(
          context,
          key: const Key('ui-setting-item-backup'),
          icon: LucideIcons.cloudUpload,
          title: 'Backup'.tr(),
          value: _backupValue,
          onTap: () async {
            await Navigator.pushNamed(context, '/backup');
            _refreshDisplayValues();
          },
        ),
        shadNavigationTile(
          context,
          key: const Key('ui-setting-item-exportbackup'),
          icon: LucideIcons.fileOutput,
          title: 'Export Backup'.tr(),
          onTap: () => startExportNotes(context),
        ),
        shadNavigationTile(
          context,
          key: const Key('ui-setting-item-importbackup'),
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
          key: const Key('ui-setting-item-biometric'),
          icon: LucideIcons.fingerprint,
          title: 'Biometric'.tr(),
          value: _biometricValue,
          onTap: () async {
            await Navigator.pushNamed(context, '/biometricSetting');
            _refreshDisplayValues();
          },
        ),
        shadNavigationTile(
          context,
          key: const Key('ui-setting-item-inactivity'),
          icon: LucideIcons.smartphone,
          title: 'Logout on Inactivity'.tr(),
          value: _inactivityValue,
          onTap: () async {
            await Navigator.pushNamed(context, '/inactivityTimerSettings');
            _refreshDisplayValues();
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
          value: _isFlagSecure,
          onChanged: (v) {
            context.read<PreferencesRepository>().setIsFlagSecure(v);
            setState(() => _isFlagSecure = v);
          },
        ),
        shadSwitchTile(
          context,
          icon: LucideIcons.eyeOff,
          title: 'Incognito Keyboard'.tr(),
          value: _keyboardIncognito,
          onChanged: (v) {
            context.read<PreferencesRepository>().setKeyboardIncognito(v);
            setState(() => _keyboardIncognito = v);
          },
        ),
        shadNavigationTile(
          context,
          key: const Key('ui-setting-item-changepassphrase'),
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
          key: const Key('ui-setting-item-language'),
          icon: LucideIcons.languages,
          title: 'Language'.tr(),
          value: _languageValue,
          subtitle: context.locale.toString() != 'en_US'
              ? 'Language'.tr()
              : null,
          onTap: () async {
            await Navigator.pushNamed(context, '/chooseLanguageSettings');
            _refreshDisplayValues();
          },
        ),
        // Auto Rotate 为纯移动端选项，桌面/Web 隐藏该行（IA 方案 §3.3）
        if (!isDesktopPlatform)
          shadSwitchTile(
            context,
            icon: LucideIcons.rotateCw,
            title: 'Auto Rotate'.tr(),
            description: 'Close and open app for change to take effect'.tr(),
            value: _isAutoRotate,
            onChanged: (v) {
              context.read<PreferencesRepository>().setIsAutoRotate(v);
              setState(() => _isAutoRotate = v);
            },
          ),
        // 关于：低频信息页入口（源码 / 开源许可 / 反馈均在 About 页内）
        shadNavigationTile(
          context,
          key: const Key('ui-setting-item-about'),
          icon: LucideIcons.info,
          title: 'About'.tr(),
          onTap: () => Navigator.pushNamed(context, '/about'),
        ),
      ]),
    ];

    return groups;
  }

  /// 当前主题色的语言化显示名（中文用中文名，其他语言用英文名）。
  String _currentThemeColorName(BuildContext context) {
    final isZh = context.locale.languageCode == 'zh';
    final seed = AppThemeSeeds.itemByIndex(
      context.read<PreferencesRepository>().themeGroupIndex,
      context.read<PreferencesRepository>().themeColorIndex,
    );
    return isZh ? seed.name : seed.nameEn;
  }

  String inactivityTimeoutValue() {
    // 取值走 PreferencesRepository 的统一来源（inactivityTimeout 已换算为秒）。
    final seconds = context.read<PreferencesRepository>().inactivityTimeout;
    if (seconds < 60) {
      return '{seconds} sec'.tr(namedArgs: {'seconds': '$seconds'});
    }
    return '{minutes} min'.tr(namedArgs: {'minutes': '${seconds ~/ 60}'});
  }

  /// 同步状态显示值（三态）。
  String _syncStatusValueString() {
    if (!SyncConfig.isSyncEnabled) return 'Disabled'.tr();
    if (!SyncConfig.hasBackendConfig) return 'Not configured'.tr();
    return SyncConfig.backendDisplayName;
  }
}
