// NotesRepository 接口：抽象化笔记存储层
//
// 设计目标：用 ChangeNotifier 接口替换对 NotesDatabase.instance 的直接调用，
// 使测试可以通过 FakeNotesRepository 注入任意笔记数据，无需依赖真实 SQLite 数据库。
//
// 用法：
//   生产：Provider<NotesRepository>.value(value: NotesDatabaseRepository())
//   测试：Provider<NotesRepository>.value(value: FakeNotesRepository())
//
// §4.2 交付物：
//   - NotesRepository（抽象类，extends ChangeNotifier）
//   - NotesDatabaseRepository（真实实现，委托给 NotesDatabase.instance）
//   - FakeNotesRepository（内存实现，用于测试）

// Dart imports:
import 'dart:convert';

// Flutter imports:
import 'package:flutter/foundation.dart';

// Package imports:
import 'package:core/core.dart';

/// 笔记存储抽象接口。
///
/// 所有方法签名与 [NotesDatabase] 公开方法一一对应。
/// 继承 ChangeNotifier 以便 Provider 监听变化。
abstract class NotesRepository extends ChangeNotifier {
  // ── Core CRUD ──

  Future<SafeNote> storeNote(SafeNote note);
  Future<int> storeNotesInTransaction(List<SafeNote> notes);
  Future<SafeNote> readNote(int id);
  Future<SafeNote?> readNoteByUuid(String uuid);
  Future<SafeNote?> readNoteByContentHash(String contentHash);
  Future<List<SafeNote>> readAllNotes();
  Future<List<SafeNote>> readDeletedNotes();
  Future<List<SafeNote>> readUnsyncedNotes();
  Future<List<SafeNote>> readAllNotesIncludingDeleted();
  Future<int> updateNote(SafeNote note);
  Future<int> updateNoteByUuid(SafeNote note);
  Future<int> softDelete(int id);
  Future<int> hardDelete(int id);
  Future<int> hardDeleteByUuid(String uuid);
  Future<int> hardDeleteAllDeleted();
  Future<int> restoreNote(int id);

  // ── Encryption ──

  void setDataKey(Uint8List key);
  void clearDataKey();
  bool get isEncryptionEnabled;
  Uint8List get dataKeyForTesting;

  // ── Sync helpers ──

  Future<bool> existsContentHash(String contentHash);
  Future<void> markSynced(String uuid);
  Future<void> markAllSynced();
  Future<void> markAllSyncedExcept(Set<String> exclude);
  Future<void> markSyncedForUuids(Set<String> uuids);

  // ── Meta ──

  Future<String?> getMeta(String key);
  Future<void> setMeta(String key, String value);
  Future<int> getManifestVersion(String providerKey);
  Future<void> setManifestVersion(String providerKey, int version);

  // ── Purge ──

  Future<List<String>> getPurgedUuids();
  Future<void> removePurgedUuids(List<String> uuids);

  // ── Maintenance ──

  Future<String> exportAll();
  Future<void> close();
  Future<String> dbFilePath();
  Future<void> deleteDbFile();
  Future<Map<String, dynamic>> inspectMetadata();

  // ── Migration ──

  Future<int> reEncryptAllNotes({
    required String oldPassword,
    required String newPassword,
  });
  bool get isMigrating;

  // ── Blob reupload ──

  Future<void> markAllForBlobReupload();
  Future<Set<String>> getPendingReuploadUuids();
  Future<void> clearAllPendingReupload();
  Future<void> removePendingReuploadUuids(Set<String> uploadedOk);

  // ── GC orphan ──

  Future<Map<String, int>> getGcOrphanCandidates();
  Future<void> setGcOrphanCandidates(Map<String, int> candidates);
}

/// 真实实现：委托给 [NotesDatabase.instance]。
class NotesDatabaseRepository extends NotesRepository {
  @override
  Future<SafeNote> storeNote(SafeNote note) =>
      NotesDatabase.instance.storeNote(note);

  @override
  Future<int> storeNotesInTransaction(List<SafeNote> notes) =>
      NotesDatabase.instance.storeNotesInTransaction(notes);

  @override
  Future<SafeNote> readNote(int id) => NotesDatabase.instance.readNote(id);

  @override
  Future<SafeNote?> readNoteByUuid(String uuid) =>
      NotesDatabase.instance.readNoteByUuid(uuid);

  @override
  Future<SafeNote?> readNoteByContentHash(String contentHash) =>
      NotesDatabase.instance.readNoteByContentHash(contentHash);

  @override
  Future<List<SafeNote>> readAllNotes() =>
      NotesDatabase.instance.readAllNotes();

  @override
  Future<List<SafeNote>> readDeletedNotes() =>
      NotesDatabase.instance.readDeletedNotes();

