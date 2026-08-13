// 主题颜色选择器（ThemeColorPicker）测试
//
// 验证：
//   1. 分组色库渲染：6 个分组 tab 可见，默认选中组 0 的颜色 0（冷调专业·深海蓝）
//   2. 点击色块 → ThemeProvider 的 groupIndex/colorIndex 更新（全局换肤入口）
//   3. 切分组 → 网格切换到新组的颜色

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/theme_seeds.g.dart';
import 'package:safenotes/views/settings/theme_color_setting.dart';

import 'test_helpers.dart';

void main() {
  setUpAll(() async {
    await initTestEnv();
  });

  setUp(() async {
    await PreferencesStorage.init();
    prepareProviders();
  });

  testWidgets('渲染 6 个分组 tab 与默认选中色', (WidgetTester tester) async {
    await tester.pumpWidget(wrapScreen(const ThemeColorPicker()));
    await tester.pumpAndSettle();

    // 6 个分组 tab 的名称（英文 locale 下用英文名）
    for (final group in AppThemeSeeds.groups) {
      expect(find.text(group.nameEn), findsWidgets,
          reason: '分组 ${group.nameEn} 的 tab 应存在');
    }

    // 默认选中态与持久化一致（组 0 / 色 0 = 冷调专业·深海蓝）
    expect(testThemeProvider.groupIndex, 0);
    expect(testThemeProvider.colorIndex, 0);
    expect(testThemeProvider.seedColor, const Color(0xFF0F3460));
  });

  testWidgets('点击色块实时更新 ThemeProvider 并持久化', (WidgetTester tester) async {
    await tester.pumpWidget(wrapScreen(const ThemeColorPicker()));
    await tester.pumpAndSettle();

    // 组 0（冷调专业）的第 3 个颜色（钢蓝色 0xFF2C5F8D）
    const targetIndex = 2;
    final targetColor = AppThemeSeeds.colorByIndex(0, targetIndex);

    await tester.tap(find.text('Steel Blue'));
    await tester.pumpAndSettle();

    expect(testThemeProvider.colorIndex, targetIndex,
        reason: '点击色块后 colorIndex 应更新');
    expect(testThemeProvider.seedColor, targetColor);
    expect(PreferencesStorage.themeColorIndex, targetIndex,
        reason: '选择应持久化到偏好设置');
  });

  testWidgets('切换分组显示新组颜色，点击色块才更新全局主题', (WidgetTester tester) async {
    await tester.pumpWidget(wrapScreen(const ThemeColorPicker()));
    await tester.pumpAndSettle();

    // 切到第 2 组（经典通用）：仅本地浏览态变化，全局 Provider 不受影响
    await tester.tap(find.text('Classic Universal'));
    await tester.pumpAndSettle();
    expect(find.text('Red'), findsWidgets,
        reason: '切组后网格应展示新组颜色（经典通用·红色）');
    expect(testThemeProvider.groupIndex, 0,
        reason: '仅切组浏览不应改变全局已选主题色组');

    // 点击新组内的色块 → 全局 ThemeProvider 才更新并持久化
    await tester.tap(find.text('Red'));
    await tester.pumpAndSettle();
    expect(testThemeProvider.groupIndex, 1);
    expect(testThemeProvider.colorIndex, 0);
    expect(testThemeProvider.seedColor, const Color(0xFFE53935));
    expect(PreferencesStorage.themeGroupIndex, 1,
        reason: '选择应持久化到偏好设置');
  });
}
