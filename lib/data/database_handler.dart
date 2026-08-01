/*
 * 数据库处理器
 *
 * 改造说明（fork 同步版）：
 *   - schema version 3，新表结构（uuid / content_hash / deleted / updated_at / synced / synced_hash）
 *   - 本地用 dataKey 加密存储（title/description 字段级 AES-256-GCM 加密）
 *   - 软删除（deleted=1 为墓碑，不真正删除行）
 *   - 新增 sync_meta 表（vault_id / manifest_version 等）
 *   - 不迁移旧数据：schema 升级一律视为全新安装（旧库无法打开）
 *
 * 本地加密说明（B1 方案）：
 *   - dataKey 在首次设置密码时生成，存于 Keyring，登录时注入到 NotesDatabase
 *   - title/description 写入前用 SyncCrypto.seal(dataKey, uuid, plaintext) 加密
 *   - 读取时用 SyncCrypto.open(dataKey, uuid, envelope) 解密
 *   - contentHash 为明文 hash，不加密（用于同步比对）
 *   - dataKey 为必填项：未设置时读写笔记会抛 DataKeyNotSetException
 *     （测试中也必须通过 setDataKey 设置，保证测试与生产逻辑一致）
 */

// Dart 导入
import 'dart:convert';
import 'dart:typed_data';

// Package 导入
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

// Project 导入
import 'package:safenotes/models/safenote.dart';
import 'package:safenotes/sync/crypto.dart';
import 'package:safenotes/utils/app_logger.dart';

const String tableMeta = 'sync_meta';

/// 隐私红线：日志中**绝不允许**出现笔记标题 / 正文明文。
///
/// SafeNotes 是隐私优先的加密笔记应用，日志文件与日志 Web 服务器都可能被
/// 第三方看到。因此所有笔记相关日志只记录**非敏感元数据**：
///   uuid、内容长度、contentHash 前缀、时间戳、影响行数。
/// 需要新增笔记相关日志时，务必遵守此约定。
String _hashBrief(String? hash) =>
    (hash != null && hash.length >= 8) ? '${hash.substring(0, 8)}…' : '-';

/// dataKey 未设置异常
///
/// 在未调用 setDataKey 前读写笔记会抛此异常。
/// 生产环境由登录流程保证 dataKey 已设置；测试环境需在 setUp 中显式设置。
class DataKeyNotSetException implements Exception {
  final String message;
  DataKeyNotSetException([
    this.message = 'dataKey 未设置：请先通过 setDataKey 注入 dataKey',
  ]);

  @override
  String toString() => 'DataKeyNotSetException: $message';
}

/// 迁移进行中异常
///
/// F4 修复：reEncryptAllNotes 期间 _dataKey 被临时切换，
/// 此时 UI 并发读取笔记会用错误的 key 解密导致抛 DataKeyNotSetException。
/// 迁移期间所有公共读方法抛此异常，UI 可捕获并显示遮罩或等待重试。
///
/// 迁移通常在同步流程内（持有 _syncInProgress 互斥锁），
/// 但 UI 的 readAllNotes 等读操作不经过同步锁，需此标志额外保护。
class MigrationInProgressException implements Exception {
  final String message;
  MigrationInProgressException([
    this.message = '数据迁移进行中，请稍候',
  ]);

  @override
  String toString() => 'MigrationInProgressException: $message';
}

class MetaFields {
  static const String key = 'key';
  static const String value = 'value';
}

// meta 表的已知键名
class MetaKeys {
  /// P2 Keyring 账本单键（唯一权威密钥态，JSON）
  static const String keyring = 'keyring';

  static const String purgedUuids = 'purged_uuids'; // M1: 待清理墓碑列表
  // Layer 2a: dataKey 变更后需强制重传 blob 的笔记 uuid 列表（JSON 数组）
  static const String blobReuploadPending = 'blob_reupload_pending';
}

class NotesDatabase {
  static final NotesDatabase instance = NotesDatabase._init();

  static Database? _database;

  /// 当前会话的 dataKey（登录时注入，登出时清除）
  ///
  /// 必填项：未设置时读写笔记会抛 DataKeyNotSetException。
  /// 生产环境由登录流程保证已设置；测试环境需在 setUp 中显式设置。
  Uint8List? _dataKey;

  /// F4 修复：迁移进行中标志
  ///
  /// reEncryptAllNotes 期间置为 true，阻止 UI 并发读取笔记。
  ///迁移在同步流程内（_syncInProgress 互斥锁），但 UI 读操作不经过同步锁。
  bool _isMigrating = false;

