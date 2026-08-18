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
import 'package:flutter/services.dart' show SystemUiOverlayStyle;

// Project imports:
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/seed_scheme.dart';
import 'package:safenotes/models/theme_seeds.g.dart';
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

  // 主题色（seed 色库）二维索引：组 + 组内颜色。
  // 默认 0 / 0 = 第一组（「通用」稳定默认组）第一个颜色。
  int _groupIndex = PreferencesStorage.themeGroupIndex;
  int _colorIndex = PreferencesStorage.themeColorIndex;

  int get groupIndex => _groupIndex;

  int get colorIndex => _colorIndex;

  /// 当前主题 seed 色（按明暗自适应：seed 相同，ColorScheme.fromSeed 自动适配暗色）。
  Color get seedColor => AppThemeSeeds.colorByIndex(_groupIndex, _colorIndex);

  bool get isDarkMode => themeMode == ThemeMode.dark;

  void setIsDarkMode(bool isDark) {
    themeMode = isDark ? ThemeMode.dark : ThemeMode.light;
    PreferencesStorage.setIsThemeDark(isDark);
    syncWindowsTitleBar(isDark);
    notifyListeners();
  }

  /// 实时切换主题色：更新索引 → 持久化 → 全局重建主题树。
  void setThemeColor(int groupIndex, int colorIndex) {
    if (groupIndex == _groupIndex && colorIndex == _colorIndex) return;
    _groupIndex = groupIndex;
    _colorIndex = colorIndex;
    PreferencesStorage.setThemeGroupIndex(groupIndex);
    PreferencesStorage.setThemeColorIndex(colorIndex);
    notifyListeners();
  }
}

class AppThemes {
  // 亮/暗共用一套配置，仅 brightness 不同。
  // 用 Flutter 内置 ColorScheme.fromSeed 生成和谐、对比度合规的 M3 调色板，
  // 再生成原生 ThemeData（不再依赖 flex_color_scheme）。
  static ThemeData build(Color seed, Brightness brightness) {
    final ColorScheme scheme = buildSeedColorScheme(seed, brightness);
    // AppBar/状态栏统一用「亮色板」的品牌深色：深色模式下 M3 会把 primary 提亮成
    // 浅色（中性 seed 甚至变纯白），AppBar 会刺眼；亮色板的 primary 才是用户
    // 认知里的"按钮深色"（黑 seed=纯黑、蓝 seed=深蓝），且两种模式外观稳定。
    final ColorScheme appBarScheme = buildSeedColorScheme(
      seed,
      Brightness.light,
    );
    // 危险/错误色同样固定用亮色板的 error：M3 暗色面板会把 error 提亮成浅粉
    // （Material 组件的 error 色源），亮色板的 #ba1a1a 才是用户认知里的红。
    final ColorScheme fixedScheme = scheme.copyWith(
      error: appBarScheme.error,
      onError: appBarScheme.onError,
    );
    // 用平台原生字体（Windows=Segoe UI 等）替代原先全局强制的 NotoSerif 衬线体，
    // 让桌面端更贴近原生观感；移动端返回 null 沿用系统默认字体。
    final TextTheme uiText = applyUiFont(
      (brightness == Brightness.light ? ThemeData.light() : ThemeData.dark())
          .textTheme,
    );

    final ThemeData base = ThemeData(
      colorScheme: fixedScheme,
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
    // AppBar：亮色用品牌深色（appBarScheme.primary，同按钮色）染色，前景用
    // onPrimary；暗色用 M3 默认 AppBar 背景色（scheme.surface）——观感与
    // 「不设置」一致（带轻微品牌色相），但必须显式赋值：滚动时 _resolveColor
    // 会用 backgroundColor 兜底（app_bar.dart 的 scrolledUnderBackground），
    // 否则传 null 会落到 surfaceContainer，滚动背景变亮一档。
    final bool darkMode = brightness == Brightness.dark;

    return base.copyWith(
      // 页面背景用 M3 的 surfaceContainerLow（亮色 #f3f3fa / 暗色 #191c20）：
      // 相比默认 surface（近白/近黑）更柔和，带轻微品牌色相，缓解
      // 「亮色死白、暗色死黑」的观感；仍属中性表面，不破坏整体风格。
      scaffoldBackgroundColor: scheme.surfaceContainerLow,
      appBarTheme: base.appBarTheme.copyWith(
        backgroundColor:
            darkMode ? scheme.surface : appBarScheme.primaryContainer,
        foregroundColor:
            darkMode ? scheme.onSurface : appBarScheme.onPrimaryContainer,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        systemOverlayStyle: darkMode
            ? null
            : SystemUiOverlayStyle(
                statusBarColor: appBarScheme.primaryContainer,
                statusBarIconBrightness: Brightness.dark,
              ),
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
