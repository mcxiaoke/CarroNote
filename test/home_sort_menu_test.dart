/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under
* terms of the GPL-3.0+ license.
*/

// 主界面「排序/显示偏好」下拉菜单测试
//
// 契约：
//   1. AppBar 排序 icon 点击弹出下拉菜单，包含全部六个开关项
//      （Newest first / Sort by Modified Date / Relative Time /
//       Compact Notes / Notes Color / Starred only）；
//   2. 「仅显示星标」为纯内存开关：开启后列表只保留置顶笔记，
//      关闭后恢复全部笔记（不写偏好、不影响其他端）；
//   3. 「新→旧」方向开关仍可切换排序方向（保留原 icon 行为）。

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

  testWidgets('排序icon弹出下拉菜单并切换仅显示星标', (WidgetTester tester) async {
    await prepareUnlockedVault(password: kPassword);

    final now = DateTime.now().millisecondsSinceEpoch;
    final noteA = SafeNote.create(
      title: 'Note A',
      description: 'body A',
    ).copyWith(updatedAt: now - 3000);
    final noteB = SafeNote.create(
      title: 'Note B',
      description: 'body B',
    ).copyWith(updatedAt: now - 2000);
    final noteC = SafeNote.create(
      title: 'Note C',
      description: 'body C',
    ).copyWith(updatedAt: now - 1000);
    await NotesDatabase.instance.storeNote(noteA);
    await NotesDatabase.instance.storeNote(noteB);
    await NotesDatabase.instance.storeNote(noteC);

    // 置顶最旧的 A：默认列表顺序应为 置顶A → C → B（新→旧）。
    await NotesDatabase.instance.setNotePinned(noteA.uuid, true);

    await pumpApp(tester);

    expect(find.widgetWithText(ShadButton, 'Login'), findsOneWidget);
    await tester.enterText(find.byType(ShadInputFormField), kPassword);
    await tester.pump();
    await tester.tap(find.widgetWithText(ShadButton, 'Login'));
    await tester.pumpAndSettle();

    // 默认排序：置顶 A 恒第 0，其余新→旧 → C 在第 1、B 在第 2。
    expect(
      find.descendant(
        of: find.byKey(const Key('ui-home-note-0')),
        matching: find.text('Note A'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('ui-home-note-1')),
        matching: find.text('Note C'),
      ),
      findsOneWidget,
    );

    // 点击排序 icon 弹出下拉菜单，六个开关项齐全。
    await tester.tap(find.byKey(const Key('ui-home-toolbar-sort')));
    await tester.pumpAndSettle();
    for (final key in const [
      'ui-home-menu-newfirst',
      'ui-home-menu-sortmodified',
      'ui-home-menu-relativetime',
      'ui-home-menu-compact',
      'ui-home-menu-colorful',
      'ui-home-menu-starredonly',
    ]) {
      expect(find.byKey(Key(key)), findsOneWidget, reason: '缺少菜单项 $key');
    }

    // 开启「仅显示星标」：只保留置顶的 A，列表只渲染一张卡片。
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('ui-home-menu-starredonly')),
        matching: find.byType(ShadSwitch),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const Key('ui-home-note-0')),
        matching: find.text('Note A'),
      ),
      findsOneWidget,
      reason: '开启仅显示星标后，置顶笔记应保留且排在第 0 位',
    );
    expect(find.text('Note B'), findsNothing);
    expect(find.text('Note C'), findsNothing);

    // 再关掉：恢复全部三张笔记（纯内存开关，不持久化）。
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('ui-home-menu-starredonly')),
        matching: find.byType(ShadSwitch),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('ui-home-note-2')),
        matching: find.text('Note B'),
      ),
      findsOneWidget,
      reason: '关闭仅显示星标后应恢复全量列表（排序不变）',
    );

    // 切换「新→旧」方向 → 旧→新：B/C 顺序反转，A 仍置顶在前。
    await tester.tap(find.byKey(const Key('ui-home-menu-newfirst')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('ui-home-note-1')),
        matching: find.text('Note B'),
      ),
      findsOneWidget,
      reason: '新→旧关闭后应改为旧→新（B 排在 C 前）',
    );
  }, timeout: const Timeout(Duration(seconds: 90)));
}
