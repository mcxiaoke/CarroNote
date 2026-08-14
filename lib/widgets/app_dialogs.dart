// 统一对话框模板：基于 Flutter 系统 M3 AlertDialog 实现。
//
// 背景：shadcn_ui 的 ShadDialog 在移动端 title 上方会留大片空白
// （shadcn flutter 布局 bug），因此标准 alert 模板全部改用系统 M3
// AlertDialog：
//   - 布局 / 间距 / 圆角 / 动画由 Material 3 规范保证，移动端不再出现
//     标题上方大片空白；
//   - 窄屏自动收窄（insetPadding + actions OverflowBar 自动竖排），
//     宽屏最小宽度 400、最大宽度 M3 默认 560（见 [_kAlertConstraints]）。
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

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:easy_localization/easy_localization.dart';

// Project imports:
import 'package:safenotes/utils/styles.dart';

/// 标准 alert 对话框约束：宽屏下最小宽度 400，最大宽度用 M3 默认（560）。
/// （AlertDialog 默认 minWidth 280 / maxWidth 560；这里把 minWidth 提到 400，
/// 宽屏上对话框不再过窄，内容多的对话框可自然伸展到 560。）
const BoxConstraints _kAlertConstraints = BoxConstraints(
  minWidth: 400,
  maxWidth: 560,
);

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
                    fontSize: 12,
                  ),
                ),
              ],
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(cancelLabel ?? 'Cancel'.tr()),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(confirmLabel ?? 'OK'.tr()),
        ),
      ],
      constraints: _kAlertConstraints,
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
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(cancelLabel ?? 'Cancel'.tr()),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(confirmLabel ?? 'Delete'.tr()),
          ),
        ],
        constraints: _kAlertConstraints,
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
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(okLabel ?? 'OK'.tr()),
        ),
      ],
      constraints: _kAlertConstraints,
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

/// 三选项对话框：典型场景是「未保存的更改 → 保存 / 放弃 / 取消」。
///
/// 返回 `AppThreeWayResult.cancel | discard | confirm`。
/// 按钮：取消=TextButton（最轻），放弃=TextButton+error 文字（中），
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
          TextButton(
            onPressed: () =>
                Navigator.of(ctx).pop(AppThreeWayResult.cancel),
            child: Text(cancelLabel ?? 'Cancel'.tr()),
          ),
          // 放弃：TextButton + error 文字色（有可见文字，权重介于取消与保存之间）
          TextButton(
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            onPressed: () =>
                Navigator.of(ctx).pop(AppThreeWayResult.discard),
            child: Text(discardLabel),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(ctx).pop(AppThreeWayResult.confirm),
            child: Text(confirmLabel),
          ),
        ],
        constraints: _kAlertConstraints,
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
              style: TextStyle(color: scheme.error, fontSize: 13),
            ),
          ],
          const SizedBox(height: 16),
          TextField(
            controller: _ctrl,
            autofocus: true,
            obscureText: _hidden,
            decoration: InputDecoration(
              labelText: widget.placeholder ?? 'Passphrase'.tr(),
              prefixIcon: const Icon(Icons.lock, size: kInputIconSize),
              suffixIcon: kInputIconButton(
                icon: Icon(
                  _hidden ? Icons.visibility : Icons.visibility_off,
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
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.cancelLabel ?? 'Cancel'.tr()),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.confirmLabel ?? 'Submit'.tr()),
        ),
      ],
      constraints: _kAlertConstraints,
    );
  }
}
