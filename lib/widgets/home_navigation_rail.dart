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

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:easy_localization/easy_localization.dart';
import 'package:provider/provider.dart';

// Project imports:
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/app_theme.dart';
import 'package:safenotes/utils/platform_ui.dart';
import 'package:safenotes/utils/url_launcher.dart';

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
class HomeSidebar extends StatelessWidget {
  final VoidCallback onImportCallback;
  final VoidCallback onChangePassCallback;
  final VoidCallback onThemeCallback;
  final VoidCallback onBiometricsCallback;
  final VoidCallback onSettingsCallback;
  final VoidCallback onDiagnosticsCallback;
  final VoidCallback onDeletedNotesCallback;
  final VoidCallback onLogoutCallback;

  const HomeSidebar({
    super.key,
    required this.onImportCallback,
    required this.onChangePassCallback,
    required this.onThemeCallback,
    required this.onBiometricsCallback,
    required this.onSettingsCallback,
    required this.onDiagnosticsCallback,
    required this.onDeletedNotesCallback,
    required this.onLogoutCallback,
  });

  @override
  Widget build(BuildContext context) {
    // 订阅 ThemeProvider：主题切换后本侧栏的颜色随之刷新。
    Provider.of<ThemeProvider>(context);

    // 直接复用主题色板，而非写死灰色，保证侧栏与整体主题一致（含暗色/亮色）。
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final Color fg = colorScheme.onSurface;
    final Color bg = colorScheme.surfaceContainerLow;
    final Color divider = colorScheme.outlineVariant;
    final String themeText = colorScheme.brightness == Brightness.dark
        ? 'Light Mode'.tr()
        : 'Dark Mode'.tr();

    Future<void> launchExternal(String url) async {
      try {
        await launchUrlExternal(Uri.parse(url));
      } catch (_) {
        // 忽略：链接打不开时静默失败（与 Drawer 行为一致）。
      }
    }

    Widget sideItem(IconData icon, String label, VoidCallback onTap) {
      return ListTile(
        leading: Icon(icon, color: fg, size: 24),
        title: Text(
          label,
          style: TextStyle(
            color: fg,
            fontSize: 15,
            fontFamily: uiFontFamily,
            fontFamilyFallback: uiFontFamilyFallback,
            fontWeight: FontWeight.bold,
          ),
        ),
        horizontalTitleGap: 14,
        dense: true,
        visualDensity: VisualDensity.compact,
        onTap: onTap,
      );
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
                    child: Image.asset(SafeNotesConfig.appLogoPath),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      SafeNotesConfig.appName.tr(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: fg,
                        fontFamily: uiFontFamily,
                        fontFamilyFallback: uiFontFamilyFallback,
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
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
                  sideItem(
                    Icons.file_download_outlined,
                    'Import Backup'.tr(),
                    onImportCallback,
                  ),
                  sideItem(
                    Icons.key_outlined,
                    'Change Passphrase'.tr(),
                    onChangePassCallback,
                  ),
                  sideItem(
                    colorScheme.brightness == Brightness.dark
                        ? Icons.light_mode_outlined
                        : Icons.dark_mode_outlined,
                    themeText,
                    onThemeCallback,
                  ),
                  sideItem(
                    Icons.fingerprint,
                    'Biometric'.tr(),
                    onBiometricsCallback,
                  ),
                  sideItem(
                    Icons.settings_outlined,
                    'Settings'.tr(),
                    onSettingsCallback,
                  ),
                  sideItem(
                    Icons.bug_report_outlined,
                    '调试面板'.tr(),
                    onDiagnosticsCallback,
                  ),
                  sideItem(
                    Icons.delete_outline,
                    '最近删除'.tr(),
                    onDeletedNotesCallback,
                  ),
                  sideItem(Icons.logout, 'Logout'.tr(), onLogoutCallback),
                ],
              ),
            ),
            Divider(color: divider, height: 1),
            // 底部外链（评审 #5 修复：分别接应用商店 / FAQ / GitHub，避免全指向 GitHub）
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: Icon(Icons.rate_review_outlined, color: fg),
                    tooltip: 'Rate Us'.tr(),
                    onPressed: () =>
                        launchExternal(SafeNotesConfig.playStoreUrl),
                  ),
                  IconButton(
                    icon: Icon(Icons.quiz_outlined, color: fg),
                    tooltip: 'FAQs'.tr(),
                    onPressed: () => launchExternal(SafeNotesConfig.faqsUrl),
                  ),
                  IconButton(
                    icon: Icon(Icons.help_outline, color: fg),
                    tooltip: 'GitHub'.tr(),
                    onPressed: () => launchExternal(SafeNotesConfig.githubUrl),
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
