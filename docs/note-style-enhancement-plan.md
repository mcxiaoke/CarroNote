# 笔记样式增强方案（Note Style Enhancement Plan）

> 目的：把「双轨字体 + 笔记样式扩展」的完整方案落盘，避免对话上下文丢失。
> 创建时间：2026-08-22（GMT+8）
> 状态：方案阶段，**未动代码**，仅设计。
> 关联文档：`docs/design-editor-font-size-setting.md`（原编辑器字号方案，本方案在其基础上演进）。

---

## 0. 摘要

把当前设置里**唯一**的「Font style」入口（一个页面同时含"字体类型=全局"与"字体大小=仅笔记"）拆成**双轨**：

| 入口 | 作用范围 | 存储键 |
|------|----------|--------|
| **字体设置**（新增，全局） | 字体类型对整个 App 生效 | `fontFamilyTypeIndex`（已有） |
| **笔记样式**（原「Font style」改名，仅笔记） | 字体类型 + 字号 + 行高 + 对齐，只作用于笔记编辑/纯文本预览 | `noteFontFamilyTypeIndex`（新增）+ `editorFontSizeIndex`（已有）+ 新增排版键 |

**v1 排版增强**：行高（仅正文）、正文对齐。段间距与首行缩进因 TextField / SelectableText 无原生 API 支持移至 v2（详见 §8）。

**Markdown 预览独立**：不跟随笔记样式，只跟随全局字体，`_markdownStyleSheet` 无需改动。

**笔记字体四档**：系统（默认，跟随全局）/ 非衬线 / 衬线 / 等宽。"系统"档让笔记字体默认跟随全局设置，用户可显式选择其他档位使笔记与全局解耦。

---

## 1. 背景与问题

现状（代码实测）：

- 设置主页只有一个入口 `Font style`（`lib/views/settings/settings.dart`），点进 `FontStylePicker`（`lib/views/settings/editor_font_setting.dart`）。
- 该页一个 `Apply` 同时写两个偏好：
  - **字体类型**（`fontFamilyTypeIndex`）→ 经 `lib/utils/platform_ui.dart` 的 `uiFontFamily` → `applyUiFont(TextTheme)` **全局生效**；
  - **字体大小**（`editorFontSizeIndex`）→ 经 `lib/utils/editor_text.dart` 的 `EditorText.body()/title()` **仅笔记编辑/预览页生效**。
- 用户看到"字体样式"里能调字号，自然以为改的是全局，结果只有笔记变——**作用范围混淆**。

此外，笔记页目前只能调字号，缺少行高、对齐等常见阅读排版项。

---

## 2. 设计原则（锁定决策）

| 项 | 决策 |
|----|------|
| 双轨 | 全局字体（字体设置）与笔记样式（仅笔记）分离，各自作用范围明确标注 |
| 渲染不冲突 | `AppText.title/body` 是**不带 `fontFamily` 的纯 `TextStyle`**；笔记经 `EditorText._style` 显式 `copyWith(fontFamily:...)` 覆盖；全局字体经 `applyUiFont` 注入 `TextTheme`。两条链路互不相交，笔记永远用自己的字体族，全局字体到不了笔记文字 → **不存在冲突**（详见 §3） |
| Markdown 独立 | Markdown 预览**不跟随笔记样式**，只跟随全局字体（`uiFontFamily`）；`_markdownStyleSheet` 保持现状不改。笔记样式仅作用于编辑态（TextField）与纯文本预览（SelectableText，即 Markdown 关闭时） |
| 笔记字体四档 | 系统（默认，跟随全局 `fontFamilyTypeIndex`）/ 非衬线 / 衬线 / 等宽。"系统"档让笔记字体默认跟随全局设置，改全局字体时笔记自动跟随；用户显式选其他档位后笔记与全局解耦 |
| 列表卡片归属 | 首页笔记列表卡片属于「App 外壳 UI」，**跟随全局字体**；只有打开/编辑笔记时的**内容**（标题 + 正文 + 纯文本预览 + 版本历史）才用笔记样式 |
| 版本历史跟随 | 版本历史页已直接调用 `EditorText.title()/body()`，切换字体来源后自动跟随笔记样式，无需额外改动 |
| 行高仅正文 | 行高档位仅作用于笔记**正文**，标题保持固定行高（`AppText.title.height = 1.2`），始终比正文紧凑 |
| 无迁移 | App 尚在开发中未发布，`noteFontFamilyTypeIndex` 直接默认 0（系统），不做老用户迁移 |
| i18n | 仅 `zh-CN.json` 与 `en-US.json`（AGENTS.md 约束） |

