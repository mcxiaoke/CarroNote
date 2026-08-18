/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

// fromSeed 反推 seed 的可行性测试。
//
// 背景：用户希望 primary 直接等于奶油色 #FBDD82，并假设 Material 的
// ColorScheme.fromSeed 是可逆的（给 primary 反推 seed）。
//
// 结论（本测试用真实 ColorScheme.fromSeed 验证）：
//   - tonalSpot（默认 variant）下，primary 只继承 seed 的 HUE；
//   - primary 的 CHROMA 被算法固定为 ≈36（与 seed chroma 无关）；
//   - primary 的 TONE 被算法固定为 40（亮色）/ 80（暗色），任何 variant 都改不了。
//   => 所以 "primary = 奶油色（tone≈87）" 在数学上不可能通过 fromSeed 得到。
//   => fromSeed 对 primary 只有 HUE 一维可逆；要真用奶油做主色，必须 copyWith 直接覆盖。

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

// ---- 辅助：Color <-> Hct ----
Hct hct(Color c) => Hct.fromInt(c.toARGB32());
Color colorFromHct(double hue, double chroma, double tone) =>
    Color(Hct.from(hue, chroma, tone).toInt());

// 反推：给定目标 primary，试图还原一个能产生它的 seed。
// 由于 chroma/tone 被算法锁定，能恢复的只有 hue；seed 的 chroma/lightness 任取。
Color reverseSeedForPrimary(Color targetPrimary, Brightness brightness) {
  final t = hct(targetPrimary);
  // 构造一个与目标同 hue 的 seed（chroma 取 36 即可，因 primary chroma 恒=36）。
  return colorFromHct(t.hue, 36.0, 40.0);
}

void main() {
  // 用户期望的 "奶油 primary"
  const cream = Color(0xFFFBDD82);

  test('tonalSpot: primary 的 hue 来自 seed，chroma 恒≈36，tone 恒=40(亮)', () {
    final scheme = ColorScheme.fromSeed(
      seedColor: cream,
      brightness: Brightness.light,
    );
    final p = hct(scheme.primary);
    debugPrint(
      '[cream seed] -> primary '
      'hue=${p.hue.toStringAsFixed(1)} '
      'chroma=${p.chroma.toStringAsFixed(1)} '
      'tone=${p.tone.toStringAsFixed(1)} '
      '#${scheme.primary.toARGB32().toRadixString(16)}',
    );

    // tone 被固定为 40（亮色）
    expect(p.tone, closeTo(40.0, 0.5));
    // chroma 被固定为 ≈36（与 seed 本身 251/221/130 的 chroma 无关）
    expect(p.chroma, closeTo(36.0, 1.5));
    // hue 与 seed 同（奶油是暖黄，约 90°）
    expect(p.hue, closeTo(hct(cream).hue, 2.0));
  });

  test('seed 的 chroma 完全不影响 primary（只能改 hue）', () {
    final hue = hct(cream).hue;
    // 两个都在黄域内的 chroma，避免超色域被裁切导致 hue 漂移
    final lowChroma = colorFromHct(hue, 10.0, 50.0);
    final highChroma = colorFromHct(hue, 45.0, 50.0);
    final pLow = hct(
      ColorScheme.fromSeed(
        seedColor: lowChroma,
        brightness: Brightness.light,
      ).primary,
    );
    final pHigh = hct(
      ColorScheme.fromSeed(
        seedColor: highChroma,
        brightness: Brightness.light,
      ).primary,
    );
    debugPrint(
      '[low chroma seed]  primary hue=${pLow.hue.toStringAsFixed(1)} chroma=${pLow.chroma.toStringAsFixed(1)}',
    );
    debugPrint(
      '[high chroma seed] primary hue=${pHigh.hue.toStringAsFixed(1)} chroma=${pHigh.chroma.toStringAsFixed(1)}',
    );
    // 关键：同 hue、不同 chroma 的 seed，生成的 primary hue 完全一致、chroma 都≈36
    expect(pLow.hue, closeTo(pHigh.hue, 0.5));
    expect(pLow.chroma, closeTo(36.0, 1.5));
    expect(pHigh.chroma, closeTo(36.0, 1.5));
  });

  test('反推 cream 作为 primary：不可行（tone 被钉在 40，chroma 被钉在 36）', () {
    final candidate = reverseSeedForPrimary(cream, Brightness.light);
    final produced = ColorScheme.fromSeed(
      seedColor: candidate,
      brightness: Brightness.light,
    ).primary;
    final ph = hct(produced);
    debugPrint(
      '[反推 seed] #${candidate.toARGB32().toRadixString(16)} '
      '-> primary hue=${ph.hue.toStringAsFixed(1)} '
      'chroma=${ph.chroma.toStringAsFixed(1)} '
      'tone=${ph.tone.toStringAsFixed(1)} '
      '#${produced.toARGB32().toRadixString(16)}',
    );

    // 反推只能恢复 hue，produced 与 cream 同 hue 但 tone=40 => 深橄榄，不是奶油
    expect(ph.tone, closeTo(40.0, 0.5));
    expect(produced, isNot(equals(cream))); // 永远不等于奶油
    expect(ph.tone, isNot(closeTo(87.0, 5.0))); // 永远到不了 tone 87
  });

  test('实证：遍历所有 hue，没有任何 seed 能让 primary 接近奶油', () {
    // 注意：Flutter Color 的 r/g/b 是归一化 0..1，故距离² 最大值=3（黑白相对）。
    double bestDist = double.infinity;
    Color? bestSeed;
    for (int h = 0; h < 360; h += 3) {
      final seed = HSLColor.fromAHSL(1.0, h.toDouble(), 1.0, 0.5).toColor();
      final primary = ColorScheme.fromSeed(
        seedColor: seed,
        brightness: Brightness.light,
      ).primary;
      final dr = primary.r - cream.r;
      final dg = primary.g - cream.g;
      final db = primary.b - cream.b;
      final dist = dr * dr + dg * dg + db * db; // 归一化空间，0..3
      if (dist < bestDist) {
        bestDist = dist;
        bestSeed = seed;
      }
    }
    final bestPrimary = ColorScheme.fromSeed(
      seedColor: bestSeed!,
      brightness: Brightness.light,
    ).primary;
    final bestLum = bestPrimary.computeLuminance();
    debugPrint(
      '[hue 扫描] 最接近奶油的 primary #${bestPrimary.toARGB32().toRadixString(16)} '
      '与奶油的归一化距离² = ${bestDist.toStringAsFixed(3)} (0=相同, 3=最远)',
    );
    debugPrint(
      '[hue 扫描] 该最近 primary 的 luminance = ${bestLum.toStringAsFixed(3)} '
      '(奶油 luminance≈0.78，说明它仍是深色)',
    );
    // 1) 最近的 primary 也明显不等于奶油（归一化距离² > 0）
    expect(bestDist, greaterThan(0.3));
    // 2) 决定性证据：任何 primary 的亮度都远低于奶油 => 永远到不了亮色
    expect(bestLum, lessThan(0.4));
  });

  test('实践路径：要真用奶油做主色，必须 copyWith 直接覆盖 primary', () {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: cream,
          brightness: Brightness.light,
        ).copyWith(
          primary: cream,
          onPrimary: const Color(0xFF1A1A1A), // 奶油做 primary 时 onPrimary 须用深色保对比
        );
    expect(scheme.primary, equals(cream)); // 覆盖成功
    debugPrint(
      '[copyWith] primary 现在 = #${scheme.primary.toARGB32().toRadixString(16)} '
      '(奶油本身)，onPrimary 用深色保证可读',
    );
  });
}
