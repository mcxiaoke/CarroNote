// SessionProvider — 会话状态管理
//
// 替代原先分散的 AppBootState / PhraseHandler / Session 静态类，统一管理：
//   - vaultInitialized（保险库是否已初始化，决定登录/设置密码路由）
//   - 会话密码（替代 PhraseHandler）
//   - 登录/登出/改密码副作用（替代 Session 静态方法）
//
// 通过 ChangeNotifier 使 Provider 可监听状态变化。

// Dart imports:
import 'dart:async';

// Flutter imports:
import 'package:flutter/foundation.dart';

// Package imports:
import 'package:core/core.dart';
import 'package:local_session_timeout/local_session_timeout.dart';

// Project imports:
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/biometric_auth.dart';
import 'package:safenotes/sync/sync_service.dart';
import 'package:safenotes/utils/scheduled_task.dart';

/// 会话状态提供者。
///
/// 提供方式：
///   Provider<SessionProvider>.value(value: SessionProvider(...))
///
/// 测试时直接构造并注入：
///   Provider<SessionProvider>.value(
///     value: SessionProvider(vaultInitialized: true),
///   )
class SessionProvider extends ChangeNotifier {
  SessionProvider({
    this.vaultInitialized,
  });

  /// null=未就绪(启动中), true=已有 keyring(走登录页), false=无 keyring(走设置密码页)
  bool? vaultInitialized;

  // ── 会话密码（替代 PhraseHandler） ──

  String _passphrase = '';

  /// 注入会话密码（内存态）
  ///
  /// 隐私红线：**只记录状态与长度，绝不记录密码本身**。
  void initPassphrase(String pass) {
    final wasSet = _passphrase.isNotEmpty;
    _passphrase = pass;
    Log.auth.i(
      '会话密码已注入内存 (len=${pass.length}, '
      '此前${wasSet ? "已有" : "为空"})',
    );
  }

  /// 清除会话密码
  void clearPassphrase() {
    final wasSet = _passphrase.isNotEmpty;
    _passphrase = '';
    if (wasSet) Log.auth.i('会话密码已从内存清除');
  }

  /// 获取当前会话密码
  String get passphrase => _passphrase;

  // ── 登录/登出/改密码（替代 Session 静态方法） ──

  /// 登录：装载密码短语 + 刷新生物识别凭据
  void login(String passphrase) {
    Log.auth.i('会话登录: 已装载密码短语 (长度=${passphrase.length})');
    initPassphrase(passphrase);
    if (PreferencesStorage.isBiometricAuthEnabled) {
      BiometricAuth.setAuthKey();
    }
  }

  /// 登出：清除会话与敏感数据
  Future<void> logout() async {
    final sw = Stopwatch()..start();
    Log.auth.i('会话登出: 开始清理会话与敏感数据');

    await ScheduledTask.backup();

    await SyncService.instance.logout();
    Log.sync.d('会话登出: 同步服务已登出并释放密钥');

    NotesDatabase.instance.clearDataKey();
    Log.crypto.i('会话登出: 内存中的 dataKey 已清除');

    clearPassphrase();

    Log.auth.i('会话登出完成, 耗时 ${sw.elapsedMilliseconds}ms');
  }

  /// 密码设置/变更后的副作用处理
  void onPasswordSet(String passphrase) {
    Log.auth.i('密码已设置/变更: 更新会话密码短语 (长度=${passphrase.length})');
    initPassphrase(passphrase);
    if (PreferencesStorage.isBiometricAuthEnabled) {
      Log.auth.i('生物识别已启用: 同步刷新安全存储中的认证凭据');
      BiometricAuth.setAuthKey();
    } else {
      Log.auth.d('生物识别未启用: 跳过认证凭据刷新');
    }
  }
}

/// 路由参数（保留原 SessionArguments 语义）
class SessionArguments {
  final StreamController<SessionState> sessionStream;
  final bool? isKeyboardFocused;

  SessionArguments({required this.sessionStream, this.isKeyboardFocused});
}