/*
 * Copyright (C) mcxiaoke 2026 - All Rights Reserved.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * NoteFormWidget 控件级测试（轻量环境，不碰 DB / 加密）。
 *
 * 守卫 initialValue → controller 的重构：
 *   - 输入经 controller 驱动（而非旧的 onChanged 回调），写入 controller.text；
 *   - ui-note-field-title / ui-note-field-body 两个测试 Key 必须保留
 *     （integration_test 用它们做 enterText）。
 */

import 'package:flutter/material.dart';

import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_session_timeout/local_session_timeout.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/app_theme.dart';
import 'package:safenotes/models/shad_theme.dart';
import 'package:safenotes/utils/notes_color.dart';
import 'package:safenotes/widgets/note_widget.dart';

import 'support/harness.dart';

/// 与 note_font_preview_test 一致的轻量封装：ShadTheme + MaterialApp + 双 Provider。
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
            theme: ShadThemes.build(const Color(0xFF0F3460), Brightness.light),
            appBuilder: (c) => MaterialApp(home: screen),
          );
        },
      ),
    ),
  );
}

void main() {
  setUpAll(() async {
    await initLightEnv();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PreferencesStorage.init();
  });

  testWidgets(
    'NoteFormWidget 用 controller 驱动输入并保留测试 Key',
    (tester) async {
      final titleC = TextEditingController();
      final descC = TextEditingController();
      await tester.pumpWidget(
        wrapScreen(
          NoteFormWidget(
            titleController: titleC,
            descriptionController: descC,
            sessionStateStream: StreamController<SessionState>(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 两个测试 Key 必须保留（集成测试依赖）
      expect(find.byKey(const Key('ui-note-field-title')), findsOneWidget);
      expect(find.byKey(const Key('ui-note-field-body')), findsOneWidget);

      // 输入经 controller 写回（而非旧 onChanged 回调）
      await tester.enterText(
        find.byKey(const Key('ui-note-field-title')),
        '标题',
      );
      await tester.enterText(
        find.byKey(const Key('ui-note-field-body')),
        '正文',
      );
      expect(titleC.text, '标题');
      expect(descC.text, '正文');
    },
  );
}
