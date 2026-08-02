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
import 'dart:io' show Platform;
import 'dart:ui' show PlatformDispatcher;

// Flutter imports:
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Package imports:
import 'package:easy_localization/easy_localization.dart';
import 'package:local_session_timeout/local_session_timeout.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Project imports:
import 'package:safenotes/app.dart';
import 'package:safenotes/authwall.dart';
import 'package:safenotes/data/database_handler.dart';
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/dialogs/generic.dart';
import 'package:safenotes/dialogs/logout_alert.dart';
import 'package:safenotes/models/editor_state.dart';
import 'package:safenotes/models/session.dart';
import 'package:safenotes/sync/sync_service.dart';
import 'package:safenotes/sync/keyring.dart';
import 'package:safenotes/utils/app_logger.dart';
import 'package:safenotes/utils/build_info.dart';
import 'package:safenotes/utils/lifecycle_handler.dart';
import 'package:safenotes/utils/log_webserver.dart';
import 'package:safenotes/utils/scheduled_task.dart';
import 'package:safenotes/views/settings/backup_setting.dart';

Future main() async {
  // runZonedGuarded 捕获所有异步未捕获异常（Zone 级兜底）。
  // 必须把 ensureInitialized 和 runApp 放在同一个 Zone 内，
  // 否则 Flutter 会抛 "Zone mismatch" 错误。
  runZonedGuarded<Future<void>>(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // ① 日志系统必须最先初始化，保证后续任何环节的错误都能落盘
      await _initLogging();

      // ② 安装全局错误钩子（同步错误 + 平台层错误）
      _installGlobalErrorHandlers();

      await _bootstrap();
    },
    (error, stack) {
      // Zone 级未捕获异常：走到这里说明没有任何 try/catch 处理它
      Log.app.f('未捕获的异步异常', error: error, stackTrace: stack);
    },
  );
}

/// 初始化日志系统（全平台一致：移动端 + 桌面端）
Future<void> _initLogging() async {
  await AppLogFile.init();
  Log.app.i('════════ SafeNotes 启动 ════════');
  // 版本详细信息（含构建期注入的 Git 提交哈希与构建时间）
  Log.app.i('版本: ${BuildInfo.version} (build ${BuildInfo.buildNumber})');
  Log.app.i('Git: ${BuildInfo.gitHashShort} @ ${BuildInfo.gitBranch}'
      '${BuildInfo.gitDirty ? " (工作区有未提交改动)" : ""}');
  Log.app.i('Commit: ${BuildInfo.gitHash}');
  Log.app.i('Tag: ${BuildInfo.gitTag.isEmpty ? "无 tag" : BuildInfo.gitTag} '
      '(累计提交 ${BuildInfo.gitCommitCount})');
  Log.app.i('构建时间: ${BuildInfo.buildDateReadable} (UTC ${BuildInfo.buildDate})');
  Log.app.i('平台: ${Platform.operatingSystem} '
      '${Platform.operatingSystemVersion}');
  Log.app.i('Dart: ${Platform.version.split(' ').first}');
  Log.app.i('日志目录: ${AppLogFile.dirPath ?? "不可用（仅内存 + 控制台）"}');
}

/// 安装全局错误钩子，确保所有 Exception / Error 都进日志
void _installGlobalErrorHandlers() {
  // Flutter framework 内部错误（build / layout / paint 阶段等）
  final previousOnError = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    Log.app.e(
      'Flutter 框架异常${details.context != null ? "（${details.context}）" : ""}',
      error: details.exception,
      stackTrace: details.stack,
    );
    // 保留默认行为（debug 期红屏 / 控制台输出）
    previousOnError?.call(details);
  };

  // 平台层 / engine 未捕获错误（返回 true 表示已处理，避免进程崩溃）
  PlatformDispatcher.instance.onError = (error, stack) {
    Log.app.f('平台层未捕获异常', error: error, stackTrace: stack);
    return true;
  };
}

