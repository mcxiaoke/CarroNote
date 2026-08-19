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

import 'package:core/core.dart';

import 'package:safenotes/widgets/note_card_body.dart';

/// 网格视图笔记卡（紧凑模式）：AutoSizeText 单块 + 时间。
///
/// P1-15：内容统一由 [NoteCardBody] 渲染，本类只负责参数透传。
class NoteCardWidgetCompact extends StatelessWidget {
  final SafeNote note;
  final int index;
  final bool pinned;

  const NoteCardWidgetCompact({
    super.key,
    required this.note,
    required this.index,
    this.pinned = false,
  });

  @override
  Widget build(BuildContext context) {
    return NoteCardBody(
      note: note,
      index: index,
      isCompact: true,
      pinned: pinned,
    );
  }
}
