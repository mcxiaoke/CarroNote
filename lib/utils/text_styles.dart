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

// Flutter imports:
import 'package:flutter/material.dart';

/// 全局 type scale（P1-1）：统一字号/字重语义档，替代散落的手写 TextStyle。
///
/// 使用方式：
/// - 需要跟随主题色/字体族时 `AppText.cardTitle.copyWith(color: ..., fontFamily: ...)`；
/// - 颜色保持默认（null）时自动继承上层 DefaultTextStyle。
class AppText {
  AppText._();

  // ---- 全局语义档 ----

  /// 主标题（页面标题 / 卡片标题 20）
  static const TextStyle title = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.bold,
    height: 1.2,
  );

  /// 次级标题（紧凑卡片 18）
  static const TextStyle titleCompact = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.bold,
    height: 1.2,
  );

  /// 正文（卡片摘要 16；编辑器正文 14 可在此基础上 copyWith 收敛，属 P1-19）
  static const TextStyle body = TextStyle(
    fontSize: 16,
    height: 1.2,
  );

  /// 时间戳 / 小标签（13 w600）
  static const TextStyle caption = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    height: 1.2,
  );

  /// 说明文字（12）
  static const TextStyle label = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.2,
  );
}
