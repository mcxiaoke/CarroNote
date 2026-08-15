// 测试用 fake 实现集合（从 lib/ 移出，避免测试替身污染生产代码）
//
// 来源：
//   - FakeNotesRepository（原 lib/data/note_repository.dart）
//   - FakeSyncRepository（原 lib/sync/sync_repository.dart）
//   - FakeNotesDbAdminPort（原 lib/data/db_admin_port.dart）
//
// 用法见 test/support/harness.dart 的 withProviders()。

// Dart imports:
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

// Flutter imports:
import 'package:flutter/foundation.dart';

// Package imports:
import 'package:core/core.dart';
import 'package:sqflite_common/sqlite_api.dart';

// Project imports:
import 'package:safenotes/data/db_admin_port.dart';
import 'package:safenotes/data/note_repository.dart';
import 'package:safenotes/sync/sync_config.dart';
import 'package:safenotes/sync/sync_repository.dart';
import 'package:safenotes/sync/sync_service.dart';

/// 内存实现：在 [List<SafeNote>] 中存储笔记，不涉及加密或数据库。
///
/// 支持基本的 CRUD 操作。适用于测试和原型开发。
class FakeNotesRepository extends NotesRepository {
  final List<SafeNote> _notes = [];
  int _nextId = 1;
  final Map<String, String> _meta = {};
  final List<String> _purgedUuids = [];
  bool _encryptionEnabled = false;
  Uint8List? _dataKey;
  bool _isMigrating = false;

  /// 可选：用预设笔记列表初始化仓库。
  FakeNotesRepository({List<SafeNote>? seedNotes}) {
    if (seedNotes != null) {
      for (final note in seedNotes) {
        _notes.add(note.copyWith(id: _nextId++));
      }
    }
  }

  @override
  Future<SafeNote> storeNote(SafeNote note) async {
    final id = _nextId++;
    final stored = note.copyWith(id: id);
    _notes.add(stored);
    notifyListeners();
    return stored;
  }

  @override
  Future<int> storeNotesInTransaction(List<SafeNote> notes) async {
    int count = 0;
    for (final note in notes) {
      // 幂等去重：已存在的 uuid 跳过
      if (_notes.any((n) => n.uuid == note.uuid)) continue;
      final id = _nextId++;
      _notes.add(note.copyWith(id: id));
      count++;
    }
    if (count > 0) notifyListeners();
    return count;
  }

  @override
  Future<SafeNote> readNote(int id) async {
    final idx = _notes.indexWhere((n) => n.id == id);
    if (idx < 0) throw Exception('ID $id not found');
    return _notes[idx];
  }

  @override
  Future<SafeNote?> readNoteByUuid(String uuid) async {
    final idx = _notes.indexWhere((n) => n.uuid == uuid);
    return idx >= 0 ? _notes[idx] : null;
  }

  @override
  Future<SafeNote?> readNoteByContentHash(String contentHash) async {
    final idx = _notes.indexWhere(
      (n) => n.contentHash == contentHash && !n.deleted,
    );
    return idx >= 0 ? _notes[idx] : null;
  }

  @override
  Future<List<SafeNote>> readAllNotes() async {
    final notes = _notes.where((n) => !n.deleted).toList()
      ..sort((a, b) => a.createdTime.compareTo(b.createdTime));
    return notes;
  }

  @override
  Future<List<SafeNote>> readDeletedNotes() async {
    final notes = _notes.where((n) => n.deleted).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return notes;
  }

  @override
  Future<List<SafeNote>> readUnsyncedNotes() async {
    return _notes.where((n) => !n.synced).toList();
  }

  @override
  Future<List<SafeNote>> readAllNotesIncludingDeleted() async {
    return List.of(_notes);
  }

  @override
  Future<int> updateNote(SafeNote note) async {
    final idx = _notes.indexWhere((n) => n.id == note.id);
    if (idx < 0) return 0;
    _notes[idx] = note;
    notifyListeners();
    return 1;
  }

  @override
  Future<int> updateNoteByUuid(SafeNote note) async {
    final idx = _notes.indexWhere((n) => n.uuid == note.uuid);
    if (idx < 0) return 0;
    _notes[idx] = note;
    notifyListeners();
    return 1;
  }

  @override
  Future<int> softDelete(int id) async {
    final idx = _notes.indexWhere((n) => n.id == id);
    if (idx < 0) return 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    _notes[idx] = _notes[idx].copyWith(
      deleted: true,
      synced: false,
      updatedAt: now,
    );
    notifyListeners();
    return 1;
  }

