// 笔记卡字体色对比度测试（P1-12）
//
// 覆盖：16 个卡片色主题（allNotesColorTheme）的每个颜色，
// 在「原色」与「浅色模式提亮 0.4」两种背景下，getFontColorForBackground
// 选出的字体色对比度均 ≥ 4.5（WCAG AA）。

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:flutter_test/flutter_test.dart';

// Project imports:
import 'package:safenotes/utils/notes_color.dart';

void main() {
  test('all note color themes meet WCAG 4.5:1 contrast', () {
    var checked = 0;
    for (final theme in allNotesColorTheme) {
      for (final rawColor in theme.colorList) {
        final raw = rawColor as Color;
        // 与 NotesColor._lightenAmount 保持一致：浅色模式提亮 40%。
        final lightened = Color.lerp(raw, Colors.white, 0.4)!;
        for (final bg in [raw, lightened]) {
          final fg = getFontColorForBackground(bg);
          final ratio = contrastRatio(fg, bg);
          expect(
            ratio,
            greaterThanOrEqualTo(4.5),
            reason: '${theme.prefix} color=$bg -> fg=$fg ratio=$ratio',
          );
          checked++;
        }
      }
    }
    // 至少覆盖 16 个主题的每个颜色 × 2 种背景。
    expect(checked, greaterThanOrEqualTo(16 * 2));
  });
}
