/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

// 基础冒烟测试（替代原先引用已删除 widgets/login_button.dart 的用例）
//
// 验证 ShadTheme + ShadButton 在测试环境下可正常构建与交互，
// 不依赖任何已删除的旧组件，也不触碰数据库。

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  group('ShadButton 冒烟测试', () {
    testWidgets('渲染并可点击回调', (WidgetTester tester) async {
      var tapped = false;
      await tester.pumpWidget(
        ShadApp.custom(
          appBuilder: (context) => MaterialApp(
            home: Scaffold(
              body: Center(
                child: ShadButton(
                  onPressed: () => tapped = true,
                  child: const Text('Tap me'),
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.widgetWithText(ShadButton, 'Tap me'), findsOneWidget);
      await tester.tap(find.widgetWithText(ShadButton, 'Tap me'));
      await tester.pump();
      expect(tapped, isTrue);
    });
  });
}
