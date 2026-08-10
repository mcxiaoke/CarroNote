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

// Dart imports:
import 'dart:async';

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:easy_localization/easy_localization.dart';
import 'package:local_session_timeout/local_session_timeout.dart';
import 'package:provider/provider.dart';
import 'package:settings_ui/settings_ui.dart';
import 'package:safenotes/utils/settings_platform.dart';

// Project imports:
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/dialogs/backup_import.dart';
import 'package:safenotes/models/app_theme.dart';
import 'package:safenotes/models/session.dart';
import 'package:safenotes/sync/sync_config.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/utils/url_launcher.dart';
import 'package:safenotes/views/settings/theme_setting.dart';
import 'package:safenotes/widgets/footer.dart';

class SettingsScreen extends StatefulWidget {
  final StreamController<SessionState> sessionStateStream;

  const SettingsScreen({super.key, required this.sessionStateStream});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    Provider.of<ThemeProvider>(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Settings'.tr(),
          style: appBarTitle,
        ),
      ),
      body: _settings(),
    );
  }

  Widget _settings() {
    return SettingsList(
      platform: currentDevicePlatform,
      lightTheme: const SettingsThemeData(),
      darkTheme: SettingsThemeData(
        settingsListBackground: AppThemes.darkSettingsScaffold,
        settingsSectionBackground: AppThemes.darkSettingsCanvas,
      ),
      sections: [
        SettingsSection(
          title: Text('General'.tr()),
          tiles: <SettingsTile>[
            SettingsTile.navigation(
              leading: const Icon(Icons.backup_outlined),
              title: Text('Backup'.tr()),
              value: PreferencesStorage.isBackupOn
                  ? Text('On'.tr())
                  : Text('Off'.tr()),
              onPressed: (context) async {
                await Navigator.pushNamed(context, '/backup');
                setState(() {});
              },
            ),
            SettingsTile.navigation(
              leading: Icon(Icons.file_download_outlined),
              title: Text('Import Backup'.tr()),
              onPressed: (context) async {
                await showImportDialog(context);
              },
            ),
            SettingsTile.switchTile(
              leading: Icon(Icons.compress),
              title: Text('Compact Notes'.tr()),
              initialValue: PreferencesStorage.isCompactPreview,
              onToggle: (bool value) {
                PreferencesStorage.setIsCompactPreview(value);
                setState(() {});
              },
            ),
            SettingsTile.switchTile(
              leading: Icon(Icons.access_time),
              title: Text('Relative Time'.tr()),
              description: Text(
                'Show note timestamps as relative (e.g. 5 minutes ago). '
                'Off shows absolute dates.'.tr(),
              ),
              initialValue: PreferencesStorage.isRelativeTime,
              onToggle: (bool value) {
                PreferencesStorage.setIsRelativeTime(value);
                setState(() {});
              },
            ),
            SettingsTile.switchTile(
              leading: Icon(Icons.sort),
              title: Text('Sort by Modified Date'.tr()),
              description: Text(
                'Sort notes by last modified time. '
                'Off sorts by creation time.'.tr(),
              ),
              initialValue: PreferencesStorage.isSortByModified,
              onToggle: (bool value) {
                PreferencesStorage.setIsSortByModified(value);
                setState(() {});
              },
            ),
            SettingsTile.navigation(
              leading: const Icon(Icons.dark_mode_outlined),
              title: Text('Dark Mode'.tr()),
              value: !PreferencesStorage.isThemeDark
                  ? Text('Off'.tr())
                  : Text('On'.tr()),
              onPressed: (context) {
                showThemeBottomSheet(context);
                setState(() {});
              },
            ),
            SettingsTile.navigation(
              leading: const Icon(Icons.screen_rotation_outlined),
              title: Text('Auto Rotate'.tr()),
              value: !PreferencesStorage.isAutoRotate
                  ? Text('Off'.tr())
                  : Text('On'.tr()),
              onPressed: (context) async {
                await Navigator.pushNamed(context, '/autoRotateSettings');
                setState(() {});
              },
            ),
            SettingsTile.navigation(
              leading: const Icon(Icons.format_paint_outlined),
              // leading: Icon(Icons.format_paint),
              title: Text('Notes Color'.tr()),
              value: !PreferencesStorage.isColorful
                  ? Text('Off'.tr())
                  : Text('On'.tr()),
              onPressed: (context) async {
                await Navigator.pushNamed(context, '/chooseColorSettings');
                setState(() {});
              },
            ),
            SettingsTile.navigation(
              leading: const Icon(Icons.language_outlined),
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Language'.tr()),
                  if (context.locale.toString() != 'en_US')
                    const Padding(
                      padding: EdgeInsets.only(top: 5),
                      child: Text(
                        'Language',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                ],
              ),
              value: Text(
                  SafeNotesConfig.mapLocaleName[context.locale.toString()]!),
              onPressed: (context) async {
                await Navigator.pushNamed(context, '/chooseLanguageSettings');
                setState(() {});
              },
            ),
          ],
        ),
        SettingsSection(
          title: Text('Security'.tr()),
          tiles: <SettingsTile>[
            SettingsTile.navigation(
              leading: Icon(Icons.fingerprint),
              title: Text('Biometric'.tr()),
              value: PreferencesStorage.isBiometricAuthEnabled
                  ? Text('On'.tr())
                  : Text('Off'.tr()),
              onPressed: (context) async {
                await Navigator.pushNamed(context, '/biometricSetting');
                setState(() {});
              },
            ),
            SettingsTile.navigation(
              leading: Icon(Icons.phonelink_lock),
              title: Text('Logout on Inactivity'.tr()),
              value: Text(inactivityTimeoutValue()),
              onPressed: (context) async {
                await Navigator.pushNamed(context, '/inactivityTimerSettings');
                setState(() {});
              },
            ),
            SettingsTile.navigation(
              leading: const Icon(Icons.phonelink_lock),
              title: Text('Secure Display'.tr()),
              value: PreferencesStorage.isFlagSecure
                  ? Text('On'.tr())
                  : Text('Off'.tr()),
              onPressed: (context) async {
                await Navigator.pushNamed(context, '/secureDisplaySetting');
                setState(() {});
              },
            ),
            SettingsTile.switchTile(
              leading: Icon(Icons.visibility_off),
              title: Text('Incognito Keyboard'.tr()),
              initialValue: PreferencesStorage.keyboardIncognito,
              onToggle: (bool value) {
                // 评审 #18：onToggle 入参即为用户切换后的目标值，直接用入参；
                // 原实现忽略入参再取反当前值，开关语义相反且违反契约。
                PreferencesStorage.setKeyboardIncognito(value);
                setState(() {});
              },
            ),
            SettingsTile.navigation(
              title: Text('Change Passphrase'.tr()),
              leading: const Icon(Icons.lock_outline),
              // leading: Icon(Icons.lock),
              onPressed: (context) async {
                await Navigator.pushNamed(context, '/changepassphrase');
              },
            ),
            SettingsTile.navigation(
              leading: const Icon(Icons.logout),
              title: Text('Logout'.tr()),
              onPressed: (context) async {
              // 顺序与 main.dart 超时退出 logout() 保持一致：
              // 1. 先停会话监听；2. 导航离开（不 await——该 Future 要等
              //    '/login' 被 pop 才完成，await 会把 logout 拖到下次登录后）；
              // 3. 导航落地、HomePage 卸载后再清敏感状态（clearDataKey 等）。
              // 若反过来先 logout 再导航，HomePage 仍挂载且 dataKey 已清，
              // 在途的 notes 读取会抛 DataKeyNotSetException。
              widget.sessionStateStream.add(SessionState.stopListening);

              if (context.mounted) {
                Navigator.pushNamedAndRemoveUntil(
                  context,
                  '/login',
                  (Route<dynamic> route) => false,
                  arguments: SessionArguments(
                    sessionStream: widget.sessionStateStream,
                    isKeyboardFocused: false,
                  ),
                );
              }

              await Session.logout();
            },
            ),
          ],
        ),
        SettingsSection(
          title: const Text('同步'),
          tiles: <SettingsTile>[
            SettingsTile.navigation(
              leading: const Icon(Icons.cloud_sync_outlined),
              title: const Text('同步设置'),
              value: Text(_syncStatusValue()),
              onPressed: (context) async {
                await Navigator.pushNamed(context, '/syncSettings');
                setState(() {});
              },
            ),
          ],
        ),
        SettingsSection(
          title: Text('Miscellaneous'.tr()),
          tiles: <SettingsTile>[
            SettingsTile.navigation(
              leading: const Icon(Icons.rate_review_outlined),
              title: Text('Rate Us'.tr()),
              onPressed: (_) async {
                String playstoreUrl = SafeNotesConfig.playStoreUrl;
                try {
                  await launchUrlExternal(Uri.parse(playstoreUrl));
                } catch (_) {}
              },
            ),
            SettingsTile.navigation(
              leading: Icon(Icons.quiz_outlined),
              title: Text('FAQs'.tr()),
              onPressed: (_) async {
                String faqsUrl = SafeNotesConfig.faqsUrl;
                try {
                  await launchUrlExternal(Uri.parse(faqsUrl));
                } catch (_) {}
              },
            ),
            SettingsTile.navigation(
              leading: Icon(Icons.code),
              title: Text('Source Code'.tr()),
              onPressed: (_) async {
                String sourceCodeUrl = SafeNotesConfig.githubUrl;
                try {
                  await launchUrlExternal(Uri.parse(sourceCodeUrl));
                } catch (_) {}
              },
            ),
            SettingsTile.navigation(
              leading: const Icon(Icons.mail_outline),
              title: Text('Email'.tr()),
              onPressed: (_) async {
                String email = SafeNotesConfig.mailToForFeedback;
                try {
                  await launchUrlExternal(Uri.parse(email));
                } catch (_) {}
              },
            ),
            SettingsTile.navigation(
              leading: const Icon(Icons.collections_bookmark_outlined),
              title: Text('Open Source license'.tr()),
              onPressed: (_) async {
                String license = SafeNotesConfig.openSourceLicense;
                try {
                  await launchUrlExternal(Uri.parse(license));
                } catch (_) {}
              },
              description: Padding(
                padding: const EdgeInsets.only(top: 20),
                child: footer(),
              ),
            ),
          ],
        ),
      ],
    );
  }

  String inactivityTimeoutValue() {
    // 评审 #18：取值走 PreferencesStorage 的统一来源，
    // 不再在设置页维护一份魔法数组 [30,1,2,3,5,10,15]
    var index = PreferencesStorage.inactivityTimeoutIndex;
    final seconds = PreferencesStorage.kInactivityTimeoutChoicesSeconds[index];
    if (seconds < 60) return '$seconds sec';
    return '${seconds ~/ 60} min';
  }

  /// 同步状态显示值
  ///
  /// 三态：总开关关掉 → 「已关闭」；开着但后端没配全 → 「未配置」；
  /// 都就绪 → 显示后端名称。
  String _syncStatusValue() {
    if (!SyncConfig.isSyncEnabled) return '已关闭';
    if (!SyncConfig.hasBackendConfig) return '未配置';
    return SyncConfig.backendDisplayName;
  }
}
