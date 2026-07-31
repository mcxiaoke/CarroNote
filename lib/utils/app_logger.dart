/*
 * 应用级统一日志系统（App-wide Logging）
 *
 * 设计目标：
 *   - 全应用统一日志入口（不再局限于 sync 子系统）：笔记 CRUD、认证、
 *     备份导入导出、设置变更、同步、加密、网络等全部走这里。
 *   - 三路输出：① console（debug 期）② 内存环形缓冲（调试面板 / WebServer）
 *     ③ 文件（持久化，按日期滚动）。
 *   - 全平台一视同仁：Android / iOS / Windows / macOS / Linux 均启用。
 *   - 所有 Exception / Error 必须可追溯（配合 main.dart 的全局错误钩子）。
 *
 * 日志文件位置：
 *   桌面端（Windows/macOS/Linux）→ exe 同目录的 logs/（不可写时回退到应用数据目录）
 *   移动端（Android/iOS）        → 应用私有数据目录的 logs/
 *   文件名：safenotes-YYYYMMDD.log，保留最近 7 天。
 *
 * 单行格式（便于 grep）：
 *   2026-07-31 17:42:03.123 [INFO ] [NOTE] 新增笔记 uuid=... len=42
 *
 * 使用方式：
 *   Log.note.i('新增笔记 uuid=$uuid');
 *   Log.sync.w('ETag 不匹配', error: e);
 *   Log.db.e('写入失败', error: e, stackTrace: st);
 *
 *   // 自定义分类：
 *   const myLog = AppLog('PAYMENT');
 */

// Dart 导入
import 'dart:async';
import 'dart:io';

// Flutter 导入
import 'package:flutter/foundation.dart' show kDebugMode, kReleaseMode;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// 第三方导入
import 'package:logger/logger.dart';

// ──────────────────────────────────────────────
// 级别
// ──────────────────────────────────────────────

/// 应用日志级别（与 package:logger 的 Level 对应）
///
/// 调试面板用此枚举过滤，避免 UI 层直接依赖 logger 包的 Level 类型。
enum AppLogLevel {
  trace,
  debug,
  info,
  warning,
  error,
  fatal,
}

/// 级别的定宽标签（对齐，便于阅读日志文件）
String _levelLabel(AppLogLevel lv) => switch (lv) {
      AppLogLevel.trace => 'TRACE',
      AppLogLevel.debug => 'DEBUG',
      AppLogLevel.info => 'INFO ',
      AppLogLevel.warning => 'WARN ',
      AppLogLevel.error => 'ERROR',
      AppLogLevel.fatal => 'FATAL',
    };

AppLogLevel _mapLevel(Level lv) => switch (lv) {
      Level.trace => AppLogLevel.trace,
      Level.debug => AppLogLevel.debug,
      Level.info => AppLogLevel.info,
      Level.warning => AppLogLevel.warning,
      Level.error => AppLogLevel.error,
      Level.fatal => AppLogLevel.fatal,
      _ => AppLogLevel.info,
    };

// ──────────────────────────────────────────────
// 单条日志
// ──────────────────────────────────────────────

/// 单条日志条目（内存结构）
class AppLogEntry {
  final DateTime time;
  final AppLogLevel level;

  /// 分类标签（NOTE / SYNC / AUTH / DB ...），用于面板与 WebServer 过滤
  final String tag;
  final String message;
  final String? error;
  final String? stackTrace;

  AppLogEntry({
    required this.time,
    required this.level,
    required this.tag,
    required this.message,
    this.error,
    this.stackTrace,
  });

  /// 格式化的完整表示（文件 / 面板 / WebServer 共用同一格式）
  String get formattedLine {
    final b = StringBuffer()
      ..write(_formatTimestamp(time))
      ..write(' [')
      ..write(_levelLabel(level))
      ..write('] [')
      ..write(tag)
      ..write('] ')
      ..write(message);
    if (error != null) b.write('\n    ERROR: $error');
    if (stackTrace != null) b.write('\n$stackTrace');
    return b.toString();
  }

