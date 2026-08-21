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
  static const double _brandTintAmount = 0.14;

  static Color getNoteColor({required int notIndex, BuildContext? context}) {
    final lightColors =
        allNotesColorTheme[PreferencesStorage.colorfulNotesColorIndex]
            .colorList;
    final isColorful = PreferencesStorage.isColorful;
    final base = isColorful
        ? lightColors[notIndex % lightColors.length]
        : _neutralCardColor(context);
    // 仅浅色模式提亮；暗黑模式保持原色不变，避免浅色卡片在深色背景上刺眼/违和。
    if (PreferencesStorage.isThemeDark) return base;
    // 关闭彩色时底色已是浅品牌色（不透明），再提亮 40% 会与背景融为一体。
    return isColorful
        ? (Color.lerp(base, Colors.white, _lightenAmount) ?? base)
        : base;
  }

  /// 关闭彩色时的卡片底色：surfaceContainerHighest 上叠加 14% 品牌主色。
  ///
  /// - 单色（中性灰度）主题：直接用 surfaceContainerLowest——素净扁平，与页面背景
  ///   （surfaceContainerLow）明确拉开一档对比，且无品牌色相干扰。
  /// - 彩色主题：surfaceContainerHighest 上叠加 14% 品牌主色，保证卡片与背景有区分
  ///   且带品牌色相（页面背景是 surfaceContainerLow，同档会融为一体）。
  static Color _neutralCardColor(BuildContext? context) {
    if (context == null) return const Color(0xFFA7BEAE); // 兜底（无 context 时）
    final scheme = Theme.of(context).colorScheme;
    if (isMonochromeMode) return scheme.surfaceBright;
    return Color.alphaBlend(
      scheme.primary.withValues(alpha: _brandTintAmount),
      scheme.surfaceContainerHighest,
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
