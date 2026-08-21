/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*/

// WCAG 对比度工具：黑/白前景色反推。
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

/// 按 WCAG 对比度反推字体色：选黑/白中对比度更高者
/// （数学上对任意背景色 ≥ ~4.55:1）。替代手调阈值 0.179 的写法。
Color getFontColorForBackground(Color background) {
  final blackContrast = contrastRatio(Colors.black, background);
  final whiteContrast = contrastRatio(Colors.white, background);
  return blackContrast >= whiteContrast ? Colors.black : Colors.white;
}
