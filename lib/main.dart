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

import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:core/core.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:local_session_timeout/local_session_timeout.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common/sqflite.dart';

import 'package:safenotes/app.dart';
import 'package:safenotes/authwall.dart';
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/generated/build_info.g.dart';
import 'package:safenotes/models/editor_state.dart';
import 'package:safenotes/models/session.dart';
import 'package:safenotes/src/logger/log_webserver.dart';
import 'package:safenotes/src/platform/data_dir_override.dart';
import 'package:safenotes/src/platform/database_bootstrap.dart';
import 'package:safenotes/sync/sync_config.dart';
import 'package:safenotes/sync/sync_service.dart';
import 'package:safenotes/utils/desktop_window.dart';
import 'package:safenotes/utils/lifecycle_handler.dart';
import 'package:safenotes/utils/platform_ui.dart';

import 'package:safenotes/src/platform/platform_io.dart'
    show Directory, File, Platform;

/// 数据目录覆盖（集成测试 / 特殊构建用）。
///
/// 读环境变量 `SN_DATA_DIR`：非空时把日志、prefs、数据库全部重定向到该目录，
/// 让测试跑在完全独立的数据环境，避免污染本机真实数据。null 表示未覆盖。
String? dataDirOverride;

Future main() async {
  // runZonedGuarded 捕获所有异步未捕获异常（Zone 级兜底）。
  // 必须把 ensureInitialized 和 runApp 放在同一个 Zone 内，
  // 否则 Flutter 会抛 "Zone mismatch" 错误。
  runZonedGuarded<Future<void>>(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // 数据目录覆盖必须在最早期应用：日志目录解析（_initLogging）、
      // prefs 后端（SharedPreferencesStorePlatform.instance）都要在各自
      // 初始化前被替换，DB 路径则在 _bootstrap 里读取。
      applyDataDirOverride();

      // ① 日志系统必须最先初始化，保证后续任何环节的错误都能落盘
      await _initLogging();

      // ② 安装全局错误钩子（同步错误 + 平台层错误）
      _installGlobalErrorHandlers();

      await _bootstrap();
    },
    (error, stack) {
      // Zone 级未捕获异常：走到这里说明没有任何 try/catch 处理它
      Log.app.f('未捕获的异步异常', error: error, stackTrace: stack);
      if (kDebugMode) throw error; // debug 重抛，让问题暴露
    },
  );
}

/// 初始化日志系统（全平台一致：移动端 + 桌面端）
Future<void> _initLogging() async {
  // 注入 dev 模式判断（读取 SharedPreferences，非 debug 构建生效）。
  // 必须在 AppLogFile.init() 之前注入，使默认日志级别按 dev 模式正确初始化。
  devModeProvider = () => PreferencesStorage.isDevMode;
  // 解析应用私有数据目录（web 无物理目录概念，返回 null 降级）。
  final appData = kIsWeb
      ? null
      : (dataDirOverride ?? (await getApplicationSupportDirectory()).path);
  // 通用应用数据目录注入：core 纯 Dart 无 path_provider，由 App 侧提供。
  // 供 core 内所有「非 DB 文件」落盘需求复用（日志目录、隔离副本等），
  // 避免每个功能各自造一个 *Override 注入点。
  AppPaths.appDataDir = appData;
  // 注入日志目录解析器（path_provider 实现），使核心日志逻辑保持纯 Dart 可编译
  logDirResolverOverride = () async => appData;
  await AppLogFile.init();
  Log.app.i('════════ SafeNotes 启动 ════════');
  // 版本详细信息（含构建期注入的 Git 提交哈希与构建时间）
  Log.app.i('版本: ${BuildInfo.version} (build ${BuildInfo.buildNumber})');
  Log.app.i(
    'Git: ${BuildInfo.gitHashShort} @ ${BuildInfo.gitBranch}'
    '${BuildInfo.gitDirty ? " (工作区有未提交改动)" : ""}',
  );
  Log.app.i('Commit: ${BuildInfo.gitHash}');
  Log.app.i(
    'Tag: ${BuildInfo.gitTag.isEmpty ? "无 tag" : BuildInfo.gitTag} '
    '(累计提交 ${BuildInfo.gitCommitCount})',
  );
  Log.app.i(
    '构建时间: ${BuildInfo.buildDateReadable} (UTC ${BuildInfo.buildDate})',
  );
  if (kIsWeb) {
    Log.app.i('平台: web web');
    Log.app.i('Dart: web');
  } else {
    Log.app.i(
      '平台: ${Platform.operatingSystem} '
      '${Platform.operatingSystemVersion}',
    );
    Log.app.i('Dart: ${Platform.version.split(' ').first}');
  }
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
    return !kDebugMode; // debug 返回 false 让引擎继续默认处理;
  };
}

