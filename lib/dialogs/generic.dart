// 通用信息框（单按钮）。
// 已迁移到统一模板 showAppInfo（lib/widgets/app_dialogs.dart）。

// Flutter imports:
import 'package:flutter/material.dart';

// Project imports:
import 'package:safenotes/widgets/app_dialogs.dart';

/// 显示单按钮信息框（无标题，仅正文 + OK 按钮）。
Future<void> showGenericDialog({
  required BuildContext context,
  required String message,
}) {
  return showAppInfo(
    context,
    title: '',
    message: message,
  );
}
