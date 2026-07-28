/*
 * WebDAV 后端实现
 *
 * 用途：
 *   - 真实云盘同步：坚果云 / NextCloud / ownCloud / Synology WebDAV 等
 *   - 零服务端开发：用户用自己的云盘账号，无需部署服务器
 *
 * 存储布局（客户端自动附加 safenotes-vault 子目录，避免污染用户网盘根目录）：
 *   <userUrl>/safenotes-vault/        # e.g. https://dav.jianguoyun.com/dav/safenotes-vault
 *   ├── manifest.json                 # 单文件，If-Match ETag 乐观锁保护
 *   └── blobs/
 *       ├── <hash-1>
 *       └── <hash-2>
 *
 * 关键 WebDAV 特性：
 *   - If-Match（RFC 4918 §10.6）：PUT 时带 ETag 做乐观锁，不匹配返回 412
 *   - If-None-Match: *：首次上传时确保远端不存在目标文件
 *   - MKCOL：创建目录（已存在返回 405，幂等）
 *   - ETag：服务器返回的版本标识，每次 PUT 后会变化
 *
 * 兼容性：
 *   - 坚果云：✅ 完整支持 If-Match + ETag
 *   - NextCloud / ownCloud：✅ 完整支持
 *   - Apache mod_dav：✅ 完整支持
 *   - 如果服务器不返回 ETag，会退化为内容 hash 作为 etag（仍可用，但 If-Match 可能被服务器忽略）
 */

// Dart 原生导入
import 'dart:convert';
import 'dart:typed_data';

// Package 导入
import 'package:crypto/crypto.dart' show sha256;
import 'package:http/http.dart' as http;

// Project 导入
import 'package:safenotes/sync/crypto.dart';
import 'package:safenotes/sync/sync_backend.dart';

/// WebDAV vault 子目录名（固定常量）
///
/// 客户端会在用户输入的 baseUrl 后自动附加此子目录，
/// 避免把 manifest/blobs 散落到用户网盘根目录与其他文件混在一起。
/// 多设备共享时只要 baseUrl 一样，子目录路径自动一致。
const String kWebDavVaultSubdir = 'safenotes-vault';

/// WebDAV 后端
///
/// [baseUrl] 是用户输入的 WebDAV 服务端根路径，例如：
///   - 坚果云：https://dav.jianguoyun.com/dav/
///   - NextCloud：https://nc.example.com/remote.php/dav/files/user/
///
/// 客户端会自动附加 `/safenotes-vault` 子目录作为 vault 根路径，
/// 用户不需要手动指定子目录名，多设备共享时只要 baseUrl 一样即一致。
///
/// [username] / [password] 是 WebDAV 账号密码（坚果云需使用应用专用密码）
class WebDavBackend implements SyncBackend {
  /// WebDAV vault 根 URL（用户 baseUrl + 自动附加的 safenotes-vault 子目录，不带末尾斜杠）
  final String baseUrl;

  /// 用户输入的原始 baseUrl（用于 providerKey 计算）
  final String _userBaseUrl;

  /// WebDAV 用户名
  final String username;

  /// WebDAV 密码（坚果云为应用专用密码）
  final String password;

  /// HTTP 客户端（可注入便于测试）
  final http.Client _client;

  bool _initialized = false;

  WebDavBackend({
    required String baseUrl,
    required this.username,
    required this.password,
    http.Client? client,
  })  : _client = client ?? http.Client(),
        _userBaseUrl = baseUrl,
        // 规范化：去掉末尾斜杠，附加固定子目录
        baseUrl = _normalizeAndAppendVault(baseUrl);

  /// 规范化用户输入的 URL，附加固定 vault 子目录
  ///
  /// 例：
  ///   - 'https://dav.jianguoyun.com/dav/' → 'https://dav.jianguoyun.com/dav/safenotes-vault'
  ///   - 'https://dav.jianguoyun.com/dav'  → 'https://dav.jianguoyun.com/dav/safenotes-vault'
  ///   - 'http://192.168.1.118:2025/my-sync/' → 'http://192.168.1.118:2025/my-sync/safenotes-vault'
  static String _normalizeAndAppendVault(String url) {
    final trimmed = url.endsWith('/')
        ? url.substring(0, url.length - 1)
        : url;
    return '$trimmed/$kWebDavVaultSubdir';
  }

