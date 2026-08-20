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
import 'package:flutter/services.dart' show SystemUiOverlayStyle;

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/seed_scheme.dart';
import 'package:safenotes/models/theme_seeds.g.dart';
import 'package:safenotes/utils/platform_ui.dart';
import 'package:safenotes/utils/window_title_bar.dart';

/// 中性（monochrome）主题的强调色 seed：app 品牌彩色「奶油黄」。
/// 用它经 fromSeed 生成一套自适应 M3 色板，从中取 primary 系用到填充按钮/Switch/
/// SegmentedButton 等大色块控件（替代写死颜色，可随品牌色自适应）；表面/文字/icon/
/// outline 保持中性，不混入这套色板。
const Color kNeutralBrandPrimary = Color(0xFFFBDD82);

/// 全局：当前主题是否为单色（monochrome / 中性灰度）模式。
///
/// 由 [ThemeProvider] 在启动与切换主题色时同步更新；供笔记卡等组件在 build 时读取，
/// 以决定素净中性下的特殊表现（如卡片背景改用 surfaceContainerLowest 与页面背景拉开对比）。
/// 纯读全局变量，值变化随 [ThemeProvider.notifyListeners] 触发整树重建而生效。
bool isMonochromeMode = false;

class ThemeProvider extends ChangeNotifier {
  ThemeProvider() {
    // 启动时把已保存的主题同步到 Windows 标题栏（非 Windows 平台无副作用）。
    syncWindowsTitleBar(isDarkMode);
    // 同步单色模式标记（供笔记卡等组件 build 时读取）。
    isMonochromeMode = isNeutralSeed(seedColor);
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

  /// 外部偏好（如全局字体类型）变更后，主动触发主题树重建，使全 App 生效。
  void notifyThemeChanged() => notifyListeners();

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
    // 同步单色模式标记（供笔记卡等组件 build 时读取）。
    isMonochromeMode = isNeutralSeed(seedColor);
    notifyListeners();
  }
}

class AppThemes {
  // 亮/暗共用一套配置，仅 brightness 不同。
  // 用 Flutter 内置 ColorScheme.fromSeed 生成和谐、对比度合规的 M3 调色板，
  // 再生成原生 ThemeData（不再依赖 flex_color_scheme）。
  static ThemeData build(Color seed, Brightness brightness) {
    final ColorScheme scheme = buildSeedColorScheme(seed, brightness);
    final bool neutral = isNeutralSeed(seed);
    // AppBar/状态栏统一用「亮色板」的品牌深色：深色模式下 M3 会把 primary 提亮成
    // 浅色（中性 seed 甚至变纯白），AppBar 会刺眼；亮色板的 primary 才是用户
    // 认知里的"按钮深色"（黑 seed=纯黑、蓝 seed=深蓝），且两种模式外观稳定。
    final ColorScheme appBarScheme = buildSeedColorScheme(
      seed,
      Brightness.light,
    );
    // 危险/错误色同样固定用亮色板的 error：M3 暗色面板会把 error 提亮成浅粉
    // （Material 组件的 error 色源），亮色板的 #ba1a1a 才是用户认知里的红。
    // 中性 seed 不改全局 primary（否则会污染 outline/icon/背景），按钮/Switch 等的
    // 死黑问题改在组件级（filledButtonTheme/switchTheme/segmentedButtonTheme）单独处理。
    final ColorScheme fixedScheme = scheme.copyWith(
      error: appBarScheme.error,
      onError: appBarScheme.onError,
    );
    // 中性主题的强调色板：用品牌 seed 经 fromSeed 生成自适应 M3 色板（纯内存计算，
    // 极快），从中取 primary 系用于大色块控件，随品牌色自适应且对比度合规。
    final ColorScheme brandScheme = buildSeedColorScheme(kNeutralBrandPrimary, brightness);
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
    // 中性主题：有填充的大色块按钮（FilledButton/ElevatedButton）底色改用品牌色板
    // 的 primaryContainer（随品牌色自适应、对比度合规），避免 monochrome 的 primary
    // 死黑；只作用于填充按钮，不碰全局 primary（因此 outline/icon/背景等不会被着色）。
    final ButtonStyle neutralFilledBtn = ButtonStyle(
      minimumSize: WidgetStatePropertyAll(const Size(0, 48)),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
      ),
      textStyle: WidgetStatePropertyAll(
        TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      backgroundColor: WidgetStatePropertyAll(brandScheme.primaryContainer),
      foregroundColor: WidgetStatePropertyAll(brandScheme.onPrimaryContainer),
    );
    final OutlineInputBorder inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(radius),
    );
    // AppBar 底色：
    // - 暗色模式：M3 默认 AppBar 表面色（scheme.surface），由系统/全局暗色统一处理；
    // - 亮色模式 + 彩色 seed：用「亮色板」品牌深色（appBarScheme.primaryContainer）
    //   染色，保证暗色主题下 AppBar 不刺眼（沿用原 hack）；
    // - 亮色模式 + 中性 seed：AppBar 直接用 seed 色作底色，得到连续灰度递进
    //   （白→浅灰→深灰→黑），前景/状态栏图标按 seed 亮度取黑/白保证对比度，
    //   不再落入 monochrome 固定 tone（无灰度递进）或 primaryContainer 的 tone 25 暗灰。
    final bool darkMode = brightness == Brightness.dark;
    final Color appBarBg = darkMode
        ? scheme.surface
        : (neutral ? seed : appBarScheme.primaryContainer);
    final Color appBarFg = darkMode
        ? scheme.onSurface
        : (neutral
            ? (seed.computeLuminance() > 0.179 ? Colors.black : Colors.white)
            : appBarScheme.onPrimaryContainer);
    final Brightness appBarStatusBarIcons = darkMode
        ? Brightness.light
        : (neutral
            ? (seed.computeLuminance() > 0.179 ? Brightness.dark : Brightness.light)
            : Brightness.dark);
    final SystemUiOverlayStyle? appBarOverlay = darkMode
        ? null
        : SystemUiOverlayStyle(
            statusBarColor: appBarBg,
            statusBarIconBrightness: appBarStatusBarIcons,
          );

