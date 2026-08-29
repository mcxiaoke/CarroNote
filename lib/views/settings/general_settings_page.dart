/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

import 'package:flutter/material.dart';

import 'package:easy_localization/easy_localization.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/utils/dev_mode.dart';
import 'package:safenotes/utils/platform_ui.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/widgets/shad_settings_tiles.dart';

class GeneralSettingsPage extends StatefulWidget {
  const GeneralSettingsPage({super.key});

  @override
  State<GeneralSettingsPage> createState() => _GeneralSettingsPageState();
}

class _GeneralSettingsPageState extends State<GeneralSettingsPage> {
  late bool _isAutoRotate;
  late String _languageValue;

  @override
  void initState() {
    super.initState();
    _isAutoRotate = PreferencesStorage.isAutoRotate;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _languageValue =
        SafeNotesConfig.mapLocaleName[context.locale.toString()] ??
        context.locale.languageCode;
  }

  void _refresh() => setState(() {
    _languageValue =
        SafeNotesConfig.mapLocaleName[context.locale.toString()] ??
        context.locale.languageCode;
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('General'.tr(), style: appBarTitle)),
      body: shadSettingsList([
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
              _refresh();
            },
          ),
          if (!isDesktopPlatform)
            shadSwitchTile(
              context,
              icon: LucideIcons.rotateCw,
              title: 'Auto Rotate'.tr(),
              description: 'Close and open app for change to take effect'.tr(),
              value: _isAutoRotate,
              onChanged: (v) {
                PreferencesStorage.setIsAutoRotate(v);
                setState(() => _isAutoRotate = v);
              },
            ),
          if (DevMode.isActive)
            KeyedSubtree(
              key: const Key('ui-setting-switch-devmode'),
              child: shadSwitchTile(
                context,
                icon: LucideIcons.bug,
                title: 'Developer Mode'.tr(),
                description: 'Enable debug panel, full logs and log web server.'
                    .tr(),
                value: true,
                onChanged: (v) async {
                  await DevMode.setActive(v);
                  if (mounted) setState(() {});
                },
              ),
            ),
        ]),
        const SizedBox(height: 12),
      ]),
    );
  }
}
