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
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

// Package imports:
import 'package:easy_localization/easy_localization.dart';
import 'package:settings_ui/settings_ui.dart';
import 'package:safenotes/utils/settings_platform.dart';

// Project imports:
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/app_theme.dart';
import 'package:safenotes/utils/styles.dart';

class InactivityTimerSetting extends StatefulWidget {
  const InactivityTimerSetting({super.key});

  @override
  State<InactivityTimerSetting> createState() => _InactivityTimerSettingState();
}

class _InactivityTimerSettingState extends State<InactivityTimerSetting> {
  var _selectedIndex = PreferencesStorage.inactivityTimeoutIndex;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Inactivity Timeout'.tr(),
          style: appBarTitle,
        ),
      ),
      body: _settings(),
    );
  }

  Widget _settings() {
    return SettingsList(
      platform: currentDevicePlatform,
      lightTheme: const SettingsThemeData(),
      darkTheme: SettingsThemeData(
        settingsListBackground: AppThemes.darkSettingsScaffold,
        settingsSectionBackground: AppThemes.darkSettingsCanvas,
      ),
      sections: [
        SettingsSection(
          //title: Text('Always on'),
          tiles: <SettingsTile>[
            SettingsTile.switchTile(
              initialValue: PreferencesStorage.isInactivityTimeoutOn,
              title: Text('Logout upon inactivity'.tr()),
              onToggle: (value) {
                PreferencesStorage.setIsInactivityTimeoutOn(value);
                setState(() {});
              },
              enabled: true,
              description:
                  Text('Close and open app for change to take effect'.tr()),
            ),
          ],
        ),
        CustomSettingsSection(
          child: CustomSettingsTile(
            child: _buildTimeList(context),
          ),
        ),
      ],
    );
  }

  Widget _buildTimeList(BuildContext context) {
    final items = _inactivityItems;
    return CupertinoPageScaffold(
      child: SingleChildScrollView(
        child: CupertinoFormSection.insetGrouped(
          backgroundColor: PreferencesStorage.isThemeDark
              ? AppThemes.darkSettingsScaffold
              : const Color(0x00000000),
          decoration: PreferencesStorage.isThemeDark
              ? BoxDecoration(
                  color: AppThemes.darkSettingsCanvas,
                  borderRadius: BorderRadius.circular(15),
                )
              : null,
          children: [
            ...List.generate(
              items.length,
              (index) => GestureDetector(
                onTap: () => setState(() {
                  _selectedIndex = index;
                  PreferencesStorage.setInactivityTimeoutIndex(index: index);
                  setState(() {});
                }),
                child: AbsorbPointer(
                  child: buildCupertinoFormRow(
                    items[index].prefix,
                    items[index].helper,
                    selected: _selectedIndex == index,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildCupertinoFormRow(
    String prefix,
    String? helper, {
    bool selected = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 5, bottom: 5),
      child: CupertinoFormRow(
        prefix: Text(prefix),
        helper: helper != null
            ? Text(
                helper,
                style: Theme.of(context).textTheme.bodySmall,
              )
            : null,
        child: selected
            ? const Padding(
                padding: EdgeInsets.only(right: 5),
                child: Icon(
                  CupertinoIcons.check_mark,
                  color: Color.fromARGB(255, 45, 118, 234),
                  size: 20,
                ),
              )
            : Container(),
      ),
    );
  }
}

class Item {
  final String prefix;
  final String? helper;
  const Item({required this.prefix, this.helper});
}

// 评审 #18：展示列表改为从 PreferenceStorage 的唯一数据源派生，
// 消除 inactivity_setting.dart 与 preference_and_config.dart 双份硬编码。
// 翻译键在语言包里按「1 minute / N minutes / 30 seconds」存在，按值生成。
List<Item> get _inactivityItems =>
    PreferencesStorage.kInactivityTimeoutChoicesSeconds.asMap().entries.map((
      entry,
    ) {
      final seconds = entry.value;
      final index = entry.key;
      String prefix;
      if (seconds < 60) {
        prefix = '$seconds seconds'.tr();
      } else if (seconds == 60) {
        prefix = '1 minute'.tr();
      } else {
        prefix = '${seconds ~/ 60} minutes'.tr();
      }
      // 缺省值索引标出「Default」提示（原实现里 3 分钟标记为 Default）
      return Item(
        prefix: prefix,
        helper: index == PreferencesStorage.kDefaultInactivityTimeoutIndex
            ? 'Default'.tr()
            : null,
      );
    }).toList();
