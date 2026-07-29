/*
 * 同步服务（应用层）
 *
 * 职责：
 *   1. 持有 Vault + SyncBackend + SyncEngine 实例，统一管理生命周期
 *   2. 互斥锁：同一时间只允许一个 sync() 执行（防止并发冲突）
 *   3. 状态管理：对外暴露 SyncState，供 UI 观察同步状态
 *   4. 触发同步：手动 sync() / 笔记变更后 autoSync()
 *
 * 不负责：
 *   - UI 渲染（由 Widget 层通过 ChangeNotification 监听状态）
 *   - 后端配置（由 Settings 页面配置后传入）
 *   - 密码输入（由 Vault 层处理）
 *
 * 使用方式：
 *   final service = SyncService();
 *   await service.initialize(vault: vault, backend: backend);
 *   await service.sync();  // 手动触发
 *   service.autoSync();    // 笔记变更后调用（非阻塞，内部 debounce）
 */

// Dart 导入
import 'dart:async';

// 项目导入
import 'package:safenotes/data/database_handler.dart';
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/sync/local_fs_backend.dart';
import 'package:safenotes/sync/safe_server_backend.dart';
import 'package:safenotes/sync/sync_backend.dart';
import 'package:safenotes/sync/sync_config.dart';
import 'package:safenotes/sync/sync_engine.dart';
import 'package:safenotes/sync/sync_models.dart';
import 'package:safenotes/sync/vault.dart';
import 'package:safenotes/sync/webdav_backend.dart';
import 'package:safenotes/utils/device_id.dart';

/// 同步状态枚举（供 UI 显示）
enum SyncStatus {
  /// 未初始化（未配置 vault 或 backend）
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

  Vault? _vault;
  SyncBackend? _backend;
  SyncEngine? _engine;

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
  /// [vault] 已解锁的 Vault 实例
  /// [backend] 已配置的 SyncBackend 实例
  /// [database] 本地数据库
  Future<void> initialize({
    required Vault vault,
    required SyncBackend backend,
    required NotesDatabase database,
  }) async {
    _vault = vault;
    _backend = backend;

    // 获取设备 ID（首次调用会查询系统 API，后续用缓存）
    _deviceId = await DeviceIdProvider.instance.getDeviceId();

    _engine = SyncEngine(
      backend: backend,
      database: database,
      vault: vault,
      deviceId: _deviceId!,
      passphraseProvider: () => PhraseHandler.getPass,
    );

    await backend.init();
    _backendReady = true;

    _updateState(state.copyWith(status: SyncStatus.idle));
  }

  /// 更新 Vault（改密码后或 dataKey 迁移后调用）
  ///
  /// 重建 SyncEngine 以使用新的 vault 引用。
  /// dataKey 不变时（改密码场景），不影响已加密的笔记。
  /// dataKey 变化时（迁移场景），database._dataKey 已在 migrateToRemote 中更新。
  Future<void> updateVault({
    required Vault vault,
    required NotesDatabase database,
  }) async {
    _vault = vault;
    final backend = _backend;
    final deviceId = _deviceId;
    if (backend != null && deviceId != null) {
      _engine = SyncEngine(
        backend: backend,
        database: database,
        vault: vault,
        deviceId: deviceId,
        passphraseProvider: () => PhraseHandler.getPass,
      );
    }
  }

  /// 销毁同步服务（应用退出时调用）
  Future<void> dispose() async {
    _autoSyncTimer?.cancel();
    await _backend?.close();
    await _stateController.close();
    _vault = null;
    _backend = null;
    _engine = null;
    _deviceId = null;
    _backendReady = false;
  }

