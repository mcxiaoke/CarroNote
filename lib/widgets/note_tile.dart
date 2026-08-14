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
import 'package:core/core.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

// Project imports:
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/utils/notes_color.dart';
import 'package:safenotes/utils/platform_ui.dart';
import 'package:safenotes/utils/spacing.dart';
import 'package:safenotes/utils/string_utils.dart';
import 'package:safenotes/utils/text_direction_util.dart';
import 'package:safenotes/utils/text_styles.dart';
import 'package:safenotes/utils/time_utils.dart';

class NoteTileWidget extends StatelessWidget {
  final SafeNote note;
  final int index;

  const NoteTileWidget({super.key, required this.note, required this.index});

  @override
  Widget build(BuildContext context) {
    // Pick colors from the accent colors based on index
    final color = NotesColor.getNoteColor(notIndex: index);
    final fontColor = getFontColorForBackground(color);

    String time = noteTimeLabel(
      // 显示时间跟随排序依据：按修改时间排序时显示修改时间，否则显示创建时间。
      time: PreferencesStorage.isSortByModified
          ? note.modifiedTime
          : note.createdTime,
      localeString: context.locale.toString(),
      isRelative: PreferencesStorage.isRelativeTime,
    );

    return ShadCard(
      backgroundColor: color,
      padding: AppSpace.cardPadding,
      radius: BorderRadius.circular(AppShape.cardRadius),
      border: ShadBorder.none,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        //crossAxisAlignment: CrossAxisAlignment.start,
        //mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            sanitize(note.title),
            textDirection: getTextDirecton(note.title),
            style: AppText.title.copyWith(
              color: fontColor,
              fontFamily: uiFontFamily,
              fontFamilyFallback: uiFontFamilyFallback,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox.square(dimension: AppSpace.xs),
          Text(
            time,
            textDirection: getTextDirecton(time),
            style: AppText.caption.copyWith(color: fontColor),
          ),
          const SizedBox.square(dimension: AppSpace.xs),
          Text(
            sanitize(note.abstractText),
            textDirection: getTextDirecton(note.abstractText),
            style: AppText.body.copyWith(color: fontColor),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
