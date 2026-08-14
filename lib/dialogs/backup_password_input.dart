// 加密备份导入时的密码输入框（docs/backup-encryption-design-20260810.md §7）。
// 已迁移到统一模板 showAppPassword（lib/widgets/app_dialogs.dart）。

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:easy_localization/easy_localization.dart';

// Project imports:
import 'package:safenotes/widgets/app_dialogs.dart';

/// 显示「输入加密备份口令」对话框：
///   - 返回 String = 用户输入的口令
///   - 返回 null = 取消
///   - 返回空串 = 用户提交了空口令（由调用方按解密失败处理）
///
/// [errorText] 上轮解密失败的提示，非空时展示在输入框上方。
Future<String?> showBackupPasswordDialog({
  required BuildContext context,
  String? errorText,
}) {
  return showAppPassword(
    context,
    title: 'Import Data is Encrypted'.tr(),
    message: 'Enter the passphrase of the device that generated this file.'
        .tr(),
    confirmLabel: 'Submit'.tr(),
    cancelLabel: 'Cancel'.tr(),
    placeholder: 'Encryption Phrase'.tr(),
    errorText: errorText,
  );
}
