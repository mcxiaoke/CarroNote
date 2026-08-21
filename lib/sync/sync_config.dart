/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

/*
 * 同步配置管理
 *
 * 使用 SharedPreferences 持久化同步相关配置：
 *   - 同步总开关（独立于后端配置，出错时可一键停用同步）
 *   - 后端类型（none / localFs / webdav / safeServer）
 *   - LocalFs 路径
 *   - WebDAV URL / 用户名
 *   - SafeServer URL
 *   - 自动同步开关
 *
 * 三个布尔量的语义必须区分清楚（[isSyncEnabled] / [hasBackendConfig] /
 * [isSyncReady]），详见各自的文档注释。
 *
 * 敏感凭据（H3 修复）改用 flutter_secure_storage：
 *   - WebDAV 密码
 *   - SafeServer Token
 * flutter_secure_storage 在 Android 用 EncryptedSharedPreferences（Keystore），
 * iOS 用 Keychain，桌面平台用 DPAPI/libsecret，避免明文存储。
 *
 * 独立于 PreferencesStorage，避免污染原有配置类。
 * 所有 getter/setter 均为静态方法，与 PreferencesStorage 风格一致。
 */

// Package 导入

import 'package:core/core.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 同步后端类型
enum SyncBackendType {
  /// 未配置同步
  none,

  /// 本地文件系统（测试/单设备用）
  localFs,

  /// WebDAV（坚果云/NextCloud/自建等）
  webdav,

  /// SafeServer（自建轻量同步服务，见 docs/server-api-spec.md）
  safeServer,
}

/// 同步配置
class SyncConfig {
  static SharedPreferences? _prefs;
  // flutter_secure_storage 10.x：Android 默认使用自定义加密（EncryptedSharedPreferences 已弃用），
  // iOS 用 Keychain，桌面用 DPAPI/libsecret。
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

  // SharedPreferences 键名（非敏感配置）
  static const _keySyncEnabled = 'sync_enabled';
  static const _keyBackendType = 'sync_backend_type';
  static const _keyLocalFsPath = 'sync_localfs_path';
  static const _keyWebdavUrl = 'sync_webdav_url';
  static const _keyWebdavUsername = 'sync_webdav_username';
  static const _keySafeServerUrl = 'sync_safeserver_url';
  static const _keyAutoSync = 'sync_auto_sync';

  // SecureStorage 键名（敏感凭据，H3 修复）
  static const _keyWebdavPassword = 'sync_webdav_password';
  static const _keySafeServerToken = 'sync_safeserver_token';

