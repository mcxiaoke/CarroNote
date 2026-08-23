# 简易富文本支持方案（纯文本预览轻量排版）

> 状态：设计修订完成，未动代码
> 创建时间：2026-08-23（GMT+8）
> 最近修订：2026-08-23（针对解析器嵌套死穴、Flutter 复制机制、中文词法边界及方案选型进行全面重构）
> 关联：`lib/views/add_edit_note.dart:647` 预览分支 / `lib/utils/editor_text.dart:29` 笔记样式 / `lib/data/preference_and_config.dart:475` Markdown 开关 / `docs/note-style-enhancement-plan.md` 笔记样式双轨 / `docs/FEATURE-EVAL-5ITEMS-20260823.md`

---

## 0. 摘要

在「Markdown 关闭时的纯文本预览」中，支持**少数 Markdown 常用符号的可视化轻量排版**（多级标题、粗体、斜体、删除线、列表、下划线），使关闭 Markdown 的用户无需面对沉重的排版体系，仍能通过手写简单符号获得清晰的视觉层次感；打开 Markdown 的用户保持全量特性不受任何影响。

**结论与选型决策：**

1. **主推方案：方案 C（`package:markdown` AST 白名单 + `SimpleTextSpanVisitor`）**
   - 依赖项目中已自带的 `package:markdown`，配置白名单语法规则，禁用表格/代码块/引用/HTML/链接等重型语法；
   - 通过仅 ~80 行的 AST Visitor 遍历生成 `TextSpan` 树；
   - **彻底规避手写正则在样式嵌套（如 `**加粗 ~~删除~~**`）、中文标点词法边界守卫、转义字符等方面的工业级边界陷阱**。
2. **备选方案：方案 B（纯手写递归 Tokenizer / 字符状态机）**
   - 弃用扁平单遍正则顺序扫描（存在嵌套断裂死穴），改用递归下降或双指针扫描；
3. **托底方案：方案 A（复用 `MarkdownBody` 套极简 `MarkdownStyleSheet`）**
   - 30 行快速兜底，代价是无法完全屏蔽未授权语法。

**分期节奏：**
- **一期（1-2 人日）**：标题（H1-H6）+ 粗体 + 删除线，基于 AST 模式直出，零歧义；
- **二期（+1 人日）**：列表（无序/有序）+ 斜体（严格对齐 CommonMark 边界规则）；
- **下划线单独立项**：标准 Markdown 无下划线语法，需定 `++text++` 规范后视需求落地。

所有方案均严格遵守 **E2EE 与存储寻址红线**：不触碰 `SafeNote`、`computeHash`、`toContentBytes` 及同步链路。

---

## 1. 背景与现状

### 1.1 现有两条预览链路

`lib/views/add_edit_note.dart:647` 的 `_buildPreview`：

```dart
if (PreferencesStorage.isMarkdownEnabled) // lib/data/preference_and_config.dart:475
  MarkdownBody(data: description, styleSheet: _markdownStyleSheet(context), ...) // :674
else
  SelectableText(description, style: _editorLikeStyle(context, EditorText.body())) // :693
```

| 模式 | 组件 | 样式来源 | 排版能力 | 用户预期 |
|------|------|----------|----------|----------|
| Markdown 开启 | `MarkdownBody` (`flutter_markdown_plus: ^1.0.12`, `pubspec.yaml:61`) | `_markdownStyleSheet` (`:736`) 固定标题层级 24/20/18/17/16，blockquote/code 单独样式 | 全量 Markdown（标题/列表/引用/代码/表格/链接） | 享受完整 Markdown 排版 |
| Markdown 关闭 | `SelectableText` | `_editorLikeStyle` + `EditorText.body()/title()` (`lib/utils/editor_text.dart:153`) 跟随笔记样式（字号/行高/对齐/字体） | **零排版**，纯字面量渲染 | 避免复杂排版干扰，但手写层级符号阅读体验素淡 |

