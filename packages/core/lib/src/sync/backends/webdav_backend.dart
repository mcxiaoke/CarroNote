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
import 'package:core/src/crypto/crypto.dart';
import 'package:core/src/sync/sync_backend.dart';
import 'package:core/src/logger/app_logger.dart';

/// WebDAV keyring 子目录名（固定常量）
///
/// 客户端会在用户输入的 baseUrl 后自动附加此子目录，
/// 避免把 manifest/blobs 散落到用户网盘根目录与其他文件混在一起。
/// 多设备共享时只要 baseUrl 一样，子目录路径自动一致。
///
/// ⚠️ **不要跟着 Vault→Keyring 重命名改成 'safenotes-keyring'**。
/// 这是**线上数据的物理路径**，不是代码内部标识符：改名 = 所有已有用户
/// 的网盘数据"凭空消失"（客户端跑去一个空目录同步），且旧目录变成孤儿。
/// P2 的 Keyring 重构只改密钥状态模型，不涉及远端存储布局。
const String kWebDavVaultSubdir = 'safenotes-vault';

/// WebDAV 后端
///
/// [baseUrl] 是用户输入的 WebDAV 服务端根路径，例如：
///   - 坚果云：https://dav.jianguoyun.com/dav/
///   - NextCloud：https://nc.example.com/remote.php/dav/files/user/
///
/// 客户端会自动附加 `/safenotes-vault` 子目录作为 keyring 根路径，
/// 用户不需要手动指定子目录名，多设备共享时只要 baseUrl 一样即一致。
///
/// [username] / [password] 是 WebDAV 账号密码（坚果云需使用应用专用密码）
class WebDavBackend implements SyncBackend {
  /// WebDAV keyring 根 URL（用户 baseUrl + 自动附加的 safenotes-vault 子目录，不带末尾斜杠）
  final String baseUrl;

  /// 用户输入的原始 baseUrl（用于 providerKey 计算）
  final String _userBaseUrl;

  /// WebDAV 用户名
  final String username;

  /// WebDAV 密码（坚果云为应用专用密码）
  final String password;

  /// HTTP 客户端（可注入便于测试）
  /// HTTP 统一超时（B3：epoch 消除 P0 五项）
  ///
  /// 所有 HTTP 调用统一加 .timeout，超时异常（TimeoutException 继承
  /// Exception）由各调用点既有 catch 映射为 BackendUnavailableException。
  static const Duration _httpTimeout = Duration(seconds: 30);

  final http.Client _client;

  bool _initialized = false;

  /// E2 修复：ETag 支持探测结果
  ///
  /// init 时通过 GET manifest 探测服务器是否返回 ETag 头。
  /// - true：服务器支持 ETag（主流 WebDAV 服务）
  /// - false：服务器不返回 ETag，退化为内容 hash 作为 etag
  /// 退化为内容 hash 时 If-Match 可能被服务器忽略，退化为"最后写入胜"。
  bool _etagSupported = true;

  /// E2 修复：是否已警告过 ETag 不支持
  ///
  /// 避免每次同步都打印警告，只在 init 时警告一次。
  bool _etagWarningLogged = false;

  WebDavBackend({
    required String baseUrl,
    required this.username,
    required this.password,
    http.Client? client,
  }) : _client = client ?? http.Client(),
       _userBaseUrl = baseUrl,
       // 规范化：去掉末尾斜杠，附加固定子目录
       baseUrl = _normalizeAndAppendVault(baseUrl);

