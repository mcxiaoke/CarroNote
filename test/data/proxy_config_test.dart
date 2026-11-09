/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*
*/

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:safenotes/data/proxy_config.dart';
import 'package:safenotes/src/platform/http_client_factory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PAC rule formatting and host:port parsing', () {
    test('formatPacRule handles various common proxy address formats', () {
      expect(formatPacRule('127.0.0.1:7890'), 'PROXY 127.0.0.1:7890;');
      expect(formatPacRule('http://127.0.0.1:7890'), 'PROXY 127.0.0.1:7890;');
      expect(
        formatPacRule('https://proxy.example.com:8080/'),
        'PROXY proxy.example.com:8080;',
      );
      expect(formatPacRule('socks5://127.0.0.1:1080'), 'SOCKS 127.0.0.1:1080;');
      expect(formatPacRule('socks://127.0.0.1:1080/'), 'SOCKS 127.0.0.1:1080;');
      expect(
        formatPacRule('PROXY 192.168.1.1:8888;'),
        'PROXY 192.168.1.1:8888;',
      );
      expect(
        formatPacRule('user:pass@127.0.0.1:7890'),
        'PROXY 127.0.0.1:7890;',
      );
      expect(formatPacRule(''), isNull);
      expect(formatPacRule('   '), isNull);
    });

    test('parseHostAndPort correctly extracts host and port', () {
      final res1 = parseHostAndPort('127.0.0.1:7890');
      expect(res1, isNotNull);
      expect(res1!.host, '127.0.0.1');
      expect(res1.port, 7890);

      final res2 = parseHostAndPort('http://localhost:8080/path');
      expect(res2, isNotNull);
      expect(res2!.host, 'localhost');
      expect(res2.port, 8080);

      final res3 = parseHostAndPort('socks5://proxy.company.internal:1080');
      expect(res3, isNotNull);
      expect(res3!.host, 'proxy.company.internal');
      expect(res3.port, 1080);

      final res4 = parseHostAndPort('[::1]:7890');
      expect(res4, isNotNull);
      expect(res4!.host, '::1');
      expect(res4.port, 7890);

      expect(parseHostAndPort(''), isNull);
      expect(parseHostAndPort('nohostport'), isNull);
      expect(parseHostAndPort('localhost:notaport'), isNull);
      expect(parseHostAndPort('localhost:999999'), isNull);
    });
  });

  group('ProxyConfig', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await ProxyConfig.init();
    });

    test('default state is disabled with empty address', () {
      expect(ProxyConfig.isProxyEnabled, isFalse);
      expect(ProxyConfig.proxyAddress, isEmpty);
    });

    test('setProxyEnabled and setProxyAddress persist values', () async {
      await ProxyConfig.setProxyEnabled(true);
      await ProxyConfig.setProxyAddress('127.0.0.1:7890');

      expect(ProxyConfig.isProxyEnabled, isTrue);
      expect(ProxyConfig.proxyAddress, '127.0.0.1:7890');

      // Reload test
      await ProxyConfig.reload();
      expect(ProxyConfig.isProxyEnabled, isTrue);
      expect(ProxyConfig.proxyAddress, '127.0.0.1:7890');
    });

    test('redactProxyForLog strips credentials from log strings', () {
      expect(
        ProxyConfig.redactProxyForLog('http://user:pass@127.0.0.1:7890'),
        'http://***@127.0.0.1:7890',
      );
      expect(
        ProxyConfig.redactProxyForLog(
          'socks5://alice:secret123@myproxy.io:1080',
        ),
        'socks5://***@myproxy.io:1080',
      );
      expect(ProxyConfig.redactProxyForLog('127.0.0.1:7890'), '127.0.0.1:7890');
      expect(ProxyConfig.redactProxyForLog(''), '');
    });

    test('createHttpClient returns functional client', () {
      final client = ProxyConfig.createHttpClient();
      expect(client, isNotNull);
      client.close();
    });
  });
}
