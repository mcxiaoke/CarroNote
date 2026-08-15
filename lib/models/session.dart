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

/// 路由参数（登录/设置密码/锁定流程用）。
///
/// 会话的登录/登出/改密码副作用已迁移到 [SessionProvider]
/// （见 `lib/models/session_provider.dart`），本文件仅保留路由参数类型。
class SessionArguments {
  final StreamController<SessionState> sessionStream;
  final bool? isKeyboardFocused;

  SessionArguments({required this.sessionStream, this.isKeyboardFocused});
}
