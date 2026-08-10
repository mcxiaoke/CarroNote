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
import 'package:safenotes/utils/url_launcher.dart';
import 'package:safenotes/views/settings/theme_setting.dart';

class HomeDrawer extends StatefulWidget {
  final VoidCallback onImportCallback;
  final VoidCallback onChangePassCallback;
  final VoidCallback onLogoutCallback;
  final VoidCallback onSettingsCallback;
  final VoidCallback onBiometricsCallback;
  final VoidCallback? onDeletedNotesCallback;
  final VoidCallback? onDiagnosticsCallback;

  const HomeDrawer({
    super.key,
    required this.onImportCallback,
    required this.onChangePassCallback,
    required this.onLogoutCallback,
    required this.onSettingsCallback,
    required this.onBiometricsCallback,
    this.onDeletedNotesCallback,
    this.onDiagnosticsCallback,
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

    final String importDataText = 'Import Backup'.tr();
    final String changePassText = 'Change Passphrase'.tr();
    final String darkModeText = 'Dark Mode'.tr();
    final String lightModeText = 'Light Mode'.tr();
    final String settings = 'Settings'.tr();
    final String helpText = 'GitHub'.tr();
    final String faqsText = 'FAQs'.tr();
    final String rateText = 'Rate Us'.tr();
    final String logoutText = 'Logout'.tr();
    final String biometrics = 'Biometric'.tr();
    const String deletedNotesText = '最近删除';
    const String diagnosticsText = '调试面板';

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
                    text: importDataText,
                    icon: Icons.file_download_outlined,
                    onClicked: widget.onImportCallback,
                  ),
                  _buildMenuItem(
                    topPadding: itemSpacing,
                    text: changePassText,
                    icon: Icons.key_outlined,
                    onClicked: widget.onChangePassCallback,
                  ),
                  _buildMenuItem(
                    topPadding: itemSpacing,
                    text: PreferencesStorage.isThemeDark
                        ? lightModeText
                        : darkModeText,
                    icon: PreferencesStorage.isThemeDark
                        ? Icons.light_mode_outlined
                        : Icons.dark_mode_outlined,
                    onClicked: () {
                      Navigator.of(context).pop();
                      showThemeBottomSheet(context);
                    },
                  ),
                  _buildMenuItem(
                    topPadding: itemSpacing,
                    text: biometrics,
                    icon: Icons.fingerprint,
                    onClicked: widget.onBiometricsCallback,
                  ),
                  _buildMenuItem(
                    topPadding: itemSpacing,
                    text: settings,
                    icon: Icons.settings_outlined,
                    onClicked: widget.onSettingsCallback,
                  ),
                  if (widget.onDiagnosticsCallback != null)
                    _buildMenuItem(
                      topPadding: itemSpacing,
                      text: diagnosticsText,
                      icon: Icons.bug_report_outlined,
                      onClicked: widget.onDiagnosticsCallback!,
                    ),
                  if (widget.onDeletedNotesCallback != null)
                    _buildMenuItem(
                      topPadding: itemSpacing,
                      text: deletedNotesText,
                      icon: Icons.delete_outline,
                      onClicked: widget.onDeletedNotesCallback!,
                    ),
                  _divide(topPadding: dividerSpacing),
                  _buildMenuItem(
                    topPadding: dividerSpacing,
                    text: rateText,
                    icon: Icons.rate_review_outlined,
                    onClicked: () async {
                      Navigator.of(context).pop();
                      try {
                        // 评审 #5 修复：Rate Us 应指向应用商店，而非 GitHub
                        await launchUrlExternal(
                            Uri.parse(SafeNotesConfig.playStoreUrl));
                      } catch (_) {}
                    },
                  ),
                  _buildMenuItem(
                    topPadding: itemSpacing,
                    text: faqsText,
                    icon: Icons.quiz_outlined,
                    onClicked: () async {
                      Navigator.of(context).pop();
                      try {
                        // 评审 #5 修复：FAQs 指向官方 FAQ 页面
                        await launchUrlExternal(
                            Uri.parse(SafeNotesConfig.faqsUrl));
                      } catch (_) {}
                    },
                  ),
                  _buildMenuItem(
                    topPadding: itemSpacing,
                    text: helpText,
                    icon: Icons.help_outline,
                    onClicked: () async {
                      Navigator.of(context).pop();
                      try {
                        // 评审 #5 修复：Help 保留指向 GitHub 仓库源码
                        await launchUrlExternal(
                            Uri.parse(SafeNotesConfig.githubUrl));
                      } catch (_) {}
                    },
                  ),
                  _divide(topPadding: dividerSpacing),
                  _buildMenuItem(
                    topPadding: dividerSpacing,
                    text: logoutText,
                    icon: Icons.logout,
                    onClicked: widget.onLogoutCallback,
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
    const double leftPaddingMenuItem = 5.0;
    const double iconTextSpacing = 25.0;

    return Padding(
      padding: EdgeInsets.only(top: topPadding),
      child: ListTile(
        horizontalTitleGap: iconTextSpacing,
        contentPadding: const EdgeInsets.only(left: leftPaddingMenuItem),
        visualDensity: VisualDensity.compact,
        dense: true,
        leading: Icon(
          icon,
          size: 27,
        ),
        title: AutoSizeText(
          text,
          minFontSize: 8,
          maxLines: 1,
          style: TextStyle(
            fontFamily: uiFontFamily,
            fontFamilyFallback: uiFontFamilyFallback,
            fontWeight: FontWeight.bold,
            letterSpacing: -0.4,
            fontSize: 18,
            color: PreferencesStorage.isThemeDark
                ? Colors.white
                : Colors.grey.shade600,
          ),
        ),
        trailing: toggle,
        onTap: onClicked,
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
    final bool isDarkTheme = PreferencesStorage.isThemeDark;

    return Padding(
      padding: EdgeInsets.only(top: topPadding),
      child: Divider(
        color: isDarkTheme ? Colors.grey.shade700 : Colors.grey.shade500,
      ),
    );
  }
}
