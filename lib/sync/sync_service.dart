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

// 第三方导入
import 'package:path_provider/path_provider.dart';

// 项目导入
import 'package:safenotes/data/database_handler.dart';
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/sync/journal.dart';
import 'package:safenotes/sync/local_fs_backend.dart';
import 'package:safenotes/sync/safe_server_backend.dart';
import 'package:safenotes/sync/sync_backend.dart';
import 'package:safenotes/sync/sync_config.dart';
import 'package:safenotes/sync/sync_engine.dart';
import 'package:safenotes/utils/log_webserver.dart';
import 'package:safenotes/utils/app_logger.dart';
import 'package:safenotes/sync/sync_models.dart';
import 'package:safenotes/sync/keyring.dart';
import 'package:safenotes/sync/webdav_backend.dart';
import 'package:safenotes/utils/device_id.dart';

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
  }) =>
      SyncServiceState(
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
    // 向日志 Web 服务器注入"同步诊断快照"提供者，使 /diagnostics 端点可用。
    // 采用反向注入而非直接依赖，避免 utils 层反向依赖 sync 层。
    LogWebServer.instance.diagnosticsProvider = exportAllLogsAsText;

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

    Log.sync.i('SyncService 初始化 (backend=${backend.runtimeType}, '
        'deviceId=$_deviceId, vaultId=${keyring.vaultId}, '
        'keyVersion=${keyring.keyVersion}, dataKeyEpoch=${keyring.dataKeyEpoch})');

    await backend.init();
    _backendReady = true;

    Log.sync.i('后端初始化成功 (providerKey=${backend.providerKey})');
    _updateState(state.copyWith(status: SyncStatus.idle));

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
      Log.sync.w('[Journal] 检测到 ${incomplete.length} 个未完成操作'
          '（仅报告，不自动重放）：'
          '${incomplete.map((e) => e.toString()).join(', ')}');
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
  }

  /// 销毁同步服务（应用退出时调用）
  ///
  /// 日志 Web 服务器与日志文件的关闭由 main.dart 的 _shutdown 统一负责，
  /// 因为它们的生命周期是应用级的，比 SyncService 更长。
  Future<void> dispose() async {
    Log.sync.i('SyncService dispose');
    _autoSyncTimer?.cancel();
    LogWebServer.instance.diagnosticsProvider = null;
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
    final engine = _engine;
    if (engine == null) {
      _updateState(state.copyWith(
        status: SyncStatus.error,
        errorMessage: '同步服务未初始化',
      ));
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
        _updateState(state.copyWith(
          status: SyncStatus.error,
          errorMessage: '同步服务未初始化',
        ));
        return null;
      }
      try {
        Log.sync.i('后端未就绪，尝试重新初始化');
        await backend.init();
        _backendReady = true;
      } on BackendUnavailableException catch (e, st) {
        Log.sync.w('后端初始化失败（网络不可用）', error: e, stackTrace: st);
        _updateState(state.copyWith(
          status: SyncStatus.error,
          lastSyncTime: DateTime.now(),
          errorMessage: '网络不可用，请检查连接后重试：$e',
        ));
        return SyncResult.failure('网络不可用，请检查连接后重试：$e');
      } on Exception catch (e, st) {
        Log.sync.e('后端初始化失败（未预期异常）', error: e, stackTrace: st);
        _updateState(state.copyWith(
          status: SyncStatus.error,
          lastSyncTime: DateTime.now(),
          errorMessage: '后端初始化失败：$e',
        ));
        return SyncResult.failure('后端初始化失败：$e');
      }
    }

    // 互斥锁
    if (_syncInProgress) {
      Log.sync.d('同步被跳过（已有同步进行中）');
      return null;
    }

    _syncInProgress = true;
    _updateState(state.copyWith(
      status: SyncStatus.syncing,
      errorMessage: null,
    ));

    try {
      final result = await engine.sync();
      _updateState(state.copyWith(
        status: result.success ? SyncStatus.success : SyncStatus.error,
        lastSyncTime: DateTime.now(),
        lastResult: result,
        errorMessage: result.success ? null : result.errorMessage,
      ));
      return result;
    } on BackendUnavailableException catch (e, st) {
      Log.sync.e('同步失败（后端不可用）', error: e, stackTrace: st);
      _updateState(state.copyWith(
        status: SyncStatus.error,
        lastSyncTime: DateTime.now(),
        errorMessage: '后端不可用：$e',
      ));
      return SyncResult.failure('后端不可用：$e');
    } on Exception catch (e, st) {
      Log.sync.e('同步失败（未预期异常）', error: e, stackTrace: st);
      _updateState(state.copyWith(
        status: SyncStatus.error,
        lastSyncTime: DateTime.now(),
        errorMessage: '同步异常：$e',
      ));
      return SyncResult.failure('同步异常：$e');
    } finally {
      _syncInProgress = false;
    }
  }

  /// 全面校验并修复远端同步数据（设置页「修复同步数据」按钮调用）。
  ///
  /// 委托给 [SyncEngine.repairRemote]。
  /// 返回修复结果；未初始化 / 正在同步时返回 null。
  Future<SyncResult?> repairRemote() async {
    final engine = _engine;
    if (engine == null) {
      _updateState(state.copyWith(
        status: SyncStatus.error,
        errorMessage: '同步服务未初始化',
      ));
      return null;
    }

    // 惰性（重）初始化后端（与 sync 同逻辑，详见 sync() 注释）
    if (!_backendReady) {
      final backend = _backend;
      if (backend == null) {
        _updateState(state.copyWith(
          status: SyncStatus.error,
          errorMessage: '同步服务未初始化',
        ));
        return null;
      }
      try {
        Log.sync.i('repairRemote: 后端未就绪，尝试重新初始化');
        await backend.init();
        _backendReady = true;
      } on BackendUnavailableException catch (e, st) {
        Log.sync.w('repairRemote: 后端初始化失败', error: e, stackTrace: st);
        return SyncResult.failure('网络不可用，请检查连接后重试：$e');
      } on Exception catch (e, st) {
        Log.sync.e('repairRemote: 后端初始化失败（未预期异常）',
            error: e, stackTrace: st);
        return SyncResult.failure('后端初始化失败：$e');
      }
    }

    // 与同步互斥（修复期间不应并发同步）
    if (_syncInProgress) return null;

    Log.sync.i('repairRemote: 开始修复');
    _syncInProgress = true;
    _updateState(state.copyWith(
      status: SyncStatus.syncing,
      errorMessage: null,
    ));

    try {
      final result = await engine.repairRemote();
      Log.sync.i('repairRemote: 修复完成 (success=${result.success}, '
          'uploaded=${result.uploaded}, failed=${result.failedNoteUuids.length})');
      _updateState(state.copyWith(
        status: result.success ? SyncStatus.success : SyncStatus.error,
        lastSyncTime: DateTime.now(),
        lastResult: result,
        errorMessage: result.success ? null : result.errorMessage,
      ));
      return result;
    } on BackendUnavailableException catch (e, st) {
      Log.sync.e('repairRemote: 后端不可用', error: e, stackTrace: st);
      return SyncResult.failure('后端不可用：$e');
    } on Exception catch (e, st) {
      Log.sync.e('repairRemote: 修复异常', error: e, stackTrace: st);
      return SyncResult.failure('修复异常：$e');
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
  void autoSync() {
    if (_engine == null) return;

    // 笔记变更后触发自动同步（debounce）：记录排程，便于排查"改了没同步"
    Log.sync.d('autoSync: 已排程 (${_autoSyncDelay.inSeconds}s 后触发)');
    _autoSyncTimer?.cancel();
    _autoSyncTimer = Timer(_autoSyncDelay, () {
      sync().then((result) {
        // L3 兜底：如果本次同步因"正在同步"被跳过（返回 null），
        // 重新排程一次，确保最新变更不丢失
        if (result == null && _engine != null) {
          Log.sync.d('autoSync: 上次同步被跳过，重新排程一次');
          _autoSyncTimer = Timer(_autoSyncDelay, () => sync());
        }
      });
    });
  }

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
      throw StateError('同步进行中，无法切换后端，请稍后重试');
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
      webdavUrl: SyncConfig.webdavUrl,
      webdavUsername: SyncConfig.webdavUsername,
      safeServerUrl: SyncConfig.safeServerUrl,
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
    buffer.writeln('后端: ${snapshot.backendDisplayName} '
        '(${snapshot.backendRuntimeType ?? "N/A"})');
    buffer.writeln('Keyring ID: ${snapshot.vaultId ?? "N/A"}');
    buffer.writeln('keyVersion: ${snapshot.keyVersion ?? "N/A"}, '
        'dataKeyEpoch: ${snapshot.dataKeyEpoch ?? "N/A"}');
    buffer.writeln('同步状态: ${snapshot.status}, '
        'isSyncing=${snapshot.isSyncing}');
    if (snapshot.errorMessage != null) {
      buffer.writeln('错误信息: ${snapshot.errorMessage}');
    }
    if (snapshot.lastResultErrorMessage != null) {
      buffer.writeln('上次同步错误: ${snapshot.lastResultErrorMessage}');
    }
    if (snapshot.lastResultFailedNoteUuids?.isNotEmpty ?? false) {
      buffer.writeln('失败笔记 UUID: '
          '${snapshot.lastResultFailedNoteUuids!.join(", ")}');
    }
    buffer.writeln('日志目录: ${snapshot.logDirPath ?? "N/A"}');
    buffer.writeln('');
    buffer.writeln('=== 日志记录 ===');
    for (final entry in AppLogBuffer.instance.all()) {
      buffer.writeln(entry.formattedLine);
    }
    return buffer.toString();
  }

  // ──────────────────────────────────────────────
  // 内部辅助
  // ──────────────────────────────────────────────

  void _updateState(SyncServiceState newState) {
    _state = newState;
    _stateController.add(newState);
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
      Log.sync.i('登录密钥环准备: 本地是否已初始化=$isInitialized, '
          '${isInitialized ? "将解锁(密码解密 dataKey)" : "将新建(生成 dataKey)"}');

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
      return (success: false, error: '密码错误：$e');
    } on Exception catch (e) {
      return (success: false, error: 'Keyring 初始化失败：$e');
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
      return (success: false, error: 'Keyring 未初始化，请重新登录');
    }

    final backend = _createBackendFromConfig();
    if (backend == null) {
      return (success: false, error: '后端配置不完整');
    }

    Log.sync.i('启用同步: 后端类型=${SyncConfig.backendType.name}'
        ' (${SyncConfig.backendDisplayName}), 开始初始化');
    try {
      await initialize(
        keyring: keyring,
        backend: backend,
        database: database,
      );
      return (success: true, error: null);
    } on Exception catch (e) {
      return (success: false, error: '后端初始化失败：$e');
    }
  }

  /// 根据 SyncConfig 创建后端实例（内部辅助）
  ///
  /// 返回 null 表示配置不完整（路径为空、URL 缺失等）。
  static SyncBackend? _createBackendFromConfig() {
    switch (SyncConfig.backendType) {
      case SyncBackendType.none:
        return null;
      case SyncBackendType.localFs:
        if (SyncConfig.localFsPath.isEmpty) return null;
        return LocalFsBackend(rootPath: SyncConfig.localFsPath);
      case SyncBackendType.webdav:
        if (SyncConfig.webdavUrl.isEmpty ||
            SyncConfig.webdavUsername.isEmpty) {
          return null;
        }
        return WebDavBackend(
          baseUrl: SyncConfig.webdavUrl,
          username: SyncConfig.webdavUsername,
          password: SyncConfig.webdavPassword,
        );
      case SyncBackendType.safeServer:
        if (SyncConfig.safeServerUrl.isEmpty ||
            SyncConfig.safeServerToken.isEmpty) {
          return null;
        }
        return SafeServerBackend(
          baseUrl: SyncConfig.safeServerUrl,
          token: SyncConfig.safeServerToken,
        );
    }
  }

  /// B2 修复：登录页验证密码时创建后端实例（不污染单例状态）
  ///
  /// 与 [_createBackendFromConfig] 相同，但公开给 login.dart 使用。
  /// 返回的后端实例独立于 _backend，调用方负责 init/close。
  /// 返回 null 表示配置不完整或未启用同步。
  SyncBackend? createBackendForVerification() =>
      _createBackendFromConfig();

  /// B2 修复：登录页通过 keyring 验证密码后缓存 keyring 引用
  ///
  /// 在 _tryVerifyPassphraseViaVault 验证成功后调用，
  /// 把已解锁的 Keyring 实例缓存到 _keyring，供后续 initBackend 使用。
  /// 避免重复解锁（PBKDF2 600k 迭代耗时 1-2 秒）。
  Future<void> cacheKeyringFromLogin(Keyring keyring) async {
    _keyring = keyring;
  }
}