---

## 3. 为什么不会冲突（机制说明）

```
全局字体  fontFamilyTypeIndex ──▶ applyUiFont(TextTheme) ──▶ App 外壳（对话框/卡片/设置页/列表卡片）
                                                            └── Markdown 预览（_markdownStyleSheet 读 uiFontFamily）
                                                            └── 笔记字体"系统"档（noteFontFamilyTypeIndex=0 时回读此键）

笔记样式  noteFontFamilyTypeIndex + editorFontSizeIndex + noteLineHeightIndex + noteTextAlignIndex
        ──▶ EditorText.body/title（显式 copyWith）
        ──▶ 编辑态 TextField + 纯文本预览 SelectableText + 版本历史 SelectableText
```

- 全局侧只改 `TextTheme` 的默认字体族；笔记侧在 `EditorText` 里用 `copyWith(fontFamily: appFontFamilyFor(noteType))` **显式覆盖**，不读 `TextTheme` 的字体族。
- 笔记字体类型为"系统"档（`noteFontFamilyTypeIndex=0`）时，`EditorText.fontType` 回读 `fontFamilyTypeIndex`，笔记字体跟随全局——这是默认行为。
- 笔记字体类型为非衬线/衬线/等宽时，`EditorText.fontType` 使用笔记专属值，与全局解耦。
- Markdown 预览通过 `_editorLikeStyle(context, AppText.body.copyWith(fontFamily: uiFontFamily))` 显式使用全局字体，始终与笔记样式无关。
- 因此即便全局设为衬线、笔记设为等宽，两者也各写各的文字，无渲染竞争。
- 唯一"视觉差异"是有意的：笔记内容可以和 App 外壳字体不同，这正是本方案想要的效果。

---

## 4. 作用范围对照表

| 设置项 | 存储键 | 编辑态（TextField） | 纯文本预览（SelectableText） | Markdown 预览 | 版本历史 |
|--------|--------|:-:|:-:|:-:|:-:|
| 全局字体类型 | `fontFamilyTypeIndex`（已有） | —（系统档间接） | —（系统档间接） | ✅ | —（系统档间接） |
| 笔记字体类型 | `noteFontFamilyTypeIndex`（新增，0=系统跟随全局） | ✅ | ✅ | — | ✅ |
| 笔记字号 | `editorFontSizeIndex`（已有） | ✅ | ✅ | — | ✅ |
| 笔记行高（仅正文） | `noteLineHeightIndex`（新增） | ✅ 正文 | ✅ 正文 | — | ✅ 正文 |
| 笔记正文对齐 | `noteTextAlignIndex`（新增） | ✅ | ✅ | — | ✅ |

> ✅ = 跟随该设置项；— = 不受影响；—（系统档间接）= 笔记字体类型为"系统"档时，通过回读 `fontFamilyTypeIndex` 间接跟随全局字体。
> Markdown 预览完全独立，仅跟随全局字体类型，字号使用固定层级（24/20/18/17/16，P1-20 既有设计）。

---

## 5. 数据层改动（PreferencesStorage）

在 `lib/data/preference_and_config.dart` 新增（仿已有 `editorFontSizeIndex` 模式）：