  /// 初始化（应用启动时调用）
  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    await _preloadCredentials();
  }

  /// 重新加载
  static Future<void> reload() async {
    await _prefs?.reload();
  }

  // ──────────────────────────────────────────────
  // 同步总开关
  // ──────────────────────────────────────────────

  /// 同步功能总开关（**独立于后端配置**）
  ///
  /// 语义：用户是否希望启用同步。关闭时无论后端配置多完整，
  /// 同步服务都不初始化、不执行任何同步——用于同步出错时快速止血，
  /// 且**不需要清空后端配置**，排查完打开开关即可恢复。
  ///
  /// 升级迁移：旧版本没有这个键，同步的开启与否完全由「后端类型是否为
  /// none」表达。因此键缺失时按 `backendType != none` 推断，保证已配置
  /// 同步的老用户升级后同步不会被静默关闭。
  static bool get isSyncEnabled {
    final stored = _prefs?.getBool(_keySyncEnabled);
    if (stored != null) return stored;
    return backendType != SyncBackendType.none;
  }

  /// [SyncConfig] 是否已经初始化（[init] 已被调用、_prefs 已就绪）
  ///
  /// 用于同步总开关的短路判断：只有在配置系统就绪后，"用户关闭同步"才
  /// 真正生效。未初始化（如同步引擎的纯逻辑测试、或启动早期的极小窗口）
  /// 时一律视为"未接管"，不拦截 sync/autoSync，保持向后兼容与历史行为。
  /// 生产环境 [init] 在 [main._bootstrap] 中早于任何同步调用，故不受影响。
  static bool get isInitialized => _prefs != null;

  static Future<void> setSyncEnabled(bool enabled) async {
    await _prefs?.setBool(_keySyncEnabled, enabled);
    Log.sync.i('同步总开关: ${enabled ? "开启" : "关闭"}');
  }

  /// 当前后端配置是否完整可用（能构造出后端实例）
  ///
  /// 只看配置字段是否齐全，不看总开关，也不代表远端可达。
  static bool get hasBackendConfig => SyncBackendDraft.fromConfig().isComplete;

  /// 同步是否可以真正工作：总开关已开 **且** 后端配置完整
  ///
  /// 所有「要不要初始化 / 要不要显示同步 UI」的判断都应该用这个，
  /// 而不是单独用 [isSyncEnabled]（那只是用户意愿）。
  static bool get isSyncReady => isSyncEnabled && hasBackendConfig;

  // ──────────────────────────────────────────────
  // 后端类型
  // ──────────────────────────────────────────────

  /// 当前配置的后端类型
  static SyncBackendType get backendType {
    final index = _prefs?.getInt(_keyBackendType) ?? 0;
    // 防御：prefs 值被外部篡改 / 旧版本写入非法索引时，越界会 RangeError 崩溃。
    // 超出合法范围一律按 none（关闭同步）处理，绝不抛异常。
    if (index < 0 || index >= SyncBackendType.values.length) {
      Log.sync.w('同步后端类型索引非法: $index，回退为 none');
      return SyncBackendType.none;
    }
    return SyncBackendType.values[index];
  }

  static Future<void> setBackendType(SyncBackendType type) async {
    final old = backendType;
    await _prefs?.setInt(_keyBackendType, type.index);
    // 同步后端类型变更是配置核心动作，info 级留痕
    Log.sync.i('同步后端类型变更: ${old.name} → ${type.name}');
  }

  // ──────────────────────────────────────────────
  // LocalFs 配置
  // ──────────────────────────────────────────────

  /// LocalFs 根目录路径
  static String get localFsPath => _prefs?.getString(_keyLocalFsPath) ?? '';

  static Future<void> setLocalFsPath(String path) async {
    await _prefs?.setString(_keyLocalFsPath, path);
    Log.sync.d('本地同步目录已设置: $path');
  }

  // ──────────────────────────────────────────────
  // WebDAV 配置
  // ──────────────────────────────────────────────

  /// WebDAV 服务端 URL（如 https://dav.jianguoyun.com/dav/）
  ///
  /// 客户端会自动附加 /safenotes-vault 子目录作为 keyring 根路径。
  static String get webdavUrl => _prefs?.getString(_keyWebdavUrl) ?? '';

  static Future<void> setWebdavUrl(String url) async {
    await _prefs?.setString(_keyWebdavUrl, url);
    Log.sync.d('WebDAV URL 已设置: $url');
  }

  /// WebDAV 用户名
  static String get webdavUsername =>
      _prefs?.getString(_keyWebdavUsername) ?? '';

  static Future<void> setWebdavUsername(String username) async {
    await _prefs?.setString(_keyWebdavUsername, username);
    Log.sync.d('WebDAV 用户名已设置: $username');
  }

  /// WebDAV 密码（应用专用密码，如坚果云的第三方密码）
  ///
  /// H3 修复：改用 flutter_secure_storage 存储，避免明文存于 SharedPreferences。
  /// 由于 SecureStorage 是异步的，这里提供同步 getter（返回缓存值）和异步 setter。
  /// 缓存值在 init() 时预加载到 _webdavPasswordCache。
  static String _webdavPasswordCache = '';

  static String get webdavPassword => _webdavPasswordCache;

  static Future<void> setWebdavPassword(String password) async {
    await _secureStorage.write(key: _keyWebdavPassword, value: password);
    _webdavPasswordCache = password;
    // 隐私红线：只记长度/状态，绝不记密码明文
    Log.sync.d('WebDAV 密码已更新 (len=${password.length})');
  }

  /// 应用启动时预加载凭据到缓存（init() 内部调用）
  static Future<void> _preloadCredentials() async {
    try {
      _webdavPasswordCache =
          await _secureStorage.read(key: _keyWebdavPassword) ?? '';
    } on Exception catch (e) {
      Log.sync.w('预加载 WebDAV 密码失败', error: e);
      _webdavPasswordCache = '';
    }
    try {
      _safeServerTokenCache =
          await _secureStorage.read(key: _keySafeServerToken) ?? '';
    } on Exception catch (e) {
      Log.sync.w('预加载 SafeServer Token 失败', error: e);
      _safeServerTokenCache = '';
    }
  }

  // ──────────────────────────────────────────────
  // SafeServer 配置
  // ──────────────────────────────────────────────

  /// SafeServer 服务端 URL（如 http://192.168.1.118:2025）
  static String get safeServerUrl => _prefs?.getString(_keySafeServerUrl) ?? '';

  static Future<void> setSafeServerUrl(String url) async {
    await _prefs?.setString(_keySafeServerUrl, url);
    Log.sync.d('SafeServer URL 已设置: $url');
  }

  /// SafeServer Bearer Token（部署时配置的固定 Token）
  ///
  /// H3 修复：改用 flutter_secure_storage 存储。
  static String _safeServerTokenCache = '';

  static String get safeServerToken => _safeServerTokenCache;

  static Future<void> setSafeServerToken(String token) async {
    await _secureStorage.write(key: _keySafeServerToken, value: token);
    _safeServerTokenCache = token;
    // 隐私红线：只记长度/状态，绝不记 Token 明文
    Log.sync.d('SafeServer Token 已更新 (len=${token.length})');
  }

  // ──────────────────────────────────────────────
  // 自动同步
  // ──────────────────────────────────────────────

  /// 是否启用自动同步（笔记变更后自动触发）
  static bool get isAutoSyncEnabled => _prefs?.getBool(_keyAutoSync) ?? true;

  static Future<void> setAutoSyncEnabled(bool enabled) async {
    await _prefs?.setBool(_keyAutoSync, enabled);
    Log.sync.i('自动同步开关: ${enabled ? "开启" : "关闭"}');
  }

  // ──────────────────────────────────────────────
  // 后端类型显示名称
  // ──────────────────────────────────────────────

  /// 获取后端类型的显示名称
  static String get backendDisplayName => displayNameOf(backendType);

  /// 后端类型的显示名称（静态版，供配置面板展示未保存的草稿类型）
  static String displayNameOf(SyncBackendType type) {
    switch (type) {
      case SyncBackendType.none:
        return 'Not configured'.tr();
      case SyncBackendType.localFs:
        return 'Local folder'.tr();
      case SyncBackendType.webdav:
        return 'WebDAV';
      case SyncBackendType.safeServer:
        return 'SafeServer';
    }
  }
}

