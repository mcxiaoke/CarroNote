/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

// 统一对话框模板：基于 Flutter 系统 M3 AlertDialog 实现。
//
// 背景：shadcn_ui 的 ShadDialog 在移动端 title 上方会留大片空白
// （shadcn flutter 布局 bug），因此标准 alert 模板全部改用系统 M3
// AlertDialog：
//   - 布局 / 间距 / 圆角 / 动画由 Material 3 规范保证，移动端不再出现
//     标题上方大片空白；
//   - 窄屏自动收窄（insetPadding + actions OverflowBar 自动竖排），
//     宽屏最小宽度 400、最大宽度 M3 默认 560（见 [kAppAlertConstraints]）。
//
// 用法（一行调用，对齐 shadcn 官方 alert 用法）：
//   if (await showAppConfirm(context,
//     title: 'Import your backup'.tr(),
//     message: '...'.tr(),
//     confirmLabel: 'Select file'.tr(),
//   )) { ... }
//
// 接口与旧版完全一致（函数签名 / 返回值不变），仅内部实现从 ShadDialog
// 换成系统 AlertDialog。自定义复杂对话框（导出面板、登出倒计时等）不受影响。
//
// 与 shadcn 系统的分工：标准 alert（确认/危险/信息/密码/三选一）走本文件的
// M3 AlertDialog + OutlinedButton/FilledButton；复杂自定义面板（导出、登出等）
// 仍走 showAppDialog（lib/widgets/shad_dialog.dart）的 ShadDialog + ShadButton
// 操作栏。两套按钮语义一致：取消=outline、确认=filled/primary、危险=error。
// 本文件按钮样式助手（appDialogActions / appDialogOutlineAction /
// appDialogFilledAction）已公开，复杂对话框如需 M3 按钮可直接复用，保证全 app
// 对话框按钮同尺寸（高 48、最小宽度 kDialogActionMinWidth）。

import 'package:flutter/material.dart';

import 'package:easy_localization/easy_localization.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/utils/text_styles.dart';

/// 标准 alert 对话框约束：宽屏下最小宽度 400，最大宽度用 M3 默认（560）。
/// （AlertDialog 默认 minWidth 280 / maxWidth 560；这里把 minWidth 提到 400，
/// 宽屏上对话框不再过窄，内容多的对话框可自然伸展到 560。）
///
/// 公开供其他对话框复用（与 M3 标准 alert 保持一致的宽窄自适应）。
const BoxConstraints kAppAlertConstraints = BoxConstraints(
  minWidth: 400,
  maxWidth: 560,
);

/// 对话框底部操作按钮统一最小宽度：保证 2/3 个按钮等宽，
/// 消除 TextButton / FilledButton 默认内边距不同导致的宽度错位。
const double kDialogActionMinWidth = 104;

/// 负向（取消/放弃）按钮样式：OutlinedButton 带描边，避免与对话框背景融为一体。
/// 可选 [foreground] 覆盖文字色（如放弃按钮用 error 红）。
/// （曾被 34f91f4 改回 TextButton 导致无边框，此处恢复描边。）
ButtonStyle appDialogOutlineAction({Color? foreground}) {
  return ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size(kDialogActionMinWidth, 48)),
    foregroundColor: foreground == null
        ? null
        : WidgetStatePropertyAll(foreground),
  );
}

/// 正向（确认）按钮样式：FilledButton，与负向按钮同宽。
/// 可选 [background]/[foreground] 覆盖配色（如破坏性按钮用 scheme.error）。
ButtonStyle appDialogFilledAction({Color? background, Color? foreground}) {
  return ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size(kDialogActionMinWidth, 48)),
    backgroundColor: background == null
        ? null
        : WidgetStatePropertyAll(background),
    foregroundColor: foreground == null
        ? null
        : WidgetStatePropertyAll(foreground),
  );
}

/// 对话框底部操作区自适应布局：
///
/// - 紧凑（屏幕宽度 < [kCompactBreakpoint]，如手机竖屏）：按钮上下排列、
///   各自占满整行，避免 AlertDialog 的 OverflowBar 竖排时按钮粘连、宽度不一。
///   按屏幕宽度而非对话框内容宽度判断：对话框宽度被 kAppAlertConstraints 固定
///   在 400~560，用内容宽度会恒判为紧凑，桌面端也会误竖排；
/// - 宽屏/横屏：按钮横向右对齐排列。
///
/// 公开供其他 M3 对话框复用，保证全 app 对话框按钮响应式行为一致。
Widget appDialogActions(BuildContext context, List<Widget> buttons) {
  final compact = MediaQuery.sizeOf(context).width < kCompactBreakpoint;
  if (compact) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < buttons.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          buttons[i],
        ],
      ],
    );
  }
  return Row(
    mainAxisAlignment: MainAxisAlignment.end,
    children: [
      for (var i = 0; i < buttons.length; i++) ...[
        if (i > 0) const SizedBox(width: 8),
        buttons[i],
      ],
    ],
  );
}

