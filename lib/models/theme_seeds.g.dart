// GENERATED FILE - DO NOT EDIT MANUALLY.
// 由 scripts/generate_theme_seeds.py 从 lib/data/theme_colors.json 生成：
// 主题 seed 色库（6 组 × 16 色，含中英文名）。
//
// 如需修改色值 / 增删颜色，请编辑 theme_colors.json 后运行：
//   python scripts/generate_theme_seeds.py
// 生成时间：2026-08-13 10:14:48

// Flutter imports:
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

/// seed 颜色分组（一组 16 色）。
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

/// 全局 seed 色库：6 组 × 16 色。
///
/// 所有索引方法均带 clamp 防越界；持久化读出的旧索引因版本升级导致
/// 分组/颜色数量变化时不会崩溃。
class AppThemeSeeds {
  AppThemeSeeds._();

  /// 全部分组（顺序即 UI 展示顺序，第一组第一色为默认主题色）
  static const List<ColorSeedGroup> groups = [
    ColorSeedGroup(
      name: '冷调专业',
      nameEn: 'Cool Professional',
      colors: [
      ColorSeedItem(
        name: '深海蓝',
        nameEn: 'Deep Sea Blue',
        color: Color(0xFF0F3460),
      ),
      ColorSeedItem(
        name: '海军蓝',
        nameEn: 'Navy Blue',
        color: Color(0xFF1A3A5C),
      ),
      ColorSeedItem(
        name: '钢蓝色',
        nameEn: 'Steel Blue',
        color: Color(0xFF2C5F8D),
      ),
      ColorSeedItem(
        name: '天蓝色',
        nameEn: 'Sky Blue',
        color: Color(0xFF3A86C4),
      ),
      ColorSeedItem(
        name: '冰蓝色',
        nameEn: 'Ice Blue',
        color: Color(0xFF5BA3D9),
      ),
      ColorSeedItem(
        name: '青灰色',
        nameEn: 'Teal Gray',
        color: Color(0xFF4A7C8C),
      ),
      ColorSeedItem(
        name: '深青色',
        nameEn: 'Deep Cyan',
        color: Color(0xFF1B6B6B),
      ),
      ColorSeedItem(
        name: '孔雀绿',
        nameEn: 'Peacock Green',
        color: Color(0xFF2A9D8F),
      ),
      ColorSeedItem(
        name: '深紫色',
        nameEn: 'Deep Purple',
        color: Color(0xFF4A3B7A),
      ),
      ColorSeedItem(
        name: '蓝紫色',
        nameEn: 'Blue Violet',
        color: Color(0xFF5B4B8A),
      ),
      ColorSeedItem(
        name: '石墨灰',
        nameEn: 'Graphite Gray',
        color: Color(0xFF3D4552),
      ),
      ColorSeedItem(
        name: '蓝灰色',
        nameEn: 'Blue Gray',
        color: Color(0xFF5A6B7D),
      ),
      ColorSeedItem(
        name: '银灰色',
        nameEn: 'Silver Gray',
        color: Color(0xFF7A8A9A),
      ),
      ColorSeedItem(
        name: '深靛蓝',
        nameEn: 'Deep Indigo',
        color: Color(0xFF1F2D5C),
      ),
      ColorSeedItem(
        name: '钴蓝色',
        nameEn: 'Cobalt Blue',
        color: Color(0xFF0047AB),
      ),
      ColorSeedItem(
        name: '暗青色',
        nameEn: 'Dark Cyan',
        color: Color(0xFF264653),
      ),
      ],
    ),
    ColorSeedGroup(
      name: '经典通用',
      nameEn: 'Classic Universal',
      colors: [
      ColorSeedItem(
        name: '红色',
        nameEn: 'Red',
        color: Color(0xFFE53935),
      ),
      ColorSeedItem(
        name: '粉红',
        nameEn: 'Pink',
        color: Color(0xFFEC407A),
      ),
      ColorSeedItem(
        name: '紫色',
        nameEn: 'Purple',
        color: Color(0xFF8E24AA),
      ),
      ColorSeedItem(
        name: '深紫',
        nameEn: 'Deep Purple',
        color: Color(0xFF5E35B1),
      ),
      ColorSeedItem(
        name: '靛蓝',
        nameEn: 'Indigo',
        color: Color(0xFF3949AB),
      ),
      ColorSeedItem(
        name: '蓝色',
        nameEn: 'Blue',
        color: Color(0xFF1E88E5),
      ),
      ColorSeedItem(
        name: '浅蓝',
        nameEn: 'Light Blue',
        color: Color(0xFF039BE5),
      ),
      ColorSeedItem(
        name: '青色',
        nameEn: 'Cyan',
        color: Color(0xFF00ACC1),
      ),
      ColorSeedItem(
        name: '水鸭绿',
        nameEn: 'Teal',
        color: Color(0xFF00897B),
      ),
      ColorSeedItem(
        name: '绿色',
        nameEn: 'Green',
        color: Color(0xFF43A047),
      ),
      ColorSeedItem(
        name: '浅绿',
        nameEn: 'Light Green',
        color: Color(0xFF7CB342),
      ),
      ColorSeedItem(
        name: '黄绿',
        nameEn: 'Lime',
        color: Color(0xFFC0CA33),
      ),
      ColorSeedItem(
        name: '琥珀',
        nameEn: 'Amber',
        color: Color(0xFFFFB300),
      ),
      ColorSeedItem(
        name: '橙色',
        nameEn: 'Orange',
        color: Color(0xFFFB8C00),
      ),
      ColorSeedItem(
        name: '深橙',
        nameEn: 'Deep Orange',
        color: Color(0xFFF4511E),
      ),
      ColorSeedItem(
        name: '棕色',
        nameEn: 'Brown',
        color: Color(0xFF6D4C41),
      ),
      ],
    ),
    ColorSeedGroup(
      name: '柔和马卡龙',
      nameEn: 'Soft Macaron',
      colors: [
      ColorSeedItem(
        name: '樱花粉',
        nameEn: 'Sakura Pink',
        color: Color(0xFFF4A6B8),
      ),
      ColorSeedItem(
        name: '蜜桃橙',
        nameEn: 'Peach Orange',
        color: Color(0xFFF5B89A),
      ),
      ColorSeedItem(
        name: '奶油黄',
        nameEn: 'Cream Yellow',
        color: Color(0xFFF7DC9F),
      ),
      ColorSeedItem(
        name: '薄荷绿',
        nameEn: 'Mint Green',
        color: Color(0xFFA8D8B9),
      ),
      ColorSeedItem(
        name: '青草绿',
        nameEn: 'Grass Green',
        color: Color(0xFFB5D99C),
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
        name: '薰衣草紫',
        nameEn: 'Lavender Purple',
        color: Color(0xFFC4B5E0),
      ),
      ColorSeedItem(
        name: '藕荷紫',
        nameEn: 'Lilac',
        color: Color(0xFFD4B5D4),
      ),
      ColorSeedItem(
        name: '豆沙粉',
        nameEn: 'Dusky Pink',
        color: Color(0xFFD9A6A6),
      ),
      ColorSeedItem(
        name: '奶咖棕',
        nameEn: 'Latte Brown',
        color: Color(0xFFC9A98A),
      ),
      ColorSeedItem(
        name: '雾霾蓝',
        nameEn: 'Haze Blue',
        color: Color(0xFF9EB5C9),
      ),
      ColorSeedItem(
        name: '灰豆绿',
        nameEn: 'Sage Green',
        color: Color(0xFFA9BFA3),
      ),
      ColorSeedItem(
        name: '浅杏色',
        nameEn: 'Light Apricot',
        color: Color(0xFFE8C9A8),
      ),
      ColorSeedItem(
        name: '香芋紫',
        nameEn: 'Taro Purple',
        color: Color(0xFFB8A8D4),
      ),
      ColorSeedItem(
        name: '水绿色',
        nameEn: 'Aqua Green',
        color: Color(0xFFA3D4C4),
      ),
      ],
    ),
    ColorSeedGroup(
      name: '复古莫兰迪',
      nameEn: 'Retro Morandi',
      colors: [
      ColorSeedItem(
        name: '灰玫瑰',
        nameEn: 'Gray Rose',
        color: Color(0xFFB08989),
      ),
      ColorSeedItem(
        name: '脏橘色',
        nameEn: 'Clay Orange',
        color: Color(0xFFC08A6B),
      ),
      ColorSeedItem(
        name: '芥末黄',
        nameEn: 'Mustard Yellow',
        color: Color(0xFFC4A968),
      ),
      ColorSeedItem(
        name: '橄榄绿',
        nameEn: 'Olive Green',
        color: Color(0xFF8A9A6B),
      ),
      ColorSeedItem(
        name: '灰湖绿',
        nameEn: 'Lake Green',
        color: Color(0xFF6B9A8A),
      ),
      ColorSeedItem(
        name: '雾霾蓝',
        nameEn: 'Haze Blue',
        color: Color(0xFF6B8A9A),
      ),
      ColorSeedItem(
        name: '灰靛蓝',
        nameEn: 'Gray Indigo',
        color: Color(0xFF6B7A9A),
      ),
      ColorSeedItem(
        name: '灰紫色',
        nameEn: 'Gray Purple',
        color: Color(0xFF8A7A9A),
      ),
      ColorSeedItem(
        name: '灰粉色',
        nameEn: 'Gray Pink',
        color: Color(0xFFA68A8A),
      ),
      ColorSeedItem(
        name: '陶土棕',
        nameEn: 'Terracotta Brown',
        color: Color(0xFF9A7A6B),
      ),
      ColorSeedItem(
        name: '卡其灰',
        nameEn: 'Khaki Gray',
        color: Color(0xFF9A947A),
      ),
      ColorSeedItem(
        name: '灰青色',
        nameEn: 'Gray Teal',
        color: Color(0xFF7A9A94),
      ),
      ColorSeedItem(
        name: '豆沙紫',
        nameEn: 'Dusky Purple',
        color: Color(0xFF8A6B7A),
      ),
      ColorSeedItem(
        name: '米灰棕',
        nameEn: 'Beige Brown',
        color: Color(0xFFA69A82),
      ),
      ColorSeedItem(
        name: '灰蓝绿',
        nameEn: 'Blue Green',
        color: Color(0xFF6B8A82),
      ),
      ColorSeedItem(
        name: '暗玫瑰',
        nameEn: 'Dark Rose',
        color: Color(0xFF9A6B6B),
      ),
      ],
    ),
    ColorSeedGroup(
      name: '高饱和活力',
      nameEn: 'Vibrant',
      colors: [
      ColorSeedItem(
        name: '烈焰红',
        nameEn: 'Flame Red',
        color: Color(0xFFE63946),
      ),
      ColorSeedItem(
        name: '珊瑚橙',
        nameEn: 'Coral Orange',
        color: Color(0xFFF77F00),
      ),
      ColorSeedItem(
        name: '明黄色',
        nameEn: 'Bright Yellow',
        color: Color(0xFFFCBF49),
      ),
      ColorSeedItem(
        name: '柠檬绿',
        nameEn: 'Lemon Green',
        color: Color(0xFF90BE6D),
      ),
      ColorSeedItem(
        name: '翡翠绿',
        nameEn: 'Emerald Green',
        color: Color(0xFF43AA8B),
      ),
      ColorSeedItem(
        name: '青碧色',
        nameEn: 'Turquoise',
        color: Color(0xFF00B4D8),
      ),
      ColorSeedItem(
        name: '宝蓝色',
        nameEn: 'Royal Blue',
        color: Color(0xFF0077B6),
      ),
      ColorSeedItem(
        name: '靛紫色',
        nameEn: 'Indigo Purple',
        color: Color(0xFF5E60CE),
      ),
      ColorSeedItem(
        name: '洋红色',
        nameEn: 'Magenta',
        color: Color(0xFFD62976),
      ),
      ColorSeedItem(
        name: '玫红色',
        nameEn: 'Rose Red',
        color: Color(0xFFF72585),
      ),
      ColorSeedItem(
        name: '橙红色',
        nameEn: 'Orange Red',
        color: Color(0xFFF95738),
      ),
      ColorSeedItem(
        name: '黄绿色',
        nameEn: 'Yellow Green',
        color: Color(0xFFB5E48C),
      ),
      ColorSeedItem(
        name: '天青色',
        nameEn: 'Sky Cyan',
        color: Color(0xFF48CAE4),
      ),
      ColorSeedItem(
        name: '紫罗兰',
        nameEn: 'Violet',
        color: Color(0xFF7209B7),
      ),
      ColorSeedItem(
        name: '桃红色',
        nameEn: 'Peach Pink',
        color: Color(0xFFFF6B9D),
      ),
      ColorSeedItem(
        name: '青柠绿',
        nameEn: 'Lime Green',
        color: Color(0xFF80ED99),
      ),
      ],
    ),
    ColorSeedGroup(
      name: '自然大地',
      nameEn: 'Natural Earth',
      colors: [
      ColorSeedItem(
        name: '深棕色',
        nameEn: 'Dark Brown',
        color: Color(0xFF6B4423),
      ),
      ColorSeedItem(
        name: '焦糖色',
        nameEn: 'Caramel',
        color: Color(0xFFA0522D),
      ),
      ColorSeedItem(
        name: '赭石色',
        nameEn: 'Ochre',
        color: Color(0xFFB87333),
      ),
      ColorSeedItem(
        name: '沙色',
        nameEn: 'Sand',
        color: Color(0xFFC2A878),
      ),
      ColorSeedItem(
        name: '米色',
        nameEn: 'Beige',
        color: Color(0xFFD4C5A0),
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
        name: '陶土红',
        nameEn: 'Terracotta Red',
        color: Color(0xFFA65D3F),
      ),
      ColorSeedItem(
        name: '砖红色',
        nameEn: 'Brick Red',
        color: Color(0xFF8B4513),
      ),
      ColorSeedItem(
        name: '灰褐色',
        nameEn: 'Gray Brown',
        color: Color(0xFF8A7D6B),
      ),
      ColorSeedItem(
        name: '卡其色',
        nameEn: 'Khaki',
        color: Color(0xFF9C8B6B),
      ),
      ColorSeedItem(
        name: '深橄榄',
        nameEn: 'Dark Olive',
        color: Color(0xFF4A5D23),
      ),
      ColorSeedItem(
        name: '泥土棕',
        nameEn: 'Earth Brown',
        color: Color(0xFF7A5C3E),
      ),
      ColorSeedItem(
        name: '荒原绿',
        nameEn: 'Prairie Green',
        color: Color(0xFF7A8A5A),
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
