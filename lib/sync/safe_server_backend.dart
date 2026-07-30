/*
 * SafeServer 后端实现
 *
 * 用途：
 *   - 自建轻量同步服务：用户自己部署 server/go 或 server/nodejs/server.js
 *   - 比 WebDAV 更简单：纯 HTTP API，无目录概念，无 MKCOL，Bearer Token 认证
 *   - 单用户场景：一个 server 实例服务一个 vault，无需账号系统
 *
 * 协议规范：docs/server-api-spec.md v2.1
 *
 * API 端点：
 *   GET    /api/v2/manifest           下载 manifest（带 ETag）
 *   PUT    /api/v2/manifest           上传 manifest（带 If-Match/If-None-Match 乐观锁）
 *   DELETE /api/v2/manifest           清理损坏 manifest（backupCorruptManifest 用）
 *   GET    /api/v2/blob/<hash>        下载 blob
 *   PUT    /api/v2/blob/<hash>        上传 blob（幂等）
 *   DELETE /api/v2/blob/<hash>        删除 blob（GC 用，幂等）
 *   GET    /api/v2/blobs              列出所有 blob hash（GC 用，需认证）
 *   GET    /api/v2/health             健康检查（无需认证）
 *
 * 与 WebDavBackend 的差异：
 *   - 无 MKCOL（服务端自动创建存储空间）
 *   - 无 vault-root 路径前缀（单用户，整个 server 即一个 vault）
 *   - Bearer Token 而非 Basic Auth
 *   - 路径前缀 /api/v2/ 为未来版本预留扩展空间
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

/// SafeServer v2 API 路径前缀
const String kSafeServerApiPrefix = '/api/v2';

/// SafeServer 后端
///
/// [baseUrl] 是用户部署的 SafeServer 服务端 URL，例如：
///   - 本机：http://192.168.1.118:2025
///   - 自建：https://safe.example.com
///
/// [token] 是部署时配置的固定 Bearer Token，所有请求共用。
///
/// 与 WebDavBackend 不同，客户端不在 URL 后附加子目录——
/// 因为单用户场景下整个 server 实例就服务一个 vault。
class SafeServerBackend implements SyncBackend {
  /// SafeServer 服务端 URL（不带末尾斜杠）
  final String baseUrl;

  /// 固定 Bearer Token
  final String token;

  /// HTTP 客户端（可注入便于测试）
  final http.Client _client;

  bool _initialized = false;

  SafeServerBackend({
    required String baseUrl,
    required this.token,
    http.Client? client,
  })  : _client = client ?? http.Client(),
        // 去掉末尾斜杠，保证 URL 拼接一致
        baseUrl = baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl;

  @override
  String get displayName => 'SafeServer';

  /// providerKey：基于 baseUrl 哈希
  @override
  String get providerKey =>
      SyncCrypto.hashString('safeServer:$baseUrl').substring(0, 16);

  /// manifest 端点 URL
  String get _manifestUrl => '$baseUrl$kSafeServerApiPrefix/manifest';

  /// blob 端点 URL 前缀
  String get _blobUrlPrefix => '$baseUrl$kSafeServerApiPrefix/blob';

  /// blobs 列表端点 URL（GC 用）
  String get _blobsUrl => '$baseUrl$kSafeServerApiPrefix/blobs';

  /// health 端点 URL
  String get _healthUrl => '$baseUrl$kSafeServerApiPrefix/health';

  @override
  Future<void> init() async {
    // 健康检查：确认服务端可达
    // 注意：health 端点不需要认证
    http.Response res;
    try {
      res = await _client.get(Uri.parse(_healthUrl));
    } on Exception catch (e) {
      throw BackendUnavailableException('SafeServer health check failed: $e');
    }

    if (res.statusCode != 200 || res.body != 'ok') {
      throw BackendUnavailableException(
        'SafeServer health check failed: ${res.statusCode} ${res.body}',
      );
    }

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
    } on Exception catch (e) {
      throw BackendUnavailableException('GET manifest network error: $e');
    }

    if (res.statusCode == 404) {
      // 首次同步：远端无 manifest
      return (ciphertext: Uint8List(0), etag: '');
    }
    if (res.statusCode == 401) {
      throw BackendUnavailableException(
          'SafeServer auth failed (401): check token');
    }
    if (res.statusCode != 200) {
      throw BackendUnavailableException(
          'GET manifest failed: ${res.statusCode} ${res.body}');
    }

    final etag = _normalizeEtag(res.headers['etag']);
    final ciphertext = res.bodyBytes;

    // 服务端必须返回 ETag（规范要求），但容错：未返回时用内容 hash 作为 fallback
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
      // 乐观锁：远端 ETag 必须匹配（带引号，符合 HTTP 规范）
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

    // 412 Precondition Failed = 乐观锁冲突
    if (res.statusCode == 412) {
      throw ConflictException(
          'SafeServer If-Match failed: ${res.statusCode} (expected etag=$expectedEtag)');
    }
    if (res.statusCode == 401) {
      throw BackendUnavailableException(
          'SafeServer auth failed (401): check token');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw BackendUnavailableException(
          'PUT manifest failed: ${res.statusCode} ${res.body}');
    }

    // 服务端返回新 ETag 优先；否则用上传内容的 hash 作为 fallback
    final newEtag = _normalizeEtag(res.headers['etag']);
    return newEtag.isNotEmpty ? newEtag : _computeContentEtag(ciphertext);
  }

  @override
  Future<Uint8List?> getBlob(String hash) async {
    _ensureInitialized();

    http.Response res;
    try {
      res = await _client.get(
        Uri.parse('$_blobUrlPrefix/$hash'),
        headers: _authHeaders(),
      );
    } on Exception catch (e) {
      throw BackendUnavailableException('GET blob network error: $e');
    }

    if (res.statusCode == 404) return null;
    if (res.statusCode == 401) {
      throw BackendUnavailableException(
          'SafeServer auth failed (401): check token');
    }
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
        Uri.parse('$_blobUrlPrefix/$hash'),
        headers: headers,
        body: data,
      );
    } on Exception catch (e) {
      throw BackendUnavailableException('PUT blob network error: $e');
    }

    // 幂等：相同内容覆盖写
    if (res.statusCode == 401) {
      throw BackendUnavailableException(
          'SafeServer auth failed (401): check token');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw BackendUnavailableException(
          'PUT blob failed: ${res.statusCode} for hash=$hash');
    }
  }

  /// 删除 blob（GC 用，幂等）
  ///
  /// SafeServer v2.1 协议定义了 DELETE /api/v2/blob/`<hash>` 端点。
  /// 客户端在 GC 流程中调用此端点清理孤儿 blob。
  ///
  /// 兼容性：若服务端为旧版 v2（未实现 DELETE 端点），返回 405 Method Not Allowed
  /// 时静默跳过，不抛异常——GC 退化为"只标记不清理"。
  @override
  Future<void> deleteBlob(String hash) async {
    _ensureInitialized();

    http.Response res;
    try {
      res = await _client.delete(
        Uri.parse('$_blobUrlPrefix/$hash'),
        headers: _authHeaders(),
      );
    } on Exception {
      // 网络错误：静默跳过，GC 不阻断同步
      return;
    }

    // 204 No Content = 删除成功
    // 405 Method Not Allowed = 旧版服务端未实现 DELETE（兼容 v2）
    // 404 Not Found = blob 不存在（幂等删除，视为成功）
    // 401 = 认证失败（仍抛异常，提示用户检查 token）
    if (res.statusCode == 204 ||
        res.statusCode == 405 ||
        res.statusCode == 404) {
      return;
    }
    if (res.statusCode == 401) {
      throw BackendUnavailableException(
          'SafeServer auth failed (401): check token');
    }
    // 其他非 2xx 状态：静默跳过（保守不抛，GC 失败不阻断同步）
  }

  /// 备份损坏的 manifest（清理损坏文件）
  ///
  /// SafeServer v2.1 协议定义了 DELETE /api/v2/manifest 端点。
  /// 客户端在 manifest 解析失败时调用此端点清理损坏文件，
  /// 然后用本地数据重建 manifest 上传。
  ///
  /// 兼容性：旧版 v2 服务端返回 405 时也视为成功（PUT 会覆盖旧文件）。
  @override
  Future<void> backupCorruptManifest(Uint8List ciphertext) async {
    _ensureInitialized();
    try {
      final res = await _client.delete(
        Uri.parse(_manifestUrl),
        headers: _authHeaders(),
      );
      // 204 = 删除成功，404 = 不存在（已删除），405 = 旧版不支持，都视为成功
      if (res.statusCode != 204 &&
          res.statusCode != 200 &&
          res.statusCode != 404 &&
          res.statusCode != 405) {
        // 删除失败：不抛异常，让 SyncEngine 的 PUT 覆盖
      }
    } on Exception {
      // 网络错误：不抛异常，让 SyncEngine 的 PUT 覆盖
    }
  }

  /// 列出所有 blob hash（GC 用）
  ///
  /// SafeServer v2.1 协议定义了 GET /api/v2/blobs 端点，返回 JSON 数组
  /// 包含所有 blob 的 hash。客户端用此列表与 manifest 引用对比，识别孤儿 blob。
  ///
  /// 兼容性：旧版 v2 服务端未实现此端点，返回 404/405 时退化为空列表，
  /// GC 退化为"只标记不清理"。
  @override
  Future<List<String>> listBlobs() async {
    _ensureInitialized();

    http.Response res;
    try {
      res = await _client.get(
        Uri.parse(_blobsUrl),
        headers: _authHeaders(),
      );
    } on Exception {
      // 网络错误：返回空列表，GC 不阻断同步
      return [];
    }

    // 404/405 = 旧版服务端未实现 list 端点，退化为空列表
    if (res.statusCode == 404 || res.statusCode == 405) return [];
    if (res.statusCode == 401) {
      throw BackendUnavailableException(
          'SafeServer auth failed (401): check token');
    }
    if (res.statusCode != 200) {
      // 其他错误：返回空列表，GC 不阻断同步
      return [];
    }

    try {
      final List<dynamic> hashes = jsonDecode(res.body);
      return hashes.cast<String>();
    } on FormatException {
      // JSON 解析失败：返回空列表，保守不抛
      return [];
    }
  }

  @override
  Future<void> close() async {
    _client.close();
    _initialized = false;
  }

  @override
  Future<bool> ping() async {
    // SafeServer 探测：GET /api/v2/health（无认证，1 次 HTTP 请求）
    // 不依赖 _initialized 标志，允许未 init 时也能探测
    try {
      final res = await _client.get(Uri.parse(_healthUrl));
      return res.statusCode == 200 && res.body == 'ok';
    } on Exception {
      return false;
    }
  }

  // ──────────────────────────────────────────────
  // 内部工具
  // ──────────────────────────────────────────────

  /// 构造 Bearer Token 认证头
  Map<String, String> _authHeaders() {
    return {'Authorization': 'Bearer $token'};
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
    if (result.startsWith('"') && result.endsWith('"') && result.length >= 2) {
      result = result.substring(1, result.length - 1);
    }
    return result;
  }

  /// 计算内容的 SHA-256 作为 fallback ETag
  ///
  /// 仅当服务端不返回 ETag 头时使用。规范要求服务端必须返回 ETag，
  /// 但容错处理让协议更健壮。
  String _computeContentEtag(Uint8List bytes) {
    return sha256.convert(bytes).toString();
  }
}
