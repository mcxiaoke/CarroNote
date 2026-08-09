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

// Project imports:
import 'package:safenotes/utils/platform_ui.dart';

/// 统一的按钮封装，按平台自适应尺寸：
/// - 桌面（尤其 Windows）：高度 ~36、无投影、小圆角、字号 14，贴近原生控件。
/// - 移动端：保持较大的触摸友好尺寸（高度 50、圆角 10、字号 18）。
enum AppButtonVariant { primary, text }

class AppButton extends StatelessWidget {
  final String text;
  final VoidCallback? onPressed;
  final AppButtonVariant variant;
  final bool fullWidth;
  final Widget? icon;
  final double? width;

  const AppButton({
    super.key,
    required this.text,
    this.onPressed,
    this.variant = AppButtonVariant.primary,
    this.fullWidth = false,
    this.icon,
    this.width,
  });

  @override
  Widget build(BuildContext context) {
    final bool isDesktop = isDesktopPlatform;
    final double height = isDesktop ? 36.0 : 50.0;
    final double borderRadius = isDesktop ? 4.0 : 10.0;
    final TextStyle textStyle = TextStyle(
      fontSize: isDesktop ? 14 : 18,
      fontWeight: FontWeight.w600,
    );

    final ButtonStyle baseStyle = ButtonStyle(
      minimumSize: WidgetStateProperty.all(Size.fromHeight(height)),
      shape: WidgetStateProperty.all(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(borderRadius),
        ),
      ),
      textStyle: WidgetStateProperty.all(textStyle),
      // 桌面端去除 Material 拟物投影，更贴近 Win32 按钮
      elevation: isDesktop ? WidgetStateProperty.all(0.0) : null,
      padding: isDesktop
          ? WidgetStateProperty.all(
              const EdgeInsets.symmetric(horizontal: 16),
            )
          : null,
    );

    final Widget child = icon != null
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              icon!,
              const SizedBox(width: 8),
              Text(text, textAlign: TextAlign.center),
            ],
          )
        : Text(text, textAlign: TextAlign.center);

    final Widget btn = variant == AppButtonVariant.primary
        ? FilledButton(style: baseStyle, onPressed: onPressed, child: child)
        : TextButton(style: baseStyle, onPressed: onPressed, child: child);

    if (fullWidth) {
      return SizedBox(width: double.infinity, child: btn);
    }
    if (width != null) {
      return SizedBox(width: width, child: btn);
    }
    return btn;
  }
}

/// 对话框操作按钮的描述（数据类），供 [DialogActionBar] 统一渲染。
class DialogButton {
  final String label;
  final VoidCallback? onPressed;
  final bool isPrimary; // 强调色填充（确认/提交等主操作）
  final bool isDestructive; // 错误色填充（删除/登出等危险操作）

  const DialogButton({
    required this.label,
    this.onPressed,
    this.isPrimary = false,
    this.isDestructive = false,
  });
}

/// 对话框底部操作区：右对齐的小号按钮对（Windows 原生对话框范式），
/// 替代原先移动端惯用的"两个撑满的 ElevatedButton"。
class DialogActionBar extends StatelessWidget {
  final List<DialogButton> actions;
  final double? spacing;

  const DialogActionBar({
    super.key,
    required this.actions,
    this.spacing,
  });

  @override
  Widget build(BuildContext context) {
    final bool isDesktop = isDesktopPlatform;
    final double gap = spacing ?? (isDesktop ? 8.0 : 12.0);
    final List<Widget> children = <Widget>[];
    for (int i = 0; i < actions.length; i++) {
      if (i > 0) children.add(SizedBox(width: gap));
      children.add(_buildButton(context, actions[i], isDesktop));
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: children,
    );
  }

  Widget _buildButton(
    BuildContext context,
    DialogButton a,
    bool isDesktop,
  ) {
    final ButtonStyle style = ButtonStyle(
      minimumSize: WidgetStateProperty.all(
        Size(isDesktop ? 72 : 0, isDesktop ? 32 : 40),
      ),
      padding: WidgetStateProperty.all(
        EdgeInsets.symmetric(
          horizontal: isDesktop ? 16 : 12,
          vertical: 0,
        ),
      ),
      textStyle: WidgetStateProperty.all(
        TextStyle(
          fontSize: isDesktop ? 13 : 15,
          fontWeight: FontWeight.w600,
        ),
      ),
      shape: WidgetStateProperty.all(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(isDesktop ? 4 : 8),
        ),
      ),
      elevation: isDesktop ? WidgetStateProperty.all(0.0) : null,
    );
    final Widget child = Text(a.label, textAlign: TextAlign.center);

    if (a.isDestructive) {
      return FilledButton(
        style: style.copyWith(
          backgroundColor: WidgetStateProperty.all(
            Theme.of(context).colorScheme.error,
          ),
        ),
        onPressed: a.onPressed,
        child: child,
      );
    }
    if (a.isPrimary) {
      return FilledButton(style: style, onPressed: a.onPressed, child: child);
    }
    return TextButton(style: style, onPressed: a.onPressed, child: child);
  }
}
