/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

/*
 * 同步服务（应用层）
 *
 * 职责：
 *   1. 持有 Keyring + SyncBackend + SyncEngine 实例，统一管理生命周期
 *   2. 互斥锁：同一时间只允许一个 sync() 执行（防止并发冲突）
 *   3. 状态管理：对外暴露 SyncState，供 UI 观察同步状态
 *   4. 触发同步：手动 sync() / 笔记变更后 autoSync()
 *
 * 不负责：
 *   - UI 渲染（由 Widget 层通过 ChangeNotification 监听状态）
 *   - 后端配置（由 Settings 页面配置后传入）
 *   - 密码输入（由 Keyring 层处理）
 *
 * 使用方式：
 *   final service = SyncService();
 *   await service.initialize(keyring: keyring, backend: backend);
 *   await service.sync();  // 手动触发
 *   service.autoSync();    // 笔记变更后调用（非阻塞，内部 debounce）
 */

// Dart 导入

import 'dart:async';
import 'dart:io';

import 'package:core/core.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/sync/sync_config.dart';
import 'package:safenotes/utils/device_id.dart';

// 第三方导入

// 项目导入

/// 同步状态枚举（供 UI 显示）
enum SyncStatus {
  /// 未初始化（未配置 keyring 或 backend）
  uninitialized,

  /// 空闲（已初始化，无同步进行中）
  idle,

  /// 同步中
  syncing,

  /// 上次同步成功
  success,

  /// 上次同步失败
  error,
}

/// 同步服务状态快照（供 UI 观察）
class SyncServiceState {
  final SyncStatus status;
  final DateTime? lastSyncTime;
  final SyncResult? lastResult;
  final String? errorMessage;

  const SyncServiceState({
    this.status = SyncStatus.uninitialized,
    this.lastSyncTime,
    this.lastResult,
    this.errorMessage,
  });

  /// 是否正在同步
  bool get isSyncing => status == SyncStatus.syncing;

  /// 是否已初始化
  bool get isInitialized => status != SyncStatus.uninitialized;

  SyncServiceState copyWith({
    SyncStatus? status,
    DateTime? lastSyncTime,
    SyncResult? lastResult,
    String? errorMessage,
  }) => SyncServiceState(
    status: status ?? this.status,
    lastSyncTime: lastSyncTime ?? this.lastSyncTime,
    lastResult: lastResult ?? this.lastResult,
    errorMessage: errorMessage,
  );
}

/// 同步服务
///
/// 单例模式，整个应用共享一个实例。
/// 通过 [stateStream] 暴露状态变化，UI 层用 StreamBuilder 监听。
class SyncService {
  // 单例
  static final SyncService instance = SyncService._();

  SyncService._();

  // ──────────────────────────────────────────────
  // 依赖
  // ──────────────────────────────────────────────

  Keyring? _keyring;
  SyncBackend? _backend;
  SyncEngine? _engine;

  /// P2 Journal（设计 §3）：整个 SyncService 生命周期内**单实例**。
  ///
  /// 为什么放在 SyncService 而不是 SyncEngine：SyncEngine 会因改密码
  /// （updateKeyring）、换后端（switchBackend）被反复重建，而 journal 的
  /// seq 单调性、滚动归档、远端上传水位（.journal-state.json）必须跨重建
  /// 保持连续。放在 Engine 里会导致每次重建都重开文件、seq 水位反复恢复，
  /// 既浪费 IO 也容易在竞态下写坏日志。
  Journal? _journal;

  /// 设备 ID（首次 sync 时通过 DeviceIdProvider 获取并缓存）
  String? _deviceId;

  // ──────────────────────────────────────────────
  // 状态
  // ──────────────────────────────────────────────

  SyncServiceState _state = const SyncServiceState();
  final StreamController<SyncServiceState> _stateController =
      StreamController<SyncServiceState>.broadcast();

  /// 状态变化流（UI 监听用）
  Stream<SyncServiceState> get stateStream => _stateController.stream;

  /// 当前状态
  SyncServiceState get state => _state;

  // ──────────────────────────────────────────────
  // 互斥锁
  // ──────────────────────────────────────────────

  bool _syncInProgress = false;

  /// 是否正在同步
  bool get isSyncing => _syncInProgress;

  /// Bug A 修复：后端是否已成功初始化。
  ///
  /// 初始化时若离线，[initialize] 中的 [SyncBackend.init] 会失败并保持
  /// 未就绪状态（[SyncBackend] 内部 _initialized == false）。此后 [sync]
  /// 直接调用 backend.getManifest → _ensureInitialized 抛
  /// "Call init() before using the backend"，且没有任何路径重新 init，
  /// 导致联网后每次同步都报同样错、只能杀进程重进。
  ///
  /// 用这个标志配合 [sync] 的惰性（重）初始化：只要尚未就绪就重试 init，
  /// 联网成功即自动恢复，失败则优雅返回"网络不可用"，不再抛 cryptic 错误。
  bool _backendReady = false;

  // ──────────────────────────────────────────────
  // autoSync debounce
  // ──────────────────────────────────────────────

  Timer? _autoSyncTimer;
  static const Duration _autoSyncDelay = Duration(seconds: 3);

  // ──────────────────────────────────────────────
  // 初始化
  // ──────────────────────────────────────────────

  /// 初始化同步服务
  ///
  /// [keyring] 已解锁的 Keyring 实例
  /// [backend] 已配置的 SyncBackend 实例
  /// [database] 本地数据库
  Future<void> initialize({
    required Keyring keyring,
    required SyncBackend backend,
    required NotesDatabase database,
  }) async {
    // 日志文件已在 main() 最早期初始化（全平台统一），此处不再重复。
    // 日志 Web 服务器（lib/src/logger/log_webserver.dart）直接调用本类方法，
    // 不再需要 provider 注入。

    // F-H03 修复：initialize 幂等化。重复调用时先关闭旧 journal/旧后端，
    // 避免旧 journal 文件句柄泄漏、seq 水位紊乱、日志链断裂；否则直接覆盖
    // 引用会让旧 journal 永远不再 flush/close，跨初始化状态错乱。
    if (_journal != null) {
      await _closeJournal();
    }
    await _backend?.close();
    _backendReady = false;

    _keyring = keyring;
    _backend = backend;

    // 获取设备 ID（首次调用会查询系统 API，后续用缓存）
    _deviceId = await DeviceIdProvider.instance.getDeviceId();

    // 打开 journal（沙盒目录不可用时抛异常，阻断初始化）
    _journal = await _openJournal(vaultId: keyring.vaultId);

    _engine = SyncEngine(
      backend: backend,
      database: database,
      keyring: keyring,
      deviceId: _deviceId!,
      journal: _journal!,
      passphraseProvider: () => PhraseHandler.getPass,
      // B2：迁移成功后回写 _keyring，避免上层持旧 keyring（旧 dataKey）
      onKeyringChanged: (k) => _keyring = k,
    );

    // 启动自检：上次进程有没有写到一半就挂掉的两阶段操作。
    // 只报告不重放——恢复必须以 DB 实际状态为准（设计 §3.6b）。
    await _reportIncompleteOperations();

    Log.sync.i(
      'SyncService 初始化 (backend=${backend.runtimeType}, '
      'deviceId=$_deviceId, vaultId=${keyring.vaultId}, '
      'keyVersion=${keyring.keyVersion}, dataKeyEpoch=${keyring.dataKeyEpoch})',
    );

    await backend.init();
    _backendReady = true;

    Log.sync.i('后端初始化成功 (providerKey=${backend.providerKey})');
    _updateState(state.copyWith(status: SyncStatus.idle));

    // P3-log：initialize 整体完成（与 dispose 对称，便于排查初始化是否走完）
    Log.sync.i('SyncService 初始化完成 (status=idle, backendReady=true)');

    // 注意：日志 Web 服务器不再由 SyncService 启动。
    // 它是应用级能力（不只服务于同步），改为进入主界面时启动、应用退出时停止，
    // 这样未配置同步的用户同样能远程查看日志。见 HomePage.initState / main._shutdown。
  }

