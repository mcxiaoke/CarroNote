/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*
*/

import 'package:core/core.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:safenotes/src/platform/http_client_factory.dart';

/// 全局网络代理配置
///
/// 独立于具体业务（如同步服务），集中管理 HTTP / SOCKS 代理设置。
/// 同步服务及其他网络调用通过 [createHttpClient] 获取已自动配置好代理的客户端。
class ProxyConfig {
  static SharedPreferences? _prefs;

  static const _keyProxyEnabled = 'network_proxy_enabled';
  static const _keyProxyAddress = 'network_proxy_address';

  /// 初始化（在应用启动时与 SyncConfig 一同调用）
  static Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  /// 重新加载配置
  static Future<void> reload() async {
    await _prefs?.reload();
  }

  /// 是否启用自定义代理
  static bool get isProxyEnabled => _prefs?.getBool(_keyProxyEnabled) ?? false;

  /// 代理服务器地址（支持 127.0.0.1:7890、http://...、socks5://... 等）
  static String get proxyAddress => _prefs?.getString(_keyProxyAddress) ?? '';

  /// 设置代理开关
  static Future<void> setProxyEnabled(bool enabled) async {
    await _prefs?.setBool(_keyProxyEnabled, enabled);
    Log.settings.i('网络代理开关: ${enabled ? "开启" : "关闭"}');
  }

  /// 设置代理服务器地址
  static Future<void> setProxyAddress(String address) async {
    final trimmed = address.trim();
    await _prefs?.setString(_keyProxyAddress, trimmed);
    Log.settings.i('网络代理地址已设置: ${redactProxyForLog(trimmed)}');
  }

  /// 创建配置好代理的统一 HTTP Client
  static http.Client createHttpClient({
    Duration timeout = const Duration(seconds: 15),
  }) {
    return createPlatformHttpClient(
      proxyEnabled: isProxyEnabled,
      proxyAddress: proxyAddress,
      connectionTimeout: timeout,
    );
  }

  /// 测试指定代理地址的连通性
  static Future<({bool success, String? message})> testConnectivity(
    String address,
  ) {
    return testProxyConnectivity(address);
  }

  /// 日志脱敏：如果代理地址含有内嵌 user:pass@，将其遮盖
  static String redactProxyForLog(String address) {
    if (address.isEmpty) return address;
    return address.replaceAllMapped(
      RegExp(r'((?:https?|socks5?)://)?[^/@\s]+@', caseSensitive: false),
      (m) => '${m[1] ?? ""}***@',
    );
  }
}
