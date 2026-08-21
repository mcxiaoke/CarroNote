/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under
* terms of the GPL-3.0+ license.
*/

// 共享导航列表（移动端 Drawer 与桌面 Sidebar 复用）。
//
// 抽取此前两份几乎一样的导航结构：主入口（Notes / Starred）+ 标签组（header 可折叠
// + 标签列表行）+ 底部导航（回收站 / Settings / Lock）。两处仅容器的品牌 header /
// Logo / collapsed 退化物不同，导航本体由本组件维护一份。
//
// - `collapsed` 仅桌面 Sidebar 收起态使用：标签组 header 隐藏、各项退化为单图标 + tooltip。
// - 标签行 icon 按日要求**不加底色盒**，直接显示；激活标签用 primary 高亮。
//
// 回调均可为空：传入 null 表示该入口不渲染（如新建场景 / 未启用星标）。

import 'package:flutter/material.dart';

import 'package:easy_localization/easy_localization.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/utils/spacing.dart';
import 'package:safenotes/utils/text_styles.dart';
import 'package:safenotes/widgets/shad_nav_items.dart';

/// Drawer / Sidebar 共用的导航列（返回 [Column]，由外层负责滚动容器与内外留边）。
class NavList extends StatefulWidget {
  /// 桌面侧栏收起态（窄图标模式）；Drawer 恒为 false。
  final bool collapsed;

  /// 「笔记」入口：回到全部笔记（清除星标/标签过滤）。
  final VoidCallback? onNotesCallback;

  /// 星标笔记入口：进入「仅看星标」过滤。
  final VoidCallback? onStarredCallback;

  /// 回收站入口。
  final VoidCallback? onDeletedNotesCallback;

  /// 设置入口。
  final VoidCallback? onSettingsCallback;

  /// 锁定入口。
  final VoidCallback? onLockCallback;

  /// 标签组标签列表（一行一个）。
  final List<String> tags;

  /// 当前生效的标签过滤（激活标签高亮），可为 null。
  final String? activeTag;

  /// 点击某个标签进入按该标签过滤。
  final ValueChanged<String>? onTagSelected;

  /// 标签组 header 编辑图标：进入标签管理（增/删全局标签池）。
  final VoidCallback? onManageTags;

  const NavList({
    super.key,
    this.collapsed = false,
    this.onNotesCallback,
    this.onStarredCallback,
    this.onDeletedNotesCallback,
    this.onSettingsCallback,
    this.onLockCallback,
    this.tags = const [],
    this.activeTag,
    this.onTagSelected,
    this.onManageTags,
  });

  @override
  State<NavList> createState() => _NavListState();
}

class _NavListState extends State<NavList> {
  /// 标签组是否展开（点击组 header 折叠/展开）。
  bool _tagsExpanded = true;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final Color dividerColor = theme.colorScheme.border;

    Widget navItem(
      IconData icon,
      String label,
      VoidCallback onTap, {
      String? key,
    }) {
      final item = shadNavMenuItem(
        context,
        icon: icon,
        label: label,
        collapsed: widget.collapsed,
        onTap: onTap,
      );
      return key == null ? item : KeyedSubtree(key: Key(key), child: item);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 主入口（收藏 / 星标）
        if (widget.onNotesCallback != null)
          navItem(
            LucideIcons.stickyNote,
            'Notes'.tr(),
            widget.onNotesCallback!,
            key: 'ui-home-nav-notes',
          ),
        if (widget.onStarredCallback != null)
          navItem(
            LucideIcons.star,
            'Starred Notes'.tr(),
            widget.onStarredCallback!,
            key: 'ui-home-nav-starred',
          ),
        Divider(color: dividerColor, height: 16),
        _buildTagGroup(context, theme),
        Divider(color: dividerColor, height: 16),
        // 底部导航（回收站 / 设置 / 锁定）
        if (widget.onDeletedNotesCallback != null)
          navItem(
            LucideIcons.trash2,
            'Trash'.tr(),
            widget.onDeletedNotesCallback!,
            key: 'ui-home-nav-deleted',
          ),
        if (widget.onSettingsCallback != null)
          navItem(
            LucideIcons.settings,
            'Settings'.tr(),
            widget.onSettingsCallback!,
            key: 'ui-home-nav-settings',
          ),
        if (widget.onLockCallback != null)
          navItem(
            LucideIcons.lock,
            'Lock'.tr(),
            widget.onLockCallback!,
            key: 'ui-home-nav-lock',
          ),
      ],
    );
  }

  /// 标签组：header（折叠箭头 + 「标签」+ 编辑图标）+ 每个标签一行。
  /// 点击 header 折叠/展开标签列表（折叠时仅显示头部）；收起态隐藏 header，标签退化为单图标。
  Widget _buildTagGroup(BuildContext context, ShadThemeData theme) {
    if (widget.collapsed) {
      // 收起态：标签仅展示单图标（尽量适配窄侧栏，与主入口一致退化为 tooltip）。
      return Column(
        children: [
          for (final tag in widget.tags)
            KeyedSubtree(
              key: Key('ui-home-nav-tag-$tag'),
              child: shadNavMenuItem(
                context,
                icon: LucideIcons.tag,
                label: tag,
                collapsed: true,
                onTap: widget.onTagSelected == null
                    ? () {}
                    : () => widget.onTagSelected!(tag),
              ),
            ),
        ],
      );
    }

    return Column(
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
                      size: AppIcon.md,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Tags'.tr(),
                      style: theme.textTheme.muted.copyWith(
                        fontWeight: FontWeight.w600,
                        fontSize: AppTextSize.s16,
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
              child: _tagItem(context, theme, tag),
            ),
      ],
    );
  }

  /// 单个标签导航项：icon **不加底色盒**直接显示，激活标签用 primary 高亮。
  Widget _tagItem(BuildContext context, ShadThemeData theme, String tag) {
    final bool active = tag == widget.activeTag;
    final color = active
        ? theme.colorScheme.primary
        : theme.colorScheme.foreground;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpace.xs),
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
                const SizedBox(width: 10),
                Icon(LucideIcons.tag, size: AppIcon.sm, color: color),
                const SizedBox(width: 22),
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
