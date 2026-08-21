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

import 'package:core/core.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/seed_scheme.dart';
import 'package:safenotes/models/theme_seeds.g.dart';
import 'package:safenotes/utils/contrast.dart';
import 'package:safenotes/utils/platform_ui.dart';
import 'package:safenotes/utils/window_title_bar.dart';

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
    Log.settings.i(
      'DarkMode 切换 → ${isDark ? "dark" : "light"} | '
      'seed=$seedColor neutral=$isMonochromeMode',
    );
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
    Log.settings.i(
      '主题色切换 → group=$groupIndex color=$colorIndex '
      'seed=$seedColor neutral=$isMonochromeMode dark=$isDarkMode',
    );
    notifyListeners();
  }
}

class AppThemes {
  // ── 重构说明：色板精简与语义化 ──────────────────────────────────────
  //
  // 旧版同时维护 scheme / appBarScheme / fixedScheme / brandScheme 多套色板对象，
  // 命名混乱、职责不清（appBarScheme 实为亮色板，fixedScheme 只是 base 改 error）。
  // 新版改为「2 个语义对象」：
  //   base  ── 主色板（当前 seed + 当前 brightness），全局色值来源。
  //   light ── 亮色板（当前 seed + Brightness.light），提供亮色模式下的稳定色值：
  //           AppBar 品牌深色、error 红色（暗色下 M3 会把它提亮成浅粉，观感失真）。
  //
  // 中性 seed 已改用 DynamicSchemeVariant.neutral 生成，primaryContainer 自带可辨识的中性色阶，
  // 不再需要注入品牌色板（奶油黄）做兜底。填充控件色统一取主色板，
  // 所有模式一套逻辑，无需「中性/非中性」分支判断。
  //
  // 所有组件级色值通过语义化变量（errorColor / filledBtnBg / appBarBg 等）获取，
  // 注释直接说明用途，消除「为什么用这个色板」的困惑。
  // ──────────────────────────────────────────────────────────────────

