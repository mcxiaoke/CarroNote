// 笔记删除确认对话框。
// 已迁移到统一模板 showAppDestructive（lib/widgets/app_dialogs.dart）。

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:easy_localization/easy_localization.dart';

// Project imports:
import 'package:safenotes/widgets/app_dialogs.dart';

/// 显示删除确认对话框，删除确认后调用 [callback]。
///
/// 旧 API 是返回 Widget 嵌入 showDialog 树，新 API 改为一次性函数，
/// 与 [showAppDestructive] 风格一致。
Future<void> showDeleteConfirmation({
  required BuildContext context,
  required VoidCallback onConfirm,
}) async {
  final ok = await showAppDestructive(
    context,
    title: 'Caution!'.tr(),
    message: "You're about to delete this note. This action cannot be undone."
        .tr(),
    confirmLabel: 'Delete'.tr(),
    cancelLabel: 'Cancel'.tr(),
  );
  if (ok == true) onConfirm();
}
