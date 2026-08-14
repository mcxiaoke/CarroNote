// 对话框底部操作区 shadcn 化：替代 DialogActionBar / DialogButton，
// 统一为 ShadButton（outline / 主操作 / 危险操作），风格与设置页、主页一致。

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:shadcn_ui/shadcn_ui.dart';

// Project imports:
import 'package:safenotes/utils/styles.dart';

/// 统一弹窗约束：固定宽度 440（min=max，窄屏自动收窄到可用宽度）、最小高度 160。
///
/// minWidth=maxWidth=440 让短内容的对话框（删除/永久删除等）不再缩到文字那么窄；
/// 在窄屏上 ConstrainedBox 会把 440 clamp 到「屏幕宽 − 两侧 margin」，不会溢出。
const BoxConstraints kAppDialogConstraints = BoxConstraints(
  minWidth: kDialogMaxWidth,
  maxWidth: kDialogMaxWidth,
  minHeight: 160,
);

/// 统一弹窗展示入口，替代「Flutter showDialog 包 ShadDialog」。
///
/// showDialog 会在 ShadDialog 外再套一层白色 Material Dialog，浅色主题下
/// 表现为「纯白框、无边框阴影、无缩放动画」，与 app 不协调。这里改用
/// showShadDialog，由 ShadDialog 自身绘制边框/阴影/背景与缩放动画，
/// 并统一左右 12 margin（窄屏不再贴边，宽屏居中且宽度由 [kAppDialogConstraints] 固定为 440）。
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  return showShadDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (dialogContext) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: builder(dialogContext),
    ),
  );
}

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
///
/// [buttonMinWidth]：按钮统一最小宽度。action bar 长度本按文字自适应，
/// 短词按钮（Cancel/Export/OK）会显得很窄；给定最小宽度后所有对话框
/// 按钮宽度整齐一致（文字本身更宽的按钮不受影响）。
Widget shadDialogActionBar({
  required List<ShadDialogAction> actions,
  double? spacing,
  double buttonMinWidth = 100.0,
}) {
  final double gap = spacing ?? 8.0;
  final children = <Widget>[];
  for (var i = 0; i < actions.length; i++) {
    if (i > 0) children.add(SizedBox(width: gap));
    final a = actions[i];
    final buttonChild = Text(a.label);
    // 关键：显式 width: 0 覆盖 ShadDialog 在小屏断点下（expandActionsWhenTiny）
    // 通过 ShadTheme 注入的 width: double.infinity。否则按钮内部 ConstrainedBox
    // 会得到 minWidth=Infinity，在 Row(mainAxisSize.min) 里触发
    // 「BoxConstraints forces an infinite width」崩溃。
    // width: 0 语义 = 按内容自适应，宽度下限由外层 ConstrainedBox(minWidth) 保证。
    Widget button;
    if (a.destructive) {
      button = ShadButton.destructive(
        width: 0,
        onPressed: a.onPressed,
        enabled: a.enabled,
        child: buttonChild,
      );
    } else if (a.primary) {
      button = ShadButton(
        width: 0,
        onPressed: a.onPressed,
        enabled: a.enabled,
        child: buttonChild,
      );
    } else {
      button = ShadButton.outline(
        width: 0,
        onPressed: a.onPressed,
        enabled: a.enabled,
        child: buttonChild,
      );
    }
    children.add(
      ConstrainedBox(
        constraints: BoxConstraints(minWidth: buttonMinWidth),
        child: button,
      ),
    );
  }
  // mainAxisSize.min：ShadDialog 的 actions 用横向 Flex（主轴无界），
  // Row 默认 max 会尝试撑满无限宽 → BoxConstraints forces an infinite width 崩溃。
  return Row(
    mainAxisSize: MainAxisSize.min,
    mainAxisAlignment: MainAxisAlignment.end,
    children: children,
  );
}
