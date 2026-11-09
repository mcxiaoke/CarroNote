/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*
*/

import 'package:http/http.dart' as http;

String? formatPacRule(String input) => null;

({String host, int port})? parseHostAndPort(String input) => null;

http.Client createPlatformHttpClient({
  bool proxyEnabled = false,
  String proxyAddress = '',
  Duration connectionTimeout = const Duration(seconds: 10),
}) {
  return http.Client();
}

Future<({bool success, String? message})> testProxyConnectivity(
  String proxyAddress, {
  Duration timeout = const Duration(seconds: 4),
}) async {
  return (
    success: false,
    message: 'Custom proxy is not supported on Web platform',
  );
}
