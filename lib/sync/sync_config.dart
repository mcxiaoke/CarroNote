/*
 * 同步配置管理
 *
 * 使用 SharedPreferences 持久化同步相关配置：
 *   - 后端类型（none / localFs / webdav / safeServer）
 *   - LocalFs 路径
 *   - WebDAV URL / 用户名
 *   - SafeServer URL
 *   - 自动同步开关
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
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Project imports:
import 'package:core/core.dart';

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

  /// 是否已配置同步
  static bool get isSyncEnabled => backendType != SyncBackendType.none;

  // ──────────────────────────────────────────────
  // LocalFs 配置
  // ──────────────────────────────────────────────

  /// LocalFs 根目录路径
  static String get localFsPath =>
      _prefs?.getString(_keyLocalFsPath) ?? '';

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
  static String get webdavUrl =>
      _prefs?.getString(_keyWebdavUrl) ?? '';

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
    } on Exception {
      _webdavPasswordCache = '';
    }
    try {
      _safeServerTokenCache =
          await _secureStorage.read(key: _keySafeServerToken) ?? '';
    } on Exception {
      _safeServerTokenCache = '';
    }
  }

  // ──────────────────────────────────────────────
  // SafeServer 配置
  // ──────────────────────────────────────────────

  /// SafeServer 服务端 URL（如 http://192.168.1.118:2025）
  static String get safeServerUrl =>
      _prefs?.getString(_keySafeServerUrl) ?? '';

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
  static bool get isAutoSyncEnabled =>
      _prefs?.getBool(_keyAutoSync) ?? true;

  static Future<void> setAutoSyncEnabled(bool enabled) async {
    await _prefs?.setBool(_keyAutoSync, enabled);
    Log.sync.i('自动同步开关: ${enabled ? "开启" : "关闭"}');
  }

  // ──────────────────────────────────────────────
  // 后端类型显示名称
  // ──────────────────────────────────────────────

  /// 获取后端类型的显示名称
  static String get backendDisplayName {
    switch (backendType) {
      case SyncBackendType.none:
        return '未配置';
      case SyncBackendType.localFs:
        return '本地文件夹';
      case SyncBackendType.webdav:
        return 'WebDAV';
      case SyncBackendType.safeServer:
        return 'SafeServer';
    }
  }
}