  /// 规范化用户输入的 URL，附加固定 keyring 子目录
  ///
  /// 例：
  ///   - 'https://dav.jianguoyun.com/dav/' → 'https://dav.jianguoyun.com/dav/safenotes-vault'
  ///   - 'https://dav.jianguoyun.com/dav'  → 'https://dav.jianguoyun.com/dav/safenotes-vault'
  ///   - 'http://192.168.1.118:2025/my-sync/' → 'http://192.168.1.118:2025/my-sync/safenotes-vault'
  static String _normalizeAndAppendVault(String url) {
    final trimmed = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
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

  /// 孤儿 blob 隔离区目录 URL
  ///
  /// 与 `blobs/` 为 vault 根下的兄弟目录（与 localFs / safeServer 后端一致），
  /// 隔离区不属于活跃 blob 命名空间，避免被 [listBlobs] 枚举。
  String get _orphanUrl => '$baseUrl/blobs-orphan';

  /// manifest 代际备份目录 URL（服务端 `manifest-backup/` 子目录）
  String get _manifestBackupUrl => '$baseUrl/manifest-backup';

  @override
  Future<void> init() async {
    // MKCOL 创建根目录和 blobs 子目录（幂等：已存在返回 405）
    await _mkcol(baseUrl);
    await _mkcol(_blobsUrl);
    // E2 修复：探测服务器是否支持 ETag
    await _probeEtagSupport();
    _initialized = true;
  }

  /// E2 修复：探测服务器是否返回 ETag 头
  ///
  /// 通过 GET manifest 探测：
  ///   - 200 响应：检查 etag 头，有则支持，无则不支持
  ///   - 404（首次同步）：用 PROPFIND 查询属性，检查是否返回 getetag
  ///   - 其他状态：保守假设支持（主流服务都支持）
  ///
  /// 不支持时打印警告（仅一次），提示用户乐观锁可能失效。
  Future<void> _probeEtagSupport() async {
    try {
      http.Response res;
      try {
        res = await _client
            .get(Uri.parse(_manifestUrl), headers: _authHeaders())
            .timeout(_httpTimeout);
      } on Exception catch (e) {
        // 网络错误：保守假设支持，不阻断 init
        Log.sync.w('[WebDAV] ETag 探测网络错误，保守假设支持', error: e);
        return;
      }

      if (res.statusCode == 200) {
        final etag = _normalizeEtag(res.headers['etag']);
        _etagSupported = etag.isNotEmpty;
      } else if (res.statusCode == 404) {
        // 首次同步：用 PROPFIND 探测
        _etagSupported = await _probeEtagViaPropfind();
      }
      // 其他状态码保守假设支持

      if (!_etagSupported && !_etagWarningLogged) {
        _etagWarningLogged = true;
        Log.sync.w(
          '[WebDAV] 警告：服务器不支持 ETag 头，'
          '乐观锁将退化为内容 hash 比较，'
          'If-Match 可能被服务器忽略，多端并发写入有覆盖风险。'
          '建议升级 WebDAV 服务或使用 SafeServer 后端。',
        );
      }
    } on Exception catch (e) {
      // 探测失败不阻断 init
      Log.sync.w('[WebDAV] ETag 探测失败，保守假设支持', error: e);
    }
  }

  /// 通过 PROPFIND 探测 ETag 支持
  ///
  /// 请求 getetag 属性，检查响应 XML 是否包含 etag 值。
  Future<bool> _probeEtagViaPropfind() async {
    try {
      final req = http.Request('PROPFIND', Uri.parse(_manifestUrl));
      req.headers.addAll(_authHeaders());
      req.headers['Depth'] = '0';
      req.headers['Content-Type'] = 'application/xml; charset=utf-8';
      req.body =
          '<?xml version="1.0" encoding="utf-8"?>'
          '<propfind xmlns="DAV:"><prop><getetag/></prop></propfind>';

      final streamedRes = await _client.send(req).timeout(_httpTimeout);
      final res = await http.Response.fromStream(streamedRes);
      if (res.statusCode != 207 && res.statusCode != 200) {
        // PROPFIND 失败：保守假设支持
        return true;
      }
      // 检查响应 XML 是否包含非空的 etag 值
      final body = res.body;
      // 简单字符串匹配（避免引入 XML 解析库）
      // 成功响应格式：<D:getetag>"xxx"</D:getetag>
      // 失败响应格式：<D:getetag/> 或 <D:status>HTTP/1.1 404 Not Found</D:status>
      return body.contains('<D:getetag>') && !body.contains('<D:getetag/>');
    } on Exception catch (e) {
      // 探测失败：保守假设支持
      Log.sync.w('[WebDAV] PROPFIND 探测失败，保守假设 ETag 支持', error: e);
      return true;
    }
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
      res = await _client
          .get(Uri.parse(_manifestUrl), headers: _authHeaders())
          .timeout(_httpTimeout);
    } catch (e) {
      throw BackendUnavailableException('GET manifest network error: $e');
    }

    if (res.statusCode == 404) {
      // 首次同步：远端无 manifest
      return (ciphertext: Uint8List(0), etag: '');
    }
    if (res.statusCode != 200) {
      throw BackendUnavailableException(
        'GET manifest failed: ${res.statusCode} ${res.body}',
      );
    }

    final etag = _normalizeEtag(res.headers['etag']);
    final ciphertext = res.bodyBytes;
    // F-M04：远端 manifest 大小上限，防恶意服务端打爆内存
    checkRemoteReadSize(ciphertext, 'WebDAV manifest', kRemoteManifestMaxBytes);

    // 服务器未返回 ETag 时，退化为内容 hash 作为 etag
    // 注意：这种情况下 putManifest 的 If-Match 可能被服务器忽略，
    // 退化为"最后写入胜"。主流 WebDAV 服务都返回 ETag，此分支极少触发。
    final effectiveEtag = etag.isNotEmpty
        ? etag
        : _computeContentEtag(ciphertext);

    return (ciphertext: ciphertext, etag: effectiveEtag);
  }