    return base.copyWith(
      // 页面背景用 M3 的 surfaceContainerLow（亮色 #f3f3fa / 暗色 #191c20）：
      // 相比默认 surface（近白/近黑）更柔和，带轻微品牌色相，缓解
      // 「亮色死白、暗色死黑」的观感；仍属中性表面，不破坏整体风格。
      scaffoldBackgroundColor: scheme.surfaceContainerLow,
      appBarTheme: base.appBarTheme.copyWith(
        backgroundColor: appBarBg,
        foregroundColor: appBarFg,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        systemOverlayStyle: appBarOverlay,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: neutral ? neutralFilledBtn : secondaryBtn,
      ),
      // 描边色改用主色 primary（替代默认 colorScheme.outline 的中性灰），
      // 让 outline 按钮与主题色一致。只在 outlinedButtonTheme 上加 side，
      // 不碰共用的 secondaryBtn，避免误给 TextButton 加边框。
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: secondaryBtn.copyWith(
          side: WidgetStatePropertyAll(BorderSide(color: scheme.primary)),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: neutral ? neutralFilledBtn : secondaryBtn,
      ),
      textButtonTheme: TextButtonThemeData(style: textBtn),
      // 中性主题：Switch 选中轨道/滑块、SegmentedButton 选中段改用品牌色板的
      // primaryContainer/onPrimaryContainer（自适应、对比度合规），避免死黑。
      switchTheme: neutral
          ? SwitchThemeData(
              trackColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? brandScheme.primaryContainer
                    : null,
              ),
              thumbColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? brandScheme.onPrimaryContainer
                    : null,
              ),
            )
          : null,
      segmentedButtonTheme: neutral
          ? SegmentedButtonThemeData(
              style: ButtonStyle(
                backgroundColor: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.selected)
                      ? brandScheme.primaryContainer
                      : null,
                ),
                foregroundColor: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.selected)
                      ? brandScheme.onPrimaryContainer
                      : null,
                ),
              ),
            )
          : null,
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
