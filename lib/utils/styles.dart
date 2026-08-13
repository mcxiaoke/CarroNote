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
import 'package:safenotes/utils/platform_ui.dart';

class Style {
  static TextStyle buttonTextStyle(BuildContext context) {
    return TextStyle(color: Theme.of(context).colorScheme.onPrimary);
  }
}

TextStyle dialogBodyTextStyle = const TextStyle(fontSize: 14);

TextStyle dialogHeadTextStyle = uiTitleStyle(fontSize: 20);

TextStyle appBarTitle = uiTitleStyle(fontSize: 20);

/// 输入框内 leading/trailing 图标统一尺寸：限制到 20，避免默认 24 的图标
/// 把输入框撑高、或与无图标框不一致；配合 [kInputIconButton] 使用。
const double kInputIconSize = 20.0;

/// 输入框统一内边距（左右 12、上下 12）。上下用对称内边距而非仅靠
/// minHeight：对称内边距会让 [leading]/文字/trailing 在框内垂直居中，
/// 而 minHeight 只是把内容顶到上方、底部留空，导致文字看起来偏上。
/// 上下取 12 而不是精确撑满 48：14px 字号行高约 20，12*2+20=44，
/// 给主题层 minHeight:48 的垫高留出边框裕量，避免小高度上下文溢出。
const EdgeInsets kInputPadding = EdgeInsets.symmetric(
  horizontal: 12,
  vertical: 12,
);

/// 桌面端窄表单/对话框最大宽度：登录、设置/修改口令、导出备份等单列居中内容，
/// 避免在宽窗口上被拉满。
const double kDialogMaxWidthCompact = 420.0;

/// 桌面端对话框最大宽度：导入备份等简单对话框。
const double kDialogMaxWidth = 440.0;

/// 桌面端宽对话框/底部面板最大宽度：同步配置、主题设置等复杂面板。
const double kDialogMaxWidthWide = 560.0;

/// 桌面端宽面板最大高度：同步配置等可滚动面板。
const double kDialogMaxHeightWide = 760.0;

/// 对话框内「输入框 + 按钮」同一行时输入框的最大宽度（如导出对话框位置行），
/// 避免 Row 内在测量时把 shadcn 输入框（minWidth=Infinity）撑出无限宽。
const double kInputMaxWidthInRow = 360.0;

/// 输入框内紧凑图标按钮：压制 Material 默认 48dp 触控区（Android/M3 下会把
/// 带 trailing 的密码框撑高，Windows 桌面因视觉密度差异不明显），
/// 使按钮与单行文字同高，各平台表现一致。
Widget kInputIconButton({
  required Widget icon,
  required VoidCallback? onPressed,
  String? tooltip,
}) {
  return IconButton(
    icon: icon,
    iconSize: kInputIconSize,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints(),
    style: IconButton.styleFrom(
      minimumSize: Size.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
    ),
    tooltip: tooltip,
    onPressed: onPressed,
  );
}
