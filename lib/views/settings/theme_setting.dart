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

import 'package:flutter/material.dart';

import 'package:easy_localization/easy_localization.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/data/preference_repository.dart';
import 'package:safenotes/models/app_theme.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/widgets/shad_settings_tiles.dart';

void showThemeBottomSheet(BuildContext context) {
  showShadSheet(
    context: context,
    side: ShadSheetSide.bottom,
    builder: (context) => ShadSheet(
      // 内容自绘（ThemeBottomSheet 自带背景/抓手/圆角），关闭 ShadDialog
      // 默认的 padding 与边框装饰，避免双层留白。
      padding: EdgeInsets.zero,
      backgroundColor: Colors.transparent,
      border: Border.all(color: Colors.transparent),
      radius: const BorderRadius.vertical(top: Radius.circular(16)),
      // 桌面端弹窗宽度跟随内容居中，避免在宽窗口上被拉成一条横带。
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kDialogMaxWidthWide),
          child: const ThemeBottomSheet(),
        ),
      ),
    ),
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
    // 订阅 ThemeProvider：切明暗时本弹层随之重建，根 Material 背景色跟随新主题。
    final themeProvider = Provider.of<ThemeProvider>(context);
    final theme = ShadTheme.of(context);

    final isPlatformDark =
        MediaQuery.of(context).platformBrightness == Brightness.dark;

    // 跟随系统时展示系统当前明暗，否则展示 ThemeProvider 的实际明暗
    // （与 app.dart 使用的 themeMode 同源，避免与 isLocalDarkSwitchEnabled 脱节）。
    final darkModeSwitchValue =
        context.read<PreferencesRepository>().isSystemDarkLightSwitchEnabled
        ? isPlatformDark
        : themeProvider.isDarkMode;

    return Material(
      color: theme.colorScheme.background,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      child: SafeArea(
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
                    borderRadius: BorderRadius.circular(4),
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
                    Provider.of<ThemeProvider>(
                      context,
                      listen: false,
                    ).setIsDarkMode(value);

                    await context.read<PreferencesRepository>().setSystemDarkLightSwitchEnabled(
                      false,
                    );

                    if (mounted) setState(() {});
                  },
                ),
                shadSwitchTile(
                  context,
                  icon: LucideIcons.monitorSmartphone,
                  title: 'Use device settings'.tr(),
                  description:
                      "Use device's light or dark mode setting for the app."
                          .tr(),
                  value: context.read<PreferencesRepository>().isSystemDarkLightSwitchEnabled,
                  onChanged: (value) async {
                    Provider.of<ThemeProvider>(
                      context,
                      listen: false,
                    ).setIsDarkMode(isPlatformDark);

                    await context.read<PreferencesRepository>().setSystemDarkLightSwitchEnabled(
                      value,
                    );

                    if (mounted) setState(() {});
                  },
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}
