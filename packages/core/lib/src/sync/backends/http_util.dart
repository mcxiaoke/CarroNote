/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

/*
 * 后端 HTTP 统一发送助手 —— B-H1 重定向修复
 *
 * 背景问题：
 *   package:http 的便捷方法（client.get/put/delete）默认 followRedirects=true，
 *   底层 dart:io HttpClient 自动跟随重定向会导致两类问题：
 *     1. 301/302/303 会把非 GET 方法重做成 GET 重发（写操作被降级）：
 *        PUT manifest/blob 变成无害的 GET，服务端返回 200 → 调用方误判写入
 *        成功 → 数据静默丢失（manifest 实际未写入、ETag 错乱）；
 *     2. 跟随重定向时原请求 headers（含 Authorization Basic/Bearer）会被
 *        带到重定向目标的任意 host，造成凭据跨站泄露。
 *
 * 本工具统一后端收发路径：所有请求 followRedirects=false，收到 3xx 后按
 * [sendWithRedirectPolicy] 的显式规则决定是否"手工重发同源请求"。
 *
 * 重定向规则（三层）：
 *   - 同源 = scheme + host + port 完全一致；
 *   - 读取类方法（GET/HEAD/PROPFIND/MKCOL）：允许跟随 301/302/303/307/308，
 *     另放宽允许 http→https 升格（相同 host:port 仅换 scheme）——这是
 *     WebDAV 服务常见的"拖尾斜杠"/"强制 https"规范化，跟随不写用户数据；
 *   - 其余写操作（PUT/DELETE/COPY/POST 等）：仅允许 307/308 且严格同源时
 *     跟随（语义保留），遇到 301/302/303 原样返回 3xx，由调用方既有
 *     非 2xx 分支响亮失败（绝不降级为 GET 造成"假成功"）。
 *
 * 跨源（含跨 scheme 降级、https→http）一律不跟随，杜绝凭据泄露。
 */

import 'dart:typed_data';

// Package 导入
import 'package:http/http.dart' as http;

// Project 导入
import 'package:core/src/logger/app_logger.dart';
import 'package:core/src/sync/sync_backend.dart';

/// 最大重定向跳数（防死循环，与 package:http 默认值一致）
const int kRedirectMaxHops = 5;

/// 允许跟随 301/302/303 的"读取类 / 无数据写入"方法：
/// 这些方法不会写入用户数据，跟随重定向不会造成数据丢失，也不存在
/// "方法降级破坏语义"的隐患。
const Set<String> _readLikeMethods = {'GET', 'HEAD', 'PROPFIND', 'MKCOL'};

/// 是否是需要走显式重定向语义的 3xx 状态码
bool _isRedirectStatus(int code) =>
    code == 301 || code == 302 || code == 303 || code == 307 || code == 308;

/// 同源判断：scheme + host + port 完全一致（端口含默认端口归一化）
bool _sameOrigin(Uri a, Uri b) =>
    a.scheme == b.scheme &&
    a.host.toLowerCase() == b.host.toLowerCase() &&
    a.port == b.port;

/// http → https 安全升格判断：
///
/// 相同 host、读取类方法场景下允许 scheme 由 http 升为 https。
/// 端口规则：
///   - 两侧均未显式指定端口（各自落在 80/443 默认值）→ 视为同端口连接目标；
///   - 任一侧显式指定了端口 → 要求两侧端口一致（不允许换端口）。
bool _isHttpToHttpsUpgrade(Uri a, Uri b) {
  if (a.scheme != 'http' || b.scheme != 'https') return false;
  if (a.host.toLowerCase() != b.host.toLowerCase()) return false;
  if (!a.hasPort && !b.hasPort) return true;
  return a.port == b.port;
}

/// 重定向策略判定：是否允许手工跟随到 [to]
bool _canFollowRedirect(int statusCode, String method, Uri from, Uri to) {
  // 同源是跟随的基础前提（读取类方法额外允许 http→https 升格）
  final sameOriginAllowed =
      _sameOrigin(from, to) ||
      (_readLikeMethods.contains(method) && _isHttpToHttpsUpgrade(from, to));
  if (!sameOriginAllowed) return false;
  // 307/308：语义保留，任何方法都可跟随
  if (statusCode == 307 || statusCode == 308) return true;
  // 301/302/303：仅读取类方法跟随（写方法会被降级破坏语义，交给调用方报错）
  return _readLikeMethods.contains(method);
}

