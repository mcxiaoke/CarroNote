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

import 'dart:convert';
import 'dart:typed_data';

import 'package:core/core.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/pin_auth.dart';

// Project imports:

class BiometricAuth {
  static const String _secureBiometricAuthKey = "_secureBiometricAuthKey";

  /// F-C01 修复：用于包裹密码的随机密钥，与包裹后的密文分开存储。
  ///
  /// 职责：把 vault 密码从「明文长期驻留 secure storage」改为「随机密钥包裹态」。
  /// 即使 secure storage 被部分导出/泄露，直接泄漏的也只是密文而非明文密码。
  static const String _secureBiometricWrapKey = "_secureBiometricWrapKey";

  /// 存储格式版本前缀：`v1:<base64(nonce||ciphertext||tag)>`
  ///
  /// 用于与新旧版本互操作：旧版本写入的是直接明文密码（无前缀），本类读取时
  /// 识别到无前缀按旧格式原样返回，保证升级兼容；下次写入密码时自动升级为 v1。
  static const String _wrappedPrefix = 'v1:';

  static const storage = FlutterSecureStorage();

  static Future<String> get authKey async {
    final value = await storage.read(key: _secureBiometricAuthKey) ?? '';
    if (value.isEmpty) return '';

    // 只记录是否命中及长度，绝不记录凭据内容（隐私红线）
    Log.auth.d('读取生物识别凭据: 已存在 (长度=${value.length})');

    if (value.startsWith(_wrappedPrefix)) {
      // v1：解包出明文密码用于后续登录（Keyring 解锁需要原始密码）
      return _unwrap(value);
    }

    // 旧版：值就是明文密码（无 v1: 前缀），兼容返回
    Log.auth.d('读取生物识别凭据: 旧版明文格式（待下次写入后自动升级为 v1）');
    return value;
  }

  static Future<void> setAuthKey() async {
    final pass = PhraseHandler.getPass;
    if (pass.isEmpty) {
      // 空密码写入会导致后续指纹登录必然失败，属于异常状态需要 warning
      Log.auth.w('写入生物识别凭据时会话密码为空, 指纹登录可能失效');
    }
    // F-C01：不直接存明文，用随机包裹密钥加密后存储
    final key = await _biometricWrapKey();
    final envelope = await SyncCrypto.seal(
      key,
      'biometric-auth',
      Uint8List.fromList(utf8.encode(pass)),
    );
    await storage.write(
      key: _secureBiometricAuthKey,
      value: '$_wrappedPrefix${base64Encode(envelope)}',
    );
    Log.auth.i('生物识别凭据已更新为包裹态 (escaped=${pass.isEmpty})');
  }

  static Future<void> disable() async {
    Log.auth.i('生物识别认证: 开始关闭');
    await PreferencesStorage.setIsBiometricAuthEnabled(false);
    // F-C01：直接删除镜像密码与解包密钥两条记录，无需"先写后删"
    // （覆盖写入在 secure storage 下并不比删除更彻底，删掉即可移除端侧可恢复源）
    await storage.delete(key: _secureBiometricAuthKey);
    await storage.delete(key: _secureBiometricWrapKey);
    Log.auth.i('生物识别认证已关闭, 密文与包裹密钥均已清除');
  }

  static Future<void> enable() async {
    Log.auth.i('生物识别认证: 开始开启');
    if (PreferencesStorage.isPinAuthEnabled) {
      Log.auth.i('生物识别认证开启，自动关闭已启用的 PIN 锁定');
      await PinAuth.disable();
    }
    await PreferencesStorage.setIsBiometricAuthEnabled(true);
    // 重新开启时生成新的包裹密钥（丢弃旧 KEY，防止开关周期内密钥复用）
    await storage.delete(key: _secureBiometricWrapKey);
    await setAuthKey();
    Log.auth.i('生物识别认证已开启');
  }

  /// 读取或首次生成包裹密钥（32B 随机）
  static Future<Uint8List> _biometricWrapKey() async {
    final existing = await storage.read(key: _secureBiometricWrapKey);
    if (existing != null && existing.isNotEmpty) {
      return base64Decode(existing);
    }
    final fresh = SyncCrypto.generateDataKey();
    await storage.write(
      key: _secureBiometricWrapKey,
      value: base64Encode(fresh),
    );
    return fresh;
  }

  static Future<String> _unwrap(String wrapped) async {
    try {
      final key = await _biometricWrapKey();
      final envelope = base64Decode(wrapped.substring(_wrappedPrefix.length));
      final bytes = await SyncCrypto.open(key, 'biometric-auth', envelope);
      return utf8.decode(bytes);
    } on Object catch (e, st) {
      // 解包失败：包裹密钥缺失/被篡改/数据损坏。返回空串使指纹登录走失败分支，
      // 绝不回退到明文继续存储，避免泄漏。
      Log.auth.e('生物识别凭据解包失败（指纹登录将不可用）', error: e, stackTrace: st);
      return '';
    }
  }
}