  @override
  String get displayName => 'WebDAV';

  /// providerKey：基于用户 baseUrl 哈希
  ///
  /// 用 _userBaseUrl（原始输入）而非 baseUrl（已附加子目录）计算，
  /// 因为子目录名是固定的，区分不同后端只需看用户输入的 URL。
  @override
  String get providerKey =>
      SyncCrypto.hashString('webdav:$_userBaseUrl').substring(0, 16);

  /// manifest 文件 URL
  String get _manifestUrl => '$baseUrl/manifest.json';

  /// blobs 目录 URL
  String get _blobsUrl => '$baseUrl/blobs';

  @override
  Future<void> init() async {
    // MKCOL 创建根目录和 blobs 子目录（幂等：已存在返回 405）
    await _mkcol(baseUrl);
    await _mkcol(_blobsUrl);
    _initialized = true;
  }

  void _ensureInitialized() {
    if (!_initialized) {
      throw BackendNotInitializedException();
    }
  }

  @override
  Future<({Uint8List ciphertext, String etag})> getManifest() async {
    _ensureInitialized();

    http.Response res;
    try {
      res = await _client.get(
        Uri.parse(_manifestUrl),
        headers: _authHeaders(),
      );
    } catch (e) {
      throw BackendUnavailableException('GET manifest network error: $e');
    }

    if (res.statusCode == 404) {
      // 首次同步：远端无 manifest
      return (ciphertext: Uint8List(0), etag: '');
    }
    if (res.statusCode != 200) {
      throw BackendUnavailableException(
          'GET manifest failed: ${res.statusCode} ${res.body}');
    }

    final etag = _normalizeEtag(res.headers['etag']);
    final ciphertext = res.bodyBytes;

    // 服务器未返回 ETag 时，退化为内容 hash 作为 etag
    // 注意：这种情况下 putManifest 的 If-Match 可能被服务器忽略，
    // 退化为"最后写入胜"。主流 WebDAV 服务都返回 ETag，此分支极少触发。
    final effectiveEtag =
        etag.isNotEmpty ? etag : _computeContentEtag(ciphertext);

    return (ciphertext: ciphertext, etag: effectiveEtag);
  }

  @override
  Future<String> putManifest(
    Uint8List ciphertext,
    String expectedEtag,
  ) async {
    _ensureInitialized();

    final headers = _authHeaders();
    headers['Content-Type'] = 'application/octet-stream';

    if (expectedEtag.isNotEmpty) {
      // 乐观锁：远端 ETag 必须匹配
      // 注意：把规范化后的 etag 用引号包回去（WebDAV If-Match 规范要求带引号）
      headers['If-Match'] = '"$expectedEtag"';
    } else {
      // 首次上传：确保远端不存在 manifest
      headers['If-None-Match'] = '*';
    }

    http.Response res;
    try {
      res = await _client.put(
        Uri.parse(_manifestUrl),
        headers: headers,
        body: ciphertext,
      );
    } on Exception catch (e) {
      throw BackendUnavailableException('PUT manifest network error: $e');
    }

    // 412 Precondition Failed = If-Match 不匹配
    // 409 Conflict = 某些 WebDAV 实现用于 If-None-Match 冲突
    if (res.statusCode == 412 || res.statusCode == 409) {
      throw ConflictException(
          'WebDAV If-Match failed: ${res.statusCode} (expected etag=$expectedEtag)');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw BackendUnavailableException(
          'PUT manifest failed: ${res.statusCode} ${res.body}');
    }

    // 服务器返回新 ETag 优先；否则用上传内容的 hash 作为 fallback
    final newEtag = _normalizeEtag(res.headers['etag']);
    return newEtag.isNotEmpty ? newEtag : _computeContentEtag(ciphertext);
  }