/// 同步后端配置草稿（不可变值对象）
///
/// 用途：配置面板在「用户编辑 → 测试连接 → 保存」这条链路上需要一份
/// **尚未落盘**的配置。直接读写 [SyncConfig] 会让「测试没通过就已经改了
/// 生效配置」，破坏「测试通过才能保存」的约束。
///
/// 关键设计：草稿**同时持有全部后端类型的字段**。用户在面板里把类型从
/// WebDAV 切到 SafeServer 再切回来时，WebDAV 的地址/用户名/密码原样还在，
/// 不会被清空——这也是持久层的行为（每种类型各有独立的 key）。
class SyncBackendDraft {
  final SyncBackendType type;
  final String localFsPath;
  final String webdavUrl;
  final String webdavUsername;
  final String webdavPassword;
  final String safeServerUrl;
  final String safeServerToken;

  const SyncBackendDraft({
    required this.type,
    this.localFsPath = '',
    this.webdavUrl = '',
    this.webdavUsername = '',
    this.webdavPassword = '',
    this.safeServerUrl = '',
    this.safeServerToken = '',
  });

  /// 从当前持久化配置读取草稿
  factory SyncBackendDraft.fromConfig() => SyncBackendDraft(
    type: SyncConfig.backendType,
    localFsPath: SyncConfig.localFsPath,
    webdavUrl: SyncConfig.webdavUrl,
    webdavUsername: SyncConfig.webdavUsername,
    webdavPassword: SyncConfig.webdavPassword,
    safeServerUrl: SyncConfig.safeServerUrl,
    safeServerToken: SyncConfig.safeServerToken,
  );