```dart
// 笔记字体类型：0=系统(跟随全局) / 1=非衬线 / 2=衬线 / 3=等宽，默认 0=系统。
// "系统"档回读 fontFamilyTypeIndex，笔记字体跟随全局设置——符合默认预期。
// App 尚在开发中未发布，无需老用户迁移。
static const _keyNoteFontFamilyTypeIndex = 'noteFontFamilyTypeIndex';
static int get noteFontFamilyTypeIndex =>
    _preferences?.getInt(_keyNoteFontFamilyTypeIndex) ?? 0;
static Future<void> setNoteFontFamilyTypeIndex(int index) async {
  final old = noteFontFamilyTypeIndex;
  await _preferences?.setInt(_keyNoteFontFamilyTypeIndex, index);
  _logPrefChange('笔记字体类型', old, index);
}

// 笔记行高档位（仅正文）：1.2 / 1.4 / 1.6 / 1.8，默认 1 = 标准 1.4（= 现状 body height）
static const _keyNoteLineHeightIndex = 'noteLineHeightIndex';
static const List<double> noteLineHeights = [1.2, 1.4, 1.6, 1.8];
static int get noteLineHeightIndex =>
    _preferences?.getInt(_keyNoteLineHeightIndex) ?? 1;
static Future<void> setNoteLineHeightIndex(int i) async { /* clamp + log */ }

// 笔记正文对齐：0=start / 1=center / 2=justify，默认 0=start（LTR 下等同左对齐）
// 内部映射为 TextAlign.start / TextAlign.center / TextAlign.justify，
// 使用 start 语义而非 left，为未来 RTL 语言预留兼容。
static const _keyNoteTextAlignIndex = 'noteTextAlignIndex';
static int get noteTextAlignIndex =>
    _preferences?.getInt(_keyNoteTextAlignIndex) ?? 0;
static Future<void> setNoteTextAlignIndex(int i) async { /* clamp + log */ }
```

`EditorText`（`lib/utils/editor_text.dart`）调整：

- `fontType` getter 改读 `noteFontFamilyTypeIndex`：值为 0（系统）时回读 `fontFamilyTypeIndex`，值为 1-3 时映射到 `AppFontType`（1→sans, 2→serif, 3→mono）。
- 新增 `noteFontTypeOf(int idx)` → 将笔记字体类型索引（0-3）解析为 `AppFontType`，供 pending 预览使用。
- 新增 `lineHeightOf(int i)` → `noteLineHeights[clamp(i)]`，返回正文行高值。
- 新增 `lineHeight` getter → `lineHeightOf(PreferencesStorage.noteLineHeightIndex)`，返回当前已保存行高。
- 新增 `textAlignOf(int i)` → 映射为 `TextAlign`：`[TextAlign.start, TextAlign.center, TextAlign.justify]`。
- 新增 `textAlign` getter → `textAlignOf(PreferencesStorage.noteTextAlignIndex)`。
- `_style` 方法签名增加可选 `double? height` 参数：**仅当 `isTitle == false`（正文）时应用**，标题忽略此参数保持 `AppText.title.height`。
- pending 版本 `bodyOf` / `titleOf` 改为接收笔记字体类型索引（0-3）而非 `AppFontType`，内部经 `noteFontTypeOf` 解析，供设置页预览区实时跟随。

```dart
/// 笔记字体类型解析：
/// - 0（系统）：回读全局 fontFamilyTypeIndex，笔记跟随全局字体。
/// - 1-3：映射到 AppFontType（1→sans, 2→serif, 3→mono），笔记用专属字体。
static AppFontType get fontType {
  final idx = PreferencesStorage.noteFontFamilyTypeIndex;
  if (idx == 0) {
    return AppFontType.values[PreferencesStorage.fontFamilyTypeIndex.clamp(
      0, AppFontType.values.length - 1)];
  }
  return AppFontType.values[(idx - 1).clamp(0, AppFontType.values.length - 1)];
}

/// 将笔记字体类型索引（0-3）解析为 AppFontType（供 pending 预览使用）。
static AppFontType noteFontTypeOf(int idx) {
  if (idx == 0) {
    return AppFontType.values[PreferencesStorage.fontFamilyTypeIndex.clamp(
      0, AppFontType.values.length - 1)];
  }
  return AppFontType.values[(idx - 1).clamp(0, AppFontType.values.length - 1)];
}

/// 构造一个带正确字号与字体族的 [TextStyle]。
///
/// [isTitle] 为 true 复用 [AppText.title]（已 bold）的层级，否则复用
/// [AppText.body]；仅覆盖 [fontSize] 和 [fontFamily]。
/// [height] 仅对正文生效（isTitle == false），标题始终保持 [AppText.title.height]。
/// [type] 为指定字体类型（不传则用已保存的笔记字体类型）。
static TextStyle _style(double size, bool isTitle, [AppFontType? type, double? height]) {
  final base = isTitle ? AppText.title : AppText.body;
  final t = type ?? fontType;
  return base.copyWith(
    fontSize: size,
    fontFamily: appFontFamilyFor(t),
    fontFamilyFallback: appFontFallbackFor(t),
    // 行高仅作用于正文，标题保持紧凑
    height: (!isTitle && height != null) ? height : null,
  );
}
```

