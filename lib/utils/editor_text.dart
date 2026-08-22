/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
*
* 编辑/预览页专用字号与排版来源。
*
* 独立于全局 [AppText]（[AppText] 是全局 const，被首页卡片、对话框、设置页等
* 大量复用，不能改动），本类只服务于笔记编辑页与预览页，从而做到「仅调节
* 编辑/预览字体，其它页面不变」。
*
* 笔记字体类型四档：系统（默认，跟随全局 [PreferencesStorage.fontFamilyTypeIndex]）
* / 非衬线 / 衬线 / 等宽。系统档回读全局，其他档位独立解耦。
*
* 提供两套方法：
* - [body]/[title]：读取「已保存」档位，供编辑/预览页使用（Apply 后重建才变）；
* - [bodyOf]/[titleOf]：读取「本地 pending」档位，供设置页预览区实时跟随。
*/

import 'package:flutter/material.dart';

import 'package:easy_localization/easy_localization.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/utils/platform_ui.dart';
import 'package:safenotes/utils/text_styles.dart';

/// 编辑器字体档位与排版样式来源。
class EditorText {
  EditorText._();

  /// 正文档位 px（索引即档位序）：小 / 标准 / 大 / 特大。
  static const List<double> bodySizes = [14, 16, 18, 20];

  /// 标题相对正文的偏移（+4），保持现有 20 vs 16 的层级差。
  static const double titleDelta = 4;

  /// 默认档位索引 = 标准（16，等于现状）。
  static const int defaultIndex = 1;

  /// 档位显示名（与 [bodySizes] 一一对应，供滑块 label / 设置入口 value 使用）。
  static const List<String> _names = ['Small', 'Standard', 'Large', 'Extra'];

  /// 正文对齐映射：0=start / 1=center / 2=justify。
  static const List<TextAlign> _aligns = [
    TextAlign.start,
    TextAlign.center,
    TextAlign.justify,
  ];

  /// 把任意索引夹紧到合法范围，避免越界崩溃。
  static int _clamp(int i) => i.clamp(0, bodySizes.length - 1);

  /// 把行高档位索引夹紧到合法范围。
  static int _clampLineHeight(int i) =>
      i.clamp(0, PreferencesStorage.noteLineHeights.length - 1);

  /// 把对齐索引夹紧到合法范围。
  static int _clampAlign(int i) => i.clamp(0, _aligns.length - 1);

  // ---- 字号 ----

  /// 当前已保存档位的正文 px。
  static double bodySizeOf(int i) => bodySizes[_clamp(i)];

  /// 当前已保存档位的标题 px（正文 + 偏移）。
  static double titleSizeOf(int i) => bodySizeOf(i) + titleDelta;

  /// 已保存档位的索引（供编辑/预览页使用，Apply 后重建才变）。
  static int get index => _clamp(PreferencesStorage.editorFontSizeIndex);

  // ---- 笔记字体类型（四档：系统/非衬线/衬线/等宽） ----

  /// 已保存的笔记字体类型（供编辑/预览页使用）。
  ///
  /// 笔记字体索引 0 = 系统：回读全局 [PreferencesStorage.fontFamilyTypeIndex]，
  /// 笔记字体跟随全局设置；1-3 映射到 [AppFontType]（1→sans, 2→serif, 3→mono），
  /// 笔记用专属字体与全局解耦。
  static AppFontType get fontType =>
      noteFontTypeOf(PreferencesStorage.noteFontFamilyTypeIndex);

  /// 将笔记字体类型索引（0-3）解析为 [AppFontType]（供 pending 预览使用）。
  ///
  /// - 0（系统）：回读全局 [PreferencesStorage.fontFamilyTypeIndex]。
  /// - 1-3：映射到 [AppFontType]（1→sans, 2→serif, 3→mono）。
  static AppFontType noteFontTypeOf(int idx) {
    if (idx <= 0) {
      return AppFontType.values[PreferencesStorage.fontFamilyTypeIndex.clamp(
        0,
        AppFontType.values.length - 1,
      )];
    }
    return AppFontType.values[(idx - 1).clamp(
      0,
      AppFontType.values.length - 1,
    )];
  }

  // ---- 行高（仅正文） ----

  /// 指定档位的行高值。
  static double lineHeightOf(int i) =>
      PreferencesStorage.noteLineHeights[_clampLineHeight(i)];

  /// 已保存的行高值（供编辑/预览页正文使用）。
  static double get lineHeight =>
      lineHeightOf(PreferencesStorage.noteLineHeightIndex);

  // ---- 正文对齐 ----

  /// 指定索引的对齐方式。
  static TextAlign textAlignOf(int i) => _aligns[_clampAlign(i)];

  /// 已保存的正文对齐（供编辑/预览页使用）。
  static TextAlign get textAlign =>
      textAlignOf(PreferencesStorage.noteTextAlignIndex);

  // ---- 样式构造 ----

  /// 构造一个带正确字号与字体族的 [TextStyle]。
  ///
  /// [isTitle] 为 true 复用 [AppText.title]（已 bold）的层级，否则复用
  /// [AppText.body]；仅覆盖 [fontSize] 和 [fontFamily]。
  /// [type] 为指定字体类型（不传则用已保存的笔记字体类型）。
  /// [height] 仅对正文生效（isTitle == false），标题始终保持
  /// [AppText.title.height]（1.2），不随行高档位变化。
  static TextStyle _style(
    double size,
    bool isTitle, [
    AppFontType? type,
    double? height,
  ]) {
    final base = isTitle ? AppText.title : AppText.body;
    final t = type ?? fontType;
    return base.copyWith(
      fontSize: size,
      fontFamily: appFontFamilyFor(t),
      fontFamilyFallback: appFontFallbackFor(t),
      // 行高仅作用于正文，标题保持紧凑
      height: (!isTitle && height != null) ? height : null,
      // 显式设 proportional（Flutter 默认）覆盖 shad textTheme.muted 的
      // TextLeadingDistribution.even。even 会把行高余量均分到行上下两侧，
      // 导致 SelectableText（预览）比 EditableText（编辑）看起来间距更大；
      // proportional 将余量全部放行底，与编辑态 EditableText 自动生成的
      // StrutStyle 行为一致，消除编辑↔预览的行高观感差异。
      leadingDistribution: TextLeadingDistribution.proportional,
    );
  }

  // ---- 已保存值版本（编辑/预览页） ----

  /// 编辑/预览页正文样式（读已保存档位 + 行高）。
  static TextStyle body() => _style(bodySizeOf(index), false, null, lineHeight);

  /// 编辑/预览页标题样式（读已保存档位，行高固定）。
  static TextStyle title() => _style(titleSizeOf(index), true);

  // ---- 本地 pending 版本（设置页预览区，实时跟随） ----

  /// 设置页预览区正文样式（读本地 pending 档位 + 字体类型索引 + 行高）。
  ///
  /// [fontTypeIdx] 为笔记字体类型索引（0-3），经 [noteFontTypeOf] 解析。
  static TextStyle bodyOf(int i, int fontTypeIdx, [double? height]) =>
      _style(bodySizeOf(i), false, noteFontTypeOf(fontTypeIdx), height);

  /// 设置页预览区标题样式（读本地 pending 档位 + 字体类型索引）。
  static TextStyle titleOf(int i, int fontTypeIdx) =>
      _style(titleSizeOf(i), true, noteFontTypeOf(fontTypeIdx));

  /// 档位显示名（本地化）：Small / Standard / Large / Extra。
  static String labelOf(int i) => _names[_clamp(i)].tr();
}
