/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

// 主题 seed 色的 M3 调色板生成（Material 与 ShadCN 两端共用，保证同步换肤）。
//
// 背景：ColorScheme.fromSeed 默认 tonalSpot 只取 seed 的 HCT 色相、把 primary
// 色度硬编码为 36，完全丢弃 seed 的明暗与饱和度。中性灰度色会被赋一个无意义
// 伪色相并放大成任意彩色（米白/瓷白/墨黑偏青、纯黑偏粉紫）。详见
// docs/THEME_COLOR_INVESTIGATION.md。
//
// 最简单修复（方案 A+C，已实施）：
// - 中性灰度 seed：改用 DynamicSchemeVariant.monochrome（色度恒 0）生成中性主题，
//   明暗跟随全局暗色开关（与彩色 seed 一致）。
// - 彩色 seed：保持默认 tonalSpot（原行为）。
// 两端（Material / ShadCN）共用本文件，均调用 buildSeedColorScheme，保证同步换肤。
//
// 备选（未采用，备忘，方案 B 曾试过但观感未提升、已回退）：
// - 让中性主题明暗由 seed 自身亮度决定（米白→浅、墨黑→深）：
//   monochrome(brightness: seed.computeLuminance() < 0.5 ? dark : light)。
// - ShadCN 端改用 shadcn_ui 内置 ShadNeutralColorScheme 替代 Slate + 品牌色覆盖：
//   改动大、观感未提升，回退到本简单方案。

import 'package:flutter/material.dart';

import 'package:safenotes/utils/env_config.dart';

/// seed 是否为中性灰度色：RGB 三通道最大差值极小（R≈G≈B）。
///
/// 阈值 26 经全色库扫描确定：恰好命中「通用」组的 6 个灰度尾色
/// （石墨灰/雾灰/米白/瓷白/墨黑/纯黑）与「深邃」组的黑曜石，
/// 不会误伤其它分组里有意向的浅彩色（米色/奶油棕/灰豆绿等）。
bool isNeutralSeed(Color seed) {
  final int r = (seed.r * 255.0).round().clamp(0, 255);
  final int g = (seed.g * 255.0).round().clamp(0, 255);
  final int b = (seed.b * 255.0).round().clamp(0, 255);
  final int max = [r, g, b].reduce((a, b) => a > b ? a : b);
  final int min = [r, g, b].reduce((a, b) => a < b ? a : b);
  return (max - min) <= 26;
}

/// Material 侧 M3 ColorScheme 生成（方案 A+C）。
///
/// - 中性灰度 seed → [DynamicSchemeVariant.monochrome]（色度 0），明暗跟随全局
///   [brightness]（暗色开关）；
/// - 彩色 seed → 默认 [DynamicSchemeVariant.tonalSpot]（原行为，保持协调彩色主题）。
///
/// 环境变量覆盖：设置 `SN_THEME_DSV`（或 `SN_ENV_VARS` 内 `THEME_DSV`）可强制
/// 使用指定的 [DynamicSchemeVariant]，用于外观对比/调试（见 [env_config.dart]）。
/// 覆盖一旦设置，中性与彩色 seed 一律走该 variant。
ColorScheme buildSeedColorScheme(Color seed, Brightness brightness) {
  final DynamicSchemeVariant? override = themeDynamicSchemeVariantOverride;
  if (override != null) {
    return ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      dynamicSchemeVariant: override,
    );
  }
  if (isNeutralSeed(seed)) {
    return ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
    );
  }
  return ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
}
