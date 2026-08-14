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

// Project imports:
import 'package:safenotes/widgets/note_card_body.dart';

/// 列表视图笔记卡（正常模式）：标题 1 行 + 时间 + 摘要 2 行。
///
/// P1-15：内容统一由 [NoteCardBody] 渲染，本类只负责参数透传。
class NoteTileWidget extends StatelessWidget {
  final SafeNote note;
  final int index;

  const NoteTileWidget({super.key, required this.note, required this.index});

  @override
  Widget build(BuildContext context) {
    return NoteCardBody(
      note: note,
      index: index,
      titleMaxLines: 1,
      bodyMaxLines: 2,
    );
  }
}
