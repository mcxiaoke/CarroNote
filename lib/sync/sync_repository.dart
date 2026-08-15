/*
 * 同步仓储抽象层（Port）
 *
 * 定义 [SyncRepository] 抽象类，作为 UI 层与同步服务的单一接口。
 * 提供两个实现：
 *   - [SyncServiceRepository]：委托给 [SyncService.instance]（生产）
 *   - [FakeSyncRepository]：内存状态，用于测试
 */

// Dart imports:
import 'dart:async';

// Flutter imports:
import 'package:flutter/foundation.dart';

// Package imports:
import 'package:core/core.dart';

// Project imports:
import 'package:safenotes/sync/sync_config.dart';
import 'package:safenotes/sync/sync_service.dart';

/// 同步仓储抽象接口
///
/// 继承 [ChangeNotifier] 使 UI 可通过 Provider 监听状态变化。
/// 所有方法签名与 [SyncService] 的公开 API 对齐。
abstract class SyncRepository extends ChangeNotifier {
  /// 初始化同步服务
  Future<void> initialize({
    required Keyring keyring,
    required SyncBackend backend,
  });

  /// 手动触发同步
  Future<SyncResult?> sync();

  /// 笔记变更后自动同步（debounce）
  void autoSync();

  /// 用户登出
  Future<void> logout();

  /// 当前同步状态
  SyncServiceState get state;

  /// 是否正在同步
  bool get isSyncing;

  /// 是否已初始化
  bool get isInitialized;

  /// 切换后端
  Future<void> switchBackend(SyncBackend backend);

  /// 将当前配置应用到同步服务
  Future<({bool success, String? error})> applyConfigToService();

  /// 从密码初始化 Keyring
  Future<({bool success, String? error})> initKeyringFromPassword(
    String password,
  );

  /// 初始化后端
  Future<({bool success, String? error})> initBackend();

  /// 测试后端配置是否可连通
  Future<({bool success, String? error})> testBackendConfig(
    String providerKey,
    Map<String, String> config,
  );

  /// 状态变化流
  Stream<SyncServiceState> get stateStream;

  /// 登录成功后缓存已解锁的 Keyring
  Future<void> cacheKeyringFromLogin(Keyring keyring);

  /// 更新 Keyring（改密码）
  Future<void> updateKeyring({
    required String currentPassword,
    required String newPassword,
  });

  /// 获取 Journal 完整导出
  Future<Map<String, dynamic>> getJournalDump();

  /// 导出全部日志为文本
  Future<String> exportAllLogsAsText();
}

/// 生产实现：委托给 [SyncService.instance]
class SyncServiceRepository extends SyncRepository {
  StreamSubscription<SyncServiceState>? _stateSub;

  SyncServiceRepository() {
    _stateSub = SyncService.instance.stateStream.listen((_) {
      notifyListeners();
    });
  }

  @override
  Future<void> initialize({
    required Keyring keyring,
    required SyncBackend backend,
  }) async {
    await SyncService.instance.initialize(
      keyring: keyring,
      backend: backend,
      database: NotesDatabase.instance,
    );
    notifyListeners();
  }

  @override
  Future<SyncResult?> sync() async {
    final result = await SyncService.instance.sync();
    notifyListeners();
    return result;
  }

  @override
  void autoSync() {
    SyncService.instance.autoSync();
    notifyListeners();
  }

  @override
  Future<void> logout() async {
    await SyncService.instance.logout();
    notifyListeners();
  }

  @override
  SyncServiceState get state => SyncService.instance.state;

  @override
  bool get isSyncing => SyncService.instance.isSyncing;

  @override
  bool get isInitialized => SyncService.instance.state.isInitialized;

  @override
  Future<void> switchBackend(SyncBackend backend) async {
    await SyncService.instance.switchBackend(
      backend: backend,
      database: NotesDatabase.instance,
    );
    notifyListeners();
  }

  @override
  Future<({bool success, String? error})> applyConfigToService() async {
    final result = await SyncService.instance.applyConfigToService(
      database: NotesDatabase.instance,
    );
    notifyListeners();
    return result;
  }

  @override
  Future<({bool success, String? error})> initKeyringFromPassword(
    String password,
  ) async {
    final result = await SyncService.instance.initKeyringFromPassword(
      password: password,
      database: NotesDatabase.instance,
    );
    notifyListeners();
    return result;
  }

  @override
  Future<({bool success, String? error})> initBackend() async {
    final result = await SyncService.instance.initBackend(
      database: NotesDatabase.instance,
    );
    notifyListeners();
    return result;
  }

  @override
  Future<({bool success, String? error})> testBackendConfig(
    String providerKey,
    Map<String, String> config,
  ) async {
    final draft = SyncBackendDraft(
      type: _parseBackendType(providerKey),
      localFsPath: config['localFsPath'] ?? '',
      webdavUrl: config['webdavUrl'] ?? '',
      webdavUsername: config['webdavUsername'] ?? '',
      webdavPassword: config['webdavPassword'] ?? '',
      safeServerUrl: config['safeServerUrl'] ?? '',
      safeServerToken: config['safeServerToken'] ?? '',
    );
    final result = await SyncService.instance.testBackendConfig(draft);
    return result;
  }

