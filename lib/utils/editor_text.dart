/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
*
* 编辑/预览页专用字号来源。
*
* 独立于全局 [AppText]（[AppText] 是全局 const，被首页卡片、对话框、设置页等
* 大量复用，不能改动），本类只服务于笔记编辑页与预览页，从而做到「仅调节
* 编辑/预览字体，其它页面不变」。
*
* 提供两套方法：
* - [body]/[title]：读取「已保存」档位，供编辑/预览页使用（Apply 后重建才变）；
* - [bodyOf]/[titleOf]：读取「本地 pending」档位，供设置页预览区实时跟随滑块。
*/

import 'package:flutter/material.dart';

import 'package:easy_localization/easy_localization.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/utils/platform_ui.dart';
import 'package:safenotes/utils/text_styles.dart';

/// 编辑器字体档位与样式来源。
class EditorText {
  EditorText._();

  /// 正文档位 px（索引即档位序）：小 / 标准 / 大 / 特大。
  static const List<double> bodySizes = [14, 16, 18, 20];

  /// 标题相对正文的偏移（+4），保持现有 20 vs 16 的层级差。
  static const double titleDelta = 4;

  /// 默认档位索引 = 标准（16，等于现状）。
  static const int defaultIndex = 1;

  /// 档位显示名（与 [bodySizes] 一一对应，供滑块 label / 设置入口 value 使用）。
  static const List<String> _names = [
    'Small',
    'Standard',
    'Large',
    'Extra Large',
  ];

  /// 把任意索引夹紧到合法范围，避免越界崩溃。
  static int _clamp(int i) => i.clamp(0, bodySizes.length - 1);

  /// 当前已保存档位的正文 px。
  static double bodySizeOf(int i) => bodySizes[_clamp(i)];

  /// 当前已保存档位的标题 px（正文 + 偏移）。
  static double titleSizeOf(int i) => bodySizeOf(i) + titleDelta;

  /// 已保存档位的索引（供编辑/预览页使用，Apply 后重建才变）。
  static int get index => _clamp(PreferencesStorage.editorFontSizeIndex);

  /// 已保存的全局字体类型（供编辑/预览页使用，与 App 全局一致）。
  static AppFontType get fontType =>
      AppFontType.values[PreferencesStorage.fontFamilyTypeIndex.clamp(
        0,
        AppFontType.values.length - 1,
      )];

  /// 构造一个带正确字号与字体族的 [TextStyle]。
  ///
  /// [isTitle] 为 true 复用 [AppText.title]（已 bold）的层级，否则复用
  /// [AppText.body]；仅覆盖 [fontSize]，行高/字重保持原有语义。
  /// [type] 为指定字体类型（不传则用已保存的全局字体类型）。
  static TextStyle _style(double size, bool isTitle, [AppFontType? type]) {
    final base = isTitle ? AppText.title : AppText.body;
    final t = type ?? fontType;
    return base.copyWith(
      fontSize: size,
      fontFamily: appFontFamilyFor(t),
      fontFamilyFallback: appFontFallbackFor(t),
    );
  }

  // ---- 已保存值版本（编辑/预览页）----

  /// 编辑/预览页正文样式（读已保存档位）。
  static TextStyle body() => _style(bodySizeOf(index), false);

  /// 编辑/预览页标题样式（读已保存档位）。
  static TextStyle title() => _style(titleSizeOf(index), true);

  // ---- 本地 pending 版本（设置页预览区，实时跟随滑块）----

  /// 设置页预览区正文样式（读本地 pending 档位 + 字体类型）。
  static TextStyle bodyOf(int i, AppFontType type) =>
      _style(bodySizeOf(i), false, type);

  /// 设置页预览区标题样式（读本地 pending 档位 + 字体类型）。
  static TextStyle titleOf(int i, AppFontType type) =>
      _style(titleSizeOf(i), true, type);

  /// 档位显示名（本地化）：Small / Standard / Large / Extra Large。
  static String labelOf(int i) => _names[_clamp(i)].tr();
}
