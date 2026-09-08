/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under
* terms of the GPL-3.0+ license.
*/

// 笔记操作菜单（note_actions_sheet）测试
//
// 目标：从 UI 层面验证「更多」弹层的纯表现与返回值契约（业务动作不在这里执行）：
//   - 默认（未置顶）渲染三项：复制全文 / 添加星标 / 删除笔记
//   - 点击各项 pop 对应 NoteAction 枚举（copyAll / toggleStar / delete）
//   - pinned=true 时星标项文案改为「取消星标」、图标改用 starOff
//   - 删除项使用危险色（与普通项前景色不同）
//   - 点击遮罩关闭时返回 null（无动作）
//
// 不依赖真实数据库/密钥环：sheet 只接收调用方传入的 pinned，断言专注 UI 与枚举契约。

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/widgets/note_actions_sheet.dart';
import 'test_helpers.dart';

void main() {
  setUpAll(() async {
    await initLightEnv();
  });

  setUp(() {
    prepareProviders();
  });

  /// 单屏里放一个按钮，点击后弹出操作菜单并把结果经 [Completer] 回传。
  /// 返回已打开的 completer.future，供断言用户选择；sheet 在返回前已 pump 完成。
  Future<Completer<NoteAction?>> openSheet(
    WidgetTester tester,
    bool pinned, {
    bool locked = false,
  }) async {
    final completer = Completer<NoteAction?>();
    await tester.pumpWidget(
      wrapScreen(
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                key: const Key('ui-open-sheet'),
                onPressed: () async {
                  final action = await showNoteActionsSheet(
                    context,
                    pinned: pinned,
                    locked: locked,
                  );
                  completer.complete(action);
                },
                child: const Text('Open sheet'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ui-open-sheet')));
    await tester.pumpAndSettle();
    return completer;
  }

  testWidgets('未置顶：渲染三项，复制返回 copyAll', (WidgetTester tester) async {
    final completer = await openSheet(tester, false);

    expect(find.byKey(const Key('ui-note-action-copy')), findsOneWidget);
    expect(find.byKey(const Key('ui-note-action-star')), findsOneWidget);
    expect(find.byKey(const Key('ui-note-action-delete')), findsOneWidget);

    expect(find.text('Copy all'), findsOneWidget);
    expect(find.text('Add star'), findsOneWidget);
    expect(find.text('Delete note'), findsOneWidget);

    // 未置顶时星标项用 star 图标
    expect(
      find.descendant(
        of: find.byKey(const Key('ui-note-action-star')),
        matching: find.byIcon(LucideIcons.star),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('ui-note-action-copy')));
    final action = await completer.future.timeout(const Duration(seconds: 5));
    expect(action, NoteAction.copyAll);
  });

  testWidgets('锁定项：未锁定时显示「Lock note」，点击返回 toggleLock', (
    WidgetTester tester,
  ) async {
    final completer = await openSheet(tester, false, locked: false);

    expect(find.byKey(const Key('ui-note-action-lock')), findsOneWidget);
    expect(find.text('Lock note'), findsOneWidget);
    expect(find.text('Unlock note'), findsNothing);

    await tester.tap(find.byKey(const Key('ui-note-action-lock')));
    final action = await completer.future.timeout(const Duration(seconds: 5));
    expect(action, NoteAction.toggleLock);
  });

  testWidgets('已锁定时：锁定项显示「Unlock note」且用 lockOpen 图标', (
    WidgetTester tester,
  ) async {
    final completer = await openSheet(tester, false, locked: true);

    expect(find.text('Unlock note'), findsOneWidget);
    expect(find.text('Lock note'), findsNothing);

    await tester.tap(find.byKey(const Key('ui-note-action-lock')));
    final action = await completer.future.timeout(const Duration(seconds: 5));
    expect(action, NoteAction.toggleLock);
  });

  testWidgets('已置顶：星标项文案为「取消星标」且用 starOff 图标', (WidgetTester tester) async {
    final completer = await openSheet(tester, true);

    expect(find.text('Remove star'), findsOneWidget);
    expect(find.text('Add star'), findsNothing);

    expect(
      find.descendant(
        of: find.byKey(const Key('ui-note-action-star')),
        matching: find.byIcon(LucideIcons.starOff),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('ui-note-action-star')));
    final action = await completer.future.timeout(const Duration(seconds: 5));
    expect(action, NoteAction.toggleStar);
  });

  testWidgets('删除项为危险色，点击返回 delete', (WidgetTester tester) async {
    final completer = await openSheet(tester, false);

    final copyIcon = tester.widget<Icon>(
      find.descendant(
        of: find.byKey(const Key('ui-note-action-copy')),
        matching: find.byType(Icon),
      ),
    );
    final deleteIcon = tester.widget<Icon>(
      find.descendant(
        of: find.byKey(const Key('ui-note-action-delete')),
        matching: find.byType(Icon),
      ),
    );

    expect(copyIcon.color, isNotNull, reason: '普通项图标应显式着色（前景色）');
    expect(
      deleteIcon.color,
      isNot(equals(copyIcon.color)),
      reason: '删除项应使用危险色，区别于普通项前景色',
    );

    await tester.tap(find.byKey(const Key('ui-note-action-delete')));
    final action = await completer.future.timeout(const Duration(seconds: 5));
    expect(action, NoteAction.delete);
  });

  testWidgets('点击遮罩关闭返回 null', (WidgetTester tester) async {
    final completer = await openSheet(tester, false);

    // 顶-left 空白处应命中模态遮罩，触发 pop(null)
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    final action = await completer.future.timeout(const Duration(seconds: 5));
    expect(action, isNull);
  });
}
