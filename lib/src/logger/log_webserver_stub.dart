// lib/src/logger/log_webserver_stub.dart
// Web 环境下的日志 WebServer 桩实现（Web 无原生 Socket 支持，恒为 disabled）

class LogWebServer {
  static final LogWebServer instance = LogWebServer._();
  static bool enableWebServer = false;
  static const int defaultPort = 8888;

  LogWebServer._();

  int get port => 0;
  String? get token => null;
  bool get isRunning => false;

  Future<List<String>> localAddresses() async => const [];

  Future<int> start({int port = defaultPort}) async => 0;

  Future<void> stop() async {}
}
