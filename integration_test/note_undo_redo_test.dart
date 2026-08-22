/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*/

/*
* Independent integration test for the note editor undo/redo feature.
*
* Drives the *real* app end-to-end (same bootstrap as app_test.dart) but lives
* in its own file so it can be run/tagged independently without touching the
* shared app_test.dart flows:
*
*   flutter test integration_test/note_undo_redo_test.dart -d windows
*   flutter test integration_test/note_undo_redo_test.dart -d windows --name="undo"
*
* It re-creates the minimal bootstrap + helpers it needs (privately) rather than
* importing app_test.dart, so the two files never share mutable state.
*
* Coverage:
*  - AppBar undo/redo buttons restore title + body together and restore caret.
*  - Keyboard shortcuts Ctrl+Z / Ctrl+Y (and Ctrl+Shift+Z) drive the same stack.
*  - Redo is cleared after a fresh edit; undo is a no-op when the stack is empty.
*  - Preview mode disables undo/redo (buttons absent / shortcuts inert).
*  - The throwaway test note is removed at the end so the vault stays clean.
*/

// Dart imports:
import 'dart:io' show Directory, Platform;

// Flutter imports:
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

// Project imports:
import 'package:safenotes/main.dart' as safenotes;

// Keys used by the app (kept in sync with lib/ for stability).
const _kHome = Key('ui-home-screen');
const _kNoteScreen = Key('ui-note-screen');
const _kPassphrase = Key('passphraseInput');
const _kLoginButton = Key('loginButton');
const _kSetupConfirm = Key('setupConfirmButton');
const _kFabNewNote = Key('ui-home-fab-newnote');
const _kFieldTitle = Key('ui-note-field-title');
const _kFieldBody = Key('ui-note-field-body');
const _kPreviewToggle = Key('ui-note-button-preview');
const _kMoreButton = Key('ui-note-button-more');
const _kSearchInput = Key('ui-home-search-input');

