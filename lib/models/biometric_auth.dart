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
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:core/core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/pin_auth.dart';

/// 生物识别解锁的结果分类。
///
/// 调用方需区分「用户取消」「凭据缺失」「真正失败」三种情况：取消不计入失败
/// 次数、凭据缺失应自动关闭开关、只有真失败才计次。
enum BiometricUnlockStatus {
  /// 取回密码，可继续走 `_login(passphrase)`
  success,

  /// 用户取消系统认证（返回键 / 取消按钮 / 切换密码）
  cancelled,

  /// 本机没有可用的生物凭据（未启用、换机、录入新生物特征致 Keychain 失效）
  notConfigured,

  /// 其他失败（认证通过但解密失败、KeyStore 异常等）
  failed,
}

/// [BiometricAuth.unlock] 的返回值。
class BiometricUnlockResult {
  const BiometricUnlockResult(this.status, {this.passphrase = '', this.error});

  final BiometricUnlockStatus status;

  /// 仅在 [status] 为 success 时非空
  final String passphrase;

  /// 原始异常，供日志留痕（绝不包含凭据内容）
  final Object? error;

  bool get isSuccess => status == BiometricUnlockStatus.success;
}

/// 生物识别认证 —— 快速解锁方式
///
/// ## 安全模型（2026-10 起）
///
/// 分两条平台路径，区别在于「认证约束由谁保证」：
///
/// **A. 硬件绑定路径（Android / iOS / macOS）**
/// 凭据存放在 keychain/keystore 的**受认证保护**条目里：
/// - Android：`AndroidOptions.biometric()` → KeyStore AES 密钥
///   `setUserAuthenticationRequired(true)` + `setInvalidatedByBiometricEnrollment(true)`，
///   独立 `storageNamespace` 隔离，读取时由系统 BiometricPrompt 认证后才解密；
/// - iOS/macOS：`accessControlFlags: [biometryCurrentSet]` →
///   `SecAccessControlCreateWithFlags(.biometryCurrentSet)`，条目本身要求当前录入的
///   生物特征才能读出。
///
/// 也就是说：**解密动作与认证是同一件事**，没有「先 authenticate 拿到 true 再去读」
/// 的时间窗，也没有可被同机进程直接读取的明文包裹密钥。因此本路径**不调用**
/// `local_auth.authenticate()`——再套一层只会把硬件门控退化成 UI 判断。
///
/// **B. 桌面回退路径（Windows / Linux / Web）**
/// 这几个平台没有任何生物识别密钥门控能力（`WindowsOptions` 只有
/// `useBackwardCompatibility`，Linux 走 libsecret 同样无认证约束），
/// 因此沿用旧方案：随机包裹密钥 + AES-GCM 信封存放在默认 secure storage，
/// 由 UI 层的 `local_auth` 做**便捷性**门控。
///
/// ⚠️ B 路径不提供硬件级保护：同机同用户进程可直接读出包裹密钥并解封。
/// 它的语义只是「防止随手翻看」，UI 必须如实标注（见 security_settings_page）。
class BiometricAuth {
  static const String _secureBiometricAuthKey = '_secureBiometricAuthKey';

  /// 桌面回退路径的包裹密钥（仅 B 路径使用；A 路径会主动清除它）
  static const String _secureBiometricWrapKey = '_secureBiometricWrapKey';

  /// 硬件绑定路径的存储命名空间：与默认 store 完全隔离，
  /// 否则同库其它 key（WebDAV 密码等）会被一并要求生物认证。
  static const String _storageNamespace = 'biometric_credential';

  /// 存储格式版本前缀（仅 B 路径）：`v1:<base64(nonce||ciphertext||tag)>`
  ///
  /// 旧版本写入的是直接明文密码（无前缀），读取时识别到无前缀按旧格式原样返回，
  /// 保证升级兼容；下次写入密码时自动升级为 v1。
  static const String _wrappedPrefix = 'v1:';

  /// 桌面回退路径 / 旧版遗留数据使用的默认存储
  static const storage = FlutterSecureStorage();

