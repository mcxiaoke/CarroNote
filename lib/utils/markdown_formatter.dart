/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

import 'dart:math';

import 'package:flutter/services.dart';

/// 纯 Dart Markdown 格式化工具集。
///
/// 负责对 [TextEditingValue] 进行基于光标和选区的精确变换，
/// 包含行内样式包裹/解包、行首前缀（标题/列表/任务/引用）切换、代码块与链接插入等。
class MarkdownFormatter {
  const MarkdownFormatter._();

  /// 行首任何 Markdown 块级前缀匹配正则：
  /// - 标题：`^#{1,6}\s+`
  /// - 待办：`^-\s+\[[ xX]\]\s+`
  /// - 无序列表：`^[-*+]\s+`
  /// - 有序列表：`^\d+\.\s+`
  /// - 引用：`^>\s+`
  static final RegExp _headingPrefixRegex = RegExp(r'^#{1,6}\s*');
  static final RegExp _taskListPrefixRegex = RegExp(r'^[-*+]\s+\[[ xX]\]\s*');
  static final RegExp _unorderedListPrefixRegex = RegExp(r'^[-*+]\s*');
  static final RegExp _orderedListPrefixRegex = RegExp(r'^\d+\.\s*');
  static final RegExp _quotePrefixRegex = RegExp(r'^>\s*');

  /// 检测文本中是否包含明确的 Markdown 语法特征。
  static bool isMarkdown(String text) {
    if (text.trim().isEmpty) return false;

    final patterns = [
      // 标题：^#{1,6}\s+\S+
      RegExp(r'^#{1,6}\s+\S+', multiLine: true),
      // 待办任务清单：^[-*+]\s+\[[ xX]\]\s+
      RegExp(r'^\s*[-*+]\s+\[[ xX]\]\s+', multiLine: true),
      // 列表（无序/有序）：^[-*+]\s+\S+ 或 ^\d+\.\s+\S+
      RegExp(r'^\s*[-*+]\s+\S+', multiLine: true),
      RegExp(r'^\s*\d+\.\s+\S+', multiLine: true),
      // 引用块：^>\s+\S+
      RegExp(r'^\s*>\s+\S+', multiLine: true),
      // 代码块：``` 或 ~~~
      RegExp(r'^(```|~~~)', multiLine: true),
      // 行内代码：`...`
      RegExp(r'`[^`\n]+`'),
      // 超链接与图片：[text](url) 或 ![alt](url)
      RegExp(r'!?\[[^\]\n]+\]\([^)\n]+\)'),
      // 行内加粗/删除线：**bold** 或 ~~del~~
      RegExp(r'(\*\*|~~)[^\s\n][^\n]*?\1'),
      // 水平分割线：^---+$ 或 ^===+$ 或 ^\*\*\*+$
      RegExp(r'^\s*([-*_])(?:\s*\1){2,}\s*$', multiLine: true),
      // 表格结构：| col | col |
      RegExp(r'^\|.+\|\s*$', multiLine: true),
    ];

    return patterns.any((p) => p.hasMatch(text));
  }

  /// 为 Markdown 渲染预处理换行符（实现类似 GFM breaks / Obsidian 的自然换行行为）：
  ///
  /// 为 Markdown 渲染预处理换行符（实现类似 GFM breaks / Obsidian 的自然换行行为）：
  ///
  /// 1. 保护代码块（``` ... ``` 或 ~~~ ... ~~~）内部原样输出，绝不追加行尾空格或注入实体；
  /// 2. 对代码块外部的非空行，若行尾未以双空格结尾，自动补齐两个空格（`  \n`）实现硬换行，
  ///    防止 CommonMark 规范默认将连续文本行合并压缩为一行；
  /// 3. 对代码块外部的空白行，注入 `&nbsp;  ` 占位，防止 Markdown AST 块级解析器将连续多个空行
  ///    折叠吞并为单个段落间距，100% 还原用户真实的连续空行排版。
  static String prepareMarkdownForRendering(String text) {
    if (text.isEmpty || !text.contains('\n')) {
      return text;
    }

    final lines = text.split('\n');
    final buffer = StringBuffer();
    bool inCodeBlock = false;
    String? codeFence;

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      final trimmed = line.trim();

      // 检查是否进入/退出代码块
      if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
        final fenceType = trimmed.substring(0, 3);
        if (!inCodeBlock) {
          inCodeBlock = true;
          codeFence = fenceType;
        } else if (codeFence == fenceType) {
          inCodeBlock = false;
          codeFence = null;
        }
        buffer.write(line);
      } else if (inCodeBlock) {
        // 代码块内部：严格保持原样，不追加任何多余空格或实体
        buffer.write(line);
      } else {
        // 普通文本/Markdown 段落：
        if (line.isEmpty || trimmed.isEmpty) {
          // 空白行：插入 &nbsp; 防止 Markdown 引擎折叠连续多个空行
          if (i < lines.length - 1) {
            buffer.write('&nbsp;  ');
          } else {
            buffer.write('&nbsp;');
          }
        } else {
          // 非空行：若不是最后一行且未以双空格结尾，追加两个空格以产生硬换行
          if (i < lines.length - 1 && !line.endsWith('  ')) {
            buffer.write('$line  ');
          } else {
            buffer.write(line);
          }
        }
      }