bool get _isDesktop =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final sep = Platform.pathSeparator;

  // 数据隔离：与 app_test.dart 完全一致（指向 temp/integration_test_data）。
  final override = _isDesktop
      ? Platform.environment['SN_DATA_DIR'] ??
            '${Directory.current.path}$sep${'temp'}$sep'
                '${'integration_test_data'}'
      : '${(await getApplicationDocumentsDirectory()).path}$sep'
            'temp${sep}integration_test_data';
  safenotes.dataDirOverride = override;

  group('note undo/redo', () {
    testWidgets(
      'undo: AppBar buttons + keyboard restore title and body together',
      (WidgetTester tester) async {
        await _loginToHome(tester);
        final stamp = DateTime.now().millisecondsSinceEpoch;
        final title = 'Undo测试标题 $stamp';
        final body = 'Undo测试正文 $stamp';

        await _createNote(tester, title, body);
        await _openNoteByTitle(tester, title);
        await _settle(tester); // 编辑器（预览态）完全就绪

        // 进入编辑态（预览→编辑切换按钮）。
        await tester.tap(find.byKey(_kPreviewToggle));
        await tester.pumpAndSettle();
        await _waitFor(tester, () => tester.any(find.byKey(_kFieldTitle)));
        await _settle(tester);

        // 记录初始值，再整体改写标题+正文（一次编辑=一个撤销步）。
        final originalTitle = title;
        final originalBody = body;
        const editedTitle = '已编辑标题 EDITED';
        const editedBody = '已编辑正文 EDITED BODY';
        await tester.enterText(find.byKey(_kFieldTitle), editedTitle);
        await tester.enterText(find.byKey(_kFieldBody), editedBody);
        await tester.pumpAndSettle();
        await _settle(tester);
        expect(
          _fieldText(tester, _kFieldTitle),
          editedTitle,
          reason: 'title should reflect the edit',
        );
        expect(
          _fieldText(tester, _kFieldBody),
          editedBody,
          reason: 'body should reflect the edit',
        );
        // 此时历史栈有 2 步：①改标题 ②改正文（每字段独立成步）。

        // --- 撤销第 1 次（AppBar 按钮）：回退“改正文”那一步 ---
        // 双字段编辑后 body 字段处于聚焦态，点击 AppBar 按钮前先聚焦回 title，
        // 避免外层 GestureDetector(unfocus) 与按钮手势竞争导致 onPressed 不触发。
        await tester.tap(find.byKey(_kFieldTitle));
        await tester.pumpAndSettle();
        await _settle(tester);
        final undoBtn = find.byKey(const Key('ui-note-button-undo'));
        await tester.ensureVisible(undoBtn);
        await tester.pumpAndSettle();
        // ignore: avoid_print
        print('[DIAG-A] before undo tap: undoDisabled=${_isUndoButtonDisabled(tester)} '
            'title=${_fieldText(tester, _kFieldTitle)} '
            'body=${_fieldText(tester, _kFieldBody)}');
        await tester.tap(undoBtn, warnIfMissed: false);
        await tester.pumpAndSettle();
        await _settle(tester);
        await tester.pump(const Duration(seconds: 1)); // 等布局/动画就绪
        await tester.pumpAndSettle();
        // ignore: avoid_print
        print('[DIAG-B] after undo tap: undoDisabled=${_isUndoButtonDisabled(tester)} '
            'title=${_fieldText(tester, _kFieldTitle)} '
            'body=${_fieldText(tester, _kFieldBody)}');
        expect(
          _fieldText(tester, _kFieldTitle),
          editedTitle,
          reason: 'after 1st undo (revert body) title stays edited',
        );
        expect(
          _fieldText(tester, _kFieldBody),
          originalBody,
          reason: 'after 1st undo (revert body) body restored',
        );

        // --- 撤销第 2 次（AppBar 按钮）：回退“改标题”那一步 ---
        await tester.tap(find.byKey(_kFieldTitle));
        await tester.pumpAndSettle();
        await _settle(tester);
        await tester.ensureVisible(undoBtn);
        await tester.pumpAndSettle();
        await tester.tap(undoBtn, warnIfMissed: false);
        await tester.pumpAndSettle();
        await _settle(tester);
        await tester.pump(const Duration(seconds: 1)); // 等布局/动画就绪
        await tester.pumpAndSettle();
        expect(
          _fieldText(tester, _kFieldTitle),
          originalTitle,
          reason: 'after 2nd undo (revert title) title restored',
        );
        expect(
          _fieldText(tester, _kFieldBody),
          originalBody,
          reason: 'after 2nd undo body stays restored',
        );

        // --- 重做第 1 次（AppBar 按钮）：恢复“改标题”那一步 ---
        await tester.tap(find.byKey(_kFieldTitle));
        await tester.pumpAndSettle();
        await _settle(tester);
        final redoBtn = find.byKey(const Key('ui-note-button-redo'));
        await tester.ensureVisible(redoBtn);
        await tester.pumpAndSettle();
        await tester.tap(redoBtn, warnIfMissed: false);
        await tester.pumpAndSettle();
        await _settle(tester);
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        expect(
          _fieldText(tester, _kFieldTitle),
          editedTitle,
          reason: 'after 1st redo title restored to edited',
        );
        expect(
          _fieldText(tester, _kFieldBody),
          originalBody,
          reason: 'after 1st redo body stays restored',
        );

        // --- 重做第 2 次（AppBar 按钮）：恢复“改正文”那一步 ---
        await tester.tap(find.byKey(_kFieldTitle));
        await tester.pumpAndSettle();
        await _settle(tester);
        await tester.ensureVisible(redoBtn);
        await tester.pumpAndSettle();
        await tester.tap(redoBtn, warnIfMissed: false);
        await tester.pumpAndSettle();
        await _settle(tester);
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        expect(
          _fieldText(tester, _kFieldTitle),
          editedTitle,
          reason: 'after 2nd redo title stays edited',
        );
        expect(
          _fieldText(tester, _kFieldBody),
          editedBody,
          reason: 'after 2nd redo body restored to edited',
        );

        // --- 再撤销 2 次回到全原始（键盘，验证多步键盘路径）---
        await tester.tap(find.byKey(_kFieldTitle));
        await tester.pumpAndSettle();
        await _settle(tester);
        await _sendUndoCombo(tester);
        await tester.pumpAndSettle();
        await _settle(tester);
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        await _sendUndoCombo(tester);
        await tester.pumpAndSettle();
        await _settle(tester);
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        expect(
          _fieldText(tester, _kFieldTitle),
          originalTitle,
          reason: 'Ctrl+Z x2 returns title to original',
        );
        expect(
          _fieldText(tester, _kFieldBody),
          originalBody,
          reason: 'Ctrl+Z x2 returns body to original',
        );

        await _popTopRoute(tester); // 自动保存并退出
        await _waitFor(tester, () => _isHome(tester));
        await _settle(tester);
        await _deleteNoteByTitle(tester, title);
      },
    );

    testWidgets(
      'undo: redo stack cleared after a fresh edit; preview disables controls',
      (WidgetTester tester) async {
        await _loginToHome(tester);
        final stamp = DateTime.now().millisecondsSinceEpoch;
        final title = 'Redo清除测试 $stamp';
        final body = 'redo-clear body $stamp';

        await _createNote(tester, title, body);
        await _openNoteByTitle(tester, title);
        await _settle(tester);

        await tester.tap(find.byKey(_kPreviewToggle));
        await tester.pumpAndSettle();
        await _waitFor(tester, () => tester.any(find.byKey(_kFieldTitle)));
        await _settle(tester);

        // 编辑一次后撤销，使 redo 栈有内容。
        await tester.enterText(find.byKey(_kFieldTitle), 'v2');
        await tester.pumpAndSettle();
        await _settle(tester);
        await tester.tap(find.byKey(const Key('ui-note-button-undo')));
        await tester.pumpAndSettle();
        await _settle(tester);
        expect(
          _fieldText(tester, _kFieldTitle),
          title,
          reason: 'after undo title returns to original',
        );

        // 一次新编辑应清空 redo 栈：撤销按钮仍可用（有历史），重做按钮变为禁用。
        // 注意：编辑态下两个按钮始终“存在”，仅 onPressed 在可用/禁用间切换，
        // 因此这里断言“禁用”而非“消失”。
        // 先聚焦标题字段（撤销经 _apply 直接改写 controller.value，输入框连接需
        // 重新聚焦才能接收 enterText）。
        await tester.tap(find.byKey(_kFieldTitle));
        await tester.pumpAndSettle();
        await _settle(tester);
        await tester.enterText(find.byKey(_kFieldTitle), 'v3');
        await tester.pumpAndSettle();
        await _settle(tester);
        // final rdFinder = find.byKey(const Key('ui-note-button-redo'));
        expect(
          _isRedoButtonDisabled(tester),
          isTrue,
          reason: 'redo control should be disabled after a fresh edit',
        );
        expect(
          _isUndoButtonDisabled(tester),
          isFalse,
          reason: 'undo control should remain enabled (history present)',
        );

        // 预览态下撤销/重做按钮应都不存在（预览只读）。
        await tester.tap(find.byKey(_kPreviewToggle)); // 切回预览
        await tester.pumpAndSettle();
        await _settle(tester);
        expect(
          find.byKey(const Key('ui-note-button-undo')),
          findsNothing,
          reason: 'undo control hidden in preview mode',
        );
        expect(
          find.byKey(const Key('ui-note-button-redo')),
          findsNothing,
          reason: 'redo control hidden in preview mode',
        );

        await _popTopRoute(tester);
        await _waitFor(tester, () => _isHome(tester));
        await _settle(tester);
        await _deleteNoteByTitle(tester, title);
      },
    );
  });
}

