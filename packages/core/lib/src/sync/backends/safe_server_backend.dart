/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

/*
 * SafeServer 后端实现
 *
 * 用途：
 *   - 自建轻量同步服务：用户自己部署 server/go 或 server/nodejs/server.js
 *   - 比 WebDAV 更简单：纯 HTTP API，无目录概念，无 MKCOL，Bearer Token 认证
 *   - 单用户场景：一个 server 实例服务一个 keyring，无需账号系统
 *
 * 协议规范：docs/server-api-spec.md v2.2
 *
 * 兼容性约束：客户端要求服务端必须实现 v2.2（含资源层）且必须返回 ETag，
 * 不兼容的服务端将抛 [BackendUnavailableException]，不做降级。
 *
 * API 端点：
 *   GET    /api/v2/manifest           下载 manifest（带 ETag）
 *   PUT    /api/v2/manifest           上传 manifest（带 If-Match/If-None-Match 乐观锁）
 *   DELETE /api/v2/manifest           清理损坏 manifest（backupCorruptManifest 兜底用）
 *   GET    /api/v2/blob/<hash>        下载 blob
 *   PUT    /api/v2/blob/<hash>        上传 blob（幂等）
 *   DELETE /api/v2/blob/<hash>        删除 blob（GC 用，幂等）
 *   GET    /api/v2/blobs              列出所有 blob hash（GC 用，需认证）
 *   POST   /api/v2/resources/<path>   扩展操作 move/mkdir/copy/propfind/stats（v2.2 孤儿隔离 & manifest 备份）
 *   GET    /api/v2/health             健康检查（无需认证）
 *
 * 与 WebDavBackend 的差异：
 *   - 无 MKCOL（服务端自动创建存储空间）
 *   - 无 keyring-root 路径前缀（单用户，整个 server 即一个 keyring）
 *   - Bearer Token 而非 Basic Auth
 *   - 路径前缀 /api/v2/ 为未来版本预留扩展空间
 */

// Dart 原生导入
import 'dart:convert';
import 'dart:typed_data';

// Package 导入
import 'package:http/http.dart' as http;

// Project 导入
import 'package:core/src/crypto/crypto.dart';
import 'package:core/src/logger/app_logger.dart';
import 'package:core/src/sync/backends/http_util.dart';
import 'package:core/src/sync/sync_backend.dart';

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
/// 因为单用户场景下整个 server 实例就服务一个 keyring。
class SafeServerBackend implements SyncBackend {
  /// SafeServer 服务端 URL（不带末尾斜杠）
  final String baseUrl;

  /// 固定 Bearer Token
  final String token;

  /// HTTP 客户端（可注入便于测试）
  /// HTTP 统一超时（B3：epoch 消除 P0 五项）
  ///
  /// 所有 HTTP 调用统一加 .timeout，超时异常（TimeoutException 继承
  /// Exception）由各调用点既有 catch 映射为 BackendUnavailableException。
  ///
  /// 分层设计（P-修复：局域网后端出门失联 + 弱网容忍）：
  ///   - [_httpTimeout]（数据类，默认）：同步载荷均为笔记小文件，30s 对
  ///     弱网（手机信号差）下的上传/下载足够宽容，不误杀慢请求；
  ///   - [_initTimeout]（探测类）：init 阶段健康检查只需判定"后端是否可达"，
  ///     后端不可达（局域网失联）时 8s 内快速失败，避免重试等 30s 的卡感。
  static const Duration _httpTimeout = Duration(seconds: 30);
  static const Duration _initTimeout = Duration(seconds: 8);

  final http.Client _client;

  bool _initialized = false;

