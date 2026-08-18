/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

// SafeNotes 核心逻辑 CLI —— 纯 Dart 驱动的真实流程测试 / 互操作验证入口。
//
// CLI 是核心逻辑的第二个前端（App 是第一个）。它一旦编译不过，就说明有人往
// core 里塞了 Flutter 依赖——这是架构约束的守卫。
//
// 设计文档：docs/cli-client-design-20260803.md
//
// 用法：
//   dart run bin/safenotes_cli.dart <命令> [子命令] [--data-dir DIR] [--password P]
//   dart run bin/safenotes_cli.dart help          # 全部命令帮助
//   dart run bin/safenotes_cli.dart note list     # 示例
//
// 约定：
//   - 全局参数（--data-dir/--password/--password-file/--device-id）必须写在
//     命令名之前；子命令参数写在其后。
//   - 退出码：0=成功；1=用户可预期错误（密码错/未找到/参数错误/同步失败）；
//     2=未预期异常。帮助/用法错误由 args 抛 UsageException，统一打印后退出。
//   - 输出默认文本，叶子命令可加 --json 输出机器可读 JSON。

// Dart 原生导入

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:core/core.dart';

import 'cli_commands.dart';
import 'cli_context.dart';

// Package 导入

// 项目导入

Future<void> main(List<String> args) async {
  final runner = buildCliRunner();
  try {
    final result = await runner.run(args);
    if (result is String && result.isNotEmpty) {
      stdout.writeln(result);
    }
  } on UsageException catch (e) {
    // 参数解析 / 用法错误：args 包已生成消息，这里直接展示（不打印堆栈）
    stderr.writeln(e.message);
    stderr.writeln();
    stderr.writeln(runner.usage);
    exitCode = 64;
  } on CliException catch (e) {
    // 用户可预期错误：只打印一行消息
    stderr.writeln('错误: ${e.message}');
    exitCode = 1;
  } on WrongPasswordException catch (e) {
    stderr.writeln('错误: 密码错误（${e.message}）');
    exitCode = 1;
  } on KeyringNotInitializedException catch (e) {
    stderr.writeln('错误: keyring 未初始化（${e.message}）');
    exitCode = 1;
  } catch (e, st) {
    // 未预期异常：带堆栈，退出码 2
    stderr.writeln('异常: $e');
    stderr.writeln(st);
    exitCode = 2;
  }
}
