/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

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
import 'dart:io';

// Package 导入
import 'package:meta/meta.dart' show visibleForTesting;
import 'package:path/path.dart';
import 'package:sqflite_common/sqlite_api.dart';
import 'package:sqflite_common/sqflite.dart' show databaseFactory;

// Project 导入
import 'package:core/src/models/note_meta.dart';
import 'package:core/src/models/note_version.dart';
import 'package:core/src/models/safenote.dart';
import 'package:core/src/crypto/crypto.dart';
import 'package:core/src/logger/app_logger.dart';
import 'package:core/src/sync/sync_error.dart';

const String tableMeta = 'sync_meta';

/// DB Inspector 数据视图隐藏的列。
///
/// notes 表的 title / description 是字段级加密的密文包络，DB Inspector 仅用于
/// 排查本地库结构，无需展示这两列（既避免噪声，也遵循隐私红线不暴露笔记字段）。
/// note_meta 表的 payload 同理（内含标签等用户输入文本的密文）。
const Set<String> _inspectorHiddenColumns = {'title', 'description', 'payload'};

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
  MigrationInProgressException([this.message = '数据迁移进行中，请稍候']);

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

  /// 数据库工厂注入点（解耦 sqflite 插件，使本文件可被纯 Dart 编译）。
  ///
  /// App 侧由 main.dart 注入全局 [databaseFactory]（桌面端已换为 FFI、
  /// 移动端由 sqflite 插件注册）；CLI / 测试侧注入 `databaseFactoryFfi`。
  /// 为 null 时回退到全局 [databaseFactory]，保证行为与改造前一致。
  static DatabaseFactory? dbFactoryOverride;

  /// 数据库目录路径注入点（解耦 `getDatabasesPath()`）。
  ///
  /// 桌面端可传 `getApplicationSupportDirectory()` 的结果，移动端传
  /// `getDatabasesPath()`。为 null 时回退到 factory 自身的数据库目录。
  static String? dbPathOverride;

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

  /// 内存态快照（仅元数据，不含敏感内容），供调试面板 / WebServer 使用。
  Map<String, dynamic> getCacheInfo() => {
    'isMigrating': _isMigrating,
    'cacheBuilt': _notesCache != null,
    'cacheCount': _notesCache?.length ?? 0,
  };

  /// 缓存笔记摘要（供内存快照 / DB Inspector 展示，不含正文内容）。
  ///
  /// 仅暴露 uuid / 标题 / 删除标记 / 修改时间 / 同步标记，绝不返回 [description]
  /// （笔记明文正文），符合隐私红线。
  List<Map<String, dynamic>> cachedNoteSummaries() {
    final cache = _notesCache;
    if (cache == null) return const [];
    return cache
        .map(
          (n) => <String, dynamic>{
            'uuid': n.uuid,
            'title': n.title,
            'deleted': n.deleted,
            'updatedAt': DateTime.fromMillisecondsSinceEpoch(
              n.updatedAt,
            ).toIso8601String(),
            'synced': n.synced,
          },
        )
        .toList();
  }

  /// 查询指定表的前 [limit] 行数据（DB Inspector 展示用）。
  ///
  /// 隐私约束：blob 列（如 notes 表的加密包络）不展开内容，仅以占位符
  /// `<blob N B>` 表示——notes 表存储密文包络、无明文，天然不泄露笔记内容。
  /// [table] 必须是合法 SQL 标识符（白名单校验，防注入）。
  Future<List<Map<String, dynamic>>> queryTableRows(
    String table, {
    int limit = 100,
  }) async {
    if (!_isSafeIdentifier(table)) {
      throw ArgumentError('非法表名: $table');
    }
    final db = await database;
    // 防御：SQLite 中只有 表/视图 可被 SELECT；索引、触发器被误传时给出
    // 明确错误，而不是透传 "no such table" 原生报错。此前调试面板曾把
    // idx_notes_uuid 等索引当表查询，日志刷屏（索引不是表，本就不可查行）。
    final objs = await db.rawQuery(
      "SELECT type FROM sqlite_master WHERE name = ? LIMIT 1",
      [table],
    );
    if (objs.isEmpty) {
      throw ArgumentError('对象不存在: $table');
    }
    final objType = objs.first['type'] as String?;
    if (objType != 'table' && objType != 'view') {
      throw ArgumentError('$table 是 $objType 类型，不是表/视图，无法查询行数据');
    }
    final rows = await db.rawQuery('SELECT * FROM "$table" LIMIT ?', [limit]);
    return rows.map((row) {
      final out = <String, dynamic>{};
      row.forEach((k, v) {
        // 隐私：DB Inspector 数据视图不展示笔记的 title / description 加密列
        if (_inspectorHiddenColumns.contains(k)) return;
        if (v is Uint8List || v is List<int>) {
          out[k] = '<blob ${(v as List<int>).length} B>';
        } else {
          out[k] = v;
        }
      });
      return out;
    }).toList();
  }

  static bool _isSafeIdentifier(String s) =>
      s.isNotEmpty && RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(s);

  /// Database Inspector：返回本地库结构元数据（表清单、行数、列 schema、文件信息）。
  ///
  /// 隐私约束：
  ///   - 不查询 blob / 密文内容，仅暴露结构元数据；
  ///   - sync_meta 的敏感 value（如 keyring JSON）不展开，仅列出 key 名。
  Future<Map<String, dynamic>> inspectMetadata() async {
    final db = await database;
    final path = db.path;
    int? sizeBytes;
    try {
      sizeBytes = await File(path).length();
    } on Object {
      sizeBytes = null;
    }
    final objects = await db.rawQuery(
      "SELECT name, type, sql FROM sqlite_master "
      "WHERE type IN ('table','view','index','trigger') ORDER BY type, name",
    );
    final tables = <Map<String, dynamic>>[];
    for (final o in objects) {
      final name = o['name'] as String;
      final type = o['type'] as String;
      if (name.startsWith('sqlite_')) continue; // 跳过内部对象
      int? rowCount;
      List<Map<String, dynamic>>? columns;
      if (type == 'table') {
        try {
          final c = await db.rawQuery('SELECT COUNT(*) AS c FROM "$name"');
          rowCount = (c.first['c'] as int?) ?? 0;
        } on Object {
          rowCount = null;
        }
        try {
          final info = await db.rawQuery('PRAGMA table_info("$name")');
          columns = info
              .map(
                (r) => <String, dynamic>{
                  'cid': r['cid'],
                  'name': r['name'],
                  'type': r['type'],
                  'notnull': r['notnull'],
                  'pk': r['pk'],
                },
              )
              .toList();
        } on Object {
          columns = null;
        }
      }
      tables.add(<String, dynamic>{
        'name': name,
        'type': type,
        'sql': o['sql'],
        'rowCount': rowCount,
        'columns': columns,
      });
    }
    // sync_meta：仅列出 key 名，不展开敏感 value
    List<String>? metaKeys;
    try {
      final meta = await db.query(tableMeta, columns: [MetaFields.key]);
      metaKeys = meta.map((m) => m[MetaFields.key] as String).toList();
    } on Object {
      metaKeys = null;
    }
    return <String, dynamic>{
      'path': path,
      'sizeBytes': sizeBytes,
      'tables': tables,
      'metaKeys': metaKeys,
    };
  }

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

  /// note_meta 的独立内存缓存（key = 笔记 uuid，仅含 deleted=0 的行）。
  ///
  /// **与 [_notesCache] 完全隔离**，这是本设计的核心收益：切换星标只
  /// UPDATE 一行 + 只改本缓存一个 entry，[_notesCache] 分毫不动 →
  /// **零笔记解密**。若把元数据塞进 notes 表或靠 JOIN 带出，点一次星标
  /// 就会走 notes 的写路径进而可能触发全量重解密，是明显的性能倒退。
  ///
  /// 懒创建：note_meta 无对应行的笔记视为 [NoteMeta.defaults]，不占 entry。
  Map<String, NoteMeta>? _metaCache;

  /// 使解密缓存整体失效（笔记 + 笔记元数据）。
  ///
  /// 触发场景：reEncryptAllNotes* / close / logout / 新数据库连接。
  /// 两份缓存一并清空——它们的明文都由同一把 dataKey 解出，
  /// 失效条件完全一致，收口在一处可避免漏清其中之一。
  void _invalidateCache() {
    _notesCache = null;
    _metaCache = null;
  }

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
  void _applySyncedToCache({
    required Set<String> uuids,
    required bool exclude,
  }) {
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
    } on SyncDecryptionException {
      // 解密失败：dataKey 不匹配或数据损坏，保留原始异常类型向上传递
      rethrow;
    } catch (e) {
      // 其他异常（如 base64 解码失败）仍包装为可捕获的异常
      throw SyncDecryptionException('字段解密失败: $e', aadId: uuid);
    }
  }

  /// 将明文 SafeNote 转为加密的数据库行（用于 insert/update）
  Future<Map<String, dynamic>> _toEncryptedRow(SafeNote note) async {
    final json = note.toJson();
    json[NoteFields.title] = await _encryptField(note.uuid, note.title);
    json[NoteFields.description] = await _encryptField(
      note.uuid,
      note.description,
    );
    return json;
  }

  /// 从加密的数据库行构造明文 SafeNote（用于 query 结果）
  Future<SafeNote> _fromEncryptedRow(Map<String, dynamic> json) async {
    final uuid = json[NoteFields.uuid] as String? ?? '';
    final encryptedTitle = json[NoteFields.title] as String? ?? '';
    final encryptedDesc = json[NoteFields.description] as String? ?? '';
    final decrypted = Map<String, dynamic>.from(json);
    decrypted[NoteFields.title] = await _decryptField(uuid, encryptedTitle);
    decrypted[NoteFields.description] = await _decryptField(
      uuid,
      encryptedDesc,
    );
    return SafeNote.fromJson(decrypted);
  }

  /// 当前 schema 版本。
  ///
  /// 版本史：
  ///   - v2/v3：含 synced_hash，无 synced_deleted
  ///   - v4：新增 notes.synced_deleted 列（冲突判定 base 补全 deleted 维度）
  ///   - v5：新增 note_meta 表（笔记级元数据：星标/标签/归档…）。
  ///     **不动 notes 表**，仅 `CREATE TABLE IF NOT EXISTS`，老库零风险升级。
  ///   - v6：note_meta 新增 `locked` 明文列（笔记锁定只读标志）。
  ///   - v7：新增 note_versions 表（笔记历史版本，字段级加密，不参与同步）。
  ///     **不动 notes 表**，仅 `CREATE TABLE IF NOT EXISTS`，老库零风险升级。
  static const int _schemaVersion = 7;

  Future<Database> _initDB(String filePath) async {
    final factory = dbFactoryOverride ?? databaseFactory;
    final dbPath = dbPathOverride ?? await factory.getDatabasesPath();
    final path = join(dbPath, filePath);

    try {
      final db = await factory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: _schemaVersion,
          onCreate: _createDB,
          onUpgrade: _onUpgrade,
        ),
      );
      Log.db.i('数据库已打开: $path (version=$_schemaVersion)');
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
    // 替换为新数据库连接：旧解密缓存（笔记 + 元数据）全部失效（实例字段）
    instance._invalidateCache();
  }

  /// 测试专用：createDB 回调（供 in-memory 数据库 onCreate 使用）
  @visibleForTesting
  static Future<void> createDBForTesting(Database db, int version) async {
    await _createDBStatic(db, version);
  }

  /// 创建 note_meta 表及其索引（幂等）
  ///
  /// **建表语句唯一副本**：`_createDBStatic` / `_createDB` / `_onUpgrade`
  /// 三条建库路径全部调用此方法。notes 表的建表语句在前两处是重复的两份
  /// （历史遗留，容易漏改一处导致 `no such table`），新表不再重复该模式。
  ///
  /// 全部 `IF NOT EXISTS`：既可用于新建库，也可用于老库升级，语义一致。
  ///
  /// ⚠️ [NoteMetaFields.uuid] **绝不能**写成
  /// `REFERENCES $tableNotes(uuid) ON DELETE CASCADE`：
  /// deleted=1 的行是墓碑，必须在 notes 行被硬删除后**继续存活**，
  /// 才能在下次同步时告知远端"这条已删"。级联删除会摧毁墓碑机制。
  /// uuid 仅为逻辑关联，一致性由应用层维护。
  static Future<void> _createNoteMetaTable(DatabaseExecutor db) async {
    await db.execute('''
    CREATE TABLE IF NOT EXISTS $tableNoteMeta (
      ${NoteMetaFields.id} INTEGER PRIMARY KEY AUTOINCREMENT,
      ${NoteMetaFields.uuid} TEXT NOT NULL UNIQUE,
      ${NoteMetaFields.pinned} INTEGER NOT NULL DEFAULT 0,
      ${NoteMetaFields.locked} INTEGER NOT NULL DEFAULT 0,
      ${NoteMetaFields.archived} INTEGER NOT NULL DEFAULT 0,
      ${NoteMetaFields.color} INTEGER,
      ${NoteMetaFields.deleted} INTEGER NOT NULL DEFAULT 0,
      ${NoteMetaFields.payload} TEXT,
      ${NoteMetaFields.updatedAt} INTEGER NOT NULL,
      ${NoteMetaFields.synced} INTEGER NOT NULL DEFAULT 0
    )
    ''');

    // 索引：待上报墓碑查询 `WHERE deleted=1 AND synced=0`（同步用）
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_note_meta_synced '
      'ON $tableNoteMeta(${NoteMetaFields.synced})',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_note_meta_deleted '
      'ON $tableNoteMeta(${NoteMetaFields.deleted})',
    );
    // 不建 uuid 索引：UNIQUE 约束已隐含唯一索引，再建是冗余。
    // 不建 pinned 索引：星标过滤在内存完成（全量行已进 _metaCache），无 SQL 消费者。
  }

  /// 创建 note_versions 表及其索引（幂等）
  ///
  /// 与 [_createNoteMetaTable] 同模式：建表语句唯一副本，
  /// `_createDBStatic` / `_createDB` / `_onUpgrade` 三条路径全部调用此方法。
  ///
  /// ⚠️ [NoteVersionFields.noteUuid] **不设** SQL 外键约束：
  /// 与 note_meta 表策略一致——墓碑硬删除后版本行先存活、由应用层清理。
  static Future<void> _createNoteVersionsTable(DatabaseExecutor db) async {
    await db.execute('''
    CREATE TABLE IF NOT EXISTS $tableNoteVersions (
      ${NoteVersionFields.id} INTEGER PRIMARY KEY AUTOINCREMENT,
      ${NoteVersionFields.noteUuid} TEXT NOT NULL,
      ${NoteVersionFields.title} TEXT NOT NULL,
      ${NoteVersionFields.description} TEXT NOT NULL,
      ${NoteVersionFields.contentHash} TEXT NOT NULL,
      ${NoteVersionFields.savedAt} INTEGER NOT NULL
    )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_versions_uuid '
      'ON $tableNoteVersions(${NoteVersionFields.noteUuid})',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_versions_uuid_time '
      'ON $tableNoteVersions(${NoteVersionFields.noteUuid}, '
      '${NoteVersionFields.savedAt} DESC)',
    );
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
      'CREATE INDEX idx_notes_uuid ON $tableNotes(${NoteFields.uuid})',
    );
    await db.execute(
      'CREATE INDEX idx_notes_deleted ON $tableNotes(${NoteFields.deleted})',
    );
    await db.execute(
      'CREATE INDEX idx_notes_synced ON $tableNotes(${NoteFields.synced})',
    );

    await _createNoteMetaTable(db);
    await _createNoteVersionsTable(db);
  }

  /// 创建新数据库（version 5 schema）
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
      'CREATE INDEX idx_notes_uuid ON $tableNotes(${NoteFields.uuid})',
    );
    // 索引：按 deleted 过滤（最近删除视图用）
    await db.execute(
      'CREATE INDEX idx_notes_deleted ON $tableNotes(${NoteFields.deleted})',
    );
    // 索引：按 synced 过滤（同步用，找未同步的笔记）
    await db.execute(
      'CREATE INDEX idx_notes_synced ON $tableNotes(${NoteFields.synced})',
    );

    // 笔记级元数据表（星标/标签/归档…），见 docs/feature-note-meta-design.md
    await _createNoteMetaTable(db);

    // 笔记历史版本表，见 docs/feature-note-version-history-design.md
    await _createNoteVersionsTable(db);
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
  static Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    Log.db.i('数据库升级: $oldVersion → $newVersion');
    if (oldVersion < 4) {
      await db.execute(
        'ALTER TABLE $tableNotes ADD COLUMN ${NoteFields.syncedDeleted} '
        'INTEGER NOT NULL DEFAULT 0',
      );
      Log.db.i('已添加列: ${NoteFields.syncedDeleted}');
    }
    // v4 → v5：新增 note_meta 表（笔记级元数据）
    //
    // 风险远低于 v3→v4 的 ALTER TABLE：CREATE TABLE IF NOT EXISTS 幂等，
    // **完全不 touch notes 表数据**，失败也不会损坏既有笔记。
    // 无需回填——新表为空 + 元数据行懒创建（读取时无行即视为全默认值）。
    if (oldVersion < 5) {
      await _createNoteMetaTable(db);
      Log.db.i('已创建表: $tableNoteMeta');
    } else if (oldVersion < 6) {
      // v5 → v6：note_meta 表已存在（旧表无 locked 列），仅补列。
      // 注意：仅当旧库已有 note_meta 时才 ALTER，否则第一次建表已含 locked，
      // 重复 ADD COLUMN 会报 duplicate column name。
      await db.execute(
        'ALTER TABLE $tableNoteMeta ADD COLUMN '
        '${NoteMetaFields.locked} INTEGER NOT NULL DEFAULT 0',
      );
      Log.db.i('已添加列: ${NoteMetaFields.locked}');
    }
    // v6 → v7：新增 note_versions 表（笔记历史版本）
    //
    // 与 v5 创建 note_meta 同样零风险：CREATE TABLE IF NOT EXISTS 幂等，
    // **完全不 touch notes 表数据**，失败也不会损坏既有笔记。
    if (oldVersion < 7) {
      await _createNoteVersionsTable(db);
      Log.db.i('已创建表: $tableNoteVersions');
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
      Log.note.i(
        '新增笔记 uuid=${note.uuid} id=$id '
        'hash=${_hashBrief(note.contentHash)} '
        'len=${note.title.length}+${note.description.length}',
      );
      return note.copyWith(id: id);
    } on Object catch (e, st) {
      Log.note.e('新增笔记失败 uuid=${note.uuid}', error: e, stackTrace: st);
      rethrow;
    }
  }

  /// 事务式批量新增（导入备份用，评审 #10 修复）
  ///
  /// 逐条 `storeNote` 是「隐式提交」：中途任一笔记失败，已插入的笔记不会
  /// 回滚，留下半库数据。这里把整个导入放入单事务，**全部成功才落库**；
  /// 任一条失败即回滚并原样抛出，由调用方提示用户「导入失败，原数据未改动」。
  ///
  /// **uuid 幂等去重**（与 CLI `import` 语义一致，见 `bin/cli_commands.dart`）：
  /// 库中已存在同 uuid 的笔记（含墓碑）直接跳过，仅新增本地没有的。
  /// 否则「导出备份 → 重新导入同一份备份」会撞 `safe_notes.uuid` 唯一约束
  /// 而整体回滚，详见 docs/backup-encryption-design-20260810.md §4.1。
  ///
  /// 成功返回**实际插入**数量（被跳过的已存在笔记不计入）。
  Future<int> storeNotesInTransaction(List<SafeNote> notes) async {
    if (notes.isEmpty) return 0;
    _checkNotMigrating();
    final db = await instance.database;

    // 幂等去重：先查候选 uuid 是否已存在于库（含墓碑，墓碑同样占用唯一键），
    // 已存在的跳过，避免裸 INSERT 触发 UNIQUE 约束整体回滚。
    final existingUuids = await _existingUuids(db, notes.map((n) => n.uuid));
    final toInsert = existingUuids.isEmpty
        ? notes
        : notes.where((n) => !existingUuids.contains(n.uuid)).toList();
    final skipped = notes.length - toInsert.length;
    if (skipped > 0) {
      Log.note.i(
        '事务批量新增: 跳过 $skipped/${notes.length} 条已存在 uuid'
        '（幂等去重）',
      );
    }

    try {
      // 先加密（异步、耗时），再在事务内批量写入，避免事务长时间占用连接
      final rows = await Future.wait(
        toInsert.map((n) async => (note: n, row: await _toEncryptedRow(n))),
      );
      await db.transaction((txn) async {
        for (final entry in rows) {
          await txn.insert(tableNotes, entry.row);
        }
      });
      // 事务提交成功后再更新缓存（插入执行中缓存不参与，避免读到半状态）
      // M-02 修复：事务内 insert 返回的自增 id 未回填到缓存条目，
      // 后续 readNote(id)/softDelete(id) 会因 id==null 失败。
      // 此处直接失效缓存，下次读取时从 DB 重建（含正确 id）。
      _invalidateCache();
      Log.note.i(
        '事务批量新增完成: 实际插入 ${rows.length}/${notes.length} 条'
        '笔记（导入，跳过 $skipped 条）',
      );
      return rows.length;
    } on Object catch (e, st) {
      Log.note.e(
        '事务批量新增失败，已整体回滚: ${toInsert.length} 条笔记（导入）',
        error: e,
        stackTrace: st,
      );
      rethrow;
    }
  }

  /// 查询给定 uuid 集合中已存在于库里的子集（导入幂等去重用）
  ///
  /// 按 chunk 折叠成 SQL `IN` 子句，避免超大导入（数千 uuid）触碰 SQLite
  /// 变量占位符上限（SQLITE_MAX_VARIABLE_NUMBER）。含墓碑——墓碑同样占用
  /// `safe_notes.uuid` 唯一键。
  Future<Set<String>> _existingUuids(
    Database db,
    Iterable<String> uuids,
  ) async {
    final unique = uuids.toSet();
    if (unique.isEmpty) return const {};
    final existing = <String>{};
    const int chunkSize = 400;
    final list = unique.toList();
    for (var i = 0; i < list.length; i += chunkSize) {
      var end = i + chunkSize;
      if (end > list.length) end = list.length;
      final chunk = list.sublist(i, end);
      final marks = List.filled(chunk.length, '?').join(',');
      final maps = await db.query(
        tableNotes,
        columns: [NoteFields.uuid],
        where: '${NoteFields.uuid} IN ($marks)',
        whereArgs: chunk,
      );
      for (final row in maps) {
        final uuid = row[NoteFields.uuid];
        if (uuid is String) existing.add(uuid);
      }
    }
    return existing;
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
    Log.db.i(
      '加载笔记列表: ${notes.length} 条（未删除）'
      '${cacheHit ? '（缓存命中，跳过解密）' : '（缓存失效，已重新解密）'}',
    );
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
    Log.db.i(
      '加载回收站笔记: ${notes.length} 条（已删除）, '
      '解密耗时 ${sw.elapsedMilliseconds}ms',
    );
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
    Log.db.i(
      '加载全量笔记（含墓碑）: 共 ${notes.length} 条 '
      '(有效 ${notes.length - tombstones} / 墓碑 $tombstones), '
      '解密耗时 ${sw.elapsedMilliseconds}ms',
    );
    // 返回副本：避免调用方（如 _buildLocalManifest）在遍历时因
    // hardDeleteByUuid 改写 _notesCache 而触发并发修改异常。
    return List.of(notes);
  }

  /// 更新笔记（title/description 加密后存储）
  Future<int> updateNote(SafeNote note) async {
    _checkNotMigrating();
    final db = await instance.database;
    try {
      // P0-log：syncedHash 变更追踪
      // UI 编辑路径若误写旧 syncedHash（覆盖同步引擎已更新的 base），
      // 会导致下次同步误判为冲突。此处对比写入前后的 syncedHash 值。
      final oldRow = await db.query(
        tableNotes,
        columns: [NoteFields.syncedHash],
        where: '${NoteFields.id} = ?',
        whereArgs: [note.id],
        limit: 1,
      );
      final oldSyncedHash = oldRow.isNotEmpty
          ? oldRow.first[NoteFields.syncedHash] as String?
          : null;

      final rows = await db.update(
        tableNotes,
        await _toEncryptedRow(note),
        where: '${NoteFields.id} = ?',
        whereArgs: [note.id],
      );
      _upsertCacheEntry(note); // 单条修改：直接更新缓存，避免全量重解密

      // P0-log：若 syncedHash 被回退（新值 ≠ 旧值且新值 ≠ null 且新值 ≠ contentHash）
      // 说明 UI 路径可能写入了过时的 base，发出 WARN
      final newSyncedHash = note.syncedHash;
      if (oldSyncedHash != null &&
          newSyncedHash != null &&
          oldSyncedHash != newSyncedHash &&
          newSyncedHash != note.contentHash) {
        Log.note.w(
          'updateNote syncedHash 回退: uuid=${note.uuid.substring(0, 8)} '
          '${oldSyncedHash.substring(0, 8)}… → ${newSyncedHash.substring(0, 8)}… '
          '(expected ${note.contentHash.substring(0, 8)}…)',
        );
      }

      Log.note.i(
        '修改笔记 uuid=${note.uuid} id=${note.id} '
        'hash=${_hashBrief(note.contentHash)} '
        'synced=${note.synced ? 1 : 0} '
        'syncedHash=${_hashBrief(note.syncedHash)} '
        'len=${note.title.length}+${note.description.length} rows=$rows',
      );
      return rows;
    } on Object catch (e, st) {
      Log.note.e(
        '修改笔记失败 uuid=${note.uuid} id=${note.id}',
        error: e,
        stackTrace: st,
      );
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
      Log.note.i(
        '按 uuid 更新笔记 uuid=${note.uuid} '
        'hash=${_hashBrief(note.contentHash)} '
        'deleted=${note.deleted} rows=$rows',
      );
      return rows;
    } on Object catch (e, st) {
      Log.note.e('按 uuid 更新笔记失败 uuid=${note.uuid}', error: e, stackTrace: st);
      rethrow;
    }
  }

  // ──────────────────────────────────────────────
  // 笔记历史版本 CRUD（title/description 自动加解密，与 notes 表一致）
  // ──────────────────────────────────────────────

  /// 每条笔记保留的最大版本数（FIFO 清理阈值）
  static const int kMaxVersionsPerNote = 50;

  /// 保存笔记内容的版本快照
  ///
  /// 在笔记内容被覆盖之前调用（editor_state.updateNote 和
  /// sync_engine._downloadNote），保存旧内容快照。
  ///
  /// contentHash 去重：如果最新版本的 contentHash 与当前相同则跳过，
  /// 避免无修改的保存产生重复版本。
  /// 超过 [kMaxVersionsPerNote] 时自动 FIFO 清理最旧版本。
  Future<void> saveVersion(SafeNote note) async {
    _checkNotMigrating();
    final db = await instance.database;

    // 去重：查最新版本的 content_hash
    final latest = await db.rawQuery(
      'SELECT ${NoteVersionFields.contentHash} FROM $tableNoteVersions '
      'WHERE ${NoteVersionFields.noteUuid} = ? '
      'ORDER BY ${NoteVersionFields.savedAt} DESC LIMIT 1',
      [note.uuid],
    );
    if (latest.isNotEmpty &&
        latest.first[NoteVersionFields.contentHash] == note.contentHash) {
      Log.note.d('版本内容与最新版本相同, 跳过 uuid=${note.uuid}');
      return;
    }

    // 加密 + 插入
    final row = <String, dynamic>{
      NoteVersionFields.noteUuid: note.uuid,
      NoteVersionFields.title: await _encryptField(note.uuid, note.title),
      NoteVersionFields.description: await _encryptField(
        note.uuid,
        note.description,
      ),
      NoteVersionFields.contentHash: note.contentHash,
      NoteVersionFields.savedAt: DateTime.now().millisecondsSinceEpoch,
    };
    await db.insert(tableNoteVersions, row);

    Log.note.i(
      '保存版本快照 uuid=${note.uuid} '
      'hash=${_hashBrief(note.contentHash)} '
      'len=${note.title.length}+${note.description.length}',
    );

    // 超限清理
    await _pruneVersions(note.uuid);
  }

  /// 读取笔记的所有历史版本（按 saved_at DESC，最新在前）
  Future<List<NoteVersion>> readVersions(String noteUuid) async {
    _checkNotMigrating();
    final db = await instance.database;
    final rows = await db.query(
      tableNoteVersions,
      where: '${NoteVersionFields.noteUuid} = ?',
      whereArgs: [noteUuid],
      orderBy: '${NoteVersionFields.savedAt} DESC',
    );
    final versions = <NoteVersion>[];
    for (final row in rows) {
      final decrypted = Map<String, dynamic>.from(row);
      final uuid = row[NoteVersionFields.noteUuid] as String? ?? '';
      decrypted[NoteVersionFields.title] = await _decryptField(
        uuid,
        row[NoteVersionFields.title] as String? ?? '',
      );
      decrypted[NoteVersionFields.description] = await _decryptField(
        uuid,
        row[NoteVersionFields.description] as String? ?? '',
      );
      versions.add(NoteVersion.fromJson(decrypted));
    }
    Log.note.d('读取版本列表 uuid=$noteUuid count=${versions.length}');
    return versions;
  }

  /// 读取单个版本（按 id，解密后返回）
  Future<NoteVersion?> readVersion(int versionId) async {
    _checkNotMigrating();
    final db = await instance.database;
    final rows = await db.query(
      tableNoteVersions,
      where: '${NoteVersionFields.id} = ?',
      whereArgs: [versionId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final uuid = row[NoteVersionFields.noteUuid] as String? ?? '';
    final decrypted = Map<String, dynamic>.from(row);
    decrypted[NoteVersionFields.title] = await _decryptField(
      uuid,
      row[NoteVersionFields.title] as String? ?? '',
    );
    decrypted[NoteVersionFields.description] = await _decryptField(
      uuid,
      row[NoteVersionFields.description] as String? ?? '',
    );
    return NoteVersion.fromJson(decrypted);
  }

  /// 恢复指定版本的内容到笔记
  ///
  /// 恢复前会先保存当前笔记内容作为新版本（确保可撤销恢复）。
  /// 恢复后笔记标记为未同步（synced=false），触发 autoSync 上传。
  Future<void> restoreVersion(int versionId, SafeNote current) async {
    _checkNotMigrating();

    // 1. 读取版本内容（解密）
    final version = await readVersion(versionId);
    if (version == null) {
      throw Exception('Version not found: $versionId');
    }

    // 2. 保存当前内容为新版本（撤销安全网）
    await saveVersion(current);

    // 3. 将版本内容写回笔记（作为新编辑）
    final restored = current.copyWith(
      title: version.title,
      description: version.description,
      contentHash: version.contentHash,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      synced: false,
    );
    await updateNote(restored);

    Log.note.i(
      '恢复版本: note_uuid=${current.uuid} version_id=$versionId '
      'hash=${_hashBrief(version.contentHash)}',
    );
  }

  /// 删除指定笔记的所有历史版本
  ///
  /// 用于笔记硬删除（墓碑 GC）时清理版本数据。
  Future<int> deleteVersionsForNote(String noteUuid) async {
    final db = await instance.database;
    final rows = await db.delete(
      tableNoteVersions,
      where: '${NoteVersionFields.noteUuid} = ?',
      whereArgs: [noteUuid],
    );
    if (rows > 0) {
      Log.note.d('清理版本数据 uuid=$noteUuid count=$rows');
    }
    return rows;
  }

  /// FIFO 清理：超出 [kMaxVersionsPerNote] 时删除最旧版本
  Future<void> _pruneVersions(String noteUuid) async {
    final db = await instance.database;
    final countRow = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM $tableNoteVersions '
      'WHERE ${NoteVersionFields.noteUuid} = ?',
      [noteUuid],
    );
    final count = (countRow.first['c'] as int?) ?? 0;

    if (count <= kMaxVersionsPerNote) return;

    final excess = count - kMaxVersionsPerNote;
    await db.rawDelete(
      'DELETE FROM $tableNoteVersions WHERE _id IN ('
      '  SELECT _id FROM $tableNoteVersions '
      '  WHERE ${NoteVersionFields.noteUuid} = ? '
      '  ORDER BY ${NoteVersionFields.savedAt} ASC LIMIT ?'
      ')',
      [noteUuid, excess],
    );
    Log.note.d('清理旧版本 uuid=$noteUuid 删除=$excess条 保留=${count - excess}条');
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
            _notesCache![i].copyWith(
              deleted: true,
              synced: false,
              updatedAt: now,
            ),
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
        // 元数据转为墓碑（同一事务）：告知远端"这条已删"，并擦除标签明文
        await _markNoteMetaDeletedInTxn(txn, uuid);
      }
    });

    _removeCacheEntry(id: id); // 笔记被删除：从缓存移除该条目
    _removeMetaCacheEntry(uuid); // 元数据已转墓碑：从元数据缓存移除

    // 不可恢复的破坏性操作，必须留痕
    Log.note.i(
      '永久删除笔记（不可恢复）uuid=$uuid id=$id rows=$deleted，'
      '已加入 purged 列表待同步清理',
    );
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
        // 元数据转为墓碑（同一事务），理由同 hardDelete
        await _markNoteMetaDeletedInTxn(txn, uuid);
      }
    });
    if (deleted > 0) {
      _removeCacheEntry(uuid: uuid); // 笔记被删除：从缓存移除该条目
      _removeMetaCacheEntry(uuid); // 元数据已转墓碑：从元数据缓存移除
      // 清理该笔记的所有历史版本（磁盘回收）
      await deleteVersionsForNote(uuid);
      Log.note.i('永久删除笔记（GC 墓碑清理）uuid=$uuid rows=$deleted');
    }
    return deleted;
  }

  /// 批量硬删除所有软删除笔记（回收站「清空」用）
  ///
  /// 与 UI 层逐条调用 [hardDelete] 相比：读 uuid → 批量删行 → 批量追加
  /// purged 列表，全部在**单个事务**内完成，避免 N 次事务往返与
  /// 「删到一半崩溃留下中间状态」。返回删除的行数。
  Future<int> hardDeleteAllDeleted() async {
    final db = await instance.database;

    var deleted = 0;
    final removedIds = <int>[];
    final removedUuids = <String>[];
    await db.transaction((txn) async {
      final maps = await txn.query(
        tableNotes,
        columns: [NoteFields.id, NoteFields.uuid],
        where: '${NoteFields.deleted} = 1',
      );
      if (maps.isEmpty) return;
      for (final row in maps) {
        removedIds.add(row[NoteFields.id] as int);
        removedUuids.add(row[NoteFields.uuid] as String);
      }
      deleted = await txn.delete(
        tableNotes,
        where: '${NoteFields.deleted} = ?',
        whereArgs: [1],
      );
      // 删行 + 写 purged 列表同一事务（B4：防止墓碑从远端复活）
      for (final uuid in removedUuids) {
        await _addPurgedUuidInTxn(txn, uuid);
        // 元数据转为墓碑（同一事务），理由同 hardDelete
        await _markNoteMetaDeletedInTxn(txn, uuid);
      }
    });

    if (deleted > 0) {
      for (final id in removedIds) {
        _removeCacheEntry(id: id); // 笔记已删除：从缓存移除
      }
      for (final uuid in removedUuids) {
        _removeMetaCacheEntry(uuid); // 元数据已转墓碑：从元数据缓存移除
      }
      // 不可恢复的破坏性操作，必须留痕
      Log.note.w('批量永久删除笔记（回收站清空，不可恢复）rows=$deleted');
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
    final existing = maps.isNotEmpty
        ? maps.first[MetaFields.value] as String?
        : null;
    final list = _parseUuidList(existing);
    if (!list.contains(uuid)) {
      list.add(uuid);
      await txn.insert(tableMeta, {
        MetaFields.key: MetaKeys.purgedUuids,
        MetaFields.value: _serializeUuidList(list),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
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
    } on Exception catch (e) {
      // 评审 #16：purged 列表损坏时绝不静默返回空列表——
      // 否则 _mergeAndTransfer 会重新合并远端仍存在的"已硬删除"笔记，
      // 导致用户已删除的数据从远端复活。这里显式报错让同步链路中止，
      // 由上层提示用户、停止拉取，而不是带着错误的空列表继续。
      throw FormatException('MetaKeys.purgedUuids 解析失败（JSON 损坏）: $e');
    }
    throw const FormatException('MetaKeys.purgedUuids 格式错误：根节点不是 JSON 数组');
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
            _notesCache![i].copyWith(
              deleted: false,
              synced: false,
              updatedAt: now,
            ),
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

      // 2b. 用 oldKey 解出 note_meta.payload 明文。
      //     **必须与笔记一同迁移**：payload 与 title/description 用同一把
      //     dataKey，若只重加密笔记而漏掉 payload，迁移后标签将永久无法解密。
      final metaPayloads = await _readMetaPayloadsPlain(db);

      // 3. 临时切换 dataKey 为 newKey，准备加密
      _dataKey = Uint8List.fromList(newKey);

      // 4. 在内存中用 newKey 重新加密所有笔记
      //    不直接修改数据库，先收集所有要写入的行
      final encryptedRows = <Map<String, dynamic>>[];
      for (final note in notes) {
        final row = await _toEncryptedRow(note);
        // 保留 id 和 uuid 用于 UPDATE WHERE 条件
        encryptedRows.add({'where_uuid': note.uuid, 'row': row});
      }

      // 4b. 用 newKey 重新加密 note_meta.payload
      final encryptedMeta = <String, String>{};
      for (final entry in metaPayloads.entries) {
        encryptedMeta[entry.key] = await _encryptField(
          _metaAad(entry.key),
          entry.value,
        );
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
        // note_meta.payload 与笔记同事务写入：要么一起成功，要么一起回滚，
        // 不会出现「笔记已用新 key、元数据仍是旧 key」的半迁移状态。
        for (final entry in encryptedMeta.entries) {
          await txn.update(
            tableNoteMeta,
            {NoteMetaFields.payload: entry.value},
            where: '${NoteMetaFields.uuid} = ?',
            whereArgs: [entry.key],
          );
        }
      });

      _invalidateCache(); // 全库密文已更新，使解密缓存失效

      // 6. 清空版本表（首期待定项，见 docs/feature-note-version-history-design.md §8.4）
      //    版本表中的密文用 oldKey 加密，无法用 newKey 解密。
      //    首期方案：直接清空，丢弃历史版本。后续可实现 _reEncryptAllVersions。
      final deletedVersions = await db.delete(tableNoteVersions);
      if (deletedVersions > 0) {
        Log.db.w('密钥迁移: 已清空 $deletedVersions 条历史版本（旧密钥加密）');
      }

      // 7. 成功后更新 _dataKey 为 newKey（后续读写用新 key）
      _dataKey = Uint8List.fromList(newKey);

      final ms = DateTime.now().difference(startedAt).inMilliseconds;
      Log.db.i(
        '全库重加密完成: ${notes.length} 条笔记, '
        '${encryptedMeta.length} 条元数据 payload, 耗时 ${ms}ms',
      );
      return notes.length;
    } catch (e, st) {
      // 失败时恢复 _dataKey 为原始值（可能是 oldKey 或 originalDataKey）
      _dataKey = originalDataKey;
      Log.db.f('全库重加密失败，已回滚事务并恢复原 dataKey', error: e, stackTrace: st);
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
  ///      含 note_meta.payload 重加密，防止换 key 后标签永久丢失
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

      // 1b. 用 oldKey 解出 note_meta.payload 明文。
      //     **必须与笔记一同迁移**：payload 与 title/description 用同一把
      //     dataKey，若只重加密笔记而漏掉 payload，迁移后标签将永久无法解密。
      final metaPayloads = await _readMetaPayloadsPlain(db);

      // 2. 临时切换 dataKey 为 newKey，准备加密
      _dataKey = Uint8List.fromList(newKey);

      // 3. 在内存中用 newKey 重新加密所有笔记
      final encryptedRows = <Map<String, dynamic>>[];
      for (final note in notes) {
        final row = await _toEncryptedRow(note);
        encryptedRows.add({'where_uuid': note.uuid, 'row': row});
      }

      // 3b. 用 newKey 重新加密 note_meta.payload
      final encryptedMeta = <String, String>{};
      for (final entry in metaPayloads.entries) {
        encryptedMeta[entry.key] = await _encryptField(
          _metaAad(entry.key),
          entry.value,
        );
      }

      // 4. 需标记重传的 uuid（dataKey 真变时：非墓碑全部标记）
      List<String>? reuploadUuids;
      if (markBlobReupload) {
        reuploadUuids = notes
            .where((n) => !n.deleted)
            .map((n) => n.uuid)
            .toList();
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
        await txn.insert(tableMeta, {
          MetaFields.key: MetaKeys.keyring,
          MetaFields.value: keyringJson,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        if (reuploadUuids != null) {
          await txn.insert(tableMeta, {
            MetaFields.key: MetaKeys.blobReuploadPending,
            MetaFields.value: jsonEncode(reuploadUuids),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        // note_meta.payload 与笔记同事务写入：要么一起成功，要么一起回滚，
        // 不会出现「笔记已用新 key、元数据仍是旧 key」的半迁移状态。
        for (final entry in encryptedMeta.entries) {
          await txn.update(
            tableNoteMeta,
            {NoteMetaFields.payload: entry.value},
            where: '${NoteMetaFields.uuid} = ?',
            whereArgs: [entry.key],
          );
        }
      });

      _invalidateCache(); // 全库密文已更新，使解密缓存失效

      // 6. 事务成功后更新 _dataKey（后续读写用新 key）
      _dataKey = Uint8List.fromList(newKey);

      final ms = DateTime.now().difference(startedAt).inMilliseconds;
      Log.db.i(
        '原子化迁移完成: ${notes.length} 条笔记, '
        '${encryptedMeta.length} 条元数据 payload, 耗时 ${ms}ms',
      );
      return notes.length;
    } catch (e, st) {
      _dataKey = originalDataKey;
      Log.db.f('原子化迁移失败，事务已回滚并恢复原 dataKey', error: e, stackTrace: st);
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
    } on Exception catch (e) {
      Log.db.w('blobReuploadPending JSON 解析失败，返回空集合', error: e);
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
      await setMeta(
        MetaKeys.blobReuploadPending,
        jsonEncode(remaining.toList()),
      );
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
    } on Object catch (e) {
      Log.db.w('gcOrphanCandidates JSON 解析失败，返回空集合', error: e);
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
    await db.insert(tableMeta, {
      MetaFields.key: key,
      MetaFields.value: value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 读取 manifest 版本号（按 providerKey 隔离存储）
  ///
  /// [providerKey] 后端实例的唯一标识（见 SyncBackend.providerKey）。
  /// 不同后端类型、不同 URL 的 manifest version 互不影响：
  /// 切换后端时新后端读不到旧 version（默认 0，走首次同步），
  /// 切回原后端时旧 version 仍在（继续增量同步）。
  Future<int> getManifestVersion(String providerKey) async {
    final value = await getMeta(_manifestVersionKey(providerKey));
    if (value == null) return 0;
    // 评审 #16：meta 值损坏时 int.parse 抛 FormatException，会导致上层
    // 同步链路意外崩溃。这里容错降级为 0（首次同步语义）并留日志。
    final version = int.tryParse(value);
    if (version == null) {
      Log.db.w(
        'getManifestVersion: meta 值非整数（损坏），降级为 0: '
        'providerKey=$providerKey value=$value',
      );
      return 0;
    }
    return version;
  }

  /// 写入 manifest 版本号（按 providerKey 隔离存储）
  Future<void> setManifestVersion(String providerKey, int version) async {
    await setMeta(_manifestVersionKey(providerKey), version.toString());
  }

  /// 生成 manifest version 的 meta key
  static String _manifestVersionKey(String providerKey) =>
      'manifest_version:$providerKey';

  // ──────────────────────────────────────────────
  // note_meta 表 CRUD（笔记级元数据：星标/标签/归档…）
  // ──────────────────────────────────────────────
  //
  // 设计文档：docs/feature-note-meta-design.md
  //
  // 三条硬性规则（违反会造成性能倒退或数据损坏）：
  //   1. 本区块**绝不触碰** notes 表、[_notesCache]、notes.updated_at、
  //      notes.content_hash —— 元数据变更不得触发笔记正文 blob 重传。
  //   2. 元数据自己的 LWW 锚点是 note_meta.updated_at，脏标记是 synced。
  //   3. payload 是密文，日志与诊断输出**绝不打印**其内容（标签名即隐私）。

  /// note_meta.payload 的 AAD 域分隔符。
  ///
  /// 用 `meta:<uuid>` 而非裸 uuid，使元数据密文与 notes 表 title/description
  /// 的密文处于**不同 AAD 域**——即便有人把 payload 密文塞进 title 列也解不开。
  /// 与 journal 用 `journal-aad` 做域分隔同属既有模式（见 crypto.dart:368）。
  static String _metaAad(String uuid) => 'meta:$uuid';

  /// 读取全部笔记元数据（key = 笔记 uuid），命中缓存时跳过查询与解密。
  ///
  /// 只返回 `deleted=0` 的行：`deleted=1` 是墓碑（§4），仅供同步上报，
  /// 不参与 UI 展示。返回副本，调用方修改不影响缓存。
  ///
  /// 无对应行的笔记视为 [NoteMeta.defaults]（懒创建），调用方按
  /// `map[uuid] ?? NoteMeta.defaults(uuid)` 取值。
  Future<Map<String, NoteMeta>> readAllNoteMeta() async {
    final cached = _metaCache;
    if (cached != null) return Map.of(cached);

    final db = await instance.database;
    final rows = await db.query(
      tableNoteMeta,
      where: '${NoteMetaFields.deleted} = 0',
    );

    final map = <String, NoteMeta>{};
    for (final row in rows) {
      final meta = await _decodeMetaRow(row);
      if (meta != null) map[meta.uuid] = meta;
    }
    _metaCache = map;
    Log.db.i('加载笔记元数据: ${map.length} 条');
    return Map.of(map);
  }

  /// 读取单条笔记元数据；无记录时返回 null（调用方自行退化为默认值）。
  Future<NoteMeta?> getNoteMeta(String uuid) async {
    final cached = _metaCache;
    if (cached != null) return cached[uuid];

    final db = await instance.database;
    final rows = await db.query(
      tableNoteMeta,
      where: '${NoteMetaFields.uuid} = ? AND ${NoteMetaFields.deleted} = 0',
      whereArgs: [uuid],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _decodeMetaRow(rows.first);
  }

  /// 解密并解析一行 note_meta；整行不可用时返回 null。
  ///
  /// **容错优先**：payload 解密/解析失败只降级为"无 payload"（保留 pinned
  /// 等明文列）并留警告日志，**不抛异常**。元数据永远是次要数据，单行损坏
  /// 不该让笔记列表加载失败——对比 purgedUuids 整个 JSON 损坏就中止整条
  /// 同步链路的旧缺陷（设计文档 §4.1），这里刻意选择相反的取舍。
  Future<NoteMeta?> _decodeMetaRow(Map<String, dynamic> row) async {
    final uuid = row[NoteMetaFields.uuid] as String?;
    if (uuid == null || uuid.isEmpty) {
      Log.db.w('note_meta 行缺少 uuid，跳过');
      return null;
    }

    final encrypted = row[NoteMetaFields.payload] as String?;
    String? plaintext;
    if (encrypted != null && encrypted.isNotEmpty) {
      try {
        plaintext = await _decryptField(_metaAad(uuid), encrypted);
      } on Object catch (e) {
        // 不打印 payload 内容，只记 uuid 与异常类型
        Log.db.w('note_meta payload 解密失败，降级为空 payload: uuid=$uuid ($e)');
        plaintext = null;
      }
    }
    return NoteMeta.fromRow(row, decryptedPayload: plaintext);
  }

  /// 写入笔记元数据（按 uuid upsert），并同步更新 [_metaCache]。
  ///
  /// 调用方负责设置 [NoteMeta.updatedAt] 与 [NoteMeta.synced]；
  /// 便捷方法 [setNotePinned] / [setNoteTags] 已代为处理。
  ///
  /// **不碰 notes 表与 [_notesCache]**（本区块规则 1）。
  Future<NoteMeta> upsertNoteMeta(NoteMeta meta) async {
    final db = await instance.database;

    final plaintext = meta.encodePayload();
    final encrypted = (plaintext == null || plaintext.isEmpty)
        ? null
        : await _encryptField(_metaAad(meta.uuid), plaintext);

    // id 由 AUTOINCREMENT 分配；replace 在 uuid 冲突时删旧行插新行，
    // 故不带入旧 id（id 无外部语义，仅供诊断）。
    final row = meta.copyWith(id: null).toRow(encryptedPayload: encrypted);
    row.remove(NoteMetaFields.id);
    await db.insert(
      tableNoteMeta,
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    _upsertMetaCacheEntry(meta);
    Log.db.i(
      'note_meta 已写入: uuid=${meta.uuid} pinned=${meta.pinned} '
      'tags=${meta.tags.length} updatedAt=${meta.updatedAt}',
    );
    return meta;
  }

  /// 更新 [_metaCache] 单个 entry（墓碑行从缓存移除）。
  void _upsertMetaCacheEntry(NoteMeta meta) {
    final cache = _metaCache;
    if (cache == null) return; // 缓存未建：下次读取自然重建（已含本条）
    if (meta.deleted) {
      cache.remove(meta.uuid);
    } else {
      cache[meta.uuid] = meta;
    }
  }

  /// 设置星标/置顶，返回写入后的元数据。
  ///
  /// 星标与置顶在本项目是**同一概念**（`pinned`）：置顶影响首页排序，
  /// 侧栏「仅看星标」按同一字段过滤。
  Future<NoteMeta> setNotePinned(String uuid, bool pinned) async {
    final current = await getNoteMeta(uuid) ?? NoteMeta.defaults(uuid);
    return upsertNoteMeta(
      current.copyWith(
        uuid: uuid,
        pinned: pinned,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        synced: false, // 待上传（阶段 4 的 items.meta 同步消费）
      ),
    );
  }

  /// 设置锁定（只读）标记，返回写入后的元数据。
  ///
  /// 与 [setNotePinned] 同构：只写 note_meta，不动笔记正文与 `updated_at`。
  Future<NoteMeta> setNoteLocked(String uuid, bool locked) async {
    final current = await getNoteMeta(uuid) ?? NoteMeta.defaults(uuid);
    return upsertNoteMeta(
      current.copyWith(
        uuid: uuid,
        locked: locked,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        synced: false,
      ),
    );
  }

  /// 设置标签（自动规范化：去空白 / 丢空串 / 去重），返回写入后的元数据。
  Future<NoteMeta> setNoteTags(String uuid, Iterable<String> tags) async {
    final current = await getNoteMeta(uuid) ?? NoteMeta.defaults(uuid);
    return upsertNoteMeta(
      current.copyWith(
        uuid: uuid,
        tags: NoteMeta.normalizeTags(tags),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        synced: false,
      ),
    );
  }

  /// 聚合全部已使用过的标签（去重后按字母序）。
  ///
  /// 供侧栏「按标签过滤」的标签选择列表使用。标签在 payload 内加密，
  /// SQL 无法反查，故只能内存聚合——当前架构下不是问题（全量行已在缓存）。
  Future<List<String>> readAllTags() async {
    final metas = await readAllNoteMeta();
    final tags = <String>{};
    for (final meta in metas.values) {
      tags.addAll(meta.tags);
    }
    final sorted = tags.toList()..sort();
    return sorted;
  }

  /// 事务版：写入元数据墓碑（供 hardDelete* 在同一事务内调用）。
  ///
  /// 与 [_addPurgedUuidInTxn] 同处一个事务：删行与写墓碑要么同时成功、
  /// 要么同时回滚，堵住「笔记已删但墓碑未写」导致远端复活的窗口。
  ///
  /// 墓碑行 payload 置 NULL——**顺带彻底擦除该笔记的标签明文**，
  /// 永久删除的笔记不该在本地留下任何用户输入文本。
  ///
  /// 注意：本方法**不更新** [_metaCache]（事务可能回滚）。
  /// 缓存由调用方在事务成功后经 [_removeMetaCacheEntry] 清理。
  Future<void> _markNoteMetaDeletedInTxn(Transaction txn, String uuid) async {
    await txn.insert(tableNoteMeta, {
      NoteMetaFields.uuid: uuid,
      NoteMetaFields.pinned: 0,
      NoteMetaFields.locked: 0,
      NoteMetaFields.archived: 0,
      NoteMetaFields.color: null,
      NoteMetaFields.deleted: 1,
      NoteMetaFields.payload: null,
      NoteMetaFields.updatedAt: DateTime.now().millisecondsSinceEpoch,
      NoteMetaFields.synced: 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 从 [_metaCache] 移除条目（笔记被硬删除后调用）。
  void _removeMetaCacheEntry(String uuid) => _metaCache?.remove(uuid);

  /// 用**当前** dataKey 解出所有非空 payload 的明文（uuid → payload 明文）。
  ///
  /// 仅供 [reEncryptAllNotes] 的 dataKey 迁移使用：迁移必须同时覆盖
  /// note_meta.payload，否则换 key 后标签永久无法解密。
  ///
  /// 含墓碑行（墓碑 payload 为 NULL，天然被 `IS NOT NULL` 过滤掉）。
  /// 解密失败的行**跳过**——留着旧密文不动，避免用新 key 覆盖出
  /// 二次损坏；只记警告，不中断迁移（笔记正文迁移优先级更高）。
  Future<Map<String, String>> _readMetaPayloadsPlain(Database db) async {
    final rows = await db.query(
      tableNoteMeta,
      columns: [NoteMetaFields.uuid, NoteMetaFields.payload],
      where: '${NoteMetaFields.payload} IS NOT NULL',
    );

    final out = <String, String>{};
    for (final row in rows) {
      final uuid = row[NoteMetaFields.uuid] as String?;
      final encrypted = row[NoteMetaFields.payload] as String?;
      if (uuid == null || uuid.isEmpty) continue;
      if (encrypted == null || encrypted.isEmpty) continue;
      try {
        out[uuid] = await _decryptField(_metaAad(uuid), encrypted);
      } on Object catch (e) {
        Log.db.w('note_meta payload 解密失败，迁移时跳过该行: uuid=$uuid ($e)');
      }
    }
    return out;
  }

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

  /// 返回当前数据库文件的绝对路径（不打开连接）
  ///
  /// 供重置（忘记密码逃生通道）前做文件级快照备份使用。
  /// 路径解析优先级与 [deleteDbFile] 一致：dbPathOverride / factory.getDatabasesPath。
  Future<String> dbFilePath() async {
    final factory = dbFactoryOverride ?? databaseFactory;
    final dbPath = dbPathOverride ?? await factory.getDatabasesPath();
    return join(dbPath, 'safenotes_sync.db');
  }

  /// 删除 db 文件（忘记密码逃生通道使用）
  ///
  /// 必须先调用 [close] 关闭数据库连接,否则文件锁占用无法删除。
  /// 删除后 _database 置为 null,下次访问 database getter 会重新创建空 db。
  /// 同时清除 _dataKey,避免残留内存中的旧密钥。
  Future<void> deleteDbFile() async {
    final factory = dbFactoryOverride ?? databaseFactory;
    final dbPath = dbPathOverride ?? await factory.getDatabasesPath();
    final path = join(dbPath, 'safenotes_sync.db');
    // 不可逆的全量数据销毁（忘记密码逃生通道），必须以 FATAL 级别留痕
    Log.db.f('⚠ 删除数据库文件（所有本地笔记将永久丢失）: $path');
    try {
      await factory.deleteDatabase(path);
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
