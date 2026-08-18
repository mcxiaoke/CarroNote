/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

/*
 * WebDavBackend / SafeServerBackend 重定向防护单元测试（B-H1 HTTP 重定向修复）
 *
 * 用 MockClient 模拟服务端 3xx，验证两个后端的写路径：
 *   - putManifest / putBlob 遇 301 不跟随 → 抛 BackendUnavailableException
 *     （拒绝"降级为 GET 后 200 假成功"的 manifest 静默丢失；验证只发 1 次请求）；
 *   - putManifest 307 同源跟随 → 保持 PUT 方法 + 密文 body + Authorization
 *     （验证不降级、不丢凭据），并从新 ETag 头取乐观锁；
 *
 * 运行：dart test packages/core/test/sync/backend_redirect_test.dart
 */

// Dart 原生导入
import 'dart:convert';
import 'dart:typed_data';

// Package 导入
import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// Project 导入
import 'package:core/core.dart';

void main() {
  group('WebDavBackend 重定向防护（B-H1）', () {
    const base = 'https://dav.example.com/remote.php/dav/';
    const vaultPath = '/remote.php/dav/safenotes-vault/manifest-2.json';

    /// init 环境 handler：MKCOL→405（目录已存在）、GET manifest→404（首次）、
    /// PROPFIND→207（ETag 探测），把 PUT 交给 [onPut] 具体模拟
    MockClient davClient(Future<http.Response> Function(http.Request) onPut) {
      return MockClient((req) async {
        if (req.method == 'MKCOL') return http.Response('', 405);
        if (req.method == 'PROPFIND') {
          return http.Response('<D:multistatus/>', 207);
        }
        if (req.method == 'GET' && req.url.path.endsWith('manifest.json')) {
          return http.Response('', 404);
        }
        if (req.method == 'PUT') return onPut(req);
        return http.Response('', 500);
      });
    }

    test('putManifest 301 不跟随：抛 BackendUnavailableException（拒绝假成功）', () async {
      var putCalls = 0;
      final backend = WebDavBackend(
        baseUrl: base,
        username: 'u',
        password: 'p',
        client: davClient((req) async {
          putCalls++;
          expect(req.method, 'PUT');
          return http.Response(
            '',
            301,
            headers: {
              'location': 'https://dav.example.com/wrong/manifest.json',
            },
          );
        }),
      );
      await backend.init();
      await expectLater(
        backend.putManifest(Uint8List.fromList([1, 2, 3]), ''),
        throwsA(isA<BackendUnavailableException>()),
      );
      expect(putCalls, 1);
    });

    test('putManifest 307 同源跟随：保持 PUT + body + Authorization', () async {
      var putCalls = 0;
      String secondMethod = '';
      String secondUrl = '';
      String secondAuth = '';
      List<int> secondBody = const [];
      final backend = WebDavBackend(
        baseUrl: base,
        username: 'u',
        password: 'p',
        client: davClient((req) async {
          putCalls++;
          if (putCalls == 1) {
            return http.Response('', 307, headers: {'location': vaultPath});
          }
          secondMethod = req.method;
          secondUrl = req.url.toString();
          secondAuth = req.headers['Authorization'] ?? '';
          secondBody = req.bodyBytes;
          return http.Response('', 200, headers: {'etag': '"new-etag"'});
        }),
      );
      await backend.init();
      final manifest = Uint8List.fromList([10, 20, 30]);
      final etag = await backend.putManifest(manifest, 'etag123');
      expect(etag, 'new-etag');
      expect(putCalls, 2);
      expect(secondMethod, 'PUT');
      expect(secondUrl, 'https://dav.example.com$vaultPath');
      expect(secondAuth, 'Basic ${base64Encode(utf8.encode('u:p'))}');
      expect(secondBody, manifest);
    });

    test('putBlob 301 不跟随：抛 BackendUnavailableException', () async {
      var putCalls = 0;
      final backend = WebDavBackend(
        baseUrl: base,
        username: 'u',
        password: 'p',
        client: davClient((req) async {
          putCalls++;
          return http.Response(
            '',
            301,
            headers: {'location': 'https://dav.example.com/wrong/blob'},
          );
        }),
      );
      await backend.init();
      await expectLater(
        backend.putBlob('a' * 64, Uint8List.fromList([5, 6, 7])),
        throwsA(isA<BackendUnavailableException>()),
      );
      expect(putCalls, 1);
    });
  });

  group('SafeServerBackend 重定向防护（B-H1）', () {
    const base = 'https://safe.example.com';

    /// init 环境 handler：health 返回 ok，PUT 交给 [onPut] 具体模拟
    MockClient safeClient(Future<http.Response> Function(http.Request) onPut) {
      return MockClient((req) async {
        if (req.url.path.endsWith('/health')) return http.Response('ok', 200);
        if (req.method == 'PUT') return onPut(req);
        return http.Response('', 500);
      });
    }

    test('putManifest 301 不跟随：抛 BackendUnavailableException（拒绝假成功）', () async {
      var putCalls = 0;
      final backend = SafeServerBackend(
        baseUrl: base,
        token: 'sekrit',
        client: safeClient((req) async {
          putCalls++;
          return http.Response(
            '',
            301,
            headers: {
              'location': 'https://safe.example.com/api/v2/manifest-bad',
            },
          );
        }),
      );
      await backend.init();
      await expectLater(
        backend.putManifest(Uint8List.fromList([5, 6, 7]), 'etag-1'),
        throwsA(isA<BackendUnavailableException>()),
      );
      expect(putCalls, 1);
    });

    test('putManifest 307 同源跟随：保持 PUT + body + Bearer 认证头', () async {
      var putCalls = 0;
      String secondUrl = '';
      String secondAuth = '';
      List<int> secondBody = const [];
      final backend = SafeServerBackend(
        baseUrl: base,
        token: 'sekrit',
        client: safeClient((req) async {
          putCalls++;
          if (putCalls == 1) {
            return http.Response(
              '',
              307,
              headers: {
                'location': 'https://safe.example.com/api/v2/manifest-2',
              },
            );
          }
          secondUrl = req.url.toString();
          secondAuth = req.headers['Authorization'] ?? '';
          secondBody = req.bodyBytes;
          return http.Response('', 200, headers: {'etag': '"etag-x"'});
        }),
      );
      await backend.init();
      final manifest = Uint8List.fromList([70, 80, 90]);
      final etag = await backend.putManifest(manifest, 'etag-1');
      expect(etag, 'etag-x');
      expect(putCalls, 2);
      expect(secondUrl, 'https://safe.example.com/api/v2/manifest-2');
      expect(secondAuth, 'Bearer sekrit');
      expect(secondBody, manifest);
    });

    test('putBlob 301 不跟随：抛 BackendUnavailableException', () async {
      var putCalls = 0;
      final backend = SafeServerBackend(
        baseUrl: base,
        token: 'sekrit',
        client: safeClient((req) async {
          putCalls++;
          return http.Response(
            '',
            301,
            headers: {'location': 'https://safe.example.com/api/v2/blob-bad'},
          );
        }),
      );
      await backend.init();
      await expectLater(
        backend.putBlob('b' * 64, Uint8List.fromList([1, 2])),
        throwsA(isA<BackendUnavailableException>()),
      );
      expect(putCalls, 1);
    });
  });
}