  SafeServerBackend({
    required String baseUrl,
    required this.token,
    http.Client? client,
  }) : _client = client ?? http.Client(),
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
    // 探测类请求用 _initTimeout：后端不可达时 8s 内快速失败
    http.Response res;
    try {
      res = await _sendHttp(
        'GET',
        Uri.parse(_healthUrl),
        timeout: _initTimeout,
      );
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

  /// B-H1 修复：后端统一 HTTP 发送入口
  ///
  /// 所有请求经 [sendWithRedirectPolicy] 显式处理重定向（followRedirects=false）：
  ///   - GET（读取）：307/308 同源跟随；301/302/303 同源或 http→https 升格时跟随；
  ///   - PUT/DELETE/POST（写操作）：仅 307/308 且严格同源时跟随；
  ///     遇到 301/302/303 原样返回 3xx，由调用方按错误响亮失败，
  ///     绝不降级为 GET 造成"写成功假象"（manifest 静默丢失）。
  Future<http.Response> _sendHttp(
    String method,
    Uri url, {
    Map<String, String>? headers,
    List<int>? bodyBytes,
    Duration timeout = _httpTimeout,
    int maxResponseBodyBytes = kRemoteManifestMaxBytes,
  }) {
    return sendWithRedirectPolicy(
      client: _client,
      method: method,
      url: url,
      headers: headers,
      bodyBytes: bodyBytes,
      timeout: timeout,
      maxResponseBodyBytes: maxResponseBodyBytes,
    );
  }

  @override
  Future<({Uint8List ciphertext, String etag})> getManifest() async {
    _ensureInitialized();

    http.Response res;
    try {
      res = await _sendHttp(
        'GET',
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
        'SafeServer auth failed (401): check token',
      );
    }
    if (res.statusCode != 200) {
      throw BackendUnavailableException(
        'GET manifest failed: ${res.statusCode} ${res.body}',
      );
    }

    final etag = _normalizeEtag(res.headers['etag']);
    final ciphertext = res.bodyBytes;
    // F-M04：远端 manifest 大小上限，防恶意服务端打爆内存
    checkRemoteReadSize(
      ciphertext,
      'SafeServer manifest',
      kRemoteManifestMaxBytes,
    );

    // 服务端必须返回 ETag（v2.2 规范要求）；缺失即视为不兼容，抛异常
    if (etag.isEmpty) {
      throw BackendUnavailableException(
        'GET manifest failed: server did not return ETag (SafeServer v2.2 required)',
      );
    }

    return (ciphertext: ciphertext, etag: etag);
  }

  @override
  Future<String> putManifest(Uint8List ciphertext, String expectedEtag) async {
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
      res = await _sendHttp(
        'PUT',
        Uri.parse(_manifestUrl),
        headers: headers,
        bodyBytes: ciphertext,
      );
    } on Exception catch (e) {
      throw BackendUnavailableException('PUT manifest network error: $e');
    }

    // 412 Precondition Failed = 乐观锁冲突
    if (res.statusCode == 412) {
      throw ConflictException(
        'SafeServer If-Match failed: ${res.statusCode} (expected etag=$expectedEtag)',
      );
    }
    if (res.statusCode == 401) {
      throw BackendUnavailableException(
        'SafeServer auth failed (401): check token',
      );
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw BackendUnavailableException(
        'PUT manifest failed: ${res.statusCode} ${res.body}',
      );
    }

    // 服务端必须返回新 ETag（v2.2 规范要求）；缺失即视为不兼容，抛异常
    final newEtag = _normalizeEtag(res.headers['etag']);
    if (newEtag.isEmpty) {
      throw BackendUnavailableException(
        'PUT manifest failed: server did not return ETag (SafeServer v2.2 required)',
      );
    }
    return newEtag;
  }

  @override
  Future<Uint8List?> getBlob(String hash) async {
    _ensureInitialized();

    http.Response res;
    try {
      res = await _sendHttp(
        'GET',
        Uri.parse('$_blobUrlPrefix/$hash'),
        headers: _authHeaders(),
        maxResponseBodyBytes: kRemoteBlobMaxBytes,
      );
    } on Exception catch (e) {
      throw BackendUnavailableException('GET blob network error: $e');
    }

    if (res.statusCode == 404) return null;
    if (res.statusCode == 401) {
      throw BackendUnavailableException(
        'SafeServer auth failed (401): check token',
      );
    }
    if (res.statusCode != 200) {
      throw BackendUnavailableException(
        'GET blob failed: ${res.statusCode} for hash=$hash',
      );
    }
    final bytes = res.bodyBytes;
    checkRemoteReadSize(bytes, 'SafeServer blob', kRemoteBlobMaxBytes);
    return bytes;
  }

