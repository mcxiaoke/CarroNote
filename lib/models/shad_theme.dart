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
// 中性灰度 seed 走 neutral 变体（见 seed_scheme.dart），明暗跟随全局暗色开关，
// 与彩色 seed 行为一致。两端共用 buildSeedColorScheme。

import 'package:flutter/material.dart';

import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/models/seed_scheme.dart';
import 'package:safenotes/utils/platform_ui.dart';

class ShadThemes {
  static ShadThemeData build(Color seed, Brightness brightness) {
    // ── 色板生成（固定 2 次 fromSeed） ──────────────────────────────
    // 主色板：当前 seed + 当前明暗 → Shad 控件中 primary/secondary/accent/ring/selection
    // 等品牌相关色的来源。
    final ColorScheme base = buildSeedColorScheme(seed, brightness);

    // 亮色板：当前 seed + 固定 light → 提供稳定亮色色值：
    // 暗色模式下 M3 会把 error 提亮成浅粉（与 primary 被提亮同理），不符合红色危险语义；
    // 亮色板的 error 保持用户认知里的红色（如 #ba1a1a + 白字），亮/暗两种模式观感一致。
    final ColorScheme light = buildSeedColorScheme(seed, Brightness.light);

    // ── 语义化色值提取（与 app_theme.dart 命名对齐，消除跨文件困惑） ──

    // 填充控件色（ShadButton / ShadSwitch）：统一用主色板 primaryContainer。
    // 中性 seed 已改用 DynamicSchemeVariant.neutral，色阶自带辨识度，无需品牌色板兜底。
    final Color filledBtnBg = base.primaryContainer;
    final Color filledBtnFg = base.onPrimaryContainer;

    // 错误色：固定用亮色板的 error，避免暗色下被提亮成浅粉。
    final Color errorColor = light.error;
    final Color onErrorColor = light.onError;

    // 中性基底沿用 Slate（背景/卡片/边框等不随品牌色走，保持页面观感稳定），
    // 品牌相关色全部映射到 M3 色板。
    final scheme =
        (brightness == Brightness.light
                ? const ShadNeutralColorScheme.light()
                : const ShadNeutralColorScheme.dark())
            .copyWith(
              primary: base.primary,
              primaryForeground: base.onPrimary,
              secondary: base.secondary,
              secondaryForeground: base.onSecondary,
              accent: base.primaryContainer,
              accentForeground: base.onPrimaryContainer,
              destructive: errorColor,
              destructiveForeground: onErrorColor,
              ring: base.primary,
              selection: base.primary.withValues(alpha: 0.2),
              card: base.surfaceBright,
            );

    return ShadThemeData(
      brightness: brightness,
      colorScheme: scheme,
      // 全局字体：覆盖 shadcn 默认 Geist，使「字体类型」设置对整个 App（含
      // ShadXxx 组件）生效。family 为 null（移动/Web 非衬线）时回落到 shadcn 默认族。
      textTheme: ShadTextTheme(family: uiFontFamily),
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
      // 填充：用 M3 中性表面阶梯的 surfaceContainer（比页面底色 surfaceContainerLow
      // 恰好一档），亮/暗两种模式都保持可辨的微弱对比，且随 seed 色与明暗自动适配、
      // 不写死固定颜色。ShadInputTheme.merge 会把默认 variant 的 outline 边框与此
      // decoration 合并，所以边框不会丢。
      inputTheme: ShadInputTheme(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: ShadDecoration(color: base.surfaceContainer),
      ),
      // 按钮文字随 48 高度放大一档（14→16），与 Material 按钮视觉一致；link 保持原样。
      // 填充主按钮：背景用 primaryContainer，文字用 onPrimaryContainer。
      // 注意不能把全局 colorScheme.primary 改成 primaryContainer——outline/link 按钮的
      // 文字就是拿 primary 当前景色的，那样会让它们变成浅色而压不住浅背景。
      // 所以只在此处单独覆盖填充按钮。
      primaryButtonTheme: ShadButtonTheme(
        backgroundColor: filledBtnBg,
        foregroundColor: filledBtnFg,
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      destructiveButtonTheme: ShadButtonTheme(
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      // 描边色改用主色 primary（替代默认 colorScheme.input 的中性灰边框），
      // 仅作用于 outline 变体（不影响 primary/secondary/ghost 变体）。
      outlineButtonTheme: ShadButtonTheme(
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        // decoration: ShadDecoration(
        //   border: ShadBorder.all(
        //     color: base.primary,
        //     width: 1,
        //     radius: BorderRadius.circular(8),
        //     padding: const EdgeInsets.all(1),
        //   ),
        // ),
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
        uncheckedTrackColor: base.surfaceContainerHighest,
        thumbColor: scheme.background,
        checkedTrackColor: base.primary,
      ),
      // 对话框背景：用 M3 的 surfaceContainerHigh，与 app_dialogs 里系统 M3
      // AlertDialog 的默认表面（colorScheme.surfaceContainerHigh）保持一致；
      // 替代 shadcn Slate 默认的「纯白(亮)/纯黑(暗)」background，随明暗与 seed
      // 自动适配，绝不刺眼的纯白纯黑。覆盖后，桌面 ShadDialog
      // （导出备份弹窗、各类 showAppDialog 弹窗）默认即使用此背景。
      primaryDialogTheme: ShadDialogTheme(
        backgroundColor: base.surfaceContainerHigh,
      ),
      alertDialogTheme: ShadDialogTheme(
        backgroundColor: base.surfaceContainerHigh,
      ),
    );
  }
}