  @override
  Future<List<SafeNote>> readUnsyncedNotes() =>
      NotesDatabase.instance.readUnsyncedNotes();

  @override
  Future<List<SafeNote>> readAllNotesIncludingDeleted() =>
      NotesDatabase.instance.readAllNotesIncludingDeleted();

  @override
  Future<int> updateNote(SafeNote note) =>
      NotesDatabase.instance.updateNote(note);

  @override
  Future<int> updateNoteByUuid(SafeNote note) =>
      NotesDatabase.instance.updateNoteByUuid(note);

  @override
  Future<int> softDelete(int id) => NotesDatabase.instance.softDelete(id);

  @override
  Future<int> hardDelete(int id) => NotesDatabase.instance.hardDelete(id);

  @override
  Future<int> hardDeleteByUuid(String uuid) =>
      NotesDatabase.instance.hardDeleteByUuid(uuid);

  @override
  Future<int> hardDeleteAllDeleted() =>
      NotesDatabase.instance.hardDeleteAllDeleted();

  @override
  Future<int> restoreNote(int id) => NotesDatabase.instance.restoreNote(id);

  @override
  void setDataKey(Uint8List key) => NotesDatabase.instance.setDataKey(key);

  @override
  void clearDataKey() => NotesDatabase.instance.clearDataKey();

  @override
  bool get isEncryptionEnabled => NotesDatabase.instance.isEncryptionEnabled;

  @override
  // ignore: invalid_use_of_visible_for_testing_member
  Uint8List get dataKeyForTesting => NotesDatabase.instance.dataKeyForTesting;

  @override
  Future<bool> existsContentHash(String contentHash) =>
      NotesDatabase.instance.existsContentHash(contentHash);

  @override
  Future<void> markSynced(String uuid) =>
      NotesDatabase.instance.markSynced(uuid);

  @override
  Future<void> markAllSynced() => NotesDatabase.instance.markAllSynced();

  @override
  Future<void> markAllSyncedExcept(Set<String> exclude) =>
      NotesDatabase.instance.markAllSyncedExcept(exclude);

  @override
  Future<void> markSyncedForUuids(Set<String> uuids) =>
      NotesDatabase.instance.markSyncedForUuids(uuids);

  @override
  Future<String?> getMeta(String key) => NotesDatabase.instance.getMeta(key);

  @override
  Future<void> setMeta(String key, String value) =>
      NotesDatabase.instance.setMeta(key, value);

  @override
  Future<int> getManifestVersion(String providerKey) =>
      NotesDatabase.instance.getManifestVersion(providerKey);

  @override
  Future<void> setManifestVersion(String providerKey, int version) =>
      NotesDatabase.instance.setManifestVersion(providerKey, version);

  @override
  Future<List<String>> getPurgedUuids() =>
      NotesDatabase.instance.getPurgedUuids();

  @override
  Future<void> removePurgedUuids(List<String> uuids) =>
      NotesDatabase.instance.removePurgedUuids(uuids);

  @override
  Future<String> exportAll() => NotesDatabase.instance.exportAll();

  @override
  Future<void> close() => NotesDatabase.instance.close();

  @override
  Future<String> dbFilePath() => NotesDatabase.instance.dbFilePath();

  @override
  Future<void> deleteDbFile() => NotesDatabase.instance.deleteDbFile();

  @override
  Future<Map<String, dynamic>> inspectMetadata() =>
      NotesDatabase.instance.inspectMetadata();

  @override
  Future<int> reEncryptAllNotes({
    required String oldPassword,
    required String newPassword,
  }) =>
      NotesDatabase.instance.reEncryptAllNotes(
        oldKey: Uint8List.fromList(utf8.encode(oldPassword)),
        newKey: Uint8List.fromList(utf8.encode(newPassword)),
      );

  @override
  bool get isMigrating => NotesDatabase.instance.isMigrating;

  @override
  Future<void> markAllForBlobReupload() =>
      NotesDatabase.instance.markAllForBlobReupload();

  @override
  Future<Set<String>> getPendingReuploadUuids() =>
      NotesDatabase.instance.getPendingReuploadUuids();

  @override
  Future<void> clearAllPendingReupload() =>
      NotesDatabase.instance.clearAllPendingReupload();

  @override
  Future<void> removePendingReuploadUuids(Set<String> uploadedOk) =>
      NotesDatabase.instance.removePendingReuploadUuids(uploadedOk);

  @override
  Future<Map<String, int>> getGcOrphanCandidates() =>
      NotesDatabase.instance.getGcOrphanCandidates();

  @override
  Future<void> setGcOrphanCandidates(Map<String, int> candidates) =>
      NotesDatabase.instance.setGcOrphanCandidates(candidates);
}

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