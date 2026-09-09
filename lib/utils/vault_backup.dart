/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

// 重置前保险库快照备份（忘记密码逃生通道的安全网）
//
// 背景：忘记密码重置原本直接删除数据库文件，过于激进——一旦用户
// 之后想起密码（或想找回旧数据），数据已不可恢复。现在重置前先把
// 加密数据库文件 + 偏好设置快照复制到应用数据根目录的 backups/ 下，
// 保留最近 [maxKeptBackups] 份。
//
// 安全性：数据库内容为字段级 AES-GCM 加密，无密码不可解密；
// 偏好 dump 仅含 UI/功能开关，不含任何密钥类数据。

import 'dart:convert';

import 'package:safenotes/src/platform/platform_io.dart';

import 'package:core/core.dart';
import 'package:path/path.dart' as p;

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/src/platform/data_dir_override.dart';

/// 保留的重置前快照份数（超出删除最旧）
const int maxKeptBackups = 5;

/// 备份保险库快照（调用方必须先 [NotesDatabase.close] 关闭连接，
/// 否则文件被占用，复制到中途可能得到不一致的副本）
///
/// 备份位置：<应用数据根目录>/backups/`pre-reset-<yyyyMMdd_HHmmss>/`
///   - safenotes_sync.db      加密数据库文件（笔记 + keyring 元数据）
///   - preferences.json       偏好设置 dump（明文，仅 UI/功能开关）
///
/// 应用数据根目录取 getEffectiveAppSupportPath()
/// （优先使用 portable mode / 测试覆盖目录，否则回退到
/// getApplicationSupportDirectory()：Windows=`%APPDATA%\<app>`，
/// macOS=`~/Library/Application Support/<app>`，
/// 移动端=应用沙箱数据目录），不随 db 目录（移动端在 databases/ 子目录）漂移。
///
/// 返回创建的备份目录；失败抛异常，调用方应中止重置。
Future<Directory> backupVaultBeforeReset() async {
  final dbPath = await NotesDatabase.instance.dbFilePath();
  final dbFile = File(dbPath);
  if (!await dbFile.exists()) {
    throw Exception('database file not found: $dbPath');
  }

  final stamp = _timestamp();
  final appDataRoot = await getEffectiveAppSupportPath();
  final backupRoot = Directory(p.join(appDataRoot, 'backups'));
  final target = Directory(p.join(backupRoot.path, 'pre-reset-$stamp'));
  await target.create(recursive: true);

  // 1. 复制加密数据库文件（字段级加密，无密码不可解密）
  await dbFile.copy(p.join(target.path, p.basename(dbPath)));

  // 2. 写偏好设置 dump（明文 JSON，仅 UI/功能开关，不含密钥）
  final prefs = PreferencesStorage.dumpAll();
  final prefsFile = File(p.join(target.path, 'preferences.json'));
  await prefsFile.writeAsString(
    const JsonEncoder.withIndent('  ').convert(prefs),
    flush: true,
  );

  Log.auth.i('重置前保险库快照已保存: ${target.path}');
  await _pruneOldBackups(backupRoot);
  return target;
}

/// 删除超出保留份数的旧快照（按目录名时间戳排序，删最旧）
Future<void> _pruneOldBackups(Directory root) async {
  if (!await root.exists()) return;
  final dirs =
      (await root.list().toList())
          .whereType<Directory>()
          .where((d) => p.basename(d.path).startsWith('pre-reset-'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  while (dirs.length > maxKeptBackups) {
    final oldest = dirs.removeAt(0);
    try {
      await oldest.delete(recursive: true);
      Log.auth.i('已清理旧的重置快照: ${oldest.path}');
    } on Exception catch (e) {
      // 清理失败不影响本次重置流程，仅留痕
      Log.auth.w('清理旧的重置快照失败（忽略）: ${oldest.path}', error: e);
    }
  }
}

/// 本地时间戳（文件名安全格式）
String _timestamp() {
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${now.year}${two(now.month)}${two(now.day)}'
      '_${two(now.hour)}${two(now.minute)}${two(now.second)}';
}
