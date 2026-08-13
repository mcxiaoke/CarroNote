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

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:easy_localization/easy_localization.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

// Project imports:
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/app_theme.dart';
import 'package:safenotes/models/theme_seeds.g.dart';
import 'package:safenotes/utils/platform_ui.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/widgets/shad_settings_tiles.dart';

/// 主题颜色选择页：6 组 × 16 色的分组色库，实时切换全局品牌色。
///
/// - 分组切换用 shadcn 的 [ShadTabs]（泛型 int）；
/// - 色块网格参照 [ColorPallet]（笔记颜色页）的卡片+选中勾模式；
/// - 选中后调 `ThemeProvider.setThemeColor`，`notifyListeners` 全局重建主题树，
///   本页无需依赖 Provider 刷新（选中态由本地 state 维护）。
class ThemeColorPicker extends StatefulWidget {
  const ThemeColorPicker({super.key});

  @override
  State<ThemeColorPicker> createState() => ThemeColorPickerState();
}

class ThemeColorPickerState extends State<ThemeColorPicker> {
  late int _groupIndex;
  late int _colorIndex;

  /// 中文环境用中文名，其他语言用英文名（用户约定）。
  bool get _isZh => context.locale.languageCode == 'zh';

  @override
  void initState() {
    super.initState();
    // 从持久化/Provider 读当前选择作为初始选中态。
    _groupIndex = PreferencesStorage.themeGroupIndex;
    _colorIndex = PreferencesStorage.themeColorIndex;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Theme color'.tr(), style: appBarTitle)),
      body: shadSettingsList([
        // 顶部大预览：当前组当前色色条 + 双语名称，常驻可见。
        _preview(context),
        const SizedBox(height: 12),
        // 分组切换：ShadTabs 泛型 int，onChanged 切组。
        ShadTabs<int>(
          value: _groupIndex,
          onChanged: (i) => setState(() => _groupIndex = i),
          tabBarAlignment: Alignment.centerLeft,
          tabsGap: 8,
          scrollable: true,
          gap: 16,
          tabs: [
            for (var g = 0; g < AppThemeSeeds.groups.length; g++)
              ShadTab<int>(
                value: g,
                content: _grid(context, g),
                child: Text(
                  AppThemeSeeds.displayGroupName(
                    AppThemeSeeds.groups[g],
                    isZh: _isZh,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
      ]),
    );
  }

  /// 当前所选配色的大色条预览（顶部常驻）。
  Widget _preview(BuildContext context) {
    final theme = ShadTheme.of(context);
    final group = AppThemeSeeds.groupByIndex(_groupIndex);
    final item = AppThemeSeeds.itemByIndex(_groupIndex, _colorIndex);
    return ShadCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${'Selected'.tr()}: ${AppThemeSeeds.displayName(item, isZh: _isZh)}'
            ' · ${AppThemeSeeds.displayGroupName(group, isZh: _isZh)}',
            style: theme.textTheme.small,
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Container(
              height: 48,
              width: double.infinity,
              color: item.color,
            ),
          ),
        ],
      ),
    );
  }

  /// 当前组颜色网格：桌面 4 列圆形色块、移动 3 列。
  Widget _grid(BuildContext context, int g) {
    final group = AppThemeSeeds.groupByIndex(g);
    return GridView.count(
      crossAxisCount: isDesktopPlatform ? 4 : 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      childAspectRatio: 1.0,
      children: [
        for (var i = 0; i < group.colors.length; i++)
          _colorCard(context, g, i),
      ],
    );
  }

  /// 单个颜色卡：圆形色块，选中显示边框高亮 + 勾选图标。
  Widget _colorCard(BuildContext context, int g, int i) {
    final theme = ShadTheme.of(context);
    final item = AppThemeSeeds.itemByIndex(g, i);
    final selected = g == _groupIndex && i == _colorIndex;

    // 色块浅色时勾选图标用深色、深色时用白色，保证可读性。
    final checkColor =
        item.color.computeLuminance() > 0.4 ? Colors.black87 : Colors.white;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          // 实时切换：更新 Provider（全局重建主题）+ 本地选中态。
          Provider.of<ThemeProvider>(context, listen: false)
              .setThemeColor(g, i);
          setState(() {
            _groupIndex = g;
            _colorIndex = i;
          });
        },
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: item.color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.border,
                  width: selected ? 3 : 1,
                ),
                boxShadow: selected
                    ? [
                        BoxShadow(
                          color: item.color.withValues(alpha: 0.35),
                          blurRadius: 10,
                          spreadRadius: 1,
                        ),
                      ]
                    : null,
              ),
              child: selected
                  ? Icon(LucideIcons.check, size: 20, color: checkColor)
                  : null,
            ),
            const SizedBox(height: 6),
            // 色名：中文用中文名，其他语言用英文名；选中加粗 + 主题色。
            Text(
              AppThemeSeeds.displayName(item, isZh: _isZh),
              style: theme.textTheme.small.copyWith(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w600 : null,
                color: selected ? theme.colorScheme.primary : null,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