---

## 6. 设置 UI 改动

### 6.1 入口分组（`lib/views/settings/settings.dart`）

- **外观组**（Theme color、Notes color 附近）新增导航项 **「字体设置」** → `FontSettingsPicker`：
  - 仅字体类型（衬线/非衬线/等宽），写 `fontFamilyTypeIndex`，**全局**；
  - 入口 value 显示当前全局字体类型；description 标注「Applies to entire app」。
- **笔记组**（Compact notes、Markdown 附近）保留并改名 **「笔记样式」** → `NoteStylePicker`（原 `FontStylePicker` 改名重构）：
  - 字体类型（系统/非衬线/衬线/等宽，写 `noteFontFamilyTypeIndex`）+ 字号 + 行高 + 对齐，全部**仅笔记**；
  - 入口 value 显示「字体类型 · 字号」；description 标注「Notes editor & preview only」。

### 6.2 两个页面各自独立 Apply

- `FontSettingsPicker`：仅写 `fontFamilyTypeIndex`，`notifyThemeChanged()` 触发全局重建。
- `NoteStylePicker`：写 `noteFontFamilyTypeIndex` + `editorFontSizeIndex` + `noteLineHeightIndex` + `noteTextAlignIndex`，编辑/预览页下次进入重建才生效（符合既有"Apply 后重建"约定）。
- 两者**互不写对方偏好**，避免一次改动影响两个范围。

### 6.3 控件与预览

- 沿用现有 `SegmentedButton`（非 Slider，与当前实现一致），参考 `theme_color_setting.dart` 布局：限宽 720 居中 + 底部固定 Apply。
- 顶部预览区用单段示例文案（标题 + 多行正文），实时跟随字体类型/字号/行高/对齐。
- 预览区使用**纯 SelectableText / Text**（非 Markdown），因为笔记样式不作用于 Markdown 预览。

**Pending 预览机制**：与现有 `EditorText.bodyOf(i, type)` / `titleOf(i, type)` 模式一致——`NoteStylePicker` 内部用本地 `int` 状态（`_fontTypeIndex`、`_fontSizeIndex`、`_lineHeightIndex`、`_textAlignIndex`）作为唯一数据源，选中态与预览区都读它，`onSelectionChanged` 直接 `setState` 更新。新增的行高与对齐参数同样经 `bodyOf` / `titleOf` 的 pending 重载传入预览区，实时跟随选择。

### 6.4 「系统」档位即跟随全局

笔记字体类型的第一个档位是 **「系统」**，选中后笔记字体跟随全局字体设置（`fontFamilyTypeIndex`）。
用户把笔记字体改为非衬线/衬线/等宽后，想恢复跟随全局，只需选回「系统」即可——无需额外按钮。

---

## 7. 笔记样式页内容（v1）

| 项 | 档位 | 默认 | 存储键 | 作用位置 |
|----|------|------|--------|----------|
| 字体类型 | 系统 / 非衬线 / 衬线 / 等宽 | 系统（0） | `noteFontFamilyTypeIndex` | 编辑 + 纯文本预览 + 版本历史 |
| 字号 | 小14 / 标准16 / 大18 / 特大20 | 标准16 | `editorFontSizeIndex` | 编辑 + 纯文本预览 + 版本历史 |
| 行高（仅正文） | 紧凑1.2 / 标准1.4 / 宽松1.6 / 特松1.8 | 标准1.4 | `noteLineHeightIndex` | 编辑正文 + 纯文本预览正文 + 版本历史正文 |
| 正文对齐 | 起始(start) / 居中 / 两端(justify) | 起始 | `noteTextAlignIndex` | 编辑 + 纯文本预览 + 版本历史 |

