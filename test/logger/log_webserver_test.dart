import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/src/logger/log_webserver.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    LogWebServer.enableWebServer = true;
  });

  test('/api/download/sp 中文内容以 UTF-8 返回（Latin1 编码回归）', () async {
    SharedPreferences.setMockInitialValues({
      'managedTags': <String>['个人', '工作'],
      'locale': 'zh_CN',
    });
    await PreferencesStorage.init();

    final port = await LogWebServer.instance.start(port: 18888);
    try {
      // TestWidgetsFlutterBinding 会劫持 HttpClient（一律返回 400），
      // 故用原始 socket 直接发送 HTTP 请求验证真实响应
      final socket = await Socket.connect('127.0.0.1', port);
      socket.write(
        'GET /api/download/sp?token=${LogWebServer.instance.token} HTTP/1.0\r\n'
        'Host: 127.0.0.1:$port\r\n'
        'Connection: close\r\n'
        '\r\n',
      );
      await socket.flush();

      final chunks = <int>[];
      await for (final chunk in socket) {
        chunks.addAll(chunk);
      }
      final raw = utf8.decode(chunks);
      final headerEnd = raw.indexOf('\r\n\r\n');
      final headers = raw.substring(0, headerEnd);
      final body = raw.substring(headerEnd + 4);

      expect(headers, contains('200 OK'));
      expect(headers.toLowerCase(), contains('charset=utf-8'));
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      expect((decoded['managedTags'] as List).first, '个人');
    } finally {
      await LogWebServer.instance.stop();
    }
  });

  test('/api/download/all 打包 ZIP 返回且可解出成员', () async {
    SharedPreferences.setMockInitialValues({
      'managedTags': <String>['个人'],
    });
    await PreferencesStorage.init();

    final port = await LogWebServer.instance.start(port: 18889);
    try {
      final socket = await Socket.connect('127.0.0.1', port);
      socket.write(
        'GET /api/download/all?token=${LogWebServer.instance.token} HTTP/1.0\r\n'
        'Host: 127.0.0.1:$port\r\n'
        'Connection: close\r\n'
        '\r\n',
      );
      await socket.flush();

      final chunks = <int>[];
      await for (final chunk in socket) {
        chunks.addAll(chunk);
      }
      // 响应体是二进制（ZIP），按字节切分 header/body
      final raw = Uint8List.fromList(chunks);
      final headerEnd = _findHeaderEnd(raw);
      expect(headerEnd, greaterThan(0));
      final headers = ascii.decode(raw.sublist(0, headerEnd));
      final zipBytes = raw.sublist(headerEnd + 4);

      expect(headers, contains('200 OK'));
      expect(headers.toLowerCase(), contains('application/zip'));
      // 必须带 Content-Length（否则 chunked 编码会让部分下载工具挂起）
      expect(
        headers.toLowerCase(),
        contains('content-length: ${zipBytes.length}'),
      );

      final archive = ZipDecoder().decodeBytes(zipBytes);
      final names = archive.files.map((f) => f.name).toSet();
      expect(names, contains('shared_preferences.json'));
      final spFile = archive.files.firstWhere(
        (f) => f.name == 'shared_preferences.json',
      );
      final spContent = utf8.decode(spFile.content as List<int>);
      expect(spContent, contains('个人'));
    } finally {
      await LogWebServer.instance.stop();
    }
  });
}

/// 在原始 HTTP 响应字节中定位 "\r\n\r\n"（header 与 body 分隔符）位置
int _findHeaderEnd(List<int> bytes) {
  for (var i = 0; i + 3 < bytes.length; i++) {
    if (bytes[i] == 13 &&
        bytes[i + 1] == 10 &&
        bytes[i + 2] == 13 &&
        bytes[i + 3] == 10) {
      return i;
    }
  }
  return -1;
}
