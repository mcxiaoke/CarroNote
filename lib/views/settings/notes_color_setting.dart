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

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:easy_localization/easy_localization.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

// Project imports:
import 'package:safenotes/data/preference_repository.dart';
import 'package:safenotes/utils/notes_color.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/utils/text_styles.dart';
import 'package:safenotes/widgets/shad_settings_tiles.dart';

class ColorPallet extends StatefulWidget {
  const ColorPallet({super.key});

  @override
  State<ColorPallet> createState() => ColorPalletState();
}

class ColorPalletState extends State<ColorPallet> {
  late int _selectedIndex;
  final items = allNotesColorTheme;

  @override
  void initState() {
    super.initState();
    _selectedIndex = context
        .read<PreferencesRepository>()
        .colorfulNotesColorIndex;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Notes Color'.tr(), style: appBarTitle)),
      body: shadSettingsList([
        shadSettingsCard([
          shadSwitchTile(
            context,
            icon: LucideIcons.palette,
            title: 'Colorful Notes'.tr(),
            description: 'Choose the note color theme from below'.tr(),
            value: context.read<PreferencesRepository>().isColorful,
            onChanged: (_) {
              // 颜色开关走 Provider，主界面卡片配色需要立即刷新。
              Provider.of<NotesColor>(context, listen: false).toggleColor();
              setState(() {});
            },
          ),
        ]),
        const SizedBox(height: 12),
        // 顶部大预览：始终可见，滚到底部也能看到当前配色
        _preview(context),
        shadSectionTitle(context, 'Notes Color'.tr()),
        // 网格：每个主题卡自带色条预览（item 本身即颜色预览），
        // 整体紧凑，顶部预览始终在视野内。
        _grid(context),
        const SizedBox(height: 12),
      ]),
    );
  }

  /// 当前所选配色的大色条预览（常驻顶部，滚动后仍可见）。
  Widget _preview(BuildContext context) {
    final theme = ShadTheme.of(context);
    return ShadCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${'Selected'.tr()}: ${items[_selectedIndex].prefix}',
            style: theme.textTheme.small,
          ),
          const SizedBox(height: 10),
          _swatch(items[_selectedIndex].colorList, height: 48, radius: 12),
        ],
      ),
    );
  }

  /// 主题选择网格：桌面 3 列、移动 2 列。
  ///
  /// 整体紧凑，配合顶部常驻预览，滚动后仍能看到当前配色。
  Widget _grid(BuildContext context) {
    // 按可用宽度决定列数：宽屏（桌面/平板）3 列，窄屏 2 列。
    final columns = MediaQuery.sizeOf(context).width >= 600 ? 3 : 2;
    // 用固定高度 mainAxisExtent 而非 childAspectRatio，避免窗口缩窄时
    // 格子高度随宽度变小导致卡片内容溢出。
    return GridView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        mainAxisExtent: 88,
      ),
      children: [for (var i = 0; i < items.length; i++) _themeCard(context, i)],
    );
  }

  /// 单个主题卡：顶部色条即该主题的颜色预览，下方主题名 + 选中勾。
  Widget _themeCard(BuildContext context, int i) {
    final theme = ShadTheme.of(context);
    final selected = _selectedIndex == i;
    return Material(
      color: theme.colorScheme.card,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          context.read<PreferencesRepository>().setColorfulNotesColorIndex(i);
          setState(() => _selectedIndex = i);
        },
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.border,
              width: selected ? 2 : 1,
            ),
          ),
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _swatch(items[i].colorList, height: 30, width: double.infinity),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      items[i].prefix,
                      style: theme.textTheme.p.copyWith(
                        fontSize: AppTextSize.s12,
                        fontWeight: selected ? FontWeight.w600 : null,
                        color: selected ? theme.colorScheme.primary : null,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (selected)
                    Icon(
                      LucideIcons.check,
                      size: 16,
                      color: theme.colorScheme.primary,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 色板：把一组主题色横向平铺成圆角色条。
  ///
  /// [width] 为空时撑满可用宽度（用于顶部大预览）。
  Widget _swatch(
    List<dynamic> colors, {
    required double height,
    double? width,
    double radius = 10,
  }) {
    // 每个色块用 Container 显式给定高度：Row 中 Expanded 默认 crossAxisAlignment
    // 为 center，不会把无 child 的 ColoredBox 纵向拉伸，导致色块高度为 0（空白）。
    // 原版（settings_ui 时期）就是给 Container 写死 height 才正常显示。
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: width ?? double.infinity,
        height: height,
        child: Row(
          children: [
            for (final color in colors)
              Expanded(
                child: Container(height: height, color: color as Color),
              ),
          ],
        ),
      ),
    );
  }
}
