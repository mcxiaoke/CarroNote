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
import 'package:easy_localization/easy_localization.dart';
import 'package:local_session_timeout/local_session_timeout.dart';

// Project imports:
import 'package:safenotes/authwall.dart';
import 'package:safenotes/main.dart';
import 'package:core/core.dart';
import 'package:safenotes/models/session.dart';
import 'package:safenotes/views/add_edit_note.dart';
import 'package:safenotes/views/authentication/login.dart';
import 'package:safenotes/views/authentication/set_passphrase.dart';
import 'package:safenotes/views/change_passphrase.dart';
import 'package:safenotes/views/deleted_notes.dart';
import 'package:safenotes/views/home.dart';
import 'package:safenotes/views/settings/backup_setting.dart';
import 'package:safenotes/views/settings/biometric_setting.dart';
import 'package:safenotes/views/settings/inactivity_setting.dart';
import 'package:safenotes/views/settings/language_setting.dart';
import 'package:safenotes/views/settings/notes_color_setting.dart';
import 'package:safenotes/views/settings/settings.dart';
import 'package:safenotes/views/settings/sync_diagnostics_page.dart';
import 'package:safenotes/views/settings/sync_settings.dart';
import 'package:safenotes/views/settings/theme_color_setting.dart';
import 'package:safenotes/views/settings/about_page.dart';

class RouteGenerator {
  static Route<dynamic> generateRoute(RouteSettings settings) {
    // Getting arguments passed in while calling Navigator.pushNamed
    var args = settings.arguments;
    final String? routeName = settings.name;
    // 集中记录每一次路由解析(界面切换的底层入口),便于全链路追踪
    Log.ui.d('路由解析: $routeName');

    switch (routeName) {
      case '/':
        return _buildRoute(const SafeNotesApp(), settings);

      case '/login':
        if (args is SessionArguments) {
          return _buildRoute(
            EncryptionPhraseLoginPage(
              sessionStream: args.sessionStream,
              isKeyboardFocused: args.isKeyboardFocused,
            ),
            settings,
          );
        }
        return _errorRoute(
            route: routeName, argsType: 'StreamController<SessionState>');

      case '/signup':
        if (args is SessionArguments) {
          return _buildRoute(
            SetEncryptionPhrasePage(
              sessionStream: args.sessionStream,
              isKeyboardFocused: args.isKeyboardFocused,
            ),
            settings,
          );
        }
        return _errorRoute(
            route: routeName, argsType: 'StreamController<SessionState>');

      case '/authwall':
        if (args is SessionArguments) {
          return _buildRoute(
            AuthWall(
              sessionStateStream: args.sessionStream,
              isKeyboardFocused: args.isKeyboardFocused,
            ),
            settings,
          );
        }
        return _errorRoute(
            route: routeName, argsType: 'StreamController<SessionState>');

      case '/home':
        if (args is StreamController<SessionState>) {
          return _buildRoute(HomePage(sessionStateStream: args), settings);
        }
        return _errorRoute(
            route: routeName, argsType: 'StreamController<SessionState>');

      case '/addnote':
        if (args is StreamController<SessionState>) {
          return _buildRoute(AddEditNotePage(sessionStateStream: args), settings);
        }
        return _errorRoute(
            route: routeName, argsType: 'StreamController<SessionState>');

      case '/editnote':
        if (args is AddEditNoteArguments) {
          return _buildRoute(
            AddEditNotePage(
              sessionStateStream: args.sessionStream,
              note: args.note,
            ),
            settings,
          );
        }
        return _errorRoute(route: routeName, argsType: 'SafeNotes');

      case '/backup':
        return _buildRoute(const BackupSetting(), settings);

      case '/changepassphrase':
        return _buildRoute(const ChangePassphrase(), settings);

      case '/syncSettings':
        return _buildRoute(const SyncSettingsPage(), settings);

      case '/diagnostics':
        return _buildRoute(const SyncDiagnosticsPage(), settings);

      case '/deletedNotes':
        return _buildRoute(const DeletedNotesPage(), settings);

      case '/about':
        return _buildRoute(const AboutPage(), settings);

      case '/settings':
        if (args is StreamController<SessionState>) {
          return _buildRoute(SettingsScreen(sessionStateStream: args), settings);
        }
        return _errorRoute(
            route: routeName, argsType: 'StreamController<SessionState>');

      case '/chooseColorSettings':
        return _buildRoute(const ColorPallet(), settings);

      case '/themeColorSettings':
        return _buildRoute(const ThemeColorPicker(), settings);

      case '/inactivityTimerSettings':
        return _buildRoute(const InactivityTimerSetting(), settings);

      case '/chooseLanguageSettings':
        return _buildRoute(const LanguageSetting(), settings);

      case '/biometricSetting':
        return _buildRoute(const BiometricSetting(), settings);

      default:
        return _errorRoute(route: routeName);
    }
  }

  /// 统一的页面切换过渡：全平台使用 Flutter 平台默认转场
  /// （MaterialPageRoute 走 pageTransitionsTheme）：
  /// - Android = FadeForwards（含预测性返回手势）、iOS/macOS = Cupertino 滑动 +
  ///   边缘返回、Windows/Linux = Zoom。符合官方 M3 推荐 forward/backward 用
  ///   平台默认，随平台更新自动演进；默认转场均为 opaque，底层有旧页面/背景色
  ///   垫底，不会出现此前 FadeThroughRoute 交叉淡出中间段的双透明黑屏。
  /// - 笔记卡片点击的"卡片放大进入编辑页"由 OpenContainer（animations 包）
  ///   在 home 卡片处独立实现，不经过本路由。
  static Route<dynamic> _buildRoute(Widget child, RouteSettings settings) {
    return MaterialPageRoute(builder: (_) => child, settings: settings);
  }

  static Route<dynamic> _errorRoute(
      {required String? route, String? argsType}) {
    // 路由解析失败是异常情况,需以 warning 级别暴露(参数缺失或路由不存在)
    Log.ui.w('路由解析失败: route=$route'
        '${argsType != null ? ", 期望参数类型=$argsType" : ""}');
    return MaterialPageRoute(builder: (_) {
      return Scaffold(
        appBar: AppBar(title: Text('Route Error'.tr())),
        body: Padding(
          padding: const EdgeInsets.only(left: 5, right: 5),
          child: Center(
            child: argsType == null
                ? Text('No route: {route}'
                    .tr(namedArgs: {'route': route.toString()}))
                : Text(
                    '{argsType}, Needed for route: {route}'.tr(namedArgs: {
                      'argsType': argsType,
                      'route': route.toString()
                    }),
                  ),
          ),
        ),
      );
    });
  }
}

class AddEditNoteArguments {
  final StreamController<SessionState> sessionStream;
  final SafeNote? note;

  AddEditNoteArguments({
    required this.sessionStream,
    this.note,
  });
}