      if (i < lines.length - 1) {
        buffer.write('\n');
      }
    }

    return buffer.toString();
  }

  /// 行内包裹与智能解包（如加粗、斜体、删除线、行内代码）。
  ///
  /// - 若选区外部或内部已被 [prefix] 和 [suffix] 包裹，则执行**解包**（Unwrap）；
  /// - 若有选区且未包裹，则在前后追加 [prefix] 与 [suffix]，并保持选区在包裹后的内容上；
  /// - 若光标折叠（未选中），插入 `$prefix$suffix` 并将光标定位于中间。
  static TextEditingValue wrapSelection(
    TextEditingValue value, {
    required String prefix,
    required String suffix,
    String? placeholder,
  }) {
    final text = value.text;
    final sel = value.selection;

    if (!sel.isValid) {
      final inserted = '$prefix${placeholder ?? ''}$suffix';
      return TextEditingValue(
        text: text + inserted,
        selection: TextSelection.collapsed(offset: text.length + prefix.length),
      );
    }

    final int start = min(sel.start, sel.end);
    final int end = max(sel.start, sel.end);

    // 1. 选区折叠（未选中文本）
    if (start == end) {
      // 检查光标当前是否恰好处在 prefix 与 suffix 中间（例如 `**|**`）
      final bool insidePrefix =
          start >= prefix.length &&
          text.substring(start - prefix.length, start) == prefix;
      final bool insideSuffix =
          end + suffix.length <= text.length &&
          text.substring(end, end + suffix.length) == suffix;

      if (insidePrefix && insideSuffix) {
        // 光标在定界符中间，再次点击则解包删除两边的定界符
        final newText = text.replaceRange(
          start - prefix.length,
          end + suffix.length,
          '',
        );
        return TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: start - prefix.length),
        );
      }

      final String content = placeholder ?? '';
      final newText = text.replaceRange(start, end, '$prefix$content$suffix');
      final newCursor = start + prefix.length;
      return TextEditingValue(
        text: newText,
        selection: placeholder != null && placeholder.isNotEmpty
            ? TextSelection(
                baseOffset: newCursor,
                extentOffset: newCursor + placeholder.length,
              )
            : TextSelection.collapsed(offset: newCursor),
      );
    }

    // 2. 有选中区域：优先检查是否已经被外部包裹
    final selectedText = text.substring(start, end);

    // 2.1 选区内部刚好包含定界符（如选中了 `**abc**`）
    if (selectedText.startsWith(prefix) &&
        selectedText.endsWith(suffix) &&
        selectedText.length >= prefix.length + suffix.length) {
      final inner = selectedText.substring(
        prefix.length,
        selectedText.length - suffix.length,
      );
      final newText = text.replaceRange(start, end, inner);
      return TextEditingValue(
        text: newText,
        selection: TextSelection(
          baseOffset: start,
          extentOffset: start + inner.length,
        ),
      );
    }

    // 2.2 选区外部刚好紧邻定界符（如选区是 `abc`，但前后是 `**abc**`）
    final bool outerHasPrefix =
        start >= prefix.length &&
        text.substring(start - prefix.length, start) == prefix;
    final bool outerHasSuffix =
        end + suffix.length <= text.length &&
        text.substring(end, end + suffix.length) == suffix;

    if (outerHasPrefix && outerHasSuffix) {
      // 移除外部定界符
      final newText = text.replaceRange(
        start - prefix.length,
        end + suffix.length,
        selectedText,
      );
      final newStart = start - prefix.length;
      return TextEditingValue(
        text: newText,
        selection: TextSelection(
          baseOffset: newStart,
          extentOffset: newStart + selectedText.length,
        ),
      );
    }

    // 2.3 正常包裹
    final newContent = '$prefix$selectedText$suffix';
    final newText = text.replaceRange(start, end, newContent);
    return TextEditingValue(
      text: newText,
      selection: TextSelection(
        baseOffset: start + prefix.length,
        extentOffset: start + prefix.length + selectedText.length,
      ),
    );
  }

  /// 切换标题（# H1 - ###### H6）。
  ///
  /// - [targetLevel]：目标层级 (1~6)。若当前行已有该层级标题，则清除标题；若为不同层级，则替换；
  /// - 若 [targetLevel] 为 null，则采用轮换模式：无标题 -> H1 -> H2 -> H3 -> 无标题。
  static TextEditingValue toggleHeading(
    TextEditingValue value, {
    int? targetLevel,
  }) {
    return _modifyCoveredLines(value, (lines) {
      return lines.map((line) {
        final match = _headingPrefixRegex.firstMatch(line);
        final currentHashCount = match != null
            ? line.substring(0, match.end).trim().length
            : 0;

        if (targetLevel != null) {
          final targetPrefix = '${'#' * targetLevel} ';
          if (currentHashCount == targetLevel) {
            // 已是目标标题，清除
            return line.substring(match!.end).trimLeft();
          } else if (currentHashCount > 0) {
            // 替换现有标题层级
            return '$targetPrefix${line.substring(match!.end).trimLeft()}';
          } else {
            // 清理其他可能的列表前缀后再加标题
            final cleanLine = _stripAnyListPrefix(line);
            return '$targetPrefix$cleanLine';
          }
        } else {
          // 轮换模式：0 -> 1 -> 2 -> 3 -> 0
          if (currentHashCount == 0) {
            return '# ${_stripAnyListPrefix(line)}';
          } else if (currentHashCount == 1) {
            return '## ${line.substring(match!.end).trimLeft()}';
          } else if (currentHashCount == 2) {
            return '### ${line.substring(match!.end).trimLeft()}';
          } else {
            return line.substring(match!.end).trimLeft();
          }
        }
      }).toList();
    });
  }

  /// 切换无序列表 (`- `) 或有序列表 (`1. `, `2. `...)。
  static TextEditingValue toggleList(
    TextEditingValue value, {
    required bool ordered,
  }) {
    return _modifyCoveredLines(value, (lines) {
      // 判断当前行是否已全是有序/无序列表
      final bool allMatch = lines.every((line) {
        if (ordered) {
          return _orderedListPrefixRegex.hasMatch(line);
        } else {
          return _unorderedListPrefixRegex.hasMatch(line) &&
              !_taskListPrefixRegex.hasMatch(line);
        }
      });

      if (allMatch) {
        // 全部已有该类型列表，取消列表
        return lines.map((line) {
          final regex = ordered
              ? _orderedListPrefixRegex
              : _unorderedListPrefixRegex;
          final match = regex.firstMatch(line);
          return match != null ? line.substring(match.end) : line;
        }).toList();
      }

      // 添加或替换为列表
      final result = <String>[];
      for (int i = 0; i < lines.length; i++) {
        final line = lines[i];
        final clean = _stripAnyPrefix(line);
        if (ordered) {
          result.add('${i + 1}. $clean');
        } else {
          result.add('- $clean');
        }
      }
      return result;
    });
  }

  /// 切换任务待办列表 (`- [ ] ` ↔ `- [x] ` ↔ 清除)。
  static TextEditingValue toggleTaskList(TextEditingValue value) {
    return _modifyCoveredLines(value, (lines) {
      final bool allAreTasks = lines.every(
        (line) => _taskListPrefixRegex.hasMatch(line),
      );

      if (allAreTasks) {
        // 检查是否全为未完成
        final bool allUnchecked = lines.every(
          (line) => line.startsWith('- [ ] '),
        );
        if (allUnchecked) {
          // 全部切为已完成 - [x]
          return lines.map((line) {
            final match = _taskListPrefixRegex.firstMatch(line);
            return '- [x] ${line.substring(match!.end)}';
          }).toList();
        } else {
          // 清除任务前缀
          return lines.map((line) {
            final match = _taskListPrefixRegex.firstMatch(line);
            return match != null ? line.substring(match.end) : line;
          }).toList();
        }
      }

      // 添加任务待办前缀
      return lines.map((line) {
        final clean = _stripAnyPrefix(line);
        return '- [ ] $clean';
      }).toList();
    });
  }

  /// 切换引用块 (`> `)。
  static TextEditingValue toggleBlockquote(TextEditingValue value) {
    return _modifyCoveredLines(value, (lines) {
      final bool allAreQuotes = lines.every(
        (line) => _quotePrefixRegex.hasMatch(line),
      );

      if (allAreQuotes) {
        // 取消引用
        return lines.map((line) {
          final match = _quotePrefixRegex.firstMatch(line);
          return match != null ? line.substring(match.end) : line;
        }).toList();
      } else {
        // 添加引用
        return lines.map((line) {
          final match = _quotePrefixRegex.firstMatch(line);
          return match == null ? '> $line' : line;
        }).toList();
      }
    });
  }

  /// 插入代码块（```）。
  static TextEditingValue insertCodeBlock(
    TextEditingValue value, {
    String language = '',
  }) {
    final text = value.text;
    final sel = value.selection;
    final int start = sel.isValid ? min(sel.start, sel.end) : text.length;
    final int end = sel.isValid ? max(sel.start, sel.end) : text.length;

    if (start != end) {
      // 选中了多行文本，将其包裹在代码块中
      final selectedText = text.substring(start, end);
      final newContent = '```$language\n$selectedText\n```\n';
      final newText = text.replaceRange(start, end, newContent);
      return TextEditingValue(
        text: newText,
        selection: TextSelection(
          baseOffset: start + 4 + language.length,
          extentOffset: start + 4 + language.length + selectedText.length,
        ),
      );
    } else {
      // 未选中文本：插入空代码块并把光标定位于内部
      final prefix = '```$language\n';
      const suffix = '\n```\n';
      final newText = text.replaceRange(start, end, '$prefix$suffix');
      final newOffset = start + prefix.length;
      return TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: newOffset),
      );
    }
  }

  /// 插入超链接 `[text](url)`。
  static TextEditingValue insertLink(
    TextEditingValue value, {
    String? defaultUrl,
  }) {
    final text = value.text;
    final sel = value.selection;
    final int start = sel.isValid ? min(sel.start, sel.end) : text.length;
    final int end = sel.isValid ? max(sel.start, sel.end) : text.length;

    final url = defaultUrl ?? 'url';

    if (start != end) {
      final selected = text.substring(start, end);
      final newContent = '[$selected]($url)';
      final newText = text.replaceRange(start, end, newContent);
      final urlStart = start + selected.length + 3;
      return TextEditingValue(
        text: newText,
        selection: TextSelection(
          baseOffset: urlStart,
          extentOffset: urlStart + url.length,
        ),
      );
    } else {
      const title = 'text';
      final newContent = '[$title]($url)';
      final newText = text.replaceRange(start, end, newContent);
      return TextEditingValue(
        text: newText,
        selection: TextSelection(
          baseOffset: start + 1,
          extentOffset: start + 1 + title.length,
        ),
      );
    }
  }

  /// 插入水平分割线 `\n---\n`。
  static TextEditingValue insertHorizontalRule(TextEditingValue value) {
    final text = value.text;
    final sel = value.selection;
    final int start = sel.isValid ? min(sel.start, sel.end) : text.length;
    final int end = sel.isValid ? max(sel.start, sel.end) : text.length;

    final bool needsLeadingNewline = start > 0 && !text.endsWith('\n');
    final String divider = '${needsLeadingNewline ? '\n' : ''}---\n';
    final newText = text.replaceRange(start, end, divider);
    final newOffset = start + divider.length;

    return TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newOffset),
    );
  }

  // --- 内部辅助算法 ---

  /// 清理行首的所有已知块级前缀（标题、待办、列表、引用）
  static String _stripAnyPrefix(String line) {
    var result = line;
    if (_headingPrefixRegex.hasMatch(result)) {
      result = result.substring(_headingPrefixRegex.firstMatch(result)!.end);
    } else if (_taskListPrefixRegex.hasMatch(result)) {
      result = result.substring(_taskListPrefixRegex.firstMatch(result)!.end);
    } else if (_orderedListPrefixRegex.hasMatch(result)) {
      result = result.substring(
        _orderedListPrefixRegex.firstMatch(result)!.end,
      );
    } else if (_unorderedListPrefixRegex.hasMatch(result)) {
      result = result.substring(
        _unorderedListPrefixRegex.firstMatch(result)!.end,
      );
    } else if (_quotePrefixRegex.hasMatch(result)) {
      result = result.substring(_quotePrefixRegex.firstMatch(result)!.end);
    }
    return result;
  }

  /// 清理行首的列表类前缀
  static String _stripAnyListPrefix(String line) {
    var result = line;
    if (_taskListPrefixRegex.hasMatch(result)) {
      result = result.substring(_taskListPrefixRegex.firstMatch(result)!.end);
    } else if (_orderedListPrefixRegex.hasMatch(result)) {
      result = result.substring(
        _orderedListPrefixRegex.firstMatch(result)!.end,
      );
    } else if (_unorderedListPrefixRegex.hasMatch(result)) {
      result = result.substring(
        _unorderedListPrefixRegex.firstMatch(result)!.end,
      );
    }
    return result;
  }

  /// 提取选区覆盖的所有行，由 [transform] 处理后重新拼接，并精准重新映射选区。
  static TextEditingValue _modifyCoveredLines(
    TextEditingValue value,
    List<String> Function(List<String> lines) transform,
  ) {
    final text = value.text;
    final sel = value.selection;

    if (text.isEmpty) {
      final transformed = transform(['']);
      final newText = transformed.join('\n');
      return TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: newText.length),
      );
    }

    final int start = sel.isValid ? min(sel.start, sel.end) : text.length;
    final int end = sel.isValid ? max(sel.start, sel.end) : text.length;

    // 寻找起始行的行首
    int lineStartIndex = text.lastIndexOf('\n', max(0, start - 1));
    lineStartIndex = lineStartIndex == -1 ? 0 : lineStartIndex + 1;

    // 寻找结束行的行尾
    int lineEndIndex = text.indexOf('\n', end);
    lineEndIndex = lineEndIndex == -1 ? text.length : lineEndIndex;

    final coveredText = text.substring(lineStartIndex, lineEndIndex);
    final lines = coveredText.split('\n');
    final transformedLines = transform(lines);
    final newCoveredText = transformedLines.join('\n');

    final newText = text.replaceRange(
      lineStartIndex,
      lineEndIndex,
      newCoveredText,
    );

    // 调整选区
    final lengthDiff = newCoveredText.length - coveredText.length;
    int newStart = start;
    int newEnd = end;

    if (start == end) {
      // 折叠光标：顺延位移，但不超出被修改行的范围
      newStart = min(newText.length, max(lineStartIndex, start + lengthDiff));
      newEnd = newStart;
    } else {
      newEnd = min(newText.length, max(lineStartIndex, end + lengthDiff));
    }

    return TextEditingValue(
      text: newText,
      selection: TextSelection(baseOffset: newStart, extentOffset: newEnd),
    );
  }
}

