#
# Copyright (C) Keshav Priyadarshi and others - All Rights Reserved.
#
# SPDX-License-Identifier: GPL-3.0-or-later
# You may use, distribute and modify this code under the
# terms of the GPL-3.0+ license.
#
# See https://safenotes.dev for support or download.
#

"""
生成 lib/models/theme_seeds.g.dart —— 从 lib/data/theme_colors.json 编译主题 seed 色库。

产出内容包含：
  - ColorSeedItem / ColorSeedGroup / AppThemeSeeds 三个类
  - 6 组 × 16 色 = 96 色（每组含中英文名，每色含中英文名 + #RRGGBB 色值）
  - 按 index 取分组 / 颜色 / 色值的方法（含 clamp 防越界）

设计要点：
  - 仅使用 Python 标准库，跨平台无需额外依赖。
  - 色值严格校验：必须为 #RRGGBB 六位十六进制，alpha 恒为 0xFF（seed 不允许透明）。
  - 生成文件头标注 GENERATED，勿手改；改色值只改 JSON 后重跑本脚本。
  - 内容未变化时不写文件，避免无谓的重新编译。
"""

import json
import re
from datetime import datetime
from pathlib import Path

# 脚本位于 <root>/scripts/，项目根目录为其父目录
ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "lib" / "data" / "theme_colors.json"
OUT = ROOT / "lib" / "models" / "theme_seeds.g.dart"

# 六位十六进制色值（无 # 前缀，如 "0F3460"）
HEX_RE = re.compile(r"^[0-9A-Fa-f]{6}$")


def validate(data: list) -> None:
    """校验 JSON 结构：分组/颜色双语名齐全、色值 #RRGGBB 且不透明。"""
    if not isinstance(data, list) or len(data) == 0:
        raise ValueError("theme_colors.json 顶层必须是非空数组（分组列表）")
    seen_colors: set[str] = set()
    for g in data:
        if not (g.get("name") and g.get("nameEn")):
            raise ValueError(f"分组缺少中/英文名: {g}")
        colors = g.get("colors")
        if not isinstance(colors, list) or len(colors) == 0:
            raise ValueError(f"分组 {g['name']} 缺少 colors")
        for c in colors:
            if not (c.get("name") and c.get("nameEn")):
                raise ValueError(f"{g['name']} 下颜色缺少中/英文名: {c}")
            color = c.get("color", "")
            m = re.fullmatch(r"#([0-9A-Fa-f]{6})", color)
            if not m:
                raise ValueError(f"{g['name']}/{c['name']} 色值格式非法: {color!r}（须为 #RRGGBB）")
            hex6 = m.group(1).upper()
            if hex6 in seen_colors:
                raise ValueError(f"重复色值 {color}（{g['name']}/{c['name']}）")
            seen_colors.add(hex6)


def build_dart_source(data: list, generated_at: str) -> str:
    """拼装 theme_seeds.g.dart 的源码文本。"""
    # 分组常量：逐个生成 const ColorSeedGroup(...) 字面量
    groups_lines = []
    for g in data:
        color_lines = []
        for c in g["colors"]:
            hex6 = c["color"][1:].upper()
            color_lines.append(
                "      ColorSeedItem(\n"
                f"        name: '{c['name']}',\n"
                f"        nameEn: '{c['nameEn']}',\n"
                f"        color: Color(0xFF{hex6}),\n"
                "      ),"
            )
        groups_lines.append(
            "    ColorSeedGroup(\n"
            f"      name: '{g['name']}',\n"
            f"      nameEn: '{g['nameEn']}',\n"
            "      colors: [\n"
            + "\n".join(color_lines)
            + "\n      ],\n"
            "    ),"
        )
    groups_block = "\n".join(groups_lines)

    return f"""// GENERATED FILE - DO NOT EDIT MANUALLY.
// 由 scripts/generate_theme_seeds.py 从 lib/data/theme_colors.json 生成：
// 主题 seed 色库（6 组 × 16 色，含中英文名）。
//
// 如需修改色值 / 增删颜色，请编辑 theme_colors.json 后运行：
//   python scripts/generate_theme_seeds.py
// 生成时间：{generated_at}

// Flutter imports:
import 'package:flutter/material.dart';

/// 单个 seed 颜色项（alpha 恒为 0xFF，不允许透明）。
class ColorSeedItem {{
  /// 中文名（如 '深海蓝'）
  final String name;

  /// 英文名（如 'Deep Sea Blue'）
  final String nameEn;

  /// seed 颜色（alpha = 0xFF）
  final Color color;

  const ColorSeedItem({{
    required this.name,
    required this.nameEn,
    required this.color,
  }});
}}

/// seed 颜色分组（一组 16 色）。
class ColorSeedGroup {{
  /// 分组中文名（如 '冷调专业'）
  final String name;

  /// 分组英文名（如 'Cool Professional'）
  final String nameEn;

  /// 组内颜色列表
  final List<ColorSeedItem> colors;

  const ColorSeedGroup({{
    required this.name,
    required this.nameEn,
    required this.colors,
  }});
}}

/// 全局 seed 色库：6 组 × 16 色。
///
/// 所有索引方法均带 clamp 防越界；持久化读出的旧索引因版本升级导致
/// 分组/颜色数量变化时不会崩溃。
class AppThemeSeeds {{
  AppThemeSeeds._();

  /// 全部分组（顺序即 UI 展示顺序，第一组第一色为默认主题色）
  static const List<ColorSeedGroup> groups = [
{groups_block}
  ];

  /// 取分组（越界自动夹取到最近合法值）
  static ColorSeedGroup groupByIndex(int groupIndex) =>
      groups[groupIndex.clamp(0, groups.length - 1)];

  /// 取某分组下的颜色项（越界自动夹取）
  static ColorSeedItem itemByIndex(int groupIndex, int colorIndex) {{
    final group = groupByIndex(groupIndex);
    return group.colors[colorIndex.clamp(0, group.colors.length - 1)];
  }}

  /// 直接取 Color（最常用；越界自动夹取）
  static Color colorByIndex(int groupIndex, int colorIndex) =>
      itemByIndex(groupIndex, colorIndex).color;

  /// 按当前语言取显示名：中文环境用中文名，其他语言用英文名。
  static String displayName(ColorSeedItem item, {{required bool isZh}}) =>
      isZh ? item.name : item.nameEn;

  /// 分组名的语言化显示。
  static String displayGroupName(ColorSeedGroup group, {{required bool isZh}}) =>
      isZh ? group.name : group.nameEn;
}}
"""


def main() -> int:
    data = json.loads(SRC.read_text(encoding="utf-8"))
    validate(data)

    generated_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    source = build_dart_source(data, generated_at)

    if OUT.exists() and OUT.read_text(encoding="utf-8") == source:
        print("[theme_seeds] 内容未变化，跳过写入")
    else:
        OUT.write_text(source, encoding="utf-8")
        print(f"[theme_seeds] 已生成 {OUT.relative_to(ROOT)}")

    total = sum(len(g["colors"]) for g in data)
    print(f"[theme_seeds] 分组={len(data)} 颜色={total} 首组={data[0]['name']} "
          f"默认色={data[0]['colors'][0]['color']} {data[0]['colors'][0]['name']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