  @override
  Future<Uint8List?> getBlob(String hash) async {
    _ensureInitialized();

    http.Response res;
    try {
      res = await _client.get(
        Uri.parse('$_blobsUrl/$hash'),
        headers: _authHeaders(),
      );
    } on Exception catch (e) {
      throw BackendUnavailableException('GET blob network error: $e');
    }

    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw BackendUnavailableException(
          'GET blob failed: ${res.statusCode} for hash=$hash');
    }
    return res.bodyBytes;
  }

  @override
  Future<void> putBlob(String hash, Uint8List data) async {
    _ensureInitialized();

    final headers = _authHeaders();
    headers['Content-Type'] = 'application/octet-stream';

    http.Response res;
    try {
      res = await _client.put(
        Uri.parse('$_blobsUrl/$hash'),
        headers: headers,
        body: data,
      );
    } on Exception catch (e) {
      throw BackendUnavailableException('PUT blob network error: $e');
    }

    // WebDAV PUT 幂等：相同内容覆盖写
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw BackendUnavailableException(
          'PUT blob failed: ${res.statusCode} for hash=$hash');
    }
  }

  @override
  Future<void> close() async {
    _client.close();
    _initialized = false;
  }

  @override
  Future<bool> ping() async {
    // WebDAV 探测：PROPFIND 深度 0 查询根目录
    // 不依赖 _initialized 标志，允许未 init 时也能探测
    try {
      final req = http.Request('PROPFIND', Uri.parse(baseUrl));
      req.headers.addAll(_authHeaders());
      req.headers['Depth'] = '0';
      req.headers['Content-Type'] = 'application/xml; charset=utf-8';
      req.body = '<?xml version="1.0" encoding="utf-8"?>'
          '<propfind xmlns="DAV:"><prop><resourcetype/></prop></propfind>';

      final streamedRes = await _client.send(req);
      final res = await http.Response.fromStream(streamedRes);
      // 207 Multi-Status 是 PROPFIND 成功的标准响应
      // 200 某些非标准 WebDAV 服务也会返回
      return res.statusCode == 207 || res.statusCode == 200;
    } on Exception {
      return false;
    }
  }

  // ──────────────────────────────────────────────
  // 内部工具
  // ──────────────────────────────────────────────

  /// 构造 HTTP Basic Auth 头
  Map<String, String> _authHeaders() {
    final credentials = base64Encode(utf8.encode('$username:$password'));
    return {'Authorization': 'Basic $credentials'};
  }

  /// 规范化 ETag：去掉弱 ETag 前缀 W/ 和引号
  ///
  /// 输入示例：
  ///   - "abc123" → abc123
  ///   - W/"abc123" → abc123
  ///   - abc123 → abc123
  ///   - null / "" → ""
  String _normalizeEtag(String? etag) {
    if (etag == null || etag.isEmpty) return '';
    var result = etag.trim();
    if (result.startsWith('W/')) {
      result = result.substring(2);
    }
    // 去掉首尾引号（可能有也可能没有）
    if (result.startsWith('"') && result.endsWith('"') && result.length >= 2) {
      result = result.substring(1, result.length - 1);
    }
    return result;
  }

  /// 计算内容的 SHA-256 作为 fallback ETag
  ///
  /// 仅当服务器不返回 ETag 头时使用，保证乐观锁逻辑仍有 etag 可比。
  String _computeContentEtag(Uint8List bytes) {
    return sha256.convert(bytes).toString();
  }

  /// WebDAV MKCOL 创建目录（幂等）
  ///
  /// 状态码：
  ///   - 201 Created：目录创建成功
  ///   - 405 Method Not Allowed：目录已存在（正常情况，忽略）
  ///   - 401 Unauthorized：认证失败
  ///   - 其他：抛异常
  Future<void> _mkcol(String url) async {
    final req = http.Request('MKCOL', Uri.parse(url));
    req.headers.addAll(_authHeaders());

    http.Response res;
    try {
      final streamedRes = await _client.send(req);
      res = await http.Response.fromStream(streamedRes);
    } on Exception catch (e) {
      throw BackendUnavailableException('MKCOL network error: $e');
    }

    if (res.statusCode == 201 || res.statusCode == 405) {
      // 201 = 新建成功，405 = 已存在，都是正常状态
      return;
    }
    if (res.statusCode == 401) {
      throw BackendUnavailableException(
          'WebDAV auth failed (401): check username/password');
    }
    throw BackendUnavailableException(
        'MKCOL $url failed: ${res.statusCode} ${res.body}');
  }
}
