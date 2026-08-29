/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

import 'dart:convert';
import 'dart:typed_data';

import 'package:core/core.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/biometric_auth.dart';

/// PIN 字符集(三种键盘类型,见 docs/pin-lock-design.md §8)
///
/// 数据层只处理字符串、不感知字符集;键盘按 [PinCharsetLayout] 的按键序列
/// 与列数渲染。
enum PinCharset {
  /// 纯数字:10 键,3×4(1-9 + 0,0 居中)
  digits,

  /// 数字+字母:10 数字 + 13 字母(A–H,J–N,去易混 I),4×6;宽屏 6×4
  alphanumeric,

  /// 精简版全键盘:10 数字 + 26 字母 + - . _ 共 39 键,5×8;桌面 8×5
  letters;

  static PinCharset fromIndex(int index) =>
      index >= 0 && index < values.length ? values[index] : digits;
}

/// PIN 字符集 → 键盘布局元数据(按键序列 + 列数)
///
/// 按键序列中空字符串为占位格;删除键由 [PinKeyboard] 固定在网格末尾。
/// 数字+字母键盘取字母表前 13 个(A–H,J–N),为 4×6 贴合主流手机 2:1 竖屏;
/// 去掉与 1 / l 易混淆的 I。
extension PinCharsetLayout on PinCharset {
  List<String> get keys => switch (this) {
    PinCharset.digits => const [
      '1',
      '2',
      '3',
      '4',
      '5',
      '6',
      '7',
      '8',
      '9',
      '',
      '0',
    ],
    PinCharset.alphanumeric => const [
      '1',
      '2',
      '3',
      '4',
      '5',
      '6',
      '7',
      '8',
      '9',
      '0',
      // 字母表最前的 A–H + J–N(跳过易与 1/l 混淆的 I)
      'A',
      'B',
      'C',
      'D',
      'E',
      'F',
      'G',
      'H',
      'J',
      'K',
      'L',
      'M',
      'N',
    ],
    PinCharset.letters => const [
      // 数字行 → A-Z → 三个符号。行主序使 5列(窄屏)/8列(桌面)都整齐无占位。
      '1',
      '2',
      '3',
      '4',
      '5',
      '6',
      '7',
      '8',
      '9',
      '0',
      'A',
      'B',
      'C',
      'D',
      'E',
      'F',
      'G',
      'H',
      'I',
      'J',
      'K',
      'L',
      'M',
      'N',
      'O',
      'P',
      'Q',
      'R',
      'S',
      'T',
      'U',
      'V',
      'W',
      'X',
      'Y',
      'Z',
      '-',
      '.',
      '_',
    ],
  };

  int get columns => switch (this) {
    PinCharset.digits => 3,
    // 数字+字母:23 键 + 删除 = 24 格,4 列 → 6 行(贴合手机 2:1)
    PinCharset.alphanumeric => 4,
    // 精简全键盘:39 键 + 删除 = 40 格,5 列 → 8 行(无占位)
    PinCharset.letters => 5,
  };

  /// 宽屏(横屏/桌面)时的列数(null = 保持 [columns])
  ///
  /// 窄屏 4列×6行 / 宽屏 6列×4行:窄屏竖排时列少行多、按键更大更好点,
  /// 宽屏横向空间充足用 6 列少两行。纯数字保持 3×4 不变。
  int? get columnsWide => switch (this) {
    PinCharset.digits => null,
    PinCharset.alphanumeric => 6,
    // 精简全键盘桌面 8 列 → 5 行(贴近标准全键盘)
    PinCharset.letters => 8,
  };
}

/// PIN 策略:长度 + 字符集 + 随机键序
class PinPolicy {
  const PinPolicy({
    this.length = PreferencesStorage.kPinDefaultLength,
    this.charset = PinCharset.digits,
    this.shuffle = false,
  });

  final int length;
  final PinCharset charset;

  /// 随机键序(防肩窥):每次打开键盘打乱键位。仅影响显示层,不影响验证。
  final bool shuffle;
}

/// PIN Lock 认证 —— 与 [BiometricAuth] 平行的第二解锁方式
///
/// 架构与 `BiometricAuth` 完全平行(包裹密钥 + 信封,详见
/// docs/pin-lock-design.md §4):
///
/// - `_securePinKdfKey`: KDF 参数 JSON(明文,含随机盐)
/// - `_securePinEnvelopeKey`: PIN 派生密钥 seal 的包裹密钥
/// - `_securePinWrapKey`: 包裹密钥明文副本(改密码联动用,与 BiometricAuth
///   同级威胁模型,见设计文档 §4.3)
/// - `_securePinAuthKey`: 包裹密钥 seal 的 vault 密码(与
///   `BiometricAuth._secureBiometricAuthKey` 同构)
///
/// 验证流程: 输入 PIN → Argon2id 派生 → 解包裹密钥 → 解出 vault 密码 →
/// 复用现有 `_login(passphrase)`。
class PinAuth {
  /// 连续失败阈值:达到后自动关闭 PIN,回退到密码登录(设计文档 §6)
  static const int kPinMaxFailedAttempts = 5;

