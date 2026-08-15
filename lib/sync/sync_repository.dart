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
  // ── 状态 ──

  /// 当前同步状态
  SyncServiceState get state;

  /// 状态变化流（UI 监听用）
  Stream<SyncServiceState> get stateStream;

  /// 是否正在同步
  bool get isSyncing;

  /// 是否已初始化
  bool get isInitialized;

  // ── 生命周期 ──

  /// 初始化同步服务
  Future<void> initialize({
    required Keyring keyring,
    required SyncBackend backend,
  });

  /// 用户登出
  Future<void> logout();

  // ── 持有对象（认证/改密流程需直接操作） ──

  /// 当前持有的 Keyring（未初始化返回 null）
  Keyring? get keyring;

  /// 当前持有的后端（未初始化返回 null）
  SyncBackend? get backend;

  // ── 同步操作 ──

  /// 手动触发同步
  Future<SyncResult?> sync();

  /// 修复远端（清理孤立 blob / 重建 manifest）
  Future<SyncResult?> repairRemote();

  /// 笔记变更后自动同步（debounce）
  void autoSync();

  /// 切换后端
  Future<void> switchBackend(SyncBackend backend);

  /// 更新 Keyring（改密码；由调用方先 changePassword 得到新 keyring）
  Future<void> updateKeyring({required Keyring keyring});

  // ── 配置 ──

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
    SyncBackendDraft draft,
  );

  /// 用当前配置构造一个临时后端实例（登录页验证密码用）
  SyncBackend? createBackendForVerification();

  /// 登录成功后缓存已解锁的 Keyring
  Future<void> cacheKeyringFromLogin(Keyring keyring);

  // ── 诊断 / 日志 ──

  /// 同步诊断快照
  SyncDiagnosticsSnapshot getDiagnosticsSnapshot();

  /// 日志缓冲快照
  List<AppLogEntry> getLogEntries();

  /// 日志流
  Stream<AppLogEntry> get logStream;

  /// 清空日志缓冲
  void clearLogBuffer();

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
    SyncBackendDraft draft,
  ) async {
    return SyncService.instance.testBackendConfig(draft);
  }

  @override
  Stream<SyncServiceState> get stateStream => SyncService.instance.stateStream;

  @override
  Future<void> cacheKeyringFromLogin(Keyring keyring) async {
    await SyncService.instance.cacheKeyringFromLogin(keyring);
    notifyListeners();
  }

  @override
  Future<void> updateKeyring({required Keyring keyring}) async {
    await SyncService.instance.updateKeyring(
      keyring: keyring,
      database: NotesDatabase.instance,
    );
    notifyListeners();
  }

  @override
  Keyring? get keyring => SyncService.instance.keyring;

  @override
  SyncBackend? get backend => SyncService.instance.backend;

  @override
  Future<SyncResult?> repairRemote() async {
    final result = await SyncService.instance.repairRemote();
    notifyListeners();
    return result;
  }

  @override
  SyncBackend? createBackendForVerification() =>
      SyncService.instance.createBackendForVerification();

  @override
  SyncDiagnosticsSnapshot getDiagnosticsSnapshot() =>
      SyncService.instance.getDiagnosticsSnapshot();

  @override
  List<AppLogEntry> getLogEntries() => SyncService.instance.getLogEntries();

  @override
  Stream<AppLogEntry> get logStream => SyncService.instance.logStream;

  @override
  void clearLogBuffer() => SyncService.instance.clearLogBuffer();

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
}

