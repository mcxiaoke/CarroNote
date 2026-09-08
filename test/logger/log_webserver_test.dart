/*
 * Copyright (C) mcxiaoke 2026 - All Rights Reserved.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 * You may use, distribute and modify this code under the
 * terms of the GPL-3.0+ license.
 */

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/src/logger/log_webserver.dart';

class _RealHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpClient client;
  late int serverPort;
  late String serverToken;

  setUpAll(() async {
    HttpOverrides.global = _RealHttpOverrides();
    LogWebServer.enableWebServer = true;
    SharedPreferences.setMockInitialValues({
      'test_key': 'test_val',
      'managedTags': <String>['个人', '工作'],
      'locale': 'zh_CN',
    });
    await PreferencesStorage.init();

    // 绑定高位测试端口
    serverPort = await LogWebServer.instance.start(port: 19888);
    serverToken = LogWebServer.instance.token!;
    client = HttpClient();
  });

  tearDownAll(() async {
    client.close(force: true);
    await LogWebServer.instance.stop();
    LogWebServer.enableWebServer = false;
    HttpOverrides.global = null;
  });

  group('LogWebServer 安全与端点验证', () {
    test('OPTIONS 预检请求返回 204 与 CORS 跨域响应头', () async {
      final req = await client.openUrl(
        'OPTIONS',
        Uri.parse('http://127.0.0.1:$serverPort/api/status'),
      );
      final res = await req.close();
      expect(res.statusCode, HttpStatus.noContent);
      expect(res.headers.value('access-control-allow-origin'), '*');
      expect(
        res.headers.value('access-control-allow-methods'),
        contains('GET'),
      );
    });

    test('缺失或无效 Token 请求被拦截并返回 403 Forbidden', () async {
      // 1. 无 token
      final reqNoToken = await client.getUrl(
        Uri.parse('http://127.0.0.1:$serverPort/api/status'),
      );
      final resNoToken = await reqNoToken.close();
      expect(resNoToken.statusCode, HttpStatus.forbidden);

      // 2. 错误 token
      final reqBadToken = await client.getUrl(
        Uri.parse(
          'http://127.0.0.1:$serverPort/api/status?token=wrong_token_value',
        ),
      );
      final resBadToken = await reqBadToken.close();
      expect(resBadToken.statusCode, HttpStatus.forbidden);
    });

    test('支持 Query 与 token Header 两种鉴权方式通过验证', () async {
      // 1. Query 参数 ?token=...
      final reqQuery = await client.getUrl(
        Uri.parse('http://127.0.0.1:$serverPort/api/status?token=$serverToken'),
      );
      final resQuery = await reqQuery.close();
      expect(resQuery.statusCode, HttpStatus.ok);

      // 2. HTTP Header token: ...
      final reqHeader = await client.getUrl(
        Uri.parse('http://127.0.0.1:$serverPort/api/status'),
      );
      reqHeader.headers.set('token', serverToken);
      final resHeader = await reqHeader.close();
      expect(resHeader.statusCode, HttpStatus.ok);
    });

    test('/logfile 端点对目录穿越攻击拦截并返回 400 Bad Request', () async {
      // 1. 包含 ..
      final reqDotDot = await client.getUrl(
        Uri.parse(
          'http://127.0.0.1:$serverPort/logfile?token=$serverToken&name=../../etc/passwd',
        ),
      );
      final resDotDot = await reqDotDot.close();
      expect(resDotDot.statusCode, HttpStatus.badRequest);

      // 2. 包含正斜杠 /
      final reqSlash = await client.getUrl(
        Uri.parse(
          'http://127.0.0.1:$serverPort/logfile?token=$serverToken&name=subdir/app.log',
        ),
      );
      final resSlash = await reqSlash.close();
      expect(resSlash.statusCode, HttpStatus.badRequest);

      // 3. 包含反斜杠 \
      final reqBackslash = await client.getUrl(
        Uri.parse(
          'http://127.0.0.1:$serverPort/logfile?token=$serverToken&name=subdir\\app.log',
        ),
      );
      final resBackslash = await reqBackslash.close();
      expect(resBackslash.statusCode, HttpStatus.badRequest);
    });

    test('/api/prefs 端点返回有效 SharedPreferences JSON 快照', () async {
      final req = await client.getUrl(
        Uri.parse('http://127.0.0.1:$serverPort/api/prefs?token=$serverToken'),
      );
      final res = await req.close();
      expect(res.statusCode, HttpStatus.ok);

      final body = await utf8.decoder.bind(res).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      expect(json, isA<Map<String, dynamic>>());
      expect(json['test_key'], 'test_val');
    });

    test('/logs 端点返回纯文本响应', () async {
      final req = await client.getUrl(
        Uri.parse('http://127.0.0.1:$serverPort/logs?token=$serverToken'),
      );
      final res = await req.close();
      expect(res.statusCode, HttpStatus.ok);
      expect(res.headers.contentType?.mimeType, 'text/plain');
    });

    test('/api/download/sp 中文内容以 UTF-8 返回（Latin1 编码回归）', () async {
      final req = await client.getUrl(
        Uri.parse(
          'http://127.0.0.1:$serverPort/api/download/sp?token=$serverToken',
        ),
      );
      final res = await req.close();
      expect(res.statusCode, HttpStatus.ok);
      expect(res.headers.contentType?.mimeType, 'application/json');

      final body = await utf8.decoder.bind(res).join();
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      expect((decoded['managedTags'] as List).first, '个人');
    });

    test('/api/download/all 打包 ZIP 返回且可解出成员', () async {
      final req = await client.getUrl(
        Uri.parse(
          'http://127.0.0.1:$serverPort/api/download/all?token=$serverToken',
        ),
      );
      final res = await req.close();
      expect(res.statusCode, HttpStatus.ok);
      expect(res.headers.contentType?.mimeType, 'application/zip');

      final chunks = <int>[];
      await for (final chunk in res) {
        chunks.addAll(chunk);
      }
      final zipBytes = Uint8List.fromList(chunks);
      final archive = ZipDecoder().decodeBytes(zipBytes);
      final names = archive.files.map((f) => f.name).toSet();
      expect(names, contains('shared_preferences.json'));
      final spFile = archive.files.firstWhere(
        (f) => f.name == 'shared_preferences.json',
      );
      final spContent = utf8.decode(spFile.content as List<int>);
      expect(spContent, contains('个人'));
    });
  });
}