  @override
  Future<String> putManifest(Uint8List ciphertext, String expectedEtag) async {
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
      res = await _client
          .put(Uri.parse(_manifestUrl), headers: headers, body: ciphertext)
          .timeout(_httpTimeout);
    } on Exception catch (e) {
      throw BackendUnavailableException('PUT manifest network error: $e');
    }

    // 412 Precondition Failed = If-Match 不匹配
    // 409 Conflict = 某些 WebDAV 实现用于 If-None-Match 冲突
    if (res.statusCode == 412 || res.statusCode == 409) {
      throw ConflictException(
        'WebDAV If-Match failed: ${res.statusCode} (expected etag=$expectedEtag)',
      );
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw BackendUnavailableException(
        'PUT manifest failed: ${res.statusCode} ${res.body}',
      );
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
      res = await _client
          .get(Uri.parse('$_blobsUrl/$hash'), headers: _authHeaders())
          .timeout(_httpTimeout);
    } on Exception catch (e) {
      throw BackendUnavailableException('GET blob network error: $e');
    }

    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw BackendUnavailableException(
        'GET blob failed: ${res.statusCode} for hash=$hash',
      );
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
      res = await _client
          .put(Uri.parse('$_blobsUrl/$hash'), headers: headers, body: data)
          .timeout(_httpTimeout);
    } on Exception catch (e) {
      throw BackendUnavailableException('PUT blob network error: $e');
    }

    // WebDAV PUT 幂等：相同内容覆盖写
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw BackendUnavailableException(
        'PUT blob failed: ${res.statusCode} for hash=$hash',
      );
    }
  }

  /// F1 修复：删除 blob（GC 用）
  ///
  /// WebDAV DELETE 是标准方法（坚果云/Nextcloud 都支持）。
  /// 幂等：404 视为已删除，不抛异常。
  @override
  Future<void> deleteBlob(String hash) async {
    _ensureInitialized();

    http.Response res;
    try {
      res = await _client
          .delete(Uri.parse('$_blobsUrl/$hash'), headers: _authHeaders())
          .timeout(_httpTimeout);
    } on Exception catch (e) {
      throw BackendUnavailableException('DELETE blob network error: $e');
    }

    // 204 No Content / 200 OK = 删除成功
    // 404 Not Found = 已删除（幂等，视为成功）
    if (res.statusCode == 404) return;
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw BackendUnavailableException(
        'DELETE blob failed: ${res.statusCode} for hash=$hash',
      );
    }
  }

  /// F1 修复：列出所有 blob 的 hash（GC 用）
  ///
  /// 用 PROPFIND 深度 1 查询 blobs/ 目录，解析响应 XML 提取 href 中的文件名。
  /// 服务器不支持 PROPFIND 或查询失败时返回空列表（GC 退化为跳过孤儿清理）。
  @override
  Future<List<String>> listBlobs() async {
    _ensureInitialized();

    try {
      final req = http.Request('PROPFIND', Uri.parse(_blobsUrl));
      req.headers.addAll(_authHeaders());
      req.headers['Depth'] = '1';
      req.headers['Content-Type'] = 'application/xml; charset=utf-8';
      req.body =
          '<?xml version="1.0" encoding="utf-8"?>'
          '<propfind xmlns="DAV:"><prop><displayname/></prop></propfind>';

      final streamedRes = await _client.send(req).timeout(_httpTimeout);
      final res = await http.Response.fromStream(streamedRes);
      // 207 Multi-Status = PROPFIND 成功
      if (res.statusCode != 207 && res.statusCode != 200) {
        return [];
      }

      // 解析响应 XML，提取 <D:href> 中的文件名
      // 响应格式：<D:response><D:href>/path/blobs/<hash></D:href>...</D:response>
      final body = res.body;
      final result = <String>[];
      final hashRegex = RegExp(r'^[a-f0-9]{64}$');
      // 简单字符串匹配（避免引入 XML 解析库）
      final hrefRegex = RegExp(
        r'<(?:[^:>]+:)?href[^>]*>([^<]+)</(?:[^:>]+:)?href>',
      );
      for (final match in hrefRegex.allMatches(body)) {
        final href = match.group(1)!;
        // 取 URL 路径最后一段作为文件名
        final name = href.split('/').where((s) => s.isNotEmpty).last;
        // URL 解码（部分服务器会编码特殊字符）
        final decoded = Uri.decodeComponent(name);
        if (hashRegex.hasMatch(decoded)) {
          result.add(decoded);
        }
      }
      return result;
    } on Exception catch (e) {
      // 探测失败：保守返回空列表，GC 跳过孤儿清理
      Log.sync.w('[WebDAV] listBlobs PROPFIND 失败，GC 跳过孤儿清理', error: e);
      return [];
    }
  }

  /// P1-2 修复：软删除 blob（COPY 到 blobs-orphan/ 隔离区，再删原 blob）
  ///
  /// WebDAV 无"移动"语义，用 COPY + DELETE 模拟：先把 blob COPY 到隔离区
  /// （`blobs-orphan/`，与 `blobs/` 同级；文件名附时间戳 `hash.<epochMs>`），
  /// 再删除原 blob。COPY 失败时退化为直接 DELETE 原 blob（硬删除），不阻断 GC。
  @override
  Future<void> deleteBlobSoft(String hash) async {
    _ensureInitialized();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final dest = '$_orphanUrl/$hash.$ts';
    // 确保隔离区目录存在（已存在返回 405，忽略）
    try {
      await _mkcol(_orphanUrl);
    } on Exception catch (e) {
      // MKCOL 失败（目录已存在或无权限），忽略继续
      Log.sync.d(
        '[WebDAV] deleteBlobSoft: MKCOL blobs-orphan 失败（可能已存在）',
        error: e,
      );
    }
    try {
      final copyReq = http.Request('COPY', Uri.parse('$_blobsUrl/$hash'));
      copyReq.headers.addAll(_authHeaders());
      copyReq.headers['Destination'] = dest;
      copyReq.headers['Depth'] = '0';
      copyReq.headers['Overwrite'] = 'T';
      final copyRes = await _client.send(copyReq).timeout(_httpTimeout);
      final copyHttp = await http.Response.fromStream(copyRes);
      if (copyHttp.statusCode >= 200 && copyHttp.statusCode < 300) {
        // 隔离区已有副本：删除原 blob
        await _client
            .delete(Uri.parse('$_blobsUrl/$hash'), headers: _authHeaders())
            .timeout(_httpTimeout);
        return;
      }
    } on Exception catch (e) {
      // COPY 失败：退化为硬删除原 blob
      Log.sync.w(
        '[WebDAV] deleteBlobSoft: COPY 失败，退化为硬删除 '
        'hash=${hash.substring(0, 8)}…',
        error: e,
      );
    }
    try {
      await _client
          .delete(Uri.parse('$_blobsUrl/$hash'), headers: _authHeaders())
          .timeout(_httpTimeout);
    } on Exception catch (e) {
      // 删除失败不抛异常（GC 不阻断同步）
      Log.sync.w(
        '[WebDAV] deleteBlobSoft: 硬删除失败 '
        'hash=${hash.substring(0, 8)}…',
        error: e,
      );
    }
  }

  /// P1-2 修复：列出隔离区孤儿 blob 的 hash
  ///
  /// PROPFIND blobs-orphan/ 目录，解析 `hash.<epochMs>` 文件名，返回 hash 部分。
  @override
  Future<List<String>> listOrphanBlobs() async {
    _ensureInitialized();
    try {
      final req = http.Request('PROPFIND', Uri.parse(_orphanUrl));
      req.headers.addAll(_authHeaders());
      req.headers['Depth'] = '1';
      req.headers['Content-Type'] = 'application/xml; charset=utf-8';
      req.body =
          '<?xml version="1.0" encoding="utf-8"?>'
          '<propfind xmlns="DAV:"><prop><displayname/></prop></propfind>';
      final streamedRes = await _client.send(req).timeout(_httpTimeout);
      final res = await http.Response.fromStream(streamedRes);
      if (res.statusCode != 207 && res.statusCode != 200) return [];
      final hashRegex = RegExp(r'^[a-f0-9]{64}\.');
      final hrefRegex = RegExp(
        r'<(?:[^:>]+:)?href[^>]*>([^<]+)</(?:[^:>]+:)?href>',
      );
      final result = <String>[];
      for (final match in hrefRegex.allMatches(res.body)) {
        final href = match.group(1)!;
        final name = Uri.decodeComponent(
          href.split('/').where((s) => s.isNotEmpty).last,
        );
        if (hashRegex.hasMatch(name)) {
          result.add(name.substring(0, 64));
        }
      }
      return result;
    } on Exception catch (e) {
      Log.sync.w('[WebDAV] listOrphanBlobs PROPFIND 失败', error: e);
      return [];
    }
  }

  /// P1-2 修复：清理隔离区中超过保留期的 blob
  ///
  /// PROPFIND blobs-orphan/ 目录，解析 `hash.<epochMs>`，早于 now-retention 的
  /// 通过 DELETE 彻底删除。
  @override
  Future<void> purgeOrphans(Duration retention) async {
    _ensureInitialized();
    try {
      final req = http.Request('PROPFIND', Uri.parse(_orphanUrl));
      req.headers.addAll(_authHeaders());
      req.headers['Depth'] = '1';
      req.headers['Content-Type'] = 'application/xml; charset=utf-8';
      req.body =
          '<?xml version="1.0" encoding="utf-8"?>'
          '<propfind xmlns="DAV:"><prop><displayname/></prop></propfind>';
      final streamedRes = await _client.send(req).timeout(_httpTimeout);
      final res = await http.Response.fromStream(streamedRes);
      if (res.statusCode != 207 && res.statusCode != 200) return;
      final hrefRegex = RegExp(
        r'<(?:[^:>]+:)?href[^>]*>([^<]+)</(?:[^:>]+:)?href>',
      );
      final cutoff = DateTime.now().subtract(retention).millisecondsSinceEpoch;
      for (final match in hrefRegex.allMatches(res.body)) {
        final href = match.group(1)!;
        final name = Uri.decodeComponent(
          href.split('/').where((s) => s.isNotEmpty).last,
        );
        final dot = name.indexOf('.');
        if (dot > 0 && name.substring(0, dot).length == 64) {
          final ts = int.tryParse(name.substring(dot + 1));
          if (ts != null && ts < cutoff) {
            try {
              await _client
                  .delete(
                    Uri.parse('$_orphanUrl/$name'),
                    headers: _authHeaders(),
                  )
                  .timeout(_httpTimeout);
            } on Exception catch (e) {
              // 单个删除失败不阻断
              Log.sync.w(
                '[WebDAV] purgeOrphans: 单个孤儿删除失败 '
                'name=$name',
                error: e,
              );
            }
          }
        }
      }
    } on Exception catch (e) {
      // 清理失败不阻断同步
      Log.sync.w('[WebDAV] purgeOrphans: 清理失败', error: e);
    }
  }

  // ──────────────────────────────────────────────
  // P2 Journal 远端副本（服务端 `journal/` 子目录）
  // ──────────────────────────────────────────────

  /// journal 远端副本目录 URL
  String get _journalUrl => '$baseUrl/journal';

  /// P2：写入 journal 密文副本（内容已由 Journal 加密，网盘只存字节）
  ///
  /// **F-H07 修复**：非 2xx 状态抛异常，禁止"假成功"。
  /// 修复前异常/非 2xx 被整体吞掉，journal 侧 `_uploadedSeq` 无条件推进，
  /// 失败归档永不重传，远端 journal 出现洞。现在由 journal.syncToRemote
  /// 的外层 catch 兜底（降级 local-only 且不推进水位，下次同步重传）。
  @override
  Future<void> putJournalObject(String name, Uint8List ciphertext) async {
    _ensureInitialized();
    // 确保目录存在（已存在返回 405，忽略；仅为幂等建目录，不影响上传结果）
    try {
      await _mkcol(_journalUrl);
    } on Exception catch (e) {
      Log.sync.d(
        '[WebDAV] putJournalObject: MKCOL journal 失败（可能已存在）',
        error: e,
      );
    }
    final res = await _client
        .put(
          Uri.parse('$_journalUrl/$name'),
          headers: {
            ..._authHeaders(),
            'Content-Type': 'application/octet-stream',
          },
          body: ciphertext,
        )
        .timeout(_httpTimeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError(
        'WebDAV journal 副本上传失败 name=$name: ${res.statusCode} ${res.body}',
      );
    }
  }

  @override
  Future<Uint8List?> getJournalObject(String name) async {
    _ensureInitialized();
    try {
      final res = await _client
          .get(Uri.parse('$_journalUrl/$name'), headers: _authHeaders())
          .timeout(_httpTimeout);
      if (res.statusCode != 200) return null;
      final bytes = res.bodyBytes;
      // F-M04：journal 副本大小上限，防恶意服务端打爆内存
      checkRemoteReadSize(bytes, 'WebDAV journal', kRemoteJournalMaxBytes);
      return bytes;
    } on Exception catch (e) {
      Log.sync.d('[WebDAV] journal 副本读取失败 name=$name', error: e);
      return null;
    }
  }

  @override
  Future<List<String>> listJournalObjects() async {
    _ensureInitialized();
    try {
      final req = http.Request('PROPFIND', Uri.parse(_journalUrl));
      req.headers.addAll(_authHeaders());
      req.headers['Depth'] = '1';
      req.headers['Content-Type'] = 'application/xml; charset=utf-8';
      req.body =
          '<?xml version="1.0" encoding="utf-8"?>'
          '<propfind xmlns="DAV:"><prop><displayname/></prop></propfind>';
      final streamedRes = await _client.send(req).timeout(_httpTimeout);
      final res = await http.Response.fromStream(streamedRes);
      if (res.statusCode != 207 && res.statusCode != 200) return [];
      final result = <String>[];
      final hrefRegex = RegExp(
        r'<(?:[^:>]+:)?href[^>]*>([^<]+)</(?:[^:>]+:)?href>',
      );
      for (final match in hrefRegex.allMatches(res.body)) {
        final href = match.group(1)!;
        final parts = href.split('/').where((s) => s.isNotEmpty);
        if (parts.isEmpty) continue;
        final decoded = Uri.decodeComponent(parts.last);
        if (decoded.endsWith('.json')) result.add(decoded);
      }
      return result;
    } on Exception catch (e) {
      Log.sync.d('[WebDAV] journal 副本列举失败', error: e);
      return [];
    }
  }

  /// P1-1 修复：manifest 代际备份（落地到服务端 `manifest-backup/` 子目录环形备份）
  ///
  /// 与 localFs / safeServer 后端一致：在"服务端"（用户网盘）的 `manifest-backup/`
  /// 子目录维护环形备份 `manifest.bak-0`..`manifest.bak-{N-1}`（轮转位置记在
  /// `.manifest-bak-index`），远端 manifest 损坏/被清空时可从服务端备份恢复。
  @override
  Future<void> backupManifest([Uint8List? currentManifestBytes]) async {
    if (currentManifestBytes == null || currentManifestBytes.isEmpty) return;
    _ensureInitialized();
    try {
      await _backupManifestOnServer(currentManifestBytes);
    } on Exception catch (e) {
      // 服务端备份失败不阻断同步
      Log.sync.w('[WebDAV] manifest 备份失败', error: e);
    }
  }

  /// P1-1：在 WebDAV 服务端 `manifest-backup/` 子目录维护环形备份
  ///
  /// 通过 GET 读取 `.manifest-bak-index` 确定轮转槽位，再 PUT 索引与备份文件
  /// （父目录由服务端自动创建，无需显式 MKCOL 备份子目录）。
  Future<void> _backupManifestOnServer(Uint8List bytes) async {
    final backupUrl = _manifestBackupUrl;
    // 确保备份子目录存在（已存在返回 405，忽略）
    try {
      await _mkcol(backupUrl);
    } on Exception catch (e) {
      // 某些服务端自动创建父目录，MKCOL 失败可忽略
      Log.sync.d(
        '[WebDAV] _backupManifestOnServer: MKCOL 备份目录失败（可能已存在）',
        error: e,
      );
    }
    var slot = 0;
    try {
      final idxRes = await _client
          .get(
            Uri.parse('$backupUrl/.manifest-bak-index'),
            headers: _authHeaders(),
          )
          .timeout(_httpTimeout);
      if (idxRes.statusCode == 200) {
        slot = int.tryParse(utf8.decode(idxRes.bodyBytes).trim()) ?? 0;
      }
    } on Exception catch (e) {
      Log.sync.d('[WebDAV] _backupManifestOnServer: 读取备份索引失败，slot=0', error: e);
      slot = 0;
    }
    slot = (slot + 1) % kManifestBackupRingCount;
    // 写轮转索引
    await _client
        .put(
          Uri.parse('$backupUrl/.manifest-bak-index'),
          headers: {
            ..._authHeaders(),
            'Content-Type': 'application/octet-stream',
          },
          body: utf8.encode(slot.toString()),
        )
        .timeout(_httpTimeout);
    // 写备份文件
    await _client
        .put(
          Uri.parse('$backupUrl/manifest.bak-$slot'),
          headers: {
            ..._authHeaders(),
            'Content-Type': 'application/octet-stream',
          },
          body: bytes,
        )
        .timeout(_httpTimeout);
  }

  /// P1-1 READ 侧：列出服务端 `manifest-backup/` 目录的备份，从新到旧
  ///
  /// 通过 PROPFIND 枚举 `manifest.bak-*` 文件名，再 GET `.manifest-bak-index`
  /// 得到最近写入槽位，从该槽降序（mod N）即「从新到旧」。未初始化 / 枚举失败
  /// 时返回空列表（恢复退化为本地重建）。
  @override
  Future<List<String>> listManifestBackups() async {
    _ensureInitialized();
    final backupUrl = _manifestBackupUrl;
    try {
      final req = http.Request('PROPFIND', Uri.parse(backupUrl));
      req.headers.addAll(_authHeaders());
      req.headers['Depth'] = '1';
      req.headers['Content-Type'] = 'application/xml; charset=utf-8';
      req.body =
          '<?xml version="1.0" encoding="utf-8"?>'
          '<propfind xmlns="DAV:"><prop><displayname/></prop></propfind>';
      final streamedRes = await _client.send(req).timeout(_httpTimeout);
      final res = await http.Response.fromStream(streamedRes);
      if (res.statusCode != 207 && res.statusCode != 200) return const [];
      final names = <String>[];
      final hrefRegex = RegExp(
        r'<(?:[^:>]+:)?href[^>]*>([^<]+)</(?:[^:>]+:)?href>',
      );
      for (final match in hrefRegex.allMatches(res.body)) {
        final href = match.group(1)!;
        final parts = href.split('/').where((s) => s.isNotEmpty);
        if (parts.isEmpty) continue;
        final decoded = Uri.decodeComponent(parts.last);
        if (RegExp(r'^manifest\.bak-\d+$').hasMatch(decoded)) {
          names.add(decoded);
        }
      }
      // 最近写入槽位（读取失败按 0 处理）
      var newestSlot = 0;
      try {
        final idxRes = await _client
            .get(
              Uri.parse('$backupUrl/.manifest-bak-index'),
              headers: _authHeaders(),
            )
            .timeout(_httpTimeout);
        if (idxRes.statusCode == 200) {
          newestSlot = int.tryParse(utf8.decode(idxRes.bodyBytes).trim()) ?? 0;
        }
      } on Exception {
        newestSlot = 0;
      }
      // 从新到旧排序：slot 距离 newestSlot 越近越新
      int slotOf(String name) =>
          int.parse(RegExp(r'^manifest\.bak-(\d+)$').firstMatch(name)!.group(1)!);
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
      Log.sync.d('[WebDAV] manifest 备份枚举失败', error: e);
      return const [];
    }
  }

  /// P1-1 READ 侧：读取指定 manifest 备份密文；不存在返回 null
  @override
  Future<Uint8List?> readManifestBackup(String name) async {
    _ensureInitialized();
    if (!RegExp(r'^manifest\.bak-\d+$').hasMatch(name)) return null;
    final backupUrl = _manifestBackupUrl;
    try {
      final res = await _client
          .get(
            Uri.parse('$backupUrl/$name'),
            headers: _authHeaders(),
          )
          .timeout(_httpTimeout);
      if (res.statusCode != 200) return null;
      return res.bodyBytes;
    } on Exception catch (e) {
      Log.sync.d('[WebDAV] manifest 备份读取失败 name=$name', error: e);
      return null;
    }
  }

  /// D2 修复：备份损坏的 manifest（WebDAV 退化实现）
  ///
  /// WebDAV 不支持原子重命名，退化为 DELETE 损坏文件，让 SyncEngine 用本地数据
  /// 重建 manifest 上传。DELETE 失败不阻断重建（PUT 会覆盖）。
  @override
  Future<void> backupCorruptManifest(Uint8List ciphertext) async {
    _ensureInitialized();
    try {
      final res = await _client
          .delete(Uri.parse(_manifestUrl), headers: _authHeaders())
          .timeout(_httpTimeout);
      // 204/200 = 删除成功，404 = 不存在（已删除），都视为成功
      if (res.statusCode != 204 &&
          res.statusCode != 200 &&
          res.statusCode != 404) {
        // 删除失败：不抛异常，让 SyncEngine 的 PUT 覆盖
      }
    } on Exception catch (e) {
      // 网络错误：不抛异常，让 SyncEngine 的 PUT 覆盖
      Log.sync.w('[WebDAV] backupCorruptManifest: 删除失败，退化为 PUT 覆盖', error: e);
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
      req.body =
          '<?xml version="1.0" encoding="utf-8"?>'
          '<propfind xmlns="DAV:"><prop><resourcetype/></prop></propfind>';

      final streamedRes = await _client.send(req).timeout(_httpTimeout);
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
      final streamedRes = await _client.send(req).timeout(_httpTimeout);
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
        'WebDAV auth failed (401): check username/password',
      );
    }
    throw BackendUnavailableException(
      'MKCOL $url failed: ${res.statusCode} ${res.body}',
    );
  }
}