  /// JSON 形式（导出用）
  Map<String, Object?> toJson() => {
        'time': time.toIso8601String(),
        'level': level.name,
        'tag': tag,
        'message': message,
        if (error != null) 'error': error,
        if (stackTrace != null) 'stackTrace': stackTrace,
      };
}

/// 时间戳格式：YYYY-MM-DD HH:MM:SS.mmm
String _formatTimestamp(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.'
      '${t.millisecond.toString().padLeft(3, '0')}';
}

// ──────────────────────────────────────────────
// 内存环形缓冲
// ──────────────────────────────────────────────

/// 内存环形缓冲（调试面板 / 日志 WebServer 用）
///
/// 单例，固定容量 2000 条。全应用所有日志都会进入此缓冲，
/// 面板通过 [all] / [allLines] 读取，[stream] 实时推送。
class AppLogBuffer {
  static final AppLogBuffer instance = AppLogBuffer._();

  AppLogBuffer._();

  final int _capacity = 2000;
  final List<AppLogEntry> _entries = [];
  final StreamController<AppLogEntry> _controller =
      StreamController<AppLogEntry>.broadcast();

  /// 实时日志流（面板 StreamBuilder / WebSocket 监听）
  Stream<AppLogEntry> get stream => _controller.stream;

  /// 当前所有日志条目（按时间顺序）
  List<AppLogEntry> all() => List.unmodifiable(_entries);

  /// 当前所有日志的文本形式
  List<String> allLines() => _entries.map((e) => e.formattedLine).toList();

  /// 当前快照（拷贝，避免后续修改影响）
  List<AppLogEntry> snapshot() => List.of(_entries);

  void _append(AppLogEntry entry) {
    _entries.add(entry);
    while (_entries.length > _capacity) {
      _entries.removeAt(0);
    }
    _controller.add(entry);
  }

  /// 清空缓冲（面板"清空"按钮）
  void clear() => _entries.clear();
}

// ──────────────────────────────────────────────
// 日志上下文（把 tag / 原始 error 传给 Output）
// ──────────────────────────────────────────────

/// 当前正在记录的日志上下文
///
/// Dart 单线程事件循环内，`Logger.log()` → printer → output 全程同步执行，
/// 因此可以安全地用一个静态变量在调用前后传递 tag，避免污染 message 文本。
class _LogContext {
  static String tag = 'APP';
}

// ──────────────────────────────────────────────
// Printer / Output
// ──────────────────────────────────────────────

/// 自定义 Printer：产出统一的单行（多行）格式
class _AppLogPrinter extends LogPrinter {
  /// 堆栈最多保留的帧数（避免日志文件被巨型堆栈撑爆）
  static const int _maxStackFrames = 12;

  @override
  List<String> log(LogEvent event) {
    final level = _mapLevel(event.level);
    final lines = <String>[
      '${_formatTimestamp(event.time)} [${_levelLabel(level)}] '
          '[${_LogContext.tag}] ${event.message}',
    ];
    if (event.error != null) {
      lines.add('    ERROR: ${event.error}');
    }
    final st = event.stackTrace;
    if (st != null) {
      lines.add(_formatStackTrace(st));
    }
    return lines;
  }

  /// 裁剪堆栈到前 N 帧并统一缩进
  static String _formatStackTrace(StackTrace st) {
    final frames = st
        .toString()
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .take(_maxStackFrames)
        .map((l) => '    $l');
    return frames.join('\n');
  }
}

/// 混合 Output：同时写入文件、内存缓冲、console
class _HybridOutput extends LogOutput {
  final AppLogBuffer buffer;

  _HybridOutput({required this.buffer});

