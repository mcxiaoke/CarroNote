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

