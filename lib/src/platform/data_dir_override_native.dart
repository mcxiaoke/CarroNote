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
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:safenotes/data/prefs_store_override.dart';
import 'package:safenotes/main.dart' show dataDirOverride;

void applyDataDirOverride() {
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
