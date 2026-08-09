/*
* Copyright (C) Keshav Priyadarshi and others - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
*
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
import 'package:flutter/material.dart';

/// 平台相关的 UI 字体族。
///
/// 让桌面端（尤其是 Windows）使用系统原生无衬线字体，而非打包的衬线字体，
/// 这是"像原生"的最关键单点。移动端返回 null，沿用系统默认（Roboto / SF）。
String? get uiFontFamily {
  switch (defaultTargetPlatform) {
    case TargetPlatform.windows:
      return 'Segoe UI';
    case TargetPlatform.macOS:
      return '.AppleSystemUIFont';
    case TargetPlatform.linux:
      return 'Ubuntu';
    case TargetPlatform.fuchsia:
      return 'Roboto';
    default:
      return null;
  }
}

/// CJK 兜底字体列表。
///
/// Segoe UI / .AppleSystemUIFont 不含中日韩字形，必须显式回退到系统中文字体，
/// 否则中文会回退到与拉丁文不同的字体族，造成中英混排不一致。
List<String> get uiFontFamilyFallback {
  switch (defaultTargetPlatform) {
    case TargetPlatform.windows:
      return const ['Microsoft YaHei', 'PingFang SC', 'Noto Sans CJK SC'];
    case TargetPlatform.macOS:
      return const ['PingFang SC', 'Microsoft YaHei', 'Noto Sans CJK SC'];
    default:
      return const [];
  }
}

/// 将平台 UI 字体应用到基础 TextTheme（保留原有字重/字号，仅替换字体族）。
TextTheme applyUiFont(TextTheme base) {
  return base.apply(
    fontFamily: uiFontFamily,
    fontFamilyFallback: uiFontFamilyFallback,
  );
}

/// 通用标题样式：用平台 UI 字体替代原先统一的 MerriweatherBlack 衬线重体。
TextStyle uiTitleStyle({
  double fontSize = 20,
  FontWeight fontWeight = FontWeight.bold,
  Color? color,
  double letterSpacing = 0,
}) {
  return TextStyle(
    fontFamily: uiFontFamily,
    fontFamilyFallback: uiFontFamilyFallback,
    fontWeight: fontWeight,
    fontSize: fontSize,
    color: color,
    letterSpacing: letterSpacing,
  );
}

/// 是否为桌面平台（用于布局与交互范式判断）。
bool get isDesktopPlatform {
  switch (defaultTargetPlatform) {
    case TargetPlatform.windows:
    case TargetPlatform.macOS:
    case TargetPlatform.linux:
      return true;
    default:
      return false;
  }
}
