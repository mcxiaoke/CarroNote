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
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage(
    // Android: 使用 EncryptedSharedPreferences（默认）
    // iOS: 使用 Keychain（默认）
    // 桌面: 使用 DPAPI/libsecret（默认）
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

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
    await _migrateCredentialsToSecureStorage();
    await _preloadCredentials();
  }

  /// 重新加载
  static Future<void> reload() async {
    await _prefs?.reload();
  }

  /// 一次性迁移：把旧版存在 SharedPreferences 中的凭据迁移到 SecureStorage
  ///
  /// 迁移策略：
  ///   1. 检查 SecureStorage 中是否已有凭据（有则跳过）
  ///   2. 若没有，检查 SharedPreferences 中是否有旧值
  ///   3. 把旧值写入 SecureStorage，然后从 SharedPreferences 删除
  ///   4. 迁移失败不影响应用启动（凭据丢失时用户重新输入）
  static Future<void> _migrateCredentialsToSecureStorage() async {
    try {
      // WebDAV 密码迁移
      final oldWebdavPassword = _prefs?.getString(_keyWebdavPassword);
      if (oldWebdavPassword != null && oldWebdavPassword.isNotEmpty) {
        final existing = await _secureStorage.read(key: _keyWebdavPassword);
        if (existing == null) {
          await _secureStorage.write(
            key: _keyWebdavPassword,
            value: oldWebdavPassword,
          );
        }
        // 删除 SharedPreferences 中的旧值
        await _prefs?.remove(_keyWebdavPassword);
      }

      // SafeServer Token 迁移
      final oldToken = _prefs?.getString(_keySafeServerToken);
      if (oldToken != null && oldToken.isNotEmpty) {
        final existing = await _secureStorage.read(key: _keySafeServerToken);
        if (existing == null) {
          await _secureStorage.write(
            key: _keySafeServerToken,
            value: oldToken,
          );
        }
        await _prefs?.remove(_keySafeServerToken);
      }
    } on Exception {
      // 迁移失败不阻断启动，用户重新输入凭据即可
    }
  }

  // ──────────────────────────────────────────────
  // 后端类型
  // ──────────────────────────────────────────────

  /// 当前配置的后端类型
  static SyncBackendType get backendType {
    final index = _prefs?.getInt(_keyBackendType) ?? 0;
    return SyncBackendType.values[index];
  }

  static Future<void> setBackendType(SyncBackendType type) async {
    await _prefs?.setInt(_keyBackendType, type.index);
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
  }

  // ──────────────────────────────────────────────
  // WebDAV 配置
  // ──────────────────────────────────────────────

  /// WebDAV 服务端 URL（如 https://dav.jianguoyun.com/dav/）
  ///
  /// 客户端会自动附加 /safenotes-vault 子目录作为 vault 根路径。
  static String get webdavUrl =>
      _prefs?.getString(_keyWebdavUrl) ?? '';

  static Future<void> setWebdavUrl(String url) async {
    await _prefs?.setString(_keyWebdavUrl, url);
  }

  /// WebDAV 用户名
  static String get webdavUsername =>
      _prefs?.getString(_keyWebdavUsername) ?? '';

  static Future<void> setWebdavUsername(String username) async {
    await _prefs?.setString(_keyWebdavUsername, username);
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
  }

  /// SafeServer Bearer Token（部署时配置的固定 Token）
  ///
  /// H3 修复：改用 flutter_secure_storage 存储。
  static String _safeServerTokenCache = '';

  static String get safeServerToken => _safeServerTokenCache;

  static Future<void> setSafeServerToken(String token) async {
    await _secureStorage.write(key: _keySafeServerToken, value: token);
    _safeServerTokenCache = token;
  }

  // ──────────────────────────────────────────────
  // 自动同步
  // ──────────────────────────────────────────────

  /// 是否启用自动同步（笔记变更后自动触发）
  static bool get isAutoSyncEnabled =>
      _prefs?.getBool(_keyAutoSync) ?? true;

  static Future<void> setAutoSyncEnabled(bool enabled) async {
    await _prefs?.setBool(_keyAutoSync, enabled);
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