`EditorText` 已实现笔记样式双轨（`docs/note-style-enhancement-plan.md`）：正文字号 4 档、行高 4 档、对齐 3 档、字体 4 档，`SelectableText` 通过 `textAlign: EditorText.textAlign` 与编辑态对齐。

### 1.2 核心诉求与边界

- **诉求**：关闭 Markdown 的用户手写 `# 标题` / `**重点**` / `- 清单` 时，在预览中希望获得适度视觉层次，而不是满屏原始符号；
- **边界控制**：绝不引入代码块高亮、HTML 标签、网络图片、外链解析、表格等重型特性，严格限定在极简文本排版子集内；
- **正交叠加**：简易排版必须与 `EditorText` 的自定义字号、行高、对齐、字体体系完全融合叠加。

---

## 2. 目标与非目标

### 2.1 目标（白名单子集）

在 `isMarkdownEnabled == false` 分支内，使下列白名单符号产生对应的视觉样式，且与 `EditorText` 样式完全叠加：

| 符号 | 源码示例 | 预览样式 | 嵌套支持 |
|------|----------|----------|----------|
| 多级标题 | `# 一级` / `## 二级` / `### 三级` | 字号 24/20/18（h4+ 回落正文字号+粗体），`FontWeight.w700` | 内部可嵌套行内加粗/删除线/斜体 |
| 粗体 | `**粗体**` | `FontWeight.w700` | 可与删除线/斜体互相嵌套 |
| 删除线 | `~~删除~~` | `TextDecoration.lineThrough` | 可与粗体/斜体互相嵌套 |
| 斜体 | `*斜体*` | `FontStyle.italic` | 严格词法边界，防公式/通配符误判 |
| 列表 | `- 项目` / `* 项目` / `1. 项目` | 行首 `• ` / `1. ` 渲染 | 内部可嵌套行内样式 |
| 下划线 | 待定（如 `++下划线++`） | `TextDecoration.underline` | 需独立立项避免语法冲突 |

### 2.2 非目标

- **不改存储与加密**：仍为 `title`/`description` 纯明文字段加密（`database_handler.dart:457`），绝不改动 `safenote.dart:255` 的 `computeHash` 与 `toContentBytes`；
- **不做所见即所得编辑**：编辑态仍为轻量 `TextField` 纯文本（`lib/widgets/note_widget.dart:105`）；
- **不解析重型语法**：代码块、HTML、引用块、表格、网络/本地图片、URL 超链接在简易模式下一律按普通文本对待；
- **显式不接入历史版本页**：`lib/views/version_history_page.dart` 完整文本与 diff 视图均保持纯文本，绝不引入简易富文本渲染（避免破坏 Myers diff 字符级对齐与删除线双重语义，见 §5.4）。

---

## 3. 语法子集与词法规则定义

为确保纯文本下的符号不被滥用或误判，语法规则必须精确界定：

### 3.1 标题规则
- **行首判定**：必须满足 `^#{1,6}\s+`，即 `#` 必须处于行首，且与后方文本之间**必须至少有一个空格**；
- **防误判**：行中的 `#`、无空格的 `#tag`、编程语言预编译指令 `#include <stdio.h>` **严禁**识别为标题；
- **标题内行内样式**：标题文本支持继续解析粗体、删除线等（如 `# 核心 **重点** 事项`）。

### 3.2 行内样式与嵌套规则
- **优先级与嵌套**：行内样式必须支持任意嵌套（如 `**加粗 ~~删除~~ 混合**`，`~~删除中包含 **加粗**~~`，`***粗斜体***`）；
- **单行闭合约束**：首版行内标记仅在单行内闭合，不允许跨段落跨换行包裹，降低异常未闭合标记对整篇排版的污染；
- **转义支持**：`\*`、`\~` 前置反斜杠时转义为字面量字符，不触发样式解析；
- **斜体边界守卫（CJK 与标点兼容）**：
  - CommonMark 规范中，单星号 `*` 的开启要求左侧不能是空白字符且（如果左侧是标点，右侧不能是普通字母/汉字）；
  - 严禁使用简单的 ASCII `(?<!\w)` 守卫，否则在中文语境下（如 `汉字*斜体*汉字` 或 `5件*3箱`）会出现 ASCII 词边界失效导致的误判或漏判；
  - 借助工业级 CommonMark 词法器（方案 C）可完美解决该问题。

