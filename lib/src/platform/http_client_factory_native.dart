/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*
*/

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// 归一化为 PAC (Proxy Auto-Config) 规则
///
/// 支持格式示例：
///   - 127.0.0.1:7890 -> PROXY 127.0.0.1:7890;
///   - http://127.0.0.1:7890 -> PROXY 127.0.0.1:7890;
///   - https://proxy.local:8080 -> PROXY proxy.local:8080;
///   - socks5://127.0.0.1:1080 -> SOCKS 127.0.0.1:1080;
///   - socks://127.0.0.1:1080 -> SOCKS 127.0.0.1:1080;
///   - PROXY 127.0.0.1:7890; -> 原样保留
String? formatPacRule(String input) {
  var raw = input.trim();
  if (raw.isEmpty) return null;

  // 已是标准 PAC 规则
  if (raw.toUpperCase().startsWith('PROXY ') ||
      raw.toUpperCase().startsWith('SOCKS ')) {
    return raw.endsWith(';') ? raw : '$raw;';
  }

  var isSocks = false;
  final lower = raw.toLowerCase();
  if (lower.startsWith('socks5://') || lower.startsWith('socks://')) {
    isSocks = true;
    raw = raw.replaceFirst(RegExp(r'^socks5?://', caseSensitive: false), '');
  } else if (lower.startsWith('http://') || lower.startsWith('https://')) {
    raw = raw.replaceFirst(RegExp(r'^https?://', caseSensitive: false), '');
  }

  // 剥离可能跟随的 URL 路径
  final slashIdx = raw.indexOf('/');
  if (slashIdx != -1) {
    raw = raw.substring(0, slashIdx);
  }

  // 剥离内嵌 user:pass@
  final atIdx = raw.indexOf('@');
  if (atIdx != -1) {
    raw = raw.substring(atIdx + 1);
  }

  raw = raw.trim();
  if (raw.isEmpty) return null;
  return isSocks ? 'SOCKS $raw;' : 'PROXY $raw;';
}

/// 解析主机名与端口
({String host, int port})? parseHostAndPort(String input) {
  var raw = input.trim();
  if (raw.isEmpty) return null;

  final lower = raw.toLowerCase();
  if (lower.startsWith('socks5://') || lower.startsWith('socks://')) {
    raw = raw.replaceFirst(RegExp(r'^socks5?://', caseSensitive: false), '');
  } else if (lower.startsWith('http://') || lower.startsWith('https://')) {
    raw = raw.replaceFirst(RegExp(r'^https?://', caseSensitive: false), '');
  }

  final slashIdx = raw.indexOf('/');
  if (slashIdx != -1) {
    raw = raw.substring(0, slashIdx);
  }

  final atIdx = raw.indexOf('@');
  if (atIdx != -1) {
    raw = raw.substring(atIdx + 1);
  }

  raw = raw.trim();
  if (raw.isEmpty) return null;

  // 支持 IPv6 [::1]:7890
  if (raw.startsWith('[')) {
    final closeBracket = raw.indexOf(']');
    if (closeBracket == -1) return null;
    final host = raw.substring(1, closeBracket);
    final rest = raw.substring(closeBracket + 1);
    if (!rest.startsWith(':')) return null;
    final port = int.tryParse(rest.substring(1));
    if (port == null || port <= 0 || port > 65535) return null;
    return (host: host, port: port);
  }

  final colonIdx = raw.lastIndexOf(':');
  if (colonIdx == -1) return null;
  final host = raw.substring(0, colonIdx).trim();
  final portStr = raw.substring(colonIdx + 1).trim();
  final port = int.tryParse(portStr);
  if (port == null || port <= 0 || port > 65535) return null;
  if (host.isEmpty) return null;

  return (host: host, port: port);
}

/// 创建带代理配置的底层平台 HTTP 客户端
http.Client createPlatformHttpClient({
  bool proxyEnabled = false,
  String proxyAddress = '',
  Duration connectionTimeout = const Duration(seconds: 10),
}) {
  if (!proxyEnabled || proxyAddress.trim().isEmpty) {
    return http.Client();
  }

  final ioClient = HttpClient();
  final rule = formatPacRule(proxyAddress);
  if (rule != null) {
    ioClient.findProxy = (uri) => rule;
  }
  ioClient.connectionTimeout = connectionTimeout;
  return IOClient(ioClient);
}

/// 测试代理服务器连通性（探测代理端口是否开启且可连接）
Future<({bool success, String? message})> testProxyConnectivity(
  String proxyAddress, {
  Duration timeout = const Duration(seconds: 4),
}) async {
  final target = parseHostAndPort(proxyAddress);
  if (target == null) {
    return (success: false, message: 'Invalid proxy address format');
  }

  try {
    final socket = await Socket.connect(
      target.host,
      target.port,
      timeout: timeout,
    );
    await socket.close();
    return (success: true, message: null);
  } on SocketException catch (e) {
    return (success: false, message: e.message);
  } catch (e) {
    return (success: false, message: e.toString());
  }
}
