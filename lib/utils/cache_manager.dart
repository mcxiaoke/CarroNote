/*
* Copyright (C) Keshav Priyadarshi and others - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*
* You should have received a copy of the GNU General Public License v3.0 with
* this file. If not, please visit https://www.gnu.org/licenses/gpl-3.0.html
*
* See https://safenotes.dev for support or download.
*/

import 'package:flutter/foundation.dart';

import 'package:path_provider/path_provider.dart';

class CacheManager {
  static Future<void> emptyCache() async {
    if (kIsWeb) return;
    final dir = await getTemporaryDirectory();
    try {
      // 异步递归删除，避免主线程同步阻塞卡 UI
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      await dir.create(recursive: true);
    } catch (_) {
      // 删除失败（文件被占用等）静默忽略，不影响主流程
    }
  }
}