  /// 迁移是否进行中（UI 可监听此状态显示遮罩）
  bool get isMigrating => _isMigrating;

  NotesDatabase._init();

  /// 设置 dataKey（登录/解锁 keyring 后调用）
  void setDataKey(Uint8List key) => _dataKey = Uint8List.fromList(key);

  /// 清除 dataKey（登出时调用）
  void clearDataKey() => _dataKey = null;

  /// dataKey 是否已设置
  bool get isEncryptionEnabled => _dataKey != null;

  /// 获取当前 dataKey 的副本（仅供测试用，生产环境通过 _requireDataKey 内部访问）
  ///
  /// 用于测试中 SyncEngine 与 NotesDatabase 共享同一个 dataKey。
  @visibleForTesting
  Uint8List get dataKeyForTesting {
    final key = _dataKey;
    if (key == null) {
      throw DataKeyNotSetException('dataKey 未设置，无法获取（测试用 getter）');
    }
    return Uint8List.fromList(key);
  }

  /// 获取 dataKey（未设置时抛异常）
  Uint8List get _requireDataKey {
    final key = _dataKey;
    if (key == null) {
      throw DataKeyNotSetException();
    }
    return key;
  }

  /// F4 修复：迁移进行中守卫
  ///
  /// reEncryptAllNotes 期间 _dataKey 被临时切换，UI 并发读取会用错误 key 解密。
  /// 面向 UI 的公共读方法（readNote/readNoteByUuid/readAllNotes/readDeletedNotes）
  /// 调用此守卫，迁移中抛 MigrationInProgressException。
  ///
  /// readAllNotesIncludingDeleted 不加守卫——它被同步引擎内部调用，
  /// 且 reEncryptAllNotes 自身需要调用它读取明文。
  void _checkNotMigrating() {
    if (_isMigrating) {
      throw MigrationInProgressException();
    }
  }

  Future<Database> get database async {
    final db = _database;
    if (db != null) return db;

    final newDb = await _initDB('safenotes_sync.db');
    _database = newDb;
    return newDb;
  }

  // ──────────────────────────────────────────────
  // 字段级加密/解密辅助
  // ──────────────────────────────────────────────

  /// 加密单个字段值，返回 base64 字符串
  ///
  /// [uuid] 作为 AAD 绑定（防止信封从一条笔记移到另一条）
  /// [plaintext] 明文文本
  /// 返回 base64(nonce + ciphertext + tag)
  String _encryptField(String uuid, String plaintext) {
    if (plaintext.isEmpty) return plaintext;
    final dataKey = _requireDataKey;
    final bytes = Uint8List.fromList(utf8.encode(plaintext));
    final envelope = SyncCrypto.seal(dataKey, uuid, bytes);
    return base64.encode(envelope);
  }

  /// 解密单个字段值
  ///
  /// [uuid] 必须与加密时一致
  /// [fieldValue] base64 编码的信封
  /// 返回明文文本
  String _decryptField(String uuid, String fieldValue) {
    if (fieldValue.isEmpty) return fieldValue;
    final dataKey = _requireDataKey;
    try {
      final envelope = base64.decode(fieldValue);
      final bytes = SyncCrypto.open(dataKey, uuid, envelope);
      return utf8.decode(bytes);
    } catch (e) {
      // 解密失败：dataKey 不匹配或数据损坏
      // 抛异常而不是返回原始值，避免静默错误
      throw DataKeyNotSetException(
        '解密失败：dataKey 不匹配或数据损坏 - $e',
      );
    }
  }

  /// 将明文 SafeNote 转为加密的数据库行（用于 insert/update）
  Map<String, dynamic> _toEncryptedRow(SafeNote note) {
    final json = note.toJson();
    json[NoteFields.title] = _encryptField(note.uuid, note.title);
    json[NoteFields.description] = _encryptField(note.uuid, note.description);
    return json;
  }

  /// 从加密的数据库行构造明文 SafeNote（用于 query 结果）
  SafeNote _fromEncryptedRow(Map<String, dynamic> json) {
    final uuid = json[NoteFields.uuid] as String? ?? '';
    final encryptedTitle = json[NoteFields.title] as String? ?? '';
    final encryptedDesc = json[NoteFields.description] as String? ?? '';
    final decrypted = Map<String, dynamic>.from(json);
    decrypted[NoteFields.title] = _decryptField(uuid, encryptedTitle);
    decrypted[NoteFields.description] = _decryptField(uuid, encryptedDesc);
    return SafeNote.fromJson(decrypted);
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    try {
      final db = await openDatabase(
        path,
        version: 3,
        onCreate: _createDB,
      );
      Log.db.i('数据库已打开: $path (version=3)');
      return db;
    } on Object catch (e, st) {
      Log.db.f('数据库打开失败: $path', error: e, stackTrace: st);
      rethrow;
    }
  }

