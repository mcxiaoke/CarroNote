/*
 * 同步日志 HTTP 服务器（E2：移动端日志远程查看）
 *
 * 设计目标：
 *   移动端无法方便地导出日志文件到 PC（SD 卡权限、沙箱限制），
 *   起一个轻量 HTTP 服务器，PC 浏览器直接访问即可查看实时日志和诊断快照。
 *
 * 生命周期：
 *   - 全局单例（SyncLogWebServer.instance），跨页面持久存在
 *   - SyncService.initialize() 时自动启动（debug 功能，后续发布版本可改）
 *   - 离开调试面板不会停止，只有用户手动停止或应用退出才关闭
 *   - 调试面板可查看状态、手动启停
 *
 * 使用方式：
 *   await SyncLogWebServer.instance.start();  // 启动，默认端口 8888
 *   // PC 浏览器访问 http://<手机IP>:8888/
 *   await SyncLogWebServer.instance.stop();   // 停止
 *
 * 端点：
 *   GET /          → HTML 页面（实时日志 + 诊断快照）
 *   GET /logs      → 纯文本日志（全量，可 curl 下载）
 *   GET /diagnostics → 诊断快照纯文本
 *   GET /stream    → WebSocket 实时日志流
 *
 * 安全性：
 *   - 仅绑定 0.0.0.0（局域网可访问），不暴露到公网
 *   - 不含敏感凭据（密码/Token），诊断快照已过滤
 *   - 当前为 debug 阶段默认开启，发布前会改为默认关闭
 */

// Dart 导入
import 'dart:async';
import 'dart:io';

// Project 导入
import 'package:safenotes/sync/sync_logging.dart';
import 'package:safenotes/sync/sync_service.dart';

/// 同步日志 HTTP 服务器
///
/// 轻量级 HTTP 服务器，供 PC 浏览器远程查看移动端日志。
/// 全局单例，跨页面持久存在，离开调试面板不会停止。
class SyncLogWebServer {
  /// 全局单例（跨页面持久存在）
  static final SyncLogWebServer instance = SyncLogWebServer._();

  SyncLogWebServer._();

  HttpServer? _server;
  StreamSubscription<SyncLogEntry>? _logSub;
  final List<WebSocket> _websockets = [];

  /// 当前监听端口（启动后可用，默认 0 表示自动分配）
  int _port = 0;
  int get port => _port;

  /// 是否正在运行
  bool get isRunning => _server != null;

  /// 启动 HTTP 服务器
  ///
  /// [port] 监听端口，默认 8888。若被占用会自动 +1 重试，最多重试 10 次。
  /// 返回实际绑定的端口，启动失败抛异常。
  Future<int> start({int port = 8888}) async {
    if (_server != null) return _port;

    // 尝试绑定端口（被占用则 +1 重试）
    for (var attempt = 0; attempt < 10; attempt++) {
      final tryPort = port + attempt;
      try {
        _server = await HttpServer.bind(
          InternetAddress.anyIPv4,
          tryPort,
        );
        _port = tryPort;
        break;
      } on SocketException {
        if (attempt == 9) rethrow;
        // 端口被占用，继续尝试下一个
      }
    }

    if (_server == null) {
      throw Exception('无法绑定端口 $port~${port + 9}');
    }

    syncLogger.i('日志 Web 服务器已启动，端口 $_port');

    // 订阅日志流，推送给所有 WebSocket 客户端
    _logSub = SyncLogBuffer.instance.stream.listen((entry) {
      _broadcastToWebsockets(entry.formattedLine);
    });

    // 处理 HTTP 请求
    _server!.listen(_handleRequest);

    return _port;
  }

  /// 停止 HTTP 服务器
  Future<void> stop() async {
    await _logSub?.cancel();
    _logSub = null;

    // 关闭所有 WebSocket
    for (final ws in _websockets) {
      await ws.close();
    }
    _websockets.clear();

    await _server?.close(force: true);
    _server = null;
    _port = 0;
    syncLogger.i('日志 Web 服务器已停止');
  }

  /// 处理单个 HTTP 请求
  void _handleRequest(HttpRequest request) {
    final path = request.uri.path;
    try {
      switch (path) {
        case '/':
          _serveHtml(request);
          break;
        case '/logs':
          _serveLogsText(request);
          break;
        case '/diagnostics':
          _serveDiagnostics(request);
          break;
        case '/stream':
          _upgradeToWebSocket(request);
          break;
        default:
          request.response
            ..statusCode = HttpStatus.notFound
            ..write('Not Found: $path');
          request.response.close();
      }
    } on Object catch (e) {
      request.response
        ..statusCode = HttpStatus.internalServerError
        ..write('Server Error: $e');
      request.response.close();
    }
  }

  /// 返回 HTML 页面（实时日志查看器）
  void _serveHtml(HttpRequest request) {
    final html = _buildHtmlPage();
    request.response.headers.contentType = ContentType.html;
    request.response.write(html);
    request.response.close();
  }

  /// 返回纯文本日志（全量）
  void _serveLogsText(HttpRequest request) {
    final logs = SyncService.instance.exportAllLogsAsText();
    request.response.headers.contentType = ContentType.text;
    logs.then((text) {
      request.response.write(text);
      request.response.close();
    });
  }

  /// 返回诊断快照纯文本
  void _serveDiagnostics(HttpRequest request) {
    final snapshot = SyncService.instance.getDiagnosticsSnapshot();
    request.response.headers.contentType = ContentType.text;
    request.response.write(snapshot.toReadableText());
    request.response.close();
  }

