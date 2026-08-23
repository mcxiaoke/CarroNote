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

import 'package:flutter/material.dart';

import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/app_theme.dart';

// 对比度工具（contrastRatio / getFontColorForBackground）已抽到 contrast.dart，
// 此处 re-export 以保住既有调用方（笔记卡 / 回收站 / 测试）的 import 路径不变。
export 'package:safenotes/utils/contrast.dart';

class NotesColor extends ChangeNotifier {
  // 浅色模式下卡片底色提亮比例：原主题色与白色混合，避免深色卡片在浅色界面下显得过重。
  // 0 = 不变，1 = 纯白；0.4 在保留主题色相差异的同时明显提亮。
  static const double _lightenAmount = 0.4;

  /// 未启用彩色笔记时，品牌色叠加在 surfaceContainerLow 上的比例（P1-13）：
  /// 替代写死 `0xFFA7BEAE`，让"无主题"卡片跟随当前 seed 色（如 Honey 黄系），
  /// 且与页面背景（scaffoldBackground ≈ surfaceContainerLow）拉开对比。
  static const double _brandTintAmount = 0.10;

  static Color getNoteColor({required int notIndex, BuildContext? context}) {
    final lightColors =
        allNotesColorTheme[PreferencesStorage.colorfulNotesColorIndex]
            .colorList;
    final isColorful = PreferencesStorage.isColorful;
    final base = isColorful
        ? lightColors[notIndex % lightColors.length]
        : _neutralCardColor(context);
    return _adjustForTheme(base, isColorful, context);
  }

  /// 根据用户设置的 NoteMeta.color 返回卡片底色。
  ///
  /// [metaColor] 为 null 时回退到 [getNoteColor] 按位置取色；
  /// 非 null 时用用户指定颜色，暗色模式下查 [noteColorDarkVariant] 取对应暗色变体。
  static Color getNoteColorWithMeta({
    required int notIndex,
    int? metaColor,
    BuildContext? context,
  }) {
    if (metaColor == null) {
      return getNoteColor(notIndex: notIndex, context: context);
    }
    // 暗色模式：使用 Google Keep 暗色变体（独立设计，保证白字可读）
    if (PreferencesStorage.isThemeDark) {
      return noteColorDarkVariant(metaColor);
    }
    return Color(metaColor);
  }

  /// 编辑页 / 预览页背景色：从 NoteMeta.color 取色并适配主题。
  ///
  /// 与 [getNoteColorWithMeta] 使用同样的暗色变体逻辑。
  /// [metaColor] 为 null 时返回 null，调用方回退到默认 scaffold 背景。
  static Color? editorBackgroundColor({int? metaColor, BuildContext? context}) {
    if (metaColor == null) return null;
    // 暗色模式：使用 Google Keep 暗色变体（独立设计，保证白字可读）
    if (PreferencesStorage.isThemeDark) {
      return noteColorDarkVariant(metaColor);
    }
    return Color(metaColor);
  }

  /// 暗色/浅色模式适配：暗色模式下压暗彩色卡，浅色模式下提亮。
  static Color _adjustForTheme(
    Color base,
    bool isColorful,
    BuildContext? context,
  ) {
    if (PreferencesStorage.isThemeDark) {
      // 暗黑模式：原调配色多为浅/亮色（黄、薄荷、近白等），直接铺在深色背景上
      // 会过亮刺眼。将彩色卡与深色背景混合压暗，保留色相差异的同时回到舒适明度；
      // 非彩色卡已在上游(_neutralCardColor)按背景微调，此处原样返回即可。
      if (!isColorful) return base;
      final darkBase = context != null
          ? Theme.of(context).colorScheme.surfaceContainerLow
          : const Color(0xFF121212);
      return Color.alphaBlend(base.withValues(alpha: 0.5), darkBase);
    }
    // 浅色模式：彩色卡提亮 40% 融入浅色界面；非彩色底色已按背景微调，原样返回。
    return isColorful
        ? (Color.lerp(base, Colors.white, _lightenAmount) ?? base)
        : base;
  }