### 3.3 列表规则
- **无序列表**：行首 `^\s*[-*+]\s+`，渲染为 `• ` 前缀；
- **有序列表**：行首 `^\s*\d+\.\s+`，渲染为原数字 + `. ` 前缀；
- **悬挂缩进（Hanging Indent）说明**：
  - 在单个 `SelectableText.rich` 中，纯文本前缀无法天然提供块级悬挂缩进；当列表项跨多行折行时，次行会顶格排版。
  - 简易预览模式接受此轻量视觉折中，如需完美块级缩进与任务清单，建议开启全量 Markdown 模式。

### 3.4 下划线说明
- 标准 Markdown（GFM/CommonMark）中 `__text__` 为粗体，无原生下划线标记；
- 若引入自定义 `++text++`，需在文档与工具栏中明确约定；
- **建议**：v1 不做下划线，保持 5 种核心语法纯粹性。

---

## 4. 三大方案深入对比与选型

| 维度 | 方案 A：`MarkdownBody` 套极简 StyleSheet | 方案 B：手写递归 Tokenizer + `SelectableText.rich` | 方案 C：`package:markdown` AST 白名单 + Visitor（推荐） |
|------|-----------------------------------------|----------------------------------------------------|---------------------------------------------------------|
| **核心机制** | 强制使用 `MarkdownBody`，将无用语法样式全部 reset 为 base | 手写递归/状态机分块分词，手动构造 `TextSpan` 树 | 利用 `md.Document` 仅挂载白名单 Syntax，通过 AST Visitor 生成 `TextSpan` 树 |
| **代码量** | ~30 行（新建样式表） | ~250-400 行（分词器 + 状态栈 + Widget） | ~80-120 行（白名单配置 + `NodeVisitor` 实现） |
| **嵌套与边界健壮性** | 高（引擎原生支持） | **极差/高风险**（手写状态机易遗漏边界与中文标点 edge cases） | **极高**（复用经过 CommonMark 工业验证的词法 AST） |
| **语法精确白名单** | **差**（代码块、引用、表格仍会被 AST 结构化解析） | **优**（完全由白名单代码控制） | **优**（`blockSyntaxes`/`inlineSyntaxes` 精确配置，未配置语法一律输出为普通文本） |
| **与 `EditorText` 样式叠加** | 需在 StyleSheet 中繁琐配置各层级，部分属性存在穿透差异 | 天然直接继承 `EditorText.body()` | 天然直接继承 `EditorText.body()`，在 Visitor 中派生 TextStyle |
| **复制交互一致性** | 跨块选中与换行可能存在 MarkdownBody 特有微调 | 原生 `SelectableText.rich` | 原生 `SelectableText.rich` |
| **依赖与维护风险** | 无额外依赖 | 无额外依赖，但维护算法用例成本高 | 项目已自带 `flutter_markdown_plus`（内置 `markdown`），无新增外置包，AST 结构极稳定 |
| **综合评分** | ★★★☆☆ (兜底可行，但有副作用) | ★★★☆☆ (开发与排错成本过高) | ★★★★★ (**最优解：代码精简、零语法溢出、零边界 Bug**) |

**选型决策：全面采纳【方案 C】作为首选主干方案；保留【方案 A】作为极端情况下的 1 小时兜底；放弃【方案 B】避免重复造脆弱的正则/分词轮子。**

---

## 5. 方案实现细化

### 5.1 方案 C 实现（推荐主推）

