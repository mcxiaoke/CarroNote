/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

// 通用信息框（单按钮）。
// 已迁移到统一模板 showAppInfo（lib/widgets/app_dialogs.dart）。

import 'package:flutter/material.dart';

import 'package:safenotes/widgets/app_dialogs.dart';

/// 显示单按钮信息框（无标题，仅正文 + OK 按钮）。
Future<void> showGenericDialog({
  required BuildContext context,
  required String message,
}) {
  return showAppInfo(context, title: '', message: message);
}
