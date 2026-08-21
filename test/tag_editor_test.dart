/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under
* terms of the GPL-3.0+ license.
*/

// 全屏标签编辑页 widget 测试
//
// 目标：验证全屏标签编辑页（Google Keep 风格）在窄屏/宽屏下都不溢出，且：
//   - 候选标签渲染为列表行，已选标签处于勾选态
//   - 点勾选框/行切换选中态
//   - 追加新标签后自动勾选，保存返回勾选子集与完整标签池
//   - 行尾 X 可删除标签（管理态 selectionMode=false 时无勾选框，仅增删）
import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:safenotes/widgets/tag_editor.dart';
import 'test_helpers.dart';

void main() {
  setUpAll(() async {
    await initLightEnv();
  });

  setUp(() {
    prepareProviders();
  });

  /// 单屏放一个按钮，点击打开 [pushTagEditor]。pool/selected 可配。
  /// 返回 completer，供断言页面返回的 [TagEditorResult]。
  Future<Completer<TagEditorResult?>> openEditor(
    WidgetTester tester, {
    List<String> pool = const ['个人', '工作', '灵感'],
    List<String> selected = const ['工作'],
    bool selectionMode = true,
  }) async {
    final completer = Completer<TagEditorResult?>();
    await tester.pumpWidget(
      wrapScreen(
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                key: const Key('ui-open-editor'),
                onPressed: () async {
                  final result = await pushTagEditor(
                    context,
                    title: 'Edit Tags',
                    pool: pool,
                    selected: selected,
                    selectionMode: selectionMode,
                  );
                  completer.complete(result);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ui-open-editor')));
    await tester.pumpAndSettle();
    return completer;
  }

  testWidgets('候选标签渲染为列表行，已选处于勾选态', (tester) async {
    await openEditor(
      tester,
      pool: const ['个人', '工作', '灵感'],
      selected: const ['工作'],
    );

    expect(find.byKey(const Key('ui-tag-row-工作')), findsOneWidget);
    expect(find.byKey(const Key('ui-tag-row-个人')), findsOneWidget);

    final workCheck = tester.widget<Checkbox>(
      find.byKey(const Key('ui-tag-toggle-工作')),
    );
    expect(workCheck.value, isTrue, reason: '已选标签应为勾选态');
    final personalCheck = tester.widget<Checkbox>(
      find.byKey(const Key('ui-tag-toggle-个人')),
    );
    expect(personalCheck.value, isFalse, reason: '未选标签不应为勾选态');

    expect(tester.takeException(), isNull, reason: '全屏页不应有布局溢出异常');
  });

  testWidgets('点勾选框切换选中态', (tester) async {
    await openEditor(tester, pool: const ['个人', '工作'], selected: const []);

    await tester.tap(find.byKey(const Key('ui-tag-toggle-个人')));
    await tester.pumpAndSettle();

    final check = tester.widget<Checkbox>(
      find.byKey(const Key('ui-tag-toggle-个人')),
    );
    expect(check.value, isTrue, reason: '点击勾选框后未选标签应变为选中');
  });

  testWidgets('追加新标签且保存返回勾选子集与标签池', (tester) async {
    final completer = await openEditor(
      tester,
      pool: const ['个人'],
      selected: const ['个人'],
    );

    await tester.enterText(find.byKey(const Key('ui-tag-new')), '读书');
    await tester.tap(find.byKey(const Key('ui-tag-add')));
    await tester.pumpAndSettle();

    // 新标签自动出现在列表且自动勾选
    expect(find.byKey(const Key('ui-tag-row-读书')), findsOneWidget);
    final newCheck = tester.widget<Checkbox>(
      find.byKey(const Key('ui-tag-toggle-读书')),
    );
    expect(newCheck.value, isTrue, reason: '新增标签应自动勾选');

    await tester.tap(find.byKey(const Key('ui-tag-save')));
    final result = await completer.future.timeout(const Duration(seconds: 5));
    expect(result, isNotNull);
    expect(result!.selected, containsAll(['个人', '读书']));
    expect(result.pool, containsAll(['个人', '读书']));
  });

  testWidgets('行尾 X 删除标签（管理态无勾选框）', (tester) async {
    await openEditor(
      tester,
      pool: const ['个人', '工作'],
      selected: const [],
      selectionMode: false,
    );

    // 管理态：不渲染行首勾选框
    expect(find.byType(Checkbox), findsNothing);
    expect(find.byKey(const Key('ui-tag-row-个人')), findsOneWidget);

    await tester.tap(find.byKey(const Key('ui-tag-delete-个人')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ui-tag-row-个人')), findsNothing);
    expect(find.byKey(const Key('ui-tag-row-工作')), findsOneWidget);
  });
}
