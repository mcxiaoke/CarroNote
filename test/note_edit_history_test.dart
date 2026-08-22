/*
 * Copyright (C) mcxiaoke 2026 - All Rights Reserved.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * NoteEditHistory 双栈快照逻辑单元测试（纯逻辑，不依赖 DB / 渲染）。
 *
 * 覆盖：record/undo/redo、标题+正文一步还原、同字段合并（用 coalesceMs
 * 参数确定性化，避免依赖真实时钟）、不同字段不合并、canUndo/canRedo
 * 翻转、undo 后新编辑清空 redo 栈、超过上限丢弃最旧一步、快照保留光标。
 */

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:safenotes/utils/note_edit_history.dart';

/// 构造带光标（selection）的 [TextEditingValue]；[sel] 缺省为 -1（无选中）。
TextEditingValue tv(String text, [int sel = -1]) =>
    TextEditingValue(text: text, selection: TextSelection.collapsed(offset: sel));

void main() {
  group('NoteEditHistory 基础撤销/重做', () {
    test('record 后 undo 还原 before、redo 还原 after', () {
      final h = NoteEditHistory();
      h.init(tv('a'), tv('x'));
      h.record(title: tv('ab'), desc: tv('x'), field: 'title');
      expect(h.canUndo, isTrue);
      expect(h.canRedo, isFalse);

      final u = h.undo()!;
      expect(u.titleBefore.text, 'a');
      expect(u.titleAfter.text, 'ab');
      expect(h.canUndo, isFalse);
      expect(h.canRedo, isTrue);

      final r = h.redo()!;
      expect(r.titleAfter.text, 'ab');
      expect(h.canRedo, isFalse);
      expect(h.canUndo, isTrue);
    });

    test('一次 undo 还原快照中的标题与正文（双字段一致）', () {
      final h = NoteEditHistory();
      h.init(tv('T0'), tv('B0'));
      h.record(title: tv('T1'), desc: tv('B0'), field: 'title');
      h.record(title: tv('T1'), desc: tv('B1'), field: 'description');

      // undo 正文步 → 还原到 (T1, B0)
      final u = h.undo()!;
      expect(u.titleBefore.text, 'T1');
      expect(u.descBefore.text, 'B0');
      // 再 undo 标题步 → 还原到 (T0, B0)
      final u2 = h.undo()!;
      expect(u2.titleBefore.text, 'T0');
      expect(u2.descBefore.text, 'B0');
    });
  });

  group('合并策略', () {
    test('同字段且在 coalesceMs 内合并为一步', () {
      // 大窗口：连续同字段编辑必然合并
      final h = NoteEditHistory(coalesceMs: 100000);
      h.init(tv(''), tv(''));
      h.record(title: tv('a'), desc: tv(''), field: 'title');
      h.record(title: tv('ab'), desc: tv(''), field: 'title');

      expect(h.canUndo, isTrue);
      final u = h.undo()!;
      expect(u.titleAfter.text, 'ab');
      expect(u.titleBefore.text, '');
      expect(h.canUndo, isFalse);
    });

    test('coalesceMs=0 时即便同字段也不合并', () {
      final h = NoteEditHistory(coalesceMs: 0);
      h.init(tv(''), tv(''));
      h.record(title: tv('a'), desc: tv(''), field: 'title');
      h.record(title: tv('ab'), desc: tv(''), field: 'title');

      final u1 = h.undo()!;
      expect(u1.titleAfter.text, 'ab');
      final u2 = h.undo()!;
      expect(u2.titleAfter.text, 'a');
      expect(h.canUndo, isFalse);
    });

    test('不同字段不合并', () {
      final h = NoteEditHistory(coalesceMs: 100000);
      h.init(tv(''), tv(''));
      h.record(title: tv('a'), desc: tv(''), field: 'title');
      h.record(title: tv('a'), desc: tv('b'), field: 'description');

      expect(h.canUndo, isTrue);
      h.undo();
      expect(h.canUndo, isTrue); // 仍有标题那一步
    });
  });

  group('纯选区事件（文本未变）不入栈', () {
    test('record 相同文本、仅移动光标/选区 → 不产生撤销步', () {
      final h = NoteEditHistory();
      h.init(tv('hello'), tv(''));

      // 仅选区变化、文本不变（如聚焦/移动光标触发 controller 回调）
      final selectionOnly = TextEditingValue(
        text: 'hello',
        selection: TextSelection.collapsed(offset: 3),
      );
      h.record(title: selectionOnly, desc: tv(''), field: 'title');

      expect(h.canUndo, isFalse, reason: '纯选区事件不应新增撤销步');
      expect(h.undo(), isNull, reason: '撤销栈应为空');

      // 随后的真实键入仍可正常记录
      h.record(title: tv('hello!'), desc: tv(''), field: 'title');
      expect(h.canUndo, isTrue);
      final u = h.undo()!;
      expect(u.titleAfter.text, 'hello!');
      expect(u.titleBefore.text, 'hello');
    });

    test('文本未变时不误清空 redo 栈', () {
      final h = NoteEditHistory();
      h.init(tv('a'), tv(''));
      h.record(title: tv('ab'), desc: tv(''), field: 'title');
      h.undo(); // 产生 redo
      expect(h.canRedo, isTrue);

      // 纯选区事件不应把已持有的 redo 清掉
      h.record(
        title: TextEditingValue(
          text: 'a',
          selection: TextSelection.collapsed(offset: 0),
        ),
        desc: tv(''),
        field: 'title',
      );
      expect(h.canRedo, isTrue, reason: '文本未变不应清空 redo 栈');
    });
  });

  group('redo 栈与上限', () {
    test('undo 后新编辑清空 redo 栈', () {
      final h = NoteEditHistory();
      h.init(tv(''), tv(''));
      h.record(title: tv('a'), desc: tv(''), field: 'title');
      h.undo();
      expect(h.canRedo, isTrue);
      h.record(title: tv('c'), desc: tv(''), field: 'title');
      expect(h.canRedo, isFalse);
    });

    test('超过上限丢弃最旧一步', () {
      // coalesceMs=0：连续同字段记录均不合并，才能凑出多步以触达上限
      final h = NoteEditHistory(max: 2, coalesceMs: 0);
      h.init(tv(''), tv(''));
      h.record(title: tv('a'), desc: tv(''), field: 'title');
      h.record(title: tv('b'), desc: tv(''), field: 'title');
      h.record(title: tv('c'), desc: tv(''), field: 'title');

      final u1 = h.undo()!;
      expect(u1.titleAfter.text, 'c');
      final u2 = h.undo()!;
      expect(u2.titleAfter.text, 'b');
      expect(h.canUndo, isFalse);
    });

    test('快照保留光标 selection', () {
      final h = NoteEditHistory();
      h.init(tv('hi'), tv(''));
      h.record(
        title: TextEditingValue(
          text: 'hi!',
          selection: TextSelection.collapsed(offset: 3),
        ),
        desc: tv(''),
        field: 'title',
      );
      final u = h.undo()!;
      expect(u.titleAfter.text, 'hi!');
      expect(u.titleAfter.selection.baseOffset, 3);
      expect(u.titleBefore.text, 'hi');
    });
  });
}
