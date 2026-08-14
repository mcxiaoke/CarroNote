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

/// 笔记卡共享内容（P1-15）：4 个卡片（网格/列表 × 正常/紧凑）退化为
/// 薄外壳，内部统一走本组件，样式调整一处生效。
///
/// - [isCompact]：紧凑模式——AutoSizeText 单块预览（标题或摘要）+ 时间；
/// - [titleMaxLines] / [bodyMaxLines]：正常模式的标题/摘要行数
///   （网格 2/3、列表 1/2）。
class NoteCardBody extends StatelessWidget {
  final SafeNote note;
  final int index;
  final bool isCompact;
  final int titleMaxLines;
  final int bodyMaxLines;

  const NoteCardBody({
    super.key,
    required this.note,
    required this.index,
    this.isCompact = false,
    this.titleMaxLines = 2,
    this.bodyMaxLines = 3,
  });

  @override
  Widget build(BuildContext context) {
    // 取色与字体色：与外壳 ShadCard backgroundColor 保持一致（纯计算，重复调用无副作用）。
    final Color color = NotesColor.getNoteColor(notIndex: index, context: context);
    final Color fontColor = getFontColorForBackground(color);

    // 显示时间跟随排序依据：按修改时间排序时显示修改时间，否则显示创建时间，
    // 否则标题下的时间戳与列表顺序对不上（看起来"错乱"）。
    final String time = noteTimeLabel(
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
      // 关闭默认 lg 阴影：浅色背景下，ShadShadows.lg（offset(0,10)+blur 15）
      // 在卡片底部内侧形成一条明显的灰色阴影边，看起来像一条"线"。
      // 设计令牌基调是扁平（去掉 BackdropFilter/去除双系统阴影），故关阴影。
      shadows: const [],
      child: isCompact ? _buildCompact(fontColor, time) : _buildFull(fontColor, time),
    );
  }

  /// 正常模式：标题 + 时间 + 摘要。
  Widget _buildFull(Color fontColor, String time) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          sanitize(note.title),
          textDirection: getTextDirecton(note.title),
          style: AppText.body.copyWith(fontWeight: FontWeight.bold,
            color: fontColor,
            fontFamily: uiFontFamily,
            fontFamilyFallback: uiFontFamilyFallback,
          ),
          maxLines: titleMaxLines,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: AppSpace.xs),
        Text(
          time,
          textDirection: getTextDirecton(time),
          style: AppText.label.copyWith(color: fontColor),
        ),
        const SizedBox(height: AppSpace.sm),
        Text(
          sanitize(note.abstractText),
          textDirection: getTextDirecton(note.abstractText),
          style: AppText.body.copyWith(color: fontColor),
          maxLines: bodyMaxLines,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  /// 紧凑模式：AutoSizeText 单块（标题或摘要）+ 时间。
  Widget _buildCompact(Color fontColor, String time) {
    final previewText = note.title == ' ' ? note.abstractText : note.title;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AutoSizeText(
          sanitize(previewText),
          textDirection: getTextDirecton(previewText),
          style: AppText.body.copyWith(fontWeight: FontWeight.bold,
            color: fontColor,
            fontFamily: uiFontFamily,
            fontFamilyFallback: uiFontFamilyFallback,
          ),
          minFontSize: 15,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: AppSpace.xs),
        Text(
          time,
          textDirection: getTextDirecton(time),
          style: AppText.label.copyWith(color: fontColor),
        ),
      ],
    );
  }
}
