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

class DeleteConfirmationDialog extends StatelessWidget {
  final VoidCallback callback;
  const DeleteConfirmationDialog({super.key, required this.callback});

  @override
  Widget build(BuildContext context) {
    const double dialogBordeRadious = 10.0;

    return BackdropFilter(
      filter: ImageFilter.blur(),
      child: Dialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(dialogBordeRadious),
        ),
        child: Padding(
          padding: const EdgeInsets.all(15.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _cautionIcon(context),
              _title(context),
              _body(context),
              _buildButtons(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cautionIcon(BuildContext context) {
    // 固定尺寸，不随窗口缩放（此前为屏宽 17%，桌面大窗口下图标巨大）。
    return Icon(
      Icons.warning_rounded,
      size: 48,
      color: Theme.of(context).colorScheme.error,
    );
  }

  Widget _title(BuildContext context) {
    final String title = 'Caution!'.tr();

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Text(title, style: dialogHeadTextStyle),
    );
  }

  Widget _body(BuildContext context) {
    final String cautionMessage =
        "You're about to delete this note. This action cannot be undone.".tr();

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Text(
        cautionMessage,
        textAlign: TextAlign.center,
        style: dialogBodyTextStyle,
      ),
    );
  }

  Widget _buildButtons(BuildContext context) {
    return shadDialogActionBar(
      actions: [
        ShadDialogAction(
          label: 'Cancel'.tr(),
          onPressed: () => Navigator.of(context).pop(),
        ),
        ShadDialogAction(
          label: 'Delete'.tr(),
          destructive: true,
          onPressed: callback,
        ),
      ],
    );
  }
}