> 笔记字体类型"系统"档（默认）回读全局 `fontFamilyTypeIndex`，笔记字体跟随全局设置。
> 标题行高固定 1.2（`AppText.title.height`），不随行高档位变化，始终比正文紧凑。
> 正文对齐内部映射为 `TextAlign.start`，LTR 下等同左对齐，为未来 RTL 语言预留。
> UI 标签可用「左对齐」/「Left」（当前仅 zh/en，均为 LTR）。

---

## 8. 可选增强（后续，不进 v1）

| 候选 | 说明 | 备注 |
|------|------|------|
| **段间距** | 段落之间增加额外间距 | **技术受限**：TextField 与 SelectableText 无段间距 API，需自定义段落渲染组件（按 `\n` 拆分、逐段 `Text` + `Padding`）。建议按正文字号倍数计算（如 `fontSize × [0, 0.25, 0.5, 0.75]`），随字号缩放保持视觉比例。v2 评估 |
| **首行缩进** | 段落首行缩进显示 | **技术受限**：TextField 与 SelectableText 无首行缩进 API。纯用户开关，不绑定 locale（设置项行为随系统语言变化不合理）。需自定义渲染组件，v2 评估 |
| 阅读背景 | 默认 / 米黄(sepia) / 纸张白，仅笔记阅读区 | 需与深浅色主题协调 |
| 最大行宽 | 桌面/平板限制正文最大宽度并居中 | 提升大屏可读性，需布局改动 |
| 代码块强制等宽 | Markdown 预览里 fenced code 强制等宽（即使正文是衬线） | 偏渲染层（Markdown 独立，可能不适用） |
| 链接 / 引用块样式 | 链接下划线、引用块左边框等 | Markdown 渲染增强 |
| 标题字号倍率独立 | 标题相对正文放大倍率可单独调（现固定 +4） | 小众 |
| 字间距 | 西文标题可用，中文一般不需 | 低价值 |

---

## 9. 接线路线（代码层面，待实施阶段参考）

> 行号为编写方案时的大致位置，实施时需重新读取代码确认。

| 文件 | 改动 |
|------|------|
| `lib/utils/editor_text.dart` | `fontType` 改读 `noteFontFamilyTypeIndex`（0=系统时回读全局）；新增 `noteFontTypeOf` 索引解析；`_style` 增加 `height` 参数（仅正文生效）；新增 `lineHeightOf` / `lineHeight` / `textAlignOf` / `textAlign` 映射；`bodyOf` / `titleOf` pending 版本增加行高参数 |
| `lib/data/preference_and_config.dart` | 新增 `noteFontFamilyTypeIndex` / `noteLineHeightIndex` / `noteTextAlignIndex` 键与 getter/setter |
| `lib/widgets/note_widget.dart` | 标题/正文 `ShadInputFormField` 的 `style` 已接 `EditorText`，确认字体来源切到笔记专属即可；正文增加 `textAlign: EditorText.textAlign`（需确认 `ShadInputFormField` 是否暴露 `textAlign`，若否则用原生 `TextField`） |
| `lib/views/add_edit_note.dart` | **`_editorLikeStyle`**：删除 `base.copyWith(fontFamily: uiFontFamily, ...)` 覆盖，改为直接 `.merge(base)`——让 base 自带字体：纯文本预览传 `EditorText.title()/body()`（携带笔记字体），Markdown 传 `AppText.body.copyWith(fontFamily: uiFontFamily, ...)`（携带全局字体）。**纯文本预览**：`SelectableText` 增加 `textAlign: EditorText.textAlign`。**`_markdownStyleSheet`**：无改动，继续通过 `_editorLikeStyle(context, AppText.body.copyWith(fontFamily: uiFontFamily))` 使用全局字体 |
| `lib/views/version_history_page.dart` | 已直接调用 `EditorText.title()/body()`，字体来源切换后自动跟随笔记样式。`_buildSelectableText` 与 `_buildDiffText` 的 `SelectableText` / `SelectableText.rich` 增加 `textAlign: EditorText.textAlign`（正文行） |
| `lib/views/settings/settings.dart` | 拆入口：新增「字体设置」（外观组）、「笔记样式」改名（笔记组） |
| `lib/views/settings/editor_font_setting.dart` | 改名为 `NoteStylePicker`，字体类型改为 4 档（系统/非衬线/衬线/等宽），增加行高/对齐分段按钮。清理注释掉的 `_segmentStyle` 死代码 |
| `lib/views/settings/font_settings_page.dart`（新增） | 「字体设置」页，仅字体类型，全局 |
| `assets/translations/zh-CN.json`、`en-US.json` | 新增各 key（见 §10） |

