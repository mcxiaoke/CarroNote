// GENERATED FILE - DO NOT EDIT MANUALLY.
// 由 scripts/generate_theme_seeds.dart 从 lib/data/theme_colors.json 生成：
// 主题 seed 色库（分组与颜色数量随 JSON 自适应，含中英文名）。
//
// 如需修改色值 / 增删颜色，请编辑 theme_colors.json 后运行：
//   dart run scripts/generate_theme_seeds.dart
// 生成时间：2026-08-17T18:15:40.991362

import 'package:flutter/material.dart';

/// 单个 seed 颜色项（alpha 恒为 0xFF，不允许透明）。
class ColorSeedItem {
  /// 中文名（如 '深海蓝'）
  final String name;

  /// 英文名（如 'Deep Sea Blue'）
  final String nameEn;

  /// seed 颜色（alpha = 0xFF）
  final Color color;

  const ColorSeedItem({
    required this.name,
    required this.nameEn,
    required this.color,
  });
}

/// seed 颜色分组（组内颜色数量随 JSON 自适应）。
class ColorSeedGroup {
  /// 分组中文名（如 '冷调专业'）
  final String name;

  /// 分组英文名（如 'Cool Professional'）
  final String nameEn;

  /// 组内颜色列表
  final List<ColorSeedItem> colors;

  const ColorSeedGroup({
    required this.name,
    required this.nameEn,
    required this.colors,
  });
}

/// 全局 seed 色库（分组与颜色数量随 JSON 自适应）。
///
/// 所有索引方法均带 clamp 防越界；持久化读出的旧索引因版本升级导致
/// 分组/颜色数量变化时不会崩溃。
class AppThemeSeeds {
  AppThemeSeeds._();

