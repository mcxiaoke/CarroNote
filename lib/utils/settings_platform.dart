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
import 'package:settings_ui/settings_ui.dart';

/// 将当前运行平台映射为 settings_ui 的 [DevicePlatform]，
/// 使设置页在各桌面端呈现对应原生风格（Windows/macOS/Linux），
/// 而非被写死成 iOS 分组表样式。
DevicePlatform get currentDevicePlatform {
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      return DevicePlatform.android;
    case TargetPlatform.iOS:
      return DevicePlatform.iOS;
    case TargetPlatform.windows:
      return DevicePlatform.windows;
    case TargetPlatform.macOS:
      return DevicePlatform.macOS;
    case TargetPlatform.linux:
      return DevicePlatform.linux;
    case TargetPlatform.fuchsia:
      return DevicePlatform.android;
  }
}
