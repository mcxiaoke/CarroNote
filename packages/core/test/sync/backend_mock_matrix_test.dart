/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*
*/

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:core/core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('SafeServerBackend 状态码与行为矩阵 (MockClient)', () {
    const baseUrl = 'http://127.0.0.1:8080';
    const token = 'test-token-12345';

    test('init: 200 ok 成功初始化', () async {
      final client = MockClient((request) async {
        if (request.url.path == '/api/v2/health') {
          return http.Response('ok', 200);
        }
        return http.Response('not found', 404);
      });

      final backend = SafeServerBackend(
        baseUrl: baseUrl,
        token: token,
        client: client,
      );
      await backend.init();
      expect(await backend.ping(), isTrue);
    });

    test(
      'init: 500 / 非 ok body / 网络异常 抛 BackendUnavailableException',
      () async {
        final client500 = MockClient(
          (req) async => http.Response('error', 500),
        );
        final backend500 = SafeServerBackend(
          baseUrl: baseUrl,
          token: token,
          client: client500,
        );
        expect(
          () => backend500.init(),
          throwsA(isA<BackendUnavailableException>()),
        );

        final clientNotOk = MockClient(
          (req) async => http.Response('welcome', 200),
        );
        final backendNotOk = SafeServerBackend(
          baseUrl: baseUrl,
          token: token,
          client: clientNotOk,
        );
        expect(
          () => backendNotOk.init(),
          throwsA(isA<BackendUnavailableException>()),
        );

        final clientSocket = MockClient(
          (req) async => throw const SocketException('Connection refused'),
        );
        final backendSocket = SafeServerBackend(
          baseUrl: baseUrl,
          token: token,
          client: clientSocket,
        );
        expect(
          () => backendSocket.init(),
          throwsA(isA<BackendUnavailableException>()),
        );
      },
    );

    test('getManifest: 404 返回空字节与空 ETag', () async {
      final client = MockClient((req) async {
        if (req.url.path == '/api/v2/health') {
          return http.Response('ok', 200);
        }
        if (req.url.path == '/api/v2/manifest') {
          return http.Response('not found', 404);
        }
        return http.Response('', 500);
      });

      final backend = SafeServerBackend(
        baseUrl: baseUrl,
        token: token,
        client: client,
      );
      await backend.init();
      final result = await backend.getManifest();
      expect(result.ciphertext, isEmpty);
      expect(result.etag, equals(''));
    });

    test('getManifest: 401 抛 BackendUnavailableException', () async {
      final client = MockClient((req) async {
        if (req.url.path == '/api/v2/health') {
          return http.Response('ok', 200);
        }
        if (req.url.path == '/api/v2/manifest') {
          return http.Response('Unauthorized', 401);
        }
        return http.Response('', 500);
      });

      final backend = SafeServerBackend(
        baseUrl: baseUrl,
        token: token,
        client: client,
      );
      await backend.init();
      expect(
        () => backend.getManifest(),
        throwsA(
          isA<BackendUnavailableException>().having(
            (e) => e.message,
            'msg',
            contains('401'),
          ),
        ),
      );
    });

    test('getManifest: 200 但无 ETag 头 抛 SafeServer v2.2 required', () async {
      final client = MockClient((req) async {
        if (req.url.path == '/api/v2/health') {
          return http.Response('ok', 200);
        }
        if (req.url.path == '/api/v2/manifest') {
          return http.Response.bytes(
            Uint8List.fromList([1, 2, 3]),
            200,
          ); // 缺失 ETag 头
        }
        return http.Response('', 500);
      });

      final backend = SafeServerBackend(
        baseUrl: baseUrl,
        token: token,
        client: client,
      );
      await backend.init();
      expect(
        () => backend.getManifest(),
        throwsA(
          isA<BackendUnavailableException>().having(
            (e) => e.message,
            'msg',
            contains('SafeServer v2.2 required'),
          ),
        ),
      );
    });

    test(
      'putManifest: If-None-Match 与 If-Match 请求头装配及 412 Conflict 抛错',
      () async {
        late http.BaseRequest capturedRequest;
        var returnCode = 200;

        final client = MockClient((req) async {
          if (req.url.path == '/api/v2/health') {
            return http.Response('ok', 200);
          }
          if (req.url.path == '/api/v2/manifest') {
            capturedRequest = req;
            if (returnCode == 412) {
              return http.Response('Precondition failed', 412);
            }
            return http.Response(
              '',
              returnCode,
              headers: {'etag': '"new-etag-456"'},
            );
          }
          return http.Response('', 500);
        });

        final backend = SafeServerBackend(
          baseUrl: baseUrl,
          token: token,
          client: client,
        );
        await backend.init();

        // 1. 首次上传：expectedEtag 为空
        final etag1 = await backend.putManifest(
          Uint8List.fromList([10, 20]),
          '',
        );
        expect(etag1, equals('new-etag-456'));
        expect(capturedRequest.headers['If-None-Match'], equals('*'));
        expect(
          capturedRequest.headers['Authorization'],
          equals('Bearer test-token-12345'),
        );

        // 2. 带 expectedEtag
        await backend.putManifest(Uint8List.fromList([10, 20]), 'old-etag-123');
        expect(capturedRequest.headers['If-Match'], equals('"old-etag-123"'));

        // 3. 412 冲突
        returnCode = 412;
        expect(
          () =>
              backend.putManifest(Uint8List.fromList([10, 20]), 'old-etag-123'),
          throwsA(isA<ConflictException>()),
        );
      },
    );

    test('deleteBlob: 204/404/405 幂等成功，401 抛错', () async {
      var deleteCode = 204;
      final client = MockClient((req) async {
        if (req.url.path == '/api/v2/health') return http.Response('ok', 200);
        if (req.url.path.startsWith('/api/v2/blob/')) {
          return http.Response('', deleteCode);
        }
        return http.Response('', 500);
      });

      final backend = SafeServerBackend(
        baseUrl: baseUrl,
        token: token,
        client: client,
      );
      await backend.init();

      deleteCode = 204;
      await expectLater(backend.deleteBlob('hash1'), completes);

      deleteCode = 404;
      await expectLater(backend.deleteBlob('hash2'), completes);

      deleteCode = 405; // F-H08 静默降级
      await expectLater(backend.deleteBlob('hash3'), completes);

      deleteCode = 401;
      expect(
        () => backend.deleteBlob('hash4'),
        throwsA(isA<BackendUnavailableException>()),
      );
    });

    test('deleteBlobSoft: 409 降级为 deleteBlob', () async {
      var deleteCalled = false;
      final client = MockClient((req) async {
        if (req.url.path == '/api/v2/health') return http.Response('ok', 200);
        if (req.url.path.startsWith('/api/v2/resources/blobs-orphan')) {
          return http.Response('{"entries":[]}', 200);
        }
        if (req.url.path.startsWith('/api/v2/resources/blobs/')) {
          // move 返回 409
          return http.Response('Conflict', 409);
        }
        if (req.method == 'DELETE' &&
            req.url.path.startsWith('/api/v2/blob/')) {
          deleteCalled = true;
          return http.Response('', 204);
        }
        return http.Response('', 200);
      });

      final backend = SafeServerBackend(
        baseUrl: baseUrl,
        token: token,
        client: client,
      );
      await backend.init();
      await backend.deleteBlobSoft('hash123');
      expect(deleteCalled, isTrue, reason: '409 后应退化为 deleteBlob');
    });

    test('环形备份与安全路径校验', () async {
      final store = <String, List<int>>{};
      final client = MockClient((req) async {
        if (req.url.path == '/api/v2/health') return http.Response('ok', 200);
        final rel = req.url.path.replaceFirst('/api/v2/resources/', '');
        if (req.method == 'GET') {
          if (store.containsKey(rel)) {
            return http.Response.bytes(store[rel]!, 200);
          }
          return http.Response('', 404);
        }
        if (req.method == 'PUT') {
          store[rel] = req.bodyBytes;
          return http.Response('', 200);
        }
        if (req.method == 'POST' && rel == 'manifest-backup') {
          // propfind
          final entries = store.keys
              .where((k) => k.startsWith('manifest-backup/'))
              .map((k) => {'name': k.split('/').last})
              .toList();
          return http.Response(jsonEncode(entries), 200);
        }
        return http.Response('', 200);
      });

      final backend = SafeServerBackend(
        baseUrl: baseUrl,
        token: token,
        client: client,
      );
      await backend.init();

      // 备份 2 次
      await backend.backupManifest(Uint8List.fromList([1, 1, 1]));
      await backend.backupManifest(Uint8List.fromList([2, 2, 2]));

      final backups = await backend.listManifestBackups();
      expect(backups.isNotEmpty, isTrue);

      // 读取合法备份
      final content = await backend.readManifestBackup(backups.first);
      expect(content, isNotNull);

      // 路径穿越攻击拒绝
      final malicious = await backend.readManifestBackup('../evil');
      expect(malicious, isNull, reason: '非 manifest.bak-N 格式直接被正则拒绝');
    });

    test('putJournalObject 非 2xx 抛出 StateError (F-H07)', () async {
      final client = MockClient((req) async {
        if (req.url.path == '/api/v2/health') return http.Response('ok', 200);
        if (req.url.path.startsWith('/api/v2/resources/journal/')) {
          return http.Response('Server Error', 500);
        }
        return http.Response('', 200);
      });

      final backend = SafeServerBackend(
        baseUrl: baseUrl,
        token: token,
        client: client,
      );
      await backend.init();
      expect(
        () => backend.putJournalObject('entry-1.json', Uint8List.fromList([1])),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('WebDavBackend 状态码与行为矩阵 (MockClient)', () {
    const baseUrl = 'http://127.0.0.1:8080/dav';
    const user = 'testuser';
    const pass = 'testpass';

    test('init: MKCOL 201/405 通过，_probeEtagSupport 正常执行', () async {
      final client = MockClient((req) async {
        if (req.method == 'MKCOL') return http.Response('', 201);
        if (req.method == 'GET' && req.url.path.endsWith('/manifest.json')) {
          return http.Response('{}', 200, headers: {'etag': '"webdav-etag-1"'});
        }
        return http.Response('', 200);
      });

      final backend = WebDavBackend(
        baseUrl: baseUrl,
        username: user,
        password: pass,
        client: client,
      );
      await backend.init();
      expect(backend.isEtagSupported, isTrue);
    });

    test('getManifest: 200 无 ETag 时 fallback 为内容 SHA-256', () async {
      final manifestBytes = utf8.encode('{"schemaVersion":5}');
      final client = MockClient((req) async {
        if (req.method == 'MKCOL') return http.Response('', 405);
        if (req.url.path.endsWith('/manifest.json')) {
          return http.Response.bytes(manifestBytes, 200); // 缺失 ETag
        }
        return http.Response('', 200);
      });

      final backend = WebDavBackend(
        baseUrl: baseUrl,
        username: user,
        password: pass,
        client: client,
      );
      await backend.init();
      final result = await backend.getManifest();
      expect(result.etag.isNotEmpty, isTrue);
      expect(backend.isEtagSupported, isFalse);
    });

    test('putManifest: 412 / 409 抛 ConflictException', () async {
      var putCode = 412;
      final client = MockClient((req) async {
        if (req.method == 'MKCOL') return http.Response('', 201);
        if (req.method == 'GET') return http.Response('', 404);
        if (req.method == 'PROPFIND') return http.Response('<D:getetag/>', 207);
        if (req.method == 'PUT') return http.Response('Conflict', putCode);
        return http.Response('', 200);
      });

      final backend = WebDavBackend(
        baseUrl: baseUrl,
        username: user,
        password: pass,
        client: client,
      );
      await backend.init();

      putCode = 412;
      expect(
        () => backend.putManifest(Uint8List.fromList([1, 2]), 'etag1'),
        throwsA(isA<ConflictException>()),
      );

      putCode = 409;
      expect(
        () => backend.putManifest(Uint8List.fromList([1, 2]), 'etag1'),
        throwsA(isA<ConflictException>()),
      );
    });

    test('listBlobs: PROPFIND XML 解析、64-hex 过滤与 URL 解码', () async {
      const validHash1 =
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
      const validHash2 =
          'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';
      const xmlResponse = '''<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/safenotes-vault/blobs/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef</D:href>
  </D:response>
  <D:response>
    <D:href>/dav/safenotes-vault/blobs/abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789</D:href>
  </D:response>
  <D:response>
    <D:href>/dav/safenotes-vault/blobs/not-a-valid-hash</D:href>
  </D:response>
</D:multistatus>''';

      final client = MockClient((req) async {
        if (req.method == 'MKCOL') return http.Response('', 201);
        if (req.method == 'GET') return http.Response('', 404);
        if (req.method == 'PROPFIND' && req.url.path.endsWith('/blobs')) {
          return http.Response(xmlResponse, 207);
        }
        return http.Response('', 200);
      });

      final backend = WebDavBackend(
        baseUrl: baseUrl,
        username: user,
        password: pass,
        client: client,
      );
      await backend.init();
      final blobs = await backend.listBlobs();
      expect(blobs.length, equals(2));
      expect(blobs.contains(validHash1), isTrue);
      expect(blobs.contains(validHash2), isTrue);
      expect(blobs.contains('not-a-valid-hash'), isFalse);
    });

    test('deleteBlobSoft: COPY 失败退化为硬删除且不抛异常', () async {
      var deleteCalled = false;
      final client = MockClient((req) async {
        if (req.method == 'MKCOL') return http.Response('', 201);
        if (req.method == 'GET') return http.Response('', 404);
        if (req.method == 'COPY') return http.Response('Copy failed', 500);
        if (req.method == 'DELETE') {
          deleteCalled = true;
          return http.Response('', 204);
        }
        return http.Response('', 200);
      });

      final backend = WebDavBackend(
        baseUrl: baseUrl,
        username: user,
        password: pass,
        client: client,
      );
      await backend.init();
      await expectLater(backend.deleteBlobSoft('somehash'), completes);
      expect(deleteCalled, isTrue, reason: 'COPY 失败后应退化为 DELETE');
    });
  });
}
