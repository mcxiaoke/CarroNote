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
import 'package:easy_localization/easy_localization.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

// Project imports:
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/widgets/shad_dialog.dart';

/// 通用信息框（单 OK 按钮）。P2-2：已迁移至 ShadDialog，去除 BackdropFilter。
class GenericDialog extends StatelessWidget {
  /// 保留调用方兼容；ShadDialog 无独立 icon 槽位，暂不渲染。
  final IconData icon;
  final String message;

  const GenericDialog({super.key, required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    return ShadDialog(
      constraints: kAppDialogConstraints,
      actions: [
        shadDialogActionBar(
          actions: [
            ShadDialogAction(
              label: 'OK'.tr(),
              primary: true,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ],
      child: Text(message, style: dialogBodyTextStyle),
    );
  }
}

Future<void> showGenericDialog({
  required BuildContext context,
  required IconData icon,
  required String message,
}) async {
  return showAppDialog(
    context: context,
    barrierDismissible: true,
    builder: (BuildContext context) {
      return GenericDialog(icon: icon, message: message);
    },
  );
}
