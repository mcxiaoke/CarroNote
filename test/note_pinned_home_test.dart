/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under
* terms of the GPL-3.0+ license.
*/

// 置顶（pinned/星标）主界面测试
//
// 目标：从真实 App 层验证阶段 2.1 + 2.2 的两个契约：
//   1. 排序：置顶笔记恒在最前（不受默认"新→旧"时间排序影响）；
//   2. 角标：置顶笔记的卡片显示星标角标（ui-note-pinned-badge），
//      未置顶的笔记不显示。
//
// 复用 test_helpers 的真实 Keyring + 真实 SQLite + 真实 App 路由：
//   - seed 三条不同 updatedAt 的笔记（默认按修改时间新→旧：C/B/A）
//   - 置顶最旧的 A
//   - 登录进入主界面后断言 A 排在第 0 位且带星标角标，B/C 无角标
//
// 这也隐式验证了红线 5：切 pinned 只走 note_meta（_metaCache），
// 不触碰 _notesCache / 笔记正文解密路径（若误走会破坏此排序契约）。

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

  testWidgets('置顶笔记恒在最前且带星标角标', (WidgetTester tester) async {
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

    // 置顶最旧的 A：若没有置顶逻辑，A 默认排最后（新→旧）；置顶后应恒排第 0。
    await NotesDatabase.instance.setNotePinned(noteA.uuid, true);

    await pumpApp(tester);

    // 已有保险库应落在登录页
    expect(find.widgetWithText(ShadButton, 'Login'), findsOneWidget);
    await tester.enterText(find.byType(ShadInputFormField), kPassword);
    await tester.pump();
    await tester.tap(find.widgetWithText(ShadButton, 'Login'));
    await tester.pumpAndSettle();

    // 置顶的 A 排在第 0 位（ui-home-note-0 是排序后列表的第一个元素）
    final firstNote = find.byKey(const Key('ui-home-note-0'));
    expect(firstNote, findsOneWidget);
    expect(
      find.descendant(of: firstNote, matching: find.text('Note A')),
      findsOneWidget,
      reason: '置顶笔记应恒排在列表第 0 位（不受时间排序影响）',
    );

    // 星标角标只出现在置顶卡片上
    final badge = find.byKey(const Key('ui-note-pinned-badge'));
    expect(badge, findsOneWidget);
    expect(find.descendant(of: firstNote, matching: badge), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('ui-home-note-1')),
        matching: find.byKey(const Key('ui-note-pinned-badge')),
      ),
      findsNothing,
      reason: '未置顶笔记不应显示星标角标',
    );

    // 角标完整渲染：圆形背景不被卡片裁切，且用的是 star 图
    final Rect cardRect = tester.getRect(firstNote);
    final Rect badgeRect = tester.getRect(badge);
    expect(
      cardRect.contains(badgeRect.topLeft) &&
          cardRect.contains(badgeRect.bottomRight),
      isTrue,
      reason: '角标应完整落在卡片内，不得被裁切（曾因负偏移被裁成四分之一）',
    );
    expect(
      find.descendant(of: badge, matching: find.byIcon(LucideIcons.star)),
      findsOneWidget,
      reason: '置顶角标应使用 star 图标',
    );
  }, timeout: const Timeout(Duration(seconds: 90)));
}