/// 打开 M3 AlertDialog 的通用入口（系统 showDialog）。
Future<T?> _showM3Dialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: builder,
  );
}

// ────────────────────────────────────────────────
// 高阶 API：5 类标准对话框
// ────────────────────────────────────────────────

/// 通用确认对话框：标题 + 描述 + 取消/确认。
///
/// - 默认 confirm 走 primary 按钮；非破坏性操作首选
/// - 返回 true = 确认，false/null = 取消
Future<bool?> showAppConfirm(
  BuildContext context, {
  required String title,
  required String message,
  String? confirmLabel,
  String? cancelLabel,
  String? notice,
}) {
  return _showM3Dialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: notice == null
          ? Text(message)
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(message),
                const SizedBox(height: 10),
                Text(
                  notice,
                  style: TextStyle(
                    color: Theme.of(ctx).colorScheme.error,
                    fontSize: AppTextSize.s12,
                  ),
                ),
              ],
            ),
      actions: [
        appDialogActions(ctx, [
          OutlinedButton(
            key: const Key('ui-dialog-cancel'),
            style: appDialogOutlineAction(),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(cancelLabel ?? 'Cancel'.tr()),
          ),
          FilledButton(
            key: const Key('ui-dialog-confirm'),
            style: appDialogFilledAction(),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(confirmLabel ?? 'OK'.tr()),
          ),
        ]),
      ],
      constraints: kAppAlertConstraints,
    ),
  );
}

/// 危险操作对话框：确认按钮走 destructive（红）。
///
/// 用于「删除 / 永久删除 / 清空 / 退出登录」等不可恢复或不可逆的操作。
Future<bool?> showAppDestructive(
  BuildContext context, {
  required String title,
  required String message,
  String? confirmLabel,
  String? cancelLabel,
}) {
  return _showM3Dialog<bool>(
    context: context,
    builder: (ctx) {
      final scheme = Theme.of(ctx).colorScheme;
      return AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          appDialogActions(ctx, [
            OutlinedButton(
              key: const Key('ui-dialog-cancel'),
              style: appDialogOutlineAction(),
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(cancelLabel ?? 'Cancel'.tr()),
            ),
            FilledButton(
              key: const Key('ui-dialog-confirm'),
              style: appDialogFilledAction(
                background: scheme.error,
                foreground: scheme.onError,
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(confirmLabel ?? 'Delete'.tr()),
            ),
          ]),
        ],
        constraints: kAppAlertConstraints,
      );
    },
  );
}

/// 单按钮信息框：标题 + 描述 + 单个 OK 按钮。
///
/// [title] 传空字符串时不显示标题行。
Future<void> showAppInfo(
  BuildContext context, {
  required String title,
  required String message,
  String? okLabel,
}) async {
  await _showM3Dialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: title.isEmpty ? null : Text(title),
      content: Text(message),
      actions: [
        appDialogActions(ctx, [
          FilledButton(
            style: appDialogFilledAction(),
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(okLabel ?? 'OK'.tr()),
          ),
        ]),
      ],
      constraints: kAppAlertConstraints,
    ),
  );
}

/// 密码输入对话框：内置显示/隐藏切换、错误提示。
///
/// - [errorText] 上轮失败时的错误提示（红字显示在输入框上方）
/// - 返回 String = 用户输入的密码；null = 取消；空串 = 用户提交了空密码
Future<String?> showAppPassword(
  BuildContext context, {
  required String title,
  required String message,
  String? confirmLabel,
  String? cancelLabel,
  String? placeholder,
  String? errorText,
  bool obscureByDefault = true,
}) {
  return _showM3Dialog<String>(
    context: context,
    builder: (ctx) => _PasswordDialog(
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      placeholder: placeholder,
      errorText: errorText,
      obscureByDefault: obscureByDefault,
    ),
  );
}

/// 单行文本输入对话框（M3 AlertDialog）。
///
/// 用于「编辑标签」「重命名」等简单文本输入场景。
/// - [initialValue] 预填内容；[hint] 输入框的 label/占位文案
/// - 返回 String = 用户输入（可为空串）；null = 取消
Future<String?> showAppInput(
  BuildContext context, {
  required String title,
  String? message,
  String? hint,
  String initialValue = '',
  String? confirmLabel,
  String? cancelLabel,
}) {
  return _showM3Dialog<String>(
    context: context,
    builder: (ctx) => _InputDialog(
      title: title,
      message: message,
      hint: hint,
      initialValue: initialValue,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
    ),
  );
}