**Markdown 渲染器无需改动**：`_markdownStyleSheet` 继续使用 `_editorLikeStyle(context, AppText.body.copyWith(fontFamily: uiFontFamily))` 构造样式，字体来源为全局，与笔记样式完全解耦。

**`_editorLikeStyle` 改动细节**（当前代码覆盖了 base 的字体）：

```dart
// 改动前：
TextStyle _editorLikeStyle(BuildContext context, TextStyle base) {
  return shad.textTheme.muted.copyWith(color: ...).merge(
    base.copyWith(
      fontFamily: uiFontFamily,          // ← 强制覆盖为全局字体
      fontFamilyFallback: uiFontFamilyFallback,
    ),
  );
}

// 改动后：不再覆盖 fontFamily，让 base 自带字体
TextStyle _editorLikeStyle(BuildContext context, TextStyle base) {
  return shad.textTheme.muted.copyWith(color: ...).merge(base);
}
```

调用方负责传入正确字体的 base：
- 纯文本预览：`_editorLikeStyle(context, EditorText.body())` → base 携带笔记字体（"系统"档时即全局字体）
- Markdown：`_editorLikeStyle(context, AppText.body.copyWith(fontFamily: uiFontFamily, fontFamilyFallback: uiFontFamilyFallback))` → base 携带全局字体

---

## 10. i18n 文案（仅 zh-CN + en-US）

| key | en-US | zh-CN |
|-----|-------|-------|
| `Font settings` | Font settings | 字体设置 |
| `Note style` | Note style | 笔记样式 |
| `Note font family` | Note font family | 笔记字体 |
| `System` | System | 系统 |
| `Line height` | Line height | 行高 |
| `Compact`(行高档) | Compact | 紧凑 |
| `Standard`(行高档) | Standard | 标准 |
| `Relaxed` | Relaxed | 宽松 |
| `Extra relaxed` | Extra relaxed | 特松 |
| `Text align` | Text align | 正文对齐 |
| `Start` | Start | 左对齐 |
| `Center` | Center | 居中 |
| `Justify` | Justify | 两端对齐 |
| `Applies to entire app` | Applies to entire app | 对整个应用生效 |
| `Notes editor and preview only` | Notes editor & preview only | 仅笔记编辑与预览 |

（已有的 `Font family` / `Font size` / `Serif` / `Sans-serif` / `Monospace` / `Small` / `Standard` / `Large` / `Extra` / `Apply` / `Current` / `Preview` 等复用，不重复新增。行高档 `Standard` 与字号档 `Standard` 复用同一 key。）

---

## 11. 风险与边界

- ✅ 笔记字体类型默认"系统"档，跟随全局字体设置；用户可显式选择非衬线/衬线/等宽使笔记与全局解耦。切换全局字体时，"系统"档笔记自动跟随，其他档位不变——这是预期行为。
- ✅ Markdown 预览完全独立，只跟随全局字体，`_markdownStyleSheet` 无需改动，不存在渲染器 API 兼容风险。
- ✅ 版本历史页已调用 `EditorText.title()/body()`，字体来源切换后自动跟随笔记样式，无需额外代码路径。
- ⚠️ 行高仅作用于正文，标题保持固定 1.2。如用户选"特松 1.8"，标题与正文行高差异较大，需在预览区验证视觉协调性。
- ⚠️ `ShadInputFormField` 是否暴露 `textAlign` 属性需在实施时确认；若不支持，正文编辑框需改用原生 `TextField` 或包裹处理。
- ⚠️ 设置页预览区需同时呈现字体类型（4 档）+ 字号 + 行高 + 对齐，布局可能拥挤 → 用单段精简示例文案 + 分组卡片。
- ✅ 首页紧凑预览 `AutoSizeText`（`minFontSize:15`）、对话框、导航栏等全部不变（属 App 外壳，跟随全局）。
- ⚠️ 段间距与首行缩进因 TextField / SelectableText 无原生 API 支持移至 v2，v1 不实现。

