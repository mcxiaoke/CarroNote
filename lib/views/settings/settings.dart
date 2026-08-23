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

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'package:easy_localization/easy_localization.dart';
import 'package:local_session_timeout/local_session_timeout.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/app_theme.dart';
import 'package:safenotes/models/theme_seeds.g.dart';
import 'package:safenotes/sync/sync_config.dart';
import 'package:safenotes/utils/editor_text.dart';
import 'package:safenotes/utils/platform_ui.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/views/settings/editor_font_setting.dart';
import 'package:safenotes/widgets/shad_settings_tiles.dart';

/// 设置 Hub 页：顶级入口
class SettingsScreen extends StatefulWidget {
  final StreamController<SessionState> sessionStateStream;

  const SettingsScreen({super.key, required this.sessionStateStream});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late String _themeValue;
  late String _displayValue;
  late String _noteStyleValue;
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
    _noteStyleValue = _currentNoteStyleValue();
    _syncStatusValue = _syncStatusValueString();
    _backupValue = PreferencesStorage.isBackupOn ? 'On'.tr() : 'Off'.tr();
    _securityValue = _securitySummary();
    _generalValue =
        SafeNotesConfig.mapLocaleName[context.locale.toString()] ??
        context.locale.languageCode;
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
          icon: LucideIcons.slidersHorizontal,
          title: 'Display'.tr(),
          value: _displayValue,
          onTap: () async {
            await Navigator.pushNamed(context, '/displaySettings');
            _refresh();
          },
        ),
        shadNavigationTile(
          context,
          key: const Key('ui-setting-hub-notestyle'),
          icon: LucideIcons.type,
          title: 'Note style'.tr(),
          value: _noteStyleValue,
          onTap: () async {
            await Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const NoteStylePicker()),
            );
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
        if (!kIsWeb)
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

  String _currentNoteStyleValue() {
    final idx = PreferencesStorage.noteFontFamilyTypeIndex;
    final fontLabel = switch (idx) {
      0 => 'System'.tr(),
      1 => 'Sans-serif'.tr(),
      2 => 'Serif'.tr(),
      3 => 'Monospace'.tr(),
      _ => 'System'.tr(),
    };
    final sizeLabel = EditorText.labelOf(
      PreferencesStorage.editorFontSizeIndex,
    );
    return '$fontLabel · $sizeLabel';
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
