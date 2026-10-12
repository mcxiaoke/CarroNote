/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:core/core.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
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

/// PIN Lock 认证 —— 快速解锁方式
///
/// 安全加固架构（详见 docs/pin-lock-design.md §4）：
/// - `_securePinKdfKey`: KDF 参数 JSON（明文，含独立随机盐与平台自适应参数）
/// - `_securePinAuthKey`: PIN + 硬件指纹派生密钥直接 seal 的 vault 主密码（AES-256-GCM，单层信封）
/// - 不再持久化任何 `_securePinWrapKey` 明文，彻底消除同机恶意进程旁路读取主密码的隐患。
/// - 绑定设备硬件特征（Device Binding）：即使安全存储文件被拷走，在异地机器上脱机穷举亦必然失效。
///
/// 验证流程: 输入 PIN + 硬件指纹 → Argon2id 派生 → 直接解密 vault 密码 → 复用现有 `_login(passphrase)`。
class PinAuth {
  /// 连续失败阈值:达到后自动关闭 PIN,回退到密码登录(设计文档 §6)
  static const int kPinMaxFailedAttempts = 5;

  static const String _securePinKdfKey = '_securePinKdfKey';
  static const String _securePinAuthKey = '_securePinAuthKey';

  // 历史旧版本 key（用于清理与向后兼容）
  static const String _securePinEnvelopeKey = '_securePinEnvelopeKey';
  static const String _securePinWrapKey = '_securePinWrapKey';

  /// 存储格式版本前缀:`v1:<base64(nonce||ciphertext||tag)>`
  static const String _wrappedPrefix = 'v1:';

  /// AES-GCM AAD 域分隔符,与其它加密消费方隔离
  static const String _aad = 'pin-auth';

  /// 桌面端加固 Argon2id 参数：128 MiB (131072 KiB)，t=4，p=4（经本地实测约 658ms）
  static const int kDesktopArgon2idMemoryKib = 131072;
  static const int kDesktopArgon2idIterations = 4;
  static const int kDesktopArgon2idParallelism = 4;

  /// 移动端 / Web 默认参数：32 MiB (32768 KiB)，t=3，p=2（实测约 173ms）
  static const int kMobileArgon2idMemoryKib = 32768;
  static const int kMobileArgon2idIterations = 3;
  static const int kMobileArgon2idParallelism = 2;

  static const storage = FlutterSecureStorage();

  static bool get isEnabled => PreferencesStorage.isPinAuthEnabled;

  /// 测试专用设备指纹注入（用于单元测试模拟设备迁移）
  @visibleForTesting
  static String? testDevicePepperOverride;

  /// 当前生效的 PIN 策略(长度 + 字符集 + 随机键序)
  static PinPolicy get policy => PinPolicy(
    length: PreferencesStorage.pinLength,
    charset: PinCharset.fromIndex(PreferencesStorage.pinCharsetIndex),
    shuffle: PreferencesStorage.pinShuffleEnabled,
  );

