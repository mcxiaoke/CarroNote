/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*/

// PinKeyboard widget 测试。
//
// 覆盖：
//   1. 数字布局渲染与点击回调（含删除键）
//   2. 触感反馈：点击数字键发出 HapticFeedback.lightImpact
//   3. 自适应布局：窄屏 4列×5行 / 宽屏 5列×4行（alphanumeric/letters）
//   4. 高度不受限（ListView 场景）时按宽度阈值切宽屏
//   5. 按键直径限制在 48~72 之间（桌面大屏不放大过头、小屏不溢出）

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:safenotes/models/pin_auth.dart';
import 'package:safenotes/widgets/pin_keyboard.dart';

Widget _wrap(Widget keyboard) {
  return MaterialApp(
    home: Scaffold(body: Center(child: keyboard)),
  );
}

/// 键盘内所有圆形按键(点击反馈改为着色 Material + InkWell 后,按键即圆形 Material)。
List<Material> _circleButtons(WidgetTester tester) {
  return tester
      .widgetList<Material>(
        find.byWidgetPredicate(
          (w) =>
              w is Material &&
              w.shape is CircleBorder &&
              w.color != null &&
              w.color != Colors.transparent,
        ),
      )
      .toList();
}

void main() {
  group('PinKeyboard 基础交互', () {
    testWidgets('数字布局渲染 1-9/0/删除键, 点击触发回调', (tester) async {
      final pressed = <String>[];
      var backspaced = 0;
      await tester.pumpWidget(
        _wrap(PinKeyboard(onKey: pressed.add, onBackspace: () => backspaced++)),
      );

      for (final d in ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0']) {
        expect(find.text(d), findsOneWidget);
      }
      expect(find.byIcon(Icons.backspace_outlined), findsOneWidget);

      await tester.tap(find.text('5'));
      await tester.pump();
      expect(pressed, ['5']);

      await tester.tap(find.byIcon(Icons.backspace_outlined));
      await tester.pump();
      expect(backspaced, 1);
    });

    testWidgets('点击数字键发出触感反馈 lightImpact', (tester) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await tester.pumpWidget(
        _wrap(PinKeyboard(onKey: (_) {}, onBackspace: () {})),
      );

      await tester.tap(find.text('3'));
      await tester.pump();

      expect(
        calls.where((c) => c.method == 'HapticFeedback.vibrate'),
        isNotEmpty,
      );
      final haptic = calls.firstWhere(
        (c) => c.method == 'HapticFeedback.vibrate',
      );
      expect(haptic.arguments, 'HapticFeedbackType.lightImpact');
    });

    testWidgets('disabled 时按键不可点击', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        _wrap(
          PinKeyboard(
            enabled: false,
            onKey: (_) => tapped = true,
            onBackspace: () {},
          ),
        ),
      );
      await tester.tap(find.text('1'), warnIfMissed: false);
      await tester.pump();
      expect(tapped, isFalse);
    });

    testWidgets('shuffle 打开时键序打乱但点击仍返回对应字符', (tester) async {
      final pressed = <String>[];
      const keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'];
      await tester.pumpWidget(
        _wrap(
          PinKeyboard(
            keys: keys,
            columns: 5,
            shuffle: true,
            onKey: pressed.add,
            onBackspace: () {},
          ),
        ),
      );
      await tester.pump();

      // 显示的字符集合与输入集合一致:shuffle 只改顺序、不丢/增键。
      final texts = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byType(PinKeyboard),
              matching: find.byType(Text),
            ),
          )
          .map((t) => t.data)
          .whereType<String>()
          .toList();
      expect(texts.toSet(), keys.toSet());
      expect(texts.length, keys.length);

      // 点击任一显示的字符,回调应返回该字符(打乱仅影响显示层,不影响判定)。
      final first = texts.first;
      await tester.tap(find.text(first));
      await tester.pump();
      expect(pressed, [first]);
    });
  });

  group('PinKeyboard 自适应布局', () {
    PinKeyboard buildKeyboard(PinCharset charset) {
      return PinKeyboard(
        keys: charset.keys,
        columns: charset.columns,
        columnsWide: charset.columnsWide,
        onKey: (_) {},
        onBackspace: () {},
      );
    }

    testWidgets('窄屏(宽<高): alphanumeric 4列×6行', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SizedBox(
            width: 380,
            height: 640,
            child: buildKeyboard(PinCharset.alphanumeric),
          ),
        ),
      );

      final rows = tester
          .widgetList<Row>(
            find.descendant(
              of: find.byType(PinKeyboard),
              matching: find.byType(Row),
            ),
          )
          .toList();
      // 24 格(23 键 + 删除键) → 4 列 × 6 行,每行 4 格(children = 4+3 间距)
      expect(rows.length, 6);
      expect(rows.first.children.length, 7);
      expect(rows.last.children.length, 7);
    });

    testWidgets('宽屏(宽>高): alphanumeric 6列×4行', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SizedBox(
            width: 900,
            height: 320,
            child: buildKeyboard(PinCharset.alphanumeric),
          ),
        ),
      );

      final rows = tester
          .widgetList<Row>(
            find.descendant(
              of: find.byType(PinKeyboard),
              matching: find.byType(Row),
            ),
          )
          .toList();
      // 24 格 → 6 列 × 4 行,每行 6 格(children = 6+5 间距)
      expect(rows.length, 4);
      expect(rows.first.children.length, 11);
    });

    testWidgets('高度不受限(ListView)且宽度足够时 alphanumeric 按宽屏 6列×4行', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SizedBox(
            width: 800,
            child: SingleChildScrollView(
              child: buildKeyboard(PinCharset.alphanumeric),
            ),
          ),
        ),
      );

      final rows = tester
          .widgetList<Row>(
            find.descendant(
              of: find.byType(PinKeyboard),
              matching: find.byType(Row),
            ),
          )
          .toList();
      // 设置/修改 PIN 界面:键盘在高度无限(ListView)中,横屏宽度≥560 → 6 列 × 4 行
      expect(rows.length, 4);
      expect(rows.first.children.length, 11);
    });

    testWidgets('高度不受限(ListView)且宽度足够时 letters 按宽屏 8列×5行', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SizedBox(
            width: 720,
            child: SingleChildScrollView(
              child: buildKeyboard(PinCharset.letters),
            ),
          ),
        ),
      );

      final rows = tester
          .widgetList<Row>(
            find.descendant(
              of: find.byType(PinKeyboard),
              matching: find.byType(Row),
            ),
          )
          .toList();
      // 精简全键盘 40 格(39 键+删除) → 8 列 × 5 行,每行 8 格(children=8+7 间距)
      expect(rows.length, 5);
      expect(rows.first.children.length, 15);
    });

    testWidgets('精简全键盘窄屏: 5列×8行 且 40 格无占位', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SizedBox(
            width: 380,
            height: 720,
            child: buildKeyboard(PinCharset.letters),
          ),
        ),
      );

      final keys = PinCharset.letters.keys;
      expect(keys.length, 39);
      // 10 数字 + 26 字母 + - . _
      expect(
        keys.where((k) => RegExp(r'[0-9]').hasMatch(k)).length,
        10,
      );
      expect(
        keys.where((k) => RegExp(r'[A-Z]').hasMatch(k)).length,
        26,
      );
      expect(keys.where((k) => '-._'.contains(k)).length, 3);

      final rows = tester
          .widgetList<Row>(
            find.descendant(
              of: find.byType(PinKeyboard),
              matching: find.byType(Row),
            ),
          )
          .toList();
      // 40 格(39 键 + 删除) → 5 列 × 8 行,每行 5 格(children=5+4 间距)
      expect(rows.length, 8);
      // 每行都满 5 格(无空占位格):字母/数字/符号 + 删除铺满整网格
      for (final row in rows) {
        expect(row.children.length, 9);
      }
    });

    testWidgets('纯数字窄屏固定 3列×4行', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SizedBox(
            width: 380,
            height: 520,
            child: buildKeyboard(PinCharset.digits),
          ),
        ),
      );

      final rows = tester
          .widgetList<Row>(
            find.descendant(
              of: find.byType(PinKeyboard),
              matching: find.byType(Row),
            ),
          )
          .toList();
      // 12 格(10 键 + 1 占位 + 删除键) → 3 列 × 4 行
      expect(rows.length, 4);
      expect(rows.first.children.length, 5);
    });
  });

  group('PinKeyboard 按键大小限制', () {
    testWidgets('桌面大屏按键不超过 72', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SizedBox(
            width: 1200,
            height: 800,
            child: PinKeyboard(
              keys: PinCharset.alphanumeric.keys,
              columns: PinCharset.alphanumeric.columns,
              columnsWide: PinCharset.alphanumeric.columnsWide,
              onKey: (_) {},
              onBackspace: () {},
            ),
          ),
        ),
      );

      final buttons = _circleButtons(tester);
      // alphanumeric 现为 24 格(23 键 + 删除)
      expect(buttons.length, 24);
      for (final b in buttons) {
        final s = tester.getSize(find.byWidget(b));
        expect(s.width, lessThanOrEqualTo(72));
        expect(s.width, greaterThanOrEqualTo(48));
      }
    });

    testWidgets('窄屏(手机 2:1)6 行不溢出且按键不小于 48', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SizedBox(
            width: 400,
            height: 800,
            child: PinKeyboard(
              keys: PinCharset.alphanumeric.keys,
              columns: PinCharset.alphanumeric.columns,
              columnsWide: PinCharset.alphanumeric.columnsWide,
              onKey: (_) {},
              onBackspace: () {},
            ),
          ),
        ),
      );

      // 不溢出:4 列 × 6 行键盘整体可放入 400×800(2:1)盒子
      expect(tester.takeException(), isNull);
      for (final b in _circleButtons(tester)) {
        final s = tester.getSize(find.byWidget(b));
        expect(s.width, greaterThanOrEqualTo(PinKeyboard.kMinButtonSize));
      }
    });
  });
}
