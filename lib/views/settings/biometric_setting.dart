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
import 'package:easy_localization/easy_localization.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

// Project imports:
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/biometric_auth.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/widgets/shad_settings_tiles.dart';

class BiometricSetting extends StatefulWidget {
  const BiometricSetting({super.key});

  @override
  State<BiometricSetting> createState() => _BiometricSettingState();
}

class _BiometricSettingState extends State<BiometricSetting> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Biometric'.tr(), style: appBarTitle)),
      body: shadSettingsList([
        shadSettingsCard([
          shadSwitchTile(
            context,
            icon: LucideIcons.fingerprint,
            title: 'Enable biometric authentication'.tr(),
            description:
                "Users are advised to assess their threat perception before enabling biometric authentication. Don't enable this if you're storing state secrets! Visit FAQs for more information."
                    .tr(),
            value: PreferencesStorage.isBiometricAuthEnabled,
            onChanged: (value) {
              if (value) {
                BiometricAuth.enable();
              } else {
                BiometricAuth.disable();
              }
              setState(() {});
            },
          ),
        ]),
        const SizedBox(height: 12),
      ]),
    );
  }
}
