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

import 'package:core/core.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

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
  /// 仅桌面回退路径使用：Android/iOS/macOS 的认证由系统密钥门控完成，
  /// 这里再调一次 local_auth 就退化成了纯 UI 判断（见 BiometricAuth 注释）。
  final LocalAuthentication _auth = LocalAuthentication();

  /// 验证进行中标记：验证期间禁用开关，防止并发触发多次验证弹窗。
  bool _isVerifying = false;

  /// 启用/关闭生物识别登录。
  ///
  /// - 硬件绑定平台（Android/iOS/macOS）：写入凭据时系统会强制认证一次，
  ///   认证不通过则写入失败、开关保持关闭，无需前置 local_auth。
  /// - 桌面回退平台（Windows/Linux）：无密钥门控，先做一次 local_auth
  ///   便捷验证，再写入凭据。
  Future<void> _onEnableToggle(bool value) async {
    if (value) {
      if (!BiometricAuth.isHardwareBound && !await _verifyBiometric()) {
        if (mounted) {
          showSnackBarMessage(
            context,
            'Biometric verification failed. Biometric login was not enabled.'
                .tr(),
          );
        }
        if (mounted) setState(() {});
        return;
      }
      try {
        await BiometricAuth.enable(
          promptTitle: 'Verify your biometric to enable biometric login'.tr(),
        );
      } on Object catch (e, st) {
        // 用户取消系统认证 / 设备无可用凭据 / KeyStore 异常：一律保持关闭
        Log.auth.w('启用生物识别失败', error: e, stackTrace: st);
        if (mounted) {
          showSnackBarMessage(
            context,
            'Biometric verification failed. Biometric login was not enabled.'
                .tr(),
          );
        }
      }
    } else {
      await BiometricAuth.disable();
    }
    if (mounted) setState(() {});
  }

  /// 执行一次 local_auth 验证，返回是否通过（桌面回退路径专用）。
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

  /// 说明文案：硬件绑定与桌面便捷门控的安全等级不同，必须如实区分。
  String get _description {
    if (BiometricAuth.isHardwareBound) {
      return "Biometric credential is protected by the system keystore/keychain and can only be unlocked by your enrolled fingerprint or face. If you enroll a new biometric, you will need to re-enable this option."
          .tr();
    }
    return "On desktop this is a convenience lock only: it asks for your system sign-in (e.g. Windows Hello) but the credential is not bound to a hardware security module. Do not rely on it against an attacker who can already run code on this machine."
        .tr();
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
            description: _description,
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