  @override
  Future<void> putBlob(String hash, Uint8List data) async {
    _ensureInitialized();

    final headers = _authHeaders();
    headers['Content-Type'] = 'application/octet-stream';

    http.Response res;
    try {
      res = await _sendHttp(
        'PUT',
        Uri.parse('$_blobUrlPrefix/$hash'),
        headers: headers,
        bodyBytes: data,
      );
    } on Exception catch (e) {
      throw BackendUnavailableException('PUT blob network error: $e');
    }

    // 幂等：相同内容覆盖写
    if (res.statusCode == 401) {
      throw BackendUnavailableException(
        'SafeServer auth failed (401): check token',
      );
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw BackendUnavailableException(
        'PUT blob failed: ${res.statusCode} for hash=$hash',
      );
    }
  }

  /// 删除 blob（GC 用，幂等）
  ///
  /// SafeServer v2.2 协议定义了 DELETE /api/v2/blob/`<hash>` 端点
  /// （在 v2.2 中委托到资源层 `blobs/<hash>`）。
  ///
  /// **F-H08 修复**：405 视为旧版服务端未实现该端点，**静默降级**（不清理，
  /// 不抛异常），与 server-api-spec §4「客户端对 405 静默降级」一致。
  /// 修复前 405 抛 `BackendUnavailableException`，会把 GC/孤儿清理的预期降级
  /// 变成同步硬失败，破坏与旧版 v2.1/v2 服务端的升级时序兼容。
  @override
  Future<void> deleteBlob(String hash) async {
    _ensureInitialized();

    http.Response res;
    try {
      res = await _sendHttp(
        'DELETE',
        Uri.parse('$_blobUrlPrefix/$hash'),
        headers: _authHeaders(),
      );
    } on Exception catch (e) {
      throw BackendUnavailableException('DELETE blob network error: $e');
    }

    // 204 No Content = 删除成功
    // 404 Not Found = blob 不存在（幂等删除，视为成功）
    // 405 = 旧版服务端未实现 DELETE 端点（静默降级：仅失去清理能力，不影响同步）
    // 401 = 认证失败（仍抛异常，提示用户检查 token）
    if (res.statusCode == 204 ||
        res.statusCode == 404 ||
        res.statusCode == 405) {
      if (res.statusCode == 405) {
        Log.sync.d(
          '[SafeServer] deleteBlob: 405 旧版服务端未实现，静默降级 '
          'hash=$hash',
        );
      }
      return;
    }
    if (res.statusCode == 401) {
      throw BackendUnavailableException(
        'SafeServer auth failed (401): check token',
      );
    }
    // 其余状态视为真实故障，抛异常
    throw BackendUnavailableException(
      'DELETE blob failed: ${res.statusCode} for hash=$hash',
    );
  }

  /// 备份损坏的 manifest（v2.2 资源层 move 到 `.corrupt-<ts>`）
  ///
  /// v2.2 资源层提供 `move` 操作，等价于 localFs 的 rename / webdav 的 COPY+DELETE：
  /// 把损坏的 `manifest` 移动到 keyring 根的 `.corrupt-<ts>`，让其脱离 manifest 端点，
  /// 随后 SyncEngine 用本地数据重建 manifest 上传（PUT If-None-Match:* 成功）。
  /// 客户端要求服务端必须实现 v2.2 资源层。
  @override
  Future<void> backupCorruptManifest(Uint8List ciphertext) async {
    _ensureInitialized();
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
    // move 意外失败（如资源层异常）：退化为 DELETE 兜底
    try {
      await _sendHttp(
        'DELETE',
        Uri.parse(_manifestUrl),
        headers: _authHeaders(),
      );
    } on Exception catch (e) {
      // 删除失败不抛异常，让 SyncEngine 的 PUT 覆盖
      Log.sync.w(
        '[SafeServer] backupCorruptManifest: 删除失败，退化为 PUT 覆盖',
        error: e,
      );
    }
  }