  static const String _securePinKdfKey = '_securePinKdfKey';
  static const String _securePinEnvelopeKey = '_securePinEnvelopeKey';
  static const String _securePinWrapKey = '_securePinWrapKey';
  static const String _securePinAuthKey = '_securePinAuthKey';

  /// 存储格式版本前缀:`v1:<base64(nonce||ciphertext||tag)>`
  /// 与 `BiometricAuth` 一致;旧版本写入的无前缀值按旧格式原样兼容返回。
  static const String _wrappedPrefix = 'v1:';

  /// AES-GCM AAD 域分隔符,与其它加密消费方隔离
  static const String _aad = 'pin-auth';

  static const storage = FlutterSecureStorage();

  static bool get isEnabled => PreferencesStorage.isPinAuthEnabled;

  /// 当前生效的 PIN 策略(长度 + 字符集 + 随机键序)
  static PinPolicy get policy => PinPolicy(
    length: PreferencesStorage.pinLength,
    charset: PinCharset.fromIndex(PreferencesStorage.pinCharsetIndex),
    shuffle: PreferencesStorage.pinShuffleEnabled,
  );

  /// 设置 / 修改 PIN
  ///
  /// 用当前会话密码生成凭据(调用前必须已登录,`PhraseHandler.getPass` 非空)。
  /// 重设时轮换包裹密钥与盐,避免复用旧凭据。成功后打开 PIN 开关。
  static Future<void> setPin(String pin, {PinPolicy? policy}) async {
    final pass = PhraseHandler.getPass;
    if (pass.isEmpty) {
      // 空密码写入会导致后续 PIN 解锁必然失败,属于异常状态需要 warning
      Log.auth.w('写入 PIN 凭据时会话密码为空, PIN 解锁可能不可用');
    }
    final effective = policy ?? PinPolicy();

    // 1. 新包裹密钥 + 新盐(重设时轮换)
    final wrapKey = SyncCrypto.generateDataKey();
    await storage.write(key: _securePinWrapKey, value: base64Encode(wrapKey));

    // 2. 包裹密钥 seal vault 密码
    final passwordEnvelope = await SyncCrypto.seal(
      wrapKey,
      _aad,
      Uint8List.fromList(utf8.encode(pass)),
    );
    await storage.write(
      key: _securePinAuthKey,
      value: '$_wrappedPrefix${base64Encode(passwordEnvelope)}',
    );

    // 3. 新盐 + KDF 参数(Argon2id,见设计文档 §5)
    final kdf = KdfParams.create(salt: SyncCrypto.generateSalt());
    await storage.write(key: _securePinKdfKey, value: jsonEncode(kdf.toJson()));

    // 4. PIN 派生密钥 seal 包裹密钥
    final pinKey = await _derivePinKey(pin, kdf);
    final wrapEnvelope = await SyncCrypto.seal(
      pinKey,
      _aad,
      Uint8List.fromList(wrapKey),
    );
    await storage.write(
      key: _securePinEnvelopeKey,
      value: '$_wrappedPrefix${base64Encode(wrapEnvelope)}',
    );

    // 5. 持久化策略与开关
    if (PreferencesStorage.isBiometricAuthEnabled) {
      Log.auth.i('PIN 锁定设置成功，自动关闭已启用的生物识别认证');
      await BiometricAuth.disable();
    }
    await PreferencesStorage.setPinLength(effective.length);
    await PreferencesStorage.setPinCharsetIndex(effective.charset.index);
    await PreferencesStorage.setPinShuffleEnabled(effective.shuffle);
    await PreferencesStorage.setIsPinAuthEnabled(true);
    await PreferencesStorage.setPinFailedCount(0);
    Log.auth.i(
      'PIN 凭据已更新: 长度=${effective.length} '
      '字符集=${effective.charset.name} 随机键序=${effective.shuffle}',
    );
  }

