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

import 'package:auto_size_text/auto_size_text.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/app_theme.dart';
import 'package:safenotes/utils/platform_ui.dart';
import 'package:safenotes/utils/spacing.dart';
import 'package:safenotes/utils/text_styles.dart';
import 'package:safenotes/widgets/shad_nav_items.dart';

class HomeDrawer extends StatefulWidget {
  final VoidCallback onSettingsCallback;
  final VoidCallback onNotesCallback;
  final VoidCallback onLockCallback;
  final VoidCallback? onDeletedNotesCallback;

  /// 星标笔记入口：进入「仅看星标」过滤。
  final VoidCallback? onStarredCallback;

  /// 标签组的标签列表（一行一个，默认 个人/工作/灵感）。
  final List<String> tags;

  /// 当前生效的标签过滤（用于高亮），可为 null。
  final String? activeTag;

  /// 点击某个标签进入按该标签过滤。
  final ValueChanged<String>? onTagSelected;

  /// 标签组 header 编辑图标：进入标签管理（增/删全局标签池）。
  final VoidCallback? onManageTags;

  const HomeDrawer({
    super.key,
    required this.onSettingsCallback,
    required this.onNotesCallback,
    required this.onLockCallback,
    this.onDeletedNotesCallback,
    this.onStarredCallback,
    this.tags = const [],
    this.activeTag,
    this.onTagSelected,
    this.onManageTags,
  });

  @override
  HomeDrawerState createState() => HomeDrawerState();
}

class HomeDrawerState extends State<HomeDrawer> {
  /// 标签组是否展开（点击组 header 折叠/展开）。
  bool _tagsExpanded = true;

