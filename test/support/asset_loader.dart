/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Locale;

import 'package:easy_localization/easy_localization.dart';

// 测试用翻译加载器（所有 widget 测试共享，替代各文件重复复制）。
//
// 背景：flutter test 的资源 bundle 不含项目翻译文件，需要自行加载。
// 原先直接用 `dart:io` 的 `File.readAsString` 从磁盘读取，但在本机测试沙箱里
// 该调用会**永久挂起**（文件 I/O 被阻断，且会冻结事件循环，连超时定时器都无法触发），
// 导致 EasyLocalization 的 LocalizationsResolver 永远不就绪 → 整个 App 被渲染成
// `SizedBox.shrink()` → AuthWall 从未构建 → 所有 `find.text` 断言失败。
//
// 改用 `rootBundle.loadString`：它走 Flutter 的 asset bundle（pubspec 已声明
// `assets/translations/`），在 flutter test 下可正常加载，且不会触发被阻断的
// dart:io 文件 I/O。en-US.json 的键与英文值一致（如 "Login"→"Login"），缺失的键
// `.tr()` 会回退到键本身，因此测试断言的英文文本与加载真实翻译后渲染的文本一致。
// 若加载仍失败，退化为空表（.tr() 返回 key），保证 UI 仍能渲染、可被驱动。
//
// 记忆化（按 locale 缓存 Future）：首个 EasyLocalization 实例卸载后，本机沙箱里
// 第二次调用 `rootBundle.loadString` 会再次挂起（事件循环被冻结），表现为后续
// `pumpWidget` 永远渲染不出 App。同一进程内翻译不会变化，故每个 locale 只加载一次，
// 既规避二次挂起，又提升确定性、减少重复 I/O。
class TestAssetLoader extends AssetLoader {
  static final Map<String, Future<Map<String, dynamic>?>> _cache = {};

  @override
  Future<Map<String, dynamic>?> load(String path, Locale locale) async {
    final code = locale.countryCode == null
        ? locale.languageCode
        : '${locale.languageCode}-${locale.countryCode}';
    final cacheKey = '$path/$code';
    return _cache.putIfAbsent(cacheKey, () async {
      try {
        final raw = await rootBundle.loadString('$cacheKey.json');
        return jsonDecode(raw) as Map<String, dynamic>;
      } on Object {
        // 退化：返回空表，.tr() 直接返回 key（英文），不影响 UI 渲染与驱动。
        return <String, dynamic>{};
      }
    });
  }
}