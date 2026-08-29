/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/widgets/markdown_toolbar.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await PreferencesStorage.init();
  });
  testWidgets('MarkdownToolbar 点击粗体按钮包裹选中文本并保持焦点', (tester) async {
    final controller = TextEditingController(text: 'Hello World');
    final focusNode = FocusNode();
    controller.selection = const TextSelection(baseOffset: 6, extentOffset: 11);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              TextField(controller: controller, focusNode: focusNode),
              MarkdownToolbar(
                controller: controller,
                focusNode: focusNode,
                isDesktop: true,
              ),
            ],
          ),
        ),
      ),
    );

    // 找到 Bold 按钮
    final boldBtn = find.byKey(const Key('ui-toolbar-btn-bold'));
    expect(boldBtn, findsOneWidget);

    await tester.tap(boldBtn);
    await tester.pumpAndSettle();

    expect(controller.text, 'Hello **World**');
    expect(controller.selection.baseOffset, 8);
    expect(controller.selection.extentOffset, 13);
  });

  testWidgets('MarkdownToolbar 点击任务清单按钮插入待办前缀', (tester) async {
    final controller = TextEditingController(text: 'Task item');
    controller.selection = const TextSelection.collapsed(offset: 0);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownToolbar(controller: controller, isDesktop: false),
        ),
      ),
    );

    final taskBtn = find.byKey(const Key('ui-toolbar-btn-task'));
    expect(taskBtn, findsOneWidget);

    await tester.tap(taskBtn);
    await tester.pumpAndSettle();

    expect(controller.text, '- [ ] Task item');
  });

  testWidgets('MarkdownToolbar 点击分割线按钮插入 hr', (tester) async {
    final controller = TextEditingController(text: 'Line 1\nLine 2');
    controller.selection = const TextSelection.collapsed(offset: 6);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownToolbar(controller: controller, isDesktop: false),
        ),
      ),
    );

    final hrBtn = find.byKey(const Key('ui-toolbar-btn-hr'));
    expect(hrBtn, findsOneWidget);

    await tester.tap(hrBtn);
    await tester.pumpAndSettle();

    expect(controller.text, 'Line 1\n---\n\nLine 2');
  });

  test(
    'PreferencesStorage.isMarkdownToolbarEnabled 默认为 true 且支持开关切换',
    () async {
      // 验证默认开启
      expect(PreferencesStorage.isMarkdownToolbarEnabled, isTrue);

      // 切换关闭
      await PreferencesStorage.setIsMarkdownToolbarEnabled(false);
      expect(PreferencesStorage.isMarkdownToolbarEnabled, isFalse);

      // 恢复开启
      await PreferencesStorage.setIsMarkdownToolbarEnabled(true);
      expect(PreferencesStorage.isMarkdownToolbarEnabled, isTrue);
    },
  );
}