  /// 打开 journal（沙盒目录解析 + 打开）
  ///
  /// journal 打开失败直接向上抛异常，阻断同步初始化——不再有内存降级路径。
  Future<Journal> _openJournal({required String vaultId}) async {
    final deviceId = _deviceId ?? 'unknown-device';
    final dir = await getApplicationSupportDirectory();
    return Journal.open(
      baseDir: dir.path,
      vaultId: vaultId,
      deviceId: deviceId,
    );
  }

  /// 启动自检：报告上次运行中未完成的两阶段操作（设计 §3.4）
  ///
  /// **只写日志，不做任何自动修复**。理由见 journal.dart 的
  /// [Journal.findIncompleteOperations] 注释：盲目重放会把「一次故障」
  /// 变成「二次损坏」。真正的恢复依据永远是 DB + manifest 的实际状态，
  /// journal 在这里的价值是让人（和支持人员）知道「哪一步断的」。
  Future<void> _reportIncompleteOperations() async {
    final journal = _journal;
    if (journal == null) return;
    try {
      final incomplete = await journal.findIncompleteOperations();
      if (incomplete.isEmpty) return;
      Log.sync.w(
        '[Journal] 检测到 ${incomplete.length} 个未完成操作'
        '（仅报告，不自动重放）：'
        '${incomplete.map((e) => e.toString()).join(', ')}',
      );
    } on Exception catch (e) {
      Log.sync.w('[Journal] 启动自检失败（忽略）', error: e);
    }
  }

  /// 更新 Keyring（改密码后或 dataKey 迁移后调用）
  ///
  /// 重建 SyncEngine 以使用新的 keyring 引用。
  /// dataKey 不变时（改密码场景），不影响已加密的笔记。
  /// dataKey 变化时（迁移场景），database._dataKey 已在 migrateToRemote 中更新。
  Future<void> updateKeyring({
    required Keyring keyring,
    required NotesDatabase database,
  }) async {
    final previous = _keyring;
    _keyring = keyring;

    // journal 可能尚未打开（initialize 之前调用），惰性补开
    _journal ??= await _openJournal(vaultId: keyring.vaultId);
    final journal = _journal!;

    // P2 journal §3.5：改密码是「密钥状态变更」中最关键的一类，必须留痕。
    //
    // 为什么记在这里而不是 Keyring.changePassword 内部：Keyring 是纯密钥
    // 模型，不应该知道 journal 的存在（否则单测要造 journal、层次也脏）。
    // updateKeyring 是改密码成功后的**唯一汇聚点**（UI 层 changePassword
    // 之后必调），在这里记录既完整又不侵入密钥层。
    //
    // 判定条件用 keyVersion 递增而非「调用了 updateKeyring」——因为迁移
    // 场景（dataKeyEpoch 变化）也会调它，那类事件由 SyncEngine 的
    // key.migrate 负责，不能重复记。
    if (previous != null && keyring.keyVersion > previous.keyVersion) {
      journal.append(
        type: JournalEventType.keyChangePassword,
        phase: JournalPhase.done,
        dataKeyEpoch: keyring.dataKeyEpoch,
        keyState: JournalKeyState(
          keyVersion: keyring.keyVersion,
          dataKeyEpoch: keyring.dataKeyEpoch,
          keyFingerprint: keyring.keyFingerprint,
          encryptedDataKey: keyring.encryptedDataKey,
        ),
        note: 'keyVersion ${previous.keyVersion} -> ${keyring.keyVersion}',
      );
      // 改密码后紧接着会 sync（见 change_passphrase.dart），但万一同步失败，
      // 这条「新 encryptedDataKey 长什么样」的记录必须已经落盘——它是密码
      // 改了却没推上去时唯一的取真依据。
      await journal.flush();
    }

    final backend = _backend;
    final deviceId = _deviceId;
    if (backend != null && deviceId != null) {
      _engine = SyncEngine(
        backend: backend,
        database: database,
        keyring: keyring,
        deviceId: deviceId,
        journal: journal,
        passphraseProvider: () => PhraseHandler.getPass,
        // B2：迁移成功后回写 _keyring
        onKeyringChanged: (k) => _keyring = k,
      );
    }

    // P3-log：updateKeyring 完成（改密码 / 迁移后的关键节点，便于追踪密钥状态切换）
    final prevVersion = previous?.keyVersion;
    Log.sync.i(
      'updateKeyring: keyring 已更新 '
      '(keyVersion: ${prevVersion ?? "null"} → ${keyring.keyVersion}, '
      'dataKeyEpoch: ${keyring.dataKeyEpoch}), SyncEngine ${backend != null ? "已重建" : "未重建（backend=null）"}',
    );
  }

  /// 销毁同步服务（应用退出时调用）
  ///
  /// 日志 Web 服务器与日志文件的关闭由 main.dart 的 _shutdown 统一负责，
  /// 因为它们的生命周期是应用级的，比 SyncService 更长。
  Future<void> dispose() async {
    Log.sync.i('SyncService dispose');
    _autoSyncTimer?.cancel();
    _autoSyncFailureRetried = false; // P3-b：清理重试状态
    // 先关 journal（内部会 flush 未落盘的缓冲），再关后端
    await _closeJournal();
    await _backend?.close();
    await _stateController.close();
    _keyring = null;
    _backend = null;
    _engine = null;
    _deviceId = null;
    _backendReady = false;
  }

  /// 关闭 journal（flush 缓冲 + 释放定时器），失败不抛
  Future<void> _closeJournal() async {
    final journal = _journal;
    _journal = null;
    if (journal == null) return;
    try {
      await journal.close();
    } on Exception catch (e) {
      Log.sync.w('[Journal] 关闭失败（忽略）', error: e);
    }
  }

