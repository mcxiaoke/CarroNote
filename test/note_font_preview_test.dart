/*
 * Copyright (C) mcxiaoke 2026 - All Rights Reserved.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * 笔记字体在预览模式下的 widget 级验证：
 * - 渲染 SelectableText（纯文本预览路径）并验证实际 fontFamily
 * - 渲染 MarkdownBody 并验证 p / code 的 fontFamily 分别跟随笔记字体 / 固定 monospace
 *
 * 测试平台 defaultTargetPlatform = android，appFontFamilyFor 返回：
 *   sans → 'sans-serif', serif → 'serif', mono → 'monospace'
 */

import 'package:flutter/material.dart';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/app_theme.dart';
import 'package:safenotes/models/shad_theme.dart';
import 'package:safenotes/utils/editor_text.dart';
import 'package:safenotes/utils/notes_color.dart';
import 'package:safenotes/utils/platform_ui.dart';
import 'package:safenotes/utils/text_styles.dart';

import 'support/harness.dart';

/// 构建 Markdown 预览 styleSheet（复刻 add_edit_note.dart 的 _markdownStyleSheet 逻辑）。
///
/// _markdownStyleSheet 是 private 方法，这里用相同逻辑构建以测试字体链。
MarkdownStyleSheet buildMarkdownStyle(BuildContext context) {
  final theme = Theme.of(context);
  final shad = ShadTheme.of(context);

  // 与 _markdownStyleSheet 相同：用 EditorText.fontType 而非全局 uiFontFamily
  final TextStyle uiBase = shad.textTheme.muted
      .copyWith(color: shad.colorScheme.foreground)
      .merge(
        AppText.body.copyWith(
          fontFamily: appFontFamilyFor(EditorText.fontType),
          fontFamilyFallback: appFontFallbackFor(EditorText.fontType),
        ),
      );

  final base = MarkdownStyleSheet.fromTheme(theme);
  final baseCode = base.code ?? AppText.body;
  const mono = 'monospace';
  return base.copyWith(
    p: uiBase,
    h1: uiBase.copyWith(fontSize: 24, fontWeight: FontWeight.w700),
    h2: uiBase.copyWith(fontSize: 20, fontWeight: FontWeight.w700),
    code: baseCode.copyWith(fontFamily: mono, fontSize: 14),
  );
}

void main() {
  setUpAll(() async {
    await initLightEnv();
    await PreferencesStorage.init();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PreferencesStorage.init();
  });

  // 把屏幕包进 ShadTheme + MaterialApp，与 App 的提供者结构一致
  Widget wrapScreen(Widget screen) {
    final tp = ThemeProvider();
    final nc = NotesColor();
    return EasyLocalization(
      path: 'assets/translations',
      supportedLocales: const [Locale('en', 'US'), Locale('zh', 'CN')],
      fallbackLocale: const Locale('en', 'US'),
      startLocale: const Locale('en', 'US'),
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

  group('纯文本预览 SelectableText fontFamily', () {
    testWidgets('serif 设置 → SelectableText fontFamily = serif', (tester) async {
      await PreferencesStorage.setNoteFontFamilyTypeIndex(2); // serif

      await tester.pumpWidget(
        wrapScreen(
          Scaffold(
            body: SelectableText('hello world', style: EditorText.body()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final text = tester.widget<SelectableText>(find.byType(SelectableText));
      expect(text.style?.fontFamily, 'serif');
    });

    testWidgets('mono 设置 → SelectableText fontFamily = monospace', (
      tester,
    ) async {
      await PreferencesStorage.setNoteFontFamilyTypeIndex(3); // mono

      await tester.pumpWidget(
        wrapScreen(
          Scaffold(
            body: SelectableText('hello world', style: EditorText.body()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final text = tester.widget<SelectableText>(find.byType(SelectableText));
      expect(text.style?.fontFamily, 'monospace');
    });

    testWidgets('system (0) 跟随全局 sans → sans-serif', (tester) async {
      // 默认 noteFont=0 (system), global=0 (sans)
      await tester.pumpWidget(
        wrapScreen(
          Scaffold(
            body: SelectableText('hello world', style: EditorText.body()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final text = tester.widget<SelectableText>(find.byType(SelectableText));
      expect(text.style?.fontFamily, 'sans-serif');
    });
  });

  group('Markdown 预览 styleSheet fontFamily', () {
    testWidgets('serif 设置 → Markdown p fontFamily = serif, code = monospace', (
      tester,
    ) async {
      await PreferencesStorage.setNoteFontFamilyTypeIndex(2); // serif

      late MarkdownStyleSheet styleSheet;
      await tester.pumpWidget(
        wrapScreen(
          Scaffold(
            body: Builder(
              builder: (context) {
                styleSheet = buildMarkdownStyle(context);
                return MarkdownBody(
                  data: 'regular text\n\n`code text`',
                  styleSheet: styleSheet,
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // p 样式跟随笔记字体
      expect(styleSheet.p?.fontFamily, 'serif');
      // code 始终用 monospace
      expect(styleSheet.code?.fontFamily, 'monospace');
    });

    testWidgets(
      'mono 设置 → Markdown p fontFamily = monospace, code = monospace',
      (tester) async {
        await PreferencesStorage.setNoteFontFamilyTypeIndex(3); // mono

        late MarkdownStyleSheet styleSheet;
        await tester.pumpWidget(
          wrapScreen(
            Scaffold(
              body: Builder(
                builder: (context) {
                  styleSheet = buildMarkdownStyle(context);
                  return MarkdownBody(
                    data: 'regular text\n\n`code text`',
                    styleSheet: styleSheet,
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(styleSheet.p?.fontFamily, 'monospace');
        expect(styleSheet.code?.fontFamily, 'monospace');
      },
    );

    testWidgets('system (0) 跟随全局 sans → Markdown p fontFamily = sans-serif', (
      tester,
    ) async {
      // 默认 noteFont=0 (system), global=0 (sans)
      late MarkdownStyleSheet styleSheet;
      await tester.pumpWidget(
        wrapScreen(
          Scaffold(
            body: Builder(
              builder: (context) {
                styleSheet = buildMarkdownStyle(context);
                return MarkdownBody(
                  data: 'regular text',
                  styleSheet: styleSheet,
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(styleSheet.p?.fontFamily, 'sans-serif');
    });

    testWidgets(
      'system (0) + 全局 serif → Markdown p fontFamily = serif (跟随全局)',
      (tester) async {
        await PreferencesStorage.setFontFamilyTypeIndex(1); // global=serif
        // noteFont 仍为默认 0 (system)

        late MarkdownStyleSheet styleSheet;
        await tester.pumpWidget(
          wrapScreen(
            Scaffold(
              body: Builder(
                builder: (context) {
                  styleSheet = buildMarkdownStyle(context);
                  return MarkdownBody(
                    data: 'regular text',
                    styleSheet: styleSheet,
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // system 档回读全局 → serif
        expect(styleSheet.p?.fontFamily, 'serif');
      },
    );
  });
}