/// 应用主初始化流程
Future<void> _bootstrap() async {
  // 桌面端窗口管理（最小尺寸 + 居中）：必须在 runApp 之前就绪
  await initDesktopWindowManager();

  // R2：桌面端点 X 关窗前先保存未提交草稿并执行退出清理，再销毁窗口。
  // 不拦截时异步保存与进程退出竞态，编辑中的内容会丢失。
  desktopWindowCloseHandler = () async {
    try {
      await NoteEditorState().handleUngracefulNoteExit();
    } on Object catch (e, st) {
      Log.app.w('关窗保存草稿失败（忽略，继续退出）', error: e, stackTrace: st);
    }
    await _shutdown();
  };

  // 平台数据库初始化（Native 桌面走 FFI，Web 走 WASM+IndexedDB，移动端走原生插件）
  await initDatabaseForPlatform(dataDirOverride: dataDirOverride);

  // 移动端 + 数据目录覆盖（集成测试真机模式）：把设备真实的 safenotes_sync.db
  // 复制一份到隔离目录，并从该副本打开，避免测试污染设备真实数据。
  // 真实 db 不存在时跳过复制（首次运行走建档流程，用空目录）。
  // 注意：必须在首次访问 database（下方 NotesDatabase.instance.database）之前完成。
  // 关键：sqflite 原生（Android）要求数据库路径位于 getDatabasesPath()（即
  // .../databases）之下，否则会把它当外部文件处理/复制，导致只读
  // （SQLITE_READONLY_DBMOVED）。因此隔离副本固定放在 <databases>/integration_test_data，
  // 而非 dataDirOverride；prefs/日志仍用 dataDirOverride。
  final overrideDir = dataDirOverride;
  if (!kIsWeb && !isDesktopPlatform && overrideDir != null) {
    final realDbDir = await databaseFactory.getDatabasesPath();
    final isoDir = p.join(realDbDir, 'integration_test_data');
    final src = File(p.join(realDbDir, 'safenotes_sync.db'));
    final dst = File(p.join(isoDir, 'safenotes_sync.db'));
    await Directory(isoDir).create(recursive: true);
    if (await src.exists()) {
      if (await dst.exists()) await dst.delete();
      await src.copy(dst.path);
      Log.app.i('移动端数据目录覆盖: 已复制 db 到 ${dst.path}');
    } else {
      Log.app.i('移动端数据目录覆盖: 真实 db 不存在(首次建档), 用空目录 $isoDir');
    }
    NotesDatabase.dbPathOverride = isoDir;
  }

  // 统一注入数据库工厂：桌面端已被换成 FFI 实现，Web 端为 WASM，移动端由 sqflite 插件注册
  // （同一注入点、不同平台实现，不引入分支）。
  NotesDatabase.dbFactoryOverride = databaseFactory;

  WidgetsBinding.instance.addObserver(
    AppLifecycleEventHandler(
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
    ),
  );

  await PreferencesStorage.init();

  // 偏好加载完成后刷新日志级别：若上次会话开启了 dev 模式，立即恢复全量 trace
  //（启动早期 Preferences 未就绪，devModeProvider 读到的是默认 false）。
  AppLog.refreshLevel();

  // 同步配置必须在任何 UI 读它之前就绪：主界面的同步按钮、设置页的同步状态
  // 都是同步 getter（背后是 SharedPreferences 缓存 + SecureStorage 预载）。
  // 原先只在登录页/设置页里 init，启动早期读到的是「未配置」默认值，
  // 表现为同步按钮短暂消失、状态显示错误。
  await SyncConfig.init();

  // 简化方案:预初始化 db + 一次性查询 Keyring.isInitialized
  // 避免 AuthWall 改 StatefulWidget + FutureBuilder 的 UI 闪烁
  await NotesDatabase.instance.database;
  AppBootState.vaultInitialized = await Keyring.isInitialized(
    NotesDatabase.instance,
  );
  Log.app.i('数据库就绪 (vaultInitialized=${AppBootState.vaultInitialized})');

  // 桌面/大屏适配（P1-3）：Windows/macOS/Linux 窗口可自由缩放，
  // 强制取向在桌面是 no-op 且不符合桌面预期，故仅在移动端（非 Web）执行。
  final isDesktopUi = isDesktopPlatform;
  if (!isDesktopUi) {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      if (PreferencesStorage.isAutoRotate) ...[
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ],
    ]);
  }

  onAppUpdate();

  EasyLocalization.logger.enableBuildModes = [];
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
  // N-5 修复：退出前销毁同步服务——等待在途同步结束、flush journal 内存
  // 缓冲并关闭后端连接；失败不阻断退出。
  try {
    await SyncService.instance.dispose();
  } on Object catch (e, st) {
    Log.app.w('SyncService dispose 失败（忽略，继续退出）', error: e, stackTrace: st);
  }
  Log.app.i('════════ SafeNotes 退出 ════════');
  // 最后关闭日志文件（flush 剩余缓冲）
  await AppLogFile.close();
}