  /// 用户登出时调用：清除敏感数据但保留 stream（供下次登录复用）
  ///
  /// 与 [dispose] 的区别：
  ///   - dispose：应用退出，关闭 stream controller，完全销毁
  ///   - logout：用户登出，保留 stream 和 _deviceId，重置状态到 uninitialized
  ///
  /// 清除内容：
  ///   - keyring 引用（含 MK 缓存）
  ///   - backend 连接（含认证 token）
  ///   - engine 实例
  /// 不清除：
  ///   - _stateController（供下次登录继续监听）
  ///   - _deviceId（设备 ID 不变，无需重新查询）
  ///   - SyncConfig（后端配置持久化在 SharedPreferences）
  Future<void> logout() async {
    _autoSyncTimer?.cancel();
    _autoSyncFailureRetried = false; // P3-b：清理重试状态
    // journal 与金库绑定，登出后可能换金库登录，必须关掉（并 flush）
    await _closeJournal();
    await _backend?.close();
    _keyring = null;
    _backend = null;
    _engine = null;
    _backendReady = false;
    _updateState(const SyncServiceState(status: SyncStatus.uninitialized));
  }

  // ──────────────────────────────────────────────
  // 同步触发
  // ──────────────────────────────────────────────

  /// 手动触发同步
  ///
  /// 互斥：如果已有同步在进行中，直接返回当前状态。
  /// 同步完成后更新状态并通知监听者。
  ///
  /// 返回同步结果。如果未初始化或正在同步，返回 null。
  Future<SyncResult?> sync() async {
    // 总开关守卫：用户手动关闭同步后，任何路径都不得再碰远端。
    // applyConfigToService 通常已经把引擎拆掉了，这里是二道防线——
    // 覆盖"配置在别处被改、引擎还残留"的边界情况。
    // 仅在配置系统就绪（SyncConfig.isInitialized）后才拦截：未初始化时
    // 没有用户偏好可依据，按历史行为放行（纯逻辑测试、启动早期窗口等）。
    if (SyncConfig.isInitialized && !SyncConfig.isSyncEnabled) {
      Log.sync.d('sync 被跳过：同步总开关已关闭');
      _updateState(
        state.copyWith(
          status: SyncStatus.error,
          errorMessage: 'Sync is disabled in settings'.tr(),
        ),
      );
      return null;
    }

    // 评审 #6 修复：互斥锁必须放在**入口第一行**（任何 await 之前）抢锁。
    // 原实现把检查放在 `await backend.init()` 之后，两个并发 sync() 可同时
    // 通过 `_syncInProgress` 检查（check-then-act 竞态），导致两个引擎并发跑。
    if (_syncInProgress) {
      Log.sync.d('同步被跳过（已有同步进行中）');
      return null;
    }
    _syncInProgress = true;
    _updateState(
      state.copyWith(status: SyncStatus.syncing, errorMessage: null),
    );

    try {
      final engine = _engine;
      if (engine == null) {
        _updateState(
          state.copyWith(
            status: SyncStatus.error,
            errorMessage: 'Sync service not initialized'.tr(),
          ),
        );
        return null;
      }

      // Bug A 修复：惰性（重）初始化后端。
      // 初始化时若离线，backend.init() 失败并保持未就绪状态，后续每次 sync
      // 都会因 backend 未初始化而抛 "Call init() before using the backend"。
      // 这里在每次 sync 开始时尝试（重）初始化：联网成功即自动恢复，
      // 失败则优雅返回"网络不可用，请稍后重试"，不再抛出 cryptic 错误；
      // 下次同步仍会重试，因此重连后无需杀进程即可恢复。
      if (!_backendReady) {
        final backend = _backend;
        if (backend == null) {
          _updateState(
            state.copyWith(
              status: SyncStatus.error,
              errorMessage: 'Sync service not initialized'.tr(),
            ),
          );
          return null;
        }
        try {
          Log.sync.i('后端未就绪，尝试重新初始化');
          await backend.init();
          _backendReady = true;
        } on BackendUnavailableException catch (e, st) {
          Log.sync.w('后端初始化失败（网络不可用）', error: e, stackTrace: st);
          _updateState(
            state.copyWith(
              status: SyncStatus.error,
              lastSyncTime: DateTime.now(),
              errorMessage:
                  'Network unavailable; check your connection and retry: {error}'
                      .tr(namedArgs: {'error': '$e'}),
            ),
          );
          return SyncResult.failure(
            'Network unavailable; check your connection and retry: {error}'.tr(
              namedArgs: {'error': '$e'},
            ),
          );
        } on Exception catch (e, st) {
          Log.sync.e('后端初始化失败（未预期异常）', error: e, stackTrace: st);
          _updateState(
            state.copyWith(
              status: SyncStatus.error,
              lastSyncTime: DateTime.now(),
              errorMessage: 'Backend initialization failed: {error}'.tr(
                namedArgs: {'error': '$e'},
              ),
            ),
          );
          return SyncResult.failure(
            'Backend initialization failed: {error}'.tr(
              namedArgs: {'error': '$e'},
            ),
          );
        }
      }

      final result = await engine.sync();
      _updateState(
        state.copyWith(
          status: result.success ? SyncStatus.success : SyncStatus.error,
          lastSyncTime: DateTime.now(),
          lastResult: result,
          errorMessage: result.success ? null : result.errorMessage,
        ),
      );
      return result;
    } on BackendUnavailableException catch (e, st) {
      Log.sync.e('同步失败（后端不可用）', error: e, stackTrace: st);
      _updateState(
        state.copyWith(
          status: SyncStatus.error,
          lastSyncTime: DateTime.now(),
          errorMessage: 'Backend unavailable: {error}'.tr(
            namedArgs: {'error': '$e'},
          ),
        ),
      );
      return SyncResult.failure(
        'Backend unavailable: {error}'.tr(namedArgs: {'error': '$e'}),
      );
    } on Exception catch (e, st) {
      Log.sync.e('同步失败（未预期异常）', error: e, stackTrace: st);
      _updateState(
        state.copyWith(
          status: SyncStatus.error,
          lastSyncTime: DateTime.now(),
          errorMessage: 'Sync error: {error}'.tr(namedArgs: {'error': '$e'}),
        ),
      );
      return SyncResult.failure(
        'Sync error: {error}'.tr(namedArgs: {'error': '$e'}),
      );
    } finally {
      _syncInProgress = false;
    }
  }

