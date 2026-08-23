/*
 * Copyright (C) mcxiaoke 2026 - All Rights Reserved.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * EditorText 映射函数单元测试：
 * - lineHeightOf：档位值正确、越界 clamp
 * - textAlignOf：映射正确、越界 clamp
 * - noteFontTypeOf：系统档回读全局、1-3 映射到 AppFontType
 * - body()/title()：行高仅正文生效，标题保持固定
 */

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/utils/editor_text.dart';
import 'package:safenotes/utils/platform_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PreferencesStorage.init();
  });

  group('lineHeightOf', () {
    test('returns correct values for valid indices', () {
      expect(EditorText.lineHeightOf(0), 1.2);
      expect(EditorText.lineHeightOf(1), 1.4);
      expect(EditorText.lineHeightOf(2), 1.6);
      expect(EditorText.lineHeightOf(3), 1.8);
    });

    test('clamps out-of-range indices', () {
      expect(EditorText.lineHeightOf(-1), 1.2);
      expect(EditorText.lineHeightOf(99), 1.8);
    });
  });

  group('lineHeight getter', () {
    test('returns default 1.4 when not set', () {
      expect(EditorText.lineHeight, 1.4);
    });

    test('returns saved value after setNoteLineHeightIndex', () async {
      await PreferencesStorage.setNoteLineHeightIndex(2);
      expect(EditorText.lineHeight, 1.6);
    });
  });

  group('textAlignOf', () {
    test('maps indices to TextAlign correctly', () {
      expect(EditorText.textAlignOf(0), TextAlign.start);
      expect(EditorText.textAlignOf(1), TextAlign.center);
      expect(EditorText.textAlignOf(2), TextAlign.justify);
    });

    test('clamps out-of-range indices', () {
      expect(EditorText.textAlignOf(-1), TextAlign.start);
      expect(EditorText.textAlignOf(99), TextAlign.justify);
    });
  });

  group('textAlign getter', () {
    test('returns default TextAlign.start when not set', () {
      expect(EditorText.textAlign, TextAlign.start);
    });

    test('returns saved value after setNoteTextAlignIndex', () async {
      await PreferencesStorage.setNoteTextAlignIndex(1);
      expect(EditorText.textAlign, TextAlign.center);
    });
  });

  group('noteFontTypeOf', () {
    test('index 0 (system) reads global fontFamilyTypeIndex', () async {
      // Default global = 0 = sans
      expect(EditorText.noteFontTypeOf(0), AppFontType.sans);

      // Set global to serif (1)
      await PreferencesStorage.setFontFamilyTypeIndex(1);
      expect(EditorText.noteFontTypeOf(0), AppFontType.serif);

      // Set global to mono (2)
      await PreferencesStorage.setFontFamilyTypeIndex(2);
      expect(EditorText.noteFontTypeOf(0), AppFontType.mono);
    });

    test('index 1-3 maps to AppFontType independent of global', () async {
      // Set global to mono to verify index 1-3 don't read it
      await PreferencesStorage.setFontFamilyTypeIndex(2);

      expect(EditorText.noteFontTypeOf(1), AppFontType.sans);
      expect(EditorText.noteFontTypeOf(2), AppFontType.serif);
      expect(EditorText.noteFontTypeOf(3), AppFontType.mono);
    });

    test('clamps out-of-range indices', () {
      expect(EditorText.noteFontTypeOf(-1), AppFontType.sans);
      expect(EditorText.noteFontTypeOf(99), AppFontType.mono);
    });
  });

  group('fontType getter', () {
    test(
      'reads noteFontFamilyTypeIndex=0 as system (follows global)',
      () async {
        // Default: noteFont=0 (system), global=0 (sans)
        expect(EditorText.fontType, AppFontType.sans);

        // Change global to serif
        await PreferencesStorage.setFontFamilyTypeIndex(1);
        expect(EditorText.fontType, AppFontType.serif);
      },
    );

    test(
      'reads noteFontFamilyTypeIndex=2 as serif (independent of global)',
      () async {
        await PreferencesStorage.setFontFamilyTypeIndex(2); // global = mono
        await PreferencesStorage.setNoteFontFamilyTypeIndex(2); // note = serif
        expect(EditorText.fontType, AppFontType.serif);
      },
    );
  });

  group('body() line height', () {
    test('body() applies saved line height', () {
      // Default line height = 1.4
      final bodyStyle = EditorText.body();
      expect(bodyStyle.height, 1.4);
    });

    test('body() reflects changed line height', () async {
      await PreferencesStorage.setNoteLineHeightIndex(3); // 1.8
      final bodyStyle = EditorText.body();
      expect(bodyStyle.height, 1.8);
    });
  });

  group('title() line height', () {
    test('title() ignores line height setting (always 1.2)', () async {
      await PreferencesStorage.setNoteLineHeightIndex(3); // 1.8
      final titleStyle = EditorText.title();
      // AppText.title.height = 1.2, not 1.8
      expect(titleStyle.height, 1.2);
    });
  });

  group('bodyOf() pending preview', () {
    test('bodyOf applies provided line height', () {
      final style = EditorText.bodyOf(1, 0, 1.6);
      expect(style.height, 1.6);
    });

    test('bodyOf without height uses base body height', () {
      final style = EditorText.bodyOf(1, 0);
      // AppText.body.height = 1.4
      expect(style.height, 1.4);
    });
  });

  group('PreferencesStorage defaults', () {
    test('noteFontFamilyTypeIndex defaults to 0 (system)', () {
      expect(PreferencesStorage.noteFontFamilyTypeIndex, 0);
    });

    test('noteLineHeightIndex defaults to 1 (standard 1.4)', () {
      expect(PreferencesStorage.noteLineHeightIndex, 1);
    });

    test('noteTextAlignIndex defaults to 0 (start)', () {
      expect(PreferencesStorage.noteTextAlignIndex, 0);
    });
  });

  // ---- 字体族生效验证（编辑器 + Markdown 预览共用同一字体链） ----
  //
  // _markdownStyleSheet 的 uiBase 现在用 appFontFamilyFor(EditorText.fontType)，
  // 与 EditorText.body()/_style() 走完全相同的字体解析链。
  // 验证 TextStyle.fontFamily 随 noteFontFamilyTypeIndex 变化即覆盖全部场景。

  group('fontFamily follows note font setting', () {
    test('system (0) follows global fontFamilyTypeIndex', () async {
      // 默认 global=0 (sans) → noteFont=0 (system) → sans
      expect(EditorText.body().fontFamily, 'sans-serif');
      expect(EditorText.title().fontFamily, 'sans-serif');

      // 改全局为 serif，noteFont 仍为 0 (system) → 跟随变为 serif
      await PreferencesStorage.setFontFamilyTypeIndex(1);
      expect(EditorText.body().fontFamily, 'serif');
      expect(EditorText.title().fontFamily, 'serif');

      // 改全局为 mono，noteFont 仍为 0 (system) → 跟随变为 mono
      await PreferencesStorage.setFontFamilyTypeIndex(2);
      expect(EditorText.body().fontFamily, 'monospace');
      expect(EditorText.title().fontFamily, 'monospace');
    });

    test('sans (1) is independent of global', () async {
      await PreferencesStorage.setFontFamilyTypeIndex(2); // global=mono
      await PreferencesStorage.setNoteFontFamilyTypeIndex(1); // note=sans
      expect(EditorText.body().fontFamily, 'sans-serif');
      expect(EditorText.title().fontFamily, 'sans-serif');
    });

    test('serif (2) is independent of global', () async {
      await PreferencesStorage.setFontFamilyTypeIndex(0); // global=sans
      await PreferencesStorage.setNoteFontFamilyTypeIndex(2); // note=serif
      expect(EditorText.body().fontFamily, 'serif');
      expect(EditorText.title().fontFamily, 'serif');
    });

    test('mono (3) is independent of global', () async {
      await PreferencesStorage.setFontFamilyTypeIndex(0); // global=sans
      await PreferencesStorage.setNoteFontFamilyTypeIndex(3); // note=mono
      expect(EditorText.body().fontFamily, 'monospace');
      expect(EditorText.title().fontFamily, 'monospace');
    });

    test(
      'changing noteFontFamilyTypeIndex immediately reflects in fontFamily',
      () async {
        // Start with system (0) → sans
        expect(EditorText.body().fontFamily, 'sans-serif');

        // Change to serif
        await PreferencesStorage.setNoteFontFamilyTypeIndex(2);
        expect(EditorText.body().fontFamily, 'serif');

        // Change to mono
        await PreferencesStorage.setNoteFontFamilyTypeIndex(3);
        expect(EditorText.body().fontFamily, 'monospace');

        // Change back to system (0) → follows global (default sans)
        await PreferencesStorage.setNoteFontFamilyTypeIndex(0);
        expect(EditorText.body().fontFamily, 'sans-serif');
      },
    );
  });
}
