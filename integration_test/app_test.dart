/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

/*
* Integration tests for SafeNotes.
*
* Drives the *real* app (same bootstrap as a normal launch) end-to-end.
* The app is launched once and stays resident across all tests; each test
* starts from the home screen (logging in on first run).
*
* Run on the desktop runner (Windows in this environment):
*   flutter test integration_test/app_test.dart -d windows
*
* Or on Android / iOS after connecting a device:
*   flutter test integration_test/app_test.dart -d <device>
*
* Platform notes:
* - Desktop (Windows/macOS/Linux): data dir is isolated to
*   temp/integration_test_data (a snapshot copied from the debug build) and
*   each flow runs under the two viewports in [_viewports] via setSurfaceSize.
* - Real devices (Android/iOS): no data-dir override and no viewport resizing;
*   the tests run once at the device's natural size and use the device's own
*   data (first run creates the vault with the passphrase below).
*
* The vault must already be initialized with the passphrase "hello.1111"
* (tests log in with it). If the app was never set up on this machine, the
* test automatically creates the vault with that passphrase first.
*
* Widgets are located by Key / Icon / type (locale-independent) rather than
* by localized text, so the tests are stable regardless of the device
* language. Keys follow a "ui-<screen>-<type>-<name>" convention so they
* read at a glance and never collide with app keys.
*/

// Dart imports:
import 'dart:io' show Directory, Platform;

// Flutter imports:
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

// Project imports:
import 'package:core/core.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:safenotes/main.dart' as safenotes;
import 'package:safenotes/models/pin_auth.dart';
import 'package:safenotes/utils/desktop_window.dart'
    show kAppWindowInitialSize, getWindowSize, setWindowPosition, setWindowSize;
import 'package:safenotes/widgets/pin_keyboard.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// 命名视口表。`null` 表示「原始默认窗口大小」（不特意 setSurfaceSize，直接用
/// runner 启动时的默认尺寸），其余为逻辑尺寸（单位 dp）。
///
/// Windows 上默认两组：原始默认 size + compact（窄屏，最容易暴露 overflow）。
/// 想覆盖更多尺寸，直接在这里加一行即可；所有用到 [_forEachViewport] 的测试
/// 会自动在新增尺寸下各跑一遍，无需改动各条 flow。
///
/// 仅桌面平台使用（[_forEachViewport] 在真机上不遍历视口，按设备自然尺寸跑）。
///
/// 换算：逻辑尺寸 = 物理像素 / (dpi / 160)。例如真机 2670x1200 @480dpi
/// => density 3.0 => 890x400 dp，可加：'phone-land-890x400': Size(890, 400),
const Map<String, Size?> _viewports = {
  'default-size': null, // 原始默认窗口大小，不特意设定
  'compact-port-400x890': Size(400, 890), // 窄屏手机，竖屏
  'compact-land-890x400': Size(890, 400), // 窄屏手机，横屏
};

/// 设置 Hub 7 个顶级 tile 的 key（主题与显示已提升为一级入口）。
const List<String> _hubTileKeys = <String>[
  'ui-setting-hub-theme',
  'ui-setting-hub-display',
  'ui-setting-hub-sync',
  'ui-setting-hub-backup',
  'ui-setting-hub-security',
  'ui-setting-hub-general',
  'ui-setting-hub-about',
];

