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
import 'dart:convert';

// Package imports:
import 'package:crypto/crypto.dart';
import 'package:local_session_timeout/local_session_timeout.dart';

// Project imports:
import 'package:safenotes/data/database_handler.dart';
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/biometric_auth.dart';
import 'package:safenotes/sync/sync_service.dart';
import 'package:safenotes/utils/scheduled_task.dart';

class Session {
  static login(String passphrase) {
    PhraseHandler.initPass(passphrase);
  }

  static logout() async {
    // Take care of backup if enabled
    await ScheduledTask.backup();

    // 清除同步相关敏感数据（与 UI 的"先导航、再清状态"顺序配合：
    // 导航走 /authwall 后 HomePage 已卸载，此时清 key 不会再打到挂载中的页面，
    // 也不会让在途的 refreshNotes 因 dataKey 被清空而抛异常）。
    await SyncService.instance.logout();
    NotesDatabase.instance.clearDataKey();

    // 清除明文密码（与原版一致）
    PhraseHandler.destroy();
  }

  static setOrChangePassphrase(String passphrase) {
    PreferencesStorage.setPassPhraseHash(
        sha256.convert(utf8.encode(passphrase)).toString());
    PhraseHandler.initPass(passphrase);
    if (PreferencesStorage.isBiometricAuthEnabled) BiometricAuth.setAuthKey();
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
