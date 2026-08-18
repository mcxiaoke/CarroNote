/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

/*
 * sendWithRedirectPolicy 单元测试（B-H1 HTTP 重定向修复）
 *
 * 用 MockClient 模拟服务端重定向，验证重定向策略：
 *   - 所有请求 followRedirects=false（底层不再自动跟随）；
 *   - 写操作（PUT/DELETE/POST）遇 301/302/303 绝不跟随（杜绝"降级为 GET
 *     造成写成功假象"），仅 307/308 且严格同源时跟随且保留 method/body/认证头；
 *   - 读取类（GET/PROPFIND/MKCOL）允许 301/302/303/307/308 同源跟随，
 *     并放开 http→https（相同 host:port）安全升格跟随；
 *   - 跨源一律不跟随（杜绝 Authorization 泄露给第三方 host）；
 *   - 3xx 无 Location 原样返回；重定向环超过跳数上限抛 ClientException。
 *
 * 运行：dart test packages/core/test/sync/http_util_test.dart
 */

// Dart 原生导入
import 'dart:convert';

// Package 导入
import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// Project 导入
import 'package:core/src/sync/backends/http_util.dart';

/// 测试用统一发送入口（默认超时为助手默认值）
Future<http.Response> _send(
  String method,
  Uri url, {
  Map<String, String>? headers,
  List<int>? bodyBytes,
  required http.Client client,
}) {
  return sendWithRedirectPolicy(
    client: client,
    method: method,
    url: url,
    headers: headers,
    bodyBytes: bodyBytes,
  );
}

