/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

/*
* First-run smoke test: simulate a fresh install (empty data dir) by pointing
* the app's data dir at a dedicated empty folder, then:
*   1. create the vault (enter the passphrase twice on the setup screen),
*   2. land on the home screen,
*   3. create 5 random notes,
*   4. verify all 5 are present,
*   5. exit.
*
* This reproduces the "flutter test uninstalled the app, data is empty" case
* so we can confirm the app initializes cleanly from an empty DB.
*
* Run: flutter test integration_test/first_run_test.dart -d windows
*/
// Dart imports:
import 'dart:io' show Directory, Platform;

// Flutter imports:
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// Project imports:
import 'package:core/core.dart' show AppLog, AppLogLevel;
import 'package:safenotes/main.dart' as safenotes;

/// 空库测试专用的隔离数据目录（相对项目 cwd，绝对路径解析）。
const String _dataDir = 'temp/first_run_test_data';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final sep = Platform.pathSeparator;

  // 指向一个专用的空目录，确保从真正的空库开始（模拟卸载后全空）。
  // 先删除旧残留，保证每次都是全新空库。
  final dataDirAbs = '${Directory.current.path}$sep$_dataDir';
  final dir = Directory(dataDirAbs);
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);
  safenotes.dataDirOverride = dataDirAbs;

  testWidgets('first run: empty vault -> create 5 notes -> verify -> exit', (
    WidgetTester tester,
  ) async {
    // ── 1. 启动 app，走首启建档流程 ──
    await safenotes.main();
    AppLog.setLevel(AppLogLevel.error);
    await _waitForFirstScreen(tester);

    // 建档页：正好两个密码输入框（passphrase + 确认）。
    final fields = find.byType(EditableText);
    expect(fields, findsNWidgets(2), reason: '应在建档页（两个密码框）');
    await tester.enterText(fields.at(0), 'hello.1111');
    await tester.enterText(fields.at(1), 'hello.1111');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('setupConfirmButton')));
    await tester.pumpAndSettle();

    // ── 2. 进入主界面 ──
    await _waitFor(
      tester,
      () => tester.any(find.byKey(const Key('ui-home-screen'))),
    );
    expect(
      find.byKey(const Key('ui-home-screen')),
      findsOneWidget,
      reason: '建档后应进入主界面',
    );

    // ── 3. 随机添加 5 条笔记 ──
    final titles = <String>[];
    for (var i = 0; i < 5; i++) {
      final title = 'IT 首启笔记 ${DateTime.now().millisecondsSinceEpoch}_$i';
      titles.add(title);
      await _createNote(tester, title, '首启空库流程 body $i');
    }

    // ── 4. 验证 5 条笔记都在 ──
    await _backToHome(tester);
    await _waitFor(tester, () => _countNotes(tester) >= 5);
    final count = _countNotes(tester);
    expect(count, greaterThanOrEqualTo(5), reason: '应至少 5 条笔记，实际 $count');

    // ── 5. 退出：回到 home，测试结束（tearDown 关闭 app）──
    await _backToHome(tester);
  });
}

/// 等待首个界面出现（建档页两个密码框，或登录页）。
Future<void> _waitForFirstScreen(WidgetTester tester) async {
  const maxAttempts = 100; // ~10s at 100ms per pump
  for (var i = 0; i < maxAttempts; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (tester.any(find.byKey(const Key('passphraseInput')))) return;
    if (tester.widgetList(find.byType(EditableText)).length == 2) return;
  }
  await tester.pumpAndSettle();
}

/// 轮询等待 [condition] 成立（异步纯计算不触发帧，pumpAndSettle 会提前返回）。
Future<void> _waitFor(WidgetTester tester, bool Function() condition) async {
  const maxAttempts = 150; // ~15s at 100ms per pump
  for (var i = 0; i < maxAttempts; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (condition()) return;
  }
  await tester.pumpAndSettle();
}

/// 从主界面新建一条笔记。
Future<void> _createNote(WidgetTester tester, String title, String body) async {
  await _backToHome(tester);
  expect(
    find.byKey(const Key('ui-home-fab-newnote')),
    findsOneWidget,
    reason: '_createNote 应从主界面开始（FAB 存在）',
  );
  await tester.pump(const Duration(seconds: 8)); // 让残留 toast 消退
  await tester.tap(
    find.byKey(const Key('ui-home-fab-newnote')),
    warnIfMissed: false,
  );
  await tester.pumpAndSettle();
  if (!tester.any(find.byKey(const Key('ui-note-screen')))) {
    await tester.tap(
      find.byKey(const Key('ui-home-fab-newnote')),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
  }
  await _waitFor(
    tester,
    () => tester.any(find.byKey(const Key('ui-note-field-title'))),
  );

  await tester.enterText(find.byKey(const Key('ui-note-field-title')), title);
  await tester.enterText(find.byKey(const Key('ui-note-field-body')), body);
  await tester.pumpAndSettle();

  await tester.ensureVisible(find.byKey(const Key('ui-note-button-save')));
  await tester.tap(find.byKey(const Key('ui-note-button-save')));
  await _waitFor(tester, () => tester.any(find.text(title)));
}

/// 统计主界面当前笔记卡片数（按 keyed index）。
int _countNotes(WidgetTester tester) {
  var n = 0;
  while (tester.any(find.byKey(Key('ui-home-note-$n')))) {
    n++;
  }
  return n;
}

/// 弹出路由直到回到主界面。
Future<void> _backToHome(WidgetTester tester) async {
  while (true) {
    if (tester.any(find.byKey(const Key('ui-home-screen')))) break;
    if (tester.any(find.byKey(const Key('passphraseInput')))) break;
    final element = tester.element(find.byType(Scaffold).first);
    Navigator.of(element, rootNavigator: true).pop();
    await tester.pumpAndSettle();
  }
}
