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
import 'package:core/core.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

// Project imports:
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/biometric_auth.dart';
import 'package:safenotes/utils/snack_message.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/widgets/shad_settings_tiles.dart';

class BiometricSetting extends StatefulWidget {
  const BiometricSetting({super.key});

  @override
  State<BiometricSetting> createState() => _BiometricSettingState();
}

class _BiometricSettingState extends State<BiometricSetting> {
  final LocalAuthentication _auth = LocalAuthentication();

  /// 验证进行中标记：验证期间禁用开关，防止并发触发多次验证弹窗。
  bool _isVerifying = false;

  /// 启用/关闭生物识别登录。
  ///
  /// 需求：启用前必须**先完成一次真实的生物识别验证**，验证通过才真正写入
  /// 凭据并打开开关；验证失败则保持关闭并提示用户（避免设备上生物识别本就
  /// 不可用/未录入时打开一个必然登录失败的开关）。
  Future<void> _onEnableToggle(bool value) async {
    if (value) {
      final ok = await _verifyBiometric();
      if (!ok) {
        if (mounted) {
          showSnackBarMessage(
            context,
            'Biometric verification failed. Biometric login was not enabled.'
                .tr(),
          );
        }
        setState(() {});
        return;
      }
      await BiometricAuth.enable();
    } else {
      await BiometricAuth.disable();
    }
    setState(() {});
  }

  /// 执行一次生物识别验证，返回是否通过。
  ///
  /// 复用与登录页一致的 LocalAuthentication 调用方式（含设备支持检测），
  /// 保证"启用时验证通过"与"登录时生物识别可用"行为一致。
  Future<bool> _verifyBiometric() async {
    setState(() => _isVerifying = true);
    try {
      final supported = await _auth.isDeviceSupported();
      final available = await _auth.canCheckBiometrics;
      if (!supported || !available) {
        Log.auth.w('启用生物识别验证失败: 设备不支持或无已录入生物识别');
        return false;
      }
      return await _auth.authenticate(
        localizedReason: 'Verify your biometric to enable biometric login'.tr(),
        persistAcrossBackgrounding: true,
      );
    } on Object catch (e, st) {
      Log.auth.w('启用生物识别前的验证失败', error: e, stackTrace: st);
      return false;
    } finally {
      if (mounted) setState(() => _isVerifying = false);
    }
  }

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
              if (_isVerifying) return;
              _onEnableToggle(value);
            },
          ),
        ]),
        const SizedBox(height: 12),
      ]),
    );
  }
}
