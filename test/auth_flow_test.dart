/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

// 认证流程集成测试
//
// 驱动真实 App（AuthWall → 登录 / 首次设置密码），覆盖三条主路径：
//   1. 首次运行：设置密码 hello.1111 → 进入主界面
//   2. 已有保险库：用 hello.1111 登录 → 主界面显示已 seed 的笔记
//   3. 错误密码：停留在登录页并提示
//
// 复用 test_helpers 的真实 Keyring + 真实 SQLite（落在系统临时目录，用例间隔离）。
//
// 环境：initFullEnv 已关闭光标闪烁（EditableText.debugDeterministicCursor），
// 登录/设置密码页的软键盘滚动动画可正常收敛，全程用 pumpAndSettle。

import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'test_helpers.dart';

const String kTestPassword = 'hello.1111';
const String kSeedNoteTitle = 'Integration Test Note 1';
const String kSeedNoteBody = 'Body of the integration test note.';

void main() {
  setUpAll(() async {
    await initFullEnv();
  });

  tearDown(() async {
    await disposeVault();
  });

  group('认证主流程', () {
    testWidgets('首次运行：设置密码 hello.1111 后进入主界面', (WidgetTester tester) async {
      await prepareEmptyVault();
      await pumpApp(tester);

      // 首次运行应落在「设置密码」页
      expect(find.text('Set Passphrase'), findsOneWidget);
      // 两个密码输入框（新密码 + 确认）
      expect(find.byType(ShadInputFormField), findsNWidgets(2));

      // 输入一致密码
      await tester.enterText(
        find.byType(ShadInputFormField).at(0),
        kTestPassword,
      );
      await tester.enterText(
        find.byType(ShadInputFormField).at(1),
        kTestPassword,
      );
      await tester.pump();

      // 点击 Confirm（keyring 派生 ~300ms + 转场）。
      // 日志 HTTP 服务器已在 initFullEnv 中关闭（不绑定 HttpServer），故此处
      // 不会留下周期性 idle-timeout Timer，pumpAndSettle 可正常收敛。
      await tester.tap(find.widgetWithText(ShadButton, 'Confirm'));
      await tester.pumpAndSettle();

      // 应进入主界面（主屏在 ≥600px 视口下 AppBar 与 HomeSidebar 都会出现
      expect(find.text('CarroNote'), findsAtLeastNWidgets(1));
      // 设置密码页已不在
      expect(find.text('Set Passphrase'), findsNothing);
    }, timeout: const Timeout(Duration(seconds: 90)));

    testWidgets(
      '已有保险库：用 hello.1111 登录后主界面显示已 seed 的笔记',
      (WidgetTester tester) async {
        await prepareUnlockedVault(
          password: kTestPassword,
          seeds: const [(title: kSeedNoteTitle, description: kSeedNoteBody)],
        );
        await pumpApp(tester);

        // 已初始化保险库应落在登录页
        expect(find.widgetWithText(ShadButton, 'Login'), findsOneWidget);

        // 输入密码并登录
        await tester.enterText(find.byType(ShadInputFormField), kTestPassword);
        await tester.pump();
        await tester.tap(find.widgetWithText(ShadButton, 'Login'));
        await tester.pumpAndSettle();

        // 进入主界面且 seed 的笔记可见（主屏 AppBar 与 HomeSidebar 都会渲染
        expect(find.text('CarroNote'), findsAtLeastNWidgets(1));
        expect(find.text(kSeedNoteTitle), findsOneWidget);
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    testWidgets('错误密码：停留在登录页并提示', (WidgetTester tester) async {
      await prepareUnlockedVault(password: kTestPassword);
      await pumpApp(tester);

      expect(find.widgetWithText(ShadButton, 'Login'), findsOneWidget);

      await tester.enterText(find.byType(ShadInputFormField), 'wrong-pass-999');
      await tester.pump();
      await tester.tap(find.widgetWithText(ShadButton, 'Login'));
      // 错误路径不派生 keyring，但仍有 snackbar 提示动画
      await tester.pumpAndSettle();

      // 仍在登录页（Login 按钮与 Passphrase 输入框标签仍在）
      expect(find.widgetWithText(ShadButton, 'Login'), findsOneWidget);
      expect(find.text('Passphrase'), findsOneWidget);
      // 错误提示出现
      expect(find.textContaining('Wrong passphrase'), findsWidgets);
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