  /// 用户登出时调用：清除敏感数据但保留 stream（供下次登录复用）
  ///
  /// 与 [dispose] 的区别：
  ///   - dispose：应用退出，关闭 stream controller，完全销毁
  ///   - logout：用户登出，保留 stream 和 _deviceId，重置状态到 uninitialized
  ///
  /// 清除内容：
  ///   - vault 引用（含 MK 缓存）
  ///   - backend 连接（含认证 token）
  ///   - engine 实例
  /// 不清除：
  ///   - _stateController（供下次登录继续监听）
  ///   - _deviceId（设备 ID 不变，无需重新查询）
  ///   - SyncConfig（后端配置持久化在 SharedPreferences）
  Future<void> logout() async {
    _autoSyncTimer?.cancel();
    await _backend?.close();
    _vault = null;
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
        await backend.init();
        _backendReady = true;
      } on BackendUnavailableException catch (e) {
        _updateState(state.copyWith(
          status: SyncStatus.error,
          lastSyncTime: DateTime.now(),
          errorMessage: '网络不可用，请检查连接后重试：$e',
        ));
        return SyncResult.failure('网络不可用，请检查连接后重试：$e');
      } on Exception catch (e) {
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
    } on BackendUnavailableException catch (e) {
      _updateState(state.copyWith(
        status: SyncStatus.error,
        lastSyncTime: DateTime.now(),
        errorMessage: '后端不可用：$e',
      ));
      return SyncResult.failure('后端不可用：$e');
    } on Exception catch (e) {
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

  /// 笔记变更后自动同步（debounce 3 秒）
  ///
  /// 频繁调用（如打字时自动保存）只触发一次同步。
  /// 非阻塞：立即返回，不等待同步完成。
  ///
  /// L3 修复：如果调用时已有同步在进行中，会重新排程一次（debounce），
  /// 确保连续编辑触发的最后一次变更不会因为"正在同步"而被丢弃。
  void autoSync() {
    if (_engine == null) return;

    _autoSyncTimer?.cancel();
    _autoSyncTimer = Timer(_autoSyncDelay, () {
      sync().then((result) {
        // L3 兜底：如果本次同步因"正在同步"被跳过（返回 null），
        // 重新排程一次，确保最新变更不丢失
        if (result == null && _engine != null) {
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
  Future<void> switchBackend({
    required SyncBackend backend,
    required NotesDatabase database,
  }) async {
    await _backend?.close();
    _backend = backend;
    await backend.init();
    _backendReady = true;

    final vault = _vault;
    final deviceId = _deviceId;
    if (vault != null && deviceId != null) {
      _engine = SyncEngine(
        backend: backend,
        database: database,
        vault: vault,
        deviceId: deviceId,
        passphraseProvider: () => PhraseHandler.getPass,
      );
    }
  }

  /// 获取当前后端（供 UI 显示配置信息）
  SyncBackend? get backend => _backend;

  /// 获取当前 Vault（供改密码等操作使用）
  Vault? get vault => _vault;

  // ──────────────────────────────────────────────
  // 内部辅助
  // ──────────────────────────────────────────────

  void _updateState(SyncServiceState newState) {
    _state = newState;
    _stateController.add(newState);
  }

  // ──────────────────────────────────────────────
  // 登录流程辅助：vault 初始化 + 后端初始化
  // ──────────────────────────────────────────────

  /// 登录/设置密码时调用：初始化 Vault 并注入 dataKey 到 database
  ///
  /// B1 方案：无论是否启用同步，都生成/解锁 dataKey，用于本地加密。
  /// 流程：
  ///   1. 检查本地 vault 是否已初始化
  ///   2. 已初始化 → Vault.unlockLocal（用密码解密 dataKey）
  ///   3. 未初始化 → Vault.createNew（首次设置密码，生成 dataKey）
  ///   4. 将 dataKey 注入 NotesDatabase（后续所有 read/write 自动加解密）
  ///
  /// 返回 (success, error)。失败时不抛异常，由 UI 层处理。
  Future<({bool success, String? error})> initVaultFromPassword({
    required String password,
    required NotesDatabase database,
  }) async {
    try {
      final isInitialized = await Vault.isInitialized(database);

      final Vault vault;
      if (isInitialized) {
        vault = await Vault.unlockLocal(
          password: password,
          database: database,
        );
      } else {
        vault = await Vault.createNew(
          password: password,
          database: database,
        );
      }

      // 注入 dataKey 到 database（启用本地加解密）
      database.setDataKey(vault.dataKey);
      // 缓存 vault（改密码、启用同步时用）
      _vault = vault;

      return (success: true, error: null);
    } on WrongPasswordException catch (e) {
      return (success: false, error: '密码错误：$e');
    } on Exception catch (e) {
      return (success: false, error: 'Vault 初始化失败：$e');
    }
  }

  /// 启用同步时调用：用已缓存的 vault 初始化后端 + SyncEngine
  ///
  /// 前置条件：initVaultFromPassword 已执行（_vault 已缓存）
  /// 流程：
  ///   1. 检查 SyncConfig 是否已配置后端
  ///   2. 创建后端实例
  ///   3. 调用 initialize(vault, backend) 启动 SyncEngine
  ///
  /// 返回 (success, error)。
  Future<({bool success, String? error})> initBackend({
    required NotesDatabase database,
  }) async {
    final vault = _vault;
    if (vault == null) {
      return (success: false, error: 'Vault 未初始化，请重新登录');
    }

    final backend = _createBackendFromConfig();
    if (backend == null) {
      return (success: false, error: '后端配置不完整');
    }

    try {
      await initialize(
        vault: vault,
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

  /// B2 修复：登录页通过 vault 验证密码后缓存 vault 引用
  ///
  /// 在 _tryVerifyPassphraseViaVault 验证成功后调用，
  /// 把已解锁的 Vault 实例缓存到 _vault，供后续 initBackend 使用。
  /// 避免重复解锁（PBKDF2 600k 迭代耗时 1-2 秒）。
  Future<void> cacheVaultFromLogin(Vault vault) async {
    _vault = vault;
  }
}
