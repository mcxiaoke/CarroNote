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

// Project imports:
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/widgets/shad_settings_tiles.dart';

class LanguageSetting extends StatefulWidget {
  const LanguageSetting({super.key});

  @override
  State<LanguageSetting> createState() => _LanguageSettingState();
}

class _LanguageSettingState extends State<LanguageSetting> {
  @override
  Widget build(BuildContext context) {
    final items = SafeNotesConfig.languageItems;

    // 当前语言在列表中的下标：由 locale 反查语言显示名，再查下标。
    var selectedIndex = 0;
    final localeKey = context.locale.toString();
    if (SafeNotesConfig.mapLocaleName.containsKey(localeKey)) {
      selectedIndex =
          indexofLanguage(SafeNotesConfig.mapLocaleName[localeKey]!);
    }

    return Scaffold(
      appBar: AppBar(title: Text('Language'.tr(), style: appBarTitle)),
      body: shadSettingsList([
        shadSettingsCard([
          for (var i = 0; i < items.length; i++)
            shadRadioTile(
              context,
              title: items[i].prefix,
              description: items[i].helper,
              selected: selectedIndex == i,
              onTap: () {
                context.setLocale(SafeNotesConfig.allLocale[items[i].prefix]!);
                setState(() {});
              },
            ),
        ]),
        const SizedBox(height: 12),
      ]),
    );
  }
}

int indexofLanguage(String language) {
  for (var i = 0; i < SafeNotesConfig.languageItems.length; i++) {
    if (SafeNotesConfig.languageItems[i].prefix == language) return i;
  }
  return 0;
}
