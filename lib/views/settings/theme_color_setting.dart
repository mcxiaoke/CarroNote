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

/// 主题颜色选择页：6 组 × 16 色的分组色库。
///
/// 交互设计：
/// - 进入页面时**所有色块默认未选中**（不预设已保存的主题色，避免误操作）；
/// - 点击色块只是**本地预览**（顶部大色条跟随变化），不立即生效；
/// - 底部「Apply theme」按钮点击后才真正写入 `ThemeProvider`（全局换肤 + 持久化）；
/// - 分组切换用 shadcn 的 [ShadTabs]（泛型 int）；色块为圆角矩形卡片
///   （参照笔记颜色页 ColorPallet），桌面/移动统一 4 列、16 色 = 4 行。
class ThemeColorPicker extends StatefulWidget {
  const ThemeColorPicker({super.key});

  @override
  State<ThemeColorPicker> createState() => ThemeColorPickerState();
}

class ThemeColorPickerState extends State<ThemeColorPicker> {
  // 本地选中态：进入时初始化为「当前已应用的主题色」（重进显示选中 + 预览带组名）；
  // 用户点击色块才改变（仅预览），Apply 才真正生效。
  // _colorIndex = -1 表示当前组内没有选中（仅切组到非当前组时出现）。
  late int _groupIndex;
  int _colorIndex = -1;

  /// 中文环境用中文名，其他语言用英文名（用户约定）。
  bool get _isZh => context.locale.languageCode == 'zh';

  /// 是否已在当前组内选中了一个颜色。
  bool get _hasColorSelected => _colorIndex >= 0;

  /// 是否有「待应用」的改动：本地选中 ≠ 全局已应用时才允许 Apply。
  bool get _hasPendingChange {
    final tp = Provider.of<ThemeProvider>(context, listen: false);
    return _hasColorSelected &&
        (_groupIndex != tp.groupIndex || _colorIndex != tp.colorIndex);
  }

  @override
  void initState() {
    super.initState();
    // 与持久化/Provider 当前主题保持一致：重进页面看到的就是当前主题。
    _groupIndex = PreferencesStorage.themeGroupIndex;
    _colorIndex = PreferencesStorage.themeColorIndex;
  }

  /// 切换分组：仅当当前已应用主题色就在新组时选中它（保持 Current 语义），
  /// 否则不选中任何颜色（避免「同位置颜色被自动选中」的误导）。
  void _switchGroup(int g) {
    final tp = Provider.of<ThemeProvider>(context, listen: false);
    setState(() {
      _groupIndex = g;
      _colorIndex = (tp.groupIndex == g) ? tp.colorIndex : -1;
    });
  }

