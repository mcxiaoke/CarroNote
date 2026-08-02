// SafeNotes 核心逻辑 CLI —— 纯 Dart 驱动的冒烟验证 / 混沌测试 / 互操作验证入口。
//
// 用法示例：
//   dart run bin/safenotes_cli.dart db info --data-dir ./temp/cli
//   dart run bin/safenotes_cli.dart note add --data-dir ./temp/cli --title hi --body world
//
// 说明：CLI 是核心逻辑的第二个前端（App 是第一个）。它一旦编译不过，
// 就说明有人往 core 里塞了 Flutter 依赖——这是架构约束的守卫。

import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:core/core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('data-dir', defaultsTo: 'temp/cli-data')
    ..addOption('title')
    ..addOption('body')
    ..addFlag('help', abbr: 'h');

  final results = parser.parse(args);
  if (results['help'] as bool) {
    stdout.writeln(parser.usage);
    return;
  }

  // 纯 Dart SQLite 初始化
  sqfliteFfiInit();
  NotesDatabase.dbFactoryOverride = databaseFactoryFfi;

  final dataDir = Directory(results['data-dir'] as String);
  await dataDir.create(recursive: true);
  NotesDatabase.dbPathOverride = dataDir.path;

  // CLI 侧日志目录注入（核心日志逻辑保持纯 Dart）
  logDirResolverOverride = () async => dataDir.path;
  await AppLogFile.init();

  final command = results.rest.isNotEmpty ? results.rest.first : 'help';
  switch (command) {
    case 'db':
      await _cmdDbInfo();
    case 'note':
      await _cmdNoteAdd(
        title: results['title'] as String? ?? 'CLI 标题',
        body: results['body'] as String? ?? 'CLI 正文',
      );
    default:
      stdout.writeln('未知命令: $command');
      stdout.writeln(parser.usage);
  }

  await NotesDatabase.instance.close();
  await AppLogFile.close();
}

/// 打印数据库 schema 状态（冒烟验证：能建库即证明核心可被 CLI 驱动）
Future<void> _cmdDbInfo() async {
  final db = await NotesDatabase.instance.database;
  final tables = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
  );
  stdout.writeln('数据库已打开: ${db.isOpen}');
  stdout.writeln('表: ${tables.map((r) => r['name']).join(', ')}');
}

/// 新增一条笔记并立即读回（验证字段级加解密往返）
Future<void> _cmdNoteAdd({required String title, required String body}) async {
  // CLI 无 UI 登录流程，用测试注入路径验证往返：
  // 直接注入 dataKey 再走加密写 / 解密读。
  await NotesDatabase.instance.database;
  final key = await SyncCrypto.deriveMasterKey('cli-demo-pass',
      salt: Uint8List.fromList(List<int>.generate(16, (i) => i + 1)));
  NotesDatabase.instance.setDataKey(key);

  final note = SafeNote.create(
    title: title,
    description: body,
  );
  await NotesDatabase.instance.storeNote(note);
  final readBack = await NotesDatabase.instance.readNoteByUuid(note.uuid);
  stdout.writeln(
      '写入成功 uuid=${note.uuid} title=${readBack?.title} body=${readBack?.description}');
}