/// 应用主初始化流程
Future<void> _bootstrap() async {
  // 桌面平台（Windows/macOS/Linux）初始化 sqflite_ffi
  // sqflite 原生只支持 Android/iOS，桌面端必须用 sqflite_common_ffi
  if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    // 桌面端：把数据库目录从 sqflite_ffi 默认的「CWD 相对路径
    // .dart_tool/sqflite_common_ffi/databases」改为应用支持目录
    // （getApplicationSupportDirectory → %APPDATA%\<app>）。
    // 原因：默认相对路径会让数据库位置随程序启动目录（exe 所在目录）漂移；
    // 打包到 Program Files 后该目录通常无写权限，会导致无法建库。
    // 注意：setDatabasesPath 必须在首次访问 database 之前调用（见下方
    // NotesDatabase.instance.database），此处顺序满足要求。
    final supportDir = await getApplicationSupportDirectory();
    await databaseFactory.setDatabasesPath(supportDir.path);
    Log.app.i('桌面平台，sqflite_ffi数据库目录已指向应用支持目录: '
        '${supportDir.path}\\safenotes_sync.db');
  }

  WidgetsBinding.instance.addObserver(AppLifecycleEventHandler(
    inactiveCallBack: ScheduledTask.backup,
    resumeCallBack: () async {
      Log.app.i('应用回到前台');
      // App 回前台时触发自动同步，拉取期间其他端可能产生的远端变更
      // autoSync 内部会判断 _engine 是否就绪，未登录/未启用同步时直接返回
      SyncService.instance.autoSync();
    },
    pausedCallBack: () async {
      Log.app.i('应用进入后台');
      // 进后台立即 flush，避免进程被系统回收导致日志丢失
      await AppLogFile.flush();
    },
    // 应用真正退出：停止日志 Web 服务器并关闭日志文件
    detachedCallBack: _shutdown,
  ));

  await PreferencesStorage.init();

  // 简化方案:预初始化 db + 一次性查询 Keyring.isInitialized
  // 避免 AuthWall 改 StatefulWidget + FutureBuilder 的 UI 闪烁
  await NotesDatabase.instance.database;
  AppBootState.vaultInitialized =
      await Keyring.isInitialized(NotesDatabase.instance);
  Log.app.i('数据库就绪 (vaultInitialized=${AppBootState.vaultInitialized})');

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
    if (PreferencesStorage.isAutoRotate) ...[
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]
  ]);

  onAppUpdate();

  await EasyLocalization.ensureInitialized();
  runApp(
    EasyLocalization(
      path: 'assets/translations',
      supportedLocales: SafeNotesConfig.localesValues,
      fallbackLocale: const Locale('en', 'US'),
      child: SafeNotesApp(),
    ),
  );
}

/// 应用退出清理（AppLifecycleState.detached）
///
/// 需求：日志 Web 服务器随主界面启动，应用退出时结束。
Future<void> _shutdown() async {
  Log.app.i('应用退出，开始清理');
  try {
    await LogWebServer.instance.stop();
  } on Object catch (e, st) {
    Log.app.w('停止日志 Web 服务器失败', error: e, stackTrace: st);
  }
  Log.app.i('════════ SafeNotes 退出 ════════');
  // 最后关闭日志文件（flush 剩余缓冲）
  await AppLogFile.close();
}

class SafeNotesApp extends StatelessWidget {
  SafeNotesApp({super.key});

  final navigatorKey = GlobalKey<NavigatorState>();
  NavigatorState? get _navigator => navigatorKey.currentState;
  final sessionStateStream = StreamController<SessionState>();
  final int foucsTimeout = PreferencesStorage.focusTimeout;
  final int inactivityTimeout = PreferencesStorage.inactivityTimeout;

