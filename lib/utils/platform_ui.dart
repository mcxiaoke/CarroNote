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
    show defaultTargetPlatform, TargetPlatform, kIsWeb;

import 'package:flutter/material.dart';

/// 平台相关的 UI 字体族。
///
/// 让桌面端（尤其是 Windows）使用系统原生无衬线字体，而非打包的衬线字体，
/// 这是"像原生"的最关键单点。移动端返回 null，沿用系统默认（Roboto / SF）。
/// Web 下恒返回 null（P1-8）：Web 走浏览器默认无衬线字体，
/// 否则会按 UA 误返回 'Segoe UI' 等桌面字体名（Web 并不保证安装该字体）。
String? get uiFontFamily {
  if (kIsWeb) return null;
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
/// Web 下与 [uiFontFamily] 一致返回空（浏览器自带中文字体回退）。
List<String> get uiFontFamilyFallback {
  if (kIsWeb) return const [];
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

/// 是否为桌面平台（Windows / macOS / Linux）。
///
/// 用于布局与交互范式判断。Web 下恒为 false（Web 是独立于桌面/移动之外的
/// 第三态，见 [isWeb]），调用方无需再额外写 `!kIsWeb && (…)`。
bool get isDesktopPlatform {
  if (kIsWeb) return false;
  switch (defaultTargetPlatform) {
    case TargetPlatform.windows:
    case TargetPlatform.macOS:
    case TargetPlatform.linux:
      return true;
    default:
      return false;
  }
}

/// 是否为 Web 平台（独立于桌面/移动之外的第三态）。
bool get isWeb => kIsWeb;

/// 是否处于「紧凑横屏」：移动端（Android / iOS）且设备当前为横屏。
///
/// 用于 PIN 键盘等场景——横屏下可用高度很矮，需要切到更紧凑的布局
/// （隐藏装饰头部 / 改流式键盘 / 缩小按键）。桌面端高度充足、Web 走浏览器
/// 自适应布局，二者恒为 false，调用方无需再重复写判定。
bool isCompactLandscape(BuildContext context) =>
    isMobilePlatform &&
    MediaQuery.orientationOf(context) == Orientation.landscape;

/// 是否为移动平台（Android / iOS）。
///
/// Web 下恒为 false，因此桌面/移动/Web 三者互斥且覆盖常见运行场景。
bool get isMobilePlatform {
  if (kIsWeb) return false;
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
      return true;
    default:
      return false;
  }
}

/// 是否为 Android（仅移动端的 Android，Web 下恒为 false）。
///
/// 替代散落的 `Platform.isAndroid`，统一来源、避免 Web 下误入 `dart:io` 分支。
bool get isAndroid {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.android;
}

/// 是否为 iOS（仅移动端的 iOS，Web 下恒为 false）。
///
/// 替代散落的 `Platform.isIOS`，统一来源、避免 Web 下误入 `dart:io` 分支。
bool get isIOS {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.iOS;
}