class SafeNotesApp extends StatefulWidget {
  const SafeNotesApp({super.key});

  @override
  State<SafeNotesApp> createState() => _SafeNotesAppState();
}

class _SafeNotesAppState extends State<SafeNotesApp>
    with WidgetsBindingObserver {
  final navigatorKey = GlobalKey<NavigatorState>();
  NavigatorState? get _navigator => navigatorKey.currentState;
  late final StreamController<SessionState> sessionStateStream;
  SessionConfig? _prevSessionConfig;
  StreamSubscription<SessionTimeoutState>? _sessionSubscription;

  /// 后台触发的会话超时事件。
  ///
  /// 空闲 Timer 不感知前后台：切到其他应用后超时照样触发。若在后台直接
  /// 导航到登录页，路由重建 + 登录页/PIN 面板的 autofocus 会向引擎发起
  /// 窗口焦点请求（Flutter Windows 引擎存在失活窗口重新激活的已知问题，
  /// flutter/flutter#187436），表现为应用突然抢前台。这里先记录事件，
  /// 延迟到回到前台时再执行锁定（见 didChangeAppLifecycleState）。
  SessionTimeoutState? _pendingLockEvent;

  // 评审 #15：缓存上一次生效的超时配置，build 只在配置真正变化时重建订阅，
  // 避免每次 build 都取消/重建会话监听、把 SessionTimeoutManager 的超时基准
  // 重置回满值（表现为「用户从不触发无操作锁定」）。
  SessionConfig? _cachedSessionConfig;
  int? _cachedFocusTimeout;
  int? _cachedInactivityTimeout;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    sessionStateStream = StreamController<SessionState>();
    // 应用初始位于 AuthWall（尚未登录）或无会话，先 stop listening
    // 原实现在 build() 里每次重建都 add，这里移入 initState 只发一次，
    // 语义保持不变（登录成功路由会再发 startListening）。
    sessionStateStream.add(SessionState.stopListening);
    // H6：把键盘按下事件转发为用户活动（节流 1s）。local_session_timeout
    // 包只监听 pointerDown，桌面端纯打字不会重置无操作锁定计时器，
    // 连续写作会被强制登出。
    HardwareKeyboard.instance.addHandler(_handleKeyboardActivity);
  }

  @override
  void dispose() {
    // F-C03：取消会话订阅、释放 SessionConfig 的闭包 stream 并关闭 controller，
    // 避免重建时旧 listener 泄漏 / StreamController 永不关闭
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_handleKeyboardActivity);
    _sessionSubscription?.cancel();
    _prevSessionConfig?.dispose();
    _cachedSessionConfig?.dispose();
    sessionStateStream.close();
    super.dispose();
  }

  /// 最近一次键盘活动转发时间（节流用，与包内 1s 活动防抖对齐）。
  DateTime? _lastKeyActivityForwardAt;

  /// H6：键盘按下 → 转发为一次用户活动。
  ///
  /// 复用 `startListening` 的语义：SessionTimeoutManager 收到后调用
  /// recordPointerEvent() 重置无操作计时器。仅已登录会话内生效
  /// （与 onTimeOutDo 相同的 isEncryptionEnabled 登录判据），登录页/
  /// 锁定页的键盘输入不会误启监听。返回 false 表示不消费事件。
  bool _handleKeyboardActivity(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!NotesDatabase.instance.isEncryptionEnabled) return false;
    final now = DateTime.now();
    final last = _lastKeyActivityForwardAt;
    if (last != null && now.difference(last) < const Duration(seconds: 1)) {
      return false;
    }
    _lastKeyActivityForwardAt = now;
    sessionStateStream.add(SessionState.startListening);
    return false;
  }

  /// F-C03：重建会话超时监听。
  ///
  /// 原实现是 StatelessWidget：build() 里每次重建都对配置的 stream 重新 listen，
  /// 旧 listener 从不取消 → 会话事件被处理 N 次（重复登出/跳转）且流泄漏。
  /// 这里改为每次 build 时先取消旧 subscription、释放旧 config 的闭包 stream，
  /// 保证任意时刻只有一个存活 listener。
  ///
  /// F-H12：SessionConfig 每次 build 时重建（超时配置改为构建期动态读取，
  /// 而非构造期 final 快照），配合本方法使「改超时设置后即时生效」。
  void _rebuildSessionSubscription(SessionConfig sessionConfig) {
    _sessionSubscription?.cancel();
    _prevSessionConfig?.dispose();
    // 评审 #15：记录当前 config，供下次 swap 时 dispose（原实现未回写，
    // 新 config 的 stream 从不被释放，且 dispose() 会二次 dispose 旧对象）。
    _prevSessionConfig = sessionConfig;
    _sessionSubscription = sessionConfig.stream.listen(sessionHandler);
  }

  @override
  Widget build(BuildContext context) {
    final focusTimeout = PreferencesStorage.focusTimeout;
    final inactivityTimeout = PreferencesStorage.inactivityTimeout;
    // 评审 #15：超时配置未变化时不重建 sessionConfig 与订阅（避免重置
    // SessionTimeoutManager 的超时基准）。配置变化时才重建，保证即时生效。
    if (_cachedSessionConfig == null ||
        _cachedFocusTimeout != focusTimeout ||
        _cachedInactivityTimeout != inactivityTimeout) {
      _cachedFocusTimeout = focusTimeout;
      _cachedInactivityTimeout = inactivityTimeout;
      _cachedSessionConfig = SessionConfig(
        invalidateSessionForAppLostFocus: Duration(seconds: focusTimeout),
        invalidateSessionForUserInactivity: Duration(
          seconds: inactivityTimeout,
        ),
      );
      _rebuildSessionSubscription(_cachedSessionConfig!);
    }

    return SessionTimeoutManager(
      sessionConfig: _cachedSessionConfig!,
      child: App(
        sessionStateStream: sessionStateStream,
        navigatorKey: navigatorKey,
      ),
    );
  }

  Future<void> sessionHandler(SessionTimeoutState timeoutEvent) async {
    // H7：先判定该事件是否需要锁定，再决定是否停监听。
    // 旧实现无条件先 stopListening，导致：
    //   1) 关闭「无操作锁定」后，首个空闲超时事件把监听永久关掉，
    //      失焦锁定（appFocusTimeout）连带失效；
    //   2) 会话中重新打开「无操作锁定」也无法生效（监听已死无人重启）。
    final bool shouldLock = switch (timeoutEvent) {
      SessionTimeoutState.userInactivityTimeout =>
        PreferencesStorage.isInactivityTimeoutOn,
      SessionTimeoutState.appFocusTimeout => true,
    };
    if (!shouldLock) {
      // 无操作锁定已关闭：保持监听，等下一次用户活动重置计时器
      return;
    }

    // 已确定要锁定：停止会话监听（用户将进入登录页）
    sessionStateStream.add(SessionState.stopListening);

    // 应用在后台时不做任何 UI 切换：记录待锁定事件，回到前台再执行。
    // （防止后台导航触发窗口焦点请求把应用抢到前台，见 _pendingLockEvent 注释）
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed &&
        (timeoutEvent == SessionTimeoutState.userInactivityTimeout ||
            timeoutEvent == SessionTimeoutState.appFocusTimeout)) {
      _pendingLockEvent = timeoutEvent;
      Log.auth.i('会话超时但应用在后台，锁定延迟至回到前台执行');
      return;
    }

    // 评审 #15：navigatorKey.currentContext 在应用首次 build 前为 null，
    // 强解包会崩溃。取不到 context 时本次超时只停监听、不导航
    // （下次超时事件到达时通常已挂载）。
    final context = navigatorKey.currentContext;
    if (context == null) {
      Log.auth.w('会话超时但 navigator 尚未挂载，跳过导航');
      return;
    }

    await _executeSessionLock(timeoutEvent, context);
  }

  /// 执行会话锁定（登出并跳转登录页）。仅在应用前台时调用。
  Future<void> _executeSessionLock(
    SessionTimeoutState timeoutEvent,
    BuildContext context,
  ) async {
    if (timeoutEvent == SessionTimeoutState.userInactivityTimeout &&
        PreferencesStorage.isInactivityTimeoutOn) {
      Log.auth.i('会话超时：用户长时间无操作，准备锁定');
      await onTimeOutDo(context: context);
      // Don't logout if user is active
    } else if (timeoutEvent == SessionTimeoutState.appFocusTimeout) {
      Log.auth.i('会话超时：应用失焦超时，准备锁定');
      await onTimeOutDo(context: context);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // 回到前台时补执行后台期间积压的锁定。重复事件是幂等的：
    // Session.logout 清掉 dataKey 后，onTimeOutDo 的 isEncryptionEnabled
    // 检查会直接跳过二次登出/导航。
    if (state != AppLifecycleState.resumed) return;
    final pendingEvent = _pendingLockEvent;
    if (pendingEvent == null) return;
    _pendingLockEvent = null;
    final context = navigatorKey.currentContext;
    if (context == null) return;
    Log.auth.i('应用回到前台，执行延迟的会话锁定');
    unawaited(_executeSessionLock(pendingEvent, context));
  }

  Future<void> onTimeOutDo({required BuildContext context}) async {
    // 简化方案:会话超时直接登出，不再弹「超时锁定」倒计时框，也不弹退出提示框。
    // execute only if user is already logged
    // no need to logout and redirect to authwall if user is not loggedIN
    // 简化方案:用 dataKey 是否注入判断登录状态(替代 PhraseHandler.getPass)
    if (NotesDatabase.instance.isEncryptionEnabled) {
      if (context.mounted) {
        logout(context: context);
      }
    }
    // User is already on authpage
  }

  Future<void> logout({required BuildContext context}) async {
    _navigator?.pushNamedAndRemoveUntil(
      '/authwall',
      (Route<dynamic> route) => false,
      arguments: SessionArguments(
        sessionStream: sessionStateStream,
        isKeyboardFocused: false,
      ),
    );

    // save unsaved note if any
    await NoteEditorState().handleUngracefulNoteExit();
    await Session.logout();
  }
}

// run once every update
void onAppUpdate() async {
  if (kIsWeb) return;
  if (PreferencesStorage.appVersionCode != SafeNotesConfig.appVersionCode) {
    Log.app.i(
      '检测到应用升级: '
      '${PreferencesStorage.appVersionCode} → '
      '${SafeNotesConfig.appVersionCode}',
    );
    // 仅更新版本号；不在这里做备份（备份改为「登录后自动备份」驱动，
    // 见 docs/backup-scheme-revamp-20260831.md）。
    PreferencesStorage.setAppVersionCodeToCurrent();
  }
}