  /// 升级为 WebSocket 连接（实时日志推送）
  Future<void> _upgradeToWebSocket(HttpRequest request) async {
    final websocket = WebSocketTransformer.upgrade(request);
    websocket.then((ws) {
      _websockets.add(ws);
      // 先发送历史日志
      for (final entry in SyncLogBuffer.instance.all()) {
        ws.add(entry.formattedLine);
      }
      ws.listen(
        (_) {}, // 客户端消息忽略
        onDone: () => _websockets.remove(ws),
        onError: (_) => _websockets.remove(ws),
      );
    });
  }

  /// 向所有 WebSocket 客户端广播消息
  void _broadcastToWebsockets(String message) {
    final closed = <WebSocket>[];
    for (final ws in _websockets) {
      try {
        ws.add(message);
      } on Object {
        closed.add(ws);
      }
    }
    _websockets.removeWhere((ws) => closed.contains(ws));
  }

  /// 构建 HTML 页面（内嵌 CSS + JS，无需外部依赖）
  String _buildHtmlPage() {
    return '''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>SafeNotes 同步日志</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: 'Consolas', 'Monaco', 'Courier New', monospace;
    background: #1e1e1e; color: #d4d4d4; padding: 12px;
  }
  .header {
    position: sticky; top: 0; background: #1e1e1e; padding: 8px 0;
    border-bottom: 1px solid #333; margin-bottom: 8px; z-index: 100;
    display: flex; gap: 12px; align-items: center; flex-wrap: wrap;
  }
  .header h1 { font-size: 16px; color: #4fc3f7; }
  .header button {
    background: #264f78; color: #fff; border: none; padding: 6px 14px;
    border-radius: 4px; cursor: pointer; font-size: 13px;
  }
  .header button:hover { background: #31708f; }
  .status { font-size: 12px; color: #888; }
  .status.connected { color: #4caf50; }
  .status.disconnected { color: #f44336; }
  #filter {
    background: #2d2d2d; color: #d4d4d4; border: 1px solid #555;
    padding: 4px 8px; border-radius: 4px; font-size: 13px; width: 200px;
  }
  #autoScroll { margin-left: 8px; }
  #autoScrollLabel { font-size: 12px; color: #aaa; cursor: pointer; }
  #logContainer {
    white-space: pre-wrap; word-break: break-all; font-size: 12px;
    line-height: 1.5; max-height: calc(100vh - 80px); overflow-y: auto;
  }
  .log-line { padding: 1px 0; }
  .log-line.ERROR { color: #f48771; }
  .log-line.WARN { color: #cca700; }
  .log-line.FATAL { color: #f44336; font-weight: bold; }
  .log-line.INFO { color: #75beff; }
  .log-line.DEBUG { color: #888; }
  .log-line.TRACE { color: #666; }
</style>
</head>
<body>
<div class="header">
  <h1>SafeNotes 同步日志</h1>
  <span class="status disconnected" id="status">未连接</span>
  <input type="text" id="filter" placeholder="过滤（不区分大小写）..." oninput="applyFilter()">
  <label><input type="checkbox" id="autoScroll" checked><span id="autoScrollLabel">自动滚动</span></label>
  <button onclick="clearLogs()">清空显示</button>
  <button onclick="downloadLogs()">下载日志</button>
  <button onclick="toggleConn()" id="connBtn">暂停</button>
</div>
<div id="logContainer"></div>
<script>
let ws = null;
let paused = false;
let allLines = [];

function connect() {
  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  ws = new WebSocket(proto + '//' + location.host + '/stream');
  ws.onopen = () => {
    document.getElementById('status').textContent = '已连接';
    document.getElementById('status').className = 'status connected';
    document.getElementById('connBtn').textContent = '暂停';
    paused = false;
  };
  ws.onmessage = (e) => {
    if (!paused) {
      allLines.push(e.data);
      appendLine(e.data);
    }
  };
  ws.onclose = () => {
    document.getElementById('status').textContent = '已断开';
    document.getElementById('status').className = 'status disconnected';
    document.getElementById('connBtn').textContent = '重连';
    paused = false;
    // 5 秒后自动重连
    setTimeout(() => { if (!ws || ws.readyState === 3) connect(); }, 5000);
  };
  ws.onerror = () => { ws.close(); };
}

function appendLine(text) {
  const container = document.getElementById('logContainer');
  const div = document.createElement('div');
  div.className = 'log-line ' + getLevelClass(text);
  div.textContent = text;
  container.appendChild(div);
  // 限制 DOM 节点数（避免内存爆炸）
  while (container.children.length > 2000) {
    container.removeChild(container.firstChild);
  }
  if (document.getElementById('autoScroll').checked) {
    container.scrollTop = container.scrollHeight;
  }
}

function getLevelClass(text) {
  if (text.includes(' ERROR ')) return 'ERROR';
  if (text.includes(' WARN ')) return 'WARN';
  if (text.includes(' FATAL ')) return 'FATAL';
  if (text.includes(' INFO ')) return 'INFO';
  if (text.includes(' DEBUG ')) return 'DEBUG';
  if (text.includes(' TRACE ')) return 'TRACE';
  return '';
}

function applyFilter() {
  const filter = document.getElementById('filter').value.toLowerCase();
  const container = document.getElementById('logContainer');
  container.innerHTML = '';
  for (const line of allLines) {
    if (filter === '' || line.toLowerCase().includes(filter)) {
      appendLine(line);
    }
  }
}

function clearLogs() {
  allLines = [];
  document.getElementById('logContainer').innerHTML = '';
}

function downloadLogs() {
  window.open('/logs', '_blank');
}

function toggleConn() {
  if (paused) {
    connect();
  } else {
    paused = true;
    if (ws) ws.close();
    document.getElementById('status').textContent = '已暂停';
    document.getElementById('connBtn').textContent = '重连';
  }
}

connect();
</script>
</body>
</html>''';
  }
}
