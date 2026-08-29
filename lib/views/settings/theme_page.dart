/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

import 'package:flutter/material.dart';

import 'package:easy_localization/easy_localization.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/app_theme.dart';
import 'package:safenotes/models/theme_seeds.g.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/views/settings/theme_setting.dart';
import 'package:safenotes/widgets/shad_settings_tiles.dart';

class ThemeSettingsPage extends StatefulWidget {
  const ThemeSettingsPage({super.key});

  @override
  State<ThemeSettingsPage> createState() => _ThemeSettingsPageState();
}

class _ThemeSettingsPageState extends State<ThemeSettingsPage> {
  late String _themeColorName;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadDisplayValues();
  }

  void _loadDisplayValues() {
    _themeColorName = _currentThemeColorName(context);
  }

  void _refresh() => setState(_loadDisplayValues);

  @override
  Widget build(BuildContext context) {
    Provider.of<ThemeProvider>(context);
    return Scaffold(
      appBar: AppBar(title: Text('Theme'.tr(), style: appBarTitle)),
      body: shadSettingsList([
        shadSettingsCard([
          shadNavigationTile(
            context,
            key: const Key('ui-setting-item-darkmode'),
            icon: LucideIcons.moon,
            title: 'Dark mode'.tr(),
            value: !PreferencesStorage.isThemeDark ? 'Off'.tr() : 'On'.tr(),
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
              _refresh();
            },
          ),
        ]),
        const SizedBox(height: 12),
      ]),
    );
  }

  String _currentThemeColorName(BuildContext context) {
    final isZh = context.locale.languageCode == 'zh';
    final seed = AppThemeSeeds.itemByIndex(
      PreferencesStorage.themeGroupIndex,
      PreferencesStorage.themeColorIndex,
    );
    return isZh ? seed.name : seed.nameEn;
  }
}