  /// 测试专用：注入 in-memory 数据库
  ///
  /// 用法（配合 sqflite_common_ffi）：
  /// ```dart
  /// setUp(() async {
  ///   sqfliteFfiInit();
  ///   databaseFactory = databaseFactoryFfi;
  ///   final db = await openDatabase(':memory:', version: 2, onCreate: NotesDatabase.createDBForTesting);
  ///   NotesDatabase.setDatabaseForTesting(db);
  /// });
  /// ```
  @visibleForTesting
  static void setDatabaseForTesting(Database db) {
    _database = db;
  }

  /// 测试专用：createDB 回调（供 in-memory 数据库 onCreate 使用）
  @visibleForTesting
  static Future<void> createDBForTesting(Database db, int version) async {
    await _createDBStatic(db, version);
  }

  /// createDB 的静态实现（测试用）
  static Future<void> _createDBStatic(Database db, int version) async {
    await db.execute('''
    CREATE TABLE $tableNotes (
      ${NoteFields.id} INTEGER PRIMARY KEY AUTOINCREMENT,
      ${NoteFields.uuid} TEXT NOT NULL UNIQUE,
      ${NoteFields.title} TEXT NOT NULL,
      ${NoteFields.description} TEXT NOT NULL,
      ${NoteFields.contentHash} TEXT NOT NULL,
      ${NoteFields.deleted} INTEGER NOT NULL DEFAULT 0,
      ${NoteFields.createdAt} TEXT NOT NULL,
      ${NoteFields.updatedAt} INTEGER NOT NULL,
      ${NoteFields.synced} INTEGER NOT NULL DEFAULT 0,
      ${NoteFields.syncedHash} TEXT
    )
    ''');

    await db.execute('''
    CREATE TABLE $tableMeta (
      ${MetaFields.key} TEXT PRIMARY KEY,
      ${MetaFields.value} TEXT NOT NULL
    )
    ''');

    await db.execute(
        'CREATE INDEX idx_notes_uuid ON $tableNotes(${NoteFields.uuid})');
    await db.execute(
        'CREATE INDEX idx_notes_deleted ON $tableNotes(${NoteFields.deleted})');
    await db.execute(
        'CREATE INDEX idx_notes_synced ON $tableNotes(${NoteFields.synced})');
  }

  /// 创建新数据库（version 3 schema）
  Future<void> _createDB(Database db, int version) async {
    await db.execute('''
    CREATE TABLE $tableNotes (
      ${NoteFields.id} INTEGER PRIMARY KEY AUTOINCREMENT,
      ${NoteFields.uuid} TEXT NOT NULL UNIQUE,
      ${NoteFields.title} TEXT NOT NULL,
      ${NoteFields.description} TEXT NOT NULL,
      ${NoteFields.contentHash} TEXT NOT NULL,
      ${NoteFields.deleted} INTEGER NOT NULL DEFAULT 0,
      ${NoteFields.createdAt} TEXT NOT NULL,
      ${NoteFields.updatedAt} INTEGER NOT NULL,
      ${NoteFields.synced} INTEGER NOT NULL DEFAULT 0,
      ${NoteFields.syncedHash} TEXT
    )
    ''');

    await db.execute('''
    CREATE TABLE $tableMeta (
      ${MetaFields.key} TEXT PRIMARY KEY,
      ${MetaFields.value} TEXT NOT NULL
    )
    ''');

    // 索引：按 uuid 快速查找（同步用）
    await db.execute(
        'CREATE INDEX idx_notes_uuid ON $tableNotes(${NoteFields.uuid})');
    // 索引：按 deleted 过滤（最近删除视图用）
    await db.execute(
        'CREATE INDEX idx_notes_deleted ON $tableNotes(${NoteFields.deleted})');
    // 索引：按 synced 过滤（同步用，找未同步的笔记）
    await db.execute(
        'CREATE INDEX idx_notes_synced ON $tableNotes(${NoteFields.synced})');
  }

  // ──────────────────────────────────────────────
  // 笔记 CRUD（自动加解密 title/description）
  // ──────────────────────────────────────────────

