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

// Project imports:
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/app_theme.dart';
import 'package:safenotes/utils/platform_ui.dart';
import 'package:safenotes/views/settings/theme_setting.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:safenotes/widgets/shad_nav_items.dart';

class HomeDrawer extends StatefulWidget {
  final VoidCallback onSettingsCallback;
  final VoidCallback onSyncSettingsCallback;
  final VoidCallback onAboutCallback;
  final VoidCallback onLockCallback;
  final VoidCallback? onDeletedNotesCallback;

  const HomeDrawer({
    super.key,
    required this.onSettingsCallback,
    required this.onSyncSettingsCallback,
    required this.onAboutCallback,
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

    const drawerPaddingHorizontal = 15.0;
    const double drawerRadius = 15.0;
    final height = MediaQuery.of(context).size.height;
    final topHeadPadding = height * 0.07;
    final bottomHeadPadding = height * 0.01;
    final double dividerSpacing = height * 0.01;
    const double itemSpacing = 1;

    final String switchThemeText = 'Switch Theme'.tr();
    final String settings = 'Settings'.tr();
    final String deletedNotesText = 'Recently Deleted'.tr();
    final String syncSettingsText = 'Sync Settings'.tr();
    final String aboutText = 'About'.tr();
    final String lockText = 'Lock'.tr();

    return OrientationBuilder(
      builder: (context, orientation) {
        return ClipRRect(
          borderRadius: const BorderRadius.only(
            topRight: Radius.circular(drawerRadius),
            bottomRight: Radius.circular(drawerRadius),
          ),
          child: Drawer(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(
                horizontal: drawerPaddingHorizontal,
              ),
              child: Column(
                children: <Widget>[
                  _drawerHeader(
                      topPadding: topHeadPadding, orientation: orientation),
                  _divide(topPadding: bottomHeadPadding),
                  _buildMenuItem(
                    topPadding: height * 0.005,
                    text: switchThemeText,
                    icon: Icons.palette_outlined,
                    onClicked: () {
                      Navigator.of(context).pop();
                      showThemeBottomSheet(context);
                    },
                  ),
                  _buildMenuItem(
                    topPadding: itemSpacing,
                    text: settings,
                    icon: Icons.settings_outlined,
                    onClicked: widget.onSettingsCallback,
                  ),
                  if (widget.onDeletedNotesCallback != null)
                    _buildMenuItem(
                      topPadding: itemSpacing,
                      text: deletedNotesText,
                      icon: Icons.delete_outline,
                      onClicked: widget.onDeletedNotesCallback!,
                    ),
                  _buildMenuItem(
                    topPadding: itemSpacing,
                    text: syncSettingsText,
                    icon: Icons.cloud_sync_outlined,
                    onClicked: widget.onSyncSettingsCallback,
                  ),
                  _buildMenuItem(
                    topPadding: itemSpacing,
                    text: aboutText,
                    icon: Icons.info_outline,
                    onClicked: widget.onAboutCallback,
                  ),
                  _divide(topPadding: dividerSpacing),
                  _buildMenuItem(
                    topPadding: dividerSpacing,
                    text: lockText,
                    icon: Icons.lock_outline,
                    onClicked: widget.onLockCallback,
                  ),
                ],
              ),
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
        ? MediaQuery.of(context).size.width
        : MediaQuery.of(context).size.height;

    final logoPath = SafeNotesConfig.appLogoPath;
    final officialAppName = SafeNotesConfig.appName;
    final appSlogan = SafeNotesConfig.appSlogan;
    final double logoHightWidth = width * 0.25;
    // final double logoHightWidth = 75.0;
    const double appNameFontSize = 20;
    const double appSloganFontSize = 12;
    const double logoNameGap = 10.0;

    return Padding(
      padding: EdgeInsets.only(top: topPadding),
      child: InkWell(
        onTap: () {},
        child: Container(
          padding: (const EdgeInsets.symmetric(vertical: 5)),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Center(
                child: SizedBox(
                  width: logoHightWidth,
                  height: logoHightWidth,
                  child: Image.asset(logoPath),
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
                        padding: const EdgeInsets.only(bottom: 5),
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
              )
            ],
          ),
        ),
      ),
    );
  }

  Widget _divide({required double topPadding}) {
    return Padding(
      padding: EdgeInsets.only(top: topPadding),
      child: Divider(
        color: ShadTheme.of(context).colorScheme.border,
      ),
    );
  }
}