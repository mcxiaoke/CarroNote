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
import 'package:shadcn_ui/shadcn_ui.dart';

// Project imports:
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/widgets/shad_settings_tiles.dart';

class InactivityTimerSetting extends StatefulWidget {
  const InactivityTimerSetting({super.key});

  @override
  State<InactivityTimerSetting> createState() => _InactivityTimerSettingState();
}

class _InactivityTimerSettingState extends State<InactivityTimerSetting> {
  var _selectedIndex = PreferencesStorage.inactivityTimeoutIndex;

  @override
  Widget build(BuildContext context) {
    final items = _inactivityItems;

    return Scaffold(
      appBar: AppBar(
        title: Text('Inactivity Timeout'.tr(), style: appBarTitle),
      ),
      body: shadSettingsList([
        shadSettingsCard([
          shadSwitchTile(
            context,
            icon: LucideIcons.smartphone,
            title: 'Logout upon inactivity'.tr(),
            description: 'Close and open app for change to take effect'.tr(),
            value: PreferencesStorage.isInactivityTimeoutOn,
            onChanged: (value) {
              PreferencesStorage.setIsInactivityTimeoutOn(value);
              setState(() {});
            },
          ),
        ]),
        shadSectionTitle(context, 'Inactivity Timeout'.tr()),
        shadSettingsCard([
          for (var i = 0; i < items.length; i++)
            shadRadioTile(
              context,
              title: items[i].prefix,
              description: items[i].helper,
              selected: _selectedIndex == i,
              onTap: () {
                PreferencesStorage.setInactivityTimeoutIndex(index: i);
                setState(() => _selectedIndex = i);
              },
            ),
        ]),
        const SizedBox(height: 12),
      ]),
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
// 注意：不得用插值字符串调用 .tr()，那样生成的 key 永远匹配不上语言包；
// 必须用静态 key 查表（见下方 _inactivityTimeoutKeyBySeconds）。
const Map<int, String> _inactivityTimeoutKeyBySeconds = {
  30: '30 seconds',
  60: '1 minute',
  120: '2 minutes',
  180: '3 minutes',
  300: '5 minutes',
  600: '10 minutes',
  900: '15 minutes',
};

List<Item> get _inactivityItems =>
    PreferencesStorage.kInactivityTimeoutChoicesSeconds.asMap().entries.map((
      entry,
    ) {
      final seconds = entry.value;
      final index = entry.key;
      final prefix = (_inactivityTimeoutKeyBySeconds[seconds] ?? '').tr();
      // 缺省值索引标出「Default」提示（原实现里 3 分钟标记为 Default）
      return Item(
        prefix: prefix,
        helper: index == PreferencesStorage.kDefaultInactivityTimeoutIndex
            ? 'Default'.tr()
            : null,
      );
    }).toList();
