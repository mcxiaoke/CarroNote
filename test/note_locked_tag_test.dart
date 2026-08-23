/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under
* terms of the GPL-3.0+ license.
*/

// 锁定笔记 + 标签浮层 widget 测试（真实 App + 真实库）
//
// 目标：
//   - 锁定笔记打开后为只读：AppBar 显示「已锁定」指示（ui-note-locked-indicator），
//     隐藏「编辑/预览/保存」入口；
//   - 预览页正文底部展示标签 Chip（ui-note-tag-*）；
//   - 通过更多菜单解锁后恢复可编辑（保存按钮重新出现）；
//   - 全程无布局溢出异常。

import 'package:flutter/material.dart';

import 'package:core/core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'test_helpers.dart';

const String kPassword = 'hello.1111';

void main() {
  setUpAll(() async {
    await initFullEnv();
  });

  tearDown(() async {
    await disposeVault();
  });

  Future<void> loginAndOpenFirstNote(WidgetTester tester) async {
    await pumpApp(tester);
    expect(find.widgetWithText(ShadButton, 'Login'), findsOneWidget);
    await tester.enterText(find.byType(ShadInputFormField), kPassword);
    await tester.pump();
    await tester.tap(find.widgetWithText(ShadButton, 'Login'));
    await tester.pumpAndSettle();

    final firstNote = find.byKey(const Key('ui-home-note-0'));
    expect(firstNote, findsOneWidget);
    await tester.tap(firstNote);
    await tester.pumpAndSettle();
  }

  testWidgets(
    '锁定笔记：只读（无编辑/保存入口）+ AppBar 锁定指示 + 标签浮层',
    (tester) async {
      await prepareUnlockedVault(
        password: kPassword,
        seeds: const [(title: '锁定笔记标题', description: 'body')],
      );
      final all = await NotesDatabase.instance.readAllNotes();
      await NotesDatabase.instance.setNoteLocked(all.first.uuid, true);
      await NotesDatabase.instance.setNoteTags(all.first.uuid, ['个人', '工作']);

      await loginAndOpenFirstNote(tester);

      // AppBar 锁定指示
      expect(find.byKey(const Key('ui-note-locked-indicator')), findsOneWidget);

      // 只读：预览/编辑切换与保存按钮不可见
      expect(find.byKey(const Key('ui-note-button-preview')), findsNothing);
      expect(find.byKey(const Key('ui-note-button-save')), findsNothing);

      // 标签浮层（正文底部）
      expect(find.byKey(const Key('ui-note-tag-个人')), findsOneWidget);
      expect(find.byKey(const Key('ui-note-tag-工作')), findsOneWidget);

      // 无布局异常
      expect(tester.takeException(), isNull, reason: '锁定预览页不应有布局溢出异常');
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  testWidgets('解锁后恢复可编辑：锁定指示消失，预览切换可点', (tester) async {
    await prepareUnlockedVault(
      password: kPassword,
      seeds: const [(title: '解锁测试', description: 'body')],
    );
    final all = await NotesDatabase.instance.readAllNotes();
    await NotesDatabase.instance.setNoteLocked(all.first.uuid, true);

    await loginAndOpenFirstNote(tester);

    expect(find.byKey(const Key('ui-note-locked-indicator')), findsOneWidget);

    // 通过更多菜单解锁
    await tester.tap(find.byKey(const Key('ui-note-button-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unlock note'));
    await tester.pumpAndSettle();

    // 解锁后恢复可编辑（保存按钮已移除，改为自动保存）
    expect(find.byKey(const Key('ui-note-locked-indicator')), findsNothing);
    expect(find.byKey(const Key('ui-note-button-preview')), findsOneWidget);
    // 保存按钮已移除，自动保存
    expect(find.byKey(const Key('ui-note-button-save')), findsNothing);
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(seconds: 90)));
}
