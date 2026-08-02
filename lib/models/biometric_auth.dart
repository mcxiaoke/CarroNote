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

// Package imports:
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// Project imports:
import 'package:safenotes/data/preference_and_config.dart';
import 'package:core/core.dart';

// Project imports:

class BiometricAuth {
  static const String _secureBiometricAuthKey = "_secureBiometricAuthKey";
  static const storage = FlutterSecureStorage();

  static Future<String> get authKey async {
    final value = await storage.read(key: _secureBiometricAuthKey) ?? '';
    // 只记录是否命中及长度，绝不记录凭据内容（隐私红线）
    Log.auth.d(
      '读取生物识别凭据: ${value.isEmpty ? "为空(未设置或已清除)" : "已存在 (长度=${value.length})"}',
    );
    return value;
  }

  static Future<void> setAuthKey() async {
    final pass = PhraseHandler.getPass;
    if (pass.isEmpty) {
      // 空密码写入会导致后续指纹登录必然失败，属于异常状态需要 warning
      Log.auth.w('写入生物识别凭据时会话密码为空, 指纹登录可能失效');
    }
    await storage.write(
      key: _secureBiometricAuthKey,
      value: pass,
    );
    Log.auth.i('生物识别凭据已写入安全存储 (长度=${pass.length})');
  }

  static Future<void> disable() async {
    Log.auth.i('生物识别认证: 开始关闭');
    await PreferencesStorage.setIsBiometricAuthEnabled(false);
    // Overwrite
    await storage.write(
      key: _secureBiometricAuthKey,
      value: "BiometricAuthDisabled",
    );
    await storage.delete(key: _secureBiometricAuthKey);
    Log.auth.i('生物识别认证已关闭, 安全存储中的凭据已覆写并删除');
  }

  static Future<void> enable() async {
    Log.auth.i('生物识别认证: 开始开启');
    await PreferencesStorage.setIsBiometricAuthEnabled(true);
    await setAuthKey();
    Log.auth.i('生物识别认证已开启');
  }
}
