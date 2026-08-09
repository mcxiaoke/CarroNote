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

// Project imports:
import 'package:safenotes/widgets/app_button.dart';

/// 登录/继续等主操作按钮。委托给统一的 [AppButton]，自动按平台适配尺寸
/// （桌面紧凑、移动端触摸友好），不再写死高 50 / 投影 5 的移动端样式。
class ButtonWidget extends StatelessWidget {
  final String text;
  final VoidCallback? onClicked;

  const ButtonWidget({super.key, required this.text, required this.onClicked});

  @override
  Widget build(BuildContext context) {
    return AppButton(
      text: text,
      onPressed: onClicked,
      fullWidth: true,
    );
  }
}
