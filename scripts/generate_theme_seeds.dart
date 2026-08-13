//
// Copyright (C) Keshav Priyadarshi and others - All Rights Reserved.
//
// SPDX-License-Identifier: GPL-3.0-or-later
// You may use, distribute and modify this code under the
// terms of the GPL-3.0+ license.
//
// See https://safenotes.dev for support or download.
//

// 生成 lib/models/theme_seeds.g.dart —— 从 lib/data/theme_colors.json 编译主题 seed 色库。
//
// 产出内容包含：
//   - ColorSeedItem / ColorSeedGroup / AppThemeSeeds 三个类
//   - N 组 × M 色（每组含中英文名，每色含中英文名 + #RRGGBB 色值，数量随 JSON 自适应）
//   - 按 index 取分组 / 颜色 / 色值的方法（含 clamp 防越界）
//
// 设计要点：
//   - 仅使用 Dart 标准库（dart:io / dart:convert），跨平台无需额外依赖；
//     运行方式：dart run scripts/generate_theme_seeds.dart
//   - 色值严格校验：必须为 #RRGGBB 六位十六进制，alpha 恒为 0xFF（seed 不允许透明）。
//   - 生成文件头标注 GENERATED，勿手改；改色值只改 JSON 后重跑本脚本。
//   - 内容未变化时不写文件，避免无谓的重新编译。
//   - theme_seeds 需要入库（稳定数据，便于直接构建），因此输出到 lib/models/，
//     不放 lib/generated/（该目录被 .gitignore 忽略，不入库）。
import 'dart:convert';
import 'dart:io';

// 脚本位于 <root>/scripts/，项目根目录 = 脚本所在目录的父目录
// （不依赖运行时的当前目录，任何 cwd 下执行都能正确定位）。
final Directory root = File(Platform.script.toFilePath()).parent.parent;
final File src = File('${root.path}/lib/data/theme_colors.json');
final File out = File('${root.path}/lib/models/theme_seeds.g.dart');

// 六位十六进制色值（无 # 前缀，如 "0F3460"）。
final RegExp hexRe = RegExp(r'^[0-9A-Fa-f]{6}$');
final RegExp fullHexRe = RegExp(r'^#([0-9A-Fa-f]{6})$');

void validate(List<dynamic> data) {
  if (data.isEmpty) {
    throw FormatException('theme_colors.json 顶层必须是非空数组（分组列表）');
  }
  final Set<String> seenColors = <String>{};
  for (final g in data) {
    final Map<String, dynamic> group = g as Map<String, dynamic>;
    if (group['name'] == null ||
        (group['name'] as String).isEmpty ||
        group['nameEn'] == null ||
        (group['nameEn'] as String).isEmpty) {
      throw FormatException('分组缺少中/英文名: $group');
    }
    final colors = group['colors'] as List<dynamic>?;
    if (colors == null || colors.isEmpty) {
      throw FormatException("分组 ${group['name']} 缺少 colors");
    }
    for (final c in colors) {
      final Map<String, dynamic> color = c as Map<String, dynamic>;
      if (color['name'] == null ||
          (color['name'] as String).isEmpty ||
          color['nameEn'] == null ||
          (color['nameEn'] as String).isEmpty) {
        throw FormatException("${group['name']} 下颜色缺少中/英文名: $color");
      }
      final raw = color['color'] as String? ?? '';
      final m = fullHexRe.firstMatch(raw);
      if (m == null) {
        throw FormatException(
          "${group['name']}/${color['name']} 色值格式非法: $raw（须为 #RRGGBB）",
        );
      }
      final hex6 = m.group(1)!.toUpperCase();
      if (!seenColors.add(hex6)) {
        throw FormatException('重复色值 $raw（${group['name']}/${color['name']}）');
      }
    }
  }
}

String buildDartSource(List<dynamic> data, String generatedAt) {
  final groupsLines = <String>[];
  for (final g in data) {
    final Map<String, dynamic> group = g as Map<String, dynamic>;
    final colorLines = <String>[];
    for (final c in group['colors'] as List<dynamic>) {
      final Map<String, dynamic> color = c as Map<String, dynamic>;
      final hex6 = (color['color'] as String).substring(1).toUpperCase();
      colorLines.add('''      ColorSeedItem(
        name: '${color['name']}',
        nameEn: '${color['nameEn']}',
        color: Color(0xFF$hex6),
      ),''');
    }
    groupsLines.add('''    ColorSeedGroup(
      name: '${group['name']}',
      nameEn: '${group['nameEn']}',
      colors: [
${colorLines.join('\n')}
      ],
    ),''');
  }
  final groupsBlock = groupsLines.join('\n');

  return '''
// GENERATED FILE - DO NOT EDIT MANUALLY.
// 由 scripts/generate_theme_seeds.dart 从 lib/data/theme_colors.json 生成：
// 主题 seed 色库（分组与颜色数量随 JSON 自适应，含中英文名）。
//
// 如需修改色值 / 增删颜色，请编辑 theme_colors.json 后运行：
//   dart run scripts/generate_theme_seeds.dart
// 生成时间：$generatedAt

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
$groupsBlock
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
''';
}

Future<int> main() async {
  final data = jsonDecode(await src.readAsString()) as List<dynamic>;
  validate(data);

  final generatedAt = DateTime.now().toIso8601String();
  final source = buildDartSource(data, generatedAt);

  if (await out.exists()) {
    final existing = await out.readAsString();
    if (existing == source) {
      stdout.writeln('[theme_seeds] 内容未变化，跳过写入');
    } else {
      await out.writeAsString(source);
      stdout.writeln('[theme_seeds] 已生成 ${out.path}');
    }
  } else {
    await out.writeAsString(source);
    stdout.writeln('[theme_seeds] 已生成 ${out.path}');
  }

  var total = 0;
  for (final g in data) {
    total +=
        ((g as Map<String, dynamic>)['colors'] as List<dynamic>? ?? <dynamic>[])
            .length;
  }
  stdout.writeln(
    '[theme_seeds] 分组=${data.length} 颜色=$total '
    '首组=${(data[0] as Map<String, dynamic>)['name']} '
    '默认色=${((data[0] as Map<String, dynamic>)['colors'] as List)[0]}',
  );
  return 0;
}
