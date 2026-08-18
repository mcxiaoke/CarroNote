/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

// SafeNotes 核心层端口（Ports）定义。
//
// 沿用 SyncBackend 的抽象风格，为核心层所需的「平台能力」定义最小接口。
// App 侧用 path_provider / shared_preferences / flutter_secure_storage 实现；
// CLI / 测试侧用临时目录 / JSON 文件 / 环境变量实现。
// 只抽必需的端口，不为架构而架构。

import 'logger/app_logger.dart';

/// 目录解析：日志目录、数据库目录、缓存目录。
abstract interface class PathProvider {
  /// 应用数据根目录（数据库、缓存等文件落盘位置）。
  Future<String> dataDir();

  /// 日志目录（可 null，null 表示日志文件功能降级）。
  Future<String?> logDir();
}

/// 普通键值存储（当前由 shared_preferences 承担）。
abstract interface class KeyValueStore {
  String? getString(String key);
  Future<void> setString(String key, String value);
  Future<void> remove(String key);
}

/// 安全存储（当前由 flutter_secure_storage 承担）。
abstract interface class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// 日志下沉（core 只产生日志事件，写文件 / 控制台由外部决定）。
abstract interface class LogSink {
  void write(
    AppLogLevel level,
    String tag,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  });
}
