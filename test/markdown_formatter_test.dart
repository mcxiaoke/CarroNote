/*
 * Copyright (C) Keshav Priyadarshi and others - All Rights Reserved.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 * You may use, distribute and modify this code under the
 * terms of the GPL-3.0+ license.
 *
 * You should have received a copy of the GNU General Public License v3.0 with
 * this file. If not, please visit https://www.gnu.org/licenses/gpl-3.0.html
 *
 * See https://safenotes.dev for support or download.
 */

import 'package:flutter/services.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:safenotes/utils/markdown_formatter.dart';

void main() {
  group('MarkdownFormatter.wrapSelection', () {
    test('未选中文本时插入定界符并将光标定位于中间', () {
      const val = TextEditingValue(
        text: 'Hello world',
        selection: TextSelection.collapsed(offset: 5),
      );
      final res = MarkdownFormatter.wrapSelection(
        val,
        prefix: '**',
        suffix: '**',
      );
      expect(res.text, 'Hello**** world');
      expect(res.selection.baseOffset, 7);
      expect(res.selection.isCollapsed, isTrue);
    });

    test('选中文本时正常包裹定界符并保持选区', () {
      const val = TextEditingValue(
        text: 'Hello world',
        selection: TextSelection(baseOffset: 6, extentOffset: 11),
      );
      final res = MarkdownFormatter.wrapSelection(
        val,
        prefix: '**',
        suffix: '**',
      );
      expect(res.text, 'Hello **world**');
      expect(res.selection.baseOffset, 8);
      expect(res.selection.extentOffset, 13);
    });

    test('选中文本内部包含定界符时智能解包', () {
      const val = TextEditingValue(
        text: 'Hello **world**!',
        selection: TextSelection(baseOffset: 6, extentOffset: 15),
      );
      final res = MarkdownFormatter.wrapSelection(
        val,
        prefix: '**',
        suffix: '**',
      );
      expect(res.text, 'Hello world!');
      expect(res.selection.baseOffset, 6);
      expect(res.selection.extentOffset, 11);
    });

    test('选区外部紧邻定界符时智能解包', () {
      const val = TextEditingValue(
        text: 'Hello **world**!',
        selection: TextSelection(baseOffset: 8, extentOffset: 13),
      );
      final res = MarkdownFormatter.wrapSelection(
        val,
        prefix: '**',
        suffix: '**',
      );
      expect(res.text, 'Hello world!');
      expect(res.selection.baseOffset, 6);
      expect(res.selection.extentOffset, 11);
    });

    test('光标处于已插入的定界符中间时再次点击删除定界符', () {
      const val = TextEditingValue(
        text: 'Hello **** world',
        selection: TextSelection.collapsed(offset: 8),
      );
      final res = MarkdownFormatter.wrapSelection(
        val,
        prefix: '**',
        suffix: '**',
      );
      expect(res.text, 'Hello  world');
      expect(res.selection.baseOffset, 6);
      expect(res.selection.isCollapsed, isTrue);
    });
  });

  group('MarkdownFormatter.toggleHeading', () {
    test('轮换模式：无标题 -> H1 -> H2 -> H3 -> 无标题', () {
      var val = const TextEditingValue(
        text: 'Title text',
        selection: TextSelection.collapsed(offset: 3),
      );

      // 0 -> 1 (# )
      val = MarkdownFormatter.toggleHeading(val);
      expect(val.text, '# Title text');

      // 1 -> 2 (## )
      val = MarkdownFormatter.toggleHeading(val);
      expect(val.text, '## Title text');

      // 2 -> 3 (### )
      val = MarkdownFormatter.toggleHeading(val);
      expect(val.text, '### Title text');

      // 3 -> 0 (无标题)
      val = MarkdownFormatter.toggleHeading(val);
      expect(val.text, 'Title text');
    });

    test('指定 targetLevel', () {
      var val = const TextEditingValue(
        text: 'Title text',
        selection: TextSelection.collapsed(offset: 3),
      );

      // 指定 H2
      val = MarkdownFormatter.toggleHeading(val, targetLevel: 2);
      expect(val.text, '## Title text');

      // 再次指定同层级 H2 -> 取消标题
      val = MarkdownFormatter.toggleHeading(val, targetLevel: 2);
      expect(val.text, 'Title text');

      // 切换到 H1
      val = MarkdownFormatter.toggleHeading(val, targetLevel: 1);
      expect(val.text, '# Title text');

      // 从 H1 直切 H3
      val = MarkdownFormatter.toggleHeading(val, targetLevel: 3);
      expect(val.text, '### Title text');
    });
  });

  group('MarkdownFormatter.toggleList', () {
    test('无序列表添加与取消', () {
      var val = const TextEditingValue(
        text: 'Item 1\nItem 2',
        selection: TextSelection(baseOffset: 2, extentOffset: 10),
      );

      val = MarkdownFormatter.toggleList(val, ordered: false);
      expect(val.text, '- Item 1\n- Item 2');

      val = MarkdownFormatter.toggleList(val, ordered: false);
      expect(val.text, 'Item 1\nItem 2');
    });

    test('有序列表递增编号添加与取消', () {
      var val = const TextEditingValue(
        text: 'First\nSecond\nThird',
        selection: TextSelection(baseOffset: 0, extentOffset: 18),
      );

      val = MarkdownFormatter.toggleList(val, ordered: true);
      expect(val.text, '1. First\n2. Second\n3. Third');

      val = MarkdownFormatter.toggleList(val, ordered: true);
      expect(val.text, 'First\nSecond\nThird');
    });
  });

  group('MarkdownFormatter.toggleTaskList', () {
    test('任务列表状态切换：普通 -> 未完成 -> 已完成 -> 取消', () {
      var val = const TextEditingValue(
        text: 'Buy milk',
        selection: TextSelection.collapsed(offset: 3),
      );

      // 添加 - [ ]
      val = MarkdownFormatter.toggleTaskList(val);
      expect(val.text, '- [ ] Buy milk');

      // 切换为 - [x]
      val = MarkdownFormatter.toggleTaskList(val);
      expect(val.text, '- [x] Buy milk');

      // 移除
      val = MarkdownFormatter.toggleTaskList(val);
      expect(val.text, 'Buy milk');
    });
  });

  group(
    'MarkdownFormatter.insertCodeBlock & insertLink & insertHorizontalRule',
    () {
      test('插入代码块', () {
        const val = TextEditingValue(
          text: 'print("hello")',
          selection: TextSelection(baseOffset: 0, extentOffset: 14),
        );
        final res = MarkdownFormatter.insertCodeBlock(val, language: 'dart');
        expect(res.text, '```dart\nprint("hello")\n```\n');
      });

      test('选中文本插入链接', () {
        const val = TextEditingValue(
          text: 'Click here for info',
          selection: TextSelection(baseOffset: 6, extentOffset: 10),
        );
        final res = MarkdownFormatter.insertLink(
          val,
          defaultUrl: 'https://example.com',
        );
        expect(res.text, 'Click [here](https://example.com) for info');
      });

      test('插入水平分割线', () {
        const val = TextEditingValue(
          text: 'First paragraph',
          selection: TextSelection.collapsed(offset: 15),
        );
        final res = MarkdownFormatter.insertHorizontalRule(val);
        expect(res.text, 'First paragraph\n---\n');
      });
    },
  );

  group('MarkdownAutoIndentFormatter', () {
    const formatter = MarkdownAutoIndentFormatter();

    test('有序列表回车自动递增下一项序号', () {
      const oldVal = TextEditingValue(
        text: '1. 第一项',
        selection: TextSelection.collapsed(offset: 6),
      );
      const newVal = TextEditingValue(
        text: '1. 第一项\n',
        selection: TextSelection.collapsed(offset: 7),
      );

      final result = formatter.formatEditUpdate(oldVal, newVal);
      expect(result.text, '1. 第一项\n2. ');
      expect(result.selection.baseOffset, 10);
    });

    test('连续多项有序列表回车继续递增', () {
      const oldVal = TextEditingValue(
        text: '1. 第一项\n2. 第二项',
        selection: TextSelection.collapsed(offset: 13),
      );
      const newVal = TextEditingValue(
        text: '1. 第一项\n2. 第二项\n',
        selection: TextSelection.collapsed(offset: 14),
      );

      final result = formatter.formatEditUpdate(oldVal, newVal);
      expect(result.text, '1. 第一项\n2. 第二项\n3. ');
      expect(result.selection.baseOffset, 17);
    });

    test('空有序列表行再次回车自动清除序号退出列表', () {
      const oldVal = TextEditingValue(
        text: '1. 第一项\n2. ',
        selection: TextSelection.collapsed(offset: 10),
      );
      const newVal = TextEditingValue(
        text: '1. 第一项\n2. \n',
        selection: TextSelection.collapsed(offset: 11),
      );

      final result = formatter.formatEditUpdate(oldVal, newVal);
      expect(result.text, '1. 第一项\n');
      expect(result.selection.baseOffset, 7);
    });

    test('无序列表回车自动续行与空行退出', () {
      const oldVal = TextEditingValue(
        text: '- 购买清单',
        selection: TextSelection.collapsed(offset: 6),
      );
      const newVal = TextEditingValue(
        text: '- 购买清单\n',
        selection: TextSelection.collapsed(offset: 7),
      );

      final res1 = formatter.formatEditUpdate(oldVal, newVal);
      expect(res1.text, '- 购买清单\n- ');

      // 空行再回车
      const emptyOld = TextEditingValue(
        text: '- 购买清单\n- ',
        selection: TextSelection.collapsed(offset: 9),
      );
      const emptyNew = TextEditingValue(
        text: '- 购买清单\n- \n',
        selection: TextSelection.collapsed(offset: 10),
      );
      final res2 = formatter.formatEditUpdate(emptyOld, emptyNew);
      expect(res2.text, '- 购买清单\n');
    });

    test('待办清单回车自动续行与空行退出', () {
      const oldVal = TextEditingValue(
        text: '- [ ] 事项 A',
        selection: TextSelection.collapsed(offset: 10),
      );
      const newVal = TextEditingValue(
        text: '- [ ] 事项 A\n',
        selection: TextSelection.collapsed(offset: 11),
      );

      final res1 = formatter.formatEditUpdate(oldVal, newVal);
      expect(res1.text, '- [ ] 事项 A\n- [ ] ');

      // 空行再回车
      const emptyOld = TextEditingValue(
        text: '- [ ] 事项 A\n- [ ] ',
        selection: TextSelection.collapsed(offset: 17),
      );
      const emptyNew = TextEditingValue(
        text: '- [ ] 事项 A\n- [ ] \n',
        selection: TextSelection.collapsed(offset: 18),
      );
      final res2 = formatter.formatEditUpdate(emptyOld, emptyNew);
      expect(res2.text, '- [ ] 事项 A\n');
    });
  });

  group('MarkdownFormatter.isMarkdown', () {
    test('正确识别 Markdown 语法', () {
      expect(MarkdownFormatter.isMarkdown('# 这是一个标题'), isTrue);
      expect(MarkdownFormatter.isMarkdown('## 二级标题'), isTrue);
      expect(MarkdownFormatter.isMarkdown('- [ ] 待办事项'), isTrue);
      expect(MarkdownFormatter.isMarkdown('- 无序列表项'), isTrue);
      expect(MarkdownFormatter.isMarkdown('* 星号列表项'), isTrue);
      expect(MarkdownFormatter.isMarkdown('1. 有序列表项'), isTrue);
      expect(MarkdownFormatter.isMarkdown('> 这是引用内容'), isTrue);
      expect(
        MarkdownFormatter.isMarkdown('```dart\nvoid main() {}\n```'),
        isTrue,
      );
      expect(MarkdownFormatter.isMarkdown('这里有 `inline code` 代码'), isTrue);
      expect(
        MarkdownFormatter.isMarkdown('[链接文字](https://example.com)'),
        isTrue,
      );
      expect(
        MarkdownFormatter.isMarkdown('![图片](https://example.com/a.png)'),
        isTrue,
      );
      expect(MarkdownFormatter.isMarkdown('这是 **粗体** 文字'), isTrue);
      expect(MarkdownFormatter.isMarkdown('这是 ~~删除线~~ 文字'), isTrue);
      expect(MarkdownFormatter.isMarkdown('---\n'), isTrue);
      expect(MarkdownFormatter.isMarkdown('| 表头1 | 表头2 |\n|---|---|'), isTrue);
    });

    test('正确识别普通纯文本（非 Markdown）', () {
      expect(MarkdownFormatter.isMarkdown(''), isFalse);
      expect(MarkdownFormatter.isMarkdown('   '), isFalse);
      expect(MarkdownFormatter.isMarkdown('这是一段没有任何格式的普通笔记。'), isFalse);
      expect(
        MarkdownFormatter.isMarkdown('床前明月光\n疑是地上霜\n举头望明月\n低头思故乡'),
        isFalse,
      );
      expect(
        MarkdownFormatter.isMarkdown('我的电话是 13800138000，请及时联系我。'),
        isFalse,
      );
      expect(MarkdownFormatter.isMarkdown('今天消费: 100 - 20 = 80 元。'), isFalse);
    });
  });

  group('MarkdownFormatter.prepareMarkdownForRendering', () {
    test('纯文本多行每行追加双空格实现硬换行，防止 CommonMark 合并行', () {
      const input = '床前明月光\n疑是地上霜\n举头望明月\n低头思故乡';
      final result = MarkdownFormatter.prepareMarkdownForRendering(input);
      expect(result, '床前明月光  \n疑是地上霜  \n举头望明月  \n低头思故乡');
    });

    test('保护代码块内部原样输出，代码块内不追加空格', () {
      const input = '''
这是普通段落第一行
这是普通段落第二行

```python
def test():
    a = 1
    return a
```

段落结尾
''';
      final result = MarkdownFormatter.prepareMarkdownForRendering(input);
      expect(result.contains('def test():\n    a = 1\n    return a'), isTrue);
      expect(result.startsWith('这是普通段落第一行  \n这是普通段落第二行  \n'), isTrue);
    });

    test('连续多个空行插入 &nbsp; 防止被 Markdown 引擎合并', () {
      const input = '第一段\n\n\n\n第二段';
      final result = MarkdownFormatter.prepareMarkdownForRendering(input);
      expect(result, '第一段  \n&nbsp;  \n&nbsp;  \n&nbsp;  \n第二段');
    });

    test('空行插入 &nbsp; 保留单空行间距', () {
      const input = '已带空格  \n\n下一段';
      final result = MarkdownFormatter.prepareMarkdownForRendering(input);
      expect(result, '已带空格  \n&nbsp;  \n下一段');
    });
  });
}
