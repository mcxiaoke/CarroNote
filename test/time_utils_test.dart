/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under
* terms of the GPL-3.0+ license.
*/

// 卡片时间标签 noteTimeLabel 契约测试
//
// 修复前：开启相对时间后只有"当天"笔记显示相对时间，更早的笔记仍是绝对时间，
// 与设置项描述（Show note timestamps as relative）不符。
// 契约：isRelative=true 时**所有**笔记（含多天前）都显示相对时间；
//       isRelative=false 时始终显示绝对日期+时间。

import 'package:flutter_test/flutter_test.dart';

import 'package:safenotes/utils/time_utils.dart';

void main() {
  test('开启相对时间：5前的笔记应显示相对时间', () {
    final old = DateTime.now().subtract(const Duration(days: 5));
    final label = noteTimeLabel(
      time: old,
      localeString: 'en_US',
      isRelative: true,
    );
    expect(
      label.toLowerCase(),
      contains('ago'),
      reason: '5前的笔记也应显示相对时间（含 ago），实际: $label',
    );
  });

  test('开启相对时间：10前的笔记应显示绝对时间', () {
    final old = DateTime.now().subtract(const Duration(days: 10));
    final label = noteTimeLabel(
      time: old,
      localeString: 'en_US',
      isRelative: true,
    );
    expect(
      label.toLowerCase(),
      isNot(contains('ago')),
      reason: '10天前的笔记应显示绝对时间（不 ago），实际: $label',
    );
  });

  test('关闭相对时间：始终显示绝对日期+时间', () {
    final old = DateTime.now().subtract(const Duration(days: 3));
    final label = noteTimeLabel(
      time: old,
      localeString: 'en_US',
      isRelative: false,
    );
    expect(
      label.toLowerCase(),
      isNot(contains('ago')),
      reason: '绝对时间不应包含 ago，实际: $label',
    );
    expect(label, contains(RegExp(r'\d{4}')), reason: '应包含年份，实际: $label');
  });
}