  /// 列出所有 blob hash（GC 用）
  ///
  /// SafeServer v2.2 协议定义了 GET /api/v2/blobs 端点，返回 JSON 数组
  /// 包含所有 blob 的 hash。客户端用此列表与 manifest 引用对比，识别孤儿 blob。
  /// 客户端要求服务端必须实现 v2.2；非 200 响应视为不兼容，抛异常。
  @override
  Future<List<String>> listBlobs() async {
    _ensureInitialized();

    http.Response res;
    try {
      res = await _sendHttp(
        'GET',
        Uri.parse(_blobsUrl),
        headers: _authHeaders(),
      );
    } on Exception catch (e) {
      throw BackendUnavailableException('GET blobs network error: $e');
    }

    if (res.statusCode == 401) {
      throw BackendUnavailableException(
        'SafeServer auth failed (401): check token',
      );
    }
    if (res.statusCode != 200) {
      throw BackendUnavailableException(
        'GET blobs failed: ${res.statusCode} ${res.body}',
      );
    }

    try {
      final List<dynamic> hashes = jsonDecode(res.body);
      return hashes.whereType<String>().toList();
    } on FormatException {
      throw BackendUnavailableException(
        'GET blobs failed: invalid JSON response',
      );
    }
  }

  /// P1-2 修复：软删除 blob（移动到 `blobs-orphan/` 隔离区）
  ///
  /// v2.2 资源层提供 `move` 操作，等价于 localFs 的 rename / webdav 的 COPY+DELETE：
  /// 先把原 blob `move` 到 `blobs-orphan/<hash>.<epochMs>`，保留一段时间可恢复，
  /// 避免立即物理删除的不可逆损失。这是与另两个后端一致的孤儿隔离语义。
  @override
  Future<void> deleteBlobSoft(String hash) async {
    _ensureInitialized();
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
        Log.sync.w(
          '[SafeServer] deleteBlobSoft: 409 后删除原 blob 失败 '
          'hash=${hash.substring(0, 8)}…',
          error: e,
        );
      }
      return;
    }
    // 其余状态：v2.2 资源层必须支持 move，视为不兼容，抛异常
    throw BackendUnavailableException(
      'SafeServer move blob to quarantine failed: ${res.statusCode} for hash=$hash',
    );
  }

  /// P1-2 修复：列出隔离区孤儿 blob 的 hash
  ///
  /// v2.2：对 `blobs-orphan/` 做 propfind（depth=1），解析 `hash.<epochMs>` 返回 hash。
  @override
  Future<List<String>> listOrphanBlobs() async {
    final res = await _postResource('blobs-orphan', 'propfind', depth: 1);
    if (res.statusCode != 200) {
      throw BackendUnavailableException(
        'SafeServer propfind blobs-orphan failed: ${res.statusCode}',
      );
    }
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
      throw BackendUnavailableException(
        'SafeServer propfind blobs-orphan failed: invalid JSON response',
      );
    }
  }

  /// P1-2 修复：清理隔离区中超过保留期的 blob
  ///
  /// v2.2：对 `blobs-orphan/` 做 propfind（depth=1），解析 `hash.<epochMs>`，
  /// 早于 now-retention 的通过 `DELETE /api/v2/resources/blobs-orphan/<name>` 彻底删除。
  @override
  Future<void> purgeOrphans(Duration retention) async {
    final res = await _postResource('blobs-orphan', 'propfind', depth: 1);
    if (res.statusCode != 200) {
      throw BackendUnavailableException(
        'SafeServer propfind blobs-orphan failed: ${res.statusCode}',
      );
    }
    final cutoff = DateTime.now().subtract(retention).millisecondsSinceEpoch;
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
              Log.sync.w(
                '[SafeServer] purgeOrphans: 单个孤儿删除失败 '
                'name=$name',
                error: e,
              );
            }
          }
        }
      }
    } on FormatException {
      throw BackendUnavailableException(
        'SafeServer propfind blobs-orphan failed: invalid JSON response',
      );
    }
  }

  /// P1-1 修复：manifest 代际备份（落地到服务端 `manifest-backup/` 子目录，环形 N 份）
  ///
  /// v2.2：用资源层在 keyring 内 `manifest-backup/` 子目录维护环形备份
  /// `manifest.bak-0`..`manifest.bak-{N-1}`（轮转位置记在 `.manifest-bak-index`），
  /// 与 localFs / webdav 后端布局一致。远端 manifest 损坏/被清空时，可从服务端
  /// 最近一代备份恢复。
  ///
  /// 备份失败不阻断同步（记录日志，由调用方 try-catch）。
  @override
  Future<void> backupManifest([Uint8List? currentManifestBytes]) async {
    if (currentManifestBytes == null || currentManifestBytes.isEmpty) return;
    try {
      await _backupManifestOnServer(currentManifestBytes);
    } on Exception catch (e) {
      // 服务端备份失败不阻断同步
      Log.sync.w('[SafeServer] 服务端 manifest 备份失败', error: e);
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
      Log.sync.d(
        '[SafeServer] _backupManifestOnServer: 读取备份索引失败，slot=0',
        error: e,
      );
      slot = 0;
    }
    slot = (slot + 1) % kManifestBackupRingCount;
    await _putResource(
      '$rel/.manifest-bak-index',
      utf8.encode(slot.toString()),
    );
    await _putResource('$rel/manifest.bak-$slot', bytes);
  }

  /// P1-1 READ 侧：列出服务端 `manifest-backup/` 目录的备份，从新到旧
  ///
  /// 通过资源层 `propfind` 枚举 `manifest.bak-*` 文件名，再读 `.manifest-bak-index`
  /// 得到最近写入槽位，从该槽降序（mod N）即「从新到旧」。未初始化 / 枚举失败
  /// 时返回空列表（恢复退化为本地重建）。
  @override
  Future<List<String>> listManifestBackups() async {
    _ensureInitialized();
    try {
      final res = await _postResource('manifest-backup', 'propfind', depth: 1);
      if (res.statusCode != 200) return const [];
      final List<dynamic> entries = jsonDecode(res.body);
      final names = <String>[];
      for (final e in entries) {
        final name = (e is Map ? e['name'] : null)?.toString() ?? '';
        if (RegExp(r'^manifest\.bak-\d+$').hasMatch(name)) {
          names.add(name);
        }
      }
      // 最近写入槽位（读取失败按 0 处理）
      var newestSlot = 0;
      try {
        final idx = await _getResource('manifest-backup/.manifest-bak-index');
        if (idx.statusCode == 200) {
          newestSlot = int.tryParse(utf8.decode(idx.bodyBytes).trim()) ?? 0;
        }
      } on Exception {
        newestSlot = 0;
      }
      // 从新到旧排序：slot 距离 newestSlot 越近越新
      int slotOf(String name) => int.parse(
        RegExp(r'^manifest\.bak-(\d+)$').firstMatch(name)!.group(1)!,
      );
      names.sort((a, b) {
        final da =
            (slotOf(a) - newestSlot + kManifestBackupRingCount) %
            kManifestBackupRingCount;
        final db =
            (slotOf(b) - newestSlot + kManifestBackupRingCount) %
            kManifestBackupRingCount;
        return da.compareTo(db);
      });
      return names;
    } on Exception catch (e) {
      Log.sync.d('[SafeServer] manifest 备份枚举失败', error: e);
      return const [];
    }
  }

  /// P1-1 READ 侧：读取指定 manifest 备份密文；不存在返回 null
  @override
  Future<Uint8List?> readManifestBackup(String name) async {
    _ensureInitialized();
    if (!RegExp(r'^manifest\.bak-\d+$').hasMatch(name)) return null;
    try {
      final res = await _getResource('manifest-backup/$name');
      if (res.statusCode != 200) return null;
      return res.bodyBytes;
    } on Exception catch (e) {
      Log.sync.d('[SafeServer] manifest 备份读取失败 name=$name', error: e);
      return null;
    }
  }

  // ──────────────────────────────────────────────
  // P2 Journal 远端副本（v2.2 资源层 `journal/` 子目录）
  // ──────────────────────────────────────────────

  /// P2：写入 journal 密文副本到服务端 `journal/<name>`
  ///
  /// 内容已由 Journal 用 AES-GCM(dataKey) 加密，服务端只存字节。
  /// 客户端要求服务端必须实现 v2.2 资源层。
  ///
  /// **F-H07 修复**：非 2xx 状态抛异常，禁止"假成功"。
  /// 修复前异常被整体吞掉，journal 侧 `_uploadedSeq` 无条件推进，
  /// 失败归档永不重传。现在由 journal.syncToRemote 外层 catch 兜底。
  @override
  Future<void> putJournalObject(String name, Uint8List ciphertext) async {
    _ensureInitialized();
    await _postResource('journal', 'mkdir'); // 201 已建 / 405 已存在（幂等）
    final res = await _putResource('journal/$name', ciphertext);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError(
        '[SafeServer] journal 副本上传失败 name=$name: '
        '${res.statusCode} ${res.body}',
      );
    }
  }

  @override
  Future<Uint8List?> getJournalObject(String name) async {
    _ensureInitialized();
    try {
      final res = await _getResource('journal/$name');
      if (res.statusCode != 200) return null;
      final bytes = res.bodyBytes;
      // F-M04：journal 副本大小上限，防恶意服务端打爆内存
      checkRemoteReadSize(bytes, 'SafeServer journal', kRemoteJournalMaxBytes);
      return bytes;
    } on Exception catch (e) {
      Log.sync.d('[SafeServer] journal 副本读取失败 name=$name', error: e);
      return null;
    }
  }

  @override
  Future<List<String>> listJournalObjects() async {
    _ensureInitialized();
    try {
      final res = await _postResource('journal', 'propfind', depth: 1);
      if (res.statusCode != 200) return [];
      final List<dynamic> entries = jsonDecode(res.body);
      final result = <String>[];
      for (final e in entries) {
        final name = (e is Map ? e['name'] : null)?.toString() ?? '';
        if (name.endsWith('.json')) result.add(name);
      }
      return result;
    } on Exception catch (e) {
      Log.sync.d('[SafeServer] journal 副本列举失败', error: e);
      return [];
    }
  }

  // ──────────────────────────────────────────────
  // 笔记元数据远端对象（v2.2 资源层根 items.meta）
  // ──────────────────────────────────────────────

  @override
  bool get supportsMetaObjects => true;

  /// 写入 items.meta（内容已由引擎用 AES-GCM(dataKey) 加密，服务端只存字节）
  ///
  /// 非 2xx 抛异常禁止"假成功"（与 putJournalObject 的 F-H07 修复同理由）；
  /// 异常由引擎 meta 同步段的外层 catch 兜底，下次同步重试。
  @override
  Future<void> putMetaObject(Uint8List ciphertext) async {
    _ensureInitialized();
    final res = await _putResource('items.meta', ciphertext);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      // 统一抛 BackendUnavailableException（而非 StateError）：
      // 与网络层异常类型一致，便于引擎按类型分级日志/重试策略
      throw BackendUnavailableException(
        '[SafeServer] items.meta 上传失败: ${res.statusCode}',
      );
    }
  }

  @override
  Future<Uint8List?> getMetaObject() async {
    _ensureInitialized();
    try {
      final res = await _getResource('items.meta');
      if (res.statusCode != 200) return null;
      final bytes = res.bodyBytes;
      // F-M04：大小上限，防恶意服务端打爆内存
      checkRemoteReadSize(bytes, 'SafeServer meta', kRemoteMetaMaxBytes);
      return bytes;
    } on Exception catch (e) {
      Log.sync.d('[SafeServer] items.meta 读取失败', error: e);
      return null;
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
    final body = <String, Object>{'op': op, 'overwrite': overwrite};
    if (dest != null) body['dest'] = dest;
    if (op == 'propfind' || op == 'stats') body['depth'] = depth;
    return _sendHttp(
      'POST',
      uri,
      headers: {..._authHeaders(), 'Content-Type': 'application/json'},
      bodyBytes: utf8.encode(jsonEncode(body)),
    );
  }

  /// GET `/api/v2/resources/<rel>`
  Future<http.Response> _getResource(String rel) async {
    final uri = Uri.parse('$baseUrl$kSafeServerApiPrefix/resources/$rel');
    return _sendHttp('GET', uri, headers: _authHeaders());
  }

  /// PUT `/api/v2/resources/<rel>`
  Future<http.Response> _putResource(String rel, List<int> bytes) async {
    final uri = Uri.parse('$baseUrl$kSafeServerApiPrefix/resources/$rel');
    return _sendHttp(
      'PUT',
      uri,
      headers: {..._authHeaders(), 'Content-Type': 'application/octet-stream'},
      bodyBytes: bytes,
    );
  }

  /// DELETE `/api/v2/resources/<rel>`
  Future<http.Response> _deleteResource(String rel) async {
    final uri = Uri.parse('$baseUrl$kSafeServerApiPrefix/resources/$rel');
    return _sendHttp('DELETE', uri, headers: _authHeaders());
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
      final res = await _sendHttp('GET', Uri.parse(_healthUrl));
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
}
