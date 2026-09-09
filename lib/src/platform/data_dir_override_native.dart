/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

// lib/src/platform/data_dir_override_native.dart
import 'dart:io';

import 'package:core/core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:safenotes/data/prefs_store_override.dart';
import 'package:safenotes/main.dart' show dataDirOverride;

/// portable 模式标记文件名。
///
/// exe 同级目录存在此文件时启用 portable mode，所有数据写入 exe 旁边的
/// `app_data/` 子目录。当前作为标记文件（存在即可），未来可扩展为 INI 配置。
const String kPortableMarkerFile = 'portable.ini';

/// portable 模式数据子目录名。
///
/// 不能用 `data`——Flutter Windows 构建产物的 exe 同级已有 `data/`
/// 目录（内含 `app.so`、`flutter_assets/`、`icudtl.dat` 等运行时文件），
/// 同名会冲突。用 `app_data` 避免覆盖运行时资源。
const String kPortableDataDir = 'app_data';

/// 检测 portable 模式标记文件。
///
/// 在 exe 所在目录查找 [kPortableMarkerFile]；存在则返回 exe 同级目录下
/// [kPortableDataDir] 的完整路径，否则返回 null。
String? _detectPortableMode() {
  try {
    final exePath = Platform.resolvedExecutable;
    final exeDir = File(exePath).parent.path;
    final marker = File(p.join(exeDir, kPortableMarkerFile));
    if (marker.existsSync()) {
      return p.join(exeDir, kPortableDataDir);
    }
  } on Object catch (e) {
    // resolvedExecutable 在某些平台/构建下可能抛异常，安全降级
    Log.app.w('Portable mode 检测失败，忽略: $e');
  }
  return null;
}

void applyDataDirOverride() {
  // 1) Portable mode: exe 同级目录存在 portable.ini → 数据放 exe 同级 app_data/
  final portableDir = _detectPortableMode();
  if (portableDir != null) {
    dataDirOverride = portableDir;
  }

  // 2) 环境变量覆盖（优先级更高，用于测试/特殊场景）
  final env = Platform.environment['SN_DATA_DIR'];
  if (env != null && env.isNotEmpty) {
    dataDirOverride = env;
  }

  final dir = dataDirOverride;
  if (dir == null) return;
  SharedPreferencesStorePlatform.instance = FilePreferencesStore(
    File(p.join(dir, 'preferences.json')),
  );
  Log.app.i('数据目录覆盖: $dir');
}

/// 返回有效的应用数据目录路径。
///
/// 优先使用 [dataDirOverride]（portable mode / 测试覆盖），
/// 否则回退到 [getApplicationSupportDirectory] 的平台默认位置。
///
/// 调用方无需各自判断 override 状态，统一走此函数即可。
Future<String> getEffectiveAppSupportPath() async {
  final dir = dataDirOverride;
  if (dir != null && dir.isNotEmpty) {
    return dir;
  }
  return (await getApplicationSupportDirectory()).path;
}
