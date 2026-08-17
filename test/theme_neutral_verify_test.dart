// 主题 seed 中性换肤（方案 A+C）回归测试。
// 验证：中性灰度 seed 被识别为中性且 monochrome 输出确为灰度；彩色 seed 不被误判。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safenotes/models/seed_scheme.dart';

/// 颜色是否灰度（三通道最大差值 ≤ 阈值，monochrome 色度恒 0，留容差给转换误差）。
bool _isGray(Color c, [int tol = 6]) {
  final int r = (c.r * 255.0).round().clamp(0, 255);
  final int g = (c.g * 255.0).round().clamp(0, 255);
  final int b = (c.b * 255.0).round().clamp(0, 255);
  final int max = [r, g, b].reduce((a, b) => a > b ? a : b);
  final int min = [r, g, b].reduce((a, b) => a < b ? a : b);
  return (max - min) <= tol;
}

void main() {
  test('通用组灰度尾色 + 黑曜石被识别为中性', () {
    const grays = [
      '#F5F5F5', // 米白
      '#FAFAFA', // 瓷白
      '#171717', // 墨黑
      '#000000', // 纯黑
      '#78828C', // 雾灰
      '#56616F', // 石墨灰
      '#0B0B0C', // 黑曜石
    ];
    for (final hex in grays) {
      final c = Color(int.parse(hex.substring(1), radix: 16) | 0xFF000000);
      expect(isNeutralSeed(c), isTrue, reason: hex);
    }
  });

  test('彩色 seed 不被误判为中性', () {
    expect(isNeutralSeed(const Color(0xFFD93636)), isFalse); // 红
    expect(isNeutralSeed(const Color(0xFF2D6CDF)), isFalse); // 蓝
    expect(isNeutralSeed(const Color(0xFF3FA34D)), isFalse); // 绿
  });

  test('中性 seed 经 monochrome 输出确为灰度（亮/暗）', () {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      final scheme = buildSeedColorScheme(const Color(0xFFF5F5F5), brightness);
      for (final c in [
        scheme.primary,
        scheme.onPrimary,
        scheme.surface,
        scheme.onSurface,
        scheme.secondary,
        scheme.outline,
      ]) {
        expect(_isGray(c), isTrue,
            reason: '非灰度: #${c.toARGB32().toRadixString(16)}');
      }
    }
  });

  test('彩色 seed 仍用 tonalSpot（primary 带色度）', () {
    final scheme = buildSeedColorScheme(const Color(0xFF2D6CDF), Brightness.light);
    expect(_isGray(scheme.primary), isFalse);
  });
}
