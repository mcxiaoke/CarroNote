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

// Dart imports:
import 'dart:ui';

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:core/core.dart';
import 'package:easy_localization/easy_localization.dart';

// Project imports:
import 'package:safenotes/models/file_handler.dart';
import 'package:safenotes/utils/snack_message.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/widgets/shad_dialog.dart';

class FileImportDialog extends StatelessWidget {
  final VoidCallback callback;

  const FileImportDialog({super.key, required this.callback});

  @override
  Widget build(BuildContext context) {
    const double paddingAllAround = 20.0;
    const double dialogRadius = 10.0;

    return BackdropFilter(
      filter: ImageFilter.blur(),
      child: Dialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(dialogRadius),
        ),
        child: Padding(
          padding: const EdgeInsets.all(paddingAllAround),
          // 限宽：原生 Dialog 不设 maxWidth 会在宽屏上撑满可用宽度，
          // 导致导入对话框横向特别宽。这里与其它对话框保持一致的宽度。
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: kDialogMaxWidth),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [_title(), _body(), _buildButtons()],
            ),
          ),
        ),
      ),
    );
  }

  Widget _title() {
    final String title = 'Import your backup'.tr();

    return Align(
      alignment: Alignment.centerLeft,
      child: Text(title, style: dialogHeadTextStyle),
    );
  }

  Widget _body() {
    final String cautionMessage =
        "If the Notes in your backup file was encrypted with different passphrase then you'll be prompted to enter the passphrase of the device that generated backup."
            .tr();
    const double topSpacing = 10.0;

    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(top: topSpacing),
        child: Text(cautionMessage, style: dialogBodyTextStyle),
      ),
    );
  }

  Widget _buildButtons() {
    return shadDialogActionBar(
      actions: [
        ShadDialogAction(
          label: 'Select file'.tr(),
          primary: true,
          onPressed: callback,
        ),
      ],
    );
  }
}

Future<void> showImportDialog(
  BuildContext context, {
  VoidCallback? homeRefresh,
}) async {
  return showDialog(
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
