/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

// SafeNotes 核心逻辑唯一公开出口。
//
// 本包为纯 Dart（无 Flutter 依赖），包含加密 / 数据库 / 同步引擎核心逻辑。
// App 侧与 CLI 侧统一从此入口导入符号。

export 'src/crypto/crypto.dart';
export 'src/db/database_handler.dart';
export 'src/logger/app_logger.dart';
export 'src/models/backup_file.dart';
export 'src/models/note_meta.dart';
export 'src/models/parse_import.dart';
export 'src/models/safenote.dart';
export 'src/ports.dart';
export 'src/sync/backends/local_fs_backend.dart';
export 'src/sync/backends/safe_server_backend.dart';
export 'src/sync/backends/webdav_backend.dart';
export 'src/sync/journal.dart';
export 'src/sync/keyring.dart';
export 'src/sync/sync_backend.dart';
export 'src/sync/sync_engine.dart';
export 'src/sync/sync_error.dart';
export 'src/sync/sync_models.dart';