  /// 全面校验并修复远端同步数据（设置页「修复同步数据」按钮调用）。
  ///
  /// 委托给 [SyncEngine.repairRemote]。
  /// 返回修复结果；未初始化 / 正在同步时返回 null。
  Future<SyncResult?> repairRemote() async {
    // 评审 #6 修复（同 sync()）：互斥锁在入口第一行抢锁，避免修复与同步、
    // 修复与修复并发（原实现把 _syncInProgress 检查放在网络 await 之后）。
    if (_syncInProgress) return null;
    _syncInProgress = true;
    _updateState(
      state.copyWith(status: SyncStatus.syncing, errorMessage: null),
    );

    try {
      final engine = _engine;
      if (engine == null) {
        _updateState(
          state.copyWith(
            status: SyncStatus.error,
            errorMessage: 'Sync service not initialized'.tr(),
          ),
        );
        return null;
      }

      // 惰性（重）初始化后端（与 sync 同逻辑，详见 sync() 注释）
      if (!_backendReady) {
        final backend = _backend;
        if (backend == null) {
          _updateState(
            state.copyWith(
              status: SyncStatus.error,
              errorMessage: 'Sync service not initialized'.tr(),
            ),
          );
          return null;
        }
        try {
          Log.sync.i('repairRemote: 后端未就绪，尝试重新初始化');
          await backend.init();
          _backendReady = true;
        } on BackendUnavailableException catch (e, st) {
          Log.sync.w('repairRemote: 后端初始化失败', error: e, stackTrace: st);
          return SyncResult.failure(
            'Network unavailable; check your connection and retry: {error}'.tr(
              namedArgs: {'error': '$e'},
            ),
          );
        } on Exception catch (e, st) {
          Log.sync.e('repairRemote: 后端初始化失败（未预期异常）', error: e, stackTrace: st);
          return SyncResult.failure(
            'Backend initialization failed: {error}'.tr(
              namedArgs: {'error': '$e'},
            ),
          );
        }
      }

      Log.sync.i('repairRemote: 开始修复');
      final result = await engine.repairRemote();
      Log.sync.i(
        'repairRemote: 修复完成 (success=${result.success}, '
        'uploaded=${result.uploaded}, failed=${result.failedNoteUuids.length})',
      );
      _updateState(
        state.copyWith(
          status: result.success ? SyncStatus.success : SyncStatus.error,
          lastSyncTime: DateTime.now(),
          lastResult: result,
          errorMessage: result.success ? null : result.errorMessage,
        ),
      );
      return result;
    } on BackendUnavailableException catch (e, st) {
      Log.sync.e('repairRemote: 后端不可用', error: e, stackTrace: st);
      return SyncResult.failure(
        'Backend unavailable: {error}'.tr(namedArgs: {'error': '$e'}),
      );
    } on Exception catch (e, st) {
      Log.sync.e('repairRemote: 修复异常', error: e, stackTrace: st);
      return SyncResult.failure(
        'Repair error: {error}'.tr(namedArgs: {'error': '$e'}),
      );
    } finally {
      _syncInProgress = false;
    }
  }

  /// 笔记变更后自动同步（debounce 3 秒）
  ///
  /// 频繁调用（如打字时自动保存）只触发一次同步。
  /// 非阻塞：立即返回，不等待同步完成。
  ///
  /// L3 修复：如果调用时已有同步在进行中，会重新排程一次（debounce），
  /// 确保连续编辑触发的最后一次变更不会因为"正在同步"而被丢弃。
  ///
  /// P3-b 互斥增强：
  ///   - **race 修复**：sync 完成后的 L3 re-schedule 不能覆盖用户在 sync 期间
  ///     新触发的 debounce timer。检查 `_autoSyncTimer?.isActive`，若已有
  ///     pending timer 则让用户的 debounce 继续，避免「T6 完成的 sync 覆盖
  ///     T4 用户编辑排程的 timer」导致用户最新编辑被立即基于旧状态同步、
  ///     多余一次同步开销。
  ///   - **失败可重试**：sync 返回非 null 但 success=false 时（网络抖动等），
  ///     排程一次重试；为避免失败死循环，限制最多 1 次失败重试，下一次失败
  ///     交给用户下次编辑或手动 sync 触发。
  ///   - **状态可见**：在 timer 触发/被跳过/re-schedule 各路径补 debug 日志，
  ///     便于排查「改了笔记怎么没同步」类问题。
  void autoSync() {
    if (SyncConfig.isInitialized && !SyncConfig.isSyncEnabled) return;
    if (_engine == null) return;

    // 笔记变更后触发自动同步（debounce）：记录排程，便于排查"改了没同步"
    Log.sync.d('autoSync: 已排程 (${_autoSyncDelay.inSeconds}s 后触发)');
    _autoSyncTimer?.cancel();
    _autoSyncTimer = Timer(_autoSyncDelay, () {
      Log.sync.d('autoSync: timer 触发，调用 sync()');
      // 评审 #12 修复：onError 兜底 `Error`（而非只 catch `Exception`）。
      // 原实现 `.then((result){...})` 只处理正常返回，sync() 若抛
      // RangeError/StateError 等 `Error`（不经过 on Exception）会让该
      // Promise 以未处理错误结束，_syncInProgress 相关状态虽由 finally
      // 复位，但错误本身无日志、无重试排程，表现为"改了笔记却从此不再同步"。
      sync().then(
        (result) {
          // L3 兜底：如果本次同步因"正在同步"被跳过（返回 null），
          // 重新排程一次，确保最新变更不丢失
          if (result == null && _engine != null) {
            // P3-b：re-schedule 前先检查是否已有用户在 sync 期间新排程的
            // timer；若有，让用户的 debounce 继续，不覆盖
            if (_autoSyncTimer?.isActive ?? false) {
              Log.sync.d('autoSync: 上次被跳过，已有 pending timer，不覆盖');
            } else {
              Log.sync.d('autoSync: 上次同步被跳过，重新排程一次');
              _autoSyncTimer = Timer(_autoSyncDelay, () => sync());
            }
            return;
          }
          // P3-b：sync 失败（result.success=false，如网络抖动）时排程一次重试。
          // 限制最多 1 次失败重试：用 _autoSyncFailureRetried 标志位防死循环，
          // 重试成功或再次失败后清零，下次 autoSync 触发的 sync 失败仍可重试一次
          if (result != null && !result.success && _engine != null) {
            if (_autoSyncFailureRetried) {
              Log.sync.d('autoSync: 上次失败已重试过，等待用户下次触发');
              _autoSyncFailureRetried = false;
            } else if (_autoSyncTimer?.isActive ?? false) {
              // 用户已新排程 timer，让用户的 debounce 接管
              Log.sync.d('autoSync: sync 失败但已有 pending timer，不重试');
            } else {
              Log.sync.d('autoSync: sync 失败，排程一次重试');
              _autoSyncFailureRetried = true;
              _autoSyncTimer = Timer(_autoSyncDelay, () {
                _autoSyncFailureRetried = false; // 进入重试即清零，允许后续重试
                sync();
              });
            }
          } else if (result != null && result.success) {
            // 成功时清零重试标志
            _autoSyncFailureRetried = false;
          }
        },
        onError: (Object e, StackTrace st) {
          Log.sync.e(
            'autoSync: sync() 抛出未预期错误，放弃本次自动同步'
            '（错误已记录，用户下次编辑或手动同步可重试）',
            error: e,
            stackTrace: st,
          );
        },
      );
    });
  }

