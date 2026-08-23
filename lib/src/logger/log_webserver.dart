/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

/*
 * 日志 HTTP 服务器（全平台：移动端 + 桌面端）
 *
 * 设计目标：
 *   移动端无法方便地导出日志文件到 PC（沙箱限制），桌面端也常需要
 *   在另一台机器上远程观察运行日志。起一个轻量 HTTP 服务器，
 *   浏览器直接访问即可查看**全应用**实时日志（不只是同步子系统）。
 *
 * 生命周期（按需求调整）：
 *   - 全局单例（LogWebServer.instance）
 *   - 进入主界面（HomePage）即自动启动
 *   - 应用退出（detached）时停止；其余情况保持运行
 *   - 调试面板可查看状态、手动启停
 *
 * 使用方式：
 *   await LogWebServer.instance.start();  // 默认端口 8888
 *   // 浏览器访问 http://<设备IP>:8888/
 *   await LogWebServer.instance.stop();
 *
 * 端点：
 *   GET /             → HTML 页面（实时日志查看器）
 *   GET /logs         → 纯文本日志（内存缓冲全量）
 *   GET /logfile      → 下载当天日志文件（完整历史，含已滚出内存的部分）
 *   GET /files        → 日志文件列表（JSON）
 *   GET /diagnostics  → 同步诊断快照纯文本
 *   GET /stream       → WebSocket 实时日志流
 *   GET /panel        → 调试面板 dashboard（HTML，来自 assets/web/dashboard.html）
 *   GET /api/status   → 同步状态快照 JSON
 *   GET /api/sync     → 上次同步结果详情 JSON
 *   GET /api/actions  → 同步动作数组 JSON
 *   GET /api/memory   → 内存数据快照 JSON
 *   GET /api/db       → 本地数据库 inspector JSON（表结构/行数/元数据；?table=&limit= 返回数据行）
 *   GET /api/prefs    → SharedPreferences 快照 JSON
 *   GET /api/download/db      → 下载本地数据库文件（.db）
 *   GET /api/download/sp      → 下载 SharedPreferences（JSON）
 *   GET /api/download/journal → 下载 Journal（JSON）
 *   GET /api/download/all     → 全部调试数据打包 ZIP（日志+数据库+SP+Journal+诊断）
 *
 * 安全性：
 *   - 仅绑定 0.0.0.0（局域网可访问），不做公网暴露
 *   - 每次启动生成随机 6 位数字 token，所有请求必须携带 ?token=xxx（URL query 或 header）
 *   - 不含敏感凭据（密码 / Token / 明文笔记），诊断快照已过滤
 */

// Dart 导入

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';

import 'package:core/core.dart';
import 'package:path/path.dart' as p;

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/sync/sync_service.dart';
import 'package:safenotes/utils/platform_ui.dart';

// Flutter 导入

// Project 导入

/// 日志 HTTP 服务器（全局单例，全平台可用）
class LogWebServer {
  /// 全局单例（跨页面持久存在）
  static final LogWebServer instance = LogWebServer._();

  /// 是否启用日志 HTTP 服务器。
  ///
  /// 默认开启。UI 集成测试（flutter test）下应设为 false：HttpServer 的
  /// idle timeout 会创建一个周期性 Timer，在 FakeAsync 测试环境里永远处于
  /// pending 状态，导致测试结束报 "A Timer is still pending"。UI 集成测试并不
  /// 验证日志服务器本身（core 包已有独立测试覆盖其正确性），故可安全关闭，
  /// 既避免测试失败，也免去在测试沙箱里绑定真实 socket。
  static bool enableWebServer = true;

  LogWebServer._();

  /// 默认端口
  static const int defaultPort = 8888;