---

## 12. 验证步骤（实施完成后执行）

```bash
# 代码格式（仅修改过的文件）
dart format lib/utils/editor_text.dart lib/data/preference_and_config.dart \
  lib/widgets/note_widget.dart lib/views/add_edit_note.dart \
  lib/views/version_history_page.dart lib/views/settings/settings.dart \
  lib/views/settings/editor_font_setting.dart
dart pub run import_sorter:main

# 静态分析
flutter analyze

# 单元测试（新增 EditorText 映射函数）
dart test packages/core/test

# Widget 测试
flutter test

# 编译验证
flutter build windows --debug
```

**新增单元测试计划**（`packages/core/test` 或 `test/`）：

| 测试对象 | 测试点 |
|----------|--------|
| `EditorText.lineHeightOf(i)` | 各档位返回正确值；越界索引被 clamp 不崩溃 |
| `EditorText.lineHeight` | 读取已保存档位值 |
| `EditorText.textAlignOf(i)` | 0→`TextAlign.start`、1→`TextAlign.center`、2→`TextAlign.justify`；越界 clamp |
| `EditorText.textAlign` | 读取已保存档位值 |
| `EditorText._style` | `isTitle=true` 时 `height` 参数被忽略（标题行高恒为 `AppText.title.height`）；`isTitle=false` 时 `height` 生效 |
| `EditorText.fontType` | `noteFontFamilyTypeIndex=0` 时回读 `fontFamilyTypeIndex`；`noteFontFamilyTypeIndex=1-3` 时映射到对应 `AppFontType`（1→sans, 2→serif, 3→mono） |
| `EditorText.noteFontTypeOf(idx)` | 与 `fontType` 同逻辑但接收外部索引 |
| `PreferencesStorage.noteFontFamilyTypeIndex` | 默认值 = 0（系统）；setter 正确写入 |

关键变更记入 `docs/CHANGES-YYYYMMDD.md` 顶部（实施当日再建）。

---

## 13. 文件改动清单（待实施）

| 类型 | 文件 |
|------|------|
| 修改 | `lib/data/preference_and_config.dart`（新增 `noteFontFamilyTypeIndex` / `noteLineHeightIndex` / `noteTextAlignIndex` 键） |
| 修改 | `lib/utils/editor_text.dart`（`fontType` 来源切换 + `noteFontTypeOf` 解析 + 行高/对齐映射 + `_style` 行高参数） |
| 修改 | `lib/views/settings/settings.dart`（拆入口、分组） |
| 改名/改 | `lib/views/settings/editor_font_setting.dart` → `NoteStylePicker`（字体类型改 4 档 + 增加行高/对齐卡片 + 清理死代码） |
| 新增 | `lib/views/settings/font_settings_page.dart`（「字体设置」页，仅字体类型，全局） |
| 修改 | `lib/widgets/note_widget.dart`（正文增加 `textAlign`，确认字体来源） |
| 修改 | `lib/views/add_edit_note.dart`（`_editorLikeStyle` 去掉 fontFamily 覆盖；纯文本预览增加 `textAlign`；`_markdownStyleSheet` 传入全局字体 base） |
| 修改 | `lib/views/version_history_page.dart`（`SelectableText` / `SelectableText.rich` 增加 `textAlign`，正文行） |
| 修改 | `assets/translations/zh-CN.json`、`en-US.json` |
| 新增 | `test/editor_text_test.dart` 或 `packages/core/test`（EditorText 映射函数单元测试） |
| 记录 | `docs/CHANGES-YYYYMMDD.md` |
