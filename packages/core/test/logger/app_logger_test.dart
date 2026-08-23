/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*
*/

import 'dart:io';

import 'package:core/core.dart';
import 'package:test/test.dart';

void main() {
  late Directory globalLogDir;

  setUpAll(() async {
    globalLogDir = await Directory.systemTemp.createTemp('global_log_');
    logDirResolverOverride = () async => globalLogDir.path;
    AppLogFile.consoleEnabled = false;
    AppLogFile.preferLogDirOverride = true;
    await AppLogFile.init();
  });

  tearDownAll(() async {
    await AppLogFile.close();
    if (globalLogDir.existsSync()) {
      await globalLogDir.delete(recursive: true);
    }
  });

  group('AppLogEntry & AppLogBuffer 环形缓冲测试', () {
    test('AppLogEntry 格式化与 toJson', () {
      final entry = AppLogEntry(
        time: DateTime(2026, 8, 23, 17, 30, 0, 123),
        level: AppLogLevel.info,
        tag: 'NOTE',
        message: 'Note created',
        error: 'Sample error',
        stackTrace: '    at test.dart:10:5',
      );

      final line = entry.formattedLine;
      expect(line, contains('2026-08-23 17:30:00.123'));
      expect(line, contains('[INFO ]'));
      expect(line, contains('[NOTE]'));
      expect(line, contains('Note created'));
      expect(line, contains('ERROR: Sample error'));
      expect(line, contains('at test.dart:10:5'));

      final json = entry.toJson();
      expect(json['level'], equals('info'));
      expect(json['tag'], equals('NOTE'));
      expect(json['message'], equals('Note created'));
      expect(json['error'], equals('Sample error'));
    });

    test('AppLogBuffer 2000 容量限制与先进先出淘汰', () {
      final buffer = AppLogBuffer.instance;
      buffer.clear();
      expect(buffer.all(), isEmpty);

      // 写入 2005 条
      for (var i = 0; i < 2005; i++) {
        Log.app.i('Message index $i');
      }

      final all = buffer.all();
      expect(all.length, equals(2000));
      expect(all.first.message, equals('Message index 5'));
      expect(all.last.message, equals('Message index 2004'));

      final snapshot = buffer.snapshot();
      expect(snapshot.length, equals(2000));

      final lines = buffer.allLines();
      expect(lines.length, equals(2000));

      buffer.clear();
      expect(buffer.all(), isEmpty);
    });
  });

  group('AppLog 级别过滤与 setLevel / resetLevel', () {
    setUp(() {
      AppLogBuffer.instance.clear();
      AppLog.resetLevel();
    });

    tearDown(() {
      AppLog.resetLevel();
    });

    test('setLevel 为 warning/error 时压制 info/debug 日志', () {
      final buffer = AppLogBuffer.instance;

      // 设为 error 级别
      AppLog.setLevel(AppLogLevel.error);

      Log.note.d('Debug msg should be ignored');
      Log.note.i('Info msg should be ignored');
      Log.note.w('Warn msg should be ignored');
      expect(buffer.all(), isEmpty);

      Log.note.e('Error msg should be recorded');
      expect(buffer.all().length, equals(1));
      expect(
        buffer.all().first.message,
        equals('Error msg should be recorded'),
      );

      // 重置回默认级别
      AppLog.resetLevel();
      Log.note.i('Info msg after reset');
      expect(buffer.all().length, equals(2));
    });
  });

  group('AppLogFile 日志文件生命周期管理', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('logger_test_');
      logDirResolverOverride = () async => tempDir.path;
      AppLogFile.consoleEnabled = false;
      AppLogFile.preferLogDirOverride = true;
      await AppLogFile.init();
    });

    tearDown(() async {
      await AppLogFile.close();
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('文件写入、列表列出与清理 clearLogFiles', () async {
      expect(AppLogFile.isInitialized, isTrue);

      Log.app.i('Test log line 1');
      Log.app.i('Test log line 2');
      await AppLogFile.close(); // 确保完全落盘写入

      final files = await AppLogFile.listFiles();
      expect(files.isNotEmpty, isTrue);

      final content = await files.first.readAsString();
      expect(content, contains('Test log line 1'));
      expect(content, contains('Test log line 2'));

      // 清空文件
      final deletedCount = await AppLogFile.clearLogFiles();
      expect(deletedCount, greaterThanOrEqualTo(1));

      final filesAfter = await AppLogFile.listFiles();
      expect(filesAfter, isEmpty);
    });
  });
}