/// 三选项对话框：典型场景是「未保存的更改 → 保存 / 放弃 / 取消」。
/// 返回 `AppThreeWayResult.cancel | discard | confirm`。
/// 按钮：取消=OutlinedButton（最轻），放弃=OutlinedButton+error 文字（中），
/// 确认=FilledButton（最重）。
Future<AppThreeWayResult?> showAppThreeWay(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  required String discardLabel,
  String? cancelLabel,
}) {
  return _showM3Dialog<AppThreeWayResult>(
    context: context,
    builder: (ctx) {
      final scheme = Theme.of(ctx).colorScheme;
      return AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          appDialogActions(ctx, [
            OutlinedButton(
              key: const Key('ui-dialog-cancel'),
              style: appDialogOutlineAction(),
              onPressed: () => Navigator.of(ctx).pop(AppThreeWayResult.cancel),
              child: Text(cancelLabel ?? 'Cancel'.tr()),
            ),
            // 放弃：OutlinedButton + error 文字色（有边框可见，权重介于取消与保存之间）
            OutlinedButton(
              key: const Key('ui-dialog-discard'),
              style: appDialogOutlineAction(foreground: scheme.error),
              onPressed: () => Navigator.of(ctx).pop(AppThreeWayResult.discard),
              child: Text(discardLabel),
            ),
            FilledButton(
              key: const Key('ui-dialog-confirm'),
              style: appDialogFilledAction(),
              onPressed: () => Navigator.of(ctx).pop(AppThreeWayResult.confirm),
              child: Text(confirmLabel),
            ),
          ]),
        ],
        constraints: kAppAlertConstraints,
      );
    },
  );
}

enum AppThreeWayResult { cancel, discard, confirm }

// ────────────────────────────────────────────────
// 密码输入对话框（含输入框，需 StatefulWidget）
// ────────────────────────────────────────────────

class _PasswordDialog extends StatefulWidget {
  final String title;
  final String message;
  final String? confirmLabel;
  final String? cancelLabel;
  final String? placeholder;
  final String? errorText;
  final bool obscureByDefault;

  const _PasswordDialog({
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.placeholder,
    required this.errorText,
    required this.obscureByDefault,
  });

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  late final TextEditingController _ctrl = TextEditingController();
  late bool _hidden = widget.obscureByDefault;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop(_ctrl.text);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.message),
          if (widget.errorText != null) ...[
            const SizedBox(height: 8),
            Text(
              widget.errorText!,
              style: TextStyle(color: scheme.error, fontSize: AppTextSize.s12),
            ),
          ],
          const SizedBox(height: 16),
          TextField(
            controller: _ctrl,
            autofocus: true,
            obscureText: _hidden,
            decoration: InputDecoration(
              labelText: widget.placeholder ?? 'Passphrase'.tr(),
              prefixIcon: const Icon(LucideIcons.lock, size: kInputIconSize),
              suffixIcon: kInputIconButton(
                icon: Icon(
                  _hidden ? LucideIcons.eye : LucideIcons.eyeOff,
                  size: kInputIconSize,
                ),
                onPressed: () => setState(() => _hidden = !_hidden),
              ),
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        appDialogActions(context, [
          OutlinedButton(
            key: const Key('ui-dialog-cancel'),
            style: appDialogOutlineAction(),
            onPressed: () => Navigator.of(context).pop(),
            child: Text(widget.cancelLabel ?? 'Cancel'.tr()),
          ),
          FilledButton(
            key: const Key('ui-dialog-confirm'),
            style: appDialogFilledAction(),
            onPressed: _submit,
            child: Text(widget.confirmLabel ?? 'Submit'.tr()),
          ),
        ]),
      ],
      constraints: kAppAlertConstraints,
    );
  }
}

/// 单行文本输入对话框（[showAppInput] 的实现）。
///
/// 与 [_PasswordDialog] 同构：M3 AlertDialog + TextField + 统一操作栏，
/// 避免 shadcn ShadDialog 在移动端标题上方留大空白的布局 bug。
class _InputDialog extends StatefulWidget {
  final String title;
  final String? message;
  final String? hint;
  final String initialValue;
  final String? confirmLabel;
  final String? cancelLabel;

  const _InputDialog({
    required this.title,
    required this.message,
    required this.hint,
    required this.initialValue,
    required this.confirmLabel,
    required this.cancelLabel,
  });

  @override
  State<_InputDialog> createState() => _InputDialogState();
}

class _InputDialogState extends State<_InputDialog> {
  late final TextEditingController _ctrl = TextEditingController(
    text: widget.initialValue,
  );

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop(_ctrl.text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.message != null) ...[
            Text(widget.message!),
            const SizedBox(height: 14),
          ],
          TextField(
            controller: _ctrl,
            autofocus: true,
            decoration: InputDecoration(
              labelText: widget.hint ?? widget.title,
              hintText: widget.hint,
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        appDialogActions(context, [
          OutlinedButton(
            key: const Key('ui-dialog-cancel'),
            style: appDialogOutlineAction(),
            onPressed: () => Navigator.of(context).pop(),
            child: Text(widget.cancelLabel ?? 'Cancel'.tr()),
          ),
          FilledButton(
            key: const Key('ui-dialog-confirm'),
            style: appDialogFilledAction(),
            onPressed: _submit,
            child: Text(widget.confirmLabel ?? 'OK'.tr()),
          ),
        ]),
      ],
      constraints: kAppAlertConstraints,
    );
  }
}