  /// 新增笔记（title/description 加密后存储）
  Future<SafeNote> storeNote(SafeNote note) async {
    _checkNotMigrating();
    final db = await instance.database;
    try {
      final id = await db.insert(tableNotes, _toEncryptedRow(note));
      // 只记录元数据，不记录标题 / 正文（见文件顶部隐私红线说明）
      Log.note.i('新增笔记 uuid=${note.uuid} id=$id '
          'hash=${_hashBrief(note.contentHash)} '
          'len=${note.title.length}+${note.description.length}');
      return note.copyWith(id: id);
    } on Object catch (e, st) {
      Log.note.e('新增笔记失败 uuid=${note.uuid}', error: e, stackTrace: st);
      rethrow;
    }
  }

  /// 按 id 读取单条笔记（自动解密）
  Future<SafeNote> readNote(int id) async {
    _checkNotMigrating();
    final db = await instance.database;
    final maps = await db.query(
      tableNotes,
      columns: NoteFields.values,
      where: '${NoteFields.id} = ?',
      whereArgs: [id],
    );

    if (maps.isNotEmpty) {
      return _fromEncryptedRow(maps.first);
    } else {
      throw Exception('ID $id not found');
    }
  }

  /// 按 uuid 读取单条笔记（同步用，自动解密）
  Future<SafeNote?> readNoteByUuid(String uuid) async {
    _checkNotMigrating();
    final db = await instance.database;
    final maps = await db.query(
      tableNotes,
      columns: NoteFields.values,
      where: '${NoteFields.uuid} = ?',
      whereArgs: [uuid],
      limit: 1,
    );
    if (maps.isNotEmpty) {
      return _fromEncryptedRow(maps.first);
    }
    return null;
  }

  /// 按内容 hash 读取一条未删除的笔记（同步去重自愈用，自动解密）
  ///
  /// 场景：blob 按内容 hash 寻址去重，两条内容相同的笔记共享同一 blob。
  /// 当某个 uuid 的 blob 解不开、且本机没有该 uuid 的明文时，
  /// 若本机存在内容相同（content_hash 相同）的"孪生笔记"，
  /// 可用孪生明文物化该 uuid 并重传修复 blob。
  Future<SafeNote?> readNoteByContentHash(String contentHash) async {
    _checkNotMigrating();
    final db = await instance.database;
    final maps = await db.query(
      tableNotes,
      columns: NoteFields.values,
      where: '${NoteFields.contentHash} = ? AND ${NoteFields.deleted} = 0',
      whereArgs: [contentHash],
      limit: 1,
    );
    if (maps.isNotEmpty) {
      return _fromEncryptedRow(maps.first);
    }
    return null;
  }

  /// 判断本机是否已存在指定 content_hash 的笔记（**含墓碑**）
  ///
  /// 用途：生成冲突副本标题时探测 hash 碰撞。
  /// 必须把墓碑一并计入——若副本与某条已删除笔记同 hash，它会重新被
  /// 孪生匹配与冲突判定卷入，等于把删除又拉回增殖循环。
  Future<bool> existsContentHash(String contentHash) async {
    _checkNotMigrating();
    final db = await instance.database;
    final maps = await db.query(
      tableNotes,
      columns: [NoteFields.id],
      where: '${NoteFields.contentHash} = ?',
      whereArgs: [contentHash],
      limit: 1,
    );
    return maps.isNotEmpty;
  }

  /// 读取所有未删除的笔记（UI 列表用，自动解密）
  Future<List<SafeNote>> readAllNotes() async {
    _checkNotMigrating();
    final db = await instance.database;
    final result = await db.query(
      tableNotes,
      columns: NoteFields.values,
      where: '${NoteFields.deleted} = 0',
      orderBy: '${NoteFields.createdAt} ASC',
    );
    return result.map((json) => _fromEncryptedRow(json)).toList();
  }

  /// 读取所有已删除的笔记（最近删除视图用，自动解密）
  Future<List<SafeNote>> readDeletedNotes() async {
    _checkNotMigrating();
    final db = await instance.database;
    final result = await db.query(
      tableNotes,
      columns: NoteFields.values,
      where: '${NoteFields.deleted} = 1',
      orderBy: '${NoteFields.updatedAt} DESC',
    );
    return result.map((json) => _fromEncryptedRow(json)).toList();
  }

  /// 读取所有未同步的笔记（同步引擎用，自动解密）
  Future<List<SafeNote>> readUnsyncedNotes() async {
    final db = await instance.database;
    final result = await db.query(
      tableNotes,
      columns: NoteFields.values,
      where: '${NoteFields.synced} = 0',
    );
    return result.map((json) => _fromEncryptedRow(json)).toList();
  }

