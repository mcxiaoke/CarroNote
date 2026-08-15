// 测试用翻译加载器（共享版本）
//
// 背景：flutter test 的资源 bundle 不含项目翻译文件，需要自行加载。
// 本文件将分散在各测试文件中的 _TestAssetLoader 集中到一处，统一维护。
//
// 用法：
//   assetLoader: TestAssetLoader(),
//
// 特性：
//   - 按 [语言-国家, 语言, en-US] 顺序回退
//   - 记忆化缓存（按 locale 缓存 Future），避免同一进程内二次加载挂起
//   - 加载失败退化返回空表（.tr() 返回 key），保证 UI 仍能渲染

// Dart imports:
import 'dart:convert';

// Flutter imports:
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Package imports:
import 'package:easy_localization/easy_localization.dart';

/// 测试用翻译加载器。
///
/// 走 `rootBundle.loadString`（Flutter asset bundle），避免 dart:io 文件 I/O
/// 在 flutter test 沙箱中永久挂起的问题。
///
/// 记忆化（按 locale 缓存 Future）：首个 EasyLocalization 实例卸载后，本机沙箱里
/// 第二次调用 `rootBundle.loadString` 会再次挂起（事件循环被冻结），表现为后续
/// `pumpApp` 永远渲染不出 App。同一进程内翻译不会变化，故每个 locale 只加载一次，
/// 既规避二次挂起，又提升确定性、减少重复 I/O。
class TestAssetLoader extends AssetLoader {
  static final Map<String, Future<Map<String, dynamic>?>> _cache = {};

  @override
  Future<Map<String, dynamic>?> load(String path, Locale locale) async {
    final candidates = <String>[
      if (locale.countryCode != null && locale.countryCode!.isNotEmpty)
        '${locale.languageCode}-${locale.countryCode}',
      locale.languageCode,
      'en-US',
    ];
    // 用第一个候选作为缓存 key
    final cacheKey = '$path/${candidates.first}';
    return _cache.putIfAbsent(cacheKey, () async {
      for (final code in candidates) {
        try {
          final raw = await rootBundle.loadString('$path/$code.json');
          return jsonDecode(raw) as Map<String, dynamic>;
        } on Object {
          // 该候选不存在，尝试下一个
        }
      }
      // 退化：返回空表，.tr() 直接返回 key（英文），不影响 UI 渲染与驱动。
      return <String, dynamic>{};
    });
  }
}