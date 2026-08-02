/*
 * 数据库处理器
 *
 * 改造说明（fork 同步版）：
 *   - schema version 4，新表结构（uuid / content_hash / deleted / updated_at / synced / synced_hash / synced_deleted）
 *   - 本地用 dataKey 加密存储（title/description 字段级 AES-256-GCM 加密）
 *   - 软删除（deleted=1 为墓碑，不真正删除行）
 *   - 新增 sync_meta 表（vault_id / manifest_version 等）
 *   - version 3→4 走 onUpgrade（ALTER TABLE 加 synced_deleted 列，老库原地升级）
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
  // P2 修复（DS002）：孤儿 blob 两阶段 GC 的候选表（JSON 对象 hash→首次观察时间戳）。
  // 首次观察到孤儿只登记候选、不隔离；连续第二次观察仍为孤儿才隔离，
  // 从而避开「他端刚 putBlob 尚未 putManifest」的并发窗口。
  static const String gcOrphanCandidates = 'gc_orphan_candidates';
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

  /// 解密结果缓存（P1 性能优化，根因 4）。
  ///
  /// 缓存「含墓碑的全量笔记」明文列表，避免每次列表刷新 / 同步都重新
  /// 对所有笔记做 AES-GCM 解密（主线程冻结 ~2s）。
  /// 仅修改 synced 标记等不影响明文的写操作（markSynced 系列）不会失效 ——
  /// 这样同步完成后主页 [refreshNotes] 在未发生内容变更时直接命中缓存，
  /// 消除日志里反复出现的全量解密卡顿。
  ///
  /// **轻量收敛（本版）**：所有缓存维护收口到下方 4 个私有方法，任何写路径
  /// 只调其中之一，缓存语义内聚、杜绝散落式维护导致的一致性 bug。缓存是 DB 的
  /// **强一致镜像**：每条写都先落 DB、再用同一份内存对象更新缓存，因此缓存里
  /// 的 updatedAt/deleted/synced 必与 DB 一致（见 [_upsertCacheEntry] / 写路径）。
  ///
  /// **实例字段（非 static）**：避免多 DB 实例（测试里反复 setDatabaseForTesting
  /// 重建库）共享同一份缓存的隐性耦合。更换数据库连接时由 [setDatabaseForTesting]
  /// 一并清空（见 [_invalidateCache]）。
  List<SafeNote>? _notesCache;

  /// 使解密缓存整体失效（内容语义整体变化：reEncryptAllNotes* / close /
  /// logout / 新数据库连接 时调用）。
  void _invalidateCache() => _notesCache = null;

  /// 单条明文覆盖（按 uuid 插或替）。
  ///
  /// storeNote / updateNote / updateNoteByUuid（以及 softDelete/restoreNote
  /// 先取缓存旧条目 + 增量重建完整对象后）都走它。用**完整 SafeNote 对象**
  /// 覆盖，updatedAt 等字段天然随对象带入，写路径无法「漏传」某字段 ——
  /// 从结构上消灭「改 DB 忘了同步缓存」类 bug。
  void _upsertCacheEntry(SafeNote note) {
    final cache = _notesCache;
    if (cache == null) return; // 缓存未建：下次读取自然重建（已含本条）
    final idx = cache.indexWhere((n) => n.uuid == note.uuid);
    if (idx >= 0) {
      cache[idx] = note;
    } else {
      cache.add(note);
    }
  }

  /// 按 id 或 uuid 从缓存移除条目（hardDelete / hardDeleteByUuid 用）。
  void _removeCacheEntry({int? id, String? uuid}) {
    if (id != null) {
      _notesCache?.removeWhere((n) => n.id == id);
    } else if (uuid != null) {
      _notesCache?.removeWhere((n) => n.uuid == uuid);
    }
  }

  /// 刷新缓存里若干条目的 synced 标记（markSynced* 系列用，不改明文）。
  ///
  /// [exclude]=false：只标记 [uuids] 集合内条目为已同步；
  /// [exclude]=true ：标记**除** [uuids] 之外的全部条目为已同步
  /// （[markAllSynced] 传空集即「全部标记」；[markAllSyncedExcept] 传排除集）。
  /// 同步收敛时 synced_hash 刷新为当前 content_hash、synced_deleted 刷新为
  /// 当前 deleted——这一刻本地与远端已一致，该 (hash,deleted) 即下一轮判定 base。
  void _applySyncedToCache({required Set<String> uuids, required bool exclude}) {
    final cache = _notesCache;
    if (cache == null || (uuids.isEmpty && !exclude)) return;
    _notesCache = [
      for (final n in cache)
        _shouldMarkSynced(n, uuids, exclude)
            ? n.copyWith(
                synced: true,
                syncedHash: n.contentHash,
                syncedDeleted: n.deleted,
              )
            : n,
    ];
  }

  /// [_applySyncedToCache] 的判定辅助：条目是否应被标记为已同步。
  static bool _shouldMarkSynced(SafeNote n, Set<String> uuids, bool exclude) =>
      exclude ? !uuids.contains(n.uuid) : uuids.contains(n.uuid);

  NotesDatabase._init();

  /// 设置 dataKey（登录/解锁 keyring 后调用）
  void setDataKey(Uint8List key) => _dataKey = Uint8List.fromList(key);

  /// 清除 dataKey（登出时调用）
  void clearDataKey() {
    _dataKey = null;
    _invalidateCache(); // 登出即丢弃解密缓存，避免下次登录命中旧会话明文
  }

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
    _invalidateCache(); // 新数据库连接：旧解密缓存失效
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
  Future<String> _encryptField(String uuid, String plaintext) async {
    if (plaintext.isEmpty) return plaintext;
    final dataKey = _requireDataKey;
    final bytes = Uint8List.fromList(utf8.encode(plaintext));
    final envelope = await SyncCrypto.seal(dataKey, uuid, bytes);
    return base64.encode(envelope);
  }

  /// 解密单个字段值
  ///
  /// [uuid] 必须与加密时一致
  /// [fieldValue] base64 编码的信封
  /// 返回明文文本
  Future<String> _decryptField(String uuid, String fieldValue) async {
    if (fieldValue.isEmpty) return fieldValue;
    final dataKey = _requireDataKey;
    try {
      final envelope = base64.decode(fieldValue);
      final bytes = await SyncCrypto.open(dataKey, uuid, envelope);
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
  Future<Map<String, dynamic>> _toEncryptedRow(SafeNote note) async {
    final json = note.toJson();
    json[NoteFields.title] = await _encryptField(note.uuid, note.title);
    json[NoteFields.description] =
        await _encryptField(note.uuid, note.description);
    return json;
  }

  /// 从加密的数据库行构造明文 SafeNote（用于 query 结果）
  Future<SafeNote> _fromEncryptedRow(Map<String, dynamic> json) async {
    final uuid = json[NoteFields.uuid] as String? ?? '';
    final encryptedTitle = json[NoteFields.title] as String? ?? '';
    final encryptedDesc = json[NoteFields.description] as String? ?? '';
    final decrypted = Map<String, dynamic>.from(json);
    decrypted[NoteFields.title] = await _decryptField(uuid, encryptedTitle);
    decrypted[NoteFields.description] = await _decryptField(uuid, encryptedDesc);
    return SafeNote.fromJson(decrypted);
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    try {
      final db = await openDatabase(
        path,
        version: 4,
        onCreate: _createDB,
        onUpgrade: _onUpgrade,
      );
      Log.db.i('数据库已打开: $path (version=4)');
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
    instance._notesCache = null; // 替换为新数据库连接：旧解密缓存失效（实例字段）
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
      ${NoteFields.syncedHash} TEXT,
      ${NoteFields.syncedDeleted} INTEGER NOT NULL DEFAULT 0
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

  /// 创建新数据库（version 4 schema）
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
      ${NoteFields.syncedHash} TEXT,
      ${NoteFields.syncedDeleted} INTEGER NOT NULL DEFAULT 0
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

  /// schema 升级回调（version 3 → 4：新增 synced_deleted 列）
  ///
  /// 历史背景：
  ///   - version 2/3：表结构含 synced_hash 但无 synced_deleted
  ///   - version 4：新增 synced_deleted 列，让冲突判定的 base 完整描述
  ///     (hash, deleted) 二元组，解决软删除不改 hash 导致 fast-forward
  ///     误判「双方都没改」的 bug（详见 sync_engine _mergeAndTransfer 注释）
  ///
  /// 老库升级策略：ALTER TABLE ADD COLUMN ... DEFAULT 0
  ///   - 老数据的 synced_deleted 全部初始化为 0（未删除）
  ///   - 已同步且 synced=1 的笔记：synced_deleted 应等于当前 deleted，
  ///     但因 synced_hash 已是收敛 hash，对应 deleted 状态也是 false
  ///     （删除会触发 synced=0），所以默认 0 与实际语义一致
  ///   - 未同步的笔记（synced=0）：synced_deleted 取何值都不影响判定
  ///     （base = synced_hash==null 时直接退化为「保守冲突」分支）
  static Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    Log.db.i('数据库升级: $oldVersion → $newVersion');
    if (oldVersion < 4) {
      await db.execute(
        'ALTER TABLE $tableNotes ADD COLUMN ${NoteFields.syncedDeleted} '
        'INTEGER NOT NULL DEFAULT 0',
      );
      Log.db.i('已添加列: ${NoteFields.syncedDeleted}');
    }
  }

  // ──────────────────────────────────────────────
  // 笔记 CRUD（自动加解密 title/description）
  // ──────────────────────────────────────────────

  /// 新增笔记（title/description 加密后存储）
  Future<SafeNote> storeNote(SafeNote note) async {
    _checkNotMigrating();
    final db = await instance.database;
    try {
      final id = await db.insert(tableNotes, await _toEncryptedRow(note));
      _upsertCacheEntry(note.copyWith(id: id)); // 单条新增：直接更新缓存，避免全量重解密
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
      return await _fromEncryptedRow(maps.first);
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
      return await _fromEncryptedRow(maps.first);
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
      return await _fromEncryptedRow(maps.first);
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
  ///
  /// 复用 [_notesCache]（含墓碑全量）按需过滤；缓存命中时跳过解密。
  Future<List<SafeNote>> readAllNotes() async {
    _checkNotMigrating();
    final cacheHit = _notesCache != null;
    final all = await readAllNotesIncludingDeleted();
    final notes = all.where((n) => !n.deleted).toList()
      ..sort((a, b) => a.createdTime.compareTo(b.createdTime));
    // 数据加载条数是排障关键信息（启动/刷新时都会打印）
    Log.db.i('加载笔记列表: ${notes.length} 条（未删除）'
        '${cacheHit ? '（缓存命中，跳过解密）' : '（缓存失效，已重新解密）'}');
    return notes;
  }

  /// 读取所有已删除的笔记（最近删除视图用，自动解密）
  Future<List<SafeNote>> readDeletedNotes() async {
    _checkNotMigrating();
    final sw = Stopwatch()..start();
    final db = await instance.database;
    final result = await db.query(
      tableNotes,
      columns: NoteFields.values,
      where: '${NoteFields.deleted} = 1',
      orderBy: '${NoteFields.updatedAt} DESC',
    );
    final notes = await Future.wait(
      result.map((json) => _fromEncryptedRow(json)).toList(),
    );
    Log.db.i('加载回收站笔记: ${notes.length} 条（已删除）, '
        '解密耗时 ${sw.elapsedMilliseconds}ms');
    return notes;
  }

  /// 读取所有未同步的笔记（同步引擎用，自动解密）
  Future<List<SafeNote>> readUnsyncedNotes() async {
    final db = await instance.database;
    final result = await db.query(
      tableNotes,
      columns: NoteFields.values,
      where: '${NoteFields.synced} = 0',
    );
    final notes = await Future.wait(
      result.map((json) => _fromEncryptedRow(json)).toList(),
    );
    Log.db.d('加载待同步笔记: ${notes.length} 条（synced=0）');
    return notes;
  }

  /// 读取所有笔记（含墓碑，同步引擎全量对账用，自动解密）
  ///
  /// 结果写入 [_notesCache]；命中缓存时直接返回副本，避免重复解密。
  Future<List<SafeNote>> readAllNotesIncludingDeleted() async {
    if (_notesCache != null) {
      Log.db.i('加载全量笔记（含墓碑）: 命中缓存，跳过解密（${_notesCache!.length} 条）');
      return List.of(_notesCache!);
    }
    final sw = Stopwatch()..start();
    final db = await instance.database;
    final result = await db.query(tableNotes, columns: NoteFields.values);
    final notes = await Future.wait(
      result.map((json) => _fromEncryptedRow(json)).toList(),
    );
    _notesCache = notes;
    final tombstones = notes.where((n) => n.deleted).length;
    Log.db.i('加载全量笔记（含墓碑）: 共 ${notes.length} 条 '
        '(有效 ${notes.length - tombstones} / 墓碑 $tombstones), '
        '解密耗时 ${sw.elapsedMilliseconds}ms');
    // 返回副本：避免调用方（如 _buildLocalManifest）在遍历时因
    // hardDeleteByUuid 改写 _notesCache 而触发并发修改异常。
    return List.of(notes);
  }

  /// 更新笔记（title/description 加密后存储）
  Future<int> updateNote(SafeNote note) async {
    _checkNotMigrating();
    final db = await instance.database;
    try {
      final rows = await db.update(
        tableNotes,
        await _toEncryptedRow(note),
        where: '${NoteFields.id} = ?',
        whereArgs: [note.id],
      );
      _upsertCacheEntry(note); // 单条修改：直接更新缓存，避免全量重解密
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
        await _toEncryptedRow(note),
        where: '${NoteFields.uuid} = ?',
        whereArgs: [note.uuid],
      );
      _upsertCacheEntry(note); // 单条修改：直接更新缓存，避免全量重解密
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
      // 软删除：取缓存旧条目 → 叠加增量重建完整对象 → 整条覆盖回缓存。
      // updatedAt 随对象带入，结构杜绝「漏改时间戳」导致的同步 LWW 误判。
      if (_notesCache != null) {
        final i = _notesCache!.indexWhere((n) => n.id == id);
        if (i >= 0) {
          _upsertCacheEntry(
            _notesCache![i].copyWith(deleted: true, synced: false, updatedAt: now),
          );
        }
      }
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
  /// B4 修复（epoch 消除 P0 五项）：删行 + 写 purged 列表**同一 SQLite 事务**，
  /// 堵住「永久删除复活」——若删行成功但 purged 未写（中途崩溃），该 uuid
  /// 会从远端 manifest 重新下载复活。
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

    // 2+3. 删除行 + 追加 purged 列表（同一事务，B4）
    var deleted = 0;
    await db.transaction((txn) async {
      deleted = await txn.delete(
        tableNotes,
        where: '${NoteFields.id} = ?',
        whereArgs: [id],
      );
      if (deleted > 0) {
        await _addPurgedUuidInTxn(txn, uuid);
      }
    });

    _removeCacheEntry(id: id); // 笔记被删除：从缓存移除该条目

    // 不可恢复的破坏性操作，必须留痕
    Log.note.i('永久删除笔记（不可恢复）uuid=$uuid id=$id rows=$deleted，'
        '已加入 purged 列表待同步清理');
    return deleted;
  }

  /// F1 修复：按 uuid 硬删除笔记（GC 墓碑清理用）
  ///
  /// 与 [hardDelete] 的区别：按 uuid 而非 id 删除，用于 GC 清理过期墓碑。
  /// 流程：从 notes 表删除行 → 把 uuid 追加到 purged_uuids 列表（同一事务，
  /// B4：防止删行成功但 purged 未写导致墓碑从远端复活）。
  /// 不存在时返回 0（幂等）。
  Future<int> hardDeleteByUuid(String uuid) async {
    final db = await instance.database;
    var deleted = 0;
    await db.transaction((txn) async {
      deleted = await txn.delete(
        tableNotes,
        where: '${NoteFields.uuid} = ?',
        whereArgs: [uuid],
      );
      if (deleted > 0) {
        await _addPurgedUuidInTxn(txn, uuid);
      }
    });
    if (deleted > 0) {
      _removeCacheEntry(uuid: uuid); // 笔记被删除：从缓存移除该条目
      Log.note.i('永久删除笔记（GC 墓碑清理）uuid=$uuid rows=$deleted');
    }
    return deleted;
  }

  /// 事务版：添加待清理的 uuid 到 meta 表（供 hardDelete* 在同一事务内调用，B4）
  Future<void> _addPurgedUuidInTxn(Transaction txn, String uuid) async {
    final maps = await txn.query(
      tableMeta,
      columns: [MetaFields.value],
      where: '${MetaFields.key} = ?',
      whereArgs: [MetaKeys.purgedUuids],
      limit: 1,
    );
    final existing = maps.isNotEmpty ? maps.first[MetaFields.value] as String? : null;
    final list = _parseUuidList(existing);
    if (!list.contains(uuid)) {
      list.add(uuid);
      await txn.insert(
        tableMeta,
        {
          MetaFields.key: MetaKeys.purgedUuids,
          MetaFields.value: _serializeUuidList(list),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
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
      // 恢复：取缓存旧条目 → 叠加增量重建完整对象 → 整条覆盖回缓存。
      // updatedAt 随对象带入，结构杜绝「漏改时间戳」导致的同步 LWW 误判。
      if (_notesCache != null) {
        final i = _notesCache!.indexWhere((n) => n.id == id);
        if (i >= 0) {
          _upsertCacheEntry(
            _notesCache![i].copyWith(deleted: false, synced: false, updatedAt: now),
          );
        }
      }
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
        final row = await _toEncryptedRow(note);
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

    _invalidateCache(); // 全库密文已更新，使解密缓存失效

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

  /// B1 修复（epoch 消除 P0 五项）：dataKey 迁移的原子化入口。
  ///
  /// 在**同一个 SQLite 事务**内完成：
  ///   1. 全库重加密（oldKey 解密 → newKey 加密 → 逐行 UPDATE）
  ///   2. keyring 账本 upsert（[keyringJson]：新包裹/新纪元）
  ///   3. （可选）blob 待重传标记（[markBlobReupload]：dataKey 真变时）
  ///
  /// 为什么必须原子：旧的「reEncryptAllNotes 独立事务 + 账本 persist 独立写」
  /// 存在崩溃窗口——重加密提交成功、账本尚未更新时崩溃，重启后 unlockLocal
  /// 用旧账本解出旧 dataKey，解不开已换新 key 的密文 → **全库不可解**（B1）。
  /// 同一事务保证：要么「新密文 + 新账本」都生效，要么都不生效。
  ///
  /// 调用方（keyring.migrateToRemote / migrateToRemoteVault）负责在事务
  /// 成功后替换内存 keyring 引用并 setDataKey（事务外），事务内的账本 JSON
  /// 由调用方用新 keyring 的 ledger 序列化生成。
  Future<int> reEncryptAllNotesAtomically({
    required Uint8List oldKey,
    required Uint8List newKey,
    required String keyringJson,
    bool markBlobReupload = false,
  }) async {
    final db = await instance.database;

    // F4 修复：设置迁移中标志，阻止 UI 并发读取笔记
    _isMigrating = true;
    Log.db.w('开始原子化 dataKey 迁移（重加密 + 账本 + 重传标记同一事务）');
    final startedAt = DateTime.now();
    final originalDataKey = _dataKey;
    _dataKey = Uint8List.fromList(oldKey);

    try {
      // 1. 用 oldKey 读取所有笔记（自动解密为明文）
      final notes = await readAllNotesIncludingDeleted();

      // 2. 临时切换 dataKey 为 newKey，准备加密
      _dataKey = Uint8List.fromList(newKey);

      // 3. 在内存中用 newKey 重新加密所有笔记
      final encryptedRows = <Map<String, dynamic>>[];
      for (final note in notes) {
        final row = await _toEncryptedRow(note);
        encryptedRows.add({
          'where_uuid': note.uuid,
          'row': row,
        });
      }

      // 4. 需标记重传的 uuid（dataKey 真变时：非墓碑全部标记）
      List<String>? reuploadUuids;
      if (markBlobReupload) {
        reuploadUuids =
            notes.where((n) => !n.deleted).map((n) => n.uuid).toList();
      }

      // 5. 同一事务：重加密 + 账本 + 重传标记（atomic，B1）
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
        await txn.insert(
          tableMeta,
          {
            MetaFields.key: MetaKeys.keyring,
            MetaFields.value: keyringJson,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        if (reuploadUuids != null) {
          await txn.insert(
            tableMeta,
            {
              MetaFields.key: MetaKeys.blobReuploadPending,
              MetaFields.value: jsonEncode(reuploadUuids),
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      });

      _invalidateCache(); // 全库密文已更新，使解密缓存失效

      // 6. 事务成功后更新 _dataKey（后续读写用新 key）
      _dataKey = Uint8List.fromList(newKey);

      final ms = DateTime.now().difference(startedAt).inMilliseconds;
      Log.db.i('原子化迁移完成: ${notes.length} 条笔记, 耗时 ${ms}ms');
      return notes.length;
    } catch (e, st) {
      _dataKey = originalDataKey;
      Log.db.f('原子化迁移失败，事务已回滚并恢复原 dataKey',
          error: e, stackTrace: st);
      rethrow;
    } finally {
      _isMigrating = false;
    }
  }

  /// 标记笔记为已同步
  ///
  /// 同步收敛时，把 synced_hash 更新为当前 content_hash、synced_deleted 更新为
  /// 当前 deleted——这一刻本地与远端已一致，当前 (hash, deleted) 二元组即成为
  /// 下一轮冲突判定的共同祖先 base。
  Future<void> markSynced(String uuid) async {
    final db = await instance.database;
    await db.rawUpdate(
      'UPDATE $tableNotes SET ${NoteFields.synced} = 1, '
      '${NoteFields.syncedHash} = ${NoteFields.contentHash}, '
      '${NoteFields.syncedDeleted} = ${NoteFields.deleted} '
      'WHERE ${NoteFields.uuid} = ?',
      [uuid],
    );
    if (_notesCache != null) _applySyncedToCache(uuids: {uuid}, exclude: false);
  }

  /// 标记所有笔记为已同步（全量同步完成后用）
  ///
  /// 同时把每条笔记的 synced_hash 刷新为 content_hash、synced_deleted 刷新为
  /// deleted：同步流程结束时本地库已是收敛后的最终状态，此刻记下的
  /// (hash, deleted) 就是下一轮判定单边/并发的 base。
  Future<void> markAllSynced() async {
    final db = await instance.database;
    final rows = await db.rawUpdate(
      'UPDATE $tableNotes SET ${NoteFields.synced} = 1, '
      '${NoteFields.syncedHash} = ${NoteFields.contentHash}, '
      '${NoteFields.syncedDeleted} = ${NoteFields.deleted}',
    );
    Log.db.i('标记全部笔记为已同步: $rows 条');
    _applySyncedToCache(uuids: {}, exclude: true);
  }

  /// 标记所有笔记为已同步，但排除指定 uuid（P6 修复，DS002）
  ///
  /// 排除的笔记本轮**并未收敛**（如上传失败的笔记：本地是新内容、远端仍是旧内容，
  /// 二者未达成一致）。若把它们也 markSynced，synced_hash 会被写成「远端没有的
  /// 新 hash」，污染下一轮冲突判定的三方合并 base（详见 sync_engine
  /// _mergeAndTransfer 的 shouldPreserveCopy 判定）。排除后这些笔记保持
  /// synced=0、synced_hash 为旧 base，下次同步照常重试。
  Future<void> markAllSyncedExcept(Set<String> exclude) async {
    if (exclude.isEmpty) {
      await markAllSynced();
      return;
    }
    final db = await instance.database;
    final placeholders = List.filled(exclude.length, '?').join(',');
    final rows = await db.rawUpdate(
      'UPDATE $tableNotes SET ${NoteFields.synced} = 1, '
      '${NoteFields.syncedHash} = ${NoteFields.contentHash}, '
      '${NoteFields.syncedDeleted} = ${NoteFields.deleted} '
      'WHERE ${NoteFields.uuid} NOT IN ($placeholders)',
      exclude.toList(),
    );
    Log.db.i('标记笔记为已同步: $rows 条已标记, ${exclude.length} 条本轮未收敛被排除');
    _applySyncedToCache(uuids: exclude, exclude: true);
  }

  /// P1-A 修复：按 uuid 集合标记已同步（白名单模式）
  ///
  /// 与 [markAllSyncedExcept] 的「黑名单排除」语义相对——只把传入的 uuid 标记为
  /// synced=1 并刷新 synced_hash/synced_deleted，集合外的笔记一律不动。
  ///
  /// 为什么需要白名单：[markAllSyncedExcept] 是全量 UPDATE（NOT IN exclude），
  /// 会把同步期间被用户编辑的笔记也一并标记 synced=1，并把 synced_hash 写成
  /// 「远端没有的新 hash」——下次同步 fast-forward 远端单边会把远端旧内容
  /// 下载覆盖本地新编辑，导致丢数据（docs/conflict-analysis-20260802.md §P1-A）。
  ///
  /// 调用方（SyncEngine._updateLocalState）只传入「本轮真正收敛」的 uuid 集合
  /// （当前 (hash, deleted) == merged.items[uuid] 的笔记），从根上杜绝误标。
  Future<void> markSyncedForUuids(Set<String> uuids) async {
    if (uuids.isEmpty) {
      Log.db.i('按 uuid 集合标记已同步: 空集合，跳过');
      return;
    }
    final db = await instance.database;
    final placeholders = List.filled(uuids.length, '?').join(',');
    final rows = await db.rawUpdate(
      'UPDATE $tableNotes SET ${NoteFields.synced} = 1, '
      '${NoteFields.syncedHash} = ${NoteFields.contentHash}, '
      '${NoteFields.syncedDeleted} = ${NoteFields.deleted} '
      'WHERE ${NoteFields.uuid} IN ($placeholders)',
      uuids.toList(),
    );
    Log.db.i('按 uuid 集合标记已同步: $rows 条已标记 (请求 ${uuids.length} 个)');
    _applySyncedToCache(uuids: uuids, exclude: false);
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
    Log.db.w('密钥变更后标记 blob 待重传: ${uuids.length} 条笔记');
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

  /// 仅移除「本轮已成功重传」的待重传标记（P1 修复）
  ///
  /// 与 [clearAllPendingReupload] 的区别：重传**失败**的笔记保留标记，下次同步
  /// 继续强制用新密钥重传，避免旧密钥 blob 永久残留；远程独享笔记（本机无明文）
  /// 不属于本轮上传集合，自然保留。本机无法处理的 uuid 由其他设备重传后，
  /// 下次同步成功上传时也会被移除。
  Future<void> removePendingReuploadUuids(Set<String> uploadedOk) async {
    if (uploadedOk.isEmpty) return;
    final current = await getPendingReuploadUuids();
    if (current.isEmpty) return;
    final remaining = current.difference(uploadedOk);
    if (remaining.isEmpty) {
      await clearAllPendingReupload();
    } else {
      await setMeta(MetaKeys.blobReuploadPending, jsonEncode(remaining.toList()));
    }
  }

  // ──────────────────────────────────────────────
  // 孤儿 blob 两阶段 GC 的候选表（P2 修复，DS002）
  // ──────────────────────────────────────────────────
  //
  // 背景：GC 的 listBlobs() 可能包含「他端刚 putBlob、尚未 putManifest」的 blob，
  // 单次观察就隔离会误删正在上传的内容（manifest 引用它时已进隔离区）。
  // 解法：首次观察只登记候选、不隔离；连续第二次观察仍为孤儿才隔离，
  // 给他端一个完整同步周期的窗口把 blob 提交进 manifest。
  // 候选表按设备本地持久化（hash → 首次观察时间戳），重启不丢。

  /// 读取孤儿 blob 候选表（hash → 首次观察时间戳；空表示无候选）
  Future<Map<String, int>> getGcOrphanCandidates() async {
    final raw = await getMeta(MetaKeys.gcOrphanCandidates);
    if (raw == null || raw.isEmpty) return {};
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return map.map((k, v) => MapEntry(k, v as int));
    } on Object {
      return {};
    }
  }

  /// 覆盖写入孤儿 blob 候选表
  Future<void> setGcOrphanCandidates(Map<String, int> candidates) async {
    if (candidates.isEmpty) {
      final db = await instance.database;
      await db.delete(
        tableMeta,
        where: '${MetaFields.key} = ?',
        whereArgs: [MetaKeys.gcOrphanCandidates],
      );
      return;
    }
    await setMeta(MetaKeys.gcOrphanCandidates, jsonEncode(candidates));
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
    _invalidateCache(); // 关闭数据库连接后丢弃解密缓存
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
      _invalidateCache();
    }
  }
}
