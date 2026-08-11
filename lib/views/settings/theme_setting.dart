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
import 'package:safenotes/widgets/shad_settings_tiles.dart';

void showThemeBottomSheet(BuildContext context) {
  final theme = ShadTheme.of(context);
  showModalBottomSheet(
    context: context,
    backgroundColor: theme.colorScheme.background,
    // 桌面端弹窗宽度跟随内容居中，避免在宽窗口上被拉成一条横带。
    constraints: const BoxConstraints(maxWidth: 560),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (context) => const ThemeBottomSheet(),
  );
}

class ThemeBottomSheet extends StatefulWidget {
  const ThemeBottomSheet({super.key});

  @override
  ThemeBottomSheetState createState() => ThemeBottomSheetState();
}

class ThemeBottomSheetState extends State<ThemeBottomSheet> {
  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    final isPlatformDark =
        MediaQuery.of(context).platformBrightness == Brightness.dark;

    // 跟随系统时展示系统当前明暗，否则展示本地开关值。
    final darkModeSwitchValue =
        PreferencesStorage.isSystemDarkLightSwitchEnabled
            ? isPlatformDark
            : PreferencesStorage.isLocalDarkSwitchEnabled;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 顶部抓手
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(2),
                  color: theme.colorScheme.border,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Dark mode'.tr(),
              textAlign: TextAlign.center,
              style: theme.textTheme.h4,
            ),
            const SizedBox(height: 14),
            shadSettingsCard([
              shadSwitchTile(
                context,
                icon: LucideIcons.moon,
                title: 'Dark mode'.tr(),
                value: darkModeSwitchValue,
                onChanged: (value) async {
                  Provider.of<ThemeProvider>(context, listen: false)
                      .setIsDarkMode(value);

                  await PreferencesStorage.setLocalDarkSwitchEnabled(value);
                  await PreferencesStorage.setSystemDarkLightSwitchEnabled(
                      false);

                  if (mounted) setState(() {});
                },
              ),
              shadSwitchTile(
                context,
                icon: LucideIcons.monitorSmartphone,
                title: 'Use device settings'.tr(),
                description:
                    "Use device's light or dark mode setting for the app.".tr(),
                value: PreferencesStorage.isSystemDarkLightSwitchEnabled,
                onChanged: (value) async {
                  Provider.of<ThemeProvider>(context, listen: false)
                      .setIsDarkMode(isPlatformDark);

                  await PreferencesStorage.setLocalDarkSwitchEnabled(
                      isPlatformDark);
                  await PreferencesStorage.setSystemDarkLightSwitchEnabled(
                      value);

                  if (mounted) setState(() {});
                },
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
