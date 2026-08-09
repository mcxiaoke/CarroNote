/*
* Copyright (C) Keshav Priyadarshi and others - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
*
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

// Package imports:
// 主题引擎接入点（插拔点）：当前使用 flex_color_scheme (FCS)。
// 业务代码一律通过 Theme.of(context).colorScheme.* 取色，不直接依赖任何主题库；
// 将来要替换主题引擎，只需重写本文件 AppThemes，业务层零改动。
import 'package:flex_color_scheme/flex_color_scheme.dart';

// Project imports:
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/utils/platform_ui.dart';
import 'package:safenotes/utils/window_title_bar.dart';

class ThemeProvider extends ChangeNotifier {
  ThemeProvider() {
    // 启动时把已保存的主题同步到 Windows 标题栏（非 Windows 平台无副作用）。
    syncWindowsTitleBar(isDarkMode);
  }

  ThemeMode themeMode = PreferencesStorage.isThemeDark
      ? ThemeMode.dark
      : ThemeMode.light;

  bool get isDarkMode => themeMode == ThemeMode.dark;

  void setIsDarkMode(bool isDark) {
    themeMode = isDark ? ThemeMode.dark : ThemeMode.light;
    PreferencesStorage.setIsThemeDark(isDark);
    syncWindowsTitleBar(isDark);
    notifyListeners();
  }
}

class AppThemes {
  // 插拔点：品牌种子色（Nord frost 蓝调）。换主题库时通常只需改这一处。
  static const Color _brandSeed = Color(0xFF5E81AC);

  // 亮/暗共用一套配置，仅 brightness 不同。
  // 用 Flutter 内置 ColorScheme.fromSeed 生成和谐、对比度合规的 M3 调色板，
  // 再交给 FCS 包装（应用表面色调、组件默认值等增强）。
  static ThemeData _build(Brightness brightness) {
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: _brandSeed,
      brightness: brightness,
    );
    // 用平台原生字体（Windows=Segoe UI 等）替代原先全局强制的 NotoSerif 衬线体，
    // 让桌面端更贴近原生观感；移动端返回 null 沿用系统默认字体。
    final TextTheme uiText = applyUiFont(
      (brightness == Brightness.light ? ThemeData.light() : ThemeData.dark())
          .textTheme,
    );

    return (brightness == Brightness.light
        ? FlexThemeData.light
        : FlexThemeData.dark)(
      colorScheme: scheme,
      useMaterial3: true,
      // 组件级微调：统一圆角，桌面端更协调（M3 默认按钮/输入/卡片圆角各异）。
      subThemesData: const FlexSubThemesData(
        defaultRadius: 8.0,
      ),
      textTheme: uiText,
      primaryTextTheme: uiText,
    );
  }

  static ThemeData get lightTheme => _build(Brightness.light);

  static ThemeData get darkTheme => _build(Brightness.dark);

  // 设置页背景（无 context，给固定语义值；后续可改为 Theme.of(context).colorScheme.surface）
  // 深色不再用纯黑，改用 Windows 风格的深灰 #202020，更接近系统设置页。
  static Color get darkSettingsScaffold => const Color(0xFF202020);
  static Color? get darkSettingsCanvas => Colors.grey.shade900;
}