#### 5.1.1 架构分层
```
lib/utils/simple_richtext_visitor.dart  // 纯 Dart：AST Visitor，将 md.Node 树转换为 Flutter TextSpan 树
lib/widgets/simple_richtext_preview.dart // Flutter Widget：封装 SelectableText.rich
lib/views/add_edit_note.dart:690        // 接线点：替换原有的纯 SelectableText
```

#### 5.1.2 纯 Dart AST Visitor 实现核心

```dart
import 'package:flutter/material.dart';
import 'package:markdown/markdown.dart' as md;

class SimpleTextSpanVisitor implements md.NodeVisitor {
  final TextStyle baseStyle;
  final List<TextSpan> _spans = [];
  final List<TextStyle> _styleStack = [];

  SimpleTextSpanVisitor({required this.baseStyle});

  TextSpan buildSpans(List<md.Node> nodes) {
    _spans.clear();
    _styleStack.clear();
    _styleStack.add(baseStyle);
    
    for (final node in nodes) {
      node.accept(this);
    }
    return TextSpan(children: List.of(_spans));
  }

  TextStyle get _currentStyle => _styleStack.last;

  @override
  bool visitElementBefore(md.Element element) {
    var nextStyle = _currentStyle;
    
    switch (element.tag) {
      case 'h1':
        nextStyle = _currentStyle.copyWith(fontSize: 24, fontWeight: FontWeight.w700);
      case 'h2':
        nextStyle = _currentStyle.copyWith(fontSize: 20, fontWeight: FontWeight.w700);
      case 'h3':
        nextStyle = _currentStyle.copyWith(fontSize: 18, fontWeight: FontWeight.w700);
      case 'h4':
      case 'h5':
      case 'h6':
        nextStyle = _currentStyle.copyWith(fontWeight: FontWeight.w700);
      case 'strong':
        nextStyle = _currentStyle.copyWith(fontWeight: FontWeight.w700);
      case 'em':
        nextStyle = _currentStyle.copyWith(fontStyle: FontStyle.italic);
      case 'del':
        nextStyle = _currentStyle.copyWith(
          decoration: TextDecoration.combine([
            if (_currentStyle.decoration != null) _currentStyle.decoration!,
            TextDecoration.lineThrough,
          ]),
        );
      case 'li':
        _spans.add(TextSpan(text: '• ', style: baseStyle));
    }
    
    _styleStack.add(nextStyle);
    return true;
  }

  @override
  void visitText(md.Text text) {
    _spans.add(TextSpan(text: text.text, style: _currentStyle));
  }

  @override
  void visitElementAfter(md.Element element) {
    _styleStack.removeLast();
    // 块级元素结束后追加换行（标题与段落后补空行保持间距）
    if (['p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'li'].contains(element.tag)) {
      _spans.add(const TextSpan(text: '\n'));
      if (element.tag.startsWith('h') || element.tag == 'p') {
        _spans.add(const TextSpan(text: '\n'));
      }
    }
  }
}
```

#### 5.1.3 白名单 Document 解析与 Widget 封装

```dart
class SimpleRichTextPreview extends StatelessWidget {
  final String text;
  final TextStyle baseStyle;
  final TextAlign textAlign;

  const SimpleRichTextPreview({
    super.key,
    required this.text,
    required this.baseStyle,
    required this.textAlign,
  });

  @override
  Widget build(BuildContext context) {
    // 仅挂载严格白名单 Syntax，其余未声明语法（表格、代码块等）自动回退为纯文本
    final document = md.Document(
      extensionSet: md.ExtensionSet.none,
      blockSyntaxes: [
        const md.HeaderSyntax(),
        const md.UnorderedListSyntax(),
        const md.OrderedListSyntax(),
      ],
      inlineSyntaxes: [
        md.EmphasisSyntax.asterisk(), // 仅支持 *粗体* 与 **粗体**
        md.StrikethroughSyntax(),     // ~~删除线~~
      ],
    );

    final lines = text.replaceAll('\r\n', '\n').split('\n');
    final nodes = document.parseLines(lines);
    final visitor = SimpleTextSpanVisitor(baseStyle: baseStyle);
    final spanTree = visitor.buildSpans(nodes);

    return SelectableText.rich(
      spanTree,
      style: baseStyle,
      textAlign: textAlign,
    );
  }
}
```