  /// 是否具备硬件级生物识别密钥门控。
  ///
  /// 仅 Android / iOS / macOS 为 true；Windows / Linux / Web 一律 false，
  /// 调用方据此决定是否需要 `local_auth` 兜底以及如何标注安全等级。
  static bool get isHardwareBound =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  /// 参数化认证提示语（随语言环境变化，故每次按需构建而非 static final 常量）
  static FlutterSecureStorage _boundStorage({String? promptTitle}) {
    return FlutterSecureStorage(
      // Android：KeyStore AES + 每次使用都要求认证
      aOptions: AndroidOptions.biometric(
        storageNamespace: _storageNamespace,
        enforceBiometrics: true,
        biometricType: AndroidBiometricType.biometricOrDeviceCredential,
        biometricPromptTitle: promptTitle,
      ),
      // iOS：条目绑定「当前录入的生物特征」，录入新指纹/面容后即失效
      iOptions: const IOSOptions(
        accessibility: KeychainAccessibility.unlocked_this_device,
        accessControlFlags: [AccessControlFlag.biometryCurrentSet],
      ),
      // macOS：同上，且强制走 Data Protection Keychain 才会真正生效
      mOptions: const MacOsOptions(
        accessibility: KeychainAccessibility.unlocked_this_device,
        accessControlFlags: [AccessControlFlag.biometryCurrentSet],
        usesDataProtectionKeychain: true,
      ),
    );
  }

  /// 读取凭据并解出 vault 密码（A 路径的读取会触发系统认证弹窗）
  ///
  /// UI 层必须用本方法而不是 `authKey`：只有它区分取消与真失败。
  static Future<BiometricUnlockResult> unlock({String? promptTitle}) async {
    try {
      final pass = isHardwareBound
          ? await _readBound(promptTitle: promptTitle)
          : await _readLegacy();
      if (pass.isEmpty) {
        // A 路径：条目不存在/已失效（换机、改过生物特征）；B 路径：凭据缺失或解包失败
        return const BiometricUnlockResult(BiometricUnlockStatus.notConfigured);
      }
      return BiometricUnlockResult(
        BiometricUnlockStatus.success,
        passphrase: pass,
      );
    } on PlatformException catch (e, st) {
      final cancelled = _isCancellation(e);
      Log.auth.i('生物识别读取未完成: ${cancelled ? '用户取消' : '平台异常 code=${e.code}'}');
      if (!cancelled) {
        Log.auth.w('生物识别读取失败', error: e, stackTrace: st);
      }
      return BiometricUnlockResult(
        cancelled
            ? BiometricUnlockStatus.cancelled
            : BiometricUnlockStatus.failed,
        error: e,
      );
    } on Object catch (e, st) {
      // iOS 侧取消以 SecurityError(-128) 形式抛出，不在 PlatformException 分支内
      final cancelled = _isCancellation(e);
      Log.auth.i('生物识别读取未完成: ${cancelled ? '用户取消' : '未知异常'}');
      if (!cancelled) {
        Log.auth.w('生物识别读取失败', error: e, stackTrace: st);
      }
      return BiometricUnlockResult(
        cancelled
            ? BiometricUnlockStatus.cancelled
            : BiometricUnlockStatus.failed,
        error: e,
      );
    }
  }

  /// 兼容旧调用的原始取值接口（失败/取消一律返回空串，不含原因）
  ///
  /// 注意：A 路径上本调用同样会触发系统认证。UI 层请改用 [unlock]。
  static Future<String> get authKey async => (await unlock()).passphrase;