  /// 读取所有笔记（含墓碑，同步引擎全量对账用，自动解密）
  Future<List<SafeNote>> readAllNotesIncludingDeleted() async {
    final db = await instance.database;
    final result = await db.query(tableNotes, columns: NoteFields.values);
    return result.map((json) => _fromEncryptedRow(json)).toList();
  }

  /// 更新笔记（title/description 加密后存储）
  Future<int> updateNote(SafeNote note) async {
    _checkNotMigrating();
    final db = await instance.database;
    try {
      final rows = await db.update(
        tableNotes,
        _toEncryptedRow(note),
        where: '${NoteFields.id} = ?',
        whereArgs: [note.id],
      );
      Log.note.i('修改笔记 uuid=${note.uuid} id=${note.id} '
          'hash=${_hashBrief(note.contentHash)} '
          'len=${note.title.length}+${note.description.length} rows=$rows');
      return rows;
    } on Object catch (e, st) {
      Log.note.e('修改笔记失败 uuid=${note.uuid} id=${note.id}',
          error: e, stackTrace: st);
      rethrow;
    }
  }

  /// 按 uuid 更新笔记（同步拉取时用，title/description 加密后存储）
  Future<int> updateNoteByUuid(SafeNote note) async {
    _checkNotMigrating();
    final db = await instance.database;
    try {
      final rows = await db.update(
        tableNotes,
        _toEncryptedRow(note),
        where: '${NoteFields.uuid} = ?',
        whereArgs: [note.uuid],
      );
      Log.note.i('按 uuid 更新笔记 uuid=${note.uuid} '
          'hash=${_hashBrief(note.contentHash)} '
          'deleted=${note.deleted} rows=$rows');
      return rows;
    } on Object catch (e, st) {
      Log.note.e('按 uuid 更新笔记失败 uuid=${note.uuid}',
          error: e, stackTrace: st);
      rethrow;
    }
  }

  /// 软删除笔记（标记为墓碑，不真正删除行）
  Future<int> softDelete(int id) async {
    final db = await instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    try {
      final rows = await db.update(
        tableNotes,
        {
          NoteFields.deleted: 1,
          NoteFields.updatedAt: now,
          NoteFields.synced: 0,
        },
        where: '${NoteFields.id} = ?',
        whereArgs: [id],
      );
      Log.note.i('删除笔记（软删除，移入回收站）id=$id rows=$rows');
      return rows;
    } on Object catch (e, st) {
      Log.note.e('软删除笔记失败 id=$id', error: e, stackTrace: st);
      rethrow;
    }
  }

  /// 彻底删除笔记（从数据库移除，最近删除视图的"永久删除"用）
  ///
  /// M1 修复：硬删除时把 uuid 加入 meta 表的"待清理墓碑"列表，
  /// 下次同步时 SyncEngine 会从远端 manifest 中移除这些 uuid。
  /// 这样硬删除的笔记不会在下次同步时从远端复活。
  ///
  /// 流程：
  ///   1. 读取笔记 uuid
  ///   2. 从 notes 表删除行
  ///   3. 把 uuid 追加到 meta 表的 'purged_uuids' 列表
  ///   4. SyncEngine 同步后清理已上传的 uuid
  Future<int> hardDelete(int id) async {
    final db = await instance.database;

    // 1. 读取 uuid
    final maps = await db.query(
      tableNotes,
      columns: [NoteFields.uuid],
      where: '${NoteFields.id} = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (maps.isEmpty) {
      Log.note.w('永久删除笔记：id=$id 不存在，忽略');
      return 0;
    }
    final uuid = maps.first[NoteFields.uuid] as String;

    // 2. 删除行
    final deleted = await db.delete(
      tableNotes,
      where: '${NoteFields.id} = ?',
      whereArgs: [id],
    );

    // 3. 追加到待清理列表
    await _addPurgedUuid(uuid);

    // 不可恢复的破坏性操作，必须留痕
    Log.note.i('永久删除笔记（不可恢复）uuid=$uuid id=$id rows=$deleted，'
        '已加入 purged 列表待同步清理');
    return deleted;
  }

