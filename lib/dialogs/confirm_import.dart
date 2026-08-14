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

class ImportConfirm extends StatefulWidget {
  final int importCount;

  /// 附加提示（如明文备份「未加密，已按明文导入」），展示在确认文案下方
  final String? notice;

  const ImportConfirm({super.key, required this.importCount, this.notice});

  @override
  ImportConfirmState createState() => ImportConfirmState();
}

/// 导入数量确认。P2-2：已迁移至 ShadDialog，去除 BackdropFilter。
class ImportConfirmState extends State<ImportConfirm> {
  @override
  Widget build(BuildContext context) {
    final String cautionMessage =
        'Do you want to import {noOfNotesInImport} new notes?'.tr(
          namedArgs: {'noOfNotesInImport': widget.importCount.toString()},
        );

    return ShadDialog(
      constraints: kAppDialogConstraints,
      title: Text('Confirm Import!'.tr()),
      actions: [
        shadDialogActionBar(
          actions: [
            ShadDialogAction(
              label: 'Cancel'.tr(),
              onPressed: () => Navigator.of(context).pop(false),
            ),
            ShadDialogAction(
              label: 'Confirm'.tr(),
              primary: true,
              onPressed: () => Navigator.of(context).pop(true),
            ),
          ],
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(cautionMessage, style: dialogBodyTextStyle),
          if (widget.notice != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                widget.notice!,
                // P1-22：错误色统一走 shad destructive。
                style: TextStyle(
                  color: ShadTheme.of(context).colorScheme.destructive,
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
