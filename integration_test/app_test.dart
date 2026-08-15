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
*   flutter test integration_test/app_test.dart
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

// Flutter imports:
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// Project imports:
import 'package:safenotes/main.dart' as safenotes;

/// 命名视口表（逻辑尺寸，单位 dp）。默认两种：窄手机 + 桌面。
///
/// 想覆盖更多尺寸 / 真机，直接在这里加一行即可；所有用到 [_forEachViewport]
/// 的测试会自动在新增尺寸下各跑一遍，无需改动各条 flow。
///
/// 换算：逻辑尺寸 = 物理像素 / (dpi / 160)。例如真机 2670x1200 @480dpi
/// => density 3.0 => 890x400 dp，可加：'phone-land-890x400': Size(890, 400),
const Map<String, Size> _viewports = {
  'compact-port-400x890': const Size(400, 890), // 窄屏手机，最容易暴露 overflow
  'desktop-1280x800': const Size(1280, 800), // 桌面窗口
};

/// 设置页 12 个导航 tile 的 key，按屏幕上从上到下的顺序。
const List<String> _settingsTileKeys = <String>[
  'ui-setting-item-darkmode',
  'ui-setting-item-themecolor',
  'ui-setting-item-notescolor',
  'ui-setting-item-sync',
  'ui-setting-item-backup',
  'ui-setting-item-exportbackup',
  'ui-setting-item-importbackup',
  'ui-setting-item-biometric',
  'ui-setting-item-inactivity',
  'ui-setting-item-changepassphrase',
  'ui-setting-item-language',
  'ui-setting-item-about',
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

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
          // Confirm we are on the settings screen: the dark-mode tile is always
          // present among the navigation tiles (the settings icon itself only
          // lives on the home entry, not on this screen).
          expect(
            find.byKey(const Key('ui-setting-item-darkmode')),
            findsOneWidget,
            reason: 'Expected to be on the settings screen @ $size',
          );

          // Navigation tiles in their on-screen top->bottom order. Visiting each
          // simply opens the sub-page/sheet/dialog and returns, asserting that
          // nothing crashed and no layout overflow occurred.
          for (final key in _settingsTileKeys) {
            final tileFinder = find.byKey(Key(key));
            // The settings list is a (lazily built) ListView. A tile may be in
            // the tree but scrolled out of view, so always scroll it into view
            // before tapping (no-op when already visible).
            await tester.scrollUntilVisible(
              tileFinder,
              200.0,
              scrollable: find.byType(Scrollable).first,
            );
            await tester.pumpAndSettle();

            await tester.tap(tileFinder);
            await tester.pumpAndSettle();

            // A "crash" surfaces as an ErrorWidget; a layout overflow surfaces as
            // a pending FlutterError captured by tester.takeException().
            expect(
              find.byType(ErrorWidget),
              findsNothing,
              reason: 'ErrorWidget rendered on $key @ $size',
            );
            expect(
              tester.takeException(),
              isNull,
              reason: 'Crash / layout overflow on $key @ $size',
            );

            // Return to the settings screen.
            await _popTopRoute(tester);
          }
        });
      },
    );
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
    await _waitForFirstScreen(tester);
    await _ensureVaultReady(tester);
    await _loginIfNeeded(tester);
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

  await tester.tap(find.byKey(const Key('loginButton')));
  // Login is async (argon2 keyring unlock, ~1-2s of pure compute that
  // schedules no frames), so pumpAndSettle can return before navigation to
  // home finishes. Wait for the home screen explicitly.
  await _waitFor(tester, () => _isHome(tester));
}

/// True when the home screen is showing (add-note FAB present, no login field).
bool _isHome(WidgetTester tester) =>
    tester.any(find.byIcon(Icons.add)) &&
    !tester.any(find.byKey(const Key('passphraseInput')));

/// Pops the top-most route (pushed page, bottom sheet, or dialog) on the root
/// navigator and lets the frame settle.
Future<void> _popTopRoute(WidgetTester tester) async {
  final element = tester.element(find.byType(Scaffold).first);
  Navigator.of(element, rootNavigator: true).pop();
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
        navigator.pop();
        await tester.pumpAndSettle();
        continue;
      }
    }
    return; // nothing left to pop
  }
}

/// Creates a note via the FAB: opens the editor, enters title/body, saves,
/// and waits for it to appear back on home.
Future<void> _createNote(
  WidgetTester tester,
  String title,
  String body,
) async {
  await tester.tap(find.byKey(const Key('ui-home-fab-newnote')));
  await tester.pumpAndSettle();

  await tester.enterText(find.byKey(const Key('ui-note-field-title')), title);
  await tester.enterText(find.byKey(const Key('ui-note-field-body')), body);
  await tester.pumpAndSettle();

  await tester.tap(find.byKey(const Key('ui-note-button-save')));
  // Save is async (DB write) then closes the page; wait for the note to show.
  await _waitFor(tester, () => tester.any(find.text(title)));
}

/// Counts the note cards currently present on home (by their keyed index).
int _countNotes(WidgetTester tester) {
  var n = 0;
  while (tester.any(find.byKey(Key('ui-home-note-$n')))) {
    n++;
  }
  return n;
}

/// Ensures at least [min] notes exist (seeds dummy notes if the vault is empty
/// or has too few). Keeps the note test deterministic regardless of prior state.
Future<void> _ensureMinNotes(WidgetTester tester, int min) async {
  var guard = 0;
  while (_countNotes(tester) < min && guard < min + 2) {
    await _createNote(tester, 'IT 种子笔记 $guard', 'seed body $guard');
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

  await tester.tap(find.byKey(const Key('setupConfirmButton')));
  await tester.pumpAndSettle();
}

/// Opens the Settings screen from the home screen.
///
/// Handles both layouts:
///  - Desktop / wide: a persistent sidebar exposes the Settings entry
///    (a Material [Icons.settings_outlined] icon).
///  - Compact: the navigation drawer must be opened first (via the menu
///    button) before the Settings entry is reachable.
Future<void> _openSettings(WidgetTester tester) async {
  final settingsKey = find.byKey(const Key('ui-home-nav-settings'));

  if (tester.any(settingsKey)) {
    // Desktop / wide: a persistent sidebar exposes the Settings entry.
    await tester.tap(settingsKey);
  } else {
    // Compact: open the navigation drawer, then tap Settings inside it.
    final scaffold = tester.state<ScaffoldState>(
      find.byType(Scaffold).first,
    );
    scaffold.openDrawer();
    await tester.pumpAndSettle();
    expect(settingsKey, findsWidgets);
    await tester.tap(settingsKey);
  }

  await tester.pumpAndSettle();
}

/// Runs [body] once per viewport listed in [_viewports].
///
/// The caller is expected to have logged in already (e.g. via [_loginToHome]);
/// the app is launched only once for the whole test and simply re-laid-out at
/// each new window size — exactly like resizing the window on the desktop
/// runner between rounds. For every viewport it:
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
  for (final entry in _viewports.entries) {
    await tester.binding.setSurfaceSize(entry.value);
    await tester.pumpAndSettle();

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

  await tester.binding.setSurfaceSize(null); // restore the default window size
  await tester.pumpAndSettle();
}