  /// P3-b：autoSync 失败重试标志位（防死循环）
  ///
  /// 语义：true 表示「上一次 autoSync 触发的 sync 失败，已排程了一次重试」。
  /// 重试 timer 触发或下次成功 sync 时清零，限制单次失败只重试一次。
  /// 不暴露给外部，仅 autoSync 内部维护。
  bool _autoSyncFailureRetried = false;

  // ──────────────────────────────────────────────
  // 后端管理
  // ──────────────────────────────────────────────

  /// 切换后端（设置页修改同步配置后调用）
  ///
  /// 关闭旧后端，初始化新后端。
  ///
  /// P6 修复（DS001）：切换前检查同步互斥锁。同步/修复进行中时 `_backend.close()`
  /// 会关闭正在被 [SyncEngine] 使用的连接或文件句柄，后续 I/O 将收到
  /// BackendUnavailableException 或静默错误 → 同步结果不可预测。与 [sync] /
  /// [repairRemote] 的互斥语义一致，此处拒绝切换。
  Future<void> switchBackend({
    required SyncBackend backend,
    required NotesDatabase database,
  }) async {
    if (_syncInProgress) {
      // P3-log：拒绝切换（避免 StateError 抛出后从日志看不出原因）
      Log.sync.w('switchBackend 被拒绝（同步进行中），抛 StateError');
      throw StateError(
        'Sync in progress; cannot switch backend. Please retry later.'.tr(),
      );
    }
    final oldType = _backend?.runtimeType.toString() ?? 'null';
    Log.sync.i('切换同步后端: $oldType → ${backend.runtimeType}');
    await _backend?.close();
    _backend = backend;
    await backend.init();
    _backendReady = true;

    final keyring = _keyring;
    final deviceId = _deviceId;
    if (keyring != null && deviceId != null) {
      // 换后端不换金库：复用同一个 journal 实例，保持 seq 与上传水位连续
      _journal ??= await _openJournal(vaultId: keyring.vaultId);
      _engine = SyncEngine(
        backend: backend,
        database: database,
        keyring: keyring,
        deviceId: deviceId,
        journal: _journal!,
        passphraseProvider: () => PhraseHandler.getPass,
        // B2：迁移成功后回写 _keyring
        onKeyringChanged: (k) => _keyring = k,
      );
    }

    // P3-log：切换完成（含 SyncEngine 重建状态，便于排查切换后状态不一致）
    Log.sync.i(
      'switchBackend 完成 (providerKey=${backend.providerKey}, '
      'engine=${keyring != null && deviceId != null ? "已重建" : "未重建（keyring/deviceId=null）"})',
    );
  }

  /// F-H06 修复：设置页修改配置（后端类型/URL/凭据）后应用生效。
  ///
  /// 场景：用户改了 WebDAV 密码/URL，或把「不同步」→「WebDAV」，
  /// 原实现只写 [SyncConfig]，运行中的 [SyncEngine] 仍握着旧 backend，
  /// autoSync 继续用旧配置同步——改配置形同虚设。
  ///
  /// 行为：
  ///   - 总开关关闭 或 配置不完整 → 停用引擎/后端，阻止任何同步；
  ///   - 配置可用且引擎已初始化 → [switchBackend] 重建引擎；
  ///   - 配置可用但引擎尚未建立、keyring 已解锁 → 走 [initBackend]
  ///     完整初始化（需求 3：开关一打开就自动把同步服务拉起来）；
  ///   - 配置可用但未登录（keyring 为空）→ 仅保存配置，登录时再初始化。
  ///
  /// 返回 (success, error)：仅当"本次确实尝试了初始化/切换"且失败时
  /// success=false，其余情况（无需动作、未登录）均为 success=true。
  Future<({bool success, String? error})> applyConfigToService({
    required NotesDatabase database,
  }) async {
    if (SyncConfig.isInitialized && !SyncConfig.isSyncEnabled) {
      // 用户关闭总开关：停用现有引擎与后端，此后 sync()/autoSync() 均不可用
      await _shutdownEngine(reason: '同步总开关已关闭');
      return (success: true, error: null);
    }

    final backend = _createBackendFromConfig();
    if (backend == null) {
      // 配置不完整（路径/URL/凭据缺失）：同样停用，避免用半截配置去同步
      await _shutdownEngine(reason: '同步配置不完整');
      return (success: true, error: null);
    }

    // 未登录：keyring 还没解锁，建不了引擎。仅保存配置，登录流程会接手。
    if (_keyring == null) {
      Log.sync.i('applyConfigToService: keyring 未就绪，仅保存配置');
      return (success: true, error: null);
    }

    // 需求 3：keyring 已解锁但引擎/设备 ID 还没建起来（首次启用同步、
    // 或此前配置不完整被停用过）→ 走完整初始化。
    // 不能用 switchBackend：它依赖 initialize() 设置的 _deviceId，
    // 为空时会静默跳过 SyncEngine 重建，表现为"配置好了却始终未初始化"。
    if (_engine == null || _deviceId == null) {
      Log.sync.i('applyConfigToService: 引擎未就绪，执行完整初始化');
      return initBackend(database: database);
    }

    try {
      // 引擎已就绪：切换后端（内含互斥与重建）
      await switchBackend(backend: backend, database: database);
      Log.sync.i(
        'applyConfigToService: 配置变更已应用到 SyncService '
        '(providerKey=${backend.providerKey})',
      );
      return (success: true, error: null);
    } on StateError catch (e) {
      Log.sync.w('applyConfigToService: 切换后端被拒绝', error: e);
      return (success: false, error: '$e');
    } on BackendUnavailableException catch (e) {
      Log.sync.w('applyConfigToService: 新后端不可用', error: e);
      return (
        success: false,
        error: 'Backend unavailable: {error}'.tr(namedArgs: {'error': '$e'}),
      );
    } on Exception catch (e, st) {
      Log.sync.e('applyConfigToService: 切换后端失败', error: e, stackTrace: st);
      return (
        success: false,
        error: 'Failed to switch backend: {error}'.tr(
          namedArgs: {'error': '$e'},
        ),
      );
    }
  }

  /// 停用同步引擎与后端（关总开关 / 配置不完整时调用）
  ///
  /// 幂等：已经是停用状态时不做任何事，也不重复刷状态。
  Future<void> _shutdownEngine({required String reason}) async {
    if (_engine == null && _backend == null) return;
    Log.sync.i('$reason：停止引擎并关闭后端');
    _autoSyncTimer?.cancel();
    await _backend?.close();
    _backend = null;
    _engine = null;
    _backendReady = false;
    _updateState(const SyncServiceState(status: SyncStatus.uninitialized));
  }

  /// 获取当前后端（供 UI 显示配置信息）
  SyncBackend? get backend => _backend;

  /// 获取当前 Keyring（供改密码等操作使用）
  Keyring? get keyring => _keyring;