/// Markdown 列表智能回车自动续行与递增 Formatter。
///
/// 当用户在列表（有序/无序/待办/引用）行末按回车键时：
/// 1. 若当前行有内容，自动在下一行续上相同列表项前缀（有序列表序号自动递增 1. -> 2. -> 3.）；
/// 2. 若当前行前缀后为空内容，再次回车则自动清空该前缀并退出列表模式。
class MarkdownAutoIndentFormatter extends TextInputFormatter {
  const MarkdownAutoIndentFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text.length <= oldValue.text.length) {
      return newValue;
    }

    final oldSel = oldValue.selection;
    final newSel = newValue.selection;

    if (!oldSel.isValid || !newSel.isValid) {
      return newValue;
    }

    // 检查新增的字符数是否为 1（即单次回车敲击）
    final int insertedLength = newValue.text.length - oldValue.text.length;
    if (insertedLength != 1) {
      return newValue;
    }

    final int insertPos = oldSel.isCollapsed
        ? oldSel.start
        : min(oldSel.start, oldSel.end);
    if (insertPos < 0 || insertPos >= newValue.text.length) {
      return newValue;
    }

    // 确认插入的字符确为换行符 '\n'
    if (newValue.text[insertPos] != '\n') {
      return newValue;
    }

    // 获取换行发生前所在行的完整内容
    final int lineStart =
        oldValue.text.lastIndexOf('\n', max(0, insertPos - 1)) == -1
        ? 0
        : oldValue.text.lastIndexOf('\n', max(0, insertPos - 1)) + 1;
    final String prevLine = oldValue.text.substring(lineStart, insertPos);

    // 1. 有序列表：如 "1. "、"  2. "
    final orderedMatch = RegExp(r'^(\s*)(\d+)\.\s*(.*)$').firstMatch(prevLine);
    if (orderedMatch != null) {
      final indent = orderedMatch.group(1) ?? '';
      final num = int.tryParse(orderedMatch.group(2) ?? '1') ?? 1;
      final rest = orderedMatch.group(3) ?? '';

      if (rest.trim().isEmpty) {
        // 当前行只有 "1. "，再次回车则清除该前缀退出列表
        final newText = oldValue.text.replaceRange(lineStart, insertPos, '');
        return TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: lineStart),
        );
      } else {
        // 自动递增下一行序号
        final nextPrefix = '$indent${num + 1}. ';
        final newText = newValue.text.replaceRange(
          insertPos + 1,
          insertPos + 1,
          nextPrefix,
        );
        final newOffset = insertPos + 1 + nextPrefix.length;
        return TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: newOffset),
        );
      }
    }

    // 2. 待办清单：如 "- [ ] "、"- [x] "、"  - [ ] "
    final taskMatch = RegExp(
      r'^(\s*[-*+]\s+\[[ xX]\])\s*(.*)$',
    ).firstMatch(prevLine);
    if (taskMatch != null) {
      final rest = taskMatch.group(2) ?? '';

      if (rest.trim().isEmpty) {
        // 清空前缀退出待办
        final newText = oldValue.text.replaceRange(lineStart, insertPos, '');
        return TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: lineStart),
        );
      } else {
        final indentMatch = RegExp(r'^(\s*)').firstMatch(prevLine);
        final indent = indentMatch?.group(1) ?? '';
        final nextPrefix = '$indent- [ ] ';
        final newText = newValue.text.replaceRange(
          insertPos + 1,
          insertPos + 1,
          nextPrefix,
        );
        final newOffset = insertPos + 1 + nextPrefix.length;
        return TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: newOffset),
        );
      }
    }

    // 3. 无序列表：如 "- "、"* "、"+ "、"  - "
    final unorderedMatch = RegExp(
      r'^(\s*)([-*+])\s*(.*)$',
    ).firstMatch(prevLine);
    if (unorderedMatch != null) {
      final indent = unorderedMatch.group(1) ?? '';
      final bullet = unorderedMatch.group(2) ?? '-';
      final rest = unorderedMatch.group(3) ?? '';

      if (rest.trim().isEmpty) {
        // 清空前缀退出列表
        final newText = oldValue.text.replaceRange(lineStart, insertPos, '');
        return TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: lineStart),
        );
      } else {
        // 自动续行无序列表
        final nextPrefix = '$indent$bullet ';
        final newText = newValue.text.replaceRange(
          insertPos + 1,
          insertPos + 1,
          nextPrefix,
        );
        final newOffset = insertPos + 1 + nextPrefix.length;
        return TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: newOffset),
        );
      }
    }

    // 4. 引用：如 "> "、">> "
    final quoteMatch = RegExp(r'^(\s*>+)\s*(.*)$').firstMatch(prevLine);
    if (quoteMatch != null) {
      final prefix = quoteMatch.group(1) ?? '>';
      final rest = quoteMatch.group(2) ?? '';

      if (rest.trim().isEmpty) {
        final newText = oldValue.text.replaceRange(lineStart, insertPos, '');
        return TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: lineStart),
        );
      } else {
        final nextPrefix = '$prefix ';
        final newText = newValue.text.replaceRange(
          insertPos + 1,
          insertPos + 1,
          nextPrefix,
        );
        final newOffset = insertPos + 1 + nextPrefix.length;
        return TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: newOffset),
        );
      }
    }

    return newValue;
  }
}
