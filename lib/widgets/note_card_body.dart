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

import 'package:flutter/material.dart';

import 'package:auto_size_text/auto_size_text.dart';
import 'package:core/core.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/app_theme.dart';
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

  /// 置顶/星标状态：置顶的卡片右上角显示星标角标。
  ///
  /// 只读标记，不承载任何写操作（写只走 setNotePinned，见红线 1/2）。
  final bool pinned;

  const NoteCardBody({
    super.key,
    required this.note,
    required this.index,
    this.isCompact = false,
    this.titleMaxLines = 2,
    this.bodyMaxLines = 3,
    this.pinned = false,
  });

  @override
  Widget build(BuildContext context) {
    // 取色与字体色：底色与 OpenContainer 的 closedColor 取同一来源（纯计算，重复调用无副作用）。
    final Color color = NotesColor.getNoteColor(
      notIndex: index,
      context: context,
    );
    final Color fontColor = getFontColorForBackground(color);
    // 单色（中性灰度）主题下，给卡片叠加一圈 primary 描边，使素净卡片与背景有边界：
    // 是否描边、颜色、粗细都由 NotesColor.cardBorder 统一封装，调用方按需传入。
    final ColorScheme cardScheme = Theme.of(context).colorScheme;
    final ShadBorder cardBorder = NotesColor.cardBorder(
      outline: isMonochromeMode && !PreferencesStorage.isColorful,
      color: cardScheme.outlineVariant,
      width: 1,
    );

    // 显示时间跟随排序依据：按修改时间排序时显示修改时间，否则显示创建时间，
    // 否则标题下的时间戳与列表顺序对不上（看起来"错乱"）。
    final String time = noteTimeLabel(
      time: PreferencesStorage.isSortByModified
          ? note.modifiedTime
          : note.createdTime,
      localeString: context.locale.toString(),
      isRelative: PreferencesStorage.isRelativeTime,
    );

    // 最外层即卡片本体：用完全可控的 Container 承载底色 + 描边 + 圆角，
    // 不再依赖 ShadCard 内部 MainAxisSize.min 的 Container——它会在被网格
    // 行对齐拉高的 cell 中只缩到内容高度，导致描边只包住内容、未包住整张卡
    //（即"outline 没包裹全部 card"）。
    // LayoutBuilder + minHeight：网格(SliverAlignedGrid)对同行短卡施加紧约束
    //（行高 H），此时 minHeight=H 让卡片撑满整格、描边包裹全卡；列表(ListView)
    // 为松约束、高度随内容，minHeight=0 退化为内容高度。
    return LayoutBuilder(
      builder: (context, constraints) {
        final double minHeight = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : 0.0;
        return Container(
          constraints: BoxConstraints(
            minWidth: double.infinity,
            minHeight: minHeight,
          ),
          width: double.infinity,
          padding: AppSpace.cardPadding,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(AppShape.cardRadius),
            border: cardBorder.toBorder(),
          ),
          // 扁平化：Container/BoxDecoration 默认无阴影，契合整体设计令牌。
          child: isCompact
              ? _buildCompact(fontColor, time)
              : _buildFull(fontColor, time),
        );
      },
    );
  }

  /// 正常模式：标题 + 时间 + 摘要。
  Widget _buildFull(Color fontColor, String time) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                sanitize(note.title),
                textDirection: getTextDirecton(note.title),
                style: AppText.body.copyWith(
                  fontWeight: FontWeight.w500,
                  color: fontColor,
                  fontFamily: uiFontFamily,
                  fontFamilyFallback: uiFontFamilyFallback,
                ),
                maxLines: titleMaxLines,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (pinned) ...[const SizedBox(width: AppSpace.xs), _PinnedBadge()],
          ],
        ),
        const SizedBox(height: AppSpace.xs),
        Text(
          time,
          textDirection: getTextDirecton(time),
          style: AppText.labelMini.copyWith(color: fontColor),
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
    final previewText = note.title.trim().isEmpty
        ? note.abstractText
        : note.title;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: AutoSizeText(
                sanitize(previewText),
                style: AppText.body.copyWith(
                  fontWeight: FontWeight.w500,
                  color: fontColor,
                  fontFamily: uiFontFamily,
                  fontFamilyFallback: uiFontFamilyFallback,
                ),
                minFontSize: 15,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (pinned) ...[const SizedBox(width: AppSpace.xs), _PinnedBadge()],
          ],
        ),
        const SizedBox(height: AppSpace.xs),
        Text(
          time,
          textDirection: getTextDirecton(time),
          style: AppText.labelMini.copyWith(color: fontColor),
        ),
      ],
    );
  }
}

/// 置顶角标（标题行末尾）。
///
/// 纯展示：不响应点击，置顶的切换只能通过编辑页「更多」菜单完成。
class _PinnedBadge extends StatelessWidget {
  const _PinnedBadge();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'Pinned'.tr(),
      child: Container(
        key: const Key('ui-note-pinned-badge'),
        width: 20,
        height: 20,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: scheme.primary,
        ),
        alignment: Alignment.center,
        child: Icon(LucideIcons.star, size: 12, color: scheme.onPrimary),
      ),
    );
  }
}
