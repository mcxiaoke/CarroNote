/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

/*
 * 自定义 SharedPreferences 存储后端（数据目录覆盖用）
 *
 * 场景：集成测试 / 特殊构建需要用「独立数据目录」跑真实 App，避免污染
 * 本机真实数据。老式 `SharedPreferences.getInstance()` 内部读写的是全局
 * 单例 `SharedPreferencesStorePlatform.instance`，我们把该单例换成指向
 * 独立目录 JSON 文件的实现，即可让 DB、日志、prefs 全部落到同一隔离目录。
 *
 * 键语义与平台实现一致：键「原样」存储（含 legacy 的 'flutter.' 前缀），
 * 由 `SharedPreferences` 自身负责前缀的写入与剥离，因此本实现只需按前缀
 * 过滤读写，与 `InMemorySharedPreferencesStore` 行为对齐。
 */

import 'dart:convert';

import 'package:safenotes/src/platform/platform_io.dart';

import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

/// 把 prefs 持久化到指定目录的 JSON 文件（`preferences.json`）的文件版 store。
///
/// 用于测试/隔离数据目录：`main.dart` 在读环境变量 `SN_DATA_DIR` 时，
/// 将 `SharedPreferencesStorePlatform.instance` 替换为本类实例。
class FilePreferencesStore extends SharedPreferencesStorePlatform {
  FilePreferencesStore(this._file);

  final File _file;
  Map<String, Object> _data = <String, Object>{};

  Future<void> _load() async {
    if (_file.existsSync()) {
      try {
        final raw = jsonDecode(_file.readAsStringSync());
        if (raw is Map) {
          _data = Map<String, Object>.from(raw);
        }
      } on Object {
        // 文件损坏视为空，避免启动崩溃（与平台默认行为一致：缺失即默认值）
        _data = <String, Object>{};
      }
    }
  }

  Future<void> _persist() async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(jsonEncode(_data));
  }

  @override
  Future<Map<String, Object>> getAll() => getAllWithPrefix('flutter.');

  @override
  Future<Map<String, Object>> getAllWithPrefix(String prefix) async {
    await _load();
    return Map<String, Object>.fromEntries(
      _data.entries.where((e) => e.key.startsWith(prefix)),
    );
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    await _load();
    _data[key] = value;
    await _persist();
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    await _load();
    _data.remove(key);
    await _persist();
    return true;
  }

  @override
  Future<bool> clear() async {
    _data = <String, Object>{};
    await _persist();
    return true;
  }
}