  SyncBackendDraft copyWith({
    SyncBackendType? type,
    String? localFsPath,
    String? webdavUrl,
    String? webdavUsername,
    String? webdavPassword,
    String? safeServerUrl,
    String? safeServerToken,
  }) => SyncBackendDraft(
    type: type ?? this.type,
    localFsPath: localFsPath ?? this.localFsPath,
    webdavUrl: webdavUrl ?? this.webdavUrl,
    webdavUsername: webdavUsername ?? this.webdavUsername,
    webdavPassword: webdavPassword ?? this.webdavPassword,
    safeServerUrl: safeServerUrl ?? this.safeServerUrl,
    safeServerToken: safeServerToken ?? this.safeServerToken,
  );

  /// 归一化：URL / 用户名 / 路径去首尾空白（粘贴时极易带上换行或空格）。
  ///
  /// 密码与 Token **不去空白**——它们可能合法地包含首尾空格，
  /// 擅自裁剪会造成"看起来对但认证失败"的诡异问题。
  SyncBackendDraft normalized() => SyncBackendDraft(
    type: type,
    localFsPath: localFsPath.trim(),
    webdavUrl: webdavUrl.trim(),
    webdavUsername: webdavUsername.trim(),
    webdavPassword: webdavPassword,
    safeServerUrl: safeServerUrl.trim(),
    safeServerToken: safeServerToken,
  );

  /// 当前类型的必填字段是否齐全（能否构造出后端实例）
  ///
  /// 判定规则必须与 [buildBackend] 保持一致：isComplete 为 true 时
  /// buildBackend 必定返回非 null，反之返回 null。
  bool get isComplete => buildBackend() != null;

  /// 当前类型下、影响连通性的字段指纹
  ///
  /// 配置面板用它判断「测试通过后用户有没有又改了什么」：指纹变了就作废
  /// 上次测试结果，必须重测才能保存。只覆盖当前类型的字段——改另一种类型
  /// 的输入框不影响当前类型的测试结论。
  String get connectionSignature {
    final n = normalized();
    switch (type) {
      case SyncBackendType.none:
        return 'none';
      case SyncBackendType.localFs:
        return 'localFs|${n.localFsPath}';
      case SyncBackendType.webdav:
        return 'webdav|${n.webdavUrl}|${n.webdavUsername}|'
            '${n.webdavPassword.hashCode}';
      case SyncBackendType.safeServer:
        return 'safeServer|${n.safeServerUrl}|${n.safeServerToken.hashCode}';
    }
  }

  /// 按当前类型构造后端实例；字段不全返回 null
  ///
  /// 调用方负责 init() / close()。
  SyncBackend? buildBackend() {
    final n = normalized();
    switch (type) {
      case SyncBackendType.none:
        return null;
      case SyncBackendType.localFs:
        if (n.localFsPath.isEmpty) return null;
        return LocalFsBackend(rootPath: n.localFsPath);
      case SyncBackendType.webdav:
        if (n.webdavUrl.isEmpty || n.webdavUsername.isEmpty) return null;
        return WebDavBackend(
          baseUrl: n.webdavUrl,
          username: n.webdavUsername,
          password: n.webdavPassword,
        );
      case SyncBackendType.safeServer:
        if (n.safeServerUrl.isEmpty || n.safeServerToken.isEmpty) return null;
        return SafeServerBackend(
          baseUrl: n.safeServerUrl,
          token: n.safeServerToken,
        );
    }
  }

  /// 落盘到 [SyncConfig]
  ///
  /// 全部类型的字段都写回，保证「切到别的类型再切回来」时旧配置还在。
  Future<void> save() async {
    final n = normalized();
    await SyncConfig.setLocalFsPath(n.localFsPath);
    await SyncConfig.setWebdavUrl(n.webdavUrl);
    await SyncConfig.setWebdavUsername(n.webdavUsername);
    await SyncConfig.setWebdavPassword(n.webdavPassword);
    await SyncConfig.setSafeServerUrl(n.safeServerUrl);
    await SyncConfig.setSafeServerToken(n.safeServerToken);
    // 类型最后写：前面任一步失败时不会留下「类型已切换但字段还是旧的」
    await SyncConfig.setBackendType(n.type);
  }
}
