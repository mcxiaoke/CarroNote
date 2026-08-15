/*
* Integration test for SafeNotes.
*
* Drives the *real* app (same bootstrap as a normal launch) end-to-end:
*   login -> home -> sidebar -> settings -> about
*
* Run on the desktop runner (Windows in this environment):
*   flutter test integration_test/app_test.dart -d windows
*
* Or on Android / iOS after connecting a device:
*   flutter test integration_test/app_test.dart
*
* The vault must already be initialized with the passphrase "hello.1111"
* (the test logs in with it). If the app was never set up on this machine,
* the test automatically creates the vault with that passphrase first.
*
* Widgets are located by Key / Icon / type (locale-independent) rather than
* by localized text, so the test is stable regardless of the device language.
*/

// Flutter imports:
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// Project imports:
import 'package:safenotes/main.dart' as safenotes;
import 'package:safenotes/views/settings/about_page.dart';
import 'package:safenotes/views/settings/settings.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('App navigation flow', () {
    testWidgets(
      'login -> home -> sidebar -> settings -> about',
      (WidgetTester tester) async {
        // Launch the full app (identical bootstrap to a real launch).
        // Await main() so its async bootstrap (DB init, EasyLocalization,
        // runApp) completes before we start pumping frames.
        await safenotes.main();

        // Wait until the first screen is actually rendered (the login screen
        // with the passphrase field, or the first-run "set passphrase" screen
        // with two fields). Bootstrap can take a moment, so poll instead of
        // relying on a single pumpAndSettle.
        await _waitForFirstScreen(tester);

        // Make sure we can reach the login screen (creating the vault on a
        // fresh machine if necessary).
        await _ensureVaultReady(tester);

        // --- Login (only if we are on the login screen) ---
        if (tester.any(find.byKey(const Key('passphraseInput')))) {
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
          // The login is async (argon2 keyring unlock, ~1-2s of pure compute
          // that schedules no frames), so pumpAndSettle can return before the
          // navigation to home finishes. Wait for the home screen explicitly.
          await _waitFor(
            tester,
            () =>
                tester.any(find.byIcon(Icons.add)) &&
                !tester.any(find.byKey(const Key('passphraseInput'))),
          );
        }

        // --- Home ---
        // The login screen must be gone and the add-note FAB must be present.
        expect(find.byKey(const Key('passphraseInput')), findsNothing);
        expect(
          find.byIcon(Icons.add),
          findsOneWidget,
          reason: 'Expected the home screen (add-note FAB)',
        );

        // --- Sidebar -> Settings ---
        await _openSettings(tester);
        expect(
          find.byType(SettingsScreen),
          findsOneWidget,
          reason: 'Expected the settings screen',
        );

        // --- Settings -> About ---
        // The settings list is a lazy ListView. The About entry lives in the
        // "General" group at the bottom and is not built into the tree until
        // it is scrolled into view, so find.byKey would not find it yet.
        // Scroll the list down until the About tile is built and visible.
        if (!tester.any(find.byKey(const Key('aboutTile')))) {
          await tester.scrollUntilVisible(
            find.byKey(const Key('aboutTile')),
            200.0,
            scrollable: find.byType(Scrollable).last,
          );
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byKey(const Key('aboutTile')));
        await tester.pumpAndSettle();

        // --- About ---
        expect(find.byType(AboutPage), findsOneWidget);
      },
    );
  });
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
  var settings = find.byIcon(Icons.settings_outlined);

  if (tester.any(settings)) {
    await tester.tap(settings);
  } else {
    // Compact layout: open the drawer, then tap Settings.
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();

    settings = find.byIcon(Icons.settings_outlined);
    expect(settings, findsWidgets);
    await tester.tap(settings);
  }

  await tester.pumpAndSettle();
}
