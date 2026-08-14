// 导入备份入口。
// 已迁移到统一模板 showAppConfirm（lib/widgets/app_dialogs.dart）。

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:core/core.dart';
import 'package:easy_localization/easy_localization.dart';

// Project imports:
import 'package:safenotes/models/file_handler.dart';
import 'package:safenotes/utils/snack_message.dart';
import 'package:safenotes/widgets/app_dialogs.dart';

/// 显示「导入你的备份」对话框：用户确认后选择备份文件。
///
/// 旧实现只有一个「选择文件」按钮，没取消按钮；新版通过 [showAppConfirm]
/// 自动补全「取消」，符合「二选一」操作预期。
Future<void> showImportDialog(
  BuildContext context, {
  VoidCallback? homeRefresh,
}) async {
  final message =
      "If the Notes in your backup file was encrypted with different passphrase then you'll be prompted to enter the passphrase of the device that generated backup."
          .tr();
  final ok = await showAppConfirm(
    context,
    title: 'Import your backup'.tr(),
    message: message,
    confirmLabel: 'Select file'.tr(),
    cancelLabel: 'Cancel'.tr(),
  );
  if (ok != true) return;
  if (!context.mounted) return;
  Log.backup.i('用户触发导入备份：开始选择备份文件');
  final String? snackMessage =
      await FileHandler().selectFileAndImport(context);
  if (homeRefresh != null) homeRefresh();
  if (context.mounted) showSnackBarMessage(context, snackMessage);
}