  /// 平台标签（用于日志面板标题展示，便于区分日志来源设备）
  String get _platformLabel {
    if (isAndroid) return 'Android';
    if (isIOS) return 'iOS';
    if (Platform.isWindows) return 'Windows';
    if (Platform.isLinux) return 'Linux';
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isFuchsia) return 'Fuchsia';
    return 'Unknown';
  }

  HttpServer? _server;
  StreamSubscription<AppLogEntry>? _logSub;
  final List<WebSocket> _websockets = [];

  /// 诊断快照 / 调试快照 / Dashboard HTML 原本通过 provider 注入，
  /// 现因本文件位于 lib 层（可直接用 flutter/services 与 SyncService），
  /// 改为直接调用，不再需要注入字段。

  /// 当前监听端口（未启动为 0）
  int _port = 0;
  int get port => _port;

  /// 启动时随机生成的 6 位数字 token，所有请求必须携带（URL ?token= 或 header）
  String? _token;
  String? get token => _token;

  /// 是否正在运行
  bool get isRunning => _server != null;

  /// 本机局域网地址列表（供 UI 展示"用哪个地址访问"）
  Future<List<String>> localAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      return [
        for (final ni in interfaces)
          for (final addr in ni.addresses) addr.address,
      ];
    } on Object {
      return [];
    }
  }

  /// 启动 HTTP 服务器
  ///
  /// [port] 监听端口，默认 8888。被占用时自动 +1 重试，最多 10 次。
  /// 返回实际绑定的端口；全部失败抛异常。
  Future<int> start({int port = defaultPort}) async {
    // UI 集成测试（flutter test）下设为 false：HttpServer 的 idle timeout 会创建
    // 一个周期性 Timer，在 FakeAsync 测试环境里永远 pending，导致测试结束报
    // "A Timer is still pending"。日志服务器本身的正确性由 core 包独立测试覆盖，
    // 集成测试不验证它，故直接跳过绑定，既避免测试失败，也免去绑定真实 socket。
    if (!enableWebServer) return _port;
    if (_server != null) return _port;

    SocketException? lastError;
    for (var attempt = 0; attempt < 10; attempt++) {
      final tryPort = port + attempt;
      try {
        _server = await HttpServer.bind(InternetAddress.anyIPv4, tryPort);
        _port = tryPort;
        break;
      } on SocketException catch (e) {
        lastError = e;
        // 端口被占用，继续尝试下一个
      }
    }

    if (_server == null) {
      throw Exception('无法绑定端口 $port~${port + 9}: $lastError');
    }

    // 生成安全随机 128-bit（16 字节）hex token，每次启动都不同（T-3 修复）
    final random = Random.secure();
    final tokenBytes = List<int>.generate(16, (_) => random.nextInt(256));
    _token = tokenBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    // 订阅日志流，实时推送给所有 WebSocket 客户端
    _logSub = AppLogBuffer.instance.stream.listen((entry) {
      _broadcastToWebsockets(entry.formattedLine);
    });

    _server!.listen(
      _handleRequest,
      onError: (Object e, StackTrace st) {
        Log.web.w('HTTP 服务器监听异常', error: e, stackTrace: st);
      },
    );

    final addrs = await localAddresses();
    final maskedToken = _token != null && _token!.length >= 8
        ? '${_token!.substring(0, 4)}...${_token!.substring(_token!.length - 4)}'
        : '****';
    Log.web.i(
      '日志 Web 服务器已启动: '
      '${addrs.map((a) => 'http://$a:$_port/?token=$maskedToken').join(', ')}'
      '${addrs.isEmpty ? '端口 $_port (token=$maskedToken)' : ''}',
    );

    return _port;
  }

  /// 停止 HTTP 服务器（应用退出时调用）
  Future<void> stop() async {
    if (_server == null) return;

    await _logSub?.cancel();
    _logSub = null;

    for (final ws in _websockets) {
      try {
        await ws.close();
      } on Object {
        // 单个连接关闭失败不影响整体
      }
    }
    _websockets.clear();

    await _server?.close(force: true);
    _server = null;
    _port = 0;
    _token = null;
    Log.web.i('日志 Web 服务器已停止');
  }

  // ──────────────────────────────────────────────
  // 请求分发
  // ──────────────────────────────────────────────

  Future<void> _handleRequest(HttpRequest request) async {
    final path = request.uri.path;
    // CORS 预检：直接返回 204 + CORS 头，使 dashboard 可跨域访问
    if (request.method == 'OPTIONS') {
      _setCors(request.response);
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      return;
    }
    // Token 认证：所有请求必须携带正确 token（URL query 或 header）
    if (!_checkToken(request)) {
      _setCors(request.response);
      request.response
        ..statusCode = HttpStatus.forbidden
        ..write('Forbidden: invalid or missing token');
      await request.response.close();
      return;
    }
    try {
      switch (path) {
        case '/':
          _serveHtml(request);
          break;
        case '/panel':
          await _serveDashboard(request);
          break;
        case '/logs':
          await _serveLogsText(request);
          break;
        case '/logfile':
          await _serveLogFile(request);
          break;
        case '/files':
          await _serveFileList(request);
          break;
        case '/diagnostics':
          await _serveDiagnostics(request);
          break;
        case '/api/status':
        case '/api/sync':
        case '/api/actions':
        case '/api/memory':
        case '/api/db':
        case '/api/prefs':
          await _serveApi(request, path);
          break;
        case '/api/download/db':
          await _serveDownloadDb(request);
          break;
        case '/api/download/sp':
          await _serveDownloadSp(request);
          break;
        case '/api/download/journal':
          await _serveDownloadJournal(request);
          break;
        case '/api/download/all':
          await _serveDownloadAll(request);
          break;
        case '/stream':
          await _upgradeToWebSocket(request);
          break;
        default:
          _setCors(request.response);
          request.response
            ..statusCode = HttpStatus.notFound
            ..write('Not Found: $path');
          await request.response.close();
      }
    } on Object catch (e, st) {
      Log.web.e('处理请求失败 path=$path', error: e, stackTrace: st);
      try {
        _setCors(request.response);
        request.response
          ..statusCode = HttpStatus.internalServerError
          ..write('Server Error: $e');
        await request.response.close();
      } on Object {
        // 响应已关闭，忽略
      }
    }
  }

  /// 校验请求 token（URL ?token= 参数或 HTTP header `token`）
  bool _checkToken(HttpRequest request) {
    final token =
        request.uri.queryParameters['token'] ?? request.headers.value('token');
    return token != null && token == _token;
  }

  /// 统一设置 CORS 响应头
  static void _setCors(HttpResponse res) {
    res.headers.set('Access-Control-Allow-Origin', '*');
    res.headers.set('Access-Control-Allow-Methods', 'GET, OPTIONS');
    res.headers.set('Access-Control-Allow-Headers', 'Content-Type, token');
  }

  /// 以 JSON 响应（自动带 CORS 头，支持 Map / List 等任意 JSON 结构）
  Future<void> _sendJson(HttpRequest request, Object? data) async {
    _setCors(request.response);
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(data));
    await request.response.close();
  }

  /// 聚合调试 JSON 端点（/api/status|sync|actions|memory|db|prefs）
  Future<void> _serveApi(HttpRequest request, String path) async {
    if (path == '/api/db') {
      await _serveDbInspect(request);
      return;
    }
    if (path == '/api/prefs') {
      await _sendJson(request, PreferencesStorage.dumpAll());
      return;
    }
    // 直接调用 SyncService（本文件位于 lib 层，无循环依赖），无需 provider 注入
    final full = SyncService.instance.getDebugJson();
    switch (path) {
      case '/api/status':
        await _sendJson(request, full['status'] as Map<String, dynamic>);
        break;
      case '/api/sync':
        await _sendJson(request, full['sync'] as Map<String, dynamic>);
        break;
      case '/api/actions':
        await _sendJson(request, full['actions'] as List);
        break;
      case '/api/memory':
        await _sendJson(request, full['memory'] as Map<String, dynamic>);
        break;
    }
  }

  /// Database Inspector 端点（/api/db）
  ///
  /// 无 query 参数：返回库结构元数据（表清单/行数/列 schema/文件信息）。
  /// ?table=TABLENAME&limit=N：返回该表前 N 行**数据**（blob 列以占位符表示）。
  Future<void> _serveDbInspect(HttpRequest request) async {
    final table = request.uri.queryParameters['table'];
    try {
      if (table != null && table.isNotEmpty) {
        final limit =
            int.tryParse(request.uri.queryParameters['limit'] ?? '100') ?? 100;
        final rows = await NotesDatabase.instance.queryTableRows(
          table,
          limit: limit,
        );
        await _sendJson(request, {
          'table': table,
          'limit': limit,
          'rowCount': rows.length,
          'rows': rows,
        });
      } else {
        final meta = await NotesDatabase.instance.inspectMetadata();
        await _sendJson(request, meta);
      }
    } on Object catch (e) {
      await _sendJson(request, {'error': '读取数据库失败: $e'});
    }
  }

  /// 调试面板 dashboard（/panel）
  /// HTML 直接来自 assets/web/dashboard.html（通过 rootBundle 读取，本文件位于
  /// lib 层，可正常使用 flutter/services）。
  Future<void> _serveDashboard(HttpRequest request) async {
    request.response.headers.contentType = ContentType.html;
    try {
      final html = await rootBundle.loadString('assets/web/dashboard.html');
      // 注入 token 供 dashboard JS 使用
      request.response.write(
        html.replaceFirst(
          '<script>',
          '<script>window.__TOKEN__="${_token ?? ""}";',
        ),
      );
    } on Object catch (e, st) {
      Log.web.e('读取 dashboard.html 失败', error: e, stackTrace: st);
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write('Failed to load dashboard.html: $e');
    }
    await request.response.close();
  }

  /// HTML 实时日志查看器
  void _serveHtml(HttpRequest request) {
    request.response.headers.contentType = ContentType.html;
    request.response.write(_buildHtmlPage());
    request.response.close();
  }

  /// 纯文本日志（内存缓冲全量）
  Future<void> _serveLogsText(HttpRequest request) async {
    final buffer = StringBuffer()
      ..writeln('=== SafeNotes 应用日志（内存缓冲 · $_platformLabel） ===')
      ..writeln('导出时间: ${DateTime.now()}')
      ..writeln('日志目录: ${AppLogFile.dirPath ?? "N/A"}')
      ..writeln('条目数: ${AppLogBuffer.instance.all().length}')
      ..writeln('');
    for (final line in AppLogBuffer.instance.allLines()) {
      buffer.writeln(line);
    }
    request.response.headers.contentType = ContentType(
      'text',
      'plain',
      charset: 'utf-8',
    );
    request.response.write(buffer.toString());
    await request.response.close();
  }

  /// 下载日志文件（默认当天；?name=xxx.log 指定某一天）
  Future<void> _serveLogFile(HttpRequest request) async {
    final name = request.uri.queryParameters['name'];
    String? path;
    if (name != null && name.isNotEmpty) {
      // 防目录穿越：只允许纯文件名
      if (name.contains('/') || name.contains('\\') || name.contains('..')) {
        request.response
          ..statusCode = HttpStatus.badRequest
          ..write('Invalid name');
        await request.response.close();
        return;
      }
      final dir = AppLogFile.dirPath;
      if (dir != null) path = p.join(dir, name);
    } else {
      path = await AppLogFile.currentPath();
    }

    if (path == null || !await File(path).exists()) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('日志文件不存在');
      await request.response.close();
      return;
    }

    // 先 flush，保证下载到的是最新内容
    await AppLogFile.flush();
    request.response.headers.contentType = ContentType(
      'text',
      'plain',
      charset: 'utf-8',
    );
    request.response.headers.add(
      'Content-Disposition',
      'attachment; filename="${p.basename(path)}"',
    );
    await request.response.addStream(File(path).openRead());
    await request.response.close();
  }

  /// 日志文件列表（JSON）
  Future<void> _serveFileList(HttpRequest request) async {
    final files = await AppLogFile.listFiles();
    final list = <Map<String, Object?>>[];
    for (final f in files) {
      try {
        final stat = await f.stat();
        list.add({
          'name': p.basename(f.path),
          'size': stat.size,
          'modified': stat.modified.toIso8601String(),
        });
      } on Object {
        // 单个文件读取失败跳过
      }
    }
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode({'dir': AppLogFile.dirPath, 'files': list}),
    );
    await request.response.close();
  }

  /// 同步诊断快照（直接调用 SyncService，无需 provider 注入）
  Future<void> _serveDiagnostics(HttpRequest request) async {
    request.response.headers.contentType = ContentType(
      'text',
      'plain',
      charset: 'utf-8',
    );
    try {
      request.response.write(await SyncService.instance.exportAllLogsAsText());
    } on Object catch (e) {
      request.response.write('获取诊断快照失败: $e');
    }
    await request.response.close();
  }

  /// 升级为 WebSocket（实时日志推送）
  Future<void> _upgradeToWebSocket(HttpRequest request) async {
    final ws = await WebSocketTransformer.upgrade(request);
    _websockets.add(ws);
    // 先补发历史日志，客户端一进来就有上下文
    for (final entry in AppLogBuffer.instance.all()) {
      ws.add(entry.formattedLine);
    }
    ws.listen(
      (_) {}, // 客户端消息忽略
      onDone: () => _websockets.remove(ws),
      onError: (Object _) => _websockets.remove(ws),
      cancelOnError: true,
    );
  }

  /// 向所有 WebSocket 客户端广播
  void _broadcastToWebsockets(String message) {
    if (_websockets.isEmpty) return;
    final closed = <WebSocket>[];
    for (final ws in _websockets) {
      try {
        ws.add(message);
      } on Object {
        closed.add(ws);
      }
    }
    if (closed.isNotEmpty) {
      _websockets.removeWhere(closed.contains);
    }
  }

  // ──────────────────────────────────────────────
  // 下载端点
  // ──────────────────────────────────────────────

  /// 通用附件响应（自动带 CORS 头）
  Future<void> _sendAttachment(
    HttpRequest request,
    String filename,
    String content,
    String mime,
  ) async {
    _setCors(request.response);
    // 显式指定 UTF-8：ContentType.parse 无 charset 时 write() 默认按 Latin1
    // 编码，内容含中文（如 managedTags）会抛 "Contains invalid characters."
    final parsed = ContentType.parse(mime);
    request.response.headers.contentType = parsed.charset == null
        ? ContentType(parsed.primaryType, parsed.subType, charset: 'utf-8')
        : parsed;
    request.response.headers.add(
      'Content-Disposition',
      'attachment; filename="$filename"',
    );
    request.response.write(content);
    await request.response.close();
  }

  /// 下载本地数据库文件（.db 二进制）
  Future<void> _serveDownloadDb(HttpRequest request) async {
    try {
      final path = await NotesDatabase.instance.dbFilePath();
      if (!await File(path).exists()) {
        await _sendJson(request, {'error': '数据库文件不存在'});
        return;
      }
      final bytes = await File(path).readAsBytes();
      _setCors(request.response);
      request.response.headers.contentType = ContentType(
        'application',
        'octet-stream',
      );
      final name =
          'safenotes_db_'
          '${DateTime.now().toIso8601String().replaceAll(':', '-')}.db';
      request.response.headers.add(
        'Content-Disposition',
        'attachment; filename="$name"',
      );
      // 显式声明 Content-Length，避免 chunked 编码导致下载工具挂起
      request.response.headers.contentLength = bytes.length;
      request.response.add(bytes);
      await request.response.close();
    } on Object catch (e) {
      await _sendJson(request, {'error': '下载数据库失败: $e'});
    }
  }

  /// 下载 SharedPreferences（JSON）
  Future<void> _serveDownloadSp(HttpRequest request) async {
    final data = PreferencesStorage.dumpAll();
    await _sendAttachment(
      request,
      'shared_preferences.json',
      jsonEncode(data),
      'application/json',
    );
  }

  /// 下载 Journal（JSON，含全部条目）
  Future<void> _serveDownloadJournal(HttpRequest request) async {
    final dump = await SyncService.instance.getJournalDump();
    await _sendAttachment(
      request,
      'journal.json',
      jsonEncode(dump),
      'application/json',
    );
  }

  /// 下载全部调试数据（ZIP 打包：日志文件 + 数据库 + SP + Journal + 诊断快照）
  ///
  /// 单个成员读取失败不影响整体，对应条目以错误文本占位，方便定位问题。
  Future<void> _serveDownloadAll(HttpRequest request) async {
    final archive = Archive();
    void addBytes(String name, List<int> bytes) {
      archive.add(ArchiveFile.bytes(name, bytes));
    }

    // 日志文件（含已滚出内存的历史）
    try {
      await AppLogFile.flush();
      final files = await AppLogFile.listFiles();
      for (final f in files) {
        try {
          addBytes('logs/${p.basename(f.path)}', await f.readAsBytes());
        } on Object catch (e) {
          addBytes('logs/${p.basename(f.path)}.error.txt', utf8.encode('$e'));
        }
      }
    } on Object catch (e) {
      addBytes('logs/error.txt', utf8.encode('列出日志文件失败: $e'));
    }

    // 本地数据库
    try {
      final dbPath = await NotesDatabase.instance.dbFilePath();
      if (await File(dbPath).exists()) {
        addBytes(p.basename(dbPath), await File(dbPath).readAsBytes());
      } else {
        addBytes('database.error.txt', utf8.encode('数据库文件不存在: $dbPath'));
      }
    } on Object catch (e) {
      addBytes('database.error.txt', utf8.encode('读取数据库失败: $e'));
    }

    // SharedPreferences 快照
    addBytes(
      'shared_preferences.json',
      utf8.encode(jsonEncode(PreferencesStorage.dumpAll())),
    );

    // Journal 转储
    try {
      addBytes(
        'journal.json',
        utf8.encode(jsonEncode(await SyncService.instance.getJournalDump())),
      );
    } on Object catch (e) {
      addBytes('journal.error.txt', utf8.encode('获取 Journal 失败: $e'));
    }

    // 同步诊断快照（纯文本）
    try {
      addBytes(
        'diagnostics.txt',
        utf8.encode(await SyncService.instance.exportAllLogsAsText()),
      );
    } on Object catch (e) {
      addBytes('diagnostics.error.txt', utf8.encode('获取诊断快照失败: $e'));
    }

    final zipBytes = ZipEncoder().encode(archive);
    final name =
        'safenotes_export_'
        '${DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-')}.zip';

    _setCors(request.response);
    request.response.headers.contentType = ContentType('application', 'zip');
    request.response.headers.add(
      'Content-Disposition',
      'attachment; filename="$name"',
    );
    // 显式声明 Content-Length：否则 HTTP/1.1 走 chunked 编码，
    // 部分下载工具（IDM 等）无法感知结束而一直挂起
    request.response.headers.contentLength = zipBytes.length;
    request.response.add(zipBytes);
    await request.response.close();
  }

  // ──────────────────────────────────────────────
  // 前端页面（内嵌 CSS + JS，无外部依赖）
  // ──────────────────────────────────────────────

  String _buildHtmlPage() {
    return '''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>SafeNotes 应用日志 ($_platformLabel)</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: 'Consolas', 'Monaco', 'Courier New', monospace;
    background: #1e1e1e; color: #d4d4d4; padding: 12px;
  }
  .header {
    position: sticky; top: 0; background: #1e1e1e; padding: 8px 0;
    border-bottom: 1px solid #333; margin-bottom: 8px; z-index: 100;
    display: flex; gap: 10px; align-items: center; flex-wrap: wrap;
  }
  .header h1 { font-size: 16px; color: #4fc3f7; margin-right: 4px; }
  .header button {
    background: #264f78; color: #fff; border: none; padding: 6px 12px;
    border-radius: 4px; cursor: pointer; font-size: 13px;
  }
  .header button:hover { background: #31708f; }
  .status { font-size: 12px; color: #888; }
  .status.connected { color: #4caf50; }
  .status.disconnected { color: #f44336; }
  #filter {
    background: #2d2d2d; color: #d4d4d4; border: 1px solid #555;
    padding: 5px 8px; border-radius: 4px; font-size: 13px; width: 200px;
  }
  .tags { display: flex; gap: 4px; flex-wrap: wrap; }
  .tag-btn {
    background: #2d2d2d; border: 1px solid #555; color: #aaa;
    padding: 3px 9px; border-radius: 10px; cursor: pointer; font-size: 11px;
  }
  .tag-btn.active { background: #37474f; color: #4fc3f7; border-color: #4fc3f7; }
  #autoScrollLabel { font-size: 12px; color: #aaa; cursor: pointer; }
  #logContainer {
    white-space: pre-wrap; word-break: break-all; font-size: 12px;
    line-height: 1.55; max-height: calc(100vh - 110px); overflow-y: auto;
  }
  .log-line { padding: 1px 0; border-left: 3px solid transparent; padding-left: 6px; }
  .log-line.ERROR { color: #f48771; border-left-color: #f48771; }
  .log-line.WARN  { color: #cca700; border-left-color: #cca700; }
  .log-line.FATAL { color: #ff5252; font-weight: bold; border-left-color: #ff5252; }
  .log-line.INFO  { color: #9cdcfe; }
  .log-line.DEBUG { color: #888; }
  .log-line.TRACE { color: #666; }
</style>
</head>
<body>
<div class="header">
  <h1>SafeNotes 日志</h1>
  <span class="status disconnected" id="status">未连接</span>
  <input type="text" id="filter" placeholder="关键字过滤..." oninput="render()">
  <label><input type="checkbox" id="autoScroll" checked><span id="autoScrollLabel">自动滚动</span></label>
  <button onclick="clearLogs()">清空显示</button>
  <button onclick="location.href='/logfile?token='+token">下载日志文件</button>
  <button onclick="window.open('/diagnostics?token='+token,'_blank')">同步诊断</button>
  <button onclick="toggleConn()" id="connBtn">暂停</button>
</div>
<div class="header tags" id="tagBar"></div>
<div id="logContainer"></div>
<script>
const token = new URLSearchParams(location.search).get('token') || '';
let ws = null;
let paused = false;
let allLines = [];
const LEVELS = ['TRACE','DEBUG','INFO','WARN','ERROR','FATAL'];
// 默认隐藏 TRACE / DEBUG，避免噪音淹没重要信息
let hiddenLevels = new Set(['TRACE','DEBUG']);
let knownTags = new Set();
let hiddenTags = new Set();

function connect() {
  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  ws = new WebSocket(proto + '//' + location.host + '/stream?token=' + encodeURIComponent(token));
  ws.onopen = () => {
    setStatus('已连接', 'connected');
    document.getElementById('connBtn').textContent = '暂停';
    paused = false;
  };
  ws.onmessage = (e) => {
    if (paused) return;
    allLines.push(e.data);
    if (allLines.length > 5000) allLines.shift();
    const tag = parseTag(e.data);
    if (tag && !knownTags.has(tag)) { knownTags.add(tag); renderTagBar(); }
    if (visible(e.data)) appendLine(e.data);
  };
  ws.onclose = () => {
    setStatus('已断开', 'disconnected');
    document.getElementById('connBtn').textContent = '重连';
    paused = false;
    setTimeout(() => { if (!ws || ws.readyState === 3) connect(); }, 5000);
  };
  ws.onerror = () => { ws.close(); };
}

function setStatus(text, cls) {
  const el = document.getElementById('status');
  el.textContent = text;
  el.className = 'status ' + cls;
}

function parseLevel(text) {
  for (const lv of LEVELS) { if (text.includes('[' + lv.padEnd(5) + ']')) return lv; }
  return '';
}
function parseTag(text) {
  const m = text.match(/\\]\\s\\[([A-Z]+)\\]/);
  return m ? m[1] : '';
}

function visible(text) {
  const lv = parseLevel(text);
  if (lv && hiddenLevels.has(lv)) return false;
  const tag = parseTag(text);
  if (tag && hiddenTags.has(tag)) return false;
  const f = document.getElementById('filter').value.toLowerCase();
  return f === '' || text.toLowerCase().includes(f);
}

function appendLine(text) {
  const container = document.getElementById('logContainer');
  const div = document.createElement('div');
  div.className = 'log-line ' + parseLevel(text);
  div.textContent = text;
  container.appendChild(div);
  while (container.children.length > 3000) container.removeChild(container.firstChild);
  if (document.getElementById('autoScroll').checked) {
    container.scrollTop = container.scrollHeight;
  }
}

function render() {
  const container = document.getElementById('logContainer');
  container.innerHTML = '';
  for (const line of allLines) { if (visible(line)) appendLine(line); }
}

function renderTagBar() {
  const bar = document.getElementById('tagBar');
  bar.innerHTML = '';
  const mk = (label, active, onClick) => {
    const b = document.createElement('button');
    b.className = 'tag-btn' + (active ? ' active' : '');
    b.textContent = label;
    b.onclick = onClick;
    bar.appendChild(b);
  };
  for (const lv of LEVELS) {
    mk(lv, !hiddenLevels.has(lv), () => {
      hiddenLevels.has(lv) ? hiddenLevels.delete(lv) : hiddenLevels.add(lv);
      renderTagBar(); render();
    });
  }
  const sep = document.createElement('span');
  sep.textContent = '|'; sep.style.color = '#555';
  bar.appendChild(sep);
  for (const tag of Array.from(knownTags).sort()) {
    mk(tag, !hiddenTags.has(tag), () => {
      hiddenTags.has(tag) ? hiddenTags.delete(tag) : hiddenTags.add(tag);
      renderTagBar(); render();
    });
  }
}

function clearLogs() { allLines = []; document.getElementById('logContainer').innerHTML = ''; }

function toggleConn() {
  if (paused || !ws || ws.readyState === 3) {
    connect();
  } else {
    paused = true;
    ws.close();
    setStatus('已暂停', 'disconnected');
    document.getElementById('connBtn').textContent = '重连';
  }
}

renderTagBar();
connect();
</script>
</body>
</html>''';
  }
}
