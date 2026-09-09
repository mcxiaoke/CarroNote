/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

// lib/src/platform/data_dir_override_web.dart

void applyDataDirOverride() {
  // Web 平台无本地文件系统与环境变量，直接空操作
}

/// Web 平台无本地文件系统，此函数不会被实际调用
/// （调用方在 Web 上已走 [kIsWeb] 分支提前返回）。
Future<String> getEffectiveAppSupportPath() async {
  throw UnsupportedError('getEffectiveAppSupportPath is not supported on web');
}
