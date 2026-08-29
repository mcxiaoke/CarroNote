/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

import 'package:flutter/material.dart';

import 'package:easy_localization/easy_localization.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/app_theme.dart';
import 'package:safenotes/utils/platform_ui.dart';
import 'package:safenotes/utils/text_styles.dart';
import 'package:safenotes/widgets/nav_list.dart';

/// 桌面端常驻侧边栏（Sidebar），对应移动端 Drawer 的同一组入口。
///
/// 设计要点（针对大屏实测反馈修正）：
/// 1. 用 `ListTile`（图标 + 右侧文字，单行横向）而非 NavigationRail，
///    文字在图标右侧（而非下方），更贴合桌面应用侧栏习惯。
/// 2. 颜色**显式按主题设置**（亮/暗分别给可见的前景色），不复用主题默认值——
///    本应用 Nord 主题下 NavigationRail 的默认前景色在亮/暗模式都不正确。
/// 3. 固定宽度（默认 240），避免桌面端过窄。
///
/// 收起模式：[isCollapsed] 为 true 时宽度收窄到 [kCollapsedWidth]，只显示
/// 每个 item 的图标（文字走 tooltip，顶部也只显示 Logo），并在底栏提供
/// 展开/收起切换按钮。
///
/// 断点策略（Material Design 3 / Flutter 官方桌面模板）：
/// - Compact (< 600px)：用 Drawer（见 lib/widgets/drawer.dart）
/// - Medium (600–1023px) / Expanded (≥ 1024px)：用本 Sidebar 常驻左侧
///
/// IA 重构（docs/settings-sidebar-ia-design-20260815.md）后侧栏只放「位置导航」：
/// Recently Deleted / Settings / Lock；动作（切换主题）与 Settings 子页
/// （同步）及低频信息页（关于）统一收敛进 Settings 页。
class HomeSidebar extends StatefulWidget {
  /// 展开态宽度
  static const double kExpandedWidth = 240;

  /// 收起态宽度（仅能容纳图标）
  static const double kCollapsedWidth = 72;

  final VoidCallback onSettingsCallback;
  final VoidCallback onDeletedNotesCallback;
  final VoidCallback onLockCallback;

  /// 「笔记」入口：回到全部笔记（清除星标/标签过滤）。
  final VoidCallback onAllNotesCallback;

  /// 星标笔记入口：进入「仅看星标」过滤。
  final VoidCallback? onStarredCallback;

  /// 标签组标签列表（一行一个）。
  final List<String> tags;

  /// 当前生效标签过滤（用于高亮）。
  final String? activeTag;

  /// 点击标签进入按该标签过滤。
  final ValueChanged<String>? onTagSelected;

  /// 标签组编辑入口。
  final VoidCallback? onManageTags;

  final bool isCollapsed;
  final VoidCallback onToggleCollapsed;

  const HomeSidebar({
    super.key,
    required this.onSettingsCallback,
    required this.onDeletedNotesCallback,
    required this.onLockCallback,
    required this.onAllNotesCallback,
    this.onStarredCallback,
    this.tags = const [],
    this.activeTag,
    this.onTagSelected,
    this.onManageTags,
    this.isCollapsed = false,
    required this.onToggleCollapsed,
  });

  @override
  State<HomeSidebar> createState() => _HomeSidebarState();
}

class _HomeSidebarState extends State<HomeSidebar> {
  @override
  Widget build(BuildContext context) {
    // 订阅 ThemeProvider：主题切换后本侧栏的颜色随之刷新。
    Provider.of<ThemeProvider>(context);

    // 背景/前景/分隔线用 Material 主题（与移动端 Drawer / body 一致）。
    // 修复：43d05ed 曾改为 ShadTheme.colorScheme.background（亮色下纯白），
    // 导致宽屏侧边栏与浅灰 body 背景割裂、"背景丢失"；还原为 surfaceContainerLow。
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final Color fg = colorScheme.onSurface;
    final Color bg = colorScheme.surfaceContainerLow;
    final Color divider = colorScheme.outlineVariant;
    final bool collapsed = widget.isCollapsed;

    // 收起/展开切换按钮：收起的底栏只放这一个按钮
    final Widget toggleButton = IconButton(
      key: const Key('ui-home-sidebar-toggle'),
      tooltip: collapsed ? 'Expand sidebar'.tr() : 'Collapse sidebar'.tr(),
      icon: Icon(
        collapsed ? LucideIcons.panelLeftOpen : LucideIcons.panelLeftClose,
        size: 18,
      ),
      color: fg.withValues(alpha: 0.75),
      onPressed: widget.onToggleCollapsed,
    );

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      width: collapsed
          ? HomeSidebar.kCollapsedWidth
          : HomeSidebar.kExpandedWidth,
      child: Material(
        color: bg,
        child: Column(
          children: [
            // 顶部：展开态 Logo + 应用名 + 标语；收起态仅 Logo 居中
            Padding(
              padding: collapsed
                  ? const EdgeInsets.symmetric(vertical: 14)
                  : const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: collapsed
                  ? const _SidebarLogo(center: true)
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        const _SidebarLogo(),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                SafeNotesConfig.appName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: fg,
                                  fontFamily: uiFontFamily,
                                  fontFamilyFallback: uiFontFamilyFallback,
                                  fontWeight: FontWeight.bold,
                                  fontSize: AppTextSize.s16,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                SafeNotesConfig.appSlogan,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: fg.withValues(alpha: 0.65),
                                  fontFamily: uiFontFamily,
                                  fontFamilyFallback: uiFontFamilyFallback,
                                  fontSize: AppTextSize.s12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
            ),
            Divider(color: divider, height: 1),
            // 导航主体（Notes / Starred / 标签组 / 回收站 / Settings / Lock）交由共享
            // NavList 统一渲染，避免与移动端 Drawer 重复；可滚动，防窗口过矮时溢出。
            Expanded(
              child: ListView(
                shrinkWrap: true,
                children: [
                  NavList(
                    collapsed: collapsed,
                    onNotesCallback: widget.onAllNotesCallback,
                    onStarredCallback: widget.onStarredCallback,
                    onDeletedNotesCallback: widget.onDeletedNotesCallback,
                    onSettingsCallback: widget.onSettingsCallback,
                    onLockCallback: widget.onLockCallback,
                    tags: widget.tags,
                    activeTag: widget.activeTag,
                    onTagSelected: widget.onTagSelected,
                    onManageTags: widget.onManageTags,
                  ),
                  // 底部：展开态 = 收起/展开按钮；收起态只留按钮。
                  if (collapsed)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: toggleButton,
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6, top: 4),
                      child: Center(child: toggleButton),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 侧栏顶部 Logo（展开态左侧对齐，收起态居中）。
class _SidebarLogo extends StatelessWidget {
  final bool center;

  const _SidebarLogo({this.center = false});

  @override
  Widget build(BuildContext context) {
    final Widget logo = SizedBox(
      width: 48,
      height: 48,
      child: Image.asset(
        SafeNotesConfig.appLogoPath,
        semanticLabel: SafeNotesConfig.appName,
      ),
    );
    return center ? Center(child: logo) : logo;
  }
}
