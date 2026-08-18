/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

// 将 shadcn_ui 的 ShadTheme 对接到 Safenotes 的动态品牌色（seed 色库）。
//
// 只作用于 ShadXxx 组件；旧 Material 页面仍由 M3 ColorScheme.fromSeed 生成的 ThemeData 主题化。
// 两套设计系统通过 ShadApp 并存，互不干扰。
//
// 品牌色由 ThemeProvider.seedColor 动态传入：FCS 与 Shad 必须同步换色，
// 否则会出现「按钮是新色、列表卡片是旧色」的割裂。
//
// 关键设计：品牌相关色一律用 M3 的 ColorScheme.fromSeed 生成，而不是直接把
// seed 塞给 Shad。fromSeed 会自动为任意 seed 推导对比度合规的 onXxx 前景色
// （暗色模式下 primary 自动提亮、文字自动变深），保证任何主题色下按钮/开关/
// 选中项都清晰可读，无需手调 —— 这正是「主题色自适应」的意义。
//
// 中性灰度 seed 走 monochrome 变体（方案 A+C，见 seed_scheme.dart），避免被染成
// 任意彩色；明暗跟随全局暗色开关，与彩色 seed 行为一致。两端共用 buildSeedColorScheme。

import 'package:flutter/material.dart';

import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/models/seed_scheme.dart';

class ShadThemes {
  static ShadThemeData build(Color seed, Brightness brightness) {
    // M3 算法：为当前 seed 生成明暗自适应的完整色板（含 onPrimary/onSecondary/
    // onError 等对比前景色）。中性 seed 走 monochrome（色度 0），对比度仍由算法保证。
    final m3 = buildSeedColorScheme(seed, brightness);
    // 危险/错误色恒定用「亮色板」的 error：暗色模式下 M3 会把 error 提亮成
    // 浅粉（与 primary 被提亮同理），不符合红色危险语义；亮色板的 error 才是
    // 用户认知里的红色（如 #ba1a1a + 白字），亮/暗两种模式观感一致。
    final ColorScheme errorScheme = buildSeedColorScheme(
      seed,
      Brightness.light,
    );

    // 中性基底沿用 Slate（背景/卡片/边框等不随品牌色走，保持页面观感稳定），
    // 品牌相关色全部映射到 M3 色板。
    final scheme =
        (brightness == Brightness.light
                ? const ShadSlateColorScheme.light()
                : const ShadSlateColorScheme.dark())
            .copyWith(
              primary: m3.primary,
              primaryForeground: m3.onPrimary,
              secondary: m3.secondary,
              secondaryForeground: m3.onSecondary,
              accent: m3.primaryContainer,
              accentForeground: m3.onPrimaryContainer,
              destructive: errorScheme.error,
              destructiveForeground: errorScheme.onError,
              ring: m3.primary,
              selection: m3.primary.withValues(alpha: 0.2),
            );

    return ShadThemeData(
      brightness: brightness,
      colorScheme: scheme,
      // 统一按钮高度为 48（手指触控标准，桌面/移动端一致）：
      // 只覆盖 regular，sm/lg/icon 保持 shadcn 默认（ShadApp 内 merge 保底），
      // 因此所有未显式指定 size 的 ShadButton 都会统一变 48，无需逐个改。
      buttonSizesTheme: const ShadButtonSizesTheme(
        regular: ShadButtonSizeTheme(
          height: 48,
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        ),
      ),
      // 输入框与按钮同高（48）：外层 minHeight 垫高 + 对称大内边距使文字垂直居中，
      // 避免「minHeight 只把内容顶到上方、底部留空」的偏上观感。
      // 仅在此覆盖，未显式指定 padding/constraints 的 ShadInput/ShadInputFormField 全部生效。
      inputTheme: const ShadInputTheme(
        constraints: BoxConstraints(minHeight: 48),
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
      // 按钮文字随 48 高度放大一档（14→16），与 Material 按钮视觉一致；link 保持原样。
      // 填充主按钮：背景用 primaryContainer（如奶油色），文字用
      // onPrimaryContainer（深色）。注意不能把全局 colorScheme.primary 改成
      // primaryContainer——outline/link 按钮的文字就是拿 primary 当前景色的，
      // 那样会让它们变成浅色而压不住浅背景。所以只在此处单独覆盖填充按钮。
      primaryButtonTheme: ShadButtonTheme(
        backgroundColor: m3.primaryContainer,
        foregroundColor: m3.onPrimaryContainer,
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      destructiveButtonTheme: ShadButtonTheme(
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      outlineButtonTheme: ShadButtonTheme(
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      secondaryButtonTheme: ShadButtonTheme(
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      ghostButtonTheme: ShadButtonTheme(
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      // switch 未选中轨道默认用 colorScheme.input（暗色 Slate 下 #1e293b 近黑，
      // 偏重）。改用 M3 的 surfaceContainerHighest（暗色 #33353a、亮色 #e1e2e9）
      // —— 同属中性色，但暗色下更柔和、层次更清晰。
      switchTheme: ShadSwitchTheme(
        uncheckedTrackColor: m3.surfaceContainerHighest,
        thumbColor: scheme.background,
      ),
    );
  }
}