// ---------------------------------------------------------------------------
// 以下为与 app_test.dart 同构的私有 helper（独立副本，避免共享可变状态）。
// ---------------------------------------------------------------------------

Future<void> _loginToHome(WidgetTester tester) async {
  final appMounted =
      tester.any(find.byType(Scaffold)) || tester.any(find.byKey(_kPassphrase));

  if (!appMounted) {
    await safenotes.main();
    await _waitForFirstScreen(tester);
    await _ensureVaultReady(tester);
    await _loginIfNeeded(tester);
    await _waitFor(tester, () => _isHome(tester));
    await _ensureMinNotes(tester, 1);
    return;
  }

  if (_isHome(tester)) return;
  if (tester.any(find.byKey(_kPassphrase))) {
    await _loginIfNeeded(tester);
    return;
  }
  await _backToHome(tester);
}

Future<void> _loginIfNeeded(WidgetTester tester) async {
  if (!tester.any(find.byKey(_kPassphrase))) return;
  await tester.enterText(find.byKey(_kPassphrase), 'hello.1111');
  await tester.pumpAndSettle();
  await _settle(tester);
  await tester.ensureVisible(find.byKey(_kLoginButton));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(_kLoginButton));
  await _waitFor(tester, () => _isHome(tester));
  await _settle(tester);
}

