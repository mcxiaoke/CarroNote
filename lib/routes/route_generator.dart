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
import 'package:page_transition/page_transition.dart';

// Project imports:
import 'package:safenotes/authwall.dart';
import 'package:safenotes/main.dart';
import 'package:safenotes/utils/platform_ui.dart';
import 'package:core/core.dart';
import 'package:safenotes/models/session.dart';
import 'package:safenotes/views/add_edit_note.dart';
import 'package:safenotes/views/authentication/login.dart';
import 'package:safenotes/views/authentication/set_passphrase.dart';
import 'package:safenotes/views/change_passphrase.dart';
import 'package:safenotes/views/deleted_notes.dart';
import 'package:safenotes/views/home.dart';
import 'package:safenotes/views/settings/autorotate_settings.dart';
import 'package:safenotes/views/settings/backup_setting.dart';
import 'package:safenotes/views/settings/biometric_setting.dart';
import 'package:safenotes/views/settings/inactivity_setting.dart';
import 'package:safenotes/views/settings/language_setting.dart';
import 'package:safenotes/views/settings/notes_color_setting.dart';
import 'package:safenotes/views/settings/secure_display_setting.dart';
import 'package:safenotes/views/settings/settings.dart';
import 'package:safenotes/views/settings/sync_diagnostics_page.dart';
import 'package:safenotes/views/settings/sync_settings.dart';

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

      case '/settings':
        if (args is StreamController<SessionState>) {
          return _buildRoute(SettingsScreen(sessionStateStream: args), settings);
        }
        return _errorRoute(
            route: routeName, argsType: 'StreamController<SessionState>');

      case '/chooseColorSettings':
        return _buildRoute(const ColorPallet(), settings);

      case '/inactivityTimerSettings':
        return _buildRoute(const InactivityTimerSetting(), settings);

      case '/chooseLanguageSettings':
        return _buildRoute(const LanguageSetting(), settings);

      case '/secureDisplaySetting':
        return _buildRoute(const SecureDisplaySetting(), settings);

      case '/biometricSetting':
        return _buildRoute(const BiometricSetting(), settings);

      case '/autoRotateSettings':
        return _buildRoute(const AutoRotationSetting(), settings);

      default:
        return _errorRoute(route: routeName);
    }
  }

  /// 统一的页面切换过渡：
  /// - 桌面端（尤其 Windows）用 Fluent 风格的快速淡入，接近原生窗口切换；
  /// - 移动端用 Material fade-through（两层交叉淡入淡出），
  ///   替代原 Web 浏览器式整屏左推（leftToRight）转场。
  static Route<dynamic> _buildRoute(Widget child, RouteSettings settings) {
    if (isDesktopPlatform) {
      return PageTransition(
        child: child,
        duration: const Duration(milliseconds: 250),
        type: PageTransitionType.fade,
      );
    }
    return FadeThroughRoute(
      child: child,
      settings: settings,
      duration: const Duration(milliseconds: 500),
    );
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

/// Material fade-through 过渡路由（Material Motion 层级导航推荐）
///
/// 进入：旧页前半段淡出、新页后半段淡入；返回反向。
/// 需要 [opaque] 为 false，两层页面在过渡期间都可见才能交叉。
class FadeThroughRoute<T> extends PageRouteBuilder<T> {
  FadeThroughRoute({
    required this.child,
    super.settings,
    this.duration = const Duration(milliseconds: 500),
  }) : super(
          transitionDuration: duration,
          reverseTransitionDuration: duration,
          opaque: false,
          pageBuilder: (_, _, _) => child,
          transitionsBuilder: _fadeThroughTransitions,
        );

  final Widget child;
  final Duration duration;

  static Widget _fadeThroughTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // 新页：animation 0→1 时在后 60%（0.4~1.0）淡入；返回时前 60% 淡出。
    final CurvedAnimation fadeIn = CurvedAnimation(
      parent: animation,
      curve: const Interval(0.4, 1.0, curve: Curves.easeInOut),
      reverseCurve: const Interval(0.0, 0.6, curve: Curves.easeInOut),
    );
    // 旧页：被覆盖（secondaryAnimation 0→1）时在前 60% 淡出。
    final CurvedAnimation fadeOut = CurvedAnimation(
      parent: secondaryAnimation,
      curve: const Interval(0.0, 0.6, curve: Curves.easeInOut),
      reverseCurve: const Interval(0.4, 1.0, curve: Curves.easeInOut),
    );
    return FadeTransition(
      opacity: fadeIn,
      child: FadeTransition(
        opacity: Tween<double>(begin: 1.0, end: 0.0).animate(fadeOut),
        child: child,
      ),
    );
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

