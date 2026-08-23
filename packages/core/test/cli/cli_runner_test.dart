/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*
*/

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:core/core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';

import '../../../../bin/cli_commands.dart';
import '../../../../bin/cli_context.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  group('CLI 密码解析优先级 resolveCliPassword', () {
    late Directory tempDir;
    late File passFile;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('cli_pw_test_');
      passFile = File('${tempDir.path}/pass.txt');
      await passFile.writeAsString('file-password-123\n');
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('--password 优先于 --password-file', () {
      final runner = buildCliRunner();
      final results = runner.argParser.parse([
        '--password',
        'direct-pass',
        '--password-file',
        passFile.path,
      ]);
      expect(resolveCliPassword(results), equals('direct-pass'));
    });

    test('--password-file 正常读取与坏文件报错', () {
      final runner = buildCliRunner();
      final results = runner.argParser.parse([
        '--password-file',
        passFile.path,
      ]);
      expect(resolveCliPassword(results), equals('file-password-123'));

      final badResults = runner.argParser.parse([
        '--password-file',
        '${tempDir.path}/non-existent.txt',
      ]);
      expect(
        () => resolveCliPassword(badResults),
        throwsA(isA<CliException>()),
      );
    });
  });

  group('CLI 端到端命令流冒烟测试', () {
    late Directory dataDir;
    const password = 'cli-test-password-2026';

    setUp(() async {
      dataDir = await Directory.systemTemp.createTemp('cli_data_');
    });

    tearDown(() async {
      await AppLogFile.close();
      await NotesDatabase.instance.close();
      if (dataDir.existsSync()) {
        await dataDir.delete(recursive: true);
      }
    });

    test(
      '全生命周期: init -> add -> list -> show -> update -> delete -> export -> wipe',
      () async {
        final runner = buildCliRunner();
        final commonArgs = ['--data-dir', dataDir.path, '--password', password];

        // 1. keyring init
        final initRes = await runner.run([...commonArgs, 'keyring', 'init']);
        expect(initRes, contains('keyring 已初始化'));

        // 2. keyring status
        final statusRes = await runner.run([
          ...commonArgs,
          'keyring',
          'status',
        ]);
        expect(statusRes, contains('已初始化: true'));

        // 3. note add
        final addRes = await runner.run([
          ...commonArgs,
          'note',
          'add',
          '--title',
          'First CLI Note',
          '--body',
          'Hello CLI World',
        ]);
        expect(addRes, contains('已创建笔记'));
        final uuidMatch = RegExp(
          r'uuid=([a-f0-9\-]+)',
        ).firstMatch(addRes ?? '');
        expect(uuidMatch, isNotNull);
        final noteUuid = uuidMatch!.group(1)!;

        // 4. note list
        final listRes = await runner.run([...commonArgs, 'note', 'list']);
        expect(listRes, contains('First CLI Note'));
        expect(listRes, contains(noteUuid));

        // 5. note get
        final showRes = await runner.run([
          ...commonArgs,
          'note',
          'get',
          noteUuid,
        ]);
        expect(showRes, contains('First CLI Note'));
        expect(showRes, contains('Hello CLI World'));

        // 6. note update
        final updateRes = await runner.run([
          ...commonArgs,
          'note',
          'update',
          noteUuid,
          '--title',
          'Updated CLI Note',
        ]);
        expect(updateRes, contains('已更新笔记'));

        // 7. export (plaintext)
        final exportRes = await runner.run([
          ...commonArgs,
          'export',
          '--format',
          'plaintext',
        ]);
        expect(exportRes, contains('已导出 1 条笔记'));

        // 8. note delete (软删除)
        final delRes = await runner.run([
          ...commonArgs,
          'note',
          'delete',
          noteUuid,
        ]);
        expect(delRes, contains('已软删除笔记'));

        // 9. note restore (恢复)
        final restoreRes = await runner.run([
          ...commonArgs,
          'note',
          'restore',
          noteUuid,
        ]);
        expect(restoreRes, contains('已恢复笔记'));

        // 10. db info
        final dbInfoRes = await runner.run([...commonArgs, 'db', 'info']);
        expect(dbInfoRes, contains('笔记总数(含回收站): 1'));
        expect(dbInfoRes, contains('回收站(墓碑): 0'));

        // 11. db wipe 确认门（未带 --yes 抛 CliException）
        await expectLater(
          buildCliRunner().run([...commonArgs, 'db', 'wipe']),
          throwsA(
            isA<CliException>().having(
              (e) => e.message,
              'msg',
              contains('--yes'),
            ),
          ),
        );

        // 12. db wipe --yes
        final wipeRes = await buildCliRunner().run([
          ...commonArgs,
          'db',
          'wipe',
          '--yes',
        ]);
        expect(wipeRes, contains('已删除数据库文件与 journal'));
      },
    );

    test('异常处理: 密码错误抛 WrongPasswordException', () async {
      final commonArgs = ['--data-dir', dataDir.path, '--password', password];

      // 首次 init
      await buildCliRunner().run([...commonArgs, 'keyring', 'init']);

      // 使用错误密码执行 note list
      final wrongArgs = [
        '--data-dir',
        dataDir.path,
        '--password',
        'wrong-password',
      ];
      await expectLater(
        buildCliRunner().run([...wrongArgs, 'note', 'list']),
        throwsA(isA<WrongPasswordException>()),
      );
    });

    test('异常处理: 未知子命令抛 UsageException', () async {
      await expectLater(
        buildCliRunner().run(['--data-dir', dataDir.path, 'unknown_command']),
        throwsA(isA<UsageException>()),
      );
    });
  });
}