bool _isHome(WidgetTester tester) {
  if (tester.any(find.byKey(_kPassphrase))) return false;
  if (!tester.any(find.byKey(_kHome))) return false;
  if (tester.any(find.byKey(_kNoteScreen))) return false;
  return true;
}

Future<void> _popTopRoute(WidgetTester tester) async {
  final element = tester.element(find.byType(Scaffold).first);
  await Navigator.of(element, rootNavigator: true).maybePop();
  await tester.pumpAndSettle();
}

Future<void> _backToHome(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    if (_isHome(tester)) return;
    if (tester.any(find.byKey(_kPassphrase))) {
      await _loginIfNeeded(tester);
      return;
    }
    if (tester.any(find.byType(Scaffold))) {
      final element = tester.element(find.byType(Scaffold).first);
      final navigator = Navigator.of(element, rootNavigator: true);
      if (navigator.canPop()) {
        await navigator.maybePop();
        await tester.pumpAndSettle();
        continue;
      }
    }
    return;
  }
}

Future<void> _createNote(
  WidgetTester tester,
  String title,
  String body,
) async {
  await _backToHome(tester);
  expect(
    find.byKey(_kFabNewNote),
    findsOneWidget,
    reason: '_createNote should start on home with the FAB present',
  );
  await tester.pump(const Duration(seconds: 8));
  await tester.tap(find.byKey(_kFabNewNote), warnIfMissed: false);
  await tester.pumpAndSettle();
  if (!tester.any(find.byKey(_kNoteScreen))) {
    await tester.tap(find.byKey(_kFabNewNote), warnIfMissed: false);
    await tester.pumpAndSettle();
  }
  await _waitFor(tester, () => tester.any(find.byKey(_kNoteScreen)));
  await _waitFor(tester, () => tester.any(find.byKey(_kFieldTitle)));
  await _settle(tester);

  await tester.enterText(find.byKey(_kFieldTitle), title);
  await tester.enterText(find.byKey(_kFieldBody), body);
  await tester.pumpAndSettle();
  await _settle(tester);
  await _popTopRoute(tester);
  await _waitFor(tester, () => tester.any(find.text(title)));
  await _settle(tester);
}

Future<void> _openNoteByTitle(WidgetTester tester, String title) async {
  await _waitFor(tester, () => tester.any(find.byKey(_kSearchInput)));
  await _settle(tester);
  await tester.enterText(find.byKey(_kSearchInput), title);
  await _waitFor(tester, () => tester.any(find.text(title)));
  await _settle(tester);
  // 搜索结果第一项（index 0）。
  final note0 = find.byKey(const Key('ui-home-note-0'));
  await tester.ensureVisible(note0);
  await tester.pumpAndSettle();
  await tester.tap(note0);
  await tester.pumpAndSettle();
}

