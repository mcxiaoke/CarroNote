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
import 'package:auto_size_text/auto_size_text.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

// Project imports:
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/app_theme.dart';
import 'package:safenotes/utils/platform_ui.dart';
import 'package:safenotes/utils/text_styles.dart';
import 'package:safenotes/widgets/footer.dart';
import 'package:safenotes/widgets/shad_nav_items.dart';

class HomeDrawer extends StatefulWidget {
  final VoidCallback onSettingsCallback;
  final VoidCallback onNotesCallback;
  final VoidCallback onLockCallback;
  final VoidCallback? onDeletedNotesCallback;

  const HomeDrawer({
    super.key,
    required this.onSettingsCallback,
    required this.onNotesCallback,
    required this.onLockCallback,
    this.onDeletedNotesCallback,
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
    final height = MediaQuery.sizeOf(context).height;
    final topHeadPadding = height * 0.07;
    final bottomHeadPadding = height * 0.01;
    const double itemSpacing = 2;

    final String notesText = 'Notes'.tr();
    final String settings = 'Settings'.tr();
    final String deletedNotesText = 'Recently Deleted'.tr();
    final String lockText = 'Lock'.tr();

    return OrientationBuilder(
      builder: (context, orientation) {
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
                        _drawerHeader(
                          topPadding: topHeadPadding,
                          orientation: orientation,
                        ),
                        _divide(topPadding: bottomHeadPadding),
                        _buildMenuItem(
                          topPadding: height * 0.005,
                          text: notesText,
                          icon: LucideIcons.stickyNote,
                          onClicked: widget.onNotesCallback,
                        ),
                        if (widget.onDeletedNotesCallback != null)
                          _buildMenuItem(
                            topPadding: itemSpacing,
                            text: deletedNotesText,
                            icon: LucideIcons.trash2,
                            onClicked: widget.onDeletedNotesCallback!,
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
                        _buildMenuItem(
                          topPadding: itemSpacing,
                          text: lockText,
                          icon: LucideIcons.lock,
                          onClicked: widget.onLockCallback,
                        ),
                      ],
                    ),
                  ),
                ),
                // 底部版本号 / 构建信息 / DEBUG 徽标（分多行小字，置底不随内容滚动）
                footer(context),
              ],
            ),
          ),
        );
      },
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

  Widget _drawerHeader({required double topPadding, required var orientation}) {
    final width = orientation == Orientation.portrait
        ? MediaQuery.sizeOf(context).width
        : MediaQuery.sizeOf(context).height;

    final logoPath = SafeNotesConfig.appLogoPath;
    final officialAppName = SafeNotesConfig.appName;
    final appSlogan = SafeNotesConfig.appSlogan;
    final double logoHightWidth = width * 0.25;
    // final double logoHightWidth = 75.0;
    const double appNameFontSize = AppTextSize.s20;
    const double appSloganFontSize = AppTextSize.s12;
    const double logoNameGap = 10.0;

    return Padding(
      padding: EdgeInsets.only(top: topPadding),
      child: InkWell(
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
                        officialAppName.tr(),
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
                          appSlogan.tr(),
                          maxLines: 1,
                          minFontSize: 8,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: appSloganFontSize),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
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