  /// 关闭彩色时的卡片底色：以页面背景(surfaceContainerLow)为基准，向正确方向微调一档。
  ///
  /// 原实现用 surfaceContainerHighest(彩色主题)/surfaceBright(单色主题) 作为底色，
  /// 但这两档在 M3 容器色阶里与页面背景(surfaceContainerLow)的相对明暗会**随亮度反转**：
  ///   浅色 → 卡片比背景更暗 → 显得太沉闷；
  ///   深色 → 卡片比背景更亮 → 显得太刺眼。
  /// 这正是「明亮模式太暗 / 深色模式太亮、且与笔记颜色开关无关」的根因。
  ///
  /// 现改为显式方向混合：
  /// - 浅色：向白色混合少量 → 卡片比背景略亮、干净不沉；
  /// - 深色：向黑色混合少量 → 卡片比背景略暗、柔和刺眼；
  /// 单色主题不叠加品牌色，仅保留这一档微调；彩色主题再叠 14% 品牌主色带出品相。
  static Color _neutralCardColor(BuildContext? context) {
    if (context == null) return const Color(0xFFA7BEAE); // 兜底（无 context 时）
    final scheme = Theme.of(context).colorScheme;
    final bg = scheme.surfaceContainerLow; // 与首页 scaffold 背景同源
    final base = PreferencesStorage.isThemeDark
        ? Color.alphaBlend(Colors.black.withValues(alpha: 0.08), bg)
        : Color.alphaBlend(Colors.white.withValues(alpha: 0.06), bg);
    if (isMonochromeMode) return base;
    return Color.alphaBlend(
      scheme.primary.withValues(alpha: _brandTintAmount),
      base,
    );
  }

  /// 未启用彩色笔记时的卡片底色（公开入口，供回收站等非笔记列表复用）。
  ///
  /// 与主界面卡片未选择彩色时的颜色完全一致，跟随当前主题 seed 色计算。
  static Color neutralCardColor(BuildContext context) =>
      _neutralCardColor(context);

  /// 通用笔记卡边框：把「是否描边 + 颜色 + 粗细」收敛到一个入口，调用方自行决定。
  ///
  /// - [outline]：是否显示边框；
  /// - [color]：边框色（调用方传入，如单色模式用 scheme.primary）；
  /// - [width]：边框粗细（逻辑像素），默认 1。
  /// 不显示时返回 [ShadBorder.none]，与原行为一致；显示时返回四边同色的 [ShadBorder.all]。
  /// 放在卡片外观模块里，与 [_neutralCardColor] 同源，便于统一治理。
  static ShadBorder cardBorder({
    required bool outline,
    required Color color,
    double width = 1,
  }) {
    return outline
        ? ShadBorder.all(color: color, width: width)
        : ShadBorder.none;
  }

  void toggleColor() {
    PreferencesStorage.setIsColorful(!PreferencesStorage.isColorful);
    notifyListeners();
  }
}

// contrastRatio / getFontColorForBackground 已移至 lib/utils/contrast.dart（见顶部 export）。

/// Google Keep 同款笔记颜色色板 — 浅色模式（11 色）。
///
/// 颜色选择器固定使用此列表，不随主题色板变化；
/// 存入 NoteMeta.color 的始终是**浅色 ARGB 值**作为"颜色身份"，
/// 渲染时按当前主题通过 [noteColorDarkVariant] 查对应的暗色变体。
const List<Color> kNoteColorPalette = [
  Color(0xFFF8A8A0), // 珊瑚红
  Color(0xFFF59B70), // 橙
  Color(0xFFFFF7B3), // 淡黄
  Color(0xFFA8C8D8), // 浅蓝
  Color(0xFFD4E8EF), // 淡青
  Color(0xFFA8DDCF), // 薄荷绿
  Color(0xFFDCF6D0), // 浅绿
  Color(0xFFD0C0E0), // 淡紫
  Color(0xFFF7E2DD), // 粉橘
  Color(0xFFEDE8D8), // 米色
  Color(0xFFF3F3F4), // 灰白
];

/// Google Keep 同款笔记颜色色板 — 暗色模式（11 色）。
///
/// 与 [kNoteColorPalette] 逐一对应：暗色色板是独立设计的（更饱和、更深），
/// 保证白色文字在暗色背景上有足够对比度，不是 alphaBlend 计算出来的。
const List<Color> kNoteColorPaletteDark = [
  Color(0xFFA02838), // 珊瑚红
  Color(0xFF783C24), // 橙
  Color(0xFF885818), // 淡黄
  Color(0xFF284050), // 浅蓝
  Color(0xFF286070), // 淡青
  Color(0xFF246860), // 薄荷绿
  Color(0xFF285840), // 浅绿
  Color(0xFF402858), // 淡紫
  Color(0xFF683848), // 粉橘
  Color(0xFF484438), // 米色
  Color(0xFF242426), // 灰白
];

/// 浅→暗色板映射表，key = 浅色 ARGB，value = 暗色变体。
final Map<int, Color> _lightToDarkColorMap = {
  for (var i = 0; i < kNoteColorPalette.length; i++)
    kNoteColorPalette[i].toARGB32(): kNoteColorPaletteDark[i],
};

