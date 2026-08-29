/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

import 'package:flutter/material.dart';

/// 动画时长 / 曲线令牌（P1-11）：跨页面动画节奏统一，禁止散落 150/250/300/500ms。
class AppMotion {
  AppMotion._();

  /// 选项切换、icon 替换等即时反馈（原 100ms → 120ms）
  static const Duration fast = Duration(milliseconds: 120);

  /// 卡片 hover/press、键盘避让（原 150/300ms → 220ms）
  static const Duration normal = Duration(milliseconds: 220);

  /// 抽屉进出、长滚动（原 500ms → 320ms）
  static const Duration slow = Duration(milliseconds: 320);

  /// 页面 push / 卡片转场（250ms：过长时编辑页 FittedBox 缩放渲染易掉帧，保持原值）
  static const Duration pageTransition = Duration(milliseconds: 250);

  // 曲线
  static const Curve standard = Curves.easeOutCubic;
  static const Curve emphasized = Curves.easeInOutCubic;
}
