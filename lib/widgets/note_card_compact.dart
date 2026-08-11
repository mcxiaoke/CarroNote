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
import 'package:auto_size_text/auto_size_text.dart';

// Project imports:
import 'package:core/core.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/utils/notes_color.dart';
import 'package:safenotes/utils/platform_ui.dart';
import 'package:safenotes/utils/string_utils.dart';
import 'package:safenotes/utils/text_direction_util.dart';
import 'package:safenotes/utils/time_utils.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class NoteCardWidgetCompact extends StatelessWidget {
  final SafeNote note;
  final int index;

  const NoteCardWidgetCompact({
    super.key,
    required this.note,
    required this.index,
  });

  @override
  Widget build(BuildContext context) {
    // Pick colors from the accent colors based on index
    final color = NotesColor.getNoteColor(notIndex: index);
    final fontColor = getFontColorForBackground(color);
    final previewText = note.title == ' ' ? note.abstractText : note.title;
    final time = noteTimeLabel(
      // 显示时间跟随排序依据：按修改时间排序时显示修改时间，否则显示创建时间。
      time: PreferencesStorage.isSortByModified
          ? note.modifiedTime
          : note.createdTime,
      localeString: context.locale.toString(),
      isRelative: PreferencesStorage.isRelativeTime,
    );

    return ShadCard(
      backgroundColor: color,
      padding: const EdgeInsets.all(10),
      radius: BorderRadius.circular(10),
      border: ShadBorder.none,
      child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AutoSizeText(
              sanitize(previewText),
              textDirection: getTextDirecton(previewText),
              style: TextStyle(
                color: fontColor,
                fontSize: 18,
                fontWeight: FontWeight.bold,
                fontFamily: uiFontFamily,
                fontFamilyFallback: uiFontFamilyFallback,
              ),
              minFontSize: 15,
              maxLines: 2,
              overflow: TextOverflow.clip,
            ),
            const SizedBox(height: 4),
            Text(
              time,
              textDirection: getTextDirecton(time),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: fontColor,
              ),
            ),
          ],
      ),
    );
  }
}
