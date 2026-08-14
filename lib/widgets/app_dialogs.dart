// 统一对话框模板：标准 ShadDialog.alert 的薄封装。
//
// 用法（一行调用，对齐 shadcn 官方 alert 用法）：
//   if (await showAppConfirm(context,
//     title: 'Import your backup'.tr(),
//     message: '...'.tr(),
//     confirmLabel: 'Select file'.tr(),
//   )) { ... }
//
// 设计原则：**完全对齐 shadcn 官方标准用法，零自定义**。
//   - 用 ShadDialog.alert 的 title / description / actions 三槽位
//   - title = Text(...)，description = Text(...)，actions = [ShadButton...]
//   - 图标、等宽按钮、自定义标题行等一律去掉
//   - 按钮布局交给官方 Flex（桌面横排右对齐、移动竖排全宽）

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:easy_localization/easy_localization.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

// Project imports:
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/widgets/shad_dialog.dart';

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
  return showAppDialog<bool>(
    context: context,
    builder: (ctx) => ShadDialog.alert(
      scrollable: false,
      padding: EdgeInsets.zero,
      title: Text(title),
      description: notice == null
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
                    color: ShadTheme.of(ctx).colorScheme.destructive,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(cancelLabel ?? 'Cancel'.tr()),
        ),
        ShadButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(confirmLabel ?? 'OK'.tr()),
        ),
      ],
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
  return showAppDialog<bool>(
    context: context,
    builder: (ctx) => ShadDialog.alert(
      scrollable: false,
      padding: EdgeInsets.zero,
      title: Text(title),
      description: Text(message),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(cancelLabel ?? 'Cancel'.tr()),
        ),
        ShadButton.destructive(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(confirmLabel ?? 'Delete'.tr()),
        ),
      ],
    ),
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
}) {
  return showAppDialog(
    context: context,
    builder: (ctx) => ShadDialog.alert(
      scrollable: false,
      padding: EdgeInsets.zero,
      title: title.isEmpty ? null : Text(title),
      description: Text(message),
      actions: [
        ShadButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(okLabel ?? 'OK'.tr()),
        ),
      ],
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
  return showAppDialog<String>(
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
/// 按钮：取消=outline（最轻），放弃=outline+destructive 文字（中），
/// 确认=primary（最重）。
Future<AppThreeWayResult?> showAppThreeWay(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  required String discardLabel,
  String? cancelLabel,
}) {
  return showAppDialog<AppThreeWayResult>(
    context: context,
    builder: (ctx) {
      final theme = ShadTheme.of(ctx);
      return ShadDialog.alert(
      scrollable: false,
      padding: EdgeInsets.zero,
        title: Text(title),
        description: Text(message),
        actions: [
          ShadButton.outline(
            onPressed: () =>
                Navigator.of(ctx).pop(AppThreeWayResult.cancel),
            child: Text(cancelLabel ?? 'Cancel'.tr()),
          ),
          // 放弃：outline + destructive 文字色（有边框可见，权重介于取消与保存之间）
          ShadButton.outline(
            foregroundColor: theme.colorScheme.destructive,
            onPressed: () =>
                Navigator.of(ctx).pop(AppThreeWayResult.discard),
            child: Text(discardLabel),
          ),
          ShadButton(
            onPressed: () =>
                Navigator.of(ctx).pop(AppThreeWayResult.confirm),
            child: Text(confirmLabel),
          ),
        ],
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
    final theme = ShadTheme.of(context);
    return ShadDialog.alert(
      scrollable: false,
      padding: EdgeInsets.zero,
      title: Text(widget.title),
      description: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.message),
          if (widget.errorText != null) ...[
            const SizedBox(height: 8),
            Text(
              widget.errorText!,
              style: TextStyle(
                color: theme.colorScheme.destructive,
                fontSize: 13,
              ),
            ),
          ],
        ],
      ),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.cancelLabel ?? 'Cancel'.tr()),
        ),
        ShadButton(
          onPressed: _submit,
          child: Text(widget.confirmLabel ?? 'Submit'.tr()),
        ),
      ],
      child: ShadInput(
        controller: _ctrl,
        autofocus: true,
        obscureText: _hidden,
        enableIMEPersonalizedLearning: false,
        placeholder: Text(widget.placeholder ?? 'Passphrase'.tr()),
        padding: kInputPadding,
        leading: const Icon(Icons.lock, size: kInputIconSize),
        trailing: kInputIconButton(
          icon: Icon(
            _hidden ? Icons.visibility : Icons.visibility_off,
            size: kInputIconSize,
          ),
          onPressed: () => setState(() => _hidden = !_hidden),
        ),
        onSubmitted: (_) => _submit(),
      ),
    );
  }
}