  @override
  Stream<SyncServiceState> get stateStream => SyncService.instance.stateStream;

  @override
  Future<void> cacheKeyringFromLogin(Keyring keyring) async {
    await SyncService.instance.cacheKeyringFromLogin(keyring);
    notifyListeners();
  }

  @override
  Future<void> updateKeyring({
    required String currentPassword,
    required String newPassword,
  }) async {
    final keyring = SyncService.instance.keyring;
    if (keyring == null) {
      throw StateError('Keyring not initialized');
    }
    final updated = await keyring.changePassword(
      oldPassword: currentPassword,
      newPassword: newPassword,
      database: NotesDatabase.instance,
    );
    await SyncService.instance.updateKeyring(
      keyring: updated,
      database: NotesDatabase.instance,
    );
    notifyListeners();
  }

  @override
  Future<Map<String, dynamic>> getJournalDump() async {
    return SyncService.instance.getJournalDump();
  }

  @override
  Future<String> exportAllLogsAsText() async {
    return SyncService.instance.exportAllLogsAsText();
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    super.dispose();
  }

  /// 将 providerKey 映射为 [SyncBackendType]
  SyncBackendType _parseBackendType(String providerKey) {
    if (providerKey.startsWith('localFs')) return SyncBackendType.localFs;
    if (providerKey.startsWith('webdav')) return SyncBackendType.webdav;
    if (providerKey.startsWith('safeServer')) return SyncBackendType.safeServer;
    return SyncBackendType.none;
  }
}

/// 假实现：内存状态，不触发真实同步
///
/// 用于 widget 测试，避免依赖 [SyncService] 单例。
class FakeSyncRepository extends SyncRepository {
  SyncServiceState _state = const SyncServiceState();
  bool _isSyncing = false;
  bool _isInitialized = false;
  Keyring? _keyring;
  SyncBackend? _backend;

  final StreamController<SyncServiceState> _stateController =
      StreamController<SyncServiceState>.broadcast();

  @override
  SyncServiceState get state => _state;

  @override
  bool get isSyncing => _isSyncing;

  @override
  bool get isInitialized => _isInitialized;

  @override
  Stream<SyncServiceState> get stateStream => _stateController.stream;

  /// 当前持有的 Keyring 引用
  Keyring? get keyring => _keyring;

  /// 当前持有的后端引用
  SyncBackend? get backend => _backend;

  @override
  Future<void> initialize({
    required Keyring keyring,
    required SyncBackend backend,
  }) async {
    _keyring = keyring;
    _backend = backend;
    _isInitialized = true;
    _state = const SyncServiceState(status: SyncStatus.idle);
    _stateController.add(_state);
    notifyListeners();
  }

  @override
  Future<SyncResult?> sync() async {
    // 不做任何实际同步操作
    return null;
  }

  @override
  void autoSync() {
    // 不做任何操作
  }

  @override
  Future<void> logout() async {
    _keyring = null;
    _backend = null;
    _isInitialized = false;
    _isSyncing = false;
    _state = const SyncServiceState();
    _stateController.add(_state);
    notifyListeners();
  }

  @override
  Future<void> switchBackend(SyncBackend backend) async {
    _backend = backend;
    notifyListeners();
  }

  @override
  Future<({bool success, String? error})> applyConfigToService() async {
    return (success: true, error: null);
  }

  @override
  Future<({bool success, String? error})> initKeyringFromPassword(
    String password,
  ) async {
    if (password.isEmpty) {
      return (success: false, error: 'Password is empty');
    }
    _isInitialized = true;
    notifyListeners();
    return (success: true, error: null);
  }

  @override
  Future<({bool success, String? error})> initBackend() async {
    if (_keyring == null) {
      return (success: false, error: 'Keyring not initialized');
    }
    _isInitialized = true;
    _state = const SyncServiceState(status: SyncStatus.idle);
    _stateController.add(_state);
    notifyListeners();
    return (success: true, error: null);
  }

  @override
  Future<({bool success, String? error})> testBackendConfig(
    String providerKey,
    Map<String, String> config,
  ) async {
    // 假实现总是返回成功
    return (success: true, error: null);
  }

  @override
  Future<void> cacheKeyringFromLogin(Keyring keyring) async {
    _keyring = keyring;
    notifyListeners();
  }

  @override
  Future<void> updateKeyring({
    required String currentPassword,
    required String newPassword,
  }) async {
    // 假实现不做实际密码变更
    notifyListeners();
  }

  @override
  Future<Map<String, dynamic>> getJournalDump() async {
    return {'present': false};
  }

  @override
  Future<String> exportAllLogsAsText() async {
    return '=== FakeSyncRepository Logs ===\nNo logs available.';
  }

  /// 设置同步状态（测试辅助方法）
  void setState(SyncServiceState newState) {
    _state = newState;
    _stateController.add(_state);
    notifyListeners();
  }

  /// 设置同步中标志（测试辅助方法）
  void setSyncing(bool syncing) {
    _isSyncing = syncing;
    notifyListeners();
  }

  @override
  void dispose() {
    _stateController.close();
    super.dispose();
  }
}