  @override
  Widget build(BuildContext context) {
    final sessionConfig = SessionConfig(
      invalidateSessionForAppLostFocus: Duration(seconds: foucsTimeout),
      invalidateSessionForUserInactivity: Duration(seconds: inactivityTimeout),
    );

    sessionConfig.stream.listen(sessionHandler);
    //  stop listening, as user will already be in auth page
    sessionStateStream.add(SessionState.stopListening);

    return SessionTimeoutManager(
      sessionConfig: sessionConfig,
      child: App(
        sessionStateStream: sessionStateStream,
        navigatorKey: navigatorKey,
      ),
    );
  }

  Future<void> sessionHandler(SessionTimeoutState timeoutEvent) async {
    // stop listening, as user will already be in auth page
    sessionStateStream.add(SessionState.stopListening);
    BuildContext context = navigatorKey.currentContext!;

    if (timeoutEvent == SessionTimeoutState.userInactivityTimeout &&
        PreferencesStorage.isInactivityTimeoutOn) {
      Log.auth.i('会话超时：用户长时间无操作，准备锁定');
      await onTimeOutDo(
        context: context,
        showPreLogoffAlert: true,
      );
      // Don't logout if user is active
    } else if (timeoutEvent == SessionTimeoutState.appFocusTimeout) {
      Log.auth.i('会话超时：应用失焦超时，准备锁定');
      await onTimeOutDo(
        context: context,
        showPreLogoffAlert: false,
      );
    }
  }

  Future<void> onTimeOutDo(
      {required BuildContext context, required bool showPreLogoffAlert}) async {
    // execute only if user is already logged
    // no need to logout and redirect to authwall if user is not loggedIN
    // 简化方案:用 dataKey 是否注入判断登录状态(替代 PhraseHandler.getPass)
    if (NotesDatabase.instance.isEncryptionEnabled) {
      bool? isUserActive;
      if (showPreLogoffAlert) {
        isUserActive = await preInactivityLogOffAlert(context);
      }
      if (isUserActive == null || showPreLogoffAlert == false) {
        // isUserActive == null => show him logout Msg
        // showPreLogoffAlert == false => i.e. triggered by appFocusTimeout

        // TODO: refactor without using BuildContexts across async gap
        if (context.mounted) {
          logout(
            context: context,
            showLogoutMsg: true,
          );
        }
      }
      if (isUserActive == false) {
        // isUserActive == false => user choose to logout, don't show msg

        // TODO: refactor without using BuildContexts across async gap
        if (context.mounted) {
          logout(
            context: context,
            showLogoutMsg: false,
          );
        }
      }
      //else user pressed cancel and is active
    }
    // User is already on authpage
  }

  Future<void> logout({
    required BuildContext context,
    required bool showLogoutMsg,
  }) async {
    _navigator?.pushNamedAndRemoveUntil(
      '/authwall',
      (Route<dynamic> route) => false,
      arguments: SessionArguments(
        sessionStream: sessionStateStream,
        isKeyboardFocused: false,
      ),
    );

    if (showLogoutMsg) {
      showGenericDialog(
        context: context,
        icon: Icons.info_outline,
        message:
            "You were logged out due to extended inactivity. This is to protect your privacy."
                .tr(),
      );
    }

    // save unsaved note if any
    await NoteEditorState().handleUngracefulNoteExit();
    await Session.logout();
  }
}

// run once every update
void onAppUpdate() async {
  if (PreferencesStorage.appVersionCode != SafeNotesConfig.appVersionCode) {
    Log.app.i('检测到应用升级: '
        '${PreferencesStorage.appVersionCode} → '
        '${SafeNotesConfig.appVersionCode}');
    if (PreferencesStorage.isBackupOn) {
      try {
        if (await handleBackupPermissionAndLocation()) {
          await ScheduledTask.backup();
        }
      } on Object catch (e, st) {
        Log.backup.e('升级后自动备份失败', error: e, stackTrace: st);
      }
    }

    // insure onAppUpdate is run once each update
    PreferencesStorage.setAppVersionCodeToCurrent();
  }
}