---

### 5.2 方案 B（手写状态机备选设计）

若环境不允许引入 AST 模块，手写解析器必须采用**递归下降扫描或双指针 Tokenizer**，严禁使用单遍正则顺序替换：

```
输入文本 -> 行扫描 Block 分离 -> 行内字符扫描 Token 流 -> 构建 Inline AST -> 输出 TextSpan
```
1. **Token 定义**：`TextToken`、`DelimiterToken(type: bold|strike|italic, state: open|close)`；
2. **栈匹配**：扫描到定界符时入栈匹配最近闭合符，匹配成功生成嵌套节点，匹配失败退化为普通文本；
3. **代价**：需手写约 300 行且需覆盖 CJK 边界测试用例，维护成本高。

---

### 5.3 方案 A（1 小时极速托底）

在 `lib/views/add_edit_note.dart` 内定义极简 `MarkdownStyleSheet`，将非白名单样式（表格、代码块边框等）全部透明化/重置为正文样式。
- **缺点**：语法依然会被全量解析为块级 Widget，无法阻止用户输入意外触发结构化排版。

---

### 5.4 历史版本页显式不接入（架构红线）

`lib/views/version_history_page.dart` **坚决不接入**任何简易富文本渲染，保持纯文本原貌：

```dart
// 完整版本视图 (version_history_page.dart:302)
SelectableText(version.description, style: EditorText.body()...)

// Diff 视图 (version_history_page.dart:324)
SelectableText.rich(TextSpan(children: segments.map(... diff 样式 ...)))
```

**原因与强约束：**
1. **历史真实性**：历史存档的唯一职责是还原数据库中存储的原始字面量，不进行二次排版解读；
2. **Diff 样式冲突**：`_DiffColors:51` 已占用 `deletionBg` + `TextDecoration.lineThrough`。若叠加富文本删除线与粗体，用户无法分辨“这是手写删除线”还是“被删除的内容”；
3. **对齐破坏**：标题字号放大与列表前缀插入会导致 Myers 字符级 diff 对齐错位，产生虚假变更视觉。

---

## 6. 交互与边界行为修正

- **选区与复制机制（关键修正）**：
  - 在 Flutter 中，`SelectableText.rich` 执行系统复制时，底层调用 `TextSpan.toPlainText()`；
  - **实际复制结果是“渲染后的可见文本”**（例如复制出的文本为 `标题` 与 `粗体`，不会携带 `# ` 或 `**` 标记）；
  - **用户预期对齐**：在预览模式下复制获得排版后的清洁文本，若需要获取 Markdown 源码，用户应当切回编辑态复制。
- **排版间距与行高**：
  - 标题 H1-H3 派生自 `EditorText.body()`，字号放大后继承相对行高；
  - 在 AST Visitor 遇到段落与标题闭合时，显式注入双换行 `\n\n`，保证大字号标题与正文之间具备清晰的纵向呼吸感。
- **无障碍与 RTL**：
  - `SelectableText.rich` 生成统一 TextSpan 语义树，屏幕朗读器无缝支持；
  - 列表 `• ` 前缀由 TextDirection 自动处理。

---

## 7. 测试策略与矩阵

