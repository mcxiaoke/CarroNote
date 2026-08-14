// 导入数量确认。
// 已迁移到统一模板 showAppConfirm（lib/widgets/app_dialogs.dart）。

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:easy_localization/easy_localization.dart';

// Project imports:
import 'package:safenotes/widgets/app_dialogs.dart';

/// 显示「导入数量确认」对话框，返回 true=确认导入，false/null=取消。
///
/// [notice] 用于明文备份等场景，在确认文案下方显示附加提示（如「未加密」）。
Future<bool?> showImportConfirmDialog({
  required BuildContext context,
  required int importCount,
  String? notice,
}) {
  final message = 'Do you want to import {noOfNotesInImport} new notes?'.tr(
    namedArgs: {'noOfNotesInImport': importCount.toString()},
  );
  return showAppConfirm(
    context,
    title: 'Confirm Import!'.tr(),
    message: message,
    confirmLabel: 'Confirm'.tr(),
    cancelLabel: 'Cancel'.tr(),
    notice: notice,
  );
}
