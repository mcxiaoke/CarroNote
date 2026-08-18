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

import 'package:safenotes/utils/motion.dart';

/// 笔记卡 hover/press 反馈包装（P0-3）。
///
/// 在 [child]（不透明卡片）之上叠一层半透明黑/白遮罩：
/// - hover：5% 遮罩 + 手型光标（桌面）；
/// - press：10% 遮罩。
/// 手势（onTap）由外层 OpenContainer 的 action 传入，避免与卡片内部
/// GestureDetector 竞争手势（InkWell 的 ripple 会被不透明卡片盖住，
/// 故不用 InkWell）。
class NoteCardPressFeedback extends StatefulWidget {
  final VoidCallback onTap;
  final Widget child;
  final double radius;

  const NoteCardPressFeedback({
    super.key,
    required this.onTap,
    required this.child,
    this.radius = 12,
  });

  @override
  State<NoteCardPressFeedback> createState() => _NoteCardPressFeedbackState();
}

class _NoteCardPressFeedbackState extends State<NoteCardPressFeedback> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final double overlayAlpha = _pressed ? 0.10 : (_hovered ? 0.05 : 0.0);
    final overlayColor = (isDark ? Colors.white : Colors.black).withValues(
      alpha: overlayAlpha,
    );

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: Stack(
          children: [
            widget.child,
            // 遮罩层：AnimatedContainer 只过渡颜色变化，避免无谓 rebuild。
            AnimatedContainer(
              duration: AppMotion.fast,
              curve: AppMotion.standard,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(widget.radius),
                color: overlayColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