  /// 全部分组（顺序即 UI 展示顺序，第一组第一色为默认主题色）
  static const List<ColorSeedGroup> groups = [
    ColorSeedGroup(
      name: '通用',
      nameEn: 'Default',
      colors: [
        ColorSeedItem(
          name: '中性白',
          nameEn: 'Mono White',
          color: Color(0xFFF3F3F3),
        ),
        ColorSeedItem(
          name: '中性黑',
          nameEn: 'Mono Black',
          color: Color(0xFF303030),
        ),
        ColorSeedItem(
          name: '奶油黄',
          nameEn: 'Cream Yellow',
          color: Color(0xFFFBDD82),
        ),
        ColorSeedItem(name: '浅柠黄', nameEn: 'Lemon', color: Color(0xFFFACC15)),
        ColorSeedItem(name: '琥珀橙', nameEn: 'Amber', color: Color(0xFFD97706)),
        ColorSeedItem(name: '金色', nameEn: 'Gold', color: Color(0xFFC58B16)),
        ColorSeedItem(
          name: '落日橙',
          nameEn: 'Sunset Orange',
          color: Color(0xFFFB923C),
        ),
        ColorSeedItem(name: '珊瑚橙', nameEn: 'Coral', color: Color(0xFFE76F51)),
        ColorSeedItem(name: '蜜桃色', nameEn: 'Peach', color: Color(0xFFD97757)),
        ColorSeedItem(name: '焦糖棕', nameEn: 'Caramel', color: Color(0xFFA66A35)),
        ColorSeedItem(name: '沙漠棕', nameEn: 'Desert', color: Color(0xFF9A7451)),
        ColorSeedItem(name: '可可棕', nameEn: 'Cocoa', color: Color(0xFF8A5A44)),
        ColorSeedItem(
          name: '砖红',
          nameEn: 'Brick Red',
          color: Color(0xFFC2413A),
        ),
        ColorSeedItem(name: '酒红', nameEn: 'Burgundy', color: Color(0xFF9F2D4E)),
        ColorSeedItem(
          name: '烟粉',
          nameEn: 'Dusty Pink',
          color: Color(0xFFD8A2A2),
        ),
        ColorSeedItem(name: '玫瑰红', nameEn: 'Rose', color: Color(0xFFE11D48)),
        ColorSeedItem(name: '莓果色', nameEn: 'Berry', color: Color(0xFFBE3F70)),
        ColorSeedItem(name: '洋红', nameEn: 'Magenta', color: Color(0xFFB33B74)),
        ColorSeedItem(name: '李子紫', nameEn: 'Plum', color: Color(0xFFA855B7)),
        ColorSeedItem(
          name: '薰衣草紫',
          nameEn: 'Lavender',
          color: Color(0xFF8B5CF6),
        ),
        ColorSeedItem(name: '紫罗兰', nameEn: 'Violet', color: Color(0xFF7C3AED)),
        ColorSeedItem(name: '靛蓝', nameEn: 'Indigo', color: Color(0xFF4F46E5)),
        ColorSeedItem(name: '海军蓝', nameEn: 'Navy', color: Color(0xFF3B5B92)),
        ColorSeedItem(
          name: '午夜蓝',
          nameEn: 'Midnight Blue',
          color: Color(0xFF38598B),
        ),
        ColorSeedItem(name: '湖蓝', nameEn: 'Sky Blue', color: Color(0xFF0284C7)),
        ColorSeedItem(name: '深青色', nameEn: 'Cyan', color: Color(0xFF0891B2)),
        ColorSeedItem(
          name: '海蓝宝',
          nameEn: 'Aquamarine',
          color: Color(0xFF168B85),
        ),
        ColorSeedItem(name: '青绿', nameEn: 'Teal', color: Color(0xFF0F9D8A)),
        ColorSeedItem(name: '薄荷绿', nameEn: 'Mint', color: Color(0xFF2A9D8F)),
        ColorSeedItem(name: '翡翠绿', nameEn: 'Emerald', color: Color(0xFF059669)),
        ColorSeedItem(
          name: '森林绿',
          nameEn: 'Forest Green',
          color: Color(0xFF34785A),
        ),
        ColorSeedItem(name: '苔藓绿', nameEn: 'Moss', color: Color(0xFF5E7D4E)),
        ColorSeedItem(name: '橄榄绿', nameEn: 'Olive', color: Color(0xFF71864A)),
        ColorSeedItem(name: '鼠尾草绿', nameEn: 'Sage', color: Color(0xFF87A884)),
      ],
    ),
    ColorSeedGroup(
      name: '马卡龙',
      nameEn: 'Pastel',
      colors: [
        ColorSeedItem(
          name: '樱花粉',
          nameEn: 'Sakura Pink',
          color: Color(0xFFF4A6B8),
        ),
        ColorSeedItem(
          name: '蜜桃粉',
          nameEn: 'Peach Pink',
          color: Color(0xFFF5A9A9),
        ),
        ColorSeedItem(
          name: '豆沙粉',
          nameEn: 'Bean Paste Pink',
          color: Color(0xFFD9A6A6),
        ),
        ColorSeedItem(
          name: '珊瑚粉',
          nameEn: 'Coral Pink',
          color: Color(0xFFF5B7B1),
        ),
        ColorSeedItem(
          name: '蜜桃橙',
          nameEn: 'Peach Orange',
          color: Color(0xFFF5B89A),
        ),
        ColorSeedItem(
          name: '浅杏色',
          nameEn: 'Light Apricot',
          color: Color(0xFFE8C9A8),
        ),
        ColorSeedItem(
          name: '奶咖棕',
          nameEn: 'Milk Coffee Brown',
          color: Color(0xFFC9A98A),
        ),
        ColorSeedItem(
          name: '香槟色',
          nameEn: 'Champagne',
          color: Color(0xFFF0D9A8),
        ),
        ColorSeedItem(
          name: '奶油黄',
          nameEn: 'Cream Yellow',
          color: Color(0xFFF7DC9F),
        ),
        ColorSeedItem(
          name: '鹅黄色',
          nameEn: 'Goose Yellow',
          color: Color(0xFFF0E68C),
        ),
        ColorSeedItem(
          name: '柠檬奶油',
          nameEn: 'Lemon Cream',
          color: Color(0xFFF5E6A8),
        ),
        ColorSeedItem(
          name: '青草绿',
          nameEn: 'Grass Green',
          color: Color(0xFFB5D99C),
        ),
        ColorSeedItem(
          name: '豆绿色',
          nameEn: 'Bean Green',
          color: Color(0xFFC8D9A8),
        ),
        ColorSeedItem(
          name: '嫩绿色',
          nameEn: 'Tender Green',
          color: Color(0xFFB8E0C4),
        ),
        ColorSeedItem(
          name: '薄荷绿',
          nameEn: 'Mint Green',
          color: Color(0xFFA8D8B9),
        ),
        ColorSeedItem(
          name: '水绿色',
          nameEn: 'Aqua Green',
          color: Color(0xFFA3D4C4),
        ),
        ColorSeedItem(
          name: '灰豆绿',
          nameEn: 'Gray Bean Green',
          color: Color(0xFFA9BFA3),
        ),
        ColorSeedItem(
          name: '蒂芙尼蓝',
          nameEn: 'Tiffany Blue',
          color: Color(0xFF9AD3D3),
        ),
        ColorSeedItem(
          name: '天空蓝',
          nameEn: 'Sky Blue',
          color: Color(0xFFA8C8E8),
        ),
        ColorSeedItem(
          name: '雾霾蓝',
          nameEn: 'Haze Blue',
          color: Color(0xFF9EB5C9),
        ),
        ColorSeedItem(
          name: '浅靛蓝',
          nameEn: 'Light Indigo',
          color: Color(0xFFB5C4E0),
        ),
        ColorSeedItem(
          name: '薰衣草紫',
          nameEn: 'Lavender Purple',
          color: Color(0xFFC4B5E0),
        ),
        ColorSeedItem(
          name: '香芋紫',
          nameEn: 'Taro Purple',
          color: Color(0xFFB8A8D4),
        ),
        ColorSeedItem(
          name: '藕荷紫',
          nameEn: 'Lotus Purple',
          color: Color(0xFFD4B5D4),
        ),
      ],
    ),
    ColorSeedGroup(
      name: '活力',
      nameEn: 'Vibrant',
      colors: [
        ColorSeedItem(
          name: '亮红',
          nameEn: 'Bright Red',
          color: Color(0xFFFF1744),
        ),
        ColorSeedItem(
          name: '橙红',
          nameEn: 'Orange Red',
          color: Color(0xFFFF3D00),
        ),
        ColorSeedItem(
          name: '亮橙',
          nameEn: 'Bright Orange',
          color: Color(0xFFFF6D00),
        ),
        ColorSeedItem(
          name: '深橙亮',
          nameEn: 'Deep Bright Orange',
          color: Color(0xFFFF9100),
        ),
        ColorSeedItem(
          name: '亮琥珀',
          nameEn: 'Bright Amber',
          color: Color(0xFFFFC400),
        ),
        ColorSeedItem(
          name: '亮黄',
          nameEn: 'Bright Yellow',
          color: Color(0xFFFFEA00),
        ),
        ColorSeedItem(
          name: '荧光黄绿',
          nameEn: 'Neon Yellow Green',
          color: Color(0xFFCCFF00),
        ),
        ColorSeedItem(
          name: '青柠绿',
          nameEn: 'Lime Green',
          color: Color(0xFF76FF03),
        ),
        ColorSeedItem(
          name: '亮绿',
          nameEn: 'Bright Green',
          color: Color(0xFF00E676),
        ),
        ColorSeedItem(
          name: '深亮绿',
          nameEn: 'Dark Bright Green',
          color: Color(0xFF00C853),
        ),
        ColorSeedItem(
          name: '青绿',
          nameEn: 'Cyan Green',
          color: Color(0xFF1DE9B6),
        ),
        ColorSeedItem(
          name: '深青绿',
          nameEn: 'Dark Cyan Green',
          color: Color(0xFF00BFA5),
        ),
        ColorSeedItem(
          name: '亮青',
          nameEn: 'Bright Cyan',
          color: Color(0xFF00E5FF),
        ),
        ColorSeedItem(
          name: '深亮蓝',
          nameEn: 'Dark Bright Blue',
          color: Color(0xFF0091EA),
        ),
        ColorSeedItem(
          name: '亮蓝',
          nameEn: 'Bright Blue',
          color: Color(0xFF2979FF),
        ),
        ColorSeedItem(
          name: '深蓝亮',
          nameEn: 'Dark Blue Bright',
          color: Color(0xFF2962FF),
        ),
        ColorSeedItem(
          name: '亮靛蓝',
          nameEn: 'Bright Indigo',
          color: Color(0xFF3D5AFE),
        ),
        ColorSeedItem(
          name: '深亮靛蓝',
          nameEn: 'Dark Bright Indigo',
          color: Color(0xFF304FFE),
        ),
        ColorSeedItem(
          name: '亮紫',
          nameEn: 'Bright Purple',
          color: Color(0xFF651FFF),
        ),
        ColorSeedItem(
          name: '深亮紫',
          nameEn: 'Dark Bright Purple',
          color: Color(0xFFAA00FF),
        ),
        ColorSeedItem(
          name: '荧光紫',
          nameEn: 'Neon Purple',
          color: Color(0xFFE040FB),
        ),
        ColorSeedItem(
          name: '亮粉红',
          nameEn: 'Bright Pink',
          color: Color(0xFFF50057),
        ),
        ColorSeedItem(
          name: '浅亮粉红',
          nameEn: 'Light Bright Pink',
          color: Color(0xFFFF4081),
        ),
        ColorSeedItem(name: '深红', nameEn: 'Deep Red', color: Color(0xFFD50000)),
      ],
    ),
    ColorSeedGroup(
      name: '自然',
      nameEn: 'Earthy',
      colors: [
        ColorSeedItem(
          name: '砖红色',
          nameEn: 'Brick Red',
          color: Color(0xFF8B4513),
        ),
        ColorSeedItem(
          name: '陶土红',
          nameEn: 'Terracotta',
          color: Color(0xFFA65D3F),
        ),
        ColorSeedItem(name: '铁锈色', nameEn: 'Rust', color: Color(0xFFB7410E)),
        ColorSeedItem(
          name: '赭红色',
          nameEn: 'Ochre Red',
          color: Color(0xFFA0522D),
        ),
        ColorSeedItem(name: '焦糖色', nameEn: 'Caramel', color: Color(0xFFB5651D)),
        ColorSeedItem(name: '赭石色', nameEn: 'Ochre', color: Color(0xFFB87333)),
        ColorSeedItem(name: '南瓜色', nameEn: 'Pumpkin', color: Color(0xFFD2691E)),
        ColorSeedItem(name: '沙色', nameEn: 'Sand', color: Color(0xFFC2A878)),
        ColorSeedItem(name: '卡其色', nameEn: 'Khaki', color: Color(0xFF9C8B6B)),
        ColorSeedItem(name: '驼色', nameEn: 'Camel', color: Color(0xFFC19A6B)),
        ColorSeedItem(name: '米色', nameEn: 'Beige', color: Color(0xFFD4C5A0)),
        ColorSeedItem(name: '燕麦色', nameEn: 'Oat', color: Color(0xFFE0D0A8)),
        ColorSeedItem(
          name: '奶油棕',
          nameEn: 'Cream Brown',
          color: Color(0xFFDCC8A0),
        ),
        ColorSeedItem(
          name: '苔藓绿',
          nameEn: 'Moss Green',
          color: Color(0xFF6B7A3A),
        ),
        ColorSeedItem(
          name: '橄榄绿',
          nameEn: 'Olive Green',
          color: Color(0xFF556B2F),
        ),
        ColorSeedItem(
          name: '深橄榄',
          nameEn: 'Deep Olive',
          color: Color(0xFF4A5D23),
        ),
        ColorSeedItem(
          name: '荒原绿',
          nameEn: 'Wasteland Green',
          color: Color(0xFF7A8A5A),
        ),
        ColorSeedItem(
          name: '森林绿',
          nameEn: 'Forest Green',
          color: Color(0xFF2D5A3D),
        ),
        ColorSeedItem(
          name: '松针绿',
          nameEn: 'Pine Green',
          color: Color(0xFF3A5A40),
        ),
        ColorSeedItem(
          name: '深绿色',
          nameEn: 'Dark Green',
          color: Color(0xFF1B4332),
        ),
        ColorSeedItem(
          name: '灰褐色',
          nameEn: 'Gray Brown',
          color: Color(0xFF8A7D6B),
        ),
        ColorSeedItem(
          name: '泥土棕',
          nameEn: 'Earth Brown',
          color: Color(0xFF7A5C3E),
        ),
        ColorSeedItem(
          name: '深棕',
          nameEn: 'Dark Brown',
          color: Color(0xFF4E342E),
        ),
        ColorSeedItem(
          name: '暗棕',
          nameEn: 'Dusk Brown',
          color: Color(0xFF3E2723),
        ),
      ],
    ),
    ColorSeedGroup(
      name: '深邃',
      nameEn: 'Gemstone',
      colors: [
        ColorSeedItem(name: '红宝石', nameEn: 'Ruby', color: Color(0xFF9B1B30)),
        ColorSeedItem(name: '石榴红', nameEn: 'Garnet', color: Color(0xFF8B0000)),
        ColorSeedItem(
          name: '酒红色',
          nameEn: 'Burgundy',
          color: Color(0xFF880E4F),
        ),
        ColorSeedItem(name: '勃艮第', nameEn: 'Claret', color: Color(0xFF6B1F3A)),
        ColorSeedItem(
          name: '粉宝石',
          nameEn: 'Pink Gem',
          color: Color(0xFFC71585),
        ),
        ColorSeedItem(
          name: '紫水晶',
          nameEn: 'Amethyst',
          color: Color(0xFF800080),
        ),
        ColorSeedItem(
          name: '紫晶浅',
          nameEn: 'Light Amethyst',
          color: Color(0xFF9932CC),
        ),
        ColorSeedItem(
          name: '深紫色',
          nameEn: 'Deep Purple',
          color: Color(0xFF4B0082),
        ),
        ColorSeedItem(
          name: '蓝宝石',
          nameEn: 'Sapphire',
          color: Color(0xFF0F2B5B),
        ),
        ColorSeedItem(
          name: '皇家蓝',
          nameEn: 'Royal Blue',
          color: Color(0xFF1E3A8A),
        ),
        ColorSeedItem(
          name: '钴蓝色',
          nameEn: 'Cobalt Blue',
          color: Color(0xFF003399),
        ),
        ColorSeedItem(
          name: '海军蓝',
          nameEn: 'Navy Blue',
          color: Color(0xFF0A2540),
        ),
        ColorSeedItem(
          name: '海蓝宝',
          nameEn: 'Aquamarine',
          color: Color(0xFF0E5E6F),
        ),
        ColorSeedItem(name: '托帕石', nameEn: 'Topaz', color: Color(0xFF0C5E8C)),
        ColorSeedItem(
          name: '青金石',
          nameEn: 'Lapis Lazuli',
          color: Color(0xFF1A4D7A),
        ),
        ColorSeedItem(
          name: '深青色',
          nameEn: 'Deep Cyan',
          color: Color(0xFF004D4D),
        ),
        ColorSeedItem(name: '祖母绿', nameEn: 'Emerald', color: Color(0xFF046307)),
        ColorSeedItem(name: '翡翠绿', nameEn: 'Jadeite', color: Color(0xFF0B6E4F)),
        ColorSeedItem(
          name: '孔雀石',
          nameEn: 'Malachite',
          color: Color(0xFF0B6B58),
        ),
        ColorSeedItem(
          name: '深绿',
          nameEn: 'Dark Green',
          color: Color(0xFF1B5E20),
        ),
        ColorSeedItem(name: '琥珀色', nameEn: 'Amber', color: Color(0xFFB8860B)),
        ColorSeedItem(name: '黄水晶', nameEn: 'Citrine', color: Color(0xFFCC7722)),
        ColorSeedItem(
          name: '玛瑙红',
          nameEn: 'Agate Red',
          color: Color(0xFFB1252C),
        ),
        ColorSeedItem(
          name: '黑曜石',
          nameEn: 'Obsidian',
          color: Color(0xFF3D3D3D),
        ),
      ],
    ),
  ];

  /// 取分组（越界自动夹取到最近合法值）
  static ColorSeedGroup groupByIndex(int groupIndex) =>
      groups[groupIndex.clamp(0, groups.length - 1)];

  /// 取某分组下的颜色项（越界自动夹取）
  static ColorSeedItem itemByIndex(int groupIndex, int colorIndex) {
    final group = groupByIndex(groupIndex);
    return group.colors[colorIndex.clamp(0, group.colors.length - 1)];
  }

  /// 直接取 Color（最常用；越界自动夹取）
  static Color colorByIndex(int groupIndex, int colorIndex) =>
      itemByIndex(groupIndex, colorIndex).color;

  /// 按当前语言取显示名：中文环境用中文名，其他语言用英文名。
  static String displayName(ColorSeedItem item, {required bool isZh}) =>
      isZh ? item.name : item.nameEn;

  /// 分组名的语言化显示。
  static String displayGroupName(ColorSeedGroup group, {required bool isZh}) =>
      isZh ? group.name : group.nameEn;
}