  // ──────────────────────────────────────────────
  // 调试面板支持（E1/E2）
  // ──────────────────────────────────────────────

  /// 获取诊断快照（调试面板"状态"页用）
  ///
  /// 返回当前同步子系统的完整状态信息（不含敏感凭据），用于调试面板展示。
  /// 包含：同步状态、后端配置、Keyring 元数据、设备 ID、最近同步结果、
  /// manifest version、失败笔记列表、日志文件路径等。
  SyncDiagnosticsSnapshot getDiagnosticsSnapshot() {
    final keyring = _keyring;
    final backend = _backend;
    final lastResult = state.lastResult;

    return SyncDiagnosticsSnapshot(
      captureTime: DateTime.now(),
      // 同步状态
      status: state.status.name,
      lastSyncTime: state.lastSyncTime,
      errorMessage: state.errorMessage,
      isSyncing: _syncInProgress,
      backendReady: _backendReady,
      // 后端配置（不含密码/Token）
      backendType: SyncConfig.backendType.name,
      backendDisplayName: SyncConfig.backendDisplayName,
      backendRuntimeType: backend?.runtimeType.toString(),
      providerKey: backend?.providerKey,
      localFsPath: SyncConfig.localFsPath,
      // 评审 #17 修复：诊断快照会经 LogWebServer（局域网可达）暴露，
      // webdavUrl 可能内嵌 user:pass@，用户名也不应完整公开——统一脱敏。
      webdavUrl: _redactUrl(SyncConfig.webdavUrl),
      webdavUsername: _maskUsername(SyncConfig.webdavUsername),
      safeServerUrl: _redactUrl(SyncConfig.safeServerUrl),
      syncEnabled: SyncConfig.isSyncEnabled,
      autoSyncEnabled: SyncConfig.isAutoSyncEnabled,
      // Keyring 元数据
      vaultId: keyring?.vaultId,
      keyVersion: keyring?.keyVersion,
      dataKeyEpoch: keyring?.dataKeyEpoch,
      keyFingerprint: keyring?.keyFingerprint,
      kdfAlgorithm: keyring?.kdf.algorithm,
      kdfIterations: keyring?.kdf.iterations,
      // 设备
      deviceId: _deviceId,
      // 最近同步结果
      lastResultSuccess: lastResult?.success,
      lastResultAttempts: lastResult?.attempts,
      lastResultUploaded: lastResult?.uploaded,
      lastResultDownloaded: lastResult?.downloaded,
      lastResultDeleted: lastResult?.deleted,
      lastResultConflicts: lastResult?.conflicts,
      lastResultMigrated: lastResult?.migrated,
      lastResultSkipped: lastResult?.skipped,
      lastResultPasswordEpochMismatch: lastResult?.passwordEpochMismatch,
      lastResultRequiresRelogin: lastResult?.requiresRelogin,
      lastResultErrorMessage: lastResult?.errorMessage,
      lastResultFailedNoteUuids: lastResult?.failedNoteUuids,
      lastResultActions: lastResult?.actions
          .map((a) => SyncActionInfo.fromAction(a))
          .toList(),
      // 日志
      logDirPath: AppLogFile.dirPath,
      logBufferCount: AppLogBuffer.instance.all().length,
    );
  }

  /// 获取日志缓冲区所有条目（调试面板"日志"页用）
  List<AppLogEntry> getLogEntries() => AppLogBuffer.instance.snapshot();

  /// 实时日志流（调试面板 StreamBuilder 监听用）
  Stream<AppLogEntry> get logStream => AppLogBuffer.instance.stream;

  /// 清空内存日志缓冲（调试面板"清空日志"按钮）
  void clearLogBuffer() => AppLogBuffer.instance.clear();

  /// 获取当前日志文件路径（调试面板"导出日志"按钮用）
  Future<String?> getLogFilePath() => AppLogFile.currentPath();

  /// 供 LogWebServer JSON 端点（/api/status /api/sync /api/actions /api/memory）
  /// 使用的完整调试快照。各端点从返回 Map 的对应子键提取数据。
  Map<String, dynamic> getDebugJson() {
    final snap = getDiagnosticsSnapshot();
    return {
      'status': {
        'status': snap.status,
        'isSyncing': snap.isSyncing,
        'backendReady': snap.backendReady,
        'syncEnabled': snap.syncEnabled,
        'autoSyncEnabled': snap.autoSyncEnabled,
        'backendType': snap.backendType,
        'backendDisplayName': snap.backendDisplayName,
        'backendRuntimeType': snap.backendRuntimeType,
        'providerKey': snap.providerKey,
        'localFsPath': snap.localFsPath,
        'webdavUrl': snap.webdavUrl,
        'webdavUsername': snap.webdavUsername,
        'safeServerUrl': snap.safeServerUrl,
        'deviceId': snap.deviceId,
        'lastSyncTime': snap.lastSyncTime?.toIso8601String(),
        'errorMessage': snap.errorMessage,
        'vaultId': snap.vaultId,
        'keyVersion': snap.keyVersion,
        'dataKeyEpoch': snap.dataKeyEpoch,
        'keyFingerprint': snap.keyFingerprint,
        'kdfAlgorithm': snap.kdfAlgorithm,
        'kdfIterations': snap.kdfIterations,
        'logDirPath': snap.logDirPath,
        'logBufferCount': snap.logBufferCount,
      },
      'sync': {
        'success': snap.lastResultSuccess,
        'attempts': snap.lastResultAttempts,
        'uploaded': snap.lastResultUploaded,
        'downloaded': snap.lastResultDownloaded,
        'deleted': snap.lastResultDeleted,
        'conflicts': snap.lastResultConflicts,
        'migrated': snap.lastResultMigrated,
        'skipped': snap.lastResultSkipped,
        'passwordEpochMismatch': snap.lastResultPasswordEpochMismatch,
        'requiresRelogin': snap.lastResultRequiresRelogin,
        'errorMessage': snap.lastResultErrorMessage,
        'failedNoteUuids': snap.lastResultFailedNoteUuids,
      },
      'actions': snap.lastResultActions?.map((a) => a.toJson()).toList() ?? [],
      'memory': getMemorySnapshot(),
    };
  }

  /// 内存数据快照（运行时真实状态，不含敏感内容）。
  ///
  /// 与早期仅返回布尔/计数不同，这里展示**实际数据**：
  /// - 缓存笔记摘要（uuid/标题/删除标记/修改时间/同步标记，不含正文）
  /// - Keyring 元数据（vaultId/指纹/版本/epoch/kdf，不含密钥本身）
  /// - Journal 运行态摘要
  Map<String, dynamic> getMemorySnapshot() {
    final db = NotesDatabase.instance;
    final snap = getDiagnosticsSnapshot();
    return {
      'status': state.status.name,
      'isSyncing': _syncInProgress,
      'backendReady': _backendReady,
      'lastSyncTime': state.lastSyncTime?.toIso8601String(),
      'hasKeyring': _keyring != null,
      'hasBackend': _backend != null,
      'hasEngine': _engine != null,
      'hasJournal': _journal != null,
      'db': db.getCacheInfo(),
      'cachedNotes': db.cachedNoteSummaries(),
      'keyring': {
        'vaultId': snap.vaultId,
        'keyFingerprint': snap.keyFingerprint,
        'keyVersion': snap.keyVersion,
        'dataKeyEpoch': snap.dataKeyEpoch,
        'kdfAlgorithm': snap.kdfAlgorithm,
        'kdfIterations': snap.kdfIterations,
      },
      'journal': _journalSummary(),
    };
  }

