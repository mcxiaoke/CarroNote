/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

// lib/src/platform/database_bootstrap_native.dart
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:safenotes/utils/platform_ui.dart';

Future<void> initDatabaseForPlatform({String? dataDirOverride}) async {
  if (isDesktopPlatform) {
    sqfliteFfiInit();
    databaseFactoryOrNull = databaseFactoryFfi;
    final dbDir =
        dataDirOverride ?? (await getApplicationSupportDirectory()).path;
    await databaseFactory.setDatabasesPath(dbDir);
  }
}