  @override
  Future<int> hardDelete(int id) async {
    final idx = _notes.indexWhere((n) => n.id == id);
    if (idx < 0) return 0;
    final uuid = _notes[idx].uuid;
    _notes.removeAt(idx);
    if (!_purgedUuids.contains(uuid)) {
      _purgedUuids.add(uuid);
    }
    notifyListeners();
    return 1;
  }

  @override
  Future<int> hardDeleteByUuid(String uuid) async {
    final idx = _notes.indexWhere((n) => n.uuid == uuid);
    if (idx < 0) return 0;
    _notes.removeAt(idx);
    if (!_purgedUuids.contains(uuid)) {
      _purgedUuids.add(uuid);
    }
    notifyListeners();
    return 1;
  }

  @override
  Future<int> hardDeleteAllDeleted() async {
    final count = _notes.length;
    final uuids = _notes.where((n) => n.deleted).map((n) => n.uuid).toList();
    _notes.removeWhere((n) => n.deleted);
    for (final uuid in uuids) {
      if (!_purgedUuids.contains(uuid)) {
        _purgedUuids.add(uuid);
      }
    }
    final removed = count - _notes.length;
    if (removed > 0) notifyListeners();
    return removed;
  }

  @override
  Future<int> restoreNote(int id) async {
    final idx = _notes.indexWhere((n) => n.id == id);
    if (idx < 0) return 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    _notes[idx] = _notes[idx].copyWith(
      deleted: false,
      synced: false,
      updatedAt: now,
    );
    notifyListeners();
    return 1;
  }

  @override
  void setDataKey(Uint8List key) {
    _dataKey = Uint8List.fromList(key);
    _encryptionEnabled = true;
  }

  @override
  void clearDataKey() {
    _dataKey = null;
    _encryptionEnabled = false;
  }

  @override
  bool get isEncryptionEnabled => _encryptionEnabled;

  @override
  Uint8List get dataKeyForTesting {
    if (_dataKey == null) {
      throw Exception('dataKey 未设置，无法获取（测试用 getter）');
    }
    return Uint8List.fromList(_dataKey!);
  }

  @override
  Future<bool> existsContentHash(String contentHash) async {
    return _notes.any((n) => n.contentHash == contentHash);
  }

  @override
  Future<void> markSynced(String uuid) async {
    final idx = _notes.indexWhere((n) => n.uuid == uuid);
    if (idx >= 0) {
      _notes[idx] = _notes[idx].copyWith(
        synced: true,
        syncedHash: _notes[idx].contentHash,
        syncedDeleted: _notes[idx].deleted,
      );
    }
  }

  @override
  Future<void> markAllSynced() async {
    for (var i = 0; i < _notes.length; i++) {
      _notes[i] = _notes[i].copyWith(
        synced: true,
        syncedHash: _notes[i].contentHash,
        syncedDeleted: _notes[i].deleted,
      );
    }
  }

  @override
  Future<void> markAllSyncedExcept(Set<String> exclude) async {
    if (exclude.isEmpty) {
      await markAllSynced();
      return;
    }
    for (var i = 0; i < _notes.length; i++) {
      if (!exclude.contains(_notes[i].uuid)) {
        _notes[i] = _notes[i].copyWith(
          synced: true,
          syncedHash: _notes[i].contentHash,
          syncedDeleted: _notes[i].deleted,
        );
      }
    }
  }

  @override
  Future<void> markSyncedForUuids(Set<String> uuids) async {
    if (uuids.isEmpty) return;
    for (var i = 0; i < _notes.length; i++) {
      if (uuids.contains(_notes[i].uuid)) {
        _notes[i] = _notes[i].copyWith(
          synced: true,
          syncedHash: _notes[i].contentHash,
          syncedDeleted: _notes[i].deleted,
        );
      }
    }
  }

  @override
  Future<String?> getMeta(String key) async => _meta[key];

  @override
  Future<void> setMeta(String key, String value) async {
    _meta[key] = value;
  }

  @override
  Future<int> getManifestVersion(String providerKey) async {
    final value = _meta['manifest_version:$providerKey'];
    if (value == null) return 0;
    return int.tryParse(value) ?? 0;
  }

  @override
  Future<void> setManifestVersion(String providerKey, int version) async {
    _meta['manifest_version:$providerKey'] = version.toString();
  }

  @override
  Future<List<String>> getPurgedUuids() async => List.of(_purgedUuids);

  @override
  Future<void> removePurgedUuids(List<String> uuids) async {
    _purgedUuids.removeWhere((uuid) => uuids.contains(uuid));
  }

  @override
  Future<String> exportAll() async {
    final notes = await readAllNotes();
    final jsonList = notes.map((note) => note.toJson()).toList();
    // ignore: dart_invalid_json_encoding
    return jsonEncode(jsonList).toString();
  }