  Map<String, dynamic> _journalSummary() {
    final j = _journal;
    if (j == null) return {'present': false};
    return {
      'present': true,
      'entryCount': j.entries.length,
      'pendingCount': j.pendingCount,
      'nextSeq': j.nextSeq,
      'uploadedSeq': j.uploadedSeq,
    };
  }

  /// Journal 完整导出（供 /api/download/journal 与内存快照使用）。
  ///
  /// 读取全部条目（含归档），每条转为 JSON；不含任何密钥明文。
  Future<Map<String, dynamic>> getJournalDump() async {
    final j = _journal;
    if (j == null) return {'present': false};
    final entries = (await j.readAll()).map((e) => e.toJson()).toList();
    return {'present': true, 'entryCount': entries.length, 'entries': entries};
  }

  /// 导出全部日志为文本（调试面板"复制全部"按钮用）
  ///
  /// 格式：每条一行，含时间戳/级别/消息/错误/堆栈。
  /// 同时包含当前诊断快照作为头部信息。
  Future<String> exportAllLogsAsText() async {
    final snapshot = getDiagnosticsSnapshot();
    final buffer = StringBuffer();
    buffer.writeln('=== SafeNotes 同步诊断快照 ===');
    buffer.writeln('导出时间: ${snapshot.captureTime}');
    buffer.writeln('设备 ID: ${snapshot.deviceId ?? "N/A"}');
    buffer.writeln(
      '后端: ${snapshot.backendDisplayName} '
      '(${snapshot.backendRuntimeType ?? "N/A"})',
    );
    buffer.writeln('Keyring ID: ${snapshot.vaultId ?? "N/A"}');
    buffer.writeln(
      'keyVersion: ${snapshot.keyVersion ?? "N/A"}, '
      'dataKeyEpoch: ${snapshot.dataKeyEpoch ?? "N/A"}',
    );
    buffer.writeln(
      '同步状态: ${snapshot.status}, '
      'isSyncing=${snapshot.isSyncing}',
    );
    if (snapshot.errorMessage != null) {
      buffer.writeln('错误信息: ${snapshot.errorMessage}');
    }
    if (snapshot.lastResultErrorMessage != null) {
      buffer.writeln('上次同步错误: ${snapshot.lastResultErrorMessage}');
    }
    if (snapshot.lastResultFailedNoteUuids?.isNotEmpty ?? false) {
      buffer.writeln(
        '失败笔记 UUID: '
        '${snapshot.lastResultFailedNoteUuids!.join(", ")}',
      );
    }
    buffer.writeln('日志目录: ${snapshot.logDirPath ?? "N/A"}');
    buffer.writeln('');
    buffer.writeln('=== 日志记录 ===');
    for (final entry in AppLogBuffer.instance.all()) {
      buffer.writeln(entry.formattedLine);
    }
    return buffer.toString();
  }

  /// 导出诊断 + 日志文本到系统下载目录（调试面板"导出"按钮用）
  ///
  /// 桌面端与 Android 均优先 [getDownloadsDirectory]（无需任何存储权限）；
  /// 平台不支持或目录不可用时回退到应用文档目录。
  /// 返回写入的文件绝对路径（供 SnackBar 展示）。
  Future<String> exportAllLogsToFile() async {
    final text = await exportAllLogsAsText();
    Directory? dir;
    try {
      dir = await getDownloadsDirectory();
    } on UnsupportedError {
      // 平台无 Downloads 概念（iOS 等）
    }
    dir ??= await getApplicationDocumentsDirectory();
    final ts = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[:\-]'), '')
        .replaceAll(' ', 'T')
        .substring(0, 15);
    final file = File(p.join(dir.path, 'safenotes-logs-$ts.txt'));
    await file.writeAsString(text, flush: true);
    Log.ui.i('诊断+日志已导出: ${file.path}');
    return file.path;
  }

  /// 清空全部日志（内存缓冲 + 日志文件，调试面板测试 tab 用）
  ///
  /// 返回删除的日志文件数。当前 sink 关闭后下次写入自动重建，
  /// 不影响日志系统继续工作。
  Future<int> clearAllLogs() async {
    AppLogBuffer.instance.clear();
    final deleted = await AppLogFile.clearLogFiles();
    Log.sync.w('[Debug] 日志已清空（调试操作）：删除文件数=$deleted');
    return deleted;
  }

  /// 清空 journal 本地日志（调试面板测试 tab 用）
  ///
  /// journal 未打开时抛 StateError（正常流程 journal 在 initialize 时打开，
  /// 未打开说明同步尚未初始化，此时也无 journal 可清）。
  Future<void> clearJournal() async {
    final j = _journal;
    if (j == null) {
      throw StateError('journal not opened');
    }
    await j.flush();
    await j.clear();
  }

  // ──────────────────────────────────────────────
  // 内部辅助
  // ──────────────────────────────────────────────

  /// 评审 #17 修复：诊断快照中的 URL 脱敏。
  ///
  /// 处理两类泄露源：
  ///   1. URL 内嵌 userinfo（`https://user:pass@host/`）→ 整体掩为 `***`
  ///   2. query 参数（可能携带 token/code）→ 掩为 `***`
  static String _redactUrl(String url) {
    if (url.isEmpty) return url;
    try {
      final uri = Uri.parse(url);
      var u = uri;
      if (u.userInfo.isNotEmpty) {
        u = u.replace(userInfo: '***');
      }
      if (u.hasQuery) {
        u = u.replace(query: '***');
      }
      return u.toString();
    } on FormatException {
      // 非合法 URL：对常见的 `scheme://user:pass@` 前缀做正则掩码
      return url.replaceAll(RegExp(r'(https?://)[^/@\s]+@'), r'$1***@');
    }
  }

  /// 评审 #17 修复：用户名脱敏，只保留前 2 字符 + `***`。
  static String _maskUsername(String username) {
    if (username.isEmpty) return username;
    if (username.length <= 2) return '***';
    return '${username.substring(0, 2)}***';
  }

  void _updateState(SyncServiceState newState) {
    _state = newState;
    // 评审 #12 修复：dispose 后 stream controller 已关闭，再 add 会抛
    // StateError("Cannot add event after closing")。这是安全性守卫——
    // dispose 是最终行为，关闭后状态同步本身没有意义，直接忽略即可。
    if (!_stateController.isClosed) {
      _stateController.add(newState);
    }
  }

