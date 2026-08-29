/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'package:easy_localization/easy_localization.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/widgets/shad_settings_tiles.dart';

class SecuritySettingsPage extends StatefulWidget {
  const SecuritySettingsPage({super.key});

  @override
  State<SecuritySettingsPage> createState() => _SecuritySettingsPageState();
}

class _SecuritySettingsPageState extends State<SecuritySettingsPage> {
  late bool _isFlagSecure;
  late bool _keyboardIncognito;

  late String _biometricValue;
  late String _pinValue;
  late String _inactivityValue;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadValues();
  }

  @override
  void initState() {
    super.initState();
    _isFlagSecure = PreferencesStorage.isFlagSecure;
    _keyboardIncognito = PreferencesStorage.keyboardIncognito;
  }

  void _loadValues() {
    _biometricValue = PreferencesStorage.isBiometricAuthEnabled
        ? 'On'.tr()
        : 'Off'.tr();
    _pinValue = PreferencesStorage.isPinAuthEnabled
        ? 'On · {n} digits'.tr(
            namedArgs: {'n': '${PreferencesStorage.pinLength}'},
          )
        : 'Off'.tr();
    _inactivityValue = _inactivityTimeoutValue();
  }

  void _refresh() => setState(_loadValues);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Security'.tr(), style: appBarTitle)),
      body: shadSettingsList([
        shadSectionTitle(context, 'Authentication'.tr()),
        shadSettingsCard([
          if (!kIsWeb)
            shadNavigationTile(
              context,
              key: const Key('ui-setting-item-biometric'),
              icon: LucideIcons.fingerprint,
              title: 'Biometric'.tr(),
              value: _biometricValue,
              onTap: () async {
                await Navigator.pushNamed(context, '/biometricSetting');
                _refresh();
              },
            ),
          shadNavigationTile(
            context,
            key: const Key('ui-setting-item-pin'),
            icon: LucideIcons.key,
            title: 'PIN Lock'.tr(),
            value: _pinValue,
            onTap: () async {
              await Navigator.pushNamed(context, '/pinSetting');
              _refresh();
            },
          ),
          shadNavigationTile(
            context,
            key: const Key('ui-setting-item-inactivity'),
            icon: LucideIcons.smartphone,
            title: 'Logout on Inactivity'.tr(),
            value: _inactivityValue,
            onTap: () async {
              await Navigator.pushNamed(context, '/inactivityTimerSettings');
              _refresh();
            },
          ),
          shadNavigationTile(
            context,
            key: const Key('ui-setting-item-changepassphrase'),
            icon: LucideIcons.lock,
            title: 'Change Passphrase'.tr(),
            onTap: () async {
              await Navigator.pushNamed(context, '/changepassphrase');
            },
          ),
        ]),
        shadSectionTitle(context, 'Privacy'.tr()),
        shadSettingsCard([
          shadSwitchTile(
            context,
            icon: LucideIcons.monitorOff,
            title: 'Secure Display'.tr(),
            description:
                '${'When turned on, the content on the screen is treated as secure, blocking background snapshots and preventing it from appearing in screenshots or from being viewed on non-secure displays.'.tr()} '
                '${'Note: on Android 13 and above, for privacy the recent-tasks thumbnail is always hidden even when this is off.'.tr()}',
            value: _isFlagSecure,
            onChanged: (v) {
              PreferencesStorage.setIsFlagSecure(v);
              setState(() => _isFlagSecure = v);
            },
          ),
          shadSwitchTile(
            context,
            icon: LucideIcons.eyeOff,
            title: 'Incognito Keyboard'.tr(),
            value: _keyboardIncognito,
            onChanged: (v) {
              PreferencesStorage.setKeyboardIncognito(v);
              setState(() => _keyboardIncognito = v);
            },
          ),
        ]),
        const SizedBox(height: 12),
      ]),
    );
  }

  String _inactivityTimeoutValue() {
    final index = PreferencesStorage.inactivityTimeoutIndex;
    final seconds = PreferencesStorage.kInactivityTimeoutChoicesSeconds[index];
    if (seconds < 60) {
      return '{seconds} sec'.tr(namedArgs: {'seconds': '$seconds'});
    }
    return '{minutes} min'.tr(namedArgs: {'minutes': '${seconds ~/ 60}'});
  }
}
