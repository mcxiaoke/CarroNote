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

// Dart imports:
import 'dart:async';

// Package imports:
import 'package:local_session_timeout/local_session_timeout.dart';

// Project imports:
import 'package:safenotes/data/database_handler.dart';
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/biometric_auth.dart';
import 'package:safenotes/sync/sync_service.dart';
import 'package:safenotes/utils/app_logger.dart';
import 'package:safenotes/utils/scheduled_task.dart';

class Session {
  static void login(String passphrase) {
    // 只记录长度，绝不记录密码明文（隐私红线）
    Log.auth.i('会话登录: 已装载密码短语 (长度=${passphrase.length})');
    PhraseHandler.initPass(passphrase);
  }

  static Future<void> logout() async {
    final sw = Stopwatch()..start();
    Log.auth.i('会话登出: 开始清理会话与敏感数据');

    // Take care of backup if enabled
    await ScheduledTask.backup();

    // 清除同步相关敏感数据（与 UI 的"先导航、再清状态"顺序配合：
    // 导航走 /authwall 后 HomePage 已卸载，此时清 key 不会再打到挂载中的页面，
    // 也不会让在途的 refreshNotes 因 dataKey 被清空而抛异常）。
    await SyncService.instance.logout();
    Log.sync.d('会话登出: 同步服务已登出并释放密钥');

    NotesDatabase.instance.clearDataKey();
    Log.crypto.i('会话登出: 内存中的 dataKey 已清除');

    // 清除明文密码（与原版一致）
    PhraseHandler.destroy();

    Log.auth.i('会话登出完成, 耗时 ${sw.elapsedMilliseconds}ms');
  }

  /// 密码设置/变更后的副作用处理（简化方案：不再写 passPhraseHash）
  ///
  /// 保留 PhraseHandler 和 biometric 更新：
  ///   - PhraseHandler.getPass:biometric 登录需要原始 password 来解锁 keyring
  ///   - BiometricAuth.setAuthKey:secure storage 存新密码
  ///
  /// 调用时机：
  ///   - set_passphrase 首次设置密码成功后
  ///   - change_passphrase 改密码成功后
  static void onPasswordSet(String passphrase) {
    // 密码变更是高重要性事件，用 info 级别；只记录长度不记录明文
    Log.auth.i('密码已设置/变更: 更新会话密码短语 (长度=${passphrase.length})');
    PhraseHandler.initPass(passphrase);
    if (PreferencesStorage.isBiometricAuthEnabled) {
      Log.auth.i('生物识别已启用: 同步刷新安全存储中的认证凭据');
      BiometricAuth.setAuthKey();
    } else {
      Log.auth.d('生物识别未启用: 跳过认证凭据刷新');
    }
  }
}

class SessionArguments {
  final StreamController<SessionState> sessionStream;
  final bool? isKeyboardFocused;

  SessionArguments({
    required this.sessionStream,
    this.isKeyboardFocused,
  });
}