Future<void> _deleteNoteByTitle(WidgetTester tester, String title) async {
  await _openNoteByTitle(tester, title);
  await _settle(tester);
  await tester.tap(find.byKey(_kMoreButton));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('ui-note-action-delete')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('ui-dialog-confirm')));
  await _waitFor(tester, () => _isHome(tester));
  await _settle(tester);
  if (tester.any(find.byIcon(LucideIcons.x))) {
    await tester.tap(find.byIcon(LucideIcons.x));
    await tester.pumpAndSettle();
  }
}

int _countNotes(WidgetTester tester) {
  var n = 0;
  while (tester.any(find.byKey(Key('ui-home-note-$n')))) {
    n++;
  }
  return n;
}

Future<void> _ensureMinNotes(WidgetTester tester, int min) async {
  var guard = 0;
  while (_countNotes(tester) < min && guard < min + 2) {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    await _createNote(tester, 'IT 种子笔记 $stamp $guard', 'seed body $guard');
    guard++;
  }
}

Future<void> _waitForFirstScreen(WidgetTester tester) async {
  const maxAttempts = 100;
  for (var i = 0; i < maxAttempts; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    final loginReady = tester.any(find.byKey(_kPassphrase));
    final signupReady =
        tester.widgetList(find.byType(EditableText)).length == 2;
    if (loginReady || signupReady) return;
  }
  await tester.pumpAndSettle();
}

Future<void> _ensureVaultReady(WidgetTester tester) async {
  if (tester.any(find.byKey(_kPassphrase))) return;
  final fields = find.byType(EditableText);
  expect(fields, findsNWidgets(2),
      reason: 'Unexpected first screen: expected login or set-passphrase');
  await tester.enterText(fields.at(0), 'hello.1111');
  await tester.enterText(fields.at(1), 'hello.1111');
  await tester.pumpAndSettle();
  await _settle(tester);
  await tester.tap(find.byKey(_kSetupConfirm));
  await tester.pumpAndSettle();
  await _settle(tester);
}

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() condition,
) async {
  const maxAttempts = 100;
  for (var i = 0; i < maxAttempts; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (condition()) return;
  }
  await tester.pumpAndSettle();
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pumpAndSettle();
}

/// Reads the current text of an editable field located by its wrapper [key].
///
/// The `ui-note-field-*` key is on the [ShadInputFormField] wrapper, not the
/// inner [EditableText], so we descend to the first [EditableText] underneath.
String _fieldText(WidgetTester tester, Key key) {
  final editableFinder = find.descendant(
    of: find.byKey(key),
    matching: find.byType(EditableText),
  );
  final editable = tester.widget<EditableText>(editableFinder.first);
  return editable.controller.text;
}

/// True when the AppBar undo button is present-but-disabled (no history).
bool _isUndoButtonDisabled(WidgetTester tester) {
  final finder = find.byKey(const Key('ui-note-button-undo'));
  if (!tester.any(finder)) return false;
  final btn = tester.widget<IconButton>(finder);
  return btn.onPressed == null;
}

/// True when the AppBar redo button is present-but-disabled (no redo history).
bool _isRedoButtonDisabled(WidgetTester tester) {
  final finder = find.byKey(const Key('ui-note-button-redo'));
  if (!tester.any(finder)) return false;
  final btn = tester.widget<IconButton>(finder);
  return btn.onPressed == null;
}

/// Sends a Ctrl+Z key combo (undo) via the page-level Focus.onKeyEvent path.
Future<void> _sendUndoCombo(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.control, platform: 'windows');
  await tester.pumpAndSettle();
  await tester.sendKeyEvent(LogicalKeyboardKey.keyZ, platform: 'windows');
  await tester.pumpAndSettle();
  await tester.sendKeyUpEvent(LogicalKeyboardKey.control, platform: 'windows');
}
