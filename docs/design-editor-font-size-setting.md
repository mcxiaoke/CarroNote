# 编辑器字体大小设置 — 设计文档

> 目的：把本功能的完整方案落盘，避免因对话上下文丢失而遗忘。
> 创建时间：2026-08-18（GMT+8）
> 关联代码：笔记编辑/预览页字体调节，仅影响编辑与预览页，不影响其它页面。

## 1. 背景与目标

当前笔记编辑页（`lib/widgets/note_widget.dart`）与预览页（`lib/views/add_edit_note.dart`）
的字体被 hardcode 为全局 `AppText.body`（16px）/ `AppText.title`（20px）。
`AppText` 是全局 `const`，被首页卡片、对话框、设置页等大量复用，**不能改动**。

目标：在设置里增加一项「字体大小」调节，**只**改变笔记编辑/预览页的字体，其它页面不变。

## 2. 锁定的设计决策

| 项 | 决策 |
|----|------|
| 入口位置 | 设置主页 Appearance 区新增导航项 → 独立子页 `editor_font_setting.dart`（仿主题色页） |
| 控件 | `ShadSlider`（shadcn_ui 0.56.1 自带，已确认） |
| 滑块模式 | 离散四档 snap：min 0 / max 3 / divisions 3，label 显示档位名 |
| 档位（正文 px） | 小 14 / 标准 16 / 大 18 / 特大 20；默认 = 标准 16（= 现状） |
| 标题档位 | 标题 = 正文 + 4（18 / 20 / 22 / 24），保持现有 20 vs 16 的层级差 |
| Markdown 预览 h1–h6 | 由固定 24/20/18/17 改为基于档位相对偏移（h1=body+8, h2=body+4, h3=body+2, h4=body+1, h5/h6=body），跟随档位缩放 |
| 顶部预览区 | `ShadCard` 两张行：标题行 `SafeNotesConfig.appName`、正文行 `SafeNotesConfig.appSlogan`；实时跟随滑块；带 `Current`/`Preview` 标签 |
| 生效时机 | 仅底部 Apply 按钮写入；无取消键，返回即放弃本地改动 |
| 宽屏窄屏适配 | `shadSettingsList`（限宽 720 居中）+ 底部 `ConstrainedBox(maxWidth:720)` 对齐，参考 `theme_color_setting.dart` |

## 3. 存储层（PreferencesStorage）

在 `lib/data/preference_and_config.dart` 新增，仿 `inactivityTimeout` 模式：

```dart
static const _keyEditorFontSizeIndex = 'editorFontSizeIndex';

static int get editorFontSizeIndex =>
    _preferences?.getInt(_keyEditorFontSizeIndex) ?? EditorText.defaultIndex;

static Future<void> setEditorFontSizeIndex(int index) async {
  final old = editorFontSizeIndex;
  await _preferences?.setInt(_keyEditorFontSizeIndex, index);
  _logPrefChange('编辑器字体大小', old, index);
}
```

> 注意：`editorFontSizeIndex` 的默认值依赖 `EditorText.defaultIndex`，需在 `EditorText`
> 定义后引用；或把默认索引常量（=1）直接写死在 getter 里以避免循环依赖。
> 推荐：在 `PreferencesStorage` 内用字面量 `1` 作为默认，文档与代码中统一注释「=标准 16」。

## 4. EditorText 工具类（lib/utils/editor_text.dart，新增）

独立于全局 `AppText`，仅供编辑/预览页使用。提供两套方法：

- `body(context)` / `title(context)`：读**已保存**档位（编辑/预览页用，Apply 后重建才变）
- `bodyOf(context, index)` / `titleOf(context, index)`：读**本地 pending** 档位（设置页预览区，实时跟随滑块）

```dart
import 'package:flutter/material.dart';
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/utils/text_styles.dart';
import 'package:safenotes/utils/platform_ui.dart'; // uiFontFamily / uiFontFamilyFallback

class EditorText {
  EditorText._();
  static const List<double> bodySizes = [14, 16, 18, 20];
  static const double titleDelta = 4;
  static const int defaultIndex = 1; // 标准 16 = 现状

  static int _clamp(int i) => i.clamp(0, bodySizes.length - 1);
  static double bodySizeOf(int i) => bodySizes[_clamp(i)];
  static double titleSizeOf(int i) => bodySizeOf(i) + titleDelta;
  static int get index => _clamp(PreferencesStorage.editorFontSizeIndex);

  static TextStyle _style(BuildContext context, double size, bool isTitle) {
    final base = isTitle ? AppText.title : AppText.body;
    return base.copyWith(
      fontSize: size,
      fontFamily: uiFontFamily,
      fontFamilyFallback: uiFontFamilyFallback,
    );
  }

  static TextStyle body(BuildContext c) => _style(c, bodySizeOf(index), false);
  static TextStyle title(BuildContext c) => _style(c, titleSizeOf(index), true);
  static TextStyle bodyOf(BuildContext c, int i) => _style(c, bodySizeOf(i), false);
  static TextStyle titleOf(BuildContext c, int i) => _style(c, titleSizeOf(i), true);

  /// 档位显示名（本地化）：Small / Standard / Large / Extra Large
  static String labelOf(int i) {
    const names = ['Small', 'Standard', 'Large', 'Extra Large'];
    return names[_clamp(i)].tr();
  }
}
```

## 5. 设置子页（lib/views/settings/editor_font_setting.dart，新增）

结构严格参考 `theme_color_setting.dart`：

