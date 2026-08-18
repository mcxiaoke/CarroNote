/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

// 导入数量确认。
// 已迁移到统一模板 showAppConfirm（lib/widgets/app_dialogs.dart）。

import 'package:flutter/material.dart';

import 'package:easy_localization/easy_localization.dart';

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