  @override
  Widget build(BuildContext context) {
    Provider.of<ThemeProvider>(context);

    const drawerPaddingHorizontal = 16.0;
    const double drawerRadius = 16.0;
    // 顶部/底部留白与菜单项间距：固定 token 值，不再用 MediaQuery 高度百分比
    // （集成测试 setSurfaceSize 不更新 MediaQuery，会导致间距按真实窗口算）。
    const double topHeadPadding = AppShape.inputHeight;
    const double bottomHeadPadding = AppSpace.sm;
    const double itemSpacing = AppSpace.xs;

    final String notesText = 'Notes'.tr();
    final String settings = 'Settings'.tr();
    final String trashText = 'Trash'.tr();
    final String lockText = 'Lock'.tr();

    return ClipRRect(
      borderRadius: const BorderRadius.only(
        topRight: Radius.circular(drawerRadius),
        bottomRight: Radius.circular(drawerRadius),
      ),
      child: Drawer(
        child: Column(
          children: [
            // 可滚动导航区：内容超出时滚动，锁定紧跟在设置之下（无分割线）
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: drawerPaddingHorizontal,
                ),
                child: Column(
                  children: <Widget>[
                    _drawerHeader(topPadding: topHeadPadding),
                    _divide(topPadding: bottomHeadPadding),
                    _buildMenuItem(
                      topPadding: itemSpacing,
                      text: notesText,
                      icon: LucideIcons.stickyNote,
                      onClicked: widget.onNotesCallback,
                    ),
                    // 星标笔记入口（OnNotes / Starred 同属上方主入口组）。
                    if (widget.onStarredCallback != null)
                      KeyedSubtree(
                        key: const Key('ui-home-nav-starred'),
                        child: _buildMenuItem(
                          topPadding: itemSpacing,
                          text: 'Starred Notes'.tr(),
                          icon: LucideIcons.star,
                          onClicked: widget.onStarredCallback!,
                        ),
                      ),
                    // 分割线：把标签组在视觉上与上方主入口、下方设置/锁定分隔。
                    _divide(topPadding: itemSpacing),
                    _buildTagGroup(
                      topPadding: itemSpacing,
                      itemSpacing: itemSpacing,
                    ),
                    _divide(topPadding: itemSpacing),
                    // 回收站（原最近删除）：随设置/锁定一起置于底部导航区，紧贴设置上方。
                    if (widget.onDeletedNotesCallback != null)
                      KeyedSubtree(
                        key: const Key('ui-home-nav-deleted'),
                        child: _buildMenuItem(
                          topPadding: itemSpacing,
                          text: trashText,
                          icon: LucideIcons.trash2,
                          onClicked: widget.onDeletedNotesCallback!,
                        ),
                      ),
                    KeyedSubtree(
                      key: const Key('ui-home-nav-settings'),
                      child: _buildMenuItem(
                        topPadding: itemSpacing,
                        text: settings,
                        icon: LucideIcons.settings,
                        onClicked: widget.onSettingsCallback,
                      ),
                    ),
                    // 锁定：与上方其它项目一致，无分割线、不置底
                    KeyedSubtree(
                      key: const Key('ui-home-nav-lock'),
                      child: _buildMenuItem(
                        topPadding: itemSpacing,
                        text: lockText,
                        icon: LucideIcons.lock,
                        onClicked: widget.onLockCallback,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMenuItem({
    required String text,
    required IconData icon,
    required double topPadding,
    Widget? toggle,
    VoidCallback? onClicked,
  }) {
    return Padding(
      padding: EdgeInsets.only(top: topPadding),
      child: shadNavMenuItem(
        context,
        icon: icon,
        label: text,
        trailing: toggle,
        onTap: onClicked ?? () {},
      ),
    );
  }

  Widget _drawerHeader({required double topPadding}) {
    final logoPath = SafeNotesConfig.appLogoPath;
    final officialAppName = SafeNotesConfig.appName;
    final appSlogan = SafeNotesConfig.appSlogan;
    const double appNameFontSize = AppTextSize.s20;
    const double appSloganFontSize = AppTextSize.s12;
    const double logoNameGap = 10.0;

    return Padding(
      padding: EdgeInsets.only(top: topPadding),
      // 用约束宽度而非 MediaQuery 计算 logo 尺寸：drawer 内容区宽度才是真实
      // 可用空间。此前用 MediaQuery.sizeOf(context).width 在集成测试（setSurfaceSize
      // 只改 View 尺寸、MediaQuery 仍返回真实窗口宽）里会把 logo 放大到超出抽屉
      // 内容区，导致 RenderFlex 溢出（见 ui-setting-item-darkmode 报错）。
      child: LayoutBuilder(
        builder: (context, constraints) {
          final double logoHightWidth = constraints.maxWidth * 0.25;
          return InkWell(
            onTap: () {},
            child: Container(
              padding: (const EdgeInsets.symmetric(vertical: 6)),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.start,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Center(
                    child: SizedBox(
                      width: logoHightWidth,
                      height: logoHightWidth,
                      child: Image.asset(
                        logoPath,
                        semanticLabel: SafeNotesConfig.appName,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(left: logoNameGap),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          AutoSizeText(
                            officialAppName,
                            maxLines: 1,
                            minFontSize: 8,
                            style: TextStyle(
                              fontFamily: uiFontFamily,
                              fontFamilyFallback: uiFontFamilyFallback,
                              fontWeight: FontWeight.bold,
                              fontSize: appNameFontSize,
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: AutoSizeText(
                              appSlogan,
                              maxLines: 1,
                              minFontSize: 8,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: appSloganFontSize,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _divide({required double topPadding}) {
    return Padding(
      padding: EdgeInsets.only(top: topPadding),
      child: Divider(color: ShadTheme.of(context).colorScheme.border),
    );
  }

  /// 标签组：header（「标签」名 + 折叠箭头 + 右侧编辑图标）+ 每个标签一行。
  /// 点击 header 折叠/展开标签列表（折叠时仅显示头部）。
  Widget _buildTagGroup({
    required double topPadding,
    required double itemSpacing,
  }) {
    final theme = ShadTheme.of(context);
    return Padding(
      padding: EdgeInsets.only(top: topPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 组 header：整体可点击折叠/展开；右侧为编辑入口（增删标签）。
          InkWell(
            key: const Key('ui-home-tag-header'),
            onTap: () => setState(() => _tagsExpanded = !_tagsExpanded),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(
                        _tagsExpanded ? Icons.expand_more : Icons.chevron_right,
                        size: AppIcon.sm,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Tags'.tr(),
                        style: theme.textTheme.muted.copyWith(
                          fontWeight: FontWeight.w600,
                          fontSize: AppTextSize.s12,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                  if (widget.onManageTags != null)
                    IconButton(
                      key: const Key('ui-home-tag-edit'),
                      tooltip: 'Manage Tags'.tr(),
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(LucideIcons.pencil, size: 18),
                      color: theme.colorScheme.primary,
                      onPressed: widget.onManageTags,
                    ),
                ],
              ),
            ),
          ),
          // 每个标签一行，点击进入按该标签过滤；折叠状态隐藏。
          if (_tagsExpanded)
            for (final tag in widget.tags)
              KeyedSubtree(
                key: Key('ui-home-nav-tag-$tag'),
                child: _tagItem(tag: tag, topPadding: itemSpacing),
              ),
        ],
      ),
    );
  }

  /// 单个标签导航项（与 shadNavMenuItem 视觉一致，激活标签高亮）。
  Widget _tagItem({required String tag, required double topPadding}) {
    final theme = ShadTheme.of(context);
    final bool active = tag == widget.activeTag;
    final color = active
        ? theme.colorScheme.primary
        : theme.colorScheme.foreground;
    return Padding(
      padding: EdgeInsets.only(top: topPadding),
      child: Material(
        color: active
            ? theme.colorScheme.primary.withValues(alpha: 0.1)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: widget.onTagSelected == null
              ? null
              : () => widget.onTagSelected!(tag),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(LucideIcons.tag, size: AppIcon.sm, color: color),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    tag,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.p.copyWith(
                      fontWeight: FontWeight.w600,
                      color: color,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