/// 根据浅色 ARGB 值返回对应的暗色变体。
///
/// [lightArgb] 必须是 [kNoteColorPalette] 中的某个色值。
/// 用于暗色模式下卡片背景、编辑页背景等渲染场景。
Color noteColorDarkVariant(int lightArgb) {
  return _lightToDarkColorMap[lightArgb] ?? Color(lightArgb);
}

class NotesColorTheme {
  final String prefix;
  final String? helper;
  final List colorList;
  const NotesColorTheme({
    required this.prefix,
    this.helper,
    required this.colorList,
  });
}

List<NotesColorTheme> allNotesColorTheme = [
  const NotesColorTheme(
    prefix: 'Nord Arctic',
    helper: 'Default',
    colorList: [
      Color(0xFF5E81AC),
      Color(0xFFD08770),
      Color(0xFFA3BE8C),
      Color(0xFFB48EAD),
      Color(0xFF81A1C1),
    ],
  ),
  const NotesColorTheme(
    prefix: 'Harmony',
    helper: 'Deep Blue, Northern Sky, Baby Blue and Coffee',
    colorList: [
      Color(0xFF2460A7),
      Color(0xFF85B3D1),
      Color(0xFFB3C7D6),
      Color(0xFFD9B48F),
    ],
  ),
  const NotesColorTheme(
    prefix: 'Blossom',
    helper: 'Soft Pink, Peach Amber, Yucca and Arbor Green',
    colorList: [
      Color(0xFFFFDDE2),
      Color(0xFFFAA094),
      Color(0xFF9ED9CC),
      Color(0xFF008C76),
    ],
  ),
  const NotesColorTheme(
    prefix: 'Peace',
    helper: 'Blue Sky, Elation, Nugget and Celestial',
    colorList: [
      Color(0xFFABD1C9),
      Color(0xFFDFDCE5),
      Color(0xFFDBB04A),
      Color(0xFF97B3D0),
    ],
  ),
  const NotesColorTheme(
    prefix: 'Nostalgic',
    helper: 'Desert Sand, Burnished Brown, Old Burgundy and Mystic',
    colorList: [
      Color(0xFFDBBEA1),
      Color(0xFFA37B73),
      Color(0xFF3E282B),
      Color(0xFFD34F73),
    ],
  ),
  const NotesColorTheme(
    prefix: 'Sapphire',
    helper: 'Sapphire, Light Slate Gray, Cadet Gray and American Silver',
    colorList: [
      Color(0xFF2E5266),
      Color(0xFF6E8898),
      Color(0xFF9FB1BC),
      Color(0xFFD3D0CB),
    ],
  ),
  const NotesColorTheme(
    prefix: 'Ensemble',
    helper: 'Light Purple, Light Blue and Light Green',
    colorList: [Color(0xFFD7A9E3), Color(0xFF8BBEE8), Color(0xFFA8D5BA)],
  ),
  const NotesColorTheme(
    prefix: 'Radiant',
    helper: 'Radiant Yellow, Living Coral and Purple',
    colorList: [Color(0xFFF9A12E), Color(0xFFFC766A), Color(0xFF9B4A97)],
  ),
  const NotesColorTheme(
    prefix: 'Innocent',
    helper: 'White, Pink Lady and Sky Blue',
    colorList: [Color(0xFFFCF6F5), Color(0xFFEDC2D8), Color(0xFF8ABAD3)],
  ),
  const NotesColorTheme(
    prefix: 'Oktoberfest',
    helper: 'Red, Yellow and Navy',
    colorList: [Color(0xFFF65058), Color(0xFFFBDE44), Color(0xFF28334A)],
  ),
  const NotesColorTheme(
    prefix: 'Nature',
    helper: 'Tanager Turquoise, Teal Blue and Kelly Green',
    colorList: [Color(0xFF95DBE5), Color(0xFF078282), Color(0xFF339E66)],
  ),
  const NotesColorTheme(
    prefix: 'Knockout',
    helper: 'Knockout Pink, Safety Yellow and Out of the Blue',
    colorList: [Color(0xFFFF3EA5), Color(0xFFEDFF00), Color(0xFF00A4CC)],
  ),
  const NotesColorTheme(
    prefix: 'Danger',
    helper: 'Danger Red, Tap Shoe and Blue Blossom',
    colorList: [Color(0xFFD9514E), Color(0xFF2A2B2D), Color(0xFF2DA8D8)],
  ),
  const NotesColorTheme(
    prefix: 'Light Teal',
    helper: null,
    colorList: [Color(0xFFA7BEAE)],
  ),
  const NotesColorTheme(
    prefix: 'Fresh Mint',
    helper: null,
    colorList: [Color(0xFFADEFD1)],
  ),
  const NotesColorTheme(
    prefix: 'Sailor Blue',
    helper: null,
    colorList: [Color(0xFF00203F)],
  ),
];