/// 大小写不敏感地读取响应头（MockClient 等注入客户端可能不规范化头名）
String? _headerIgnoreCase(http.Response res, String name) {
  for (final e in res.headers.entries) {
    if (e.key.toLowerCase() == name) return e.value;
  }
  return null;
}

/// 统一发送 HTTP 请求，关掉 package:http 默认的盲目重定向，改走显式策略。
///
/// 行为与 package:http 类似但有三处关键增强：
///   1. 关掉底层 Client.followRedirects，避免写操作被静默降级为 GET（B-H1）；
///   2. 3xx 按 [sendWithRedirectPolicy] 规则显式决定是否手工重发；
///   3. 不跟随的 3xx 原样返回给调用方，由既有非 2xx 分支给出响亮失败。
///   4. T-5 修复：流式接收响应体边收边计数，超出 [maxResponseBodyBytes]
///      立即抛异常截断连接，避免把超大恶意响应体全量收进内存。
///
/// [bodyBytes] 在每次手工重发时都会被重新带上（307/308 语义保留）。
/// 超过 [kRedirectMaxHops] 跳抛 [http.ClientException]（确定性错误）。
Future<http.Response> sendWithRedirectPolicy({
  required http.Client client,
  required String method,
  required Uri url,
  Map<String, String>? headers,
  List<int>? bodyBytes,
  Duration timeout = const Duration(seconds: 30),
  int maxResponseBodyBytes = kRemoteManifestMaxBytes,
}) async {
  var current = url;
  for (var hop = 0; hop <= kRedirectMaxHops; hop++) {
    final req = http.Request(method, current);
    // 关键：关掉底层自动跟随，重定向完全由本函数显式决策
    req.followRedirects = false;
    if (headers != null) req.headers.addAll(headers);
    if (bodyBytes != null) req.bodyBytes = bodyBytes;

    final streamed = await client.send(req).timeout(timeout);
    if (streamed.contentLength != null &&
        streamed.contentLength! > maxResponseBodyBytes) {
      throw http.ClientException(
        'Response Content-Length (${streamed.contentLength}) exceeds limit ($maxResponseBodyBytes)',
        current,
      );
    }
    final builder = BytesBuilder(copy: false);
    var bytesReceived = 0;
    // P1-11：响应体读取超时。client.send(...).timeout 只护到「收到响应头」，
    // 恶意/故障服务端可以先回 200 头再以极慢速度吐 body，让 await for 永不
    // 结束（同步互斥锁永久持有）。Stream.timeout 保证任意相邻 chunk 间隔
    // 超过 [timeout] 即报错断流。
    final chunkStream = streamed.stream.timeout(
      timeout,
      onTimeout: (sink) {
        sink.addError(
          http.ClientException(
            'Response body read timed out after $timeout '
            '($method $current)',
            current,
          ),
        );
        sink.close();
      },
    );
    await for (final chunk in chunkStream) {
      bytesReceived += chunk.length;
      if (bytesReceived > maxResponseBodyBytes) {
        throw http.ClientException(
          'Response body exceeded max limit of $maxResponseBodyBytes bytes',
          current,
        );
      }
      builder.add(chunk);
    }
    final res = http.Response.bytes(
      builder.takeBytes(),
      streamed.statusCode,
      request: streamed.request,
      headers: streamed.headers,
      isRedirect: streamed.isRedirect,
      persistentConnection: streamed.persistentConnection,
      reasonPhrase: streamed.reasonPhrase,
    );
    if (!_isRedirectStatus(res.statusCode)) return res;

    final location = _headerIgnoreCase(res, 'location');
    if (location == null || location.isEmpty) {
      // 3xx 但无 Location：无从跟随，原样返回交给调用方按错误处理
      return res;
    }
    final target = current.resolve(location);
    if (!_canFollowRedirect(res.statusCode, method, current, target)) {
      // 不跟随（写操作 301/302/303 或跨源）：原样返回 3xx，调用方响亮失败
      return res;
    }
    Log.sync.d(
      '[HTTP] $method ${res.statusCode} → $target'
      '（同源/升格跟随，body=${bodyBytes?.length ?? 0}B）',
    );
    current = target;
  }
  // 跳数超限：确定性错误（重定向环），调用方会映射为 BackendUnavailableException
  throw http.ClientException(
    'redirect loop exceeded ($kRedirectMaxHops hops) for $method $url',
    url,
  );
}
