/*
* Copyright (C) Keshav Priyadarshi and others - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*
* You should have received a copy of the GNU General Public License v3.0 with
* this file. If you not, please visit https://www.gnu.org/licenses/gpl-3.0.html
*
* See https://safenotes.dev for support or download.
*/

import 'package:flutter/material.dart';

import 'package:easy_localization/easy_localization.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/app_theme.dart';
import 'package:safenotes/utils/platform_ui.dart';
import 'package:safenotes/utils/text_styles.dart';
import 'package:safenotes/widgets/footer.dart';
import 'package:safenotes/widgets/shad_nav_items.dart';

/// 桌面端常驻侧边栏（Sidebar），对应移动端 Drawer 的同一组入口。
///
/// 设计要点（针对大屏实测反馈修正）：
/// 1. 用 `ListTile`（图标 + 右侧文字，单行横向）而非 NavigationRail，
///    文字在图标右侧（而非下方），更贴合桌面应用侧栏习惯。
/// 2. 颜色**显式按主题设置**（亮/暗分别给可见的前景色），不复用主题默认值——
///    本应用 Nord 主题下 NavigationRail 的默认前景色在亮/暗模式都不正确。
/// 3. 固定宽度（默认 240），避免桌面端过窄。
///
/// 断点策略（Material Design 3 / Flutter 官方桌面模板）：
/// - Compact (< 600px)：用 Drawer（见 lib/widgets/drawer.dart）
/// - Medium (600–1023px) / Expanded (≥ 1024px)：用本 Sidebar 常驻左侧
///
/// IA 重构（docs/settings-sidebar-ia-design-20260815.md）后侧栏只放「位置导航」：
/// Recently Deleted / Settings / Lock；动作（切换主题）与 Settings 子页
/// （同步）及低频信息页（关于）统一收敛进 Settings 页。
class HomeSidebar extends StatelessWidget {
  final VoidCallback onSettingsCallback;
  final VoidCallback onDeletedNotesCallback;
  final VoidCallback onLockCallback;

  const HomeSidebar({
    super.key,
    required this.onSettingsCallback,
    required this.onDeletedNotesCallback,
    required this.onLockCallback,
  });

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

    Widget sideItem(IconData icon, String label, VoidCallback onTap) {
      return shadNavMenuItem(context, icon: icon, label: label, onTap: onTap);
    }

    return SizedBox(
      width: 240,
      child: Material(
        color: bg,
        child: Column(
          children: [
            // 顶部 Logo + 应用名
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  SizedBox(
                    width: 32,
                    height: 32,
                    child: Image.asset(
                      SafeNotesConfig.appLogoPath,
                      semanticLabel: SafeNotesConfig.appName,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child:                   Text(
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
                  ),
                ],
              ),
            ),
            Divider(color: divider, height: 1),
            // 主入口（可滚动，防窗口过矮时溢出）
            Expanded(
              child: ListView(
                shrinkWrap: true,
                children: [
                  KeyedSubtree(
                    key: const Key('ui-home-nav-deleted'),
                    child: sideItem(
                      LucideIcons.trash2,
                      'Recently Deleted'.tr(),
                      onDeletedNotesCallback,
                    ),
                  ),
                  KeyedSubtree(
                    key: const Key('ui-home-nav-settings'),
                    child: sideItem(
                      LucideIcons.settings,
                      'Settings'.tr(),
                      onSettingsCallback,
                    ),
                  ),
                  // 锁定：紧跟在设置之下，不置底、无分割线（与移动端 Drawer 一致）
                  KeyedSubtree(
                    key: const Key('ui-home-nav-lock'),
                    child: sideItem(
                      LucideIcons.lock,
                      'Lock'.tr(),
                      onLockCallback,
                    ),
                  ),
                ],
              ),
            ),
            // 底部版本号 / 构建信息 / DEBUG 徽标（分多行小字，置底）
            footer(context),
          ],
        ),
      ),
    );
  }
}
