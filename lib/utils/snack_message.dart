/*
* Copyright (C) Keshav Priyadarshi and others - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*
* You should have received a copy of the GNU General Public License v3.0 with
* this file. If not, please visit https://www.gnu.org/licenses/gpl-3.0.html
*
* See https://safenotes.dev for support or download.
*/

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:shadcn_ui/shadcn_ui.dart';

/// 信息提示（P2-3）：统一走 ShadSonner/ShadToast。
///
/// 桌面端宽度由 ShadSonner 自动约束（≥md 断点 maxWidth 420）；
/// 信息类 3 秒，错误类 6 秒（[showErrorToast]）。
void showSnackBarMessage(BuildContext context, String? message) {
  if (message == null) return;
  ShadSonner.maybeOf(context)?.show(
    ShadToast(
      title: Text(message, textAlign: TextAlign.center),
      duration: const Duration(seconds: 3),
    ),
  );
}

/// 错误提示：destructive 变体 + 6 秒，用于同步失败等关键场景。
void showErrorToast(BuildContext context, String message) {
  ShadSonner.maybeOf(context)?.show(
    ShadToast.destructive(
      title: Text(message, textAlign: TextAlign.center),
      duration: const Duration(seconds: 6),
    ),
  );
}