  @override
  Widget build(BuildContext context) {
    // 订阅 ThemeProvider：用于判断本地选中是否为「当前主题」（Current/Preview 标签）。
    Provider.of<ThemeProvider>(context);

    return Scaffold(
      appBar: AppBar(title: Text('Theme color'.tr(), style: appBarTitle)),
      // 底部固定操作栏：Apply 按钮始终可见（不随内容滚动）。
      // 与登录页按钮一致：width 撑满可用宽度；外层限宽 720 与页面内容区
      // （shadSettingsList maxWidth）保持一致，桌面/移动都自然。
      // 注意：不能用 Center（Scaffold 给 bottomNavigationBar 的高度约束为剩余全部，
      // Center 会撑满把 body 挤成 0 高）；用 Align(heightFactor: 1.0) 收缩高度到按钮。
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Align(
            alignment: Alignment.center,
            heightFactor: 1.0,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ShadButton(
                width: double.infinity,
                onPressed: _hasPendingChange ? _applyTheme : null,
                child: Text('Apply theme'.tr()),
              ),
            ),
          ),
        ),
      ),
      body: shadSettingsList([
        // 顶部大预览：进入页面展示当前主题（Current），点击色块后展示预览（Preview）。
        _preview(context),
        const SizedBox(height: 12),
        // 分组切换：ShadTabs 泛型 int，onChanged 切组（仅当前组色才保留选中）。
        ShadTabs<int>(
          value: _groupIndex,
          onChanged: _switchGroup,
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

  /// 应用所选主题色：写入 Provider（全局重建）+ 持久化。
  void _applyTheme() {
    if (!_hasPendingChange) return;
    Provider.of<ThemeProvider>(context, listen: false)
        .setThemeColor(_groupIndex, _colorIndex);
  }

  /// 当前所选配色的大色条预览（顶部常驻）。
  ///
  /// - 本地未选中任何色（切到非当前组）→ 展示当前已应用主题色（Current）；
  /// - 本地选中 == 全局已应用 → Current；
  /// - 本地选中 ≠ 全局已应用 → Preview。
  Widget _preview(BuildContext context) {
    final theme = ShadTheme.of(context);
    final tp = Provider.of<ThemeProvider>(context);

    final Color previewColor;
    final String title;
    if (_hasColorSelected) {
      // 本地已选中：按本地选中显示，区分 Current / Preview。
      final isCurrent =
          _groupIndex == tp.groupIndex && _colorIndex == tp.colorIndex;
      final item = AppThemeSeeds.itemByIndex(_groupIndex, _colorIndex);
      final group = AppThemeSeeds.groupByIndex(_groupIndex);
      previewColor = item.color;
      final name = AppThemeSeeds.displayName(item, isZh: _isZh);
      final groupName = AppThemeSeeds.displayGroupName(group, isZh: _isZh);
      title = isCurrent
          ? '${'Current'.tr()}: $name · $groupName'
          : '${'Preview'.tr()}: $name · $groupName';
    } else {
      // 本地未选中（刚切到非当前组）：展示当前已应用主题色。
      previewColor = tp.seedColor;
      title = '${'Current'.tr()}: '
          '${AppThemeSeeds.displayName(
                AppThemeSeeds.itemByIndex(tp.groupIndex, tp.colorIndex),
                isZh: _isZh,
              )}'
          ' · ${AppThemeSeeds.displayGroupName(
                AppThemeSeeds.groupByIndex(tp.groupIndex),
                isZh: _isZh,
              )}';
    }

    return ShadCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.small),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Container(
              height: 48,
              width: double.infinity,
              color: previewColor,
            ),
          ),
        ],
      ),
    );
  }

  /// 当前组颜色网格：列数自适应（宽屏 4 列、移动 3 列），圆角矩形卡片。
  ///
  /// 用 [mainAxisExtent] 固定卡片高度（而非 childAspectRatio 按宽度推导），
  /// 保证任何屏宽下色块+名称行都不溢出；高度紧贴内容避免底部大留白。
  Widget _grid(BuildContext context, int g) {
    final group = AppThemeSeeds.groupByIndex(g);
    return GridView.count(
      crossAxisCount: isDesktopPlatform ? 4 : 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 8,
      mainAxisSpacing: 8,
      // 内容高度：padding 10*2 + 色块 30 + 间距 8 + 名称行 ~17 ≈ 75。
      mainAxisExtent: 84,
      children: [
        for (var i = 0; i < group.colors.length; i++)
          _colorCard(context, g, i),
      ],
    );
  }

  /// 单个颜色卡：圆角矩形卡片（色块 + 名称 + 选中勾），参照笔记颜色页。
  Widget _colorCard(BuildContext context, int g, int i) {
    final theme = ShadTheme.of(context);
    final item = AppThemeSeeds.itemByIndex(g, i);
    final selected =
        _hasColorSelected && g == _groupIndex && i == _colorIndex;

    return Material(
      color: theme.colorScheme.card,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() {
          _groupIndex = g;
          _colorIndex = i;
        }),
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
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            // 卡片高度固定（mainAxisExtent 84），内容垂直居中避免底部大留白。
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // 色块：圆角矩形撑满宽度。
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  height: 30,
                  width: double.infinity,
                  color: item.color,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      AppThemeSeeds.displayName(item, isZh: _isZh),
                      style: theme.textTheme.p.copyWith(
                        fontSize: 12,
                        fontWeight: selected ? FontWeight.w600 : null,
                        color: selected ? theme.colorScheme.primary : null,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (selected)
                    Icon(LucideIcons.check,
                        size: 14, color: theme.colorScheme.primary),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