  /// F1 修复：按 uuid 硬删除笔记（GC 墓碑清理用）
  ///
  /// 与 [hardDelete] 的区别：按 uuid 而非 id 删除，用于 GC 清理过期墓碑。
  /// 流程：从 notes 表删除行 → 把 uuid 追加到 purged_uuids 列表。
  /// 不存在时返回 0（幂等）。
  Future<int> hardDeleteByUuid(String uuid) async {
    final db = await instance.database;
    final deleted = await db.delete(
      tableNotes,
      where: '${NoteFields.uuid} = ?',
      whereArgs: [uuid],
    );
    if (deleted > 0) {
      await _addPurgedUuid(uuid);
      Log.note.i('永久删除笔记（GC 墓碑清理）uuid=$uuid rows=$deleted');
    }
    return deleted;
  }

  /// 添加待清理的 uuid 到 meta 表
  Future<void> _addPurgedUuid(String uuid) async {
    final existing = await getMeta(MetaKeys.purgedUuids);
    final list = _parseUuidList(existing);
    if (!list.contains(uuid)) {
      list.add(uuid);
      await setMeta(MetaKeys.purgedUuids, _serializeUuidList(list));
    }
  }

  /// 读取待清理的 uuid 列表（SyncEngine 同步时调用）
  Future<List<String>> getPurgedUuids() async {
    final value = await getMeta(MetaKeys.purgedUuids);
    return _parseUuidList(value);
  }

  /// 从待清理列表中移除指定 uuid（SyncEngine 同步成功后调用）
  Future<void> removePurgedUuids(List<String> uuids) async {
    if (uuids.isEmpty) return;
    final existing = await getMeta(MetaKeys.purgedUuids);
    final list = _parseUuidList(existing);
    list.removeWhere((uuid) => uuids.contains(uuid));
    await setMeta(MetaKeys.purgedUuids, _serializeUuidList(list));
  }