| 层级 | 测试文件 | 关键用例与断言 |
|------|----------|----------------|
| **单元测试** | `test/simple_richtext_visitor_test.dart` | 1. 基础语法：`# h1`、`**bold**`、`~~strike~~`、`*italic*` 正确生成对应样式属性；<br>2. **嵌套语法**：`**加粗 ~~嵌套删除~~ 尾部**` 必须正确生成包含 strike 的加粗子 span；<br>3. **转义符号**：`\*not bold\*` 渲染为字面量字符；<br>4. **CJK 边界**：`中文*斜体*中文`、`5件*3箱` 正常解析/不误判；<br>5. **白名单拦截**：` ```代码块``` `、`> 引用`、`|表格|` 均作为普通文本渲染。 |
| **Widget 测试** | `test/simple_richtext_preview_test.dart` | 传入复杂混排文本，泵 `SimpleRichTextPreview`，验证 `SelectableText.rich` 内部 TextSpan 树的层级结构与 TextStyle 继承正确。 |
| **历史页防护** | `test/version_history_plain_test.dart` | 验证 `VersionHistoryPage` 在完整与 diff 模式下均保持纯文本，无富文本样式污染。 |
| **集成验证** | 命令行回归 | `flutter analyze` 零警告；`dart test packages/core/test` 全通；`flutter test` 全通；`flutter build windows --debug` 编译无误。 |

---

## 8. 落地规划与工作量

| 阶段 | 范围 | 工作量 | 交付成果 |
|------|------|--------|----------|
| **Phase 1（核心 MVP）** | 基于方案 C 实现 `SimpleTextSpanVisitor` + `SimpleRichTextPreview`，支持标题（H1-H6）、粗体、删除线，完成 `add_edit_note.dart` 接线与单元测试 | 1-1.5 人日 | 纯文本预览具备安全的核心排版能力，测试用例全覆盖 |
| **Phase 2（补齐列表与斜体）** | 挂载 `UnorderedListSyntax`、`OrderedListSyntax`、`EmphasisSyntax`，完成列表前缀注入与斜体词法调优 | 0.5-1 人日 | 完成 5 项核心 Markdown 子集支持 |
| **Phase 3（可选下划线）** | 自定义 `++underline++` InlineSyntax 扩展 | 0.5 人日 | 可选能力 |
| **托底保障** | 若 AST 模式遇到未预期阻碍，随时可启用方案 A（30 行 StyleSheet）快速上线 | 1 小时 | 无风险托底 |

---

## 9. 附录与修订记录

### 9.1 关联代码锚点
- `lib/views/add_edit_note.dart:647`（`_buildPreview` 预览装配点）
- `lib/utils/editor_text.dart:29`（`EditorText` 笔记双轨样式体系）
- `lib/views/version_history_page.dart:247`（历史版本完整视图与 diff 视图）
- `lib/data/preference_and_config.dart:475`（`isMarkdownEnabled` 偏好开关）

---

### 9.2 修订记录（Major Revision Log）

| 日期 | 修订类型 | 修订内容摘要与依据 |
|:---|:---|:---|
| **2026-08-23** | **架构与算法大改** | **1. 修正复制机制的 Flutter 底层事实**：修正原文档中“复制能还原带 `**`/`#` 源码”的事实性错误，明确 `SelectableText.rich` 底层调用 `toPlainText()` 复制出的是渲染后的可见文本，符合预览态用户心智。<br>**2. 重构解析器算法，主推方案 C（AST 白名单）**：指出原方案 B 顺序单遍正则扫描会导致嵌套样式（如 `**加粗 ~~删除~~**`）结构断裂的致命缺陷；将基于 `package:markdown` AST 白名单的方案 C 升级为第一推荐方案，代码量缩减 60% 且获得工业级 CommonMark 边界与嵌套保障。<br>**3. 解决 CJK 中文词法边界与公式误判**：针对正则 `\w` 无法识别中文词边界的问题，确立了严格对齐 CommonMark 的词法守卫规则。<br>**4. 完善排版与行间距细节**：补充列表在 `SelectableText.rich` 内无原生悬挂缩进的折中说明，并在 Visitor 块级闭合处优化段间距与大标题纵向行距。<br>**5. 保持并强化历史版本页红线**：保留并强化了版本历史页（完整文本与 Myers diff）绝对不接入简易富文本的架构约束。 |
| **2026-08-23** | 初版创建 | 初始方案起草，提出纯文本预览轻量排版设想与三方案对比。 |