- `StatefulWidget` + 本地 `_pendingIndex`（init 为 `PreferencesStorage.editorFontSizeIndex`）。
- `build`：
  - `Scaffold` + `appBar` 标题「Font size」`.tr()`。
  - `bottomNavigationBar`：`SafeArea` → `Padding` → `Align(heightFactor:1.0)` →
    `ConstrainedBox(maxWidth:720)` → `ShadButton(width:double.infinity, onPressed: _hasPendingChange ? _apply : null, child: Text('Apply'.tr()))`。
  - `body`: `shadSettingsList([ _preview(context), SizedBox(12), _slider(context) ])`。
- `_preview`：`ShadCard`，`Column` 内第一行标签（`Current`/`Preview` `.tr()` 区分），
  第二行标题 `SafeNotesConfig.appName`（用 `EditorText.titleOf(context, _pendingIndex)`），
  第三行正文 `SafeNotesConfig.appSlogan`（用 `EditorText.bodyOf(context, _pendingIndex)`）。
- `_slider`：`ShadSlider(value: _pendingIndex.toDouble(), min: 0, max: 3, divisions: 3,
  label: EditorText.labelOf(_pendingIndex), onChanged: (v) => setState(() => _pendingIndex = v.round()))`。
  （实施时以 `lib/src/components/slider.dart` 实际 API 为准：确认 `label` 是 String 还是 Widget。）
- `_hasPendingChange`：`_pendingIndex != PreferencesStorage.editorFontSizeIndex`。
- `_apply`：`PreferencesStorage.setEditorFontSizeIndex(_pendingIndex)`。

宽屏窄屏：`shadSettingsList` 已限宽 720 居中；底部按钮同样限宽 720，桌面/移动都自然。

## 6. 接线路线（仅编辑/预览页）

| 文件 | 行 | 改动 |
|------|----|------|
| `lib/widgets/note_widget.dart` | `:81`（标题） | `AppText.title.copyWith(fontFamily:...)` → `EditorText.title(context)` |
| `lib/widgets/note_widget.dart` | `:121`（正文） | `AppText.body.copyWith(fontFamily:...)` → `EditorText.body(context)` |
| `lib/views/add_edit_note.dart` | `:249`（预览标题） | `_editorLikeStyle(context, AppText.title)` → `EditorText.title(context)` |
| `lib/views/add_edit_note.dart` | `:278`（预览正文） | `_editorLikeStyle(context, AppText.body)` → `EditorText.body(context)` |
| `lib/views/add_edit_note.dart` | `:296`（Markdown uiBase） | `_editorLikeStyle(context, AppText.body)` → `EditorText.body(context)` |
| `lib/views/add_edit_note.dart` | `:305-313`（h1–h6） | 固定 24/20/18/17 → 基于 `EditorText.bodySizeOf(EditorText.index)` 相对偏移 |

`_editorLikeStyle` 函数本身**尽量少改**，仅把传入的 `base` 换成 `EditorText.*`；
其内部的 `shad muted + 注入 foreground + 补字体族`逻辑保持不变。

Markdown h1–h6 改动草图：

```dart
final double body = EditorText.bodySizeOf(EditorText.index);
return base.copyWith(
  p: uiBase,
  h1: uiBase.copyWith(fontSize: body + 8, fontWeight: FontWeight.w700),
  h2: uiBase.copyWith(fontSize: body + 4, fontWeight: FontWeight.w700),
  h3: uiBase.copyWith(fontSize: body + 2, fontWeight: FontWeight.w700),
  h4: uiBase.copyWith(fontSize: body + 1, fontWeight: FontWeight.w700),
  h5: uiBase.copyWith(fontWeight: FontWeight.w700),
  h6: uiBase.copyWith(fontWeight: FontWeight.w600, color: cs.onSurfaceVariant),
  // code/blockquote 保持原有逻辑
);
```

## 7. i18n 文案（仅 zh-CN.json 与 en-US.json）

复用已有 key：`Current`、`Preview`、`Apply theme`（如复用则按钮用 `Apply theme`，
否则新增 `Apply`）。新增 key：

| key | en-US | zh-CN |
|-----|-------|-------|
| `Font size` | Font size | 字体大小 |
| `Small` | Small | 小 |
| `Standard` | Standard | 标准 |
| `Large` | Large | 大 |
| `Extra Large` | Extra Large | 特大 |
| `Apply` | Apply | 应用 |

（`AppName`/`AppSlogan` 已存在，无需新增。）

## 8. 影响范围与边界

- ✅ 仅编辑页、预览页（含 Markdown 预览）字号变化。
- ✅ 首页卡片（`note_card_body` 用 `AppText.body/label`）、对话框、设置页、导航栏等全部不变。
- ✅ 首页紧凑预览 `AutoSizeText`（`minFontSize:15`）不变。
- ⚠️ 设置页内预览区实时跟随滑块；编辑/预览页本身要等点 Apply、下次进入重建才变（符合需求）。

## 9. 验证步骤（改完执行）

```bash
flutter analyze
dart test packages\core\test
flutter test
flutter build windows --debug
```

关键变更同时记入 `docs/CHANGES-20260818.md` 顶部。

## 10. 文件改动清单

| 类型 | 文件 |
|------|------|
| 新增 | `lib/utils/editor_text.dart` |
| 修改 | `lib/data/preference_and_config.dart`（editorFontSizeIndex） |
| 修改 | `lib/views/settings/settings.dart`（Appearance 入口） |
| 新增 | `lib/views/settings/editor_font_setting.dart` |
| 修改 | `lib/widgets/note_widget.dart`（:81 / :121） |
| 修改 | `lib/views/add_edit_note.dart`（:249 / :278 / :296 / :305-313） |
| 修改 | `assets/translations/zh-CN.json`、`assets/translations/en-US.json` |
| 记录 | `docs/CHANGES-20260818.md` |