  @override
  void output(OutputEvent event) {
    final level = _mapLevel(event.level);
    final fullText = event.lines.join('\n');

    // 1) 文件写入（整条含堆栈，便于 grep 上下文）
    AppLogFile.writeLine(fullText);

    // 2) 内存缓冲：拆出 message / error / stackTrace 三段
    //    格式由 _AppLogPrinter 保证：第一行是主消息，
    //    随后可能是 "    ERROR: xxx"，再随后是缩进的堆栈。
    final lines = event.lines;
    final messageLine = lines.isNotEmpty ? lines.first : '';
    // 去掉 "时间 [级别] [TAG] " 前缀，只保留正文（tag/level/time 已是独立字段）
    final message = _stripPrefix(messageLine);

    String? errorPart;
    String? stackPart;
    for (final line in lines.skip(1)) {
      if (line.startsWith('    ERROR: ')) {
        errorPart = line.substring('    ERROR: '.length);
      } else {
        stackPart = stackPart == null ? line : '$stackPart\n$line';
      }
    }

    buffer._append(AppLogEntry(
      time: event.origin.time,
      level: level,
      tag: _LogContext.tag,
      message: message,
      error: errorPart,
      stackTrace: stackPart,
    ));

    // 3) console（仅 debug 模式，避免 release 期无谓开销）
    if (kDebugMode) {
      // ignore: avoid_print
      print(fullText);
    }
  }

  /// 剥离 "YYYY-MM-DD HH:MM:SS.mmm [LEVEL] [TAG] " 前缀
  static String _stripPrefix(String line) {
    final idx = line.indexOf('] ', line.indexOf('] ') + 1);
    if (idx > 0 && idx + 2 <= line.length) return line.substring(idx + 2);
    return line;
  }
}

// ──────────────────────────────────────────────
// 日志文件管理
// ──────────────────────────────────────────────

/// 应用日志文件管理（按日期滚动，保留最近 N 天）
class AppLogFile {
  static const int _keepDays = 7;
  static const String _filePrefix = 'safenotes-';
  static const String _fileSuffix = '.log';

  static String? _dirPath;
  static IOSink? _currentSink;
  static String? _currentDate;
  static DateTime? _lastFlush;
  static bool _initialized = false;

  /// 是否已初始化（重复调用 init 会被忽略）
  static bool get isInitialized => _initialized;

  /// 日志目录路径（面板 / WebServer 展示用）
  static String? get dirPath => _dirPath;

  /// 初始化日志目录（应用启动最早期调用，全平台）
  ///
  /// 幂等：重复调用直接返回。失败不阻断应用，退化为 console + 内存缓冲。
  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    AppLog._enabled = true;