// ignore: unused_element
/// Hub 内二级页 leaf tile 映射（用于遍历二级页不崩溃校验，专项用例覆盖时可参考）。
const Map<String, List<String>> _hubLeafKeys = {
  'ui-setting-hub-theme': [
    'ui-setting-item-darkmode',
    'ui-setting-item-themecolor',
    'ui-setting-item-notescolor',
  ],
  'ui-setting-hub-display': [
    'ui-setting-item-fontsettings',
    'ui-setting-switch-compact',
    'ui-setting-switch-markdown',
    'ui-setting-item-notestyle',
    'ui-setting-switch-relativetime',
  ],
  'ui-setting-hub-sync': ['ui-setting-switch-sync', 'ui-sync-config-tile'],
  'ui-setting-hub-backup': [
    'ui-setting-item-exportbackup',
    'ui-setting-item-importbackup',
  ],
  'ui-setting-hub-security': [
    'ui-setting-item-biometric',
    'ui-setting-item-pin',
    'ui-setting-item-inactivity',
    'ui-setting-item-changepassphrase',
  ],
  'ui-setting-hub-general': ['ui-setting-item-language'],
  'ui-setting-hub-about': [],
};

Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final sep = Platform.pathSeparator;

  // 数据隔离：默认把 App 数据目录指向隔离目录，避免污染真实数据。
  // 必须在 safenotes.main() 之前设置（用绝对路径，避免 cwd 漂移产生嵌套目录）。
  // - 桌面：temp/integration_test_data（复用一次性复制的快照，不删不建）。
  // - 真机：设备沙箱 <documents>/temp/integration_test_data；app 启动时会把
  //   设备真实的 safenotes_sync.db 复制到该目录并从副本打开（见 main.dart），
  //   测试不污染设备真实数据。
  // 可用环境变量 SN_DATA_DIR 覆盖（桌面）。
  final override = _isDesktop
      ? Platform.environment['SN_DATA_DIR'] ??
            '${Directory.current.path}$sep${'temp'}$sep'
                '${'integration_test_data'}'
      : '${(await getApplicationDocumentsDirectory()).path}$sep'
            'temp${sep}integration_test_data';
  safenotes.dataDirOverride = override;

  group('SafeNotes flows', () {
    testWidgets(
      'note: open 2nd note, toggle preview/edit, create a new note across window sizes',
      (WidgetTester tester) async {
        await _loginToHome(tester);
        // Make sure there is a 2nd note to open (seed dummy notes if needed).
        await _ensureMinNotes(tester, 2);

        const fixedTitle = '集成测试固定标题 IntegrationTest';
        const fixedBody = '集成测试固定文本 IntegrationTest body content.';

        await _forEachViewport(tester, (tester, size) async {
          // --- Open the 2nd note (index 1) ---
          final noteFinder = find.byKey(const Key('ui-home-note-1'));
          await tester.ensureVisible(noteFinder);
          await tester.tap(noteFinder);
          await tester.pumpAndSettle();
          // Existing notes open in preview mode: title shown as SelectableText.
          expect(
            find.byType(SelectableText),
            findsWidgets,
            reason: 'Expected the note opened in preview mode @ $size',
          );

          // --- Toggle to edit, then back to preview ---
          await tester.tap(find.byKey(const Key('ui-note-button-preview')));
          await tester.pumpAndSettle();
          // Edit mode exposes the title + body editable fields.
          expect(
            tester.widgetList(find.byType(EditableText)).length,
            greaterThanOrEqualTo(2),
            reason: 'Expected edit mode with title + body fields @ $size',
          );
          await tester.tap(find.byKey(const Key('ui-note-button-preview')));
          await tester.pumpAndSettle();
          expect(
            find.byType(SelectableText),
            findsWidgets,
            reason: 'Expected to have toggled back to preview mode @ $size',
          );

          // --- Return to home ---
          await _popTopRoute(tester);
          expect(_isHome(tester), isTrue, reason: 'Expected home @ $size');

          // --- Create a new note with fixed title/body ---
          await _createNote(tester, fixedTitle, fixedBody);

          // --- Confirm the new note exists on home ---
          await _waitFor(tester, () => tester.any(find.text(fixedTitle)));
          expect(
            find.text(fixedTitle),
            findsWidgets,
            reason: 'Expected the newly created note to appear on home @ $size',
          );
        });
      },
    );

    testWidgets(
      'settings: visit every sub-page without crashing / overflow across window sizes',
      (WidgetTester tester) async {
        await _loginToHome(tester);

        await _forEachViewport(tester, (tester, size) async {
          await _openSettings(tester);
          // Hub 已拆为 7 顶级入口（主题/显示为一级标题），不再直接展示 darkmode 等叶节点。
          expect(
            find.byKey(const Key('ui-setting-hub-theme')),
            findsOneWidget,
            reason: 'Expected to be on the settings hub @ $size',
          );
          expect(
            find.byKey(const Key('ui-settings-screen')),
            findsOneWidget,
            reason: 'Expected settings hub screen @ $size',
          );

          // 遍历每个 Hub 入口，进入二级页后校验不崩溃即返回 Hub。
          // 二级页内的叶节点由其它专项用例覆盖，此处仅校验 Hub→二级 的导航链路。
          for (final hubKey in _hubTileKeys) {
            final hubFinder = find.byKey(Key(hubKey));
            await tester.scrollUntilVisible(
              hubFinder,
              200.0,
              scrollable: find.byType(Scrollable).first,
            );
            await tester.pumpAndSettle();
            await tester.tap(hubFinder);
            await tester.pumpAndSettle();

            expect(
              find.byType(ErrorWidget),
              findsNothing,
              reason: 'ErrorWidget on hub $hubKey @ $size',
            );
            expect(
              tester.takeException(),
              isNull,
              reason: 'Crash / overflow on hub $hubKey @ $size',
            );

            await _popTopRoute(tester);
            await tester.pumpAndSettle();
            expect(
              find.byKey(const Key('ui-settings-screen')),
              findsOneWidget,
              reason: 'Should return to hub after $hubKey @ $size',
            );
          }
        });
      },
    );

    testWidgets(
      'auth: lock via sidebar/drawer then re-login across window sizes',
      (WidgetTester tester) async {
        await _loginToHome(tester);

        await _forEachViewport(tester, (tester, size) async {
          // Lock lands us back on the login page.
          await _openNavEntry(tester, const Key('ui-home-nav-lock'));
          await _waitFor(
            tester,
            () => tester.any(find.byKey(const Key('passphraseInput'))),
          );
          expect(
            find.byKey(const Key('passphraseInput')),
            findsOneWidget,
            reason: 'Lock should land on the login screen @ $size',
          );

          // Re-login returns to home.
          await _loginIfNeeded(tester);
          expect(_isHome(tester), isTrue, reason: 'Expected home @ $size');
        });
      },
    );

    testWidgets('auth: passphrase visibility toggle on the login screen', (
      WidgetTester tester,
    ) async {
      await _loginToHome(tester);
      // Lock to reach the login page.
      await _openNavEntry(tester, const Key('ui-home-nav-lock'));
      await _waitFor(
        tester,
        () => tester.any(find.byKey(const Key('passphraseInput'))),
      );

      EditableText editable() => tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const Key('passphraseInput')),
          matching: find.byType(EditableText),
        ),
      );

      // Hidden by default.
      expect(editable().obscureText, isTrue);
      // Reveal via the trailing eye button.
      await tester.tap(find.byIcon(LucideIcons.eye));
      await tester.pumpAndSettle();
      expect(editable().obscureText, isFalse);
      // Hide again.
      await tester.tap(find.byIcon(LucideIcons.eyeOff));
      await tester.pumpAndSettle();
      expect(editable().obscureText, isTrue);

      // Log back in (field stays empty) for the next test.
      await _loginIfNeeded(tester);
      expect(_isHome(tester), isTrue);
    });

    testWidgets(
      'pin: Use passphrase must not cover the PIN keypad across window sizes',
      (WidgetTester tester) async {
        await _loginToHome(tester);
        // 直接写 PIN 凭据(已登录,getPass 可用),省去设置页 UI 流程。
        await PinAuth.setPin('123456');
        try {
          for (final entry in _viewports.entries) {
            final target = entry.value ?? kAppWindowInitialSize;
            await setWindowSize(target);
            await tester.pumpAndSettle();

            // 锁定回登录页 → PIN 覆盖层自动弹出(PinUnlockPanel)。
            await _openNavEntry(tester, const Key('ui-home-nav-lock'));
            await _waitFor(tester, () => tester.any(find.byType(PinKeyboard)));

            // 取键盘与「Use passphrase」按钮矩形,断言互不覆盖。
            final keypad = find.byType(PinKeyboard);
            final usePass = find.byKey(const Key('ui-pin-use-passphrase'));
            await tester.ensureVisible(usePass);
            await tester.pumpAndSettle();
            final kbRect = tester.getRect(keypad);
            final btnRect = tester.getRect(usePass);
            expect(
              kbRect.overlaps(btnRect),
              isFalse,
              reason:
                  'Use passphrase must not cover the PIN keypad '
                  '(keypad=$kbRect, btn=$btnRect) @ ${entry.key}',
            );

            // 关闭覆盖层 → 用主密码回 home,为下一尺寸准备。
            await tester.tap(usePass, warnIfMissed: false);
            await tester.pumpAndSettle();
            await _loginIfNeeded(tester);
            await _backToHome(tester);
          }
          await setWindowSize(kAppWindowInitialSize);
        } finally {
          // 清理:PIN 破坏性影响后续测试,无论成败都关闭。
          await PinAuth.disable();
        }
      },
      timeout: const Timeout(Duration(minutes: 4)),
    );

    testWidgets(
      'home: search filters notes and shows the no-result empty state',
      (WidgetTester tester) async {
        await _loginToHome(tester);

        // Throwaway notes with unique titles make the match deterministic
        // regardless of pre-existing notes; they are cleaned up at the end.
        const tgt = 'ZZZHomeFilterTgt';
        const other = 'ZZZHomeFilterOther';
        await _createNote(tester, tgt, 'body $tgt');
        await _createNote(tester, other, 'body $other');
        try {
          await _forEachViewport(tester, (tester, size) async {
            // A term matching only the target filters the other note out.
            await tester.enterText(
              find.byKey(const Key('ui-home-search-input')),
              tgt,
            );
            await _waitFor(tester, () => !tester.any(find.text(other)));
            expect(
              find.text(tgt),
              findsWidgets,
              reason: 'matching note should remain @ $size',
            );
            expect(
              find.text(other),
              findsNothing,
              reason: 'non-matching note should be filtered out @ $size',
            );

            // A term matching nothing shows the no-result empty state.
            await tester.enterText(
              find.byKey(const Key('ui-home-search-input')),
              'zzz-no-such-note',
            );
            await _waitFor(
              tester,
              () => tester.any(find.byIcon(LucideIcons.searchX)),
            );
            expect(
              find.byIcon(LucideIcons.searchX),
              findsOneWidget,
              reason: 'no-result empty state icon @ $size',
            );
            expect(
              find.text(tgt),
              findsNothing,
              reason: 'no notes shown on no-result empty state @ $size',
            );

            // Clear via the search box clearing icon restores the full list.
            await tester.tap(find.byIcon(LucideIcons.x));
            await _waitFor(tester, () => tester.any(find.text(tgt)));
            expect(
              find.text(tgt),
              findsWidgets,
              reason: 'full list restored after clearing search @ $size',
            );
          });
        } finally {
          await _deleteNoteByTitle(tester, tgt);
          await _deleteNoteByTitle(tester, other);
        }
      },
    );

    testWidgets('home: toggle grid/list layout without crash', (
      WidgetTester tester,
    ) async {
      await _loginToHome(tester);
      await _ensureMinNotes(tester, 2);

      await _forEachViewport(tester, (tester, size) async {
        IconButton layoutBtn() => tester.widget<IconButton>(
          find.byKey(const Key('ui-home-toolbar-layout')),
        );
        final firstIcon = (layoutBtn().icon as Icon).icon;

        await tester.tap(find.byKey(const Key('ui-home-toolbar-layout')));
        await tester.pumpAndSettle();
        expect(
          (layoutBtn().icon as Icon).icon,
          isNot(firstIcon),
          reason: 'layout toggle should flip the button icon @ $size',
        );
        expect(tester.takeException(), isNull, reason: 'overflow @ $size');

        // Toggle back to restore the original layout.
        await tester.tap(find.byKey(const Key('ui-home-toolbar-layout')));
        await tester.pumpAndSettle();
        expect(
          (layoutBtn().icon as Icon).icon,
          firstIcon,
          reason: 'layout toggle should toggle back @ $size',
        );
      });
    });

    testWidgets('home: sort menu popover opens with all preference toggles', (
      WidgetTester tester,
    ) async {
      await _loginToHome(tester);
      await _ensureMinNotes(tester, 2);

      await _forEachViewport(tester, (tester, size) async {
        // 点击排序 icon 应弹出「排序/显示偏好」下拉菜单（不再翻转 icon）。
        await tester.tap(find.byKey(const Key('ui-home-toolbar-sort')));
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason: 'popover overflow @ $size',
        );
        for (final key in const [
          'ui-home-menu-newfirst',
          'ui-home-menu-sortmodified',
          'ui-home-menu-relativetime',
          'ui-home-menu-compact',
          'ui-home-menu-colorful',
          'ui-home-menu-starredonly',
        ]) {
          expect(
            find.byKey(Key(key)),
            findsOneWidget,
            reason: 'popover 缺少菜单项 $key @ $size',
          );
        }

        // 再次点击收起 popover，回到干净的主界面。
        await tester.tap(find.byKey(const Key('ui-home-toolbar-sort')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('ui-home-menu-newfirst')),
          findsNothing,
          reason: '再次点击应关闭 popover @ $size',
        );
      });
    });

    testWidgets('note: edit an existing note and save the changes', (
      WidgetTester tester,
    ) async {
      await _loginToHome(tester);
      const title = 'ZZZEditTgt';
      await _createNote(tester, title, 'original body');
      try {
        await _openNoteByTitle(tester, title);
        // Switch to edit mode and change the body.
        await tester.tap(find.byKey(const Key('ui-note-button-preview')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('ui-note-field-body')),
          'edited body',
        );
        await tester.pumpAndSettle();
        // 自动保存：退出编辑页时保存
        await _popTopRoute(tester);
        await _waitFor(tester, () => _isHome(tester));

        // Re-open and verify the edited body persisted.
        await _openNoteByTitle(tester, title);
        expect(
          find.text('edited body'),
          findsWidgets,
          reason: 'edited body should persist',
        );
        await _popTopRoute(tester);
        await _waitFor(tester, () => _isHome(tester));
      } finally {
        await _deleteNoteByTitle(tester, title);
      }
    });

    testWidgets('note: delete moves a note out of the home list', (
      WidgetTester tester,
    ) async {
      await _loginToHome(tester);
      const title = 'ZZZDelTgt';
      await _createNote(tester, title, 'body');
      try {
        await _openNoteByTitle(tester, title);
        await _tapEditorDelete(tester);
        await tester.tap(find.byKey(const Key('ui-dialog-confirm')));
        await _waitFor(tester, () => _isHome(tester));
        // Clear the leftover search query (its text still matches the title).
        if (tester.any(find.byIcon(LucideIcons.x))) {
          await tester.tap(find.byIcon(LucideIcons.x));
          await tester.pumpAndSettle();
        }
        await _waitFor(tester, () => !tester.any(find.text(title)));
        expect(
          find.text(title),
          findsNothing,
          reason: 'deleted note should be gone from home',
        );
      } finally {
        // Soft-deleted note now lives in the recycle bin; group D clears it.
      }
    });

    testWidgets('note: unsaved changes are auto-saved on exit (no dialog)', (
      WidgetTester tester,
    ) async {
      // 笔记页改为退出时自动保存（PopScope canPop:false 拦截 → 自动保存），
      // 不再弹「取消/丢弃/保存」三选一对话框。此用例校验：编辑后直接退出，
      // 改动被自动落库，重新打开仍能看到最新内容。
      await _loginToHome(tester);
      const title = 'ZZZAutoSave';
      await _createNote(tester, title, 'orig body');
      try {
        await _openNoteByTitle(tester, title);
        // 切到编辑态并修改正文。
        await tester.tap(find.byKey(const Key('ui-note-button-preview')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('ui-note-field-body')),
          'autosaved body',
        );
        await tester.pumpAndSettle();
        // 直接退出（不点任何保存按钮）→ 触发自动保存。
        await _popTopRoute(tester);
        await _waitFor(tester, () => _isHome(tester));
        // 重新打开校验改动已持久化。
        await _openNoteByTitle(tester, title);
        expect(
          find.text('autosaved body'),
          findsWidgets,
          reason: 'unsaved edit should be auto-saved on exit',
        );
        await _popTopRoute(tester);
        await _waitFor(tester, () => _isHome(tester));
      } finally {
        await _deleteNoteByTitle(tester, title);
      }
    });

    testWidgets('note: markdown renders in the preview when enabled', (
      WidgetTester tester,
    ) async {
      await _loginToHome(tester);
      const title = 'ZZZMarkdown';
      // Enable Markdown preview via settings, then restore it afterwards.
      await _toggleMarkdown(tester);
      try {
        await _createNote(tester, title, '# Heading\n**bold** text');
        await _openNoteByTitle(tester, title);
        expect(
          find.byType(MarkdownBody),
          findsWidgets,
          reason: 'MarkdownBody should render when markdown is enabled',
        );
        await _popTopRoute(tester);
        await _waitFor(tester, () => _isHome(tester));
      } finally {
        await _deleteNoteByTitle(tester, title);
        await _toggleMarkdown(tester); // restore markdown off
      }
    });

    testWidgets('trash: recycle bin page renders (empty state)', (
      WidgetTester tester,
    ) async {
      await _loginToHome(tester);
      await _clearAllTrash(tester);
      await _openNavEntry(tester, const Key('ui-home-nav-deleted'));
      // Empty state shows the trash icon; no Clear All button.
      expect(find.byIcon(LucideIcons.trash2), findsWidgets);
      expect(find.byKey(const Key('ui-deleted-clearall')), findsNothing);
      expect(tester.takeException(), isNull);
      await _popTopRoute(tester);
      await _waitFor(tester, () => _isHome(tester));
    });

    testWidgets('trash: restore a single note returns it to home', (
      WidgetTester tester,
    ) async {
      await _loginToHome(tester);
      await _clearAllTrash(tester);
      const title = 'ZZZRestore';
      await _createNote(tester, title, 'body');
      await _deleteNoteByTitle(tester, title); // into the recycle bin
      try {
        await _openNavEntry(tester, const Key('ui-home-nav-deleted'));
        await tester.tap(find.byIcon(LucideIcons.moreVertical));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('ui-deleted-menu-restore')));
        await _waitFor(tester, () => !tester.any(find.text(title)));

        // Back to home and confirm the note is back.
        await _popTopRoute(tester);
        await _waitFor(tester, () => _isHome(tester));
        await _openNoteByTitle(tester, title);
        expect(find.text(title), findsWidgets);
        // Return home before cleanup (the editor is open right now).
        await _popTopRoute(tester);
        await _waitFor(tester, () => _isHome(tester));
      } finally {
        // Delete it again (back to trash; the clear-all test empties it).
        await _deleteNoteByTitle(tester, title);
      }
    });

    testWidgets('trash: permanently delete a single note', (
      WidgetTester tester,
    ) async {
      await _loginToHome(tester);
      await _clearAllTrash(tester);
      const title = 'ZZZPermDel';
      await _createNote(tester, title, 'body');
      await _deleteNoteByTitle(tester, title); // into the recycle bin
      try {
        await _openNavEntry(tester, const Key('ui-home-nav-deleted'));
        await tester.tap(find.byIcon(LucideIcons.moreVertical));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('ui-deleted-menu-permdelete')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('ui-dialog-confirm')));
        await _waitFor(tester, () => !tester.any(find.text(title)));

        // Gone from trash and from home (permanently deleted).
        await _popTopRoute(tester);
        await _waitFor(tester, () => _isHome(tester));
        expect(find.text(title), findsNothing);
      } finally {
        // The note is permanently gone; nothing to clean up.
      }
    });

    testWidgets('trash: clear all empties the recycle bin', (
      WidgetTester tester,
    ) async {
      await _loginToHome(tester);
      await _clearAllTrash(tester);
      for (final t in const ['ZZZClear1', 'ZZZClear2']) {
        await _createNote(tester, t, 'body');
        await _deleteNoteByTitle(tester, t);
      }
      try {
        await _openNavEntry(tester, const Key('ui-home-nav-deleted'));
        expect(find.byKey(const Key('ui-deleted-clearall')), findsOneWidget);
        await tester.tap(find.byKey(const Key('ui-deleted-clearall')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('ui-dialog-confirm')));
        await _waitFor(
          tester,
          () => !tester.any(find.byKey(const Key('ui-deleted-clearall'))),
        );
        // Empty state shown again.
        expect(find.byIcon(LucideIcons.trash2), findsWidgets);
        await _popTopRoute(tester);
        await _waitFor(tester, () => _isHome(tester));
      } finally {
        // Trash is empty; nothing to clean up.
      }
    });

    testWidgets(
      'backup: export dialog renders and validates a matching password',
      (WidgetTester tester) async {
        await _loginToHome(tester);
        await _openSettings(tester);
        // Hub: 进入 Backup 二级页（同步与备份已拆为顶级入口）
        await tester.scrollUntilVisible(
          find.byKey(const Key('ui-setting-hub-backup')),
          200.0,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('ui-setting-hub-backup')));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byKey(const Key('ui-setting-item-exportbackup')),
          200.0,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('ui-setting-item-exportbackup')));
        await tester.pumpAndSettle();

        // Panel open: password + confirm fields present.
        expect(find.byKey(const Key('ui-export-password')), findsOneWidget);
        expect(find.byKey(const Key('ui-export-confirm')), findsOneWidget);

        // The Export button is the only disabled ShadButton while the password
        // is empty/mismatched; it becomes enabled once the passwords match.
        bool exportDisabled() => tester.any(
          find.byWidgetPredicate((w) => w is ShadButton && w.enabled == false),
        );

        // No password yet -> Export disabled.
        expect(exportDisabled(), isTrue);

        // Mismatched passwords keep Export disabled.
        await tester.enterText(
          find.byKey(const Key('ui-export-password')),
          'abc',
        );
        await tester.enterText(
          find.byKey(const Key('ui-export-confirm')),
          'def',
        );
        await tester.pumpAndSettle();
        expect(exportDisabled(), isTrue);

        // Matching passwords enable Export.
        await tester.enterText(
          find.byKey(const Key('ui-export-confirm')),
          'abc',
        );
        await tester.pumpAndSettle();
        expect(exportDisabled(), isFalse);

        // Cancel (pop the dialog) closes the panel back to backup page.
        await _popTopRoute(tester);
        await tester.pumpAndSettle();
        // 回到 Backup 页后返回 Hub，再回 Home
        await _popTopRoute(tester);
        await _waitFor(
          tester,
          () => tester.any(find.byKey(const Key('ui-settings-screen'))),
        );
        await _popTopRoute(tester);
        await _waitFor(tester, () => _isHome(tester));
      },
    );

    testWidgets('backup: import confirmation dialog can be cancelled', (
      WidgetTester tester,
    ) async {
      await _loginToHome(tester);
      await _openSettings(tester);
      await tester.scrollUntilVisible(
        find.byKey(const Key('ui-setting-hub-backup')),
        200.0,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ui-setting-hub-backup')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('ui-setting-item-importbackup')),
        200.0,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ui-setting-item-importbackup')));
      await tester.pumpAndSettle();

      // Confirmation dialog appears; cancel it (no file picker is triggered).
      expect(find.byKey(const Key('ui-dialog-cancel')), findsOneWidget);
      await tester.tap(find.byKey(const Key('ui-dialog-cancel')));
      await tester.pumpAndSettle();
      // 仍在 Backup 二级页
      expect(
        find.byKey(const Key('ui-setting-item-importbackup')),
        findsOneWidget,
      );

      // 返回 Hub 再回 Home
      await _popTopRoute(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ui-settings-screen')), findsOneWidget);

      await _popTopRoute(tester);
      await _waitFor(tester, () => _isHome(tester));
    });

    testWidgets('settings: dark mode bottom sheet toggles without crash', (
      WidgetTester tester,
    ) async {
      await _loginToHome(tester);
      await _openSettings(tester);
      // 进入 Theme 二级页（主题已提升为一级入口）
      await tester.scrollUntilVisible(
        find.byKey(const Key('ui-setting-hub-theme')),
        200.0,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ui-setting-hub-theme')));
      await tester.pumpAndSettle();
      // The dark-mode tile opens a bottom sheet.
      await _toggleSettingSwitch(tester, const Key('ui-setting-item-darkmode'));
      expect(find.byKey(const Key('ui-theme-switch-dark')), findsOneWidget);

      // Toggle the dark-mode switch and back (restores the original state).
      await _toggleSettingSwitch(tester, const Key('ui-theme-switch-dark'));
      await _toggleSettingSwitch(tester, const Key('ui-theme-switch-dark'));
      expect(tester.takeException(), isNull);

      await _popTopRoute(tester); // close the sheet
      await tester.pumpAndSettle();
      // 返回 Hub
      await _popTopRoute(tester);
      await _waitFor(
        tester,
        () => tester.any(find.byKey(const Key('ui-settings-screen'))),
      );
      await _popTopRoute(tester); // back home
      await _waitFor(tester, () => _isHome(tester));
    });

    testWidgets('settings: notes color switch toggles without crash', (
      WidgetTester tester,
    ) async {
      await _loginToHome(tester);
      await _openSettings(tester);
      await tester.scrollUntilVisible(
        find.byKey(const Key('ui-setting-hub-theme')),
        200.0,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ui-setting-hub-theme')));
      await tester.pumpAndSettle();
      await _toggleSettingSwitch(
        tester,
        const Key('ui-setting-item-notescolor'),
      );
      expect(find.byKey(const Key('ui-notescolor-switch')), findsOneWidget);

      await _toggleSettingSwitch(tester, const Key('ui-notescolor-switch'));
      await _toggleSettingSwitch(tester, const Key('ui-notescolor-switch'));
      expect(tester.takeException(), isNull);

      await _popTopRoute(tester); // back to appearance
      await tester.pumpAndSettle();
      await _popTopRoute(tester); // back to hub
      await _waitFor(
        tester,
        () => tester.any(find.byKey(const Key('ui-settings-screen'))),
      );
      await _popTopRoute(tester); // back home
      await _waitFor(tester, () => _isHome(tester));
    });

    testWidgets('settings: change passphrase page renders without changing', (
      WidgetTester tester,
    ) async {
      await _loginToHome(tester);
      await _openSettings(tester);
      await tester.scrollUntilVisible(
        find.byKey(const Key('ui-setting-hub-security')),
        200.0,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ui-setting-hub-security')));
      await tester.pumpAndSettle();
      await _toggleSettingSwitch(
        tester,
        const Key('ui-setting-item-changepassphrase'),
      );
      // Page renders with at least the old/new/confirm passphrase fields.
      expect(
        tester.widgetList(find.byType(EditableText)).length,
        greaterThanOrEqualTo(3),
        reason: 'change passphrase should show 3 password fields',
      );
      expect(tester.takeException(), isNull);

      await _popTopRoute(tester); // back to security page
      await tester.pumpAndSettle();
      await _popTopRoute(tester); // back to hub
      await _waitFor(
        tester,
        () => tester.any(find.byKey(const Key('ui-settings-screen'))),
      );
      await _popTopRoute(tester); // back home
      await _waitFor(tester, () => _isHome(tester));
    });

    testWidgets('settings: preference switches toggle and restore', (
      WidgetTester tester,
    ) async {
      await _loginToHome(tester);
      await _openSettings(tester);
      // 进入 Display 二级页操作紧凑/相对时间开关（已从 Appearance 提升）
      await tester.scrollUntilVisible(
        find.byKey(const Key('ui-setting-hub-display')),
        200.0,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ui-setting-hub-display')));
      await tester.pumpAndSettle();

      await _toggleSettingSwitch(
        tester,
        const Key('ui-setting-switch-compact'),
      );
      await _toggleSettingSwitch(
        tester,
        const Key('ui-setting-switch-compact'),
      );
      await _toggleSettingSwitch(
        tester,
        const Key('ui-setting-switch-relativetime'),
      );
      await _toggleSettingSwitch(
        tester,
        const Key('ui-setting-switch-relativetime'),
      );
      expect(tester.takeException(), isNull);

      await _popTopRoute(tester); // back to hub
      await tester.pumpAndSettle();
      await _popTopRoute(tester); // back home
      await _waitFor(tester, () => _isHome(tester));
    });

    testWidgets('sync: sync settings page renders', (
      WidgetTester tester,
    ) async {
      await _loginToHome(tester);
      await _openSettings(tester);
      await tester.scrollUntilVisible(
        find.byKey(const Key('ui-setting-hub-sync')),
        200.0,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ui-setting-hub-sync')));
      await tester.pumpAndSettle();

      // The sync settings page renders its tiles (sync switch, config tile).
      expect(find.byKey(const Key('ui-setting-switch-sync')), findsOneWidget);
      expect(find.byKey(const Key('ui-sync-config-tile')), findsOneWidget);
      expect(tester.takeException(), isNull);

      await _popTopRoute(tester); // back to hub
      await _waitFor(
        tester,
        () => tester.any(find.byKey(const Key('ui-settings-screen'))),
      );
      await _popTopRoute(tester); // back home
      await _waitFor(tester, () => _isHome(tester));
    });

    testWidgets('sync: backend config panel opens and switches type', (
      WidgetTester tester,
    ) async {
      await _loginToHome(tester);
      await _openSettings(tester);
      await tester.scrollUntilVisible(
        find.byKey(const Key('ui-setting-hub-sync')),
        200.0,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ui-setting-hub-sync')));
      await tester.pumpAndSettle();

      // Open the backend config panel (a dialog on desktop).
      await tester.tap(find.byKey(const Key('ui-sync-config-tile')));
      await tester.pumpAndSettle();
      expect(find.text('WebDAV'), findsWidgets);
      expect(find.text('SafeServer'), findsWidgets);

      // Switch to SafeServer: its section title now appears twice (selector
      // row + section header). The backend behind is WebDAV, so SafeServer
      // only occurs inside the panel, making the count deterministic.
      await tester.tap(find.text('SafeServer').first);
      await tester.pumpAndSettle();
      expect(find.text('SafeServer'), findsNWidgets(2));
      expect(tester.takeException(), isNull);

      // Close the panel (back to sync settings), then back home.
      await _popTopRoute(tester);
      await tester.pumpAndSettle();
      await _backToHome(tester);
    });

    testWidgets('scroll: settings page scrolls to bottom and back to top', (
      WidgetTester tester,
    ) async {
      await _loginToHome(tester);
      await _openSettings(tester);
      final scrollable = find.byType(Scrollable).first;

      // Hub 已缩短为 6 项，About 仍在底部；校验 Hub 滚动不溢出
      await tester.scrollUntilVisible(
        find.byKey(const Key('ui-setting-hub-about')),
        300.0,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ui-setting-hub-about')), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Scroll back up to the first hub tile（主题为首项）.
      await tester.scrollUntilVisible(
        find.byKey(const Key('ui-setting-hub-theme')),
        -300.0,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ui-setting-hub-theme')), findsOneWidget);
      expect(tester.takeException(), isNull);

      await _popTopRoute(tester);
      await _waitFor(tester, () => _isHome(tester));
    });

    testWidgets('scroll: home notes list scrolls down and back to top', (
      WidgetTester tester,
    ) async {
      await _loginToHome(tester);
      await _ensureMinNotes(tester, 15);

      // Desktop has two Scrollables (sidebar + notes); notes is the last.
      // Compact has only one.
      final scrollables = find.byType(Scrollable);
      final noteScrollable = scrollables.last;

      // A far note is off-screen initially; scroll it into view.
      await tester.scrollUntilVisible(
        find.byKey(const Key('ui-home-note-9')),
        200.0,
        scrollable: noteScrollable,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ui-home-note-9')), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Scroll back to the top (note 0).
      await tester.scrollUntilVisible(
        find.byKey(const Key('ui-home-note-0')),
        -200.0,
        scrollable: noteScrollable,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ui-home-note-0')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

/// Logs in (or reuses an already-running, logged-in app) and lands on home.
///
/// The integration_test runner disposes the widget tree between tests, so if
/// the app is no longer mounted we re-launch [safenotes.main] and log in. Once
/// the app is up, subsequent calls just make sure we are on the home screen
/// (popping back from wherever the previous test left off).
Future<void> _loginToHome(WidgetTester tester) async {
  final appMounted =
      tester.any(find.byType(Scaffold)) ||
      tester.any(find.byKey(const Key('passphraseInput')));

  if (!appMounted) {
    await safenotes.main();
    // 压噪：集成测试只需在出错时看日志，把输出级别提到 error。
    AppLog.setLevel(AppLogLevel.error);
    await _waitForFirstScreen(tester);
    await _ensureVaultReady(tester);
    await _loginIfNeeded(tester);
    // 空库容错：flutter test 可能卸载/重装 app 导致数据目录被清空，首次建档后
    // 先确保稳定在主界面，再补足种子笔记，保证后续用例有数据可用。
    await _waitFor(tester, () => _isHome(tester));
    await _ensureMinNotes(tester, 3);
    // Disable sync once (backend unreachable in the test env) so background
    // syncs don't destabilize unrelated tests.
    await _disableSync(tester);
    return;
  }

  if (_isHome(tester)) return;
  if (tester.any(find.byKey(const Key('passphraseInput')))) {
    await _loginIfNeeded(tester);
    return;
  }
  await _backToHome(tester);
}

/// Logs in only when the login screen is shown.
Future<void> _loginIfNeeded(WidgetTester tester) async {
  if (!tester.any(find.byKey(const Key('passphraseInput')))) return;

  expect(
    find.byKey(const Key('passphraseInput')),
    findsOneWidget,
    reason: 'Expected to be on the login screen',
  );
  await tester.enterText(
    find.byKey(const Key('passphraseInput')),
    'hello.1111',
  );
  await tester.pumpAndSettle();
  await _settle(tester); // 输入完成后再点登录

  // 矮横屏（如 compact-land-890x400）下登录按钮可能在表单滚动区视口外，
  // 先滚动到可见再点，否则 tap 落空导致登录不触发、_isHome 断言失败。
  await tester.ensureVisible(find.byKey(const Key('loginButton')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('loginButton')));
  // Login is async (argon2 keyring unlock, ~1-2s of pure compute that
  // schedules no frames), so pumpAndSettle can return before navigation to
  // home finishes. Wait for the home screen explicitly.
  await _waitFor(tester, () => _isHome(tester));
  await _settle(tester); // 登录后主界面稳定
}

/// True when the home screen is the current (top) route.
///
/// Detection is purely key-based (no [Icons.add] guesswork — the FAB uses
/// [LucideIcons.plus]). Home is the base route, so it stays mounted underneath
/// any pushed page (e.g. the note page opened via an OpenContainer, or the
/// settings page via pushNamed). We therefore require the home root key to be
/// present *and* every other top-level screen root key to be absent — that is
/// what distinguishes "looking at home" from "home mounted underneath a pushed
/// page".
bool _isHome(WidgetTester tester) {
  if (tester.any(find.byKey(const Key('passphraseInput')))) return false;
  if (!tester.any(find.byKey(const Key('ui-home-screen')))) return false;
  for (final other in const [
    Key('ui-note-screen'),
    Key('ui-settings-screen'),
    Key('ui-deleted-screen'),
  ]) {
    if (tester.any(find.byKey(other))) return false;
  }
  return true;
}

/// Pops the top-most route (pushed page, bottom sheet, or dialog) on the root
/// navigator and lets the frame settle.
Future<void> _popTopRoute(WidgetTester tester) async {
  final element = tester.element(find.byType(Scaffold).first);
  // 必须用 maybePop 而非 pop：笔记页用 PopScope(canPop:false) 拦截退出并
  // 自动保存，pop() 会强制关闭路由、绕过自动保存导致内容丢失；maybePop 才会
  // 触发 onPopInvoked(didPop:false) → 自动保存 → 真正关闭。
  await Navigator.of(element, rootNavigator: true).maybePop();
  await tester.pumpAndSettle();
}

/// Pops routes until the home screen is reached (or login is shown, in which
/// case it logs back in).
Future<void> _backToHome(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    if (_isHome(tester)) return;
    if (tester.any(find.byKey(const Key('passphraseInput')))) {
      await _loginIfNeeded(tester);
      return;
    }
    if (tester.any(find.byType(Scaffold))) {
      final element = tester.element(find.byType(Scaffold).first);
      final navigator = Navigator.of(element, rootNavigator: true);
      if (navigator.canPop()) {
        // 同 _popTopRoute：用 maybePop 尊重 PopScope 的自动保存拦截。
        await navigator.maybePop();
        await tester.pumpAndSettle();
        continue;
      }
    }
    return; // nothing left to pop
  }
}

/// Creates a note via the FAB: opens the editor, enters title/body, saves,
/// and waits for it to appear back on home.
Future<void> _createNote(WidgetTester tester, String title, String body) async {
  // Ensure we are on home (a prior helper may have left a route open).
  await _backToHome(tester);
  expect(
    find.byKey(const Key('ui-home-fab-newnote')),
    findsOneWidget,
    reason: '_createNote should start on home with the FAB present',
  );
  // Let any lingering toast/snackbar (e.g. from a prior clear-all) auto-dismiss
  // so it does not obscure the FAB. Error toasts last 6s.
  await tester.pump(const Duration(seconds: 8));
  await tester.tap(
    find.byKey(const Key('ui-home-fab-newnote')),
    warnIfMissed: false,
  );
  await tester.pumpAndSettle();
  // If the tap missed, retry once.
  if (!tester.any(find.byKey(const Key('ui-note-screen')))) {
    await tester.tap(
      find.byKey(const Key('ui-home-fab-newnote')),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
  }
  // Wait for the editor and its fields to be ready before typing.
  await _waitFor(
    tester,
    () => tester.any(find.byKey(const Key('ui-note-screen'))),
  );
  await _waitFor(
    tester,
    () => tester.any(find.byKey(const Key('ui-note-field-title'))),
  );
  await _settle(tester); // 编辑器完全就绪后再输入

  await tester.enterText(find.byKey(const Key('ui-note-field-title')), title);
  await tester.enterText(find.byKey(const Key('ui-note-field-body')), body);
  await tester.pumpAndSettle();
  await _settle(tester);
  // 自动保存：退出编辑页时保存（无保存按钮）
  await _popTopRoute(tester);
  // Save is async (DB write) then closes the page; wait for the note to show.
  await _waitFor(tester, () => tester.any(find.text(title)));
  await _settle(tester); // 保存后返回 home 的转场动画走完，避免卡在半透明过渡态
}

/// Opens an existing note by its (unique) title: searches the exact title
/// (narrows the home list to that single note) then taps it, landing on the
/// editor in preview mode. The search query is left in place.
Future<void> _openNoteByTitle(WidgetTester tester, String title) async {
  // 从笔记页 pop 回 home 有一个过渡期，搜索框可能尚未挂载；先等它就绪，
  // 再稳定等待避免 enterText 对尚未出现的输入框抛 "No element"（偶发时序抖动）。
  await _waitFor(
    tester,
    () => tester.any(find.byKey(const Key('ui-home-search-input'))),
  );
  await _settle(tester);
  await tester.enterText(find.byKey(const Key('ui-home-search-input')), title);
  await _waitFor(tester, () => tester.any(find.text(title)));
  await _settle(tester);
  await tester.tap(find.byKey(const Key('ui-home-note-0')));
  await tester.pumpAndSettle(); // open the editor (preview mode)
}

/// 在编辑页触发删除：AppBar 只留预览与保存，删除已收进「更多」底部菜单，
/// 因此要先开 sheet 再点删除项。返回时停在删除确认弹框上（尚未确认）。
Future<void> _tapEditorDelete(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('ui-note-button-more')));
  await tester.pumpAndSettle(); // 底部操作 sheet 打开
  await tester.tap(find.byKey(const Key('ui-note-action-delete')));
  await tester.pumpAndSettle(); // sheet 关闭 + 弹出删除确认框
}

/// Deletes an existing note by its (unique) title, cleaning up the DB.
///
/// Used after tests that create throwaway notes so the note count does not
/// keep growing across runs. Steps: open the note -> tap delete in the editor
/// -> confirm the destructive dialog -> return home and clear the leftover
/// search query.
Future<void> _deleteNoteByTitle(WidgetTester tester, String title) async {
  await _openNoteByTitle(tester, title);
  await _settle(tester); // 编辑器（预览态）完全就绪后再点删除

  await _tapEditorDelete(tester);
  await _settle(tester); // 确认弹框动画走完

  await tester.tap(find.byKey(const Key('ui-dialog-confirm')));
  await _waitFor(tester, () => _isHome(tester));
  await _settle(tester); // 删除后返回 home 稳定

  // Clear the leftover search query so the next test sees the full list.
  if (tester.any(find.byIcon(LucideIcons.x))) {
    await tester.tap(find.byIcon(LucideIcons.x));
    await tester.pumpAndSettle();
  }
}

/// Counts the note cards currently present on home (by their keyed index).
int _countNotes(WidgetTester tester) {
  var n = 0;
  while (tester.any(find.byKey(Key('ui-home-note-$n')))) {
    n++;
  }
  return n;
}

/// Ensures at least [min] notes exist (seeds random notes if the vault is empty
/// or has too few). Keeps the note test deterministic regardless of prior state
/// (e.g. flutter test uninstalling the app and clearing its data).
Future<void> _ensureMinNotes(WidgetTester tester, int min) async {
  var guard = 0;
  while (_countNotes(tester) < min && guard < min + 2) {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    await _createNote(tester, 'IT 种子笔记 $stamp $guard', 'seed body $guard');
    guard++;
  }
}

/// Pumps frames until the first screen is rendered.
///
/// The first screen is either the login screen (a single passphrase field
/// with [Key('passphraseInput')]) or the first-run "set passphrase" screen
/// (two editable fields). Polls for a few seconds so we don't race the
/// async bootstrap in [safenotes.main].
Future<void> _waitForFirstScreen(WidgetTester tester) async {
  const maxAttempts = 100; // ~10s at 100ms per pump
  for (var i = 0; i < maxAttempts; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    final bool loginReady = tester.any(
      find.byKey(const Key('passphraseInput')),
    );
    final bool signupReady =
        tester.widgetList(find.byType(EditableText)).length == 2;
    if (loginReady || signupReady) return;
  }
  // Fall back to a settle in case the screen appeared between pumps.
  await tester.pumpAndSettle();
}

/// Pumps frames until [condition] is true (or a timeout elapses).
///
/// Used for steps whose completion is driven by async work that does not
/// schedule frames (e.g. the argon2 keyring unlock during login), where a
/// plain [WidgetTester.pumpAndSettle] would return too early.
Future<void> _waitFor(WidgetTester tester, bool Function() condition) async {
  const maxAttempts = 100; // ~10s at 100ms per pump
  for (var i = 0; i < maxAttempts; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (condition()) return;
  }
  await tester.pumpAndSettle();
}

/// 操作前的稳定等待：条件就绪后，再等待短暂时间让界面过渡动画/后台异步完全
/// 走完，避免立刻点击导致「界面未渲染完、后台逻辑未走完」的偶发失败（真机上
/// 尤其明显）。用法：`await _waitFor(...); await _settle(tester);`
Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pumpAndSettle();
}

/// Ensures the login screen is reachable.
///
/// On a fresh install the app starts on the "set passphrase" screen instead
/// of the login screen. In that case we create the vault with the known
/// passphrase so the rest of the flow can proceed.
Future<void> _ensureVaultReady(WidgetTester tester) async {
  // Already on the login screen -> nothing to do.
  if (tester.any(find.byKey(const Key('passphraseInput')))) return;

  // Otherwise assume the first-run "set passphrase" screen, which has exactly
  // two editable fields (passphrase + confirmation).
  final fields = find.byType(EditableText);
  expect(
    fields,
    findsNWidgets(2),
    reason: 'Unexpected first screen: expected login or set-passphrase',
  );

  await tester.enterText(fields.at(0), 'hello.1111');
  await tester.enterText(fields.at(1), 'hello.1111');
  await tester.pumpAndSettle();
  await _settle(tester); // 输入完成后再点确认

  await tester.tap(find.byKey(const Key('setupConfirmButton')));
  await tester.pumpAndSettle();
  await _settle(tester); // 建档完成进入主界面稳定
}

/// Opens the Settings screen from the home screen.
///
/// Handles both layouts:
///  - Desktop / wide: a persistent sidebar exposes the Settings entry
///    (a Material [Icons.settings_outlined] icon).
///  - Compact: the navigation drawer must be opened first (via the menu
///    button) before the Settings entry is reachable.
Future<void> _openSettings(WidgetTester tester) async {
  await _openNavEntry(tester, const Key('ui-home-nav-settings'));
}

/// Opens a home navigation entry ([key]) from the current screen, handling both
/// layouts like [_openSettings]:
///  - Desktop / wide: the entry is already visible in the persistent sidebar.
///  - Compact: open the navigation drawer, then tap the entry inside it.
Future<void> _openNavEntry(WidgetTester tester, Key key) async {
  if (tester.any(find.byKey(key))) {
    // Desktop / wide: a persistent sidebar exposes the entry.
    // 矮横屏（如 compact-land-890x400，宽度 890→走桌面 sidebar）下侧栏是
    // 可滚动 ListView，底部入口可能在视口外，先滚动到可见再点。
    await tester.ensureVisible(find.byKey(key));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(key));
  } else {
    // Compact: open the navigation drawer, then tap the entry inside it.
    final scaffold = tester.state<ScaffoldState>(find.byType(Scaffold).first);
    scaffold.openDrawer();
    await tester.pumpAndSettle();
    await _settle(tester); // 抽屉开启动画完全走完再点入口
    expect(find.byKey(key), findsWidgets);
    // 抽屉导航是 SingleChildScrollView，矮屏下底部入口可能滚出视口。
    await tester.ensureVisible(find.byKey(key));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(key));
  }

  await tester.pumpAndSettle();
}

/// Toggles a settings switch tile located by [key], scrolling it into view first
/// (the settings list is a lazily built ListView).
Future<void> _toggleSettingSwitch(WidgetTester tester, Key key) async {
  await tester.scrollUntilVisible(
    find.byKey(key),
    200.0,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  await _settle(tester); // 滚动定位完成后再点开关
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
  await _settle(tester); // 开关切换动画/持久化走完
}

/// Opens Settings → Display, toggles the "Markdown" switch, and returns to home.
Future<void> _toggleMarkdown(WidgetTester tester) async {
  await _openSettings(tester);
  await tester.scrollUntilVisible(
    find.byKey(const Key('ui-setting-hub-display')),
    200.0,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('ui-setting-hub-display')));
  await tester.pumpAndSettle();
  await _toggleSettingSwitch(tester, const Key('ui-setting-switch-markdown'));
  await _popTopRoute(tester); // back to hub
  await tester.pumpAndSettle();
  await _popTopRoute(tester); // back to home
  await tester.pumpAndSettle();
}

/// Turns off "Enable Sync" once so the app's autoSync is a no-op for the rest of
/// the run. The test environment's sync backend is unreachable, so leaving sync
/// on makes background syncs throw BackendNotInitialized / BackendUnavailable
/// and destabilizes otherwise-unrelated tests.
bool _syncDisabled = false;
Future<void> _disableSync(WidgetTester tester) async {
  if (_syncDisabled) return;
  _syncDisabled = true;

  // 空库首次建档等场景下 settings 入口可能尚未就绪；同步后端本就不可达，
  // 找不到入口时跳过禁用，不影响后续用例。
  if (!tester.any(find.byKey(const Key('ui-home-nav-settings')))) return;

  await _openNavEntry(tester, const Key('ui-home-nav-settings'));
  await tester.scrollUntilVisible(
    find.byKey(const Key('ui-setting-hub-sync')),
    200.0,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('ui-setting-hub-sync')));
  await tester.pumpAndSettle();

  // Only toggle off if sync is currently enabled.
  final switchFinder = find.descendant(
    of: find.byKey(const Key('ui-setting-switch-sync')),
    matching: find.byType(ShadSwitch),
  );
  if (tester.any(switchFinder) &&
      tester.widget<ShadSwitch>(switchFinder).value) {
    await tester.tap(find.byKey(const Key('ui-setting-switch-sync')));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
  }

  await _backToHome(tester);
}

/// Empties the recycle bin (if it has anything) via Clear All, then returns home.
/// Gives each recycle-bin sub-test a clean slate so the per-note "more" menu is
/// unambiguous (only the note the test seeds is present).
Future<void> _clearAllTrash(WidgetTester tester) async {
  await _openNavEntry(tester, const Key('ui-home-nav-deleted'));
  await _settle(tester); // 回收站页就绪
  if (tester.any(find.byKey(const Key('ui-deleted-clearall')))) {
    await tester.tap(find.byKey(const Key('ui-deleted-clearall')));
    await tester.pumpAndSettle();
    await _settle(tester); // 确认弹框动画走完
    await tester.tap(find.byKey(const Key('ui-dialog-confirm')));
    await _waitFor(
      tester,
      () => !tester.any(find.byKey(const Key('ui-deleted-clearall'))),
    );
    await _settle(tester); // 清空完成后稳定
  }
  // Loop-popping handles any lingering dialog/route from the clear-all before
  // settling back on home.
  await _backToHome(tester);
}

/// Runs [body] once per viewport.
///
/// 桌面平台（Windows/macOS/Linux）会遍历 [_viewports]，用
/// `setSurfaceSize` 程序化 resize（等效于拖拽窗口边框），在每个尺寸下校验
/// overflow 并运行 [body]。真机（Android/iOS）窗口尺寸由系统决定、不可程序化
/// 缩放，因此**不遍历视口**，只按设备自然尺寸运行一遍 [body]。
///
/// The caller is expected to have logged in already (e.g. via [_loginToHome]);
/// the app is launched only once for the whole test and simply re-laid-out at
/// each new window size. For every desktop viewport it:
///   1. programmatically resizes the surface (the test-mode equivalent of
///      dragging the window border on Windows),
///   2. pumps so the tree rebuilds under the new constraints,
///   3. asserts home itself does not overflow at that size,
///   4. runs [body], then returns to home before the next size.
///
/// [body] receives the current viewport name so it can bake it into assertion
/// `reason`s, making a failure name the exact size that overflowed.
///
/// To cover a new window size in every flow, just add one line to [_viewports].
Future<void> _forEachViewport(
  WidgetTester tester,
  Future<void> Function(WidgetTester tester, String sizeName) body,
) async {
  // 真机（Android/iOS）：不 resize，按设备当前尺寸跑一遍即可。
  if (!_isDesktop) {
    await body(tester, 'device');
    return;
  }

  // 把窗口固定到已知屏幕位置，避免在各尺寸间缩放时左上角/位置漂移出屏。
  await setWindowPosition(const Offset(100, 100));

  for (final entry in _viewports.entries) {
    // 桌面：用 window_manager 真实缩放窗口，使 MediaQuery/约束随平台尺寸更新
    //（setSurfaceSize 只改 View.physicalSize、不更新 MediaQuery）。
    // null 表示恢复默认初始尺寸（对应 runner 启动时的 kAppWindowInitialSize）。
    final size = entry.value;
    final target = size ?? kAppWindowInitialSize;
    await setWindowSize(target);
    await tester.pumpAndSettle();

    // 核验窗口尺寸真的生效：打印实际尺寸，并断言与目标误差不超过 50（容忍
    // 系统边框/DWM 缩放等造成的偏差）。若 resize 未生效会在这里即时报错，
    // 而不是等到后续布局断言才暴露。
    final Size? actual = await getWindowSize();
    // ignore: avoid_print
    print('[viewport ${entry.key}] 目标尺寸=$target, 实际窗口尺寸=$actual');
    expect(
      actual,
      isNotNull,
      reason: 'getWindowSize() 应返回桌面窗口实际尺寸 @ ${entry.key}',
    );
    expect(
      (actual!.width - target.width).abs() <= 50 &&
          (actual.height - target.height).abs() <= 50,
      isTrue,
      reason:
          'setWindowSize 后窗口尺寸应接近目标 '
          '(目标=$target, 实际=$actual) @ ${entry.key}',
    );

    // After resizing, check home does not overflow at this size before we
    // drill into any sub-page.
    expect(
      tester.takeException(),
      isNull,
      reason: 'home overflow @ ${entry.key}',
    );

    await body(tester, entry.key);
    await _backToHome(tester); // next round starts from a clean home
  }

  // restore the default window size
  await setWindowSize(kAppWindowInitialSize);
  await tester.pumpAndSettle();
}

/// 是否桌面平台。真机上应从设备自然尺寸运行，程序化 resize 无意义。
bool get _isDesktop =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;
