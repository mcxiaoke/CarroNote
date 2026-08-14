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

class DeleteConfirmationDialog extends StatelessWidget {
  final VoidCallback callback;
  const DeleteConfirmationDialog({super.key, required this.callback});

  @override
  Widget build(BuildContext context) {
    // 容器统一使用 ShadDialog（shadcn 风格：圆角/边框/阴影/缩放动画），
    // 与回收站、清空全部等对话框保持一致。
    return ShadDialog(
      constraints: kAppDialogConstraints,
      title: Text('Caution!'.tr()),
      actions: [
        shadDialogActionBar(
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
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 固定尺寸，不随窗口缩放（此前为屏宽 17%，桌面大窗口下图标巨大）。
          Icon(
            LucideIcons.triangleAlert,
            size: 48,
            color: ShadTheme.of(context).colorScheme.destructive,
          ),
          const SizedBox(height: 12),
          Text(
            "You're about to delete this note. This action cannot be undone."
                .tr(),
            textAlign: TextAlign.center,
            style: dialogBodyTextStyle,
          ),
        ],
      ),
    );
  }
}
