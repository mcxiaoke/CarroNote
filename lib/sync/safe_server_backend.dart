/*
 * SafeServer 后端实现
 *
 * 用途：
 *   - 自建轻量同步服务：用户自己部署 server/go 或 server/nodejs/server.js
 *   - 比 WebDAV 更简单：纯 HTTP API，无目录概念，无 MKCOL，Bearer Token 认证
 *   - 单用户场景：一个 server 实例服务一个 vault，无需账号系统
 *
 * 协议规范：docs/server-api-spec.md v2.2
 *
 * API 端点：
 *   GET    /api/v2/manifest           下载 manifest（带 ETag）
 *   PUT    /api/v2/manifest           上传 manifest（带 If-Match/If-None-Match 乐观锁）
 *   DELETE /api/v2/manifest           清理损坏 manifest（backupCorruptManifest 用）
 *   GET    /api/v2/blob/<hash>        下载 blob
 *   PUT    /api/v2/blob/<hash>        上传 blob（幂等）
 *   DELETE /api/v2/blob/<hash>        删除 blob（GC 用，幂等）
 *   GET    /api/v2/blobs              列出所有 blob hash（GC 用，需认证）
 *   POST   /api/v2/resources/<path>   扩展操作 move/mkdir/copy/propfind/stats（v2.2 孤儿隔离 & manifest 备份）
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
import 'dart:io';
import 'dart:typed_data';

// Package 导入
import 'package:crypto/crypto.dart' show sha256;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

// Project 导入
import 'package:safenotes/sync/crypto.dart';
import 'package:safenotes/sync/sync_backend.dart';
import 'package:safenotes/utils/app_logger.dart';

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

  /// v2.2 资源层能力探测（懒执行，缓存）
  ///
  /// null = 未探测；true = 服务端支持 `/api/v2/resources/<path>`（v2.2）；
  /// false = 旧版 v2.1/v2，孤儿隔离与 manifest 备份走降级路径。
  bool? _resourcesSupported;

  /// 资源层能力是否已探测过（避免每次同步重复探测）
  bool _resourcesProbed = false;

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
    } on Exception catch (e) {
      // 网络错误：静默跳过，GC 不阻断同步
      Log.sync.w('[SafeServer] deleteBlob 网络错误，GC 跳过 '
          'hash=${hash.substring(0, 8)}…', error: e);
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

  /// 备份损坏的 manifest（v2.2 资源层 move 到 `.corrupt-<ts>`）
  ///
  /// v2.2 资源层提供 `move` 操作，等价于 localFs 的 rename / webdav 的 COPY+DELETE：
  /// 把损坏的 `manifest` 移动到 vault 根的 `.corrupt-<ts>`，让其脱离 manifest 端点，
  /// 随后 SyncEngine 用本地数据重建 manifest 上传（PUT If-None-Match:* 成功）。
  ///
  /// 降级：旧版服务端未实现资源层时，退化为 DELETE /api/v2/manifest（旧行为）。
  @override
  Future<void> backupCorruptManifest(Uint8List ciphertext) async {
    _ensureInitialized();
    await _ensureResourcesProbed();
    if (_resourcesSupported == true) {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final res = await _postResource(
        'manifest',
        'move',
        dest: '.corrupt-$ts',
        overwrite: false,
      );
      if (res.statusCode == 204 || res.statusCode == 404) {
        return; // 已移走（manifest 端点失效）或本就不存在
      }
      // 其他状态：退化为 DELETE 兜底
    }
    try {
      await _client.delete(
        Uri.parse(_manifestUrl),
        headers: _authHeaders(),
      );
    } on Exception catch (e) {
      // 删除失败不抛异常，让 SyncEngine 的 PUT 覆盖
      Log.sync.w('[SafeServer] backupCorruptManifest: 删除失败，退化为 PUT 覆盖',
          error: e);
    }
  }

  /// 列出所有 blob hash（GC 用）
  ///
  /// SafeServer v2.1 协议定义了 GET /api/v2/blobs 端点，返回 JSON 数组
  /// 包含所有 blob 的 hash。客户端用此列表与 manifest 引用对比，识别孤儿 blob。
  ///
  /// 兼容性：旧版 v2 服务端未实现此端点，返回 404/405 时退化为空列表，
  /// GC 退化为"只标记不清理"。
  /// 列出所有 blob hash（含隔离区项，不过滤）
  ///
  /// [listBlobs] 在它之上排除隔离区前缀；[listOrphanBlobs] 在它之上筛选隔离区项。
  Future<List<String>> _listAllBlobs() async {
    _ensureInitialized();

    http.Response res;
    try {
      res = await _client.get(
        Uri.parse(_blobsUrl),
        headers: _authHeaders(),
      );
    } on Exception catch (e) {
      // 网络错误：返回空列表，GC 不阻断同步
      Log.sync.w('[SafeServer] _listAllBlobs 网络错误，GC 退化为只标记', error: e);
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
      return hashes.whereType<String>().toList();
    } on FormatException {
      // JSON 解析失败：返回空列表，保守不抛
      return [];
    }
  }

  @override
  Future<List<String>> listBlobs() async {
    // P1-2：排除隔离区 blob（0rphan- 前缀），避免被 GC 再次误判为孤儿
    return (await _listAllBlobs()).where((h) => !h.startsWith('0rphan-')).toList();
  }

  /// P1-2 修复：软删除 blob（移动到 `blobs-orphan/` 隔离区）
  ///
  /// v2.2 资源层提供 `move` 操作，等价于 localFs 的 rename / webdav 的 COPY+DELETE：
  /// 先把原 blob `move` 到 `blobs-orphan/<hash>.<epochMs>`，保留一段时间可恢复，
  /// 避免立即物理删除的不可逆损失。这是与另两个后端一致的孤儿隔离语义。
  ///
  /// 降级路径：旧版 v2.1/v2 服务端未实现资源层（探测返回 404），退化为
  /// GET+PUT（`0rphan-` 前缀副本）+DELETE 的伪隔离方案（保留旧行为）。
  @override
  Future<void> deleteBlobSoft(String hash) async {
    _ensureInitialized();
    await _ensureResourcesProbed();
    if (_resourcesSupported == true) {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final dest = 'blobs-orphan/$hash.$ts';
      // 确保隔离区目录存在（201 已建 / 405 已存在，均忽略）
      await _postResource('blobs-orphan', 'mkdir');
      final res = await _postResource(
        'blobs/$hash',
        'move',
        dest: dest,
        overwrite: false,
      );
      if (res.statusCode == 204) return; // 已移入隔离区
      if (res.statusCode == 404) return; // 原 blob 已不存在，幂等
      if (res.statusCode == 409) {
        // 隔离区已存在同名项：直接删除原 blob 即可
        try {
          await deleteBlob(hash);
        } on Exception catch (e) {
          Log.sync.w('[SafeServer] deleteBlobSoft: 409 后删除原 blob 失败 '
              'hash=${hash.substring(0, 8)}…', error: e);
        }
        return;
      }
      // 其他状态：退化到降级路径兜底
    }
    await _deleteBlobSoftLegacy(hash);
  }

  /// P1-2 修复：列出隔离区孤儿 blob 的 hash
  ///
  /// v2.2：对 `blobs-orphan/` 做 propfind（depth=1），解析 `hash.<epochMs>` 返回 hash。
  /// 降级：旧版服务端读全量 blob，筛选 `0rphan-` 前缀项。
  @override
  Future<List<String>> listOrphanBlobs() async {
    await _ensureResourcesProbed();
    if (_resourcesSupported == true) {
      final res = await _postResource('blobs-orphan', 'propfind', depth: 1);
      if (res.statusCode == 200) {
        try {
          final List<dynamic> entries = jsonDecode(res.body);
          final result = <String>[];
          for (final e in entries) {
            final name = (e is Map ? e['name'] : null)?.toString() ?? '';
            final dot = name.indexOf('.');
            if (dot > 0) result.add(name.substring(0, dot));
          }
          return result;
        } on FormatException {
          // 解析失败：退化为降级路径
        }
      }
    }
    // 降级路径：筛选全量 blob 中的 `0rphan-` 项
    final all = await _listAllBlobs();
    final result = <String>[];
    for (final name in all) {
      if (!name.startsWith('0rphan-')) continue;
      final stripped = name.substring('0rphan-'.length);
      final dot = stripped.indexOf('.');
      result.add(dot > 0 ? stripped.substring(0, dot) : stripped);
    }
    return result;
  }

  /// P1-2 修复：清理隔离区中超过保留期的 blob
  ///
  /// v2.2：对 `blobs-orphan/` 做 propfind（depth=1），解析 `hash.<epochMs>`，
  /// 早于 now-retention 的通过 `DELETE /api/v2/resources/blobs-orphan/<name>` 彻底删除。
  /// 降级：旧版服务端筛全量 blob 的 `0rphan-` 项，DELETE 清理。
  @override
  Future<void> purgeOrphans(Duration retention) async {
    await _ensureResourcesProbed();
    if (_resourcesSupported == true) {
      final res = await _postResource('blobs-orphan', 'propfind', depth: 1);
      if (res.statusCode == 200) {
        final cutoff =
            DateTime.now().subtract(retention).millisecondsSinceEpoch;
        try {
          final List<dynamic> entries = jsonDecode(res.body);
          for (final e in entries) {
            final name = (e is Map ? e['name'] : null)?.toString() ?? '';
            final dot = name.indexOf('.');
            if (dot > 0 && name.substring(0, dot).length == 64) {
              final ts = int.tryParse(name.substring(dot + 1));
              if (ts != null && ts < cutoff) {
                try {
                  await _deleteResource('blobs-orphan/$name');
                } on Exception catch (e) {
                  // 单个删除失败不阻断
                  Log.sync.w('[SafeServer] purgeOrphans: 单个孤儿删除失败 '
                      'name=$name', error: e);
                }
              }
            }
          }
          return;
        } on FormatException {
          // 解析失败：退化为降级路径
        }
      }
    }
    // 降级路径：筛选全量 blob 的 `0rphan-` 项
    final all = await _listAllBlobs();
    final cutoff = DateTime.now().subtract(retention).millisecondsSinceEpoch;
    for (final name in all) {
      if (!name.startsWith('0rphan-')) continue;
      final stripped = name.substring('0rphan-'.length);
      final dot = stripped.indexOf('.');
      if (dot > 0) {
        final ts = int.tryParse(stripped.substring(dot + 1));
        if (ts != null && ts < cutoff) {
          try {
            await _client.delete(
              Uri.parse('$_blobUrlPrefix/$name'),
              headers: _authHeaders(),
            );
          } on Exception catch (e) {
            // 单个删除失败不阻断
            Log.sync.w('[SafeServer] purgeOrphans(降级): 单个删除失败 '
                'name=$name', error: e);
          }
        }
      }
    }
  }

  /// P1-1 修复：manifest 代际备份（落地到服务端 `manifest-backup/` 子目录，环形 N 份）
  ///
  /// v2.2：用资源层在 vault 内 `manifest-backup/` 子目录维护环形备份
  /// `manifest.bak-0`..`manifest.bak-{N-1}`（轮转位置记在 `.manifest-bak-index`），
  /// 与 localFs / webdav 后端布局一致。远端 manifest 损坏/被清空时，可从服务端
  /// 最近一代备份恢复。
  ///
  /// 降级：旧版服务端未实现资源层时，退化为客户端本地临时目录环形备份（旧行为）。
  @override
  Future<void> backupManifest([Uint8List? currentManifestBytes]) async {
    if (currentManifestBytes == null || currentManifestBytes.isEmpty) return;
    await _ensureResourcesProbed();
    if (_resourcesSupported == true) {
      try {
        await _backupManifestOnServer(currentManifestBytes);
        return;
      } on Exception catch (e) {
        // 服务端备份失败：退化为本地临时目录兜底
        Log.sync.w('[SafeServer] 服务端 manifest 备份失败，退化为本地临时目录',
            error: e);
      }
    }
    try {
      final dir = Directory(p.join(
        Directory.systemTemp.path,
        'safenotes-manifest-backup',
        providerKey,
      ));
      await writeRingBackup(dir, currentManifestBytes);
    } on Exception catch (e) {
      // 备份失败不阻断同步
      Log.sync.w('[SafeServer] 本地 manifest 备份失败', error: e);
    }
  }

  /// P1-1（v2.2 资源层实现）：把 manifest 密文环形写入服务端 `manifest-backup/`
  Future<void> _backupManifestOnServer(Uint8List bytes) async {
    const rel = 'manifest-backup';
    await _postResource(rel, 'mkdir'); // 201 已建 / 405 已存在，均忽略
    var slot = 0;
    try {
      final idx = await _getResource('$rel/.manifest-bak-index');
      if (idx.statusCode == 200) {
        slot = int.tryParse(utf8.decode(idx.bodyBytes).trim()) ?? 0;
      }
    } on Exception catch (e) {
      Log.sync.d('[SafeServer] _backupManifestOnServer: 读取备份索引失败，slot=0',
          error: e);
      slot = 0;
    }
    slot = (slot + 1) % kManifestBackupRingCount;
    await _putResource(
      '$rel/.manifest-bak-index',
      utf8.encode(slot.toString()),
    );
    await _putResource('$rel/manifest.bak-$slot', bytes);
  }

  /// v2.2 资源层能力探测（懒执行，仅一次）
  ///
  /// 通过 `MKCOL blobs-orphan` 探测资源层是否实现：
  /// - 201/405 → 服务端支持资源层（v2.2）
  /// - 404/其他 → 旧版 v2.1/v2，标记不支持，后续走降级路径
  Future<void> _ensureResourcesProbed() async {
    if (_resourcesProbed) return;
    _resourcesProbed = true;
    try {
      final res = await _postResource('blobs-orphan', 'mkdir');
      _resourcesSupported = (res.statusCode == 201 || res.statusCode == 405);
    } on Exception catch (e) {
      Log.sync.d('[SafeServer] 资源层探测失败，标记为不支持', error: e);
      _resourcesSupported = false;
    }
  }

  /// POST `/api/v2/resources/<rel>` 扩展操作（move / mkdir / copy / propfind / stats）
  Future<http.Response> _postResource(
    String rel,
    String op, {
    String? dest,
    bool overwrite = false,
    int depth = 1,
  }) async {
    final uri = Uri.parse('$baseUrl$kSafeServerApiPrefix/resources/$rel');
    final req = http.Request('POST', uri);
    req.headers.addAll(_authHeaders());
    req.headers['Content-Type'] = 'application/json';
    final body = <String, Object>{
      'op': op,
      'overwrite': overwrite,
    };
    if (dest != null) body['dest'] = dest;
    if (op == 'propfind' || op == 'stats') body['depth'] = depth;
    req.body = jsonEncode(body);
    final streamed = await _client.send(req);
    return http.Response.fromStream(streamed);
  }

  /// GET `/api/v2/resources/<rel>`
  Future<http.Response> _getResource(String rel) async {
    final uri = Uri.parse('$baseUrl$kSafeServerApiPrefix/resources/$rel');
    return _client.get(uri, headers: _authHeaders());
  }

  /// PUT `/api/v2/resources/<rel>`
  Future<http.Response> _putResource(String rel, List<int> bytes) async {
    final uri = Uri.parse('$baseUrl$kSafeServerApiPrefix/resources/$rel');
    final req = http.Request('PUT', uri);
    req.headers.addAll(_authHeaders());
    req.headers['Content-Type'] = 'application/octet-stream';
    req.bodyBytes = bytes;
    final streamed = await _client.send(req);
    return http.Response.fromStream(streamed);
  }

  /// DELETE `/api/v2/resources/<rel>`
  Future<http.Response> _deleteResource(String rel) async {
    final uri = Uri.parse('$baseUrl$kSafeServerApiPrefix/resources/$rel');
    return _client.delete(uri, headers: _authHeaders());
  }

  /// P1-2 修复（降级路径）：旧版服务端伪隔离（GET+PUT+DELETE，0rphan- 前缀）
  Future<void> _deleteBlobSoftLegacy(String hash) async {
    Uint8List? bytes;
    try {
      final res = await _client.get(
        Uri.parse('$_blobUrlPrefix/$hash'),
        headers: _authHeaders(),
      );
      if (res.statusCode == 200) bytes = res.bodyBytes;
    } on Exception catch (e) {
      Log.sync.d('[SafeServer] _deleteBlobSoftLegacy: GET 原 blob 失败 '
          'hash=${hash.substring(0, 8)}…', error: e);
      bytes = null;
    }
    if (bytes == null) return; // 原 blob 已不存在，幂等
    final ts = DateTime.now().millisecondsSinceEpoch;
    final orphanName = '0rphan-$hash.$ts';
    try {
      final putRes = await _client.put(
        Uri.parse('$_blobUrlPrefix/$orphanName'),
        headers: {
          ..._authHeaders(),
          'Content-Type': 'application/octet-stream',
        },
        body: bytes,
      );
      if (putRes.statusCode >= 200 && putRes.statusCode < 300) {
        await _client.delete(
          Uri.parse('$_blobUrlPrefix/$hash'),
          headers: _authHeaders(),
        );
        return;
      }
    } on Exception catch (e) {
      // 复制失败：退化为硬删除原 blob
      Log.sync.w('[SafeServer] _deleteBlobSoftLegacy: 复制到隔离区失败，退化为硬删除 '
          'hash=${hash.substring(0, 8)}…', error: e);
    }
    try {
      await _client.delete(
        Uri.parse('$_blobUrlPrefix/$hash'),
        headers: _authHeaders(),
      );
    } on Exception catch (e) {
      // 删除失败不抛异常（GC 不阻断同步）
      Log.sync.w('[SafeServer] _deleteBlobSoftLegacy: 硬删除失败 '
          'hash=${hash.substring(0, 8)}…', error: e);
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
