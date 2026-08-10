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
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart'
    show BuildContext, ColorScheme, Theme, TextStyle, FontWeight;
import 'package:settings_ui/settings_ui.dart';

// Project imports:
import 'package:safenotes/utils/platform_ui.dart';

/// 将当前运行平台映射为 settings_ui 的 [DevicePlatform]。
///
/// 桌面与 Android 移动端统一渲染 Material 分组（与 App 整体主题一致）；
/// 仅 iOS 保留 iOS 分组表原生风格。
DevicePlatform get currentDevicePlatform {
  switch (defaultTargetPlatform) {
    case TargetPlatform.iOS:
      return DevicePlatform.iOS;
    case TargetPlatform.android:
    case TargetPlatform.windows:
    case TargetPlatform.macOS:
    case TargetPlatform.linux:
    case TargetPlatform.fuchsia:
      return DevicePlatform.android;
  }
}

/// 设置页全局主题。
///
/// 桌面端（Windows/Linux/macOS）：tile 用更大的字号与行高
/// （18 × 1.5 ≈ 27px 文本 + 默认 12.5×2 padding ≈ 52px 行高），
/// 提高可点击目标高度，接近 Android 原生触控尺寸；
/// 移动端返回全 null，沿用 settings_ui 默认（tile 16）。
///
/// dark 时沿用 [AppThemes] 的自定义背景色，与 settings.dart 现有覆盖一致。
/// [SettingsThemeData.merge] 使用 `field ?? this.field`，未覆盖字段保持默认。
SettingsThemeData appSettingsTheme(BuildContext context) {
  final bool desktop = isDesktopPlatform;
  final ColorScheme colorScheme = Theme.of(context).colorScheme;
  return SettingsThemeData(
    titleTextStyle: desktop
        ? const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)
        : null,
    tileTextStyle: desktop
        ? const TextStyle(fontSize: 18, height: 1.5)
        : null,
    tileDescriptionTextStyle: desktop ? const TextStyle(fontSize: 14) : null,
    // 背景统一跟随主题色板（与 App 其它页面一致），不再硬编码 #F2F2F7/#202020/白。
    // settingsSectionBackground 需显式设置：settings_ui 的 android 主题默认为 null
    // （透明无背景块）。
    settingsListBackground: colorScheme.surface,
    settingsSectionBackground: colorScheme.surfaceContainerLow,
  );
}