    _dirPath = await _resolveLogDir();
    if (_dirPath == null) {
      // ignore: avoid_print
      print('[AppLog] 日志目录无法初始化，文件日志已禁用');
      return;
    }
    try {
      await _cleanupOldFiles();
    } on Object catch (e) {
      // ignore: avoid_print
      print('[AppLog] 清理历史日志失败: $e');
    }
  }

  /// 解析并创建日志目录
  ///
  /// 桌面端优先用 exe 同目录的 logs/（便于用户直接找到）；
  /// 若该目录不可写（如安装在 Program Files），回退到应用数据目录。
  static Future<String?> _resolveLogDir() async {
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      try {
        final exeDir = p.dirname(Platform.resolvedExecutable);
        final candidate = p.join(exeDir, 'logs');
        if (await _ensureWritableDir(candidate)) return candidate;
      } on Object {
        // 忽略，走下面的回退分支
      }
    }

    // 移动端 / 桌面端回退：应用私有数据目录的 logs/
    try {
      final appDir = await getApplicationSupportDirectory();
      final candidate = p.join(appDir.path, 'logs');
      if (await _ensureWritableDir(candidate)) return candidate;
    } on Object {
      // 忽略
    }
    return null;
  }

  /// 确保目录存在且可写（写一个探针文件验证）
  static Future<bool> _ensureWritableDir(String path) async {
    try {
      final dir = Directory(path);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final probe = File(p.join(path, '.write_probe'));
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
      return true;
    } on Object {
      return false;
    }
  }

  /// 当前日志文件路径（导出 / 下载用）
  static Future<String?> currentPath() async {
    if (_dirPath == null) return null;
    return p.join(_dirPath!, '$_filePrefix${_todayStr()}$_fileSuffix');
  }

  /// 列出所有历史日志文件（按文件名倒序，最新在前）
  static Future<List<File>> listFiles() async {
    if (_dirPath == null) return [];
    try {
      final dir = Directory(_dirPath!);
      if (!await dir.exists()) return [];
      final files = <File>[];
      await for (final e in dir.list()) {
        if (e is File && _isLogFile(p.basename(e.path))) files.add(e);
      }
      files.sort((a, b) => p.basename(b.path).compareTo(p.basename(a.path)));
      return files;
    } on Object {
      return [];
    }
  }

  static bool _isLogFile(String name) =>
      name.startsWith(_filePrefix) && name.endsWith(_fileSuffix);

  /// 写入一行到当前日志文件（由 [_HybridOutput] 调用）
  static void writeLine(String line) {
    if (_dirPath == null) return;
    try {
      _ensureSink();
      _currentSink?.writeln(line);
      _maybeFlush();
    } on Object {
      // 文件写入失败静默忽略，不影响主流程（避免日志系统自身把 app 拖垮）
    }
  }

  /// 确保当前日期的 sink 已打开（跨天自动滚动）
  static void _ensureSink() {
    final today = _todayStr();
    if (_currentDate == today && _currentSink != null) return;

    // 跨天：关闭旧 sink（fire-and-forget，避免阻塞写入路径）
    final old = _currentSink;
    _currentSink = null;
    if (old != null) {
      old.flush().then<void>((_) => old.close()).catchError((Object _) {});
    }

    final path = p.join(_dirPath!, '$_filePrefix$today$_fileSuffix');
    _currentSink = File(path).openWrite(mode: FileMode.writeOnlyAppend);
    _currentDate = today;
  }

  /// 限频 flush（每秒最多一次，兼顾性能与丢日志风险）
  static void _maybeFlush() {
    final now = DateTime.now();
    if (_lastFlush == null || now.difference(_lastFlush!).inSeconds >= 1) {
      _currentSink?.flush();
      _lastFlush = now;
    }
  }

  /// 立即 flush（应用进入后台 / 退出前调用，避免丢日志）
  static Future<void> flush() async {
    try {
      await _currentSink?.flush();
    } on Object {
      // 忽略
    }
  }

  /// 清理超过 [_keepDays] 天的日志文件
  static Future<void> _cleanupOldFiles() async {
    if (_dirPath == null) return;
    final dir = Directory(_dirPath!);
    if (!await dir.exists()) return;
    final cutoff = DateTime.now().subtract(const Duration(days: _keepDays));
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (!_isLogFile(name)) continue;
      // 解析文件名中的日期：safenotes-YYYYMMDD.log
      final dateStr = name.substring(
        _filePrefix.length,
        name.length - _fileSuffix.length,
      );
      if (dateStr.length != 8) continue;
      try {
        final fileDate = DateTime(
          int.parse(dateStr.substring(0, 4)),
          int.parse(dateStr.substring(4, 6)),
          int.parse(dateStr.substring(6, 8)),
        );
        if (fileDate.isBefore(cutoff)) await entity.delete();
      } on Object {
        // 单个文件解析/删除失败不影响其他文件
      }
    }
  }

  static String _todayStr() {
    final now = DateTime.now();
    return '${now.year.toString().padLeft(4, '0')}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}';
  }

  /// 关闭日志文件（应用退出时调用）
  static Future<void> close() async {
    final sink = _currentSink;
    _currentSink = null;
    _currentDate = null;
    if (sink == null) return;
    try {
      await sink.flush();
      await sink.close();
    } on Object {
      // 忽略
    }
  }
}

// ──────────────────────────────────────────────
// Logger 实例与对外 API
// ──────────────────────────────────────────────

/// 底层 logger 实例（不建议直接使用，请用 [Log] / [AppLog]）
///
/// release 模式下过滤 trace/debug（只留 info 及以上），
/// debug 模式下全量输出。两种模式都会写文件，方便用户反馈问题时提供日志。
final Logger _rawLogger = Logger(
  level: kReleaseMode ? Level.info : Level.trace,
  filter: ProductionFilter(),
  printer: _AppLogPrinter(),
  output: _HybridOutput(buffer: AppLogBuffer.instance),
);

