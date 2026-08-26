/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

// 应用私有数据目录的通用注入点。
//
// core 为纯 Dart 包，无法直接调用 path_provider 获取各平台的应用数据目录；
// 由 App 启动时（main.dart）注入 path_provider 的解析结果，CLI/测试注入
// 临时目录。供 core 内所有「非 DB 文件」的落盘需求复用（如 M1 隔离副本、
// 未来的临时文件等），避免每个功能各自造一个 *Override 注入点。
library;

import 'package:path/path.dart' as p;

/// 应用路径注入点（解耦 path_provider）。
class AppPaths {
  AppPaths._();

  /// 应用私有数据目录（各平台 path_provider 的应用数据目录）。
  ///
  /// 未注入时为 null；调用方应自行降级（如跳过落盘、仅记日志）。
  static String? appDataDir;

  /// 是否已注入可用的应用数据目录。
  static bool get isAvailable => appDataDir != null && appDataDir!.isNotEmpty;

  /// 组合子目录：`<appDataDir>/<sub>`；未注入时返回 null。
  ///
  /// 例：`AppPaths.subDir('broken_notes')` → `<appDataDir>/broken_notes`。
  static String? subDir(String sub) {
    if (!isAvailable) return null;
    return p.join(appDataDir!, sub);
  }

  /// 清除注入（测试隔离 / 应用退出时使用）。
  static void reset() => appDataDir = null;
}