  /// 验证 PIN,成功返回 vault 密码,失败返回空串
  ///
  /// 任一步骤 GCM 校验失败都视为 PIN 错误(无静默错误路径)。
  /// 成功时清零失败计数;失败时由调用方负责 [onPinFailed] 计数。
  static Future<String> verifyPin(String pin) async {
    final kdf = await _kdfParams();
    final wrapped = await storage.read(key: _securePinEnvelopeKey);
    final authKey = await storage.read(key: _securePinAuthKey);
    if (kdf == null || wrapped == null || authKey == null) {
      Log.auth.w('PIN 凭据不完整(未设置或已清除), 解锁不可用');
      return '';
    }
    try {
      // 1. PIN → Argon2id → 密钥
      final pinKey = await _derivePinKey(pin, kdf);
      // 2. 解包裹密钥
      final envelope = base64Decode(_stripPrefix(wrapped));
      final wrapKey = await SyncCrypto.open(pinKey, _aad, envelope);
      // 3. 解 vault 密码
      final passwordEnvelope = base64Decode(_stripPrefix(authKey));
      final bytes = await SyncCrypto.open(wrapKey, _aad, passwordEnvelope);
      final pass = utf8.decode(bytes);
      if (pass.isEmpty) {
        Log.auth.w('PIN 验证通过但解出的密码为空, 视为失败');
        return '';
      }
      await PreferencesStorage.setPinFailedCount(0);
      return pass;
    } on Object catch (e, st) {
      // 解封失败 = PIN 错误(或凭据损坏);绝不回退到明文继续存储
      Log.auth.w('PIN 验证失败(解封不通过)', error: e, stackTrace: st);
      return '';
    }
  }

  /// PIN 验证失败后的计数处理
  ///
  /// 返回 true 表示已达到阈值并已自动关闭 PIN(调用方应提示用户
  /// 改用密码登录);false 表示还有剩余次数。
  static Future<bool> onPinFailed() async {
    final count = PreferencesStorage.pinFailedCount + 1;
    await PreferencesStorage.setPinFailedCount(count);
    if (count >= kPinMaxFailedAttempts) {
      Log.auth.w('PIN 连续失败 $count 次, 达到阈值, 自动关闭 PIN 锁定');
      await disable();
      return true;
    }
    Log.auth.d('PIN 验证失败: 第 $count/$kPinMaxFailedAttempts 次');
    return false;
  }

  /// 关闭 PIN:删除全部凭据并关闭开关
  static Future<void> disable() async {
    Log.auth.i('PIN 锁定: 开始关闭');
    await PreferencesStorage.setIsPinAuthEnabled(false);
    await storage.delete(key: _securePinKdfKey);
    await storage.delete(key: _securePinEnvelopeKey);
    await storage.delete(key: _securePinWrapKey);
    await storage.delete(key: _securePinAuthKey);
    await PreferencesStorage.setPinFailedCount(0);
    Log.auth.i('PIN 锁定已关闭, 全部凭据已清除');
  }

  /// 修改 vault 密码后的联动刷新(无需 PIN,见设计文档 §4.2)
  ///
  /// 读包裹密钥明文副本,用其重新 seal 新密码;PIN 信封与 PIN 本身不变。
  /// 调用时机:`Session.login` / `Session.onPasswordSet`(与 BiometricAuth 对称)。
  static Future<void> refreshCredential() async {
    final wrapKeyB64 = await storage.read(key: _securePinWrapKey);
    final authKey = await storage.read(key: _securePinAuthKey);
    if (wrapKeyB64 == null || authKey == null) {
      Log.auth.w('PIN 凭据不完整, 跳过改密码联动刷新');
      return;
    }
    final pass = PhraseHandler.getPass;
    if (pass.isEmpty) {
      Log.auth.w('刷新 PIN 凭据时会话密码为空, 跳过');
      return;
    }
    final wrapKey = base64Decode(wrapKeyB64);
    final envelope = await SyncCrypto.seal(
      wrapKey,
      _aad,
      Uint8List.fromList(utf8.encode(pass)),
    );
    await storage.write(
      key: _securePinAuthKey,
      value: '$_wrappedPrefix${base64Encode(envelope)}',
    );
    Log.auth.i('PIN 凭据已随密码变更联动刷新');
  }

  // ──────────────────────────────────────────────
  // 内部
  // ──────────────────────────────────────────────

  static Future<KdfParams?> _kdfParams() async {
    final raw = await storage.read(key: _securePinKdfKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return KdfParams.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } on Object catch (e, st) {
      Log.auth.w('PIN KDF 参数解析失败(按未设置处理)', error: e, stackTrace: st);
      return null;
    }
  }

  static Future<Uint8List> _derivePinKey(String pin, KdfParams kdf) {
    // 只记录长度,绝不记录 PIN 内容(隐私红线)
    Log.auth.d('PIN 密钥派生: 长度=${pin.length} 算法=${kdf.algorithm}');
    return SyncCrypto.deriveMasterKeyAsync(pin, kdf: kdf);
  }

  static String _stripPrefix(String value) => value.startsWith(_wrappedPrefix)
      ? value.substring(_wrappedPrefix.length)
      : value;
}
