/*
 * Copyright (C) Keshav Priyadarshi and others - All Rights Reserved.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 * You may use, distribute and modify this code under the
 * terms of the GPL-3.0+ license.
 *
 * See https://safenotes.dev for support or download.
 */

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:easy_localization/easy_localization.dart';
import 'package:local_session_timeout/local_session_timeout.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/app_theme.dart';
import 'package:safenotes/models/theme_seeds.g.dart';
import 'package:safenotes/sync/sync_config.dart';
import 'package:safenotes/utils/platform_ui.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/widgets/shad_settings_tiles.dart';

/// 设置 Hub 页：6 顶级入口（外观 / 同步 / 备份 / 安全 / 通用 / 关于）
///
/// 原单页 24 行长列表按 docs/settings-hub-ia-20260822.md 重构为 Hub + 二级页：
/// 同步与备份拆为顶级入口，移动端通过 pushNamed 进二级页，桌面端同样走 push（首版）；
/// 后续可升级为 Master-Detail 双栏，当前已通过 720 限宽居中解决过宽问题。
class SettingsScreen extends StatefulWidget {
  final StreamController<SessionState> sessionStateStream;

  const SettingsScreen({super.key, required this.sessionStateStream});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late String _themeValue;
  late String _displayValue;
  late String _syncStatusValue;
  late String _backupValue;
  late String _securityValue;
  late String _generalValue;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadDisplayValues();
  }

  void _loadDisplayValues() {
    _themeValue = _currentThemeColorName(context);
    _displayValue = _globalFontTypeValue();
    _syncStatusValue = _syncStatusValueString();
    _backupValue = PreferencesStorage.isBackupOn ? 'On'.tr() : 'Off'.tr();
    _securityValue = _securitySummary();
    _generalValue = SafeNotesConfig.mapLocaleName[context.locale.toString()]!;
  }

  void _refresh() => setState(_loadDisplayValues);

  @override
  Widget build(BuildContext context) {
    Provider.of<ThemeProvider>(context);
    return Scaffold(
      key: const Key('ui-settings-screen'),
      appBar: AppBar(title: Text('Settings'.tr(), style: appBarTitle)),
      body: shadSettingsList(_hubGroups(context)),
    );
  }

  List<Widget> _hubGroups(BuildContext context) {
    return [
      shadSectionTitle(context, 'Appearance'.tr()),
      shadSettingsCard([
        shadNavigationTile(
          context,
          key: const Key('ui-setting-hub-theme'),
          icon: LucideIcons.palette,
          title: 'Theme'.tr(),
          value: _themeValue,
          onTap: () async {
            await Navigator.pushNamed(context, '/themeSettings');
            _refresh();
          },
        ),
        shadNavigationTile(
          context,
          key: const Key('ui-setting-hub-display'),
          icon: LucideIcons.type,
          title: 'Display'.tr(),
          value: _displayValue,
          onTap: () async {
            await Navigator.pushNamed(context, '/displaySettings');
            _refresh();
          },
        ),
      ]),
      shadSectionTitle(context, 'Data'.tr()),
      shadSettingsCard([
        shadNavigationTile(
          context,
          key: const Key('ui-setting-hub-sync'),
          icon: LucideIcons.cloud,
          title: 'Sync Settings'.tr(),
          value: _syncStatusValue,
          onTap: () async {
            await Navigator.pushNamed(context, '/syncSettings');
            _refresh();
          },
        ),
        shadNavigationTile(
          context,
          key: const Key('ui-setting-hub-backup'),
          icon: LucideIcons.cloudUpload,
          title: 'Backup'.tr(),
          value: _backupValue,
          onTap: () async {
            await Navigator.pushNamed(context, '/backup');
            _refresh();
          },
        ),
      ]),
      shadSectionTitle(context, 'Security'.tr()),
      shadSettingsCard([
        shadNavigationTile(
          context,
          key: const Key('ui-setting-hub-security'),
          icon: LucideIcons.shield,
          title: 'Security'.tr(),
          value: _securityValue,
          onTap: () async {
            await Navigator.pushNamed(context, '/securitySettings');
            _refresh();
          },
        ),
      ]),
      shadSectionTitle(context, 'General'.tr()),
      shadSettingsCard([
        shadNavigationTile(
          context,
          key: const Key('ui-setting-hub-general'),
          icon: LucideIcons.slidersHorizontal,
          title: 'General'.tr(),
          value: _generalValue,
          onTap: () async {
            await Navigator.pushNamed(context, '/generalSettings');
            _refresh();
          },
        ),
        shadNavigationTile(
          context,
          key: const Key('ui-setting-hub-about'),
          icon: LucideIcons.info,
          title: 'About'.tr(),
          onTap: () async {
            await Navigator.pushNamed(context, '/about');
            if (mounted) setState(() {});
            _refresh();
          },
        ),
      ]),
      const SizedBox(height: 12),
    ];
  }

  String _currentThemeColorName(BuildContext context) {
    final isZh = context.locale.languageCode == 'zh';
    final seed = AppThemeSeeds.itemByIndex(
      PreferencesStorage.themeGroupIndex,
      PreferencesStorage.themeColorIndex,
    );
    return isZh ? seed.name : seed.nameEn;
  }

  String _globalFontTypeValue() {
    final t =
        AppFontType.values[PreferencesStorage.fontFamilyTypeIndex.clamp(
          0,
          AppFontType.values.length - 1,
        )];
    return switch (t) {
      AppFontType.serif => 'Serif'.tr(),
      AppFontType.sans => 'Sans-serif'.tr(),
      AppFontType.mono => 'Monospace'.tr(),
    };
  }

  String _securitySummary() {
    if (PreferencesStorage.isBiometricAuthEnabled ||
        PreferencesStorage.isPinAuthEnabled) {
      return 'On'.tr();
    }
    return 'Off'.tr();
  }

  String _syncStatusValueString() {
    if (!SyncConfig.isSyncEnabled) return 'Disabled'.tr();
    if (!SyncConfig.hasBackendConfig) return 'Not configured'.tr();
    return SyncConfig.backendDisplayName;
  }
}
