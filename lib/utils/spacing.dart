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

/// 间距刻度（P0-2）：全站统一间距，禁止散落的魔法数字。
class AppSpace {
  static const double xs = 4.0;
  static const double sm = 8.0;
  static const double md = 12.0;
  static const double lg = 16.0;
  static const double xl = 20.0;
  static const double xxl = 24.0;

  /// 卡片内边距规范：同类型卡片保持一致（原 note_card all(10) / note_tile h20×v10 收敛于此）。
  static const EdgeInsets cardPadding = EdgeInsets.symmetric(
    horizontal: lg,
    vertical: md,
  );
}

/// 圆角 / 高度刻度（P1-14）：全站圆角三档化（8/12），高度两档化（48/卡片自适应）。
class AppShape {
  /// 输入框、搜索框圆角
  static const double inputRadius = 8.0;

  /// 笔记卡、设置卡片、对话框圆角（与 ShadDialog 一致）
  static const double cardRadius = 12.0;

  /// 按钮圆角
  static const double buttonRadius = 8.0;

  /// 输入框统一高度
  static const double inputHeight = 48.0;

  /// 搜索框高度（与输入框同高，原 44 收敛于此）
  static const double searchHeight = 48.0;
}

/// 图标尺寸刻度（P1-20）：三档全局令牌，禁止局部"按平台调字号"覆写。
class AppIcon {
  /// 列表项 leading（原散落 16/18 收敛于此）
  static const double sm = 16.0;

  /// 输入框 leading/trailing（与 kInputIconSize 一致）
  static const double md = 20.0;

  /// AppBar 按钮 / 主操作图标
  static const double lg = 24.0;
}