  /// 设置 / 修改 PIN
  ///
  /// 用当前会话密码生成凭据(调用前必须已登录,`PhraseHandler.getPass` 非空)。
  /// 成功后打开 PIN 开关。
  static Future<void> setPin(String pin, {PinPolicy? policy}) async {
    final pass = PhraseHandler.getPass;
    if (pass.isEmpty) {
      Log.auth.w('写入 PIN 凭据时会话密码为空, PIN 解锁可能不可用');
    }
    final effective = policy ?? PinPolicy();

    // 1. 生成平台自适应的 KDF 参数（含独立随机盐）
    final kdf = _createKdfParams();
    await storage.write(key: _securePinKdfKey, value: jsonEncode(kdf.toJson()));

    // 2. PIN + 硬件指纹 → Argon2id 派生密钥
    final pinKey = await _derivePinKey(pin, kdf);

    // 3. 直接用 PIN 密钥 seal vault 密码（单层直接信封，彻底杜绝 wrapKey 明文存储）
    final passwordEnvelope = await SyncCrypto.seal(
      pinKey,
      _aad,
      Uint8List.fromList(utf8.encode(pass)),
    );
    await storage.write(
      key: _securePinAuthKey,
      value: '$_wrappedPrefix${base64Encode(passwordEnvelope)}',
    );

    // 4. 清理旧版可能遗留的历史 key
    await storage.delete(key: _securePinWrapKey);
    await storage.delete(key: _securePinEnvelopeKey);

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
      '字符集=${effective.charset.name} 随机键序=${effective.shuffle} '
      'KDF内存=${kdf.memoryKiB}KiB 迭代=${kdf.iterations} 并行=${kdf.parallelism}',
    );
  }

  /// 验证 PIN,成功返回 vault 密码,失败返回空串
  ///
  /// 任一步骤 GCM 校验失败都视为 PIN 错误(无静默错误路径)。
  /// 成功时清零失败计数;失败时由调用方负责 [onPinFailed] 计数。
  static Future<String> verifyPin(String pin) async {
    final kdf = await _kdfParams();
    final authKey = await storage.read(key: _securePinAuthKey);
    if (kdf == null || authKey == null) {
      Log.auth.w('PIN 凭据不完整(未设置或已清除), 解锁不可用');
      return '';
    }
    try {
      // 1. PIN + 硬件指纹 → Argon2id → 密钥
      final pinKey = await _derivePinKey(pin, kdf);
      // 2. 直接解密 vault 密码
      final passwordEnvelope = base64Decode(_stripPrefix(authKey));
      final bytes = await SyncCrypto.open(pinKey, _aad, passwordEnvelope);
      final pass = utf8.decode(bytes);
      if (pass.isEmpty) {
        Log.auth.w('PIN 验证通过但解出的密码为空, 视为失败');
        return '';
      }
      await PreferencesStorage.setPinFailedCount(0);
      return pass;
    } on Object catch (e, st) {
      // 若新版解密失败，尝试旧版双层信封向后兼容（平滑过渡）
      final legacyWrapped = await storage.read(key: _securePinEnvelopeKey);
      if (legacyWrapped != null) {
        try {
          final legacyPinKey = await SyncCrypto.deriveMasterKeyAsync(
            pin,
            kdf: kdf,
          );
          final envelope = base64Decode(_stripPrefix(legacyWrapped));
          final wrapKey = await SyncCrypto.open(legacyPinKey, _aad, envelope);
          final passwordEnvelope = base64Decode(_stripPrefix(authKey));
          final bytes = await SyncCrypto.open(wrapKey, _aad, passwordEnvelope);
          final pass = utf8.decode(bytes);
          if (pass.isNotEmpty) {
            Log.auth.i('检测到旧版 PIN 凭据，验证通过，自动无感升级为新版单层加固信封');
            PhraseHandler.initPass(pass);
            await setPin(pin, policy: policy);
            await PreferencesStorage.setPinFailedCount(0);
            return pass;
          }
        } on Object catch (e2, st2) {
          Log.auth.w('旧版兼容解封亦失败', error: e2, stackTrace: st2);
        }
      }
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
    Log.auth.i('PIN 锁定: 开始关闭并销毁全部凭据');
    await PreferencesStorage.setIsPinAuthEnabled(false);
    await storage.delete(key: _securePinKdfKey);
    await storage.delete(key: _securePinEnvelopeKey);
    await storage.delete(key: _securePinWrapKey);
    await storage.delete(key: _securePinAuthKey);
    await PreferencesStorage.setPinFailedCount(0);
    Log.auth.i('PIN 锁定已关闭, 全部凭据已清除');
  }

  // ──────────────────────────────────────────────
  // 内部
  // ──────────────────────────────────────────────

  /// 生成平台自适应的 KdfParams
  static KdfParams _createKdfParams() {
    final isDesktop =
        !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
    return KdfParams(
      algorithm: kArgon2idAlgorithm,
      salt: base64.encode(SyncCrypto.generateSalt()),
      iterations: isDesktop
          ? kDesktopArgon2idIterations
          : kMobileArgon2idIterations,
      memoryKiB: isDesktop
          ? kDesktopArgon2idMemoryKib
          : kMobileArgon2idMemoryKib,
      parallelism: isDesktop
          ? kDesktopArgon2idParallelism
          : kMobileArgon2idParallelism,
    );
  }

  /// 获取硬件设备唯一指纹（用于设备绑定防脱机拷贝爆破）
  static Future<String> _getDevicePepper() async {
    if (testDevicePepperOverride != null) return testDevicePepperOverride!;
    try {
      if (kIsWeb) return 'web-client';
      final info = DeviceInfoPlugin();
      if (Platform.isWindows) {
        final win = await info.windowsInfo;
        return win.deviceId;
      } else if (Platform.isLinux) {
        final linux = await info.linuxInfo;
        return linux.machineId ?? 'linux-machine';
      } else if (Platform.isMacOS) {
        final mac = await info.macOsInfo;
        return mac.systemGUID ?? '${mac.computerName}-${mac.model}';
      } else if (Platform.isAndroid) {
        final android = await info.androidInfo;
        return android.id;
      } else if (Platform.isIOS) {
        final ios = await info.iosInfo;
        return ios.identifierForVendor ?? 'ios-device';
      }
    } on Object catch (e, st) {
      Log.auth.w('获取设备硬件指纹失败，回退默认设备标识', error: e, stackTrace: st);
    }
    return 'fallback-device-id';
  }

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

  static Future<Uint8List> _derivePinKey(String pin, KdfParams kdf) async {
    final pepper = await _getDevicePepper();
    final combined = '$pin#$pepper';
    // 只记录长度与算法参数,绝不记录 PIN 内容或硬件指纹详情(隐私红线)
    Log.auth.d(
      'PIN 密钥派生: 长度=${pin.length} 算法=${kdf.algorithm} '
      'mem=${kdf.memoryKiB}KiB iter=${kdf.iterations} p=${kdf.parallelism}',
    );
    return SyncCrypto.deriveMasterKeyAsync(combined, kdf: kdf);
  }

  static String _stripPrefix(String value) => value.startsWith(_wrappedPrefix)
      ? value.substring(_wrappedPrefix.length)
      : value;
}
