import 'package:flutter/material.dart';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/app_theme.dart';
import 'package:safenotes/models/shad_theme.dart';
import 'package:safenotes/utils/editor_text.dart';
import 'package:safenotes/utils/notes_color.dart';
import 'support/asset_loader.dart';
import 'support/harness.dart';

void main() {
  setUpAll(() async {
    await initLightEnv();
    await PreferencesStorage.init();
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PreferencesStorage.init();
  });

  Widget wrapScreen(Widget screen) {
    final tp = ThemeProvider();
    final nc = NotesColor();
    return EasyLocalization(
      path: 'assets/translations',
      supportedLocales: const [Locale('en', 'US'), Locale('zh', 'CN')],
      fallbackLocale: const Locale('en', 'US'),
      startLocale: const Locale('en', 'US'),
      assetLoader: TestAssetLoader(),
      child: MultiProvider(
        providers: [
          ChangeNotifierProvider<ThemeProvider>.value(value: tp),
          ChangeNotifierProvider<NotesColor>.value(value: nc),
        ],
        builder: (context, _) => Builder(
          builder: (ctx) {
            Provider.of<ThemeProvider>(ctx);
            return ShadApp.custom(
              themeMode: ThemeMode.light,
              theme: ShadThemes.build(
                const Color(0xFF0F3460),
                Brightness.light,
              ),
              appBuilder: (c) => MaterialApp(home: screen),
            );
          },
        ),
      ),
    );
  }

  testWidgets('dump merged TextStyle values', (tester) async {
    late TextStyle shadMuted;
    late TextStyle mergedBody;
    late TextStyle mergedTitle;

    await tester.pumpWidget(
      wrapScreen(
        Scaffold(
          body: Builder(
            builder: (context) {
              shadMuted = ShadTheme.of(context).textTheme.muted;
              mergedBody = shadMuted
                  .copyWith(color: ShadTheme.of(context).colorScheme.foreground)
                  .merge(EditorText.body());
              mergedTitle = shadMuted
                  .copyWith(color: ShadTheme.of(context).colorScheme.foreground)
                  .merge(EditorText.title());
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // shad muted has 'even', but EditorText._style() now sets 'proportional'
    // so merged result should be 'proportional' (matching EditableText's StrutStyle)
    expect(
      shadMuted.leadingDistribution,
      TextLeadingDistribution.even,
      reason: 'shad muted should have even',
    );

    expect(
      mergedBody.leadingDistribution,
      TextLeadingDistribution.proportional,
      reason: 'merged body should override to proportional',
    );
    expect(
      mergedTitle.leadingDistribution,
      TextLeadingDistribution.proportional,
      reason: 'merged title should override to proportional',
    );

    expect(
      EditorText.body().leadingDistribution,
      TextLeadingDistribution.proportional,
      reason: 'raw EditorText.body() should set proportional',
    );
    expect(
      EditorText.title().leadingDistribution,
      TextLeadingDistribution.proportional,
      reason: 'raw EditorText.title() should set proportional',
    );
  });
}
