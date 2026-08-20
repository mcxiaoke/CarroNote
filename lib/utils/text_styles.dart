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

import 'package:flutter/material.dart';

/// 全局 type scale（P1-1）：四档语义字号，替代散落的手写 TextStyle。
///
/// 使用方式：
/// - 需要跟随主题色/字体族时 `AppText.title.copyWith(color: ..., fontFamily: ...)`；
/// - 颜色保持默认（null）时自动继承上层 DefaultTextStyle。
class AppText {
  AppText._();

  // ---- 全局语义档 ----

  /// 大标题（页面标题 / 对话框标题 / 笔记标题 20）
  static const TextStyle title = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.bold,
    height: 1.2,
  );

  /// 正文（笔记正文 / 卡片标题 / 按钮文字 16）
  static const TextStyle body = TextStyle(fontSize: 16, height: 1.4);

  /// 小号正文（对话框正文 / 编辑器正文 / 描述文字 14）
  static const TextStyle bodySmall = TextStyle(fontSize: 14, height: 1.4);

  /// 说明文字（时间戳 / 标签 / 辅助信息 12）
  static const TextStyle label = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.2,
  );
}

/// 纯字号刻度：仅统一「字号数字」来源，不附加字体/字重/字距等样式。
///
/// 供散落的 `fontSize: N` 硬编码引用（各处以 `copyWith(fontSize: ...)` 或
/// 自带字重的方式保留原有样式），避免直接用 [AppText] 四档（其绑定
/// fontWeight/letterSpacing）造成视觉漂移。
class AppTextSize {
  AppTextSize._();

  /// 12（对应 [AppText.label] 的字号）
  static const double s12 = 12;

  /// 14（对应 [AppText.bodySmall] 的字号）
  static const double s14 = 14;

  /// 16（对应 [AppText.body] 的字号）
  static const double s16 = 16;

  /// 20（对应 [AppText.title] 的字号）
  static const double s20 = 20;
}
