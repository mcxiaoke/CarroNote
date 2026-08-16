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

import 'package:flutter/material.dart';

import 'package:safenotes/data/preference_repository.dart';
import 'package:safenotes/models/theme_seeds.g.dart';
import 'package:safenotes/utils/platform_ui.dart';
import 'package:safenotes/utils/window_title_bar.dart';

class ThemeProvider extends ChangeNotifier {
  ThemeProvider({required this._prefs}) {
    // 启动时把已保存的主题同步到 Windows 标题栏（非 Windows 平台无副作用）。
    syncWindowsTitleBar(isDarkMode);
    // 偏好变化（含其它页面写入 isthemedark / 跟随系统开关）时重建主题树。
    _prefs.addListener(_onPrefsChanged);
    // 系统亮度变化（「跟随系统」开启时）需实时生效。
    WidgetsBinding.instance.platformDispatcher.onPlatformBrightnessChanged =
        _onPlatformBrightnessChanged;
  }

  final PreferencesRepository _prefs;

  /// 当前明暗：实时反映 PreferencesRepository 的有效值
  /// （「跟随系统」开启时返回系统亮度，否则返回显式设置）。
  /// 用 getter 实时计算，避免构造期一次性快照导致的启动竞态 / 不再刷新。
  ThemeMode get themeMode =>
      _prefs.isThemeDark ? ThemeMode.dark : ThemeMode.light;

  // 主题色（seed 色库）二维索引：组 + 组内颜色。
  // 默认 0 / 0 = 第一组（「通用」稳定默认组）第一个颜色。
  int get _groupIndex => _prefs.themeGroupIndex;
  int get _colorIndex => _prefs.themeColorIndex;

  int get groupIndex => _groupIndex;

  int get colorIndex => _colorIndex;

  /// 当前主题 seed 色（按明暗自适应：seed 相同，ColorScheme.fromSeed 自动适配暗色）。
  Color get seedColor => AppThemeSeeds.colorByIndex(_groupIndex, _colorIndex);

  bool get isDarkMode => themeMode == ThemeMode.dark;

  void _onPrefsChanged() {
    syncWindowsTitleBar(isDarkMode);
    notifyListeners();
  }

  void _onPlatformBrightnessChanged() {
    // 跟随系统模式下系统亮度变化需重建；非跟随模式 getter 本身已正确，无副作用。
    notifyListeners();
  }

  void setIsDarkMode(bool isDark) {
    _prefs.setIsThemeDark(isDark);
    _prefs.setSystemDarkLightSwitchEnabled(false);
    syncWindowsTitleBar(isDark);
    notifyListeners();
  }

  /// 实时切换主题色：更新索引 → 持久化 → 全局重建主题树。
  void setThemeColor(int groupIndex, int colorIndex) {
    if (groupIndex == _groupIndex && colorIndex == _colorIndex) return;
    _prefs.setThemeGroupIndex(groupIndex);
    _prefs.setThemeColorIndex(colorIndex);
    notifyListeners();
  }

  @override
  void dispose() {
    _prefs.removeListener(_onPrefsChanged);
    final dispatcher = WidgetsBinding.instance.platformDispatcher;
    if (dispatcher.onPlatformBrightnessChanged == _onPlatformBrightnessChanged) {
      dispatcher.onPlatformBrightnessChanged = null;
    }
    super.dispose();
  }
}

class AppThemes {
  // 亮/暗共用一套配置，仅 brightness 不同。
  // 用 Flutter 内置 ColorScheme.fromSeed 生成和谐、对比度合规的 M3 调色板，
  // 再生成原生 ThemeData（不再依赖 flex_color_scheme）。
  static ThemeData build(Color seed, Brightness brightness) {
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );
    // 用平台原生字体（Windows=Segoe UI 等）替代原先全局强制的 NotoSerif 衬线体，
    // 让桌面端更贴近原生观感；移动端返回 null 沿用系统默认字体。
    final TextTheme uiText = applyUiFont(
      (brightness == Brightness.light ? ThemeData.light() : ThemeData.dark())
          .textTheme,
    );

    final ThemeData base = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      // 组件级微调：统一圆角，桌面端更协调（M3 默认按钮/输入/卡片圆角各异）。
      // 对应原 flex_color_scheme 的 FlexSubThemesData(defaultRadius: 8)。
      cardTheme: const CardThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
        ),
      ),
      textTheme: uiText,
      primaryTextTheme: uiText,
    );

    // 全局按钮/输入框统一（兜底所有未显式定制样式的裸控件）：
    //   - AppButton / DialogActionBar 用自身显式 style，不受以下 theme 影响；
    //   - 各设置页/对话框里的 FilledButton/OutlinedButton/ElevatedButton/TextButton
    //     与 TextFormField/TextField 统一尺寸、圆角、字号。
    final bool desktop = isDesktopPlatform;
    final double radius = desktop ? 8 : 12;
    final ButtonStyle secondaryBtn = ButtonStyle(
      minimumSize: WidgetStatePropertyAll(const Size(0, 48)),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
      ),
      textStyle: WidgetStatePropertyAll(
        TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    );
    final ButtonStyle textBtn = ButtonStyle(
      minimumSize: WidgetStatePropertyAll(const Size(0, 48)),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
      ),
      textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 16)),
    );
    final OutlineInputBorder inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(radius),
    );

    return base.copyWith(
      // 页面背景用 M3 的 surfaceContainerLow（亮色 #f3f3fa / 暗色 #191c20）：
      // 相比默认 surface（近白/近黑）更柔和，带轻微品牌色相，缓解
      // 「亮色死白、暗色死黑」的观感；仍属中性表面，不破坏整体风格。
      scaffoldBackgroundColor: scheme.surfaceContainerLow,
      // AppBar 滚动时不再叠加 surfaceTint 染色（之前主界面"安全笔记"标题
      // 滚动会变色；FCS 默认开了 surfaceTint，需要显式关闭）。
      appBarTheme: base.appBarTheme.copyWith(
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      filledButtonTheme: FilledButtonThemeData(style: secondaryBtn),
      outlinedButtonTheme: OutlinedButtonThemeData(style: secondaryBtn),
      elevatedButtonTheme: ElevatedButtonThemeData(style: secondaryBtn),
      textButtonTheme: TextButtonThemeData(style: textBtn),
      inputDecorationTheme: InputDecorationTheme(
        contentPadding: EdgeInsets.symmetric(
          horizontal: 16,
          vertical: desktop ? 12 : 14,
        ),
        border: inputBorder,
        enabledBorder: inputBorder,
        focusedBorder: inputBorder,
      ),
    );
  }

  static ThemeData light(Color seed) => build(seed, Brightness.light);

  static ThemeData dark(Color seed) => build(seed, Brightness.dark);
}