  /// 亮/暗共用一套配置，仅 brightness 不同。
  /// 用 Flutter 内置 ColorScheme.fromSeed 生成和谐、对比度合规的 M3 调色板，
  /// 再生成原生 ThemeData（不再依赖 flex_color_scheme）。
  static ThemeData build(Color seed, Brightness brightness) {
    // ── 色板生成（固定 2 次 fromSeed） ──────────────────────────────
    // 主色板：当前 seed + 当前明暗 → 页面/卡片/文字/轮廓的全部基础色值来源。
    final ColorScheme base = buildSeedColorScheme(seed, brightness);

    // 亮色板：当前 seed + 固定 light → 提供稳定亮色色值，不随暗色切换而变化。
    // 暗色模式下 M3 会把 primary / error 提亮成浅色/浅粉，不符合用户认知，
    // 亮色板的 error 保持用户认知里的红色（如 #ba1a1a），亮暗两种模式观感一致。
    final ColorScheme light = buildSeedColorScheme(seed, Brightness.light);

    final bool neutral = isNeutralSeed(seed);

    // ── 语义化色值提取（消除「用哪个色板」的困惑） ─────────────────

    // 1. 错误色：固定用亮色板的 error，避免暗色下被提亮成浅粉（与 primary 被提亮同理）。
    final Color errorColor = light.error;
    final Color onErrorColor = light.onError;

    // 2. 填充控件色（FilledButton / ElevatedButton / Switch / SegmentedButton 等）。
    //    中性 seed 已改用 DynamicSchemeVariant.neutral，primaryContainer 自带可辨识中性色阶，
    //    所有模式统一取主色板 primaryContainer，无需品牌色板兜底。
    final Color filledBtnBg = base.primaryContainer;
    final Color filledBtnFg = base.onPrimaryContainer;

    // 3. AppBar 颜色：
    //    - 暗色模式：M3 默认表面色（base.surface），由系统/全局暗色统一处理；
    //    - 亮色 + 彩色 seed：亮色板容器色（light.secondaryContainer），亮暗稳定；
    //    - 亮色 + 中性 seed：直接用 seed 色作底色，连续灰度递进（白→浅灰→深灰→黑），
    //      不再落入 monochrome 固定 tone（无灰度递进）或 primaryContainer 的 tone 25 暗灰。
    final bool darkMode = brightness == Brightness.dark;
    final Color scaffoldBgColor = darkMode
        ? base.surfaceContainerLow
        : base.surfaceContainerLow;
    final Color appBarBg = darkMode
        ? base.surfaceContainer
        : (neutral ? seed : light.secondaryContainer);
    final Color appBarFg = darkMode
        ? base.onSurface
        : (neutral
              ? getFontColorForBackground(seed)
              : light.onSecondaryContainer);
    final Brightness appBarStatusBarIcons = darkMode
        ? Brightness.light
        : (neutral
              ? (appBarFg == Colors.black ? Brightness.dark : Brightness.light)
              : Brightness.dark);
    final SystemUiOverlayStyle? appBarOverlay = darkMode
        ? null
        : SystemUiOverlayStyle(
            statusBarColor: appBarBg,
            statusBarIconBrightness: appBarStatusBarIcons,
          );

    // 用平台原生字体（Windows=Segoe UI 等）替代原先全局强制的 NotoSerif 衬线体，
    // 让桌面端更贴近原生观感；移动端返回 null 沿用系统默认字体。
    final TextTheme uiText = applyUiFont(
      (darkMode ? ThemeData.dark() : ThemeData.light()).textTheme,
    );

    // ── ThemeData 基础构建 ──────────────────────────────────────────
    // 错误色在 ThemeData 层级覆盖（替代旧版 fixedScheme 对象），Material 组件全局取 error
    // 色时自动生效，无需逐个组件显式改。
    final ThemeData themeBase = ThemeData(
      colorScheme: base.copyWith(error: errorColor, onError: onErrorColor),
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

    // ── 按钮与输入框共享样式 ─────────────────────────────────────────
    final bool desktop = isDesktopPlatform;
    final double radius = desktop ? 8 : 12;

    // 通用按钮骨架：48 高度 + 统一圆角 + 16 字号，所有按钮变体在此基础上衍生。
    final ButtonStyle btnBase = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(0, 48)),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
      ),
    );

    // 次级按钮（OutlinedButton）：字重 600，无边框色（由 outedButtonTheme 单独加 primary 描边）。
    final ButtonStyle secondaryBtn = btnBase.copyWith(
      textStyle: const WidgetStatePropertyAll(
        TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    );

    // 文字按钮（TextButton）：字重 400，用于低强调操作。
    final ButtonStyle textBtn = btnBase.copyWith(
      textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 16)),
    );

    // 填充按钮（FilledButton / ElevatedButton）：统一用主色板 primaryContainer，
    // 中性 seed 已改用 DynamicSchemeVariant.neutral，色阶自带辨识度。
    final ButtonStyle filledBtn = btnBase.copyWith(
      textStyle: const WidgetStatePropertyAll(
        TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      backgroundColor: WidgetStatePropertyAll(filledBtnBg),
      foregroundColor: WidgetStatePropertyAll(filledBtnFg),
    );

    final OutlineInputBorder inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(radius),
    );

    // ── 组件主题覆盖 ─────────────────────────────────────────────────
    return themeBase.copyWith(
      // 页面背景用 M3 的 surfaceContainerLow（亮色 #f3f3fa / 暗色 #191c20）：
      // 相比默认 surface（近白/近黑）更柔和，带轻微品牌色相，缓解「亮色死白、暗色死黑」的观感。
      scaffoldBackgroundColor: scaffoldBgColor,
      appBarTheme: themeBase.appBarTheme.copyWith(
        backgroundColor: appBarBg,
        foregroundColor: appBarFg,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        systemOverlayStyle: appBarOverlay,
      ),
      // highlightColor
      splashColor: base.secondary.withValues(alpha: 0.12),   // 水波纹
      highlightColor: base.secondary.withValues(alpha: 0.08), // 按下时的实色高亮
      hoverColor: base.secondary.withValues(alpha: 0.06),    // 桌面 hover(可选)

      // 填充按钮：统一用主色板 primaryContainer。
      filledButtonTheme: FilledButtonThemeData(style: filledBtn),
      // 描边按钮：描边色改用主色 primary（替代默认 colorScheme.outline 的中性灰），
      // 让 outline 按钮与主题色一致。只覆盖 outlinedButtonTheme，不碰 textBtn，避免误给 TextButton 加边框。
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: secondaryBtn.copyWith(
          side: WidgetStatePropertyAll(BorderSide(color: base.primary)),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(style: filledBtn),
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