  /// 解析 JSON 格式的 uuid 列表
  static List<String> _parseUuidList(String? value) {
    if (value == null || value.isEmpty) return [];
    try {
      final decoded = json.decode(value);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toList();
      }
    } on Exception {
      // 解析失败返回空列表
    }
    return [];
  }

  /// 序列化 uuid 列表为 JSON 字符串
  static String _serializeUuidList(List<String> uuids) {
    return json.encode(uuids);
  }

  /// 恢复软删除的笔记（撤回墓碑标记）
  ///
  /// 用于"最近删除"视图的"恢复"操作：
  ///   - deleted 改回 0
  ///   - updatedAt 设为当前时间（触发同步：本地新版本，远端会被覆盖）
  ///   - synced 设为 0（标记为待同步）
  Future<int> restoreNote(int id) async {
    final db = await instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    try {
      final rows = await db.update(
        tableNotes,
        {
          NoteFields.deleted: 0,
          NoteFields.updatedAt: now,
          NoteFields.synced: 0,
        },
        where: '${NoteFields.id} = ?',
        whereArgs: [id],
      );
      Log.note.i('恢复笔记（撤回删除）id=$id rows=$rows');
      return rows;
    } on Object catch (e, st) {
      Log.note.e('恢复笔记失败 id=$id', error: e, stackTrace: st);
      rethrow;
    }
  }

  /// 重新加密所有笔记（dataKey 迁移时调用）
  ///
  /// 场景：本地 dataKey 与远端不一致，需要用新 dataKey 重新加密所有笔记。
  /// 这是多端 join 的核心操作，必须保证 crash 安全：
  ///
  /// Crash 安全策略：
  ///   1. 在 SQLite 事务中执行（atomic）：要么全部成功，要么全部回滚
  ///   2. 内存中先用 oldKey 解密所有笔记 → 用 newKey 重新加密
  ///      （不直接修改数据库，避免半加密状态）
  ///   3. 全部加密完成后，在事务中一次性写入所有新密文
  ///   4. 最后才更新 database 的 _dataKey 为 newKey
  ///
  /// 如果在步骤 2 crash：数据库仍为旧密文，_dataKey 仍为 oldKey，状态一致。
  /// 如果在步骤 3 crash：SQLite 事务回滚，数据库仍为旧密文。
  /// 如果在步骤 4 crash：数据库已更新为新密文，但 _dataKey 还是 oldKey，
  ///   下次登录时 Keyring.unlockLocal 会用密码重新派生 dataKey，状态恢复一致。
  ///
  /// [oldKey] 旧的 dataKey（用于解密当前数据库内容）
  /// [newKey] 新的 dataKey（用于重新加密）
  /// 返回重新加密的笔记数量
  Future<int> reEncryptAllNotes({
    required Uint8List oldKey,
    required Uint8List newKey,
  }) async {
    final db = await instance.database;

    // F4 修复：设置迁移中标志，阻止 UI 并发读取笔记
    // 迁移期间 _dataKey 被临时切换，UI 读取会用错误 key 解密
    _isMigrating = true;
    // 全库重加密是最高风险的数据变更，起止与结果都必须留痕
    Log.db.w('开始全库重加密（dataKey 迁移），期间禁止 UI 读取笔记');
    final startedAt = DateTime.now();

    // 1. 临时切换 dataKey 为 oldKey 读取所有笔记（自动解密为明文）
    //    保存当前 _dataKey 以便失败时恢复
    final originalDataKey = _dataKey;
    _dataKey = Uint8List.fromList(oldKey);

    try {
      // 2. 读取所有笔记（含墓碑），此时返回的是明文 SafeNote 对象
      final notes = await readAllNotesIncludingDeleted();

      // 3. 临时切换 dataKey 为 newKey，准备加密
      _dataKey = Uint8List.fromList(newKey);

      // 4. 在内存中用 newKey 重新加密所有笔记
      //    不直接修改数据库，先收集所有要写入的行
      final encryptedRows = <Map<String, dynamic>>[];
      for (final note in notes) {
        final row = _toEncryptedRow(note);
        // 保留 id 和 uuid 用于 UPDATE WHERE 条件
        encryptedRows.add({
          'where_uuid': note.uuid,
          'row': row,
        });
      }

      // 5. 在事务中一次性写入所有新密文（atomic）
      await db.transaction((txn) async {
        for (final entry in encryptedRows) {
          final uuid = entry['where_uuid'] as String;
          final row = entry['row'] as Map<String, dynamic>;
          await txn.update(
            tableNotes,
            row,
            where: '${NoteFields.uuid} = ?',
            whereArgs: [uuid],
          );
        }
      });

      // 6. 成功后更新 _dataKey 为 newKey（后续读写用新 key）
      _dataKey = Uint8List.fromList(newKey);

      final ms = DateTime.now().difference(startedAt).inMilliseconds;
      Log.db.i('全库重加密完成: ${notes.length} 条笔记, 耗时 ${ms}ms');
      return notes.length;
    } catch (e, st) {
      // 失败时恢复 _dataKey 为原始值（可能是 oldKey 或 originalDataKey）
      _dataKey = originalDataKey;
      Log.db.f('全库重加密失败，已回滚事务并恢复原 dataKey',
          error: e, stackTrace: st);
      rethrow;
    } finally {
      // F4 修复：无论成功或失败，清除迁移中标志
      _isMigrating = false;
    }
  }

  /// 标记笔记为已同步
  ///
  /// 同步收敛时，把 synced_hash 更新为当前 content_hash——这一刻本地与远端
  /// 已一致，当前内容 hash 即成为下一轮冲突判定的共同祖先 base。
  Future<void> markSynced(String uuid) async {
    final db = await instance.database;
    await db.rawUpdate(
      'UPDATE $tableNotes SET ${NoteFields.synced} = 1, '
      '${NoteFields.syncedHash} = ${NoteFields.contentHash} '
      'WHERE ${NoteFields.uuid} = ?',
      [uuid],
    );
  }

  /// 标记所有笔记为已同步（全量同步完成后用）
  ///
  /// 同时把每条笔记的 synced_hash 刷新为其 content_hash：同步流程结束时本地库
  /// 已是收敛后的最终状态，此刻记下的 hash 就是下一轮判定单边/并发的 base。
  Future<void> markAllSynced() async {
    final db = await instance.database;
    await db.rawUpdate(
      'UPDATE $tableNotes SET ${NoteFields.synced} = 1, '
      '${NoteFields.syncedHash} = ${NoteFields.contentHash}',
    );
  }

  // ──────────────────────────────────────────────
  // Layer 2a: dataKey 变更后强制重传 blob
  // ──────────────────────────────────────────────────
  //
  // 背景：migrateToRemote / migrateToRemoteVault 重加密本地笔记后，本地 DB 已用新
  // dataKey，但服务器上的 blob 可能仍是旧 dataKey 加密（密钥分歧残留）。由于 manifest
  // hash 与密钥无关，合并时会判定"无变化"而不重传，导致坏 blob 永久残留。
  //
  // 解决：密钥变更时把所有本地笔记标记为"需重传 blob"，_mergeAndTransfer 对这些 uuid
  // 即使 _itemsEqual 也强制 _uploadNote，用新密钥覆盖服务器 blob。同步成功后清除标记。

  /// 标记全部未删除笔记需重传 blob（密钥变更后调用）
  Future<void> markAllForBlobReupload() async {
    final db = await instance.database;
    final maps = await db.query(
      tableNotes,
      columns: [NoteFields.uuid],
      where: '${NoteFields.deleted} = 0',
    );
    final uuids = maps.map((m) => m[NoteFields.uuid] as String).toList();
    await setMeta(MetaKeys.blobReuploadPending, jsonEncode(uuids));
  }

  /// 读取待重传 blob 的 uuid 集合（空集合表示无）
  Future<Set<String>> getPendingReuploadUuids() async {
    final raw = await getMeta(MetaKeys.blobReuploadPending);
    if (raw == null || raw.isEmpty) return {};
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list.map((e) => e as String).toSet();
    } on Exception {
      return {};
    }
  }

  /// 清除全部待重传标记（同步成功后调用）
  ///
  /// 密钥变更后的首次同步会把这些 uuid 的 blob 用新密钥重新上传，
  /// 成功后即可清除标记；剩余未在本机处理的 uuid（如本机无明文的远程独享笔记）
  /// 由其持有明文的设备自行重传，本机清除不影响。
  Future<void> clearAllPendingReupload() async {
    final db = await instance.database;
    await db.delete(
      tableMeta,
      where: '${MetaFields.key} = ?',
      whereArgs: [MetaKeys.blobReuploadPending],
    );
  }

  // ──────────────────────────────────────────────
  // sync_meta 表 CRUD
  // ──────────────────────────────────────────────

  /// 读取 meta 值
  Future<String?> getMeta(String key) async {
    final db = await instance.database;
    final maps = await db.query(
      tableMeta,
      columns: [MetaFields.value],
      where: '${MetaFields.key} = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (maps.isNotEmpty) {
      return maps.first[MetaFields.value] as String;
    }
    return null;
  }

  /// 写入 meta 值（upsert）
  Future<void> setMeta(String key, String value) async {
    final db = await instance.database;
    await db.insert(
      tableMeta,
      {MetaFields.key: key, MetaFields.value: value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 读取 manifest 版本号（按 providerKey 隔离存储）
  ///
  /// [providerKey] 后端实例的唯一标识（见 SyncBackend.providerKey）。
  /// 不同后端类型、不同 URL 的 manifest version 互不影响：
  /// 切换后端时新后端读不到旧 version（默认 0，走首次同步），
  /// 切回原后端时旧 version 仍在（继续增量同步）。
  Future<int> getManifestVersion(String providerKey) async {
    final value = await getMeta(_manifestVersionKey(providerKey));
    return value != null ? int.parse(value) : 0;
  }

  /// 写入 manifest 版本号（按 providerKey 隔离存储）
  Future<void> setManifestVersion(
    String providerKey,
    int version,
  ) async {
    await setMeta(_manifestVersionKey(providerKey), version.toString());
  }

  /// 生成 manifest version 的 meta key
  static String _manifestVersionKey(String providerKey) =>
      'manifest_version:$providerKey';

  // ──────────────────────────────────────────────
  // 导出（backup 功能）
  // ──────────────────────────────────────────────

  /// 导出所有笔记为 JSON 字符串（明文，已解密）
  ///
  /// 返回完整字段（含 uuid/contentHash 等），导入时可直接通过 SafeNote.fromJson 解析。
  /// 注意：导出内容为明文 JSON，备份加密由上层 FileHandler 负责。
  Future<String> exportAll() async {
    // 复用 readAllNotes（自动解密）
    final notes = await readAllNotes();
    final jsonList = notes.map((note) => note.toJson()).toList();
    return jsonEncode(jsonList).toString();
  }

  Future<void> close() async {
    final db = _database;
    if (db != null) {
      await db.close();
      _database = null;
    }
  }

  /// 删除 db 文件（忘记密码逃生通道使用）
  ///
  /// 必须先调用 [close] 关闭数据库连接,否则文件锁占用无法删除。
  /// 删除后 _database 置为 null,下次访问 database getter 会重新创建空 db。
  /// 同时清除 _dataKey,避免残留内存中的旧密钥。
  Future<void> deleteDbFile() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'safenotes_sync.db');
    // 不可逆的全量数据销毁（忘记密码逃生通道），必须以 FATAL 级别留痕
    Log.db.f('⚠ 删除数据库文件（所有本地笔记将永久丢失）: $path');
    try {
      await databaseFactory.deleteDatabase(path);
      Log.db.i('数据库文件已删除，内存密钥已清空');
    } on Object catch (e, st) {
      Log.db.e('删除数据库文件失败', error: e, stackTrace: st);
      rethrow;
    } finally {
      _database = null;
      _dataKey = null;
    }
  }
}
