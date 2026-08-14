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
import 'package:core/core.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

// Project imports:
import 'package:safenotes/models/file_handler.dart';
import 'package:safenotes/utils/snack_message.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/widgets/shad_dialog.dart';

/// 导入备份入口。P2-2：已迁移至 ShadDialog，去除 BackdropFilter。
class FileImportDialog extends StatelessWidget {
  final VoidCallback callback;

  const FileImportDialog({super.key, required this.callback});

  @override
  Widget build(BuildContext context) {
    final String cautionMessage =
        "If the Notes in your backup file was encrypted with different passphrase then you'll be prompted to enter the passphrase of the device that generated backup."
            .tr();

    return ShadDialog(
      constraints: kAppDialogConstraints,
      title: Text('Import your backup'.tr()),
      actions: [
        shadDialogActionBar(
          actions: [
            ShadDialogAction(
              label: 'Select file'.tr(),
              primary: true,
              onPressed: callback,
            ),
          ],
        ),
      ],
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(cautionMessage, style: dialogBodyTextStyle),
      ),
    );
  }
}

Future<void> showImportDialog(
  BuildContext context, {
  VoidCallback? homeRefresh,
}) async {
  return showAppDialog(
    context: context,
    barrierDismissible: true,
    builder: (BuildContext contextChild) {
      return FileImportDialog(
        callback: () async {
          Navigator.of(contextChild).pop();
          // 用户从导入对话框确认，开始选择备份文件
          Log.backup.i('用户触发导入备份：开始选择备份文件');
          String? snackMessage = await FileHandler().selectFileAndImport(
            context,
          );
          if (homeRefresh != null) homeRefresh();

          // TODO: refactor without using BuildContexts across async gap
          if (context.mounted) showSnackBarMessage(context, snackMessage);
        },
      );
    },
  );
}
