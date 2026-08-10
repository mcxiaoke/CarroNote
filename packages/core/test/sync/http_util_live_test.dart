/*
 * sendWithRedirectPolicy 真实网络集成测试（B-H1，默认跳过）
 *
 * 用真实 http.Client()（底层 dart:io HttpClient）打 https://httpbun.com/，
 * 验证 MockClient 单测覆盖不到的"传输层真实行为"：
 *   1. 修复核心：写操作（PUT/POST/DELETE）遇 301/302/303 返回 3xx 不跟随——
 *      修复前 package:http 默认 followRedirects=true，底层会自动跟随并把
 *      方法降级为 GET，制造"写成功假象"（manifest 静默丢失）；
 *   2. 307 同源真实跟随：method / body / Authorization 完整保留（无降级无丢凭据）；
 *   3. 跨源 307 拒绝：Authorization 不外泄给其他 host；
 *   4. 相对 Location 经 httpbun 真实逐跳解析；重定向环超限抛 ClientException。
 *
 * httpbun 端点（https://httpbun.com/）：
 *   /redirect-to?url=<相对或绝对>&status=<code>  任意状态码重定向
 *   /any                                         回显 method / headers（JSON）
 *   /redirect/{n}                                相对 Location 连续重定向 n 次
 *
 * 需要联网，默认跳过。启用：
 *   $env:HTTPBUN_LIVE_TEST="1"
 *   dart test packages/core/test/sync/http_util_live_test.dart
 *
 * CI 建议自建（docker run -p 80:80 sharat87/httpbun）后把 [kBaseUrl]
 * 指向本机实例，避免依赖公网服务。
 */

// Dart 原生导入
import 'dart:convert';
import 'dart:io';

// Package 导入
import 'package:test/test.dart';
import 'package:http/http.dart' as http;

// Project 导入
import 'package:core/src/sync/backends/http_util.dart';

/// 真实测试服务地址。
/// 自建 httpbun（docker run -p 80:80 sharat87/httpbun）后可改为 http://localhost
const String kBaseUrl = 'https://httpbun.com';

/// 经 [sendWithRedirectPolicy] 发送的真实请求
Future<http.Response> _real(
  String method,
  String pathOrUrl, {
  Map<String, String>? headers,
  List<int>? bodyBytes,
  required http.Client client,
}) {
  final url = pathOrUrl.startsWith('http')
      ? Uri.parse(pathOrUrl)
      : Uri.parse('$kBaseUrl$pathOrUrl');
  return sendWithRedirectPolicy(
    client: client,
    method: method,
    url: url,
    headers: headers,
    bodyBytes: bodyBytes,
    timeout: const Duration(seconds: 20),
  );
}

/// 大小写不敏感地从 httpbun 回显的 headers JSON 中取值
String? _headerOf(Map<String, dynamic> json, String name) {
  final headers = json['headers'];
  if (headers is! Map) return null;
  for (final e in headers.entries) {
    if (e.key.toString().toLowerCase() == name) return e.value.toString();
  }
  return null;
}

void main() {
  final liveEnabled = Platform.environment['HTTPBUN_LIVE_TEST'] == '1';

  group('sendWithRedirectPolicy 真实 httpbun 集成（HTTPBUN_LIVE_TEST=1 启用）', () {
    if (!liveEnabled) {
      test(
        '跳过：未设置 HTTPBUN_LIVE_TEST=1，不访问公网测试服务',
        () => print('SKIP: 设置 HTTPBUN_LIVE_TEST=1 运行真实网络测试'),
      );
      return;
    }

    late http.Client client;
    setUp(() => client = http.Client());
    tearDown(() => client.close());

    test(
      '对照：裸 client.get 默认自动跟随重定向（即被 followRedirects=false 关掉的传输行为）',
      () async {
        final res = await client.get(Uri.parse('$kBaseUrl/redirect/1'));
        expect(res.statusCode, 200);
      },
    );

    test('真实 307 同源跟随：method / body / Authorization 完整保留（无降级）', () async {
      final body = utf8.encode('secret-payload-42');
      final res = await _real(
        'PUT',
        '/redirect-to?url=/any&status=307',
        headers: {'Authorization': 'Bearer tok-123'},
        bodyBytes: body,
        client: client,
      );
      expect(res.statusCode, 200);
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      expect(json['method'], 'PUT');
      expect(_headerOf(json, 'authorization'), 'Bearer tok-123');
      expect(_headerOf(json, 'content-length'), '${body.length}');
    });

    test('真实 301 不跟随：写操作返回 301（修复前会被降级为 GET 假成功）', () async {
      final res = await _real(
        'PUT',
        '/redirect-to?url=/any&status=301',
        bodyBytes: utf8.encode('manifest-bytes'),
        client: client,
      );
      expect(res.statusCode, 301);
    });

    test('真实 303 不跟随：写操作返回 303（拒绝 See-Other 降级）', () async {
      final res = await _real(
        'POST',
        '/redirect-to?url=/any&status=303',
        bodyBytes: utf8.encode('{"op":"move"}'),
        client: client,
      );
      expect(res.statusCode, 303);
    });

    test('真实 302 跟随：GET 读操作可跟随到 /any 回显', () async {
      final res = await _real(
        'GET',
        '/redirect-to?url=/any&status=302',
        client: client,
      );
      expect(res.statusCode, 200);
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      expect(json['method'], 'GET');
    });

    test('真实 307 跨源不跟随：Authorization 不外泄给 example.com', () async {
      final res = await _real(
        'DELETE',
        '/redirect-to?url=https://example.com/&status=307',
        headers: {'Authorization': 'Bearer sekrit'},
        client: client,
      );
      expect(res.statusCode, 307);
    });

    test('真实相对 Location 逐跳解析：/redirect/2 跟随到最终 200', () async {
      final res = await _real('GET', '/redirect/2', client: client);
      expect(res.statusCode, 200);
    });

    test('真实重定向环超过 5 跳抛 ClientException（/redirect/6 超限）', () async {
      await expectLater(
        _real('GET', '/redirect/6', client: client),
        throwsA(isA<http.ClientException>()),
      );
    });
  });
}
