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
import 'package:easy_localization/easy_localization.dart';

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

class ImportConfirmState extends State<ImportConfirm> {
  @override
  Widget build(BuildContext context) {
    const double paddingAllAround = 20.0;
    // P1-14：圆角 10→12，与 ShadDialog（AppShape.cardRadius）一致。
    const double dialogRadius = 12.0;

    return BackdropFilter(
      filter: ImageFilter.blur(),
      child: Dialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(dialogRadius),
        ),
        child: Padding(
          padding: const EdgeInsets.all(paddingAllAround),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [_title(), _body(paddingAllAround), _buildButtons()],
          ),
        ),
      ),
    );
  }

  Widget _title() {
    final String title = 'Confirm Import!'.tr();
    const double topSpacing = 10.0;

    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(top: topSpacing), //, right: 100),
        child: Text(title, style: dialogHeadTextStyle),
      ),
    );
  }

  Widget _body(double padding) {
    final String cautionMessage =
        'Do you want to import {noOfNotesInImport} new notes?'.tr(
          namedArgs: {'noOfNotesInImport': widget.importCount.toString()},
        );
    const double topSpacing = 15.0;

    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: EdgeInsets.only(top: topSpacing, bottom: padding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(cautionMessage, style: dialogBodyTextStyle),
            if (widget.notice != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  widget.notice!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildButtons() {
    return shadDialogActionBar(
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
    );
  }
}
