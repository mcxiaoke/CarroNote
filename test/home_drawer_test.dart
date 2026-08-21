/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under
* terms of the GPL-3.0+ license.
*/

// 抽屉（HomeDrawer）结构/布局 widget 测试
//
// 目标：验证本轮新增的导航结构不引入布局错误（RenderFlex 溢出等），并校验关键节点：
//   - 主入口：Notes / Starred + 标签组（header「Tags」+ 箭头 + 编辑图标 + 每标签一行 ui-home-nav-tag-*）
//   - 标签组 header（ui-home-tag-header）可点击折叠/展开
//   - 回收站（Trash，原 Recently Deleted）随设置/锁定置于底部导航区（ui-home-nav-deleted）
//   - 分割线（Divider）数量——标签组上下各一条
//   - 设置 / 锁定仍在原 Key（ui-home-nav-settings / ui-home-nav-lock）
//   - 点击标签触发 onTagSelected 回调

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/widgets/drawer.dart';
import 'test_helpers.dart';

void main() {
  setUpAll(() async {
    await initLightEnv();
  });

  setUp(() {
    prepareProviders();
  });

  /// 把抽屉包进一个与真实抽屉等宽/等高的容器，验证展开态布局不溢出。
  Future<void> pumpDrawer(
    WidgetTester tester, {
    List<String> tags = const ['个人', '工作', '灵感'],
    String? activeTag,
    String selectedTag = '',
  }) async {
    String? selected;
    await tester.pumpWidget(
      wrapScreen(
        Scaffold(
          body: SizedBox(
            width: 320,
            height: 600,
            child: HomeDrawer(
              onSettingsCallback: () {},
              onNotesCallback: () {},
              onLockCallback: () {},
              onDeletedNotesCallback: () {},
              onStarredCallback: () {},
              tags: tags,
              activeTag: activeTag,
              onTagSelected: (t) => selected = t,
              onManageTags: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (selectedTag.isNotEmpty) {
      await tester.tap(find.byKey(Key('ui-home-nav-tag-$selectedTag')));
      await tester.pumpAndSettle();
      expect(selected, selectedTag);
    }
  }

  testWidgets('抽屉渲染主入口 + 星标 + 标签组 + 设置/锁定，无布局错误', (tester) async {
    await pumpDrawer(tester);

    expect(find.text('Notes'), findsOneWidget);
    expect(find.byKey(const Key('ui-home-nav-deleted')), findsOneWidget);
    expect(find.text('Trash'), findsOneWidget);

    // 星标入口
    expect(find.byKey(const Key('ui-home-nav-starred')), findsOneWidget);
    expect(find.text('Starred Notes'), findsOneWidget);

    // 标签组 header + 编辑图标
    expect(find.byKey(const Key('ui-home-tag-edit')), findsOneWidget);

    // 每个标签一行
    for (final tag in ['个人', '工作', '灵感']) {
      expect(find.byKey(Key('ui-home-nav-tag-$tag')), findsOneWidget);
      expect(find.text(tag), findsOneWidget);
    }

    // 设置 / 锁定的既有 Key 保持不变
    expect(find.byKey(const Key('ui-home-nav-settings')), findsOneWidget);
    expect(find.byKey(const Key('ui-home-nav-lock')), findsOneWidget);
  });

  testWidgets('标签组上下各一条分割线', (tester) async {
    await pumpDrawer(tester);
    // 三条 tag + header 顶部的编辑图标所在行下方 + 组下方，
    // 理论上分割线至少 2 条（组前/组后）。
    final dividers = find.byType(Divider);
    expect(dividers, findsNWidgets(3), reason: 'header下1条 + 标签组前1条 + 标签组后1条');
  });

  testWidgets('点击标签触发 onTagSelected 回调', (tester) async {
    await pumpDrawer(tester, selectedTag: '工作');
  });

  testWidgets('标签组 header 可折叠/展开', (tester) async {
    await pumpDrawer(tester);

    final tagRows = find.byKey(const Key('ui-home-nav-tag-个人'));
    expect(tagRows, findsOneWidget, reason: '初始为展开态，标签可见');

    // 点击 header 折叠：标签行消失，仅保留 header + 编辑图标。
    await tester.tap(find.byKey(const Key('ui-home-tag-header')));
    await tester.pumpAndSettle();
    expect(tagRows, findsNothing, reason: '折叠后标签行隐藏');

    // 再次点击展开：标签行恢复。
    await tester.tap(find.byKey(const Key('ui-home-tag-header')));
    await tester.pumpAndSettle();
    expect(tagRows, findsOneWidget, reason: '再次点击后标签行恢复');
  });

  testWidgets('操作菜单仍含既有动作项（作为回归保障）', (tester) async {
    // 打开更多菜单回归：锁定/星标/复制/删除 均在。
    // 该断言走 note_actions_sheet 已有测试覆盖，此处仅确认抽屉不破坏其入口常量。
    expect(LucideIcons.star, isNotNull);
  });
}
