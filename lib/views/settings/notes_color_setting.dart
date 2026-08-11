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
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

// Project imports:
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/utils/notes_color.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/widgets/shad_settings_tiles.dart';

class ColorPallet extends StatefulWidget {
  const ColorPallet({super.key});

  @override
  State<ColorPallet> createState() => ColorPalletState();
}

class ColorPalletState extends State<ColorPallet> {
  var _selectedIndex = PreferencesStorage.colorfulNotesColorIndex;
  final items = allNotesColorTheme;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Notes Color'.tr(), style: appBarTitle)),
      body: shadSettingsList([
        shadSettingsCard([
          shadSwitchTile(
            context,
            icon: LucideIcons.palette,
            title: 'Colorful Notes'.tr(),
            description: 'Choose the note color theme from below'.tr(),
            value: PreferencesStorage.isColorful,
            onChanged: (_) {
              // 颜色开关走 Provider，主界面卡片配色需要立即刷新。
              Provider.of<NotesColor>(context, listen: false).toggleColor();
              setState(() {});
            },
          ),
        ]),
        const SizedBox(height: 12),
        _preview(context),
        shadSectionTitle(context, 'Notes Color'.tr()),
        shadSettingsCard([
          for (var i = 0; i < items.length; i++)
            shadRadioTile(
              context,
              title: items[i].prefix.tr(),
              description: items[i].helper?.tr(),
              selected: _selectedIndex == i,
              leading: _swatch(items[i].colorList, height: 36, width: 36),
              onTap: () {
                PreferencesStorage.setColorfulNotesColorIndex(i);
                setState(() => _selectedIndex = i);
              },
            ),
        ]),
        const SizedBox(height: 12),
      ]),
    );
  }

  /// 当前所选配色的大色条预览。
  Widget _preview(BuildContext context) {
    return ShadCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            items[_selectedIndex].prefix.tr(),
            style: ShadTheme.of(context).textTheme.small,
          ),
          const SizedBox(height: 10),
          _swatch(items[_selectedIndex].colorList, height: 44, radius: 12),
        ],
      ),
    );
  }

  /// 色板：把一组主题色横向平铺成圆角色条。
  ///
  /// [width] 为空时撑满可用宽度（用于顶部大预览）。
  Widget _swatch(
    List<dynamic> colors, {
    required double height,
    double? width,
    double radius = 10,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: width ?? double.infinity,
        height: height,
        child: Row(
          children: [
            for (final color in colors)
              Expanded(child: ColoredBox(color: color as Color)),
          ],
        ),
      ),
    );
  }
}