  @override
  Future<void> close() async {
    _notes.clear();
    _meta.clear();
    _purgedUuids.clear();
    _dataKey = null;
    _encryptionEnabled = false;
  }

  @override
  Future<String> dbFilePath() async => ':memory: (fake)';

  @override
  Future<void> deleteDbFile() async {
    await close();
  }

  @override
  Future<Map<String, dynamic>> inspectMetadata() async {
    return <String, dynamic>{
      'path': ':memory: (fake)',
      'sizeBytes': null,
      'tables': [
        <String, dynamic>{
          'name': 'safe_notes',
          'type': 'table',
          'sql': '-- fake in-memory --',
          'rowCount': _notes.length,
          'columns': [
            for (final f in NoteFields.values)
              <String, dynamic>{'name': f, 'type': 'TEXT'},
          ],
        },
      ],
      'metaKeys': _meta.keys.toList(),
    };
  }

  @override
  Future<int> reEncryptAllNotes({
    required String oldPassword,
    required String newPassword,
  }) async {
    // Fake 实现：不涉及真实加密，仅占位
    _isMigrating = true;
    try {
      final count = _notes.length;
      // 模拟重加密耗时
      await Future.delayed(const Duration(milliseconds: 10));
      return count;
    } finally {
      _isMigrating = false;
    }
  }

  @override
  bool get isMigrating => _isMigrating;

  @override
  Future<void> markAllForBlobReupload() async {
    // Fake 实现：无操作
  }

  @override
  Future<Set<String>> getPendingReuploadUuids() async => {};

  @override
  Future<void> clearAllPendingReupload() async {
    // Fake 实现：无操作
  }

  @override
  Future<void> removePendingReuploadUuids(Set<String> uploadedOk) async {
    // Fake 实现：无操作
  }

  @override
  Future<Map<String, int>> getGcOrphanCandidates() async => {};

  @override
  Future<void> setGcOrphanCandidates(Map<String, int> candidates) async {
    // Fake 实现：无操作
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
  @override
  Keyring? get keyring => _keyring;

  /// 当前持有的后端引用
  @override
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
    SyncBackendDraft draft,
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
  Future<void> updateKeyring({required Keyring keyring}) async {
    _keyring = keyring;
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

  @override
  Future<SyncResult?> repairRemote() async {
    // 假实现不做任何修复操作
    return null;
  }

  @override
  SyncBackend? createBackendForVerification() => _backend;

  @override
  SyncDiagnosticsSnapshot getDiagnosticsSnapshot() => SyncDiagnosticsSnapshot(
    captureTime: DateTime.now(),
    status: 'idle',
    isSyncing: false,
    backendReady: false,
    backendType: 'none',
    backendDisplayName: 'None',
    localFsPath: '',
    webdavUrl: '',
    webdavUsername: '',
    safeServerUrl: '',
    syncEnabled: false,
    autoSyncEnabled: false,
    logBufferCount: 0,
  );

  @override
  List<AppLogEntry> getLogEntries() => const [];

  @override
  Stream<AppLogEntry> get logStream => const Stream.empty();

  @override
  void clearLogBuffer() {}

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

/// 测试用内存实现。
class FakeNotesDbAdminPort extends NotesDbAdminPort {
  final List<Map<String, dynamic>> _tables = [];
  final String _fakePath = ':memory: (fake)';

  @override
  Future<Database> get database async {
    throw UnimplementedError('FakeNotesDbAdminPort 不提供真实 Database 句柄');
  }

  @override
  Future<List<Map<String, dynamic>>> queryTableRows(
    String table, {
    int limit = 100,
  }) async {
    return _tables.where((t) => t['name'] == table).toList();
  }

  @override
  Future<Map<String, dynamic>> inspectMetadata() async {
    return <String, dynamic>{
      'path': _fakePath,
      'sizeBytes': null,
      'tables': [
        <String, dynamic>{
          'name': 'safe_notes',
          'type': 'table',
          'sql': '-- fake in-memory --',
          'rowCount': 0,
          'columns': [
            for (final f in NoteFields.values)
              <String, dynamic>{'name': f, 'type': 'TEXT'},
          ],
        },
      ],
      'metaKeys': <String>[],
    };
  }

  @override
  Future<String> exportAll() async => '[]';

  @override
  Future<void> close() async {
    // 内存实现：无连接可关闭
  }

  @override
  Future<String> dbFilePath() async => _fakePath;

  @override
  Future<void> deleteDbFile() async {
    // 内存实现：无文件可删
  }
}