/// 带分类标签的日志器
///
/// 通过 [Log] 使用预定义分类，也可自行创建：`const AppLog('PAYMENT')`。
class AppLog {
  /// 日志总开关：默认关闭，仅在 [AppLogFile.init] 被调用（应用启动时）后才真正写文件 / 缓冲 / console。
  /// 此前（如 flutter test 或仅 import 时）所有 [Log] 调用均为 no-op，不产生任何输出或文件。
  static bool _enabled = false;

  /// 是否在启用中（调试面板 / UI 据此判断当前是否处于激活日志模式）
  static bool get enabled => _enabled;

  /// 分类标签，会出现在每行日志的 `[TAG]` 位置
  final String tag;

  const AppLog(this.tag);

  /// 最细粒度追踪（release 不输出）
  void t(Object? message, {Object? error, StackTrace? stackTrace}) =>
      _log(Level.trace, message, error, stackTrace);

  /// 调试信息（release 不输出）
  void d(Object? message, {Object? error, StackTrace? stackTrace}) =>
      _log(Level.debug, message, error, stackTrace);

  /// 关键流程 / 重要操作（release 也会记录）
  void i(Object? message, {Object? error, StackTrace? stackTrace}) =>
      _log(Level.info, message, error, stackTrace);

  /// 异常但可恢复
  void w(Object? message, {Object? error, StackTrace? stackTrace}) =>
      _log(Level.warning, message, error, stackTrace);

  /// 错误（所有捕获到的 Exception 都应走这里）
  void e(Object? message, {Object? error, StackTrace? stackTrace}) =>
      _log(Level.error, message, error, stackTrace);

  /// 致命错误（导致功能不可用）
  void f(Object? message, {Object? error, StackTrace? stackTrace}) =>
      _log(Level.fatal, message, error, stackTrace);

  /// 统一出口：设置 tag 上下文 → 记录 → 恢复
  ///
  /// printer/output 在 `_rawLogger.log` 内同步执行，因此 tag 一定对应当前这条。
  void _log(
    Level level,
    Object? message,
    Object? error,
    StackTrace? stackTrace,
  ) {
    if (!_enabled) return;
    final previous = _LogContext.tag;
    _LogContext.tag = tag;
    try {
      _rawLogger.log(level, message, error: error, stackTrace: stackTrace);
    } on Object catch (e) {
      // 日志系统自身异常绝不能影响业务
      // ignore: avoid_print
      if (kDebugMode) print('[AppLog] 记录日志失败: $e');
    } finally {
      _LogContext.tag = previous;
    }
  }
}

/// 预定义日志分类
///
/// 新增分类时在此登记，保证 tag 命名统一、便于过滤。
class Log {
  Log._();

  /// 应用生命周期：启动、退出、前后台切换、未捕获异常
  static const AppLog app = AppLog('APP');

  /// 笔记业务操作：新增 / 编辑 / 删除 / 恢复 / 永久删除
  static const AppLog note = AppLog('NOTE');

  /// 数据库层：建表、升级、迁移、重加密、删库
  static const AppLog db = AppLog('DB');

  /// 认证与会话：登录、登出、生物识别、超时锁定、改密码
  static const AppLog auth = AppLog('AUTH');

  /// 同步子系统：引擎、后端、manifest、blob
  static const AppLog sync = AppLog('SYNC');

  /// 备份与导入导出
  static const AppLog backup = AppLog('BACKUP');

  /// 设置变更
  static const AppLog settings = AppLog('SETTINGS');

  /// 加密 / 密钥管理
  static const AppLog crypto = AppLog('CRYPTO');

  /// 日志 WebServer 自身
  static const AppLog web = AppLog('WEB');

  /// UI 层交互（页面跳转、对话框等，一般用 debug 级别）
  static const AppLog ui = AppLog('UI');
}
