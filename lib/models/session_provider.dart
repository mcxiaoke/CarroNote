// SessionProvider — 会话状态管理
//
// 替代原先分散的 AppBootState / Session 静态类，统一管理：
//   - vaultInitialized（保险库是否已初始化，决定登录/设置密码路由）
//   - 会话密码（委托 PhraseHandler，SyncService 的 passphraseProvider 依赖它）
//   - 登录/登出/改密码副作用（依赖注入，可测试）
//
// 通过 ChangeNotifier 使 Provider 可监听状态变化。

// Dart imports:
import 'dart:async';

// Flutter imports:
import 'package:flutter/foundation.dart';

// Package imports:
import 'package:core/core.dart';

// Project imports:
import 'package:safenotes/data/note_repository.dart';
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/data/preference_repository.dart';
import 'package:safenotes/platform/ports.dart';
import 'package:safenotes/sync/sync_repository.dart';
import 'package:safenotes/utils/scheduled_task.dart';

/// 会话状态提供者。
///
/// 依赖通过构造注入（NotesRepository / SyncRepository / PreferencesRepository /
/// BiometricPort），测试时用 fake 即可，不碰全局单例。
class SessionProvider extends ChangeNotifier {
  SessionProvider({
    required NotesRepository notesRepo,
    required SyncRepository syncRepo,
    required PreferencesRepository prefsRepo,
    required BiometricPort biometric,
    this.vaultInitialized,
  }) : _notesRepo = notesRepo,
       _syncRepo = syncRepo,
       _prefsRepo = prefsRepo,
       _biometric = biometric;

  final NotesRepository _notesRepo;
  final SyncRepository _syncRepo;
  final PreferencesRepository _prefsRepo;
  final BiometricPort _biometric;

  /// null=未就绪(启动中), true=已有 keyring(走登录页), false=无 keyring(走设置密码页)
  bool? vaultInitialized;

  // ── 会话密码（委托 PhraseHandler，因 SyncService 的 passphraseProvider 依赖） ──

  void initPassphrase(String pass) => PhraseHandler.initPass(pass);

  void clearPassphrase() => PhraseHandler.destroy();

  String get passphrase => PhraseHandler.getPass;

  // ── 登录/登出/改密码 ──

  void login(String passphrase) {
    Log.auth.i('会话登录: 已装载密码短语 (长度=${passphrase.length})');
    initPassphrase(passphrase);
    if (_prefsRepo.isBiometricAuthEnabled) {
      unawaited(_biometric.saveCredential(passphrase));
    }
  }

  Future<void> logout() async {
    final sw = Stopwatch()..start();
    Log.auth.i('会话登出: 开始清理会话与敏感数据');

    // 登出前自动备份（ScheduledTask 仍为静态调度器，见文档 §4.7 遗留）
    await ScheduledTask.backup();

    await _syncRepo.logout();
    Log.sync.d('会话登出: 同步服务已登出并释放密钥');

    _notesRepo.clearDataKey();
    Log.crypto.i('会话登出: 内存中的 dataKey 已清除');

    clearPassphrase();

    Log.auth.i('会话登出完成, 耗时 ${sw.elapsedMilliseconds}ms');
  }

  void onPasswordSet(String passphrase) {
    Log.auth.i('密码已设置/变更: 更新会话密码短语 (长度=${passphrase.length})');
    initPassphrase(passphrase);
    if (_prefsRepo.isBiometricAuthEnabled) {
      unawaited(_biometric.saveCredential(passphrase));
    }
  }
}
