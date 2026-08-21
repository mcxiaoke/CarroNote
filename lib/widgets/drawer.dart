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
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/app_theme.dart';
import 'package:safenotes/utils/platform_ui.dart';
import 'package:safenotes/utils/spacing.dart';
import 'package:safenotes/utils/text_styles.dart';
import 'package:safenotes/widgets/nav_list.dart';

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
  @override
  Widget build(BuildContext context) {
    Provider.of<ThemeProvider>(context);

    const drawerPaddingHorizontal = 16.0;
    const double drawerRadius = 16.0;
    // 顶部/底部留白：固定 token 值，不再用 MediaQuery 高度百分比
    // （集成测试 setSurfaceSize 不更新 MediaQuery，会导致间距按真实窗口算）。
    const double topHeadPadding = AppShape.inputHeight;
    const double bottomHeadPadding = AppSpace.sm;

    return ClipRRect(
      borderRadius: const BorderRadius.only(
        topRight: Radius.circular(drawerRadius),
        bottomRight: Radius.circular(drawerRadius),
      ),
      child: Drawer(
        child: Column(
          children: [
            // 可滚动导航区：内容超出时滚动。
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: drawerPaddingHorizontal,
                ),
                child: Column(
                  children: <Widget>[
                    _drawerHeader(topPadding: topHeadPadding),
                    _divide(topPadding: bottomHeadPadding),
                    // 导航主体（Notes / Starred / 标签组 / 回收站 / Settings / Lock）
                    // 交由共享 NavList 统一渲染，避免与桌面 Sidebar 重复。
                    NavList(
                      onNotesCallback: widget.onNotesCallback,
                      onStarredCallback: widget.onStarredCallback,
                      onDeletedNotesCallback: widget.onDeletedNotesCallback,
                      onSettingsCallback: widget.onSettingsCallback,
                      onLockCallback: widget.onLockCallback,
                      tags: widget.tags,
                      activeTag: widget.activeTag,
                      onTagSelected: widget.onTagSelected,
                      onManageTags: widget.onManageTags,
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
}