  // ──────────────────────────────────────────────
  // 登录流程辅助：keyring 初始化 + 后端初始化
  // ──────────────────────────────────────────────

  /// 登录/设置密码时调用：初始化 Keyring 并注入 dataKey 到 database
  ///
  /// B1 方案：无论是否启用同步，都生成/解锁 dataKey，用于本地加密。
  /// 流程：
  ///   1. 检查本地 keyring 是否已初始化
  ///   2. 已初始化 → Keyring.unlockLocal（用密码解密 dataKey）
  ///   3. 未初始化 → Keyring.createNew（首次设置密码，生成 dataKey）
  ///   4. 将 dataKey 注入 NotesDatabase（后续所有 read/write 自动加解密）
  ///
  /// 返回 (success, error)。失败时不抛异常，由 UI 层处理。
  Future<({bool success, String? error})> initKeyringFromPassword({
    required String password,
    required NotesDatabase database,
  }) async {
    try {
      final isInitialized = await Keyring.isInitialized(database);
      Log.sync.i(
        '登录密钥环准备: 本地是否已初始化=$isInitialized, '
        '${isInitialized ? "将解锁(密码解密 dataKey)" : "将新建(生成 dataKey)"}',
      );

      final Keyring keyring;
      if (isInitialized) {
        keyring = await Keyring.unlockLocal(
          password: password,
          database: database,
        );
      } else {
        keyring = await Keyring.createNew(
          password: password,
          database: database,
        );
      }

      // 注入 dataKey 到 database（启用本地加解密）
      database.setDataKey(keyring.dataKey);
      // 缓存 keyring（改密码、启用同步时用）
      _keyring = keyring;

      return (success: true, error: null);
    } on WrongPasswordException catch (e) {
      return (
        success: false,
        error: 'Wrong passphrase: {error}'.tr(namedArgs: {'error': '$e'}),
      );
    } on Exception catch (e) {
      return (
        success: false,
        error: 'Keyring initialization failed: {error}'.tr(
          namedArgs: {'error': '$e'},
        ),
      );
    }
  }

  /// 启用同步时调用：用已缓存的 keyring 初始化后端 + SyncEngine
  ///
  /// 前置条件：initKeyringFromPassword 已执行（_keyring 已缓存）
  /// 流程：
  ///   1. 检查 SyncConfig 是否已配置后端
  ///   2. 创建后端实例
  ///   3. 调用 initialize(keyring, backend) 启动 SyncEngine
  ///
  /// 返回 (success, error)。
  Future<({bool success, String? error})> initBackend({
    required NotesDatabase database,
  }) async {
    final keyring = _keyring;
    if (keyring == null) {
      return (
        success: false,
        error: 'Keyring not initialized. Please log in again.'.tr(),
      );
    }

    final backend = _createBackendFromConfig();
    if (backend == null) {
      return (
        success: false,
        error: 'Backend configuration is incomplete'.tr(),
      );
    }

    Log.sync.i(
      '启用同步: 后端类型=${SyncConfig.backendType.name}'
      ' (${SyncConfig.backendDisplayName}), 开始初始化',
    );
    try {
      await initialize(keyring: keyring, backend: backend, database: database);
      return (success: true, error: null);
    } on Exception catch (e) {
      return (
        success: false,
        error: 'Backend initialization failed: {error}'.tr(
          namedArgs: {'error': '$e'},
        ),
      );
    }
  }

  /// 根据 SyncConfig 创建后端实例（内部辅助）
  ///
  /// 返回 null 表示配置不完整（路径为空、URL 缺失等）。
  /// 构造与完整性判定逻辑统一收敛在 [SyncBackendDraft]，避免与配置面板
  /// 的「能否保存」判断出现两套标准。
  static SyncBackend? _createBackendFromConfig() =>
      SyncBackendDraft.fromConfig().buildBackend();

  // ──────────────────────────────────────────────
  // 连接测试（配置面板「测试」按钮）
  // ──────────────────────────────────────────────

  /// 测试一份**尚未保存**的后端配置能否真正连通。
  ///
  /// 用草稿构造一个临时后端实例，与单例持有的 [_backend] 完全隔离：
  /// 测试失败不会影响正在运行的同步，测试成功也不会自动生效。
  ///
  /// 检测两层：
  ///   1. [SyncBackend.init]：目录可建 / 服务可达（WebDAV 在此识别 401）；
  ///   2. [SyncBackend.getManifest]：一次**带认证**的真实读取。
  ///      这一步不可省——SafeServer 的 health 端点不校验 Token，只做 init
  ///      的话填错 Token 也会显示"测试通过"。远端还没有 manifest 时后端
  ///      统一返回空内容而非报错，所以首次配置同样能通过。
  ///
  /// 无论成功失败都会 close 临时后端，不泄漏 HTTP 连接。
  Future<({bool success, String? error})> testBackendConfig(
    SyncBackendDraft draft,
  ) async {
    if (draft.type == SyncBackendType.none) {
      return (success: false, error: 'No sync backend type selected'.tr());
    }
    final backend = draft.buildBackend();
    if (backend == null) {
      return (
        success: false,
        error: 'Configuration incomplete; please fill in required fields'.tr(),
      );
    }

    Log.sync.i('测试同步后端连接: type=${draft.type.name}');
    try {
      await backend.init();
      await backend.getManifest();
      Log.sync.i('同步后端连接测试通过 (providerKey=${backend.providerKey})');
      return (success: true, error: null);
    } on BackendUnavailableException catch (e) {
      Log.sync.w('同步后端连接测试失败（后端不可用）', error: e);
      return (success: false, error: '$e');
    } on Exception catch (e, st) {
      Log.sync.w('同步后端连接测试失败', error: e, stackTrace: st);
      return (success: false, error: '$e');
    } finally {
      try {
        await backend.close();
      } on Exception catch (e) {
        Log.sync.d('测试后端 close 失败（忽略）: $e');
      }
    }
  }

  /// B2 修复：登录页验证密码时创建后端实例（不污染单例状态）
  ///
  /// 与 [_createBackendFromConfig] 相同，但公开给 login.dart 使用。
  /// 返回的后端实例独立于 _backend，调用方负责 init/close。
  /// 返回 null 表示配置不完整或未启用同步。
  SyncBackend? createBackendForVerification() => _createBackendFromConfig();

  /// B2 修复：登录页通过 keyring 验证密码后缓存 keyring 引用
  ///
  /// 在 _tryVerifyPassphraseViaVault 验证成功后调用，
  /// 把已解锁的 Keyring 实例缓存到 _keyring，供后续 initBackend 使用。
  /// 避免重复解锁（PBKDF2 600k 迭代耗时 1-2 秒）。
  Future<void> cacheKeyringFromLogin(Keyring keyring) async {
    _keyring = keyring;
  }
}
