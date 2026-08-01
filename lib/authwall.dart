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

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:local_session_timeout/local_session_timeout.dart';

// Project imports:
import 'package:safenotes/views/authentication/login.dart';
import 'package:safenotes/views/authentication/set_passphrase.dart';

/// 启动期 keyring 初始化状态(在 main() 预查询后填充)
///
/// 简化方案:AuthWall 不再读 passPhraseHash 判断路由,改用 Keyring.isInitialized。
/// 为避免 AuthWall 改 StatefulWidget + FutureBuilder 的 UI 闪烁,
/// 在 main() 启动序列里一次性查询并缓存到此单例,AuthWall 直接读取。
class AppBootState {
  /// null=未就绪(启动中), true=已有 keyring(走登录页), false=无 keyring(走设置密码页)
  static bool? vaultInitialized;
}

class AuthWall extends StatelessWidget {
  final StreamController<SessionState> sessionStateStream;
  final bool? isKeyboardFocused;

  const AuthWall({
    super.key,
    required this.sessionStateStream,
    this.isKeyboardFocused,
  });

  @override
  Widget build(BuildContext context) {
    // 简化方案:用 Keyring.isInitialized 判断路由(替代 passPhraseHash)
    // AppBootState.vaultInitialized 在 main() 预初始化时填充
    return AppBootState.vaultInitialized == true
        ? EncryptionPhraseLoginPage(
            sessionStream: sessionStateStream,
            isKeyboardFocused: isKeyboardFocused,
          )
        : SetEncryptionPhrasePage(
            sessionStream: sessionStateStream,
            isKeyboardFocused: isKeyboardFocused,
          );
  }
}
