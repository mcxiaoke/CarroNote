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
      expect(keys.where((k) => RegExp(r'[0-9]').hasMatch(k)).length, 10);
      expect(keys.where((k) => RegExp(r'[A-Z]').hasMatch(k)).length, 26);
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

  group('PinKeyboard wrap(紧凑横屏) 布局', () {
    PinKeyboard buildWrap(PinCharset charset) {
      return PinKeyboard(
        wrap: true,
        wrapMinRows: 2,
        keys: charset.keys,
        columns: charset.columns,
        columnsWide: charset.columnsWide,
        onKey: (_) {},
        onBackspace: () {},
      );
    }

    List<Row> findRows(WidgetTester tester) => tester
        .widgetList<Row>(
          find.descendant(
            of: find.byType(PinKeyboard),
            matching: find.byType(Row),
          ),
        )
        .toList();

    testWidgets('数字键盘横屏: 至少 2 行且末行左对齐, 不溢出', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SizedBox(
            width: 700,
            height: 320,
            child: buildWrap(PinCharset.digits),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 不溢出(此前会压成单行;现在强制 6+5 两行)
      expect(tester.takeException(), isNull);
      // 11 键(10 数字 + 删除)→ 每行最多 6 → 2 行
      final rows = findRows(tester);
      expect(rows.length, 2);
      // 末行按键数 < 满行(5 < 6),即确有折行
      expect(rows.last.children.length, lessThan(rows.first.children.length));
    });

    testWidgets('全键盘(letters)横屏: 按可用宽度自然折行, 不溢出且不止 2 行', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SizedBox(
            width: 700,
            height: 320,
            child: buildWrap(PinCharset.letters),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 关键回归:letters 40 键不能再被压成 2 行并横向溢出
      expect(tester.takeException(), isNull);
      // 700 宽约 11 个/行 → 4 行(而非 2 行)
      final rows = _rows(tester);
      expect(rows.length, greaterThan(2));
      // 按键总数不变:39 键 + 删除 = 40
      expect(_circleButtons(tester).length, 40);
    });
  });

  group('PinKeyboard 样式 (filled / outline / keyColor)', () {
    PinKeyboard build({
      PinKeyStyle? style,
      Color? keyColor,
      double? keyBorderWidth,
    }) {
      return PinKeyboard(
        keys: PinCharset.digits.keys,
        columns: PinCharset.digits.columns,
        keyStyle: style ?? PinKeyStyle.filled,
        keyColor: keyColor,
        keyBorderWidth: keyBorderWidth,
        onKey: (_) {},
        onBackspace: () {},
      );
    }

    // 所有圆形 Material(不限背景是否透明;outline 的 Material 背景是 transparent)
    List<Material> findCircleMats(WidgetTester tester) => tester
        .widgetList<Material>(
          find.byWidgetPredicate(
            (w) => w is Material && w.shape is CircleBorder,
          ),
        )
        .toList();

    // 空心装饰:PinKeyboard 内带 BoxShape.circle 且描边非空白的 Container
    List<Container> findOutlineRings(WidgetTester tester) {
      final rings = <Container>[];
      for (final c in tester.widgetList<Container>(
        find.descendant(
          of: find.byType(PinKeyboard),
          matching: find.byType(Container),
        ),
      )) {
        final d = c.decoration;
        if (d is BoxDecoration &&
            d.shape == BoxShape.circle &&
            d.border != null) {
          rings.add(c);
        }
      }
      return rings;
    }

    testWidgets('outline 与 filled 按钮尺寸完全一致, 窄屏不溢出', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SizedBox(
            width: 400,
            height: 800,
            child: build(style: PinKeyStyle.filled),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final filledSizes = findCircleMats(
        tester,
      ).map((m) => tester.getSize(find.byWidget(m))).toSet();

      expect(tester.takeException(), isNull);

      await tester.pumpWidget(
        _wrap(
          SizedBox(
            width: 400,
            height: 800,
            child: build(style: PinKeyStyle.outline),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final outlineSizes = _circleMats(
        tester,
      ).map((m) => tester.getSize(find.byWidget(m))).toSet();
      final ex = tester.takeException();

      // 核心回归:outline 每键若向外扩 borderWidth 会比 filled 大 → 触发溢出。
      expect(ex, isNull, reason: 'outline 不应溢出');
      expect(outlineSizes, filledSizes, reason: 'outline 按钮尺寸必须与 filled 完全一致');
    });

    testWidgets('outline: 背景透明 + 有描边圆环 + 描边用前景色', (tester) async {
      const teal = Color(0xFF00897B);
      await tester.pumpWidget(
        _wrap(
          SizedBox(
            width: 400,
            height: 800,
            child: build(style: PinKeyStyle.outline, keyColor: teal),
          ),
        ),
      );
      await tester.pumpAndSettle();

      for (final m in _circleMats(tester)) {
        expect(m.color, Colors.transparent, reason: '空心底应为透明');
      }
      final rings = findOutlineRings(tester);
      expect(rings, isNotEmpty);
      for (final r in rings) {
        final border = (r.decoration! as BoxDecoration).border! as Border;
        expect(border.top.color, teal, reason: '描边色应取 keyColor');
        expect(border.top.width, closeTo(1.5, 0.01), reason: '默认描边宽 1.5');
      }
    });

    testWidgets('keyBorderWidth 自定义描边宽度生效', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SizedBox(
            width: 400,
            height: 800,
            child: build(
              style: PinKeyStyle.outline,
              keyColor: const Color(0xFF000000),
              keyBorderWidth: 3.5,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final rings = findOutlineRings(tester);
      expect(rings, isNotEmpty);
      final border =
          (rings.first.decoration! as BoxDecoration).border! as Border;
      expect(border.top.width, closeTo(3.5, 0.01));
    });

    testWidgets('filled + 深色 keyColor: 以 keyColor 为圆底, 字取白色', (tester) async {
      const dark = Color(0xFF1B1B1B);
      await tester.pumpWidget(
        _wrap(SizedBox(width: 400, height: 800, child: build(keyColor: dark))),
      );
      await tester.pumpAndSettle();

      // 亮度估算基准
      expect(ThemeData.estimateBrightnessForColor(dark), Brightness.dark);
      // 圆底用 keyColor(非透明,能被 _circleMats 抓到)
      final mats = _circleMats(tester).map((m) => m.color).toSet();
      expect(mats, contains(dark));
      // 深底 → 白色字
      final colors = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byType(PinKeyboard),
              matching: find.byType(Text),
            ),
          )
          .map((t) => t.style!.color)
          .toSet();
      expect(colors, contains(Colors.white));
    });

    testWidgets('filled + 浅色 keyColor: 字取黑色', (tester) async {
      const light = Color(0xFFFFF3E0);
      await tester.pumpWidget(
        _wrap(SizedBox(width: 400, height: 800, child: build(keyColor: light))),
      );
      await tester.pumpAndSettle();

      expect(ThemeData.estimateBrightnessForColor(light), Brightness.light);
      final colors = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byType(PinKeyboard),
              matching: find.byType(Text),
            ),
          )
          .map((t) => t.style!.color)
          .toSet();
      expect(colors, contains(Colors.black));
    });

    testWidgets('outline 未传 keyColor 时描边与字用主题 primary', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SizedBox(
            width: 400,
            height: 800,
            child: build(style: PinKeyStyle.outline),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final rings = findOutlineRings(tester);
      expect(rings, isNotEmpty);
      final primary = Theme.of(
        tester.element(find.byType(PinKeyboard)),
      ).colorScheme.primary;
      final border =
          (rings.first.decoration! as BoxDecoration).border! as Border;
      expect(border.top.color, primary);
    });
  });
}