  static Future<void> setAuthKey({String? promptTitle}) async {
    final pass = PhraseHandler.getPass;
    if (pass.isEmpty) {
      // 空密码写入会导致后续指纹登录必然失败，属于异常状态需要 warning
      Log.auth.w('写入生物识别凭据时会话密码为空, 指纹登录可能失效');
    }

    if (isHardwareBound) {
      // A 路径：写入即由 KeyStore/Keychain 用认证保护的密钥加密，
      // 写入动作本身会触发一次系统认证（等价于「启用前先验证一次」）。
      await _boundStorage(
        promptTitle: promptTitle,
      ).write(key: _secureBiometricAuthKey, value: pass);
      // 清掉旧版（10.x 及更早）写在默认 store 的包裹密钥与密文，
      // 否则升级后仍残留一份可被同机进程解封的副本。
      await storage.delete(key: _secureBiometricAuthKey);
      await storage.delete(key: _secureBiometricWrapKey);
      Log.auth.i('生物识别凭据已写入硬件绑定存储 (escaped=${pass.isEmpty})');
      return;
    }

    // B 路径：不直接存明文，用随机包裹密钥加密后存储
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
    // 两条路径都要清理：A 路径的 namespace 条目 + B 路径的密文与包裹密钥
    await _deleteBound();
    await storage.delete(key: _secureBiometricAuthKey);
    await storage.delete(key: _secureBiometricWrapKey);
    Log.auth.i('生物识别认证已关闭, 硬件条目与本地密文均已清除');
  }

  static Future<void> enable({String? promptTitle}) async {
    Log.auth.i('生物识别认证: 开始开启');
    if (PreferencesStorage.isPinAuthEnabled) {
      Log.auth.i('生物识别认证开启，自动关闭已启用的 PIN 锁定');
      await PinAuth.disable();
    }
    // 重新开启时清理旧条目（丢弃旧密钥，防止开关周期内密钥复用）
    await _deleteBound();
    await storage.delete(key: _secureBiometricWrapKey);
    // 先写凭据再打开开关：写入在硬件绑定路径上会触发系统认证，用户取消时
    // 抛异常，此时开关必须保持关闭，否则会出现"开着但登不进去"的僵尸状态。
    await setAuthKey(promptTitle: promptTitle);
    await PreferencesStorage.setIsBiometricAuthEnabled(true);
    Log.auth.i('生物识别认证已开启');
  }

  // ──────────────────────────────────────────────
  // 内部
  // ──────────────────────────────────────────────

  /// A 路径读取：Keychain/KeyStore 在解密前要求用户认证，
  /// 取消或失败会以异常抛出，绝不会返回可用的明文。
  static Future<String> _readBound({String? promptTitle}) async {
    final value = await _boundStorage(
      promptTitle: promptTitle,
    ).read(key: _secureBiometricAuthKey);
    if (value == null || value.isEmpty) return '';
    // 只记录长度，绝不记录凭据内容（隐私红线）
    Log.auth.d('读取生物识别凭据(硬件绑定): 长度=${value.length}');
    return value;
  }

  /// B 路径读取：先取密文再取包裹密钥，无任何认证约束（由 UI 层兜底）
  static Future<String> _readLegacy() async {
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

  /// 清理硬件绑定 namespace 中的全部条目（不存在时 deleteAll 也不报错）
  static Future<void> _deleteBound() async {
    // 桌面上 "bound" 实例与默认实例是同一份存储，deleteAll 会连 WebDAV 密码
    // 等无关 key 一起清掉，必须按平台短路。
    if (!isHardwareBound) return;
    try {
      await _boundStorage().deleteAll();
    } on Object catch (e, st) {
      // 凭据已失效（换机/改过生物特征）时清理可能抛错，不能阻断关闭流程
      Log.auth.w('清理硬件绑定凭据失败(可忽略)', error: e, stackTrace: st);
    }
  }

  /// 读取或首次生成桌面回退路径的包裹密钥（32B 随机）
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

  /// 判断异常是否为「用户主动取消」，取消不计入失败次数
  static bool _isCancellation(Object e) {
    final msg = e.toString().toLowerCase();
    return msg.contains('cancel') ||
        msg.contains('user_cancel') ||
        msg.contains('dismiss') ||
        msg.contains('negative button') ||
        msg.contains('errsecusercanceled') ||
        msg.contains('-128');
  }
}
