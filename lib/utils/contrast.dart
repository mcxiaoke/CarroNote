/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*/

// WCAG 对比度工具 + 字体色反推。
//
// 从 notes_color.dart 抽出为独立模块，避免 app_theme.dart（被 notes_color.dart
// 反向依赖）再引入 notes_color.dart 形成循环依赖。笔记卡与 AppBar 两端共用本文件。

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// WCAG 相对对比度：(L1+0.05)/(L2+0.05)。
double contrastRatio(Color a, Color b) {
  final l1 = a.computeLuminance();
  final l2 = b.computeLuminance();
  return (math.max(l1, l2) + 0.05) / (math.min(l1, l2) + 0.05);
}

/// 用于浅色模式的"深色"前景色（替代纯黑）。
const Color kDarkForeground = Color(0xFF1C1B1F); // M3 onSurface (light)

/// 用于暗色模式的"浅色"前景色（替代纯白）。
const Color kLightForeground = Color(0xFFE6E1E5); // M3 onSurface (dark)

/// 根据背景色亮度反推字体色。
///
/// 优先返回 M3 onSurface 色阶（深灰/浅灰），比纯黑纯白更柔和；
/// 当中等亮度背景与 onSurface 的对比度不足 WCAG AA (4.5:1) 时，
/// 回退到纯黑/纯白（选对比度更高者，数学上保证 ≥ 4.58:1）。
///
/// [isDark] 为当前是否暗色模式。不传时按背景亮度自行判断：
/// 使用 WCAG 理论阈值 0.179（黑白对比度相等点），而非 0.5。
Color getFontColorForBackground(Color background, {bool? isDark}) {
  final dark = isDark ?? background.computeLuminance() < 0.179;
  final softFg = dark ? kLightForeground : kDarkForeground;
  if (contrastRatio(softFg, background) >= 4.5) {
    return softFg;
  }
  // 回退：选黑/白中对比度更高者（数学上对任意背景 ≥ ~4.58:1）。
  final blackContrast = contrastRatio(Colors.black, background);
  final whiteContrast = contrastRatio(Colors.white, background);
  return blackContrast >= whiteContrast ? Colors.black : Colors.white;
}
