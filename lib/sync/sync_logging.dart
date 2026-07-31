/*
 * 同步子系统统一日志
 *
 * 设计目标：
 *   - 替代散落在 sync_engine.dart / sync_service.dart / local_fs_backend.dart
 *     的零星 print / _logger 调用，统一日志入口。
 *   - 同时输出到：① console（开发期）② 内存环形缓冲（调试面板）③ 文件（持久化）。
 *   - 文件位置：
 *       桌面端（Windows/macOS/Linux）→ exe 同目录的 logs/ 子目录
 *       移动端（Android/iOS）→ 应用私有数据目录的 logs/ 子目录
 *   - 文件按日期滚动（每天一个），保留最近 N 天。
 *
 * 使用方式：
 *   syncLogger.i('...')
 *   syncLogger.w('...', error: e, stackTrace: st)
 *
 *   // 调试面板读取：
 *   SyncLogBuffer.instance.allLines()  // List<String>
 *
 *   // 文件路径（导出用）：
 *   await SyncLogFile.currentPath()
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

/// 同步日志级别（与 package:logger 的 Level 对应）
///
/// 调试面板用此枚举过滤，避免依赖 logger 包的 Level 类型。
enum SyncLogLevel {
  trace,
  debug,
  info,
  warning,
  error,
  fatal,
}

/// 内存环形缓冲（调试面板用）
///
/// 单例，固定容量 1000 条。同步引擎和 backend 的所有日志都会进入此缓冲，
/// 调试面板通过 [allLines] / [snapshot] 读取，[stream] 实时推送。
class SyncLogBuffer {
  static final SyncLogBuffer instance = SyncLogBuffer._();

  SyncLogBuffer._();

  final int _capacity = 1000;
  final List<SyncLogEntry> _entries = [];
  final StreamController<SyncLogEntry> _controller =
      StreamController<SyncLogEntry>.broadcast();

  /// 实时日志流（调试面板用 StreamBuilder 监听）
  Stream<SyncLogEntry> get stream => _controller.stream;

  /// 当前所有日志条目（按时间顺序）
  List<SyncLogEntry> all() => List.unmodifiable(_entries);

  /// 当前所有日志的文本形式（每条一行，调试面板"日志"页直接渲染）
  List<String> allLines() => _entries.map((e) => e.formattedLine).toList();

  /// 当前快照（拷贝，避免后续修改影响）
  List<SyncLogEntry> snapshot() => List.of(_entries);

  void _append(SyncLogEntry entry) {
    _entries.add(entry);
    while (_entries.length > _capacity) {
      _entries.removeAt(0);
    }
    _controller.add(entry);
  }

  /// 清空缓冲（调试面板"清空"按钮）
  void clear() {
    _entries.clear();
  }
}

/// 单条日志条目（内存结构）
class SyncLogEntry {
  final DateTime time;
  final SyncLogLevel level;
  final String message;
  final String? error;
  final String? stackTrace;

  SyncLogEntry({
    required this.time,
    required this.level,
    required this.message,
    this.error,
    this.stackTrace,
  });

  /// 格式化的单行表示（调试面板展示）
  String get formattedLine {
    final lv = _levelTag(level);
    final ts =
        '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}:'
        '${time.second.toString().padLeft(2, '0')}';
    var line = '[$ts] $lv $message';
    if (error != null) line += ' | $error';
    if (stackTrace != null) line += '\n$stackTrace';
    return line;
  }

  /// JSON 形式（导出用）
  Map<String, Object?> toJson() => {
        'time': time.toIso8601String(),
        'level': level.name,
        'message': message,
        if (error != null) 'error': error,
        if (stackTrace != null) 'stackTrace': stackTrace,
      };

  static String _levelTag(SyncLogLevel lv) => switch (lv) {
        SyncLogLevel.trace => 'TRACE',
        SyncLogLevel.debug => 'DEBUG',
        SyncLogLevel.info => 'INFO',
        SyncLogLevel.warning => 'WARN',
        SyncLogLevel.error => 'ERROR',
        SyncLogLevel.fatal => 'FATAL',
      };
}

/// 自定义 Output：把每行同时写入 [SyncLogFile] 和 [SyncLogBuffer]
///
/// 此 Output 把"完整行（含 stackTrace 多行）"
/// 一起写入文件，方便 grep；同时把每条 LogEvent 拆成 SyncLogEntry 写入缓冲。
class _HybridOutput extends LogOutput {
  final SyncLogBuffer buffer;

  _HybridOutput({required this.buffer});

  @override
  void output(OutputEvent event) {
    final level = _mapLevel(event.level);
    // 合并多行为一个 entry（message + error + stackTrace 拼一起）
    final fullText = event.lines.join('\n');

    // 1) 文件写入
    SyncLogFile.writeLine(fullText);

    // 2) 内存缓冲
    // 拆分 message 和 stackTrace：通常 logger 格式是
    //   [时间] LEVEL message
    //   Error: xxx
    //   StackTrace: ...
    String? errorPart;
    String? stackPart;
    String messagePart;

    if (event.lines.length > 1) {
      // 尝试提取 error 和 stackTrace
      final lines = event.lines;
      messagePart = lines.first;
      final rest = lines.skip(1).join('\n');
      if (rest.contains('StackTrace:') || rest.contains('#0 ')) {
        stackPart = rest;
      } else if (rest.startsWith('Error:')) {
        errorPart = rest;
      } else {
        // 未知格式，全部塞到 stackTrace
        stackPart = rest;
      }
    } else {
      messagePart = fullText;
    }

    buffer._append(SyncLogEntry(
      time: event.origin.time,
      level: level,
      message: messagePart,
      error: errorPart,
      stackTrace: stackPart,
    ));

    // 3) console（debug 模式）
    if (kDebugMode) {
      // ignore: avoid_print
      print(fullText);
    }
  }

  static SyncLogLevel _mapLevel(Level lv) => switch (lv) {
        Level.trace => SyncLogLevel.trace,
        Level.debug => SyncLogLevel.debug,
        Level.info => SyncLogLevel.info,
        Level.warning => SyncLogLevel.warning,
        Level.error => SyncLogLevel.error,
        Level.fatal => SyncLogLevel.fatal,
        _ => SyncLogLevel.info,
      };
}

/// 同步日志文件管理（按日期滚动）
class SyncLogFile {
  static const int _keepDays = 7;

  static String? _dirPath;
  static IOSink? _currentSink;
  static String? _currentDate;
  static DateTime? _lastFlush;

  /// 初始化日志目录（应用启动时调用）
  ///
  /// 桌面端：exe 同目录的 logs/
  /// 移动端：应用私有数据目录的 logs/
  static Future<void> init() async {
    _dirPath = await _resolveLogDir();
    if (_dirPath == null) {
      syncLogger.w('日志目录无法初始化，文件日志禁用');
      return;
    }
    final dir = Directory(_dirPath!);
    try {
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      await _cleanupOldFiles();
    } on Object catch (e) {
      // 目录创建失败不阻断应用，只是退化为只用 console + 内存缓冲
      // ignore: avoid_print
      print('[SyncLog] 日志目录创建失败: $e');
    }
  }

  /// 解析日志目录路径
  static Future<String?> _resolveLogDir() async {
    // 桌面端：exe 同目录的 logs/
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      try {
        // Platform.executable 是当前进程可执行文件的绝对路径
        // （桌面端打包后即 exe / App 的路径；测试环境下可能指向 flutter_tester，
        // 此时写入测试临时目录，可接受）
        final exePath = Platform.executable;
        final exeDir = p.dirname(exePath);
        return p.join(exeDir, 'logs');
      } on Object {
        // 退化为应用支持目录
      }
    }

    // 移动端：应用私有数据目录的 logs/
    try {
      // getApplicationSupportDirectory 在 Android/iOS 返回应用私有目录
      final appDir = await getApplicationSupportDirectory();
      return p.join(appDir.path, 'logs');
    } on Object {
      return null;
    }
  }

  /// 当前日志文件路径（调试面板"导出"按钮用）
  static Future<String?> currentPath() async {
    if (_dirPath == null) return null;
    final today = _todayStr();
    return p.join(_dirPath!, 'safenotes-sync-$today.log');
  }

  /// 日志目录路径（调试面板展示用）
  static String? get dirPath => _dirPath;

  /// 写入一行到当前日志文件（由 _SyncLogOutput 调用）
  static void writeLine(String line) {
    if (_dirPath == null) return;
    try {
      _ensureSink();
      _currentSink?.writeln(line);
      _maybeFlush();
    } on Object {
      // 文件写入失败静默忽略，不影响主流程
    }
  }

  /// 确保当前日期的 sink 已打开（按日期滚动）
  static void _ensureSink() {
    final today = _todayStr();
    if (_currentDate == today && _currentSink != null) return;

    // 关闭旧 sink
    _currentSink?.close();
    _currentSink = null;

    final path = p.join(_dirPath!, 'safenotes-sync-$today.log');
    _currentSink = File(path).openWrite(mode: FileMode.writeOnlyAppend);
    _currentDate = today;
  }

  /// 定时 flush（避免日志丢失，每 1 秒最多一次）
  static void _maybeFlush() {
    final now = DateTime.now();
    if (_lastFlush == null || now.difference(_lastFlush!).inSeconds >= 1) {
      _currentSink?.flush();
      _lastFlush = now;
    }
  }

  /// 清理超过 [_keepDays] 天的日志文件
  static Future<void> _cleanupOldFiles() async {
    if (_dirPath == null) return;
    final dir = Directory(_dirPath!);
    final cutoff = DateTime.now().subtract(const Duration(days: _keepDays));
    try {
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (!name.startsWith('safenotes-sync-') ||
            !name.endsWith('.log')) continue;
        // 解析文件名中的日期：safenotes-sync-YYYYMMDD.log
        final dateStr = name
            .replaceAll('safenotes-sync-', '')
            .replaceAll('.log', '');
        if (dateStr.length != 8) continue;
        try {
          final year = int.parse(dateStr.substring(0, 4));
          final month = int.parse(dateStr.substring(4, 6));
          final day = int.parse(dateStr.substring(6, 8));
          final fileDate = DateTime(year, month, day);
          if (fileDate.isBefore(cutoff)) {
            await entity.delete();
          }
        } on Object {
          // 日期解析失败，跳过
        }
      }
    } on Object {
      // 清理失败不阻断
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
    await _currentSink?.flush();
    await _currentSink?.close();
    _currentSink = null;
  }
}

/// 全局同步 logger 实例
///
/// 使用方式：
///   syncLogger.i('同步开始')
///   syncLogger.w('ETag 不匹配', error: e)
///   syncLogger.e('解密失败', error: e, stackTrace: st)
///
/// 注意：此 logger 在 release 模式下也会写文件（便于用户反馈问题时提供日志），
/// 但会过滤掉 trace/debug 级别（生产环境默认 info 起）。
final Logger syncLogger = Logger(
  level: kReleaseMode ? Level.info : Level.trace,
  printer: PrettyPrinter(
    methodCount: 0,
    errorMethodCount: 8,
    dateTimeFormat: DateTimeFormat.onlyTimeAndSinceStart,
    noBoxingByDefault: true,
  ),
  output: _HybridOutput(buffer: SyncLogBuffer.instance),
);