void main() {
  group('sendWithRedirectPolicy 重定向策略', () {
    test('所有发出的请求 followRedirects=false（禁止底层自动跟随降级）', () async {
      var sawFlag = false;
      final client = MockClient((req) async {
        if (!req.followRedirects) sawFlag = true;
        return http.Response('', 200);
      });
      final res = await _send(
        'PUT',
        Uri.parse('https://example.com/manifest'),
        bodyBytes: utf8.encode('data'),
        client: client,
      );
      expect(res.statusCode, 200);
      expect(sawFlag, isTrue);
    });

    test('PUT 301 不跟随：写操作不允许被降级为 GET', () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        expect(req.method, 'PUT');
        return http.Response(
          '',
          301,
          headers: {'location': 'https://example.com/other-manifest'},
        );
      });
      final res = await _send(
        'PUT',
        Uri.parse('https://example.com/manifest'),
        bodyBytes: utf8.encode('data'),
        client: client,
      );
      expect(calls, 1);
      expect(res.statusCode, 301);
    });

    test('POST 301 不跟随（SafeServer 资源层操作同样不被降级）', () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        return http.Response(
          '',
          301,
          headers: {'location': 'https://example.com/api/v2/resources/other'},
        );
      });
      final res = await _send(
        'POST',
        Uri.parse('https://example.com/api/v2/resources/manifest'),
        bodyBytes: utf8.encode('{"op":"move"}'),
        client: client,
      );
      expect(calls, 1);
      expect(res.statusCode, 301);
    });

    test('PUT 307 同源跟随：保持 method / body / Authorization', () async {
      late String secondMethod;
      late String secondUrl;
      late String secondAuth;
      late List<int> secondBody;
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        if (calls == 1) {
          return http.Response(
            '',
            307,
            headers: {'location': 'https://example.com/manifest-2'},
          );
        }
        secondMethod = req.method;
        secondUrl = req.url.toString();
        secondAuth = req.headers['Authorization'] ?? '';
        secondBody = req.bodyBytes;
        return http.Response('', 201, headers: {'etag': '"abc"'});
      });
      final res = await _send(
        'PUT',
        Uri.parse('https://example.com/manifest'),
        headers: {'Authorization': 'Bearer t0kEn'},
        bodyBytes: utf8.encode('secret-payload'),
        client: client,
      );
      expect(res.statusCode, 201);
      expect(calls, 2);
      expect(secondMethod, 'PUT');
      expect(secondUrl, 'https://example.com/manifest-2');
      expect(secondAuth, 'Bearer t0kEn');
      expect(utf8.decode(secondBody), 'secret-payload');
    });

    test('DELETE 307 同源跟随（语义保留）', () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        if (calls == 1) {
          return http.Response(
            '',
            307,
            headers: {'location': 'https://example.com/blob-2'},
          );
        }
        return http.Response('', 204);
      });
      final res = await _send(
        'DELETE',
        Uri.parse('https://example.com/blob'),
        client: client,
      );
      expect(calls, 2);
      expect(res.statusCode, 204);
    });

    test('PUT 307 跨源不跟随：Authorization 不会发给其他 host', () async {
      var calls = 0;
      String? seenAuth;
      final client = MockClient((req) async {
        calls++;
        seenAuth = req.headers['Authorization'];
        return http.Response(
          '',
          307,
          headers: {'location': 'https://evil.example.com/steal'},
        );
      });
      final res = await _send(
        'PUT',
        Uri.parse('https://example.com/manifest'),
        headers: {'Authorization': 'Basic Zm9vOmJhcg=='},
        client: client,
      );
      expect(calls, 1);
      expect(res.statusCode, 307);
      expect(seenAuth, 'Basic Zm9vOmJhcg==');
    });

    test('GET 301 同源跟随（读操作允许，路径规范化）', () async {
      var calls = 0;
      String secondUrl = '';
      final client = MockClient((req) async {
        calls++;
        if (calls == 1) {
          return http.Response('', 301, headers: {'location': '/blobs/'});
        }
        secondUrl = req.url.toString();
        return http.Response('ok-body', 200);
      });
      final res = await _send(
        'GET',
        Uri.parse('https://example.com/blobs'),
        client: client,
      );
      expect(res.statusCode, 200);
      expect(res.body, 'ok-body');
      expect(calls, 2);
      expect(secondUrl, 'https://example.com/blobs/');
    });

    test('GET 301 http→https 同 host 跟随（放宽的升格）', () async {
      var calls = 0;
      Uri secondUrl = Uri();
      final client = MockClient((req) async {
        calls++;
        if (calls == 1) {
          return http.Response(
            '',
            301,
            headers: {'location': 'https://dav.example.com/manifest.json'},
          );
        }
        secondUrl = req.url;
        return http.Response('', 200);
      });
      final res = await _send(
        'GET',
        Uri.parse('http://dav.example.com/manifest.json'),
        client: client,
      );
      expect(calls, 2);
      expect(secondUrl.scheme, 'https');
      expect(res.statusCode, 200);
    });

    test('GET 301 http→https 端口变化不跟随', () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        return http.Response(
          '',
          301,
          headers: {'location': 'https://dav.example.com:8443/manifest.json'},
        );
      });
      final res = await _send(
        'GET',
        Uri.parse('http://dav.example.com:8080/manifest.json'),
        client: client,
      );
      expect(calls, 1);
      expect(res.statusCode, 301);
    });

    test('GET 301 http→https 显式同端口跟随', () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        if (calls == 1) {
          return http.Response(
            '',
            301,
            headers: {'location': 'https://host:8443/x'},
          );
        }
        return http.Response('', 200);
      });
      final res = await _send(
        'GET',
        Uri.parse('http://host:8443/x'),
        client: client,
      );
      expect(calls, 2);
      expect(res.statusCode, 200);
    });

    test('PROPFIND 301 同源跟随：方法与 body 保留', () async {
      var calls = 0;
      final seenMethods = <String>[];
      List<int>? firstBody;
      final client = MockClient((req) async {
        calls++;
        seenMethods.add(req.method);
        if (calls == 1) {
          firstBody = req.bodyBytes;
          return http.Response(
            '',
            301,
            headers: {'location': 'https://example.com/x/'},
          );
        }
        return http.Response('<D:multistatus/>', 207);
      });
      final body = utf8.encode('<propfind/>');
      final res = await _send(
        'PROPFIND',
        Uri.parse('https://example.com/x'),
        bodyBytes: body,
        client: client,
      );
      expect(calls, 2);
      expect(seenMethods, ['PROPFIND', 'PROPFIND']);
      expect(res.statusCode, 207);
      expect(firstBody, body);
    });

    test('MKCOL 301 http→https 升格跟随', () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        expect(req.method, 'MKCOL');
        if (calls == 1) {
          return http.Response(
            '',
            301,
            headers: {'location': 'https://dav.example.com/new'},
          );
        }
        return http.Response('', 405);
      });
      final res = await _send(
        'MKCOL',
        Uri.parse('http://dav.example.com/new'),
        client: client,
      );
      expect(calls, 2);
      expect(res.statusCode, 405);
    });

    test('GET 302 同源跟随（读操作允许 302）', () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        if (calls == 1) {
          return http.Response('', 302, headers: {'location': '/blobs/'});
        }
        return http.Response('', 200);
      });
      final res = await _send(
        'GET',
        Uri.parse('https://example.com/blobs'),
        client: client,
      );
      expect(calls, 2);
      expect(res.statusCode, 200);
    });

    test('DELETE 303 不跟随（写操作遇 303 同样拒绝方法降级）', () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        expect(req.method, 'DELETE');
        return http.Response('', 303, headers: {'location': '/deleted'});
      });
      final res = await _send(
        'DELETE',
        Uri.parse('https://example.com/note'),
        client: client,
      );
      expect(calls, 1);
      expect(res.statusCode, 303);
    });

    test('GET 多跳重定向链全跟随（302 → 307 → 200）', () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        switch (calls) {
          case 1:
            return http.Response('', 302, headers: {'location': '/hop2'});
          case 2:
            return http.Response('', 307, headers: {'location': '/hop3'});
          default:
            return http.Response('final', 200);
        }
      });
      final res = await _send(
        'GET',
        Uri.parse('https://example.com/start'),
        client: client,
      );
      expect(res.statusCode, 200);
      expect(res.body, 'final');
      expect(calls, 3);
    });

    test('GET https→http 跨协议降级不跟随（凭据不落明文信道）', () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        return http.Response(
          '',
          302,
          headers: {'location': 'http://example.com/plain'},
        );
      });
      final res = await _send(
        'GET',
        Uri.parse('https://example.com/start'),
        headers: {'Authorization': 'Bearer sekrit'},
        client: client,
      );
      expect(calls, 1);
      expect(res.statusCode, 302);
    });

    test('3xx 无 Location 原样返回（无从跟随）', () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        return http.Response('', 302);
      });
      final res = await _send(
        'PUT',
        Uri.parse('https://example.com/m'),
        client: client,
      );
      expect(calls, 1);
      expect(res.statusCode, 302);
    });

    test('重定向环超过跳数上限抛 ClientException', () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        return http.Response(
          '',
          307,
          headers: {'location': 'https://example.com/loop'},
        );
      });
      await expectLater(
        _send('PUT', Uri.parse('https://example.com/loop'), client: client),
        throwsA(isA<http.ClientException>()),
      );
      expect(calls, greaterThan(kRedirectMaxHops));
    });
  });
}
