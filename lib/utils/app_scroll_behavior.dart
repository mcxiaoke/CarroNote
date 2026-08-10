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

/// 桌面平台滚动行为。
///
/// 默认 [MaterialScrollBehavior] 在桌面会给每个垂直 Scrollable 自动加
/// Scrollbar。其中依赖 [PrimaryScrollController] 的滚动（ScrollView 未指定
/// controller、primary 为 true）在 fade-through（`opaque:false`，多路由共存）
/// 时会被多个页面争用同一个 PrimaryScrollController —— 新路由 attach 会使旧
/// 路由的 Scrollbar 失去 ScrollPosition，抛出框架异常
/// "The Scrollbar's ScrollController has no ScrollPosition attached"。
///
/// 这里跳过依赖 PrimaryScrollController 的自动滚动条；需要滚动条的页面
/// （主页笔记列表/网格）自行用显式 [Scrollbar] + 独立 [ScrollController]，
/// 见 home.dart 的 `_notesListScroll` / `_notesGridScroll`。
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    if (details.controller is PrimaryScrollController) {
      return child;
    }
    return super.buildScrollbar(context, child, details);
  }
}
