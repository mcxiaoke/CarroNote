/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

// AppPaths 通用应用数据目录注入测试。
//
// 覆盖：默认未注入降级、注入后 subDir 拼接、空串视为未注入、reset 清理。

import 'dart:io';

import 'package:core/core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  setUp(AppPaths.reset);
  tearDown(AppPaths.reset);

  test('默认未注入：不可用，subDir 返回 null', () {
    expect(AppPaths.isAvailable, isFalse);
    expect(AppPaths.subDir('broken_notes'), isNull);
  });

  test('注入后：isAvailable 为 true，subDir 正确拼接', () {
    final dir = Directory.systemTemp.createTempSync('app_paths_test');
    addTearDown(() => dir.deleteSync(recursive: true));

    AppPaths.appDataDir = dir.path;
    expect(AppPaths.isAvailable, isTrue);
    expect(AppPaths.subDir('broken_notes'), p.join(dir.path, 'broken_notes'));
    // 不产生副作用：subDir 只拼接，不创建目录
    expect(Directory(AppPaths.subDir('broken_notes')!).existsSync(), isFalse);
  });

  test('空串视为未注入', () {
    AppPaths.appDataDir = '';
    expect(AppPaths.isAvailable, isFalse);
    expect(AppPaths.subDir('broken_notes'), isNull);
  });

  test('reset 清除注入', () {
    final dir = Directory.systemTemp.createTempSync('app_paths_reset');
    addTearDown(() => dir.deleteSync(recursive: true));

    AppPaths.appDataDir = dir.path;
    expect(AppPaths.isAvailable, isTrue);
    AppPaths.reset();
    expect(AppPaths.isAvailable, isFalse);
  });
}
