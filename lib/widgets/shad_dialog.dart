// 对话框底部操作区 shadcn 化：替代 DialogActionBar / DialogButton，
// 统一为 ShadButton（outline / 主操作 / 危险操作），风格与设置页、主页一致。

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:shadcn_ui/shadcn_ui.dart';

/// 对话框操作按钮描述（数据类），供 [shadDialogActionBar] 统一渲染。
class ShadDialogAction {
  final String label;
  final VoidCallback? onPressed;
  final bool primary; // 主操作（确认/提交）：强调色填充
  final bool destructive; // 危险操作（删除/登出）：错误色填充
  final bool enabled; // 是否可用；false 时按钮置灰（如密码未填）

  const ShadDialogAction({
    required this.label,
    this.onPressed,
    this.primary = false,
    this.destructive = false,
    this.enabled = true,
  });
}

/// 右对齐的 ShadButton 操作组，替代 DialogActionBar。
Widget shadDialogActionBar({
  required List<ShadDialogAction> actions,
  double? spacing,
}) {
  final double gap = spacing ?? 8.0;
  final children = <Widget>[];
  for (var i = 0; i < actions.length; i++) {
    if (i > 0) children.add(SizedBox(width: gap));
    final a = actions[i];
    final buttonChild = Text(a.label);
    if (a.destructive) {
      children.add(
        ShadButton.destructive(
          onPressed: a.onPressed,
          enabled: a.enabled,
          child: buttonChild,
        ),
      );
    } else if (a.primary) {
      children.add(
        ShadButton(
          onPressed: a.onPressed,
          enabled: a.enabled,
          child: buttonChild,
        ),
      );
    } else {
      children.add(
        ShadButton.outline(
          onPressed: a.onPressed,
          enabled: a.enabled,
          child: buttonChild,
        ),
      );
    }
  }
  return Row(mainAxisAlignment: MainAxisAlignment.end, children: children);
}
