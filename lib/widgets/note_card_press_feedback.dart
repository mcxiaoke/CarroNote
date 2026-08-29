/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

import 'package:flutter/material.dart';

/// 笔记卡 hover/press 反馈包装（P0-3 重构为 Material ink）。
///
/// 直接复用父级 Material（OpenContainer 的 closedColor）的 ink 系统：
/// 按下 splash / 高亮 highlight / hover 颜色均继承自全局 ThemeData
/// （app_theme 已设为 secondary），与设置项等其它 InkWell 行为一致。
/// 卡片底色由 NoteCardBody 透传（背景色由 OpenContainer 的 closedColor 承载，
/// 此处 Container 仅保留描边/圆角且填充透明），墨色得以画在底色之上、不被盖住。
class NoteCardPressFeedback extends StatelessWidget {
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Widget child;
  final double radius;

  const NoteCardPressFeedback({
    super.key,
    required this.onTap,
    required this.child,
    this.onLongPress,
    this.radius = 12,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      mouseCursor: SystemMouseCursors.click,
      borderRadius: BorderRadius.circular(radius),
      child: child,
    );
  }
}
