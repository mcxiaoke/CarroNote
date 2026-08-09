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

/// 开关列表项。原先使用 CupertinoSwitch（iOS 控件），在 Windows 等桌面端会
/// 直接暴露为 iOS 样式，与系统不一致；改为 Material 的 SwitchListTile，
/// 由 Flutter 在各平台渲染为对应的原生开关观感（Windows 上为 M3 开关）。
class CupertinoSwitchListTile extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  final Widget title;
  final Widget? subtitle;
  final Widget? secondary;
  final bool isThreeLine;
  final bool dense;
  final EdgeInsetsGeometry contentPadding;
  final bool selected;

  const CupertinoSwitchListTile({
    super.key,
    required this.value,
    required this.onChanged,
    required this.title,
    this.subtitle,
    this.secondary,
    this.isThreeLine = false,
    this.dense = false,
    this.contentPadding = const EdgeInsets.symmetric(horizontal: 15.0),
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      value: value,
      onChanged: onChanged,
      title: title,
      subtitle: subtitle,
      secondary: secondary,
      isThreeLine: isThreeLine,
      dense: dense,
      contentPadding: contentPadding,
      selected: selected,
      visualDensity: VisualDensity.compact,
    );
  }
}
