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

import 'package:safenotes/data/preference_and_config.dart';

/// 用户可选「全局字体类型」：覆盖平台原生字体，对整个 App 生效。
///
/// 顺序即索引，[PreferencesStorage.fontFamilyTypeIndex] 存的是这里的索引：
/// 0 = 非衬线（默认，沿用平台原生无衬线字体，保持现状）、
/// 1 = 衬线、2 = 等宽。切换后由 [uiFontFamily]/[uiFontFamilyFallback] 全局生效。
enum AppFontType {
  /// 非衬线字体：桌面复用系统原生无衬线体（Segoe UI / SF / Ubuntu），移动/Web 走系统默认。
  sans,

  /// 衬线字体。
  serif,

  /// 等宽字体。
  mono,
}

/// 指定字体类型的主字体族。
///
/// 平台差异（关键，踩过坑）：
/// - **Windows / macOS**：通用族名（'serif' / 'monospace'）解析不稳定，尤其 Windows
///   的 'serif' 会回退成默认无衬线，导致「衬线」与「非衬线」外观完全相同、切换无变化；
///   这两个桌面平台都预装了下列具体字体，故用具体名保证三种字体外观明显不同。
/// - **Android / iOS / Linux / Web**：具体西文字体通常不预装（如 Android 没有
///   Georgia / Consolas），必须用通用族名，由平台/系统字体映射到真实系统字体
///   （Android 的 'serif' 会映射到系统衬线体、'monospace' 映射到系统等宽体）。
String? appFontFamilyFor(AppFontType type) {
  if (defaultTargetPlatform == TargetPlatform.windows) {
    return switch (type) {
      AppFontType.sans => _platformSansFamily,
      AppFontType.serif => 'Georgia',
      AppFontType.mono => 'Consolas',
    };
  }
  if (defaultTargetPlatform == TargetPlatform.macOS) {
    return switch (type) {
      AppFontType.sans => _platformSansFamily,
      AppFontType.serif => 'Georgia',
      AppFontType.mono => 'Menlo',
    };
  }
  // 其余平台：用通用族名，交系统映射到真实字体。
  // 注意：sans 必须返回非空的 'sans-serif' 而**不能返回 null**——Flutter 在
  // fontFamily 由非空（'serif'/'monospace'）变为 null 时不会重排文字（已知
  // repaint 缺陷），会导致「从衬线/等宽切回非衬线时预览不更新」。'sans-serif'
  // 在 Android/iOS/Linux/Web 均映射到系统默认无衬线，观感与 null 一致。
  switch (type) {
    case AppFontType.sans:
      return 'sans-serif';
    case AppFontType.serif:
      return 'serif';
    case AppFontType.mono:
      return 'monospace';
  }
}

/// 指定字体类型的 CJK 兜底字体族（主字体不含中日韩字形时回退）。
///
/// 桌面（Win/macOS）用具体字体名，需显式 CJK 兜底；其余平台主字体是通用族名，
/// 系统本身已含 CJK 回退，故留空避免引入不存在的字体名。
List<String> appFontFallbackFor(AppFontType type) {
  if (defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS) {
    switch (type) {
      case AppFontType.sans:
        return _platformSansFallback;
      case AppFontType.serif:
        return const [
          'Songti SC',
          'SimSun',
          'Noto Serif CJK SC',
          'Source Han Serif SC',
        ];
      case AppFontType.mono:
        return const [
          'Noto Sans Mono CJK SC',
          'Sarasa Mono SC',
          'Microsoft YaHei',
        ];
    }
  }
  return const [];
}

/// 平台原生非衬线主字体族（与历史行为一致：桌面用系统原生，移动/Web 返回 null）。
String? get _platformSansFamily {
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

/// 平台原生非衬线 CJK 兜底（与历史行为一致）。
List<String> get _platformSansFallback {
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

/// 平台相关的 UI 字体族（全局生效）。
///
/// 优先使用用户在设置中选定的 [AppFontType]；默认（非衬线）沿用平台原生
/// 无衬线字体，保持现状。切换字体类型存于 [PreferencesStorage.fontFamilyTypeIndex]，
/// 由主题重建（[ThemeProvider.notifyListeners]）全局生效。
String? get uiFontFamily => appFontFamilyFor(_currentAppFontType);

/// CJK 兜底字体列表（与 [uiFontFamily] 同一字体类型）。
///
/// Segoe UI / .AppleSystemUIFont 不含中日韩字形，必须显式回退到系统中文字体，
/// 否则中文会回退到与拉丁文不同的字体族，造成中英混排不一致。
List<String> get uiFontFamilyFallback =>
    appFontFallbackFor(_currentAppFontType);

/// 当前生效的全局字体类型（读偏好并夹紧，防越界崩溃）。
AppFontType get _currentAppFontType {
  final max = AppFontType.values.length - 1;
  final i = PreferencesStorage.fontFamilyTypeIndex.clamp(0, max);
  return AppFontType.values[i];
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
