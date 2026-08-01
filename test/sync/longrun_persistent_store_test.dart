// 长期存续测试（真实数据库 / 跨运行复用 / 永不清理）
//
// ─────────────────────────────────────────────────────────────────────────
// 为什么需要这个测试（与 chaos 的根本差别）
// ─────────────────────────────────────────────────────────────────────────
//   chaos   : 每次 setUp 建新库、tearDown 删干净 → 只能证明「单次会话内不出错」
//   longrun : 客户端 DB + 服务端目录 **跨进程、跨运行持续累积**，模拟真实用户
//             「装上就再也不删数据」的使用方式 → 只有长期存续才会暴露的问题：
//               · 本地 keyring 账本反复 unlockLocal / 改密后是否退化
//               · manifest 墓碑无限增长、老条目被悄悄挤掉
//               · journal 归档滚动 + seq 水位能否跨进程续接（远端副本时序才有效）
//               · 孤儿 blob 隔离区是否无界膨胀
//               · 历史笔记密文经过多轮密钥轮换后是否仍能解出原文（静默腐坏）
//
// ─────────────────────────────────────────────────────────────────────────
// 用法
// ─────────────────────────────────────────────────────────────────────────
//   flutter test test/sync/longrun_persistent_store_test.dart      # 在既有数据上追加 1 代
//   LONGRUN_GENS=5 flutter test test/sync/longrun_persistent_store_test.dart
//   LONGRUN_RESET=1 flutter test test/sync/longrun_persistent_store_test.dart   # 清空重来
//
// 数据落在 temp/longrun-store/，**测试结束不清理**，下次运行接着用。
// 每一代结束都会把「本代应当存在的全部笔记 uuid → contentHash」写进 state.json，
// 下一次运行（可能是几天后的另一个进程）会拿它当账本逐条核对，
// 因此「上一轮写进去的数据这一轮还在不在、内容有没有被改烂」是被真正锁死的。
//
// 断言的不变量（每代结束都查一遍）：
//   I1 收敛一致  ：三端 live 集合（uuid→hash）完全相同
//   I2 历史不丢  ：账本里所有未删 uuid 在每端都在，且 hash == 账本记录值
//   I3 墓碑保留  ：账本里删过的 uuid 仍以 deleted=true 留在 manifest（不许静默消失）
//   I4 引用完整  ：manifest 每个非墓碑条目的 blob 在远端真实存在（无悬挂引用）
//   I5 GC 有效  ：blobs/ 文件数 == manifest 非墓碑条目去重 hash 数（孤儿被隔离走）
//   I6 水位不退  ：每端 journal.nextSeq >= 上一代记录值（跨进程续接）
//   I7 密钥自洽  ：每端 keyVersion == 远端 header.keyVersion
//   I8 明文自洽  ：每条笔记 computeHash(title, desc) == contentHash（抓静默腐坏）

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:safenotes/data/database_handler.dart';
import 'package:safenotes/models/safenote.dart';
import 'package:safenotes/sync/journal.dart';
import 'package:safenotes/sync/keyring.dart';
import 'package:safenotes/sync/local_fs_backend.dart';
import 'package:safenotes/sync/sync_engine.dart';
import 'package:safenotes/sync/sync_models.dart';

// ──────────────────────────────────────────────
// 常量
// ──────────────────────────────────────────────

/// 持久化存储根目录（项目内 temp/longrun-store，跨运行复用，绝不清理）
const String kStoreRootRel = 'temp/longrun-store';

/// 模拟的设备数（手机 / 平板 / 桌面）
const List<String> kDeviceIds = ['A', 'B', 'C'];

/// state.json 结构版本；不匹配时自动重置（避免旧账本误判为数据丢失）
const int kStateSchema = 1;

/// 初始密码（后续按代轮换，真实密码记录在 state.json 里）
const String kInitialPassword = 'longrun-pw-gen0';

// ──────────────────────────────────────────────
// 跨运行账本
// ──────────────────────────────────────────────

/// 跨运行持久化的「期望值账本」。
///
/// 这是长期测试的核心：它把「上一次运行结束时数据应该长什么样」写在磁盘上，
/// 下一次运行（另一个进程）据此核对。没有它，跨运行的数据丢失/腐坏无法被发现。
class LongRunState {
  LongRunState({
    required this.generation,
    required this.password,
    required this.vaultId,
    required this.createdAt,
    required this.notes,
    required this.deleted,
    required this.journalSeq,
    required this.history,
  });

  /// 已完成的代数（第 N 次「用户使用日」）
  int generation;

  /// 当前密码（改密后更新）
  String password;

  String vaultId;

  /// 存储首次创建时间（Unix 毫秒）
  int createdAt;

  /// 活跃笔记账本：uuid → {title, hash}
  Map<String, NoteFact> notes;

  /// 已删除笔记 uuid（墓碑应长期保留）
  Set<String> deleted;

  /// 各端 journal 水位：deviceId → nextSeq
  Map<String, int> journalSeq;

  /// 每代的规模指标（用于观察长期增长趋势）
  List<Map<String, Object?>> history;

  static LongRunState fresh() => LongRunState(
        generation: 0,
        password: kInitialPassword,
        vaultId: '',
        createdAt: DateTime.now().millisecondsSinceEpoch,
        notes: <String, NoteFact>{},
        deleted: <String>{},
        journalSeq: <String, int>{},
        history: <Map<String, Object?>>[],
      );

  Map<String, Object?> toJson() => {
        'schema': kStateSchema,
        'generation': generation,
        'password': password,
        'vaultId': vaultId,
        'createdAt': createdAt,
        'notes': notes.map((k, v) => MapEntry(k, v.toJson())),
        'deleted': deleted.toList()..sort(),
        'journalSeq': journalSeq,
        'history': history,
      };

  /// 解析账本；结构版本不符或字段损坏时返回 null（调用方视为需要重置）
  static LongRunState? tryParse(String raw) {
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      if (m['schema'] != kStateSchema) return null;
      final notesRaw = (m['notes'] as Map).cast<String, dynamic>();
      return LongRunState(
        generation: m['generation'] as int,
        password: m['password'] as String,
        vaultId: m['vaultId'] as String,
        createdAt: m['createdAt'] as int,
        notes: notesRaw.map(
          (k, v) => MapEntry(k, NoteFact.fromJson((v as Map).cast<String, dynamic>())),
        ),
        deleted: (m['deleted'] as List).map((e) => e as String).toSet(),
        journalSeq: (m['journalSeq'] as Map).cast<String, dynamic>().map(
              (k, v) => MapEntry(k, v as int),
            ),
        history: (m['history'] as List)
            .map((e) => (e as Map).cast<String, Object?>())
            .toList(),
      );
    } catch (_) {
      return null;
    }
  }
}

/// 账本中一条笔记的期望事实
class NoteFact {
  NoteFact(this.title, this.hash);
  final String title;
  final String hash;

  Map<String, Object?> toJson() => {'title': title, 'hash': hash};

  static NoteFact fromJson(Map<String, dynamic> j) =>
      NoteFact(j['title'] as String, j['hash'] as String);
}

// ──────────────────────────────────────────────
// 客户端
// ──────────────────────────────────────────────

class LongRunClient {
  LongRunClient({
    required this.id,
    required this.db,
    required this.keyring,
    required this.engine,
    required this.journal,
    required this.journalBaseDir,
  });

  final String id;
  final Database db;
  Keyring keyring;
  SyncEngine engine;
  Journal journal;
  final String journalBaseDir;
}

// ──────────────────────────────────────────────
// 存储
// ──────────────────────────────────────────────

class LongRunStore {
  LongRunStore(this.rootPath);

  final String rootPath;
  late LongRunState state;
  late LocalFsBackend backend;
  final List<LongRunClient> clients = <LongRunClient>[];

  /// 本次运行是否是「全新创建」（决定断言口径：全新时账本为空，不做历史核对）
  bool freshlyCreated = false;

  String get vaultDir => p.join(rootPath, 'vault');
  String get statePath => p.join(rootPath, 'state.json');
  String _dbPath(String id) => p.join(rootPath, 'client-$id.db');
  String journalBase(String id) => p.join(rootPath, 'journal-$id');

  Directory get blobsDir => Directory(p.join(vaultDir, 'blobs'));

  Uint8List get dataKey => clients.first.keyring.dataKey;

  /// 打开（或首次创建）持久化存储。
  ///
  /// 首次：创建 keyring + 上传空 manifest + 建三个空客户端库。
  /// 后续：**走真实 App 冷启动路径** —— 打开磁盘上的老库，用密码 `unlockLocal`
  /// 从本地 keyring 账本恢复 dataKey。这条路径是 P2 Scheme B 的核心承诺
  /// （Keyring 是密钥态唯一真相源），只有跨进程复用老库才能真正验证它。
  Future<void> open({required bool reset}) async {
    final rootDir = Directory(rootPath);
    if (reset && rootDir.existsSync()) {
      await rootDir.delete(recursive: true);
    }
    await rootDir.create(recursive: true);

    // 1. 读账本（损坏/版本不符 → 视为全新，但**不删已有数据目录**，
    //    避免误判导致真实数据被清掉；由断言口径退化为「只查本代」）
    final stateFile = File(statePath);
    LongRunState? loaded;
    if (stateFile.existsSync()) {
      loaded = LongRunState.tryParse(await stateFile.readAsString());
      if (loaded == null) {
        // ignore: avoid_print
        print('WARN: state.json 无法解析或结构版本不符，本次按全新账本处理');
      }
    }
    state = loaded ?? LongRunState.fresh();

    backend = LocalFsBackend(rootPath: vaultDir);
    await backend.init();

    final manifestExists = File(p.join(vaultDir, 'manifest.json')).existsSync();
    final dbExists = File(_dbPath(kDeviceIds.first)).existsSync();
    freshlyCreated = !manifestExists || !dbExists;

    if (freshlyCreated) {
      await _createFromScratch();
    } else {
      await _reopenExisting();
    }
  }

  /// 首次创建：建库者生成 keyring → 上传空 manifest → 三端各自入网
  Future<void> _createFromScratch() async {
    final creatorDb = await _openDb(p.join(rootPath, 'creator.db'));
    NotesDatabase.setDatabaseForTesting(creatorDb);
    final created = await Keyring.createNew(
      password: state.password,
      database: NotesDatabase.instance,
    );
    state.vaultId = created.vaultId;
    await _uploadEmptyManifest(created);
    await creatorDb.close();

    for (final id in kDeviceIds) {
      final db = await _openDb(_dbPath(id));
      NotesDatabase.setDatabaseForTesting(db);
      final keyring = await _unlockFromRemote(state.password);
      clients.add(await _mountClient(id, db, keyring));
    }
  }

  /// 复用既有数据：冷启动打开老库 + unlockLocal
  Future<void> _reopenExisting() async {
    for (final id in kDeviceIds) {
      final db = await _openDb(_dbPath(id));
      NotesDatabase.setDatabaseForTesting(db);

      Keyring keyring;
      try {
        // 真实 App 冷启动路径：本地账本 + 密码 → dataKey
        keyring = await Keyring.unlockLocal(
          password: state.password,
          database: NotesDatabase.instance,
        );
      } on KeyringNotInitializedException {
        // 该端还没入过网（例如上次运行中途新增设备），退化为新设备入网
        keyring = await _unlockFromRemote(state.password);
      }
      clients.add(await _mountClient(id, db, keyring));
    }
  }

  Future<LongRunClient> _mountClient(
    String id,
    Database db,
    Keyring keyring,
  ) async {
    final jBase = journalBase(id);
    final journal = await Journal.open(
      baseDir: jBase,
      vaultId: keyring.vaultId,
      deviceId: id,
    );
    return LongRunClient(
      id: id,
      db: db,
      keyring: keyring,
      engine: _buildEngine(keyring, id, journal),
      journal: journal,
      journalBaseDir: jBase,
    );
  }

  SyncEngine _buildEngine(Keyring keyring, String deviceId, Journal journal) =>
      SyncEngine(
        backend: backend,
        database: NotesDatabase.instance,
        keyring: keyring,
        deviceId: deviceId,
        journal: journal,
      );

  // version 3：跨运行复用的文件库可能是旧 schema（version 2，无 synced_hash），
  // 挂上 onUpgrade 走 v2 → v3 加列 + 回填迁移，保留历史数据、避免 no such column。
  Future<Database> _openDb(String path) => openDatabase(
        path,
        version: 3,
        onCreate: NotesDatabase.createDBForTesting,
        onUpgrade: NotesDatabase.upgradeDBForTesting,
      );

  Future<Keyring> _unlockFromRemote(String pw) async {
    final resp = await backend.getManifest();
    final header = ManifestCrypto.deserializeHeaderOnly(resp.ciphertext);
    return Keyring.unlockFromRemoteManifest(
      password: pw,
      remoteVaultId: header.vaultId,
      remoteEncryptedDataKey: header.encryptedDataKey,
      remoteKdf: header.kdf,
      remoteKeyFingerprint: header.keyFingerprint,
      remoteKeyVersion: header.keyVersion,
      remoteDataKeyEpoch: header.dataKeyEpoch,
      remoteCreatedAt: header.createdAt,
      database: NotesDatabase.instance,
    );
  }

  Future<void> _uploadEmptyManifest(Keyring keyring) async {
    final header = ManifestHeader(
      schemaVersion: 1,
      version: 1,
      vaultId: keyring.vaultId,
      createdAt: keyring.createdAt,
      updatedAt: keyring.createdAt,
      keyFingerprint: keyring.keyFingerprint,
      keyVersion: keyring.keyVersion,
      encryptedDataKey: keyring.encryptedDataKey,
      kdf: keyring.kdf,
      dataKeyWrap: 'AES-256-GCM',
      lastModifiedBy: 'longrun-seed',
    );
    final manifest = Manifest(header: header, items: <String, ManifestItem>{});
    await backend.putManifest(
      ManifestCrypto.serialize(keyring.dataKey, manifest),
      '',
    );
  }

  // ── 客户端操作 ──────────────────────────────

  void activate(LongRunClient c) {
    NotesDatabase.setDatabaseForTesting(c.db);
    NotesDatabase.instance.setDataKey(c.keyring.dataKey);
  }

  Future<SyncResult> sync(LongRunClient c) async {
    activate(c);
    return c.engine.sync();
  }

  Future<SafeNote> createNote(LongRunClient c, String title, String desc) async {
    activate(c);
    final note = SafeNote.create(title: title, description: desc);
    await NotesDatabase.instance.storeNote(note);
    return note;
  }

  /// 读取某端的活跃笔记：uuid → 笔记对象
  Future<Map<String, SafeNote>> liveNotes(LongRunClient c) async {
    activate(c);
    final notes = await NotesDatabase.instance.readAllNotes();
    return {for (final n in notes) n.uuid: n};
  }

  /// 模拟 App 被杀后重启：关 journal → 同目录重开 → 重建引擎
  Future<void> restart(LongRunClient c) async {
    await c.journal.close();
    c.journal = await Journal.open(
      baseDir: c.journalBaseDir,
      vaultId: c.keyring.vaultId,
      deviceId: c.id,
    );
    activate(c);
    c.engine = _buildEngine(c.keyring, c.id, c.journal);
  }

  /// 让全部端来回同步至收敛
  Future<void> converge({int rounds = 2}) async {
    for (var i = 0; i < rounds; i++) {
      for (final c in clients) {
        await sync(c);
      }
    }
  }

  /// 读远端 manifest（解密 items）
  Future<Manifest> remoteManifest() async {
    final resp = await backend.getManifest();
    return ManifestCrypto.deserialize(dataKey, resp.ciphertext);
  }

  Future<ManifestHeader> remoteHeader() async {
    final resp = await backend.getManifest();
    return ManifestCrypto.deserializeHeaderOnly(resp.ciphertext);
  }

  /// 落盘账本 + 关闭资源（**只关不删**，下次运行继续用）
  Future<void> persistAndClose() async {
    await File(statePath).writeAsString(
      const JsonEncoder.withIndent('  ').convert(state.toJson()),
    );
    for (final c in clients) {
      try {
        await c.journal.close();
      } catch (_) {}
      try {
        await c.db.close();
      } catch (_) {}
    }
    clients.clear();
  }
}

// ──────────────────────────────────────────────
// 主测试
// ──────────────────────────────────────────────

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('长期存续 - 真实数据库跨运行累积（永不清理）', () async {
    final reset = Platform.environment['LONGRUN_RESET'] == '1';
    final gens = int.tryParse(Platform.environment['LONGRUN_GENS'] ?? '') ?? 1;

    final store = LongRunStore(p.join(Directory.current.path, kStoreRootRel));
    await store.open(reset: reset);

    // ignore: avoid_print
    print('=== 长期存续测试 ===');
    // ignore: avoid_print
    print('存储目录 : ${store.rootPath}');
    // ignore: avoid_print
    print('起始代数 : ${store.state.generation}'
        '${store.freshlyCreated ? "（全新创建）" : "（复用既有数据）"}');
    // ignore: avoid_print
    print('账本笔记 : 活跃 ${store.state.notes.length} 条 / 墓碑 ${store.state.deleted.length} 条');

    try {
      // 复用既有数据时：先做**冷启动对账**，吸收「进程被杀 / 崩溃 / 断电」等极端故障
      // 后账本落后于真实数据的遗留笔记（笔记已落盘 + 同步，但 state.json 未持久化）。
      // 这是长期测试刻意模拟极端场景后的自愈——只补登「账本既不记也不墓碑」的笔记，
      // 绝不掩盖真正的 resurrection（账本标墓碑却本地复活）或 data-loss（账本有却本地丢）bug。
      if (!store.freshlyCreated) {
        // 崩溃/断电/网络中断后先同步一次，使本地库与 manifest 对齐
        // （下载崩溃前已上传、但本端尚未落地的笔记），再对账吸收崩溃遗留。
        await store.converge(rounds: 1);
        await _reconcileLedgerWithLocal(store, scene: '冷启动对账');
      }
      // 复用既有数据时：再做一次**开机自检**，
      // 验证「上次运行结束后原样躺在磁盘上的数据」现在还读得出来。
      // 这一步先于任何本次写入，否则新写入会掩盖旧数据的损坏。
      if (!store.freshlyCreated && store.state.notes.isNotEmpty) {
        await _assertColdStartIntegrity(store);
        // ignore: avoid_print
        print('冷启动自检 : 通过（${store.state.notes.length} 条历史笔记全部可解密且哈希自洽）');
      }

      for (var i = 0; i < gens; i++) {
        final gen = store.state.generation + 1;
        await _runGeneration(store, gen);
        store.state.generation = gen;
      }
    } finally {
      // 无论断言是否失败都要落盘并关句柄：
      // 失败时保留现场（数据不清），下次运行可直接在同一份数据上复现。
      await store.persistAndClose();
    }

    _printGrowthTable(store.state);
  }, timeout: const Timeout(Duration(minutes: 30)));
}

// ──────────────────────────────────────────────
// 冷启动自检
// ──────────────────────────────────────────────

/// 复用既有数据时的开机自检：本次一个字节都还没写，先证明旧数据完好。
///
/// 查三件事：
///   1. 每端都能用账本里的密码打开老库（keyring 账本没退化）——open() 已隐含验证
///   2. 账本里的活跃笔记在每端都在，且 title/hash 与上次记录逐字节一致
///   3. 每条笔记 computeHash(title, desc) == contentHash（密文没被改烂）
Future<void> _assertColdStartIntegrity(LongRunStore store) async {
  for (final c in store.clients) {
    final live = await store.liveNotes(c);
    for (final entry in store.state.notes.entries) {
      final uuid = entry.key;
      final fact = entry.value;
      final n = live[uuid];
      expect(n, isNotNull,
          reason: '冷启动自检失败：客户端 ${c.id} 丢失历史笔记 $uuid '
              '(title=${fact.title})。上次运行结束时它还在账本里。');
      expect(n!.title, fact.title,
          reason: '冷启动自检失败：客户端 ${c.id} 的 $uuid 标题被改动');
      expect(n.contentHash, fact.hash,
          reason: '冷启动自检失败：客户端 ${c.id} 的 $uuid 内容哈希与账本不符（静默腐坏）');
      expect(SafeNote.computeHash(n.title, n.description), n.contentHash,
          reason: '冷启动自检失败：客户端 ${c.id} 的 $uuid 明文与自身哈希不自洽');
    }
  }
}

/// 冷启动对账：进程被杀 / 崩溃 / 断电后，账本 `state.json` 可能落后于真实数据——
/// 某代跑到一半被 killed，`_runGeneration` 里 step7 的账本更新与 `persistAndClose`
/// 都没跑，但该代创建的笔记已经落盘并同步到 manifest / 各端。下一次运行会发现这些
/// 笔记「活跃但不在账本」→ 被幽灵数据断言误判为生产缺陷。
///
/// 这里把它们补登到账本，使测试能从崩溃中自愈、继续长期累积。关键安全边界：
///   · 只补登「**账本 notes 没有、且 deleted 也没有**」的笔记（真正的崩溃遗留）；
///   · 若某笔记「账本标记为 deleted，但本地仍是活跃」→ 那是 resurrection bug，
///     不补登，幽灵数据断言会照常失败（不掩盖真实缺陷）；
///   · 若某笔记「账本 notes 有，但本地已无」→ 那是 data-loss bug，I2 断言会失败。
///
/// 同一套逻辑也用于**每代结束时**的对账：同步引擎在「同一 uuid 两端离线分叉且内容
/// 冲突」时，会把败方另存为新 uuid 的冲突副本（conflict-copy，见 sync_engine.dart
/// `_resolveConflict` 之后的分支）——这是「绝不静默丢数据」原则下的正确行为，但账本
/// 无从预知这些新 uuid。补登它们，才不会把保数据机制误判成幽灵数据。
///
/// 正常（无崩溃、无冲突）运行时本地与账本一致，本函数是无操作，不影响任何既有不变量。
Future<void> _reconcileLedgerWithLocal(LongRunStore store,
    {required String scene}) async {
  var patched = 0;
  final absorbed = <String>[];
  for (final c in store.clients) {
    store.activate(c);
    final all = await NotesDatabase.instance.readAllNotesIncludingDeleted();
    for (final n in all) {
      if (n.deleted) {
        // 本地已软删但账本未记 → 补登为墓碑，避免 I3 误报
        if (!store.state.deleted.contains(n.uuid)) {
          store.state.deleted.add(n.uuid);
          patched++;
        }
      } else {
        // 本地活跃且账本既不记也不墓碑 → 崩溃遗留，补登（保留数据，不丢）
        if (!store.state.notes.containsKey(n.uuid) &&
            !store.state.deleted.contains(n.uuid)) {
          store.state.notes[n.uuid] = NoteFact(n.title, n.contentHash);
          absorbed.add('${c.id}/${n.uuid.substring(0, 8)}/${n.title}');
          patched++;
        }
      }
    }
  }
  if (patched > 0) {
    // ignore: avoid_print
    print('$scene : 吸收 $patched 条账本外记录（账本已自愈，数据一条未删）'
        '${absorbed.isEmpty ? "" : " → $absorbed"}');
  }
}

// ──────────────────────────────────────────────
// 一「代」= 模拟用户一天的使用
// ──────────────────────────────────────────────

Future<void> _runGeneration(LongRunStore store, int gen) async {
  // 种子固定 → 同一代的操作序列可复现
  final rng = Random(0x10AC * gen + 7);
  final a = store.clients[0];
  final b = store.clients[1];
  final c = store.clients[2];

  // ── 1. A 端新建 2 条并同步 ──────────────────
  final created = <SafeNote>[];
  for (var k = 0; k < 2; k++) {
    final title = 'g$gen-n$k-${rng.nextInt(1 << 20)}';
    created.add(await store.createNote(a, title, 'body of $title'));
  }
  await store.sync(a);

  // ── 2. B 端拉取后编辑一条历史笔记 ────────────
  await store.sync(b);
  String? editedUuid;
  {
    final live = await store.liveNotes(b);
    if (live.isNotEmpty) {
      final uuids = live.keys.toList()..sort();
      final target = live[uuids[rng.nextInt(uuids.length)]]!;
      final newTitle = 'g$gen-edit-${rng.nextInt(1 << 20)}';
      final newDesc = 'edited at gen $gen';
      await NotesDatabase.instance.updateNoteByUuid(
        target.copyWith(
          title: newTitle,
          description: newDesc,
          contentHash: SafeNote.computeHash(newTitle, newDesc),
          updatedAt: DateTime.now().millisecondsSinceEpoch,
          synced: false,
        ),
      );
      editedUuid = target.uuid;
    }
  }
  await store.sync(b);

  // ── 3. C 端每 2 代删一条（真实用户偶尔才删） ──
  await store.sync(c);
  String? deletedUuid;
  if (gen % 2 == 0) {
    final live = await store.liveNotes(c);
    // 保留一定存量，避免长期测试把库删空后失去「历史数据」的检验意义
    if (live.length > 4) {
      final uuids = live.keys.toList()..sort();
      final victim = live[uuids[rng.nextInt(uuids.length)]]!;
      // 不删本代刚编辑的那条，避免断言口径互相纠缠
      if (victim.uuid != editedUuid) {
        await NotesDatabase.instance.softDelete(victim.id!);
        deletedUuid = victim.uuid;
      }
    }
  }
  await store.sync(c);

  // ── 4. 每 3 代改一次密码（A 端发起，其余端输新密码跟进） ──
  if (gen % 3 == 0) {
    await store.sync(a);
    final newPw = 'longrun-pw-gen$gen';
    store.activate(a);
    final newKeyring = await a.keyring.changePassword(
      oldPassword: store.state.password,
      newPassword: newPw,
      database: NotesDatabase.instance,
    );
    a.keyring = newKeyring;
    a.engine.keyring = newKeyring;
    await store.sync(a);

    // 其余端：模拟用户在另一台设备上输入新密码
    for (final other in [b, c]) {
      store.activate(other);
      final k = await store._unlockFromRemote(newPw);
      other.keyring = k;
      other.engine = store._buildEngine(k, other.id, other.journal);
    }
    store.state.password = newPw;
  }

  // ── 5. 每 4 代模拟一次全端重启（journal 水位必须续得上） ──
  if (gen % 4 == 0) {
    for (final cl in store.clients) {
      final before = cl.journal.nextSeq;
      await store.restart(cl);
      expect(cl.journal.nextSeq, greaterThanOrEqualTo(before),
          reason: '重启后 ${cl.id} 的 journal seq 回退了，远端副本时序会错乱');
    }
  }

  // ── 6. 收敛 ────────────────────────────────
  await store.converge(rounds: 2);

  // ── 7. 更新账本（先记本代变更，再统一核对） ──
  for (final n in created) {
    store.state.notes[n.uuid] = NoteFact(n.title, n.contentHash);
  }
  if (editedUuid != null) {
    // 编辑后的真值以 B 端落库结果为准（LWW 已收敛）
    final live = await store.liveNotes(b);
    final n = live[editedUuid];
    if (n != null) {
      store.state.notes[editedUuid] = NoteFact(n.title, n.contentHash);
    }
  }
  if (deletedUuid != null) {
    store.state.notes.remove(deletedUuid);
    store.state.deleted.add(deletedUuid);
  }

  // 本代对账：吸收冲突副本（conflict-copy）等「保数据」机制产生的新 uuid 笔记。
  // 注意顺序——必须在账本更新之后、不变量核对之前，且不会掩盖 resurrection /
  // data-loss 两类真缺陷（详见 _reconcileLedgerWithLocal 的安全边界说明）。
  await _reconcileLedgerWithLocal(store, scene: 'gen $gen 本代对账');

  // ── 8. 不变量核对 ──────────────────────────
  await _assertInvariants(store, gen);

  // ── 9. 记录本代规模指标 ────────────────────
  final metrics = await _collectMetrics(store, gen);
  store.state.history.add(metrics);
  for (final cl in store.clients) {
    store.state.journalSeq[cl.id] = cl.journal.nextSeq;
  }

  // ignore: avoid_print
  print('gen $gen: 活跃 ${metrics['live']} / 墓碑 ${metrics['tombstones']} / '
      'blob ${metrics['blobs']} / 隔离 ${metrics['quarantine']} / '
      'journal ${metrics['journalTotal']} / DB ${metrics['dbKB']}KB'
      '${deletedUuid != null ? " / 本代删 1 条" : ""}'
      '${gen % 3 == 0 ? " / 本代改密" : ""}'
      '${gen % 4 == 0 ? " / 本代重启" : ""}');
}

// ──────────────────────────────────────────────
// 不变量
// ──────────────────────────────────────────────

Future<void> _assertInvariants(LongRunStore store, int gen) async {
  final expectedLive = store.state.notes;

  // I1 + I2：三端收敛一致 & 账本里的历史笔记一条都不能少
  Map<String, String>? reference;
  for (final c in store.clients) {
    final live = await store.liveNotes(c);
    final shape = {for (final e in live.entries) e.key: e.value.contentHash};

    reference ??= shape;
    expect(shape, reference,
        reason: 'gen $gen I1 收敛失败：客户端 ${c.id} 与其他端 live 集合不一致');

    for (final entry in expectedLive.entries) {
      final n = live[entry.key];
      expect(n, isNotNull,
          reason: 'gen $gen I2 数据丢失：客户端 ${c.id} 少了 ${entry.key} '
              '(title=${entry.value.title})');
      expect(n!.contentHash, entry.value.hash,
          reason: 'gen $gen I2 内容不符：客户端 ${c.id} 的 ${entry.key} '
              'hash 与账本不一致');
      // I8：明文与哈希自洽（抓静默腐坏）
      expect(SafeNote.computeHash(n.title, n.description), n.contentHash,
          reason: 'gen $gen I8 静默腐坏：客户端 ${c.id} 的 ${entry.key} '
              '明文与 contentHash 不自洽');
    }

    // 反向：本端不该有账本之外的活跃笔记（幽灵数据/删除未生效）
    for (final uuid in live.keys) {
      expect(expectedLive.containsKey(uuid), isTrue,
          reason: 'gen $gen 幽灵数据：客户端 ${c.id} 出现账本外的活跃笔记 $uuid');
    }
  }

  final manifest = await store.remoteManifest();

  // I3：墓碑长期保留（30 天内不许 GC 掉，更不许静默消失）
  for (final uuid in store.state.deleted) {
    final item = manifest.items[uuid];
    expect(item, isNotNull,
        reason: 'gen $gen I3 墓碑丢失：$uuid 从 manifest 中消失，'
            '其他端将永远收不到这条删除');
    expect(item!.deleted, isTrue,
        reason: 'gen $gen I3 墓碑复活：$uuid 的 deleted 标记被抹掉');
  }

  // manifest 应覆盖账本全部活跃笔记
  for (final uuid in expectedLive.keys) {
    final item = manifest.items[uuid];
    expect(item, isNotNull,
        reason: 'gen $gen manifest 缺失活跃条目 $uuid');
    expect(item!.deleted, isFalse,
        reason: 'gen $gen 活跃笔记 $uuid 在 manifest 中被标记为已删除');
  }

  // I4：引用完整——每个非墓碑条目的 blob 必须真实存在
  final referenced = <String>{
    for (final it in manifest.items.values)
      if (!it.deleted) it.hash,
  };
  final blobFiles = store.blobsDir.existsSync()
      ? store.blobsDir.listSync().whereType<File>().map((f) => p.basename(f.path)).toSet()
      : <String>{};
  for (final h in referenced) {
    expect(blobFiles.contains(h), isTrue,
        reason: 'gen $gen I4 悬挂引用：manifest 引用了不存在的 blob $h');
  }

  // I5：GC 有效——blobs/ 不该堆积孤儿（老版本 blob 应被隔离走）
  expect(blobFiles.length, referenced.length,
      reason: 'gen $gen I5 孤儿堆积：blobs/ 有 ${blobFiles.length} 个文件，'
          '但 manifest 只引用 ${referenced.length} 个。'
          '多出来的：${blobFiles.difference(referenced).take(5).toList()}');

  // I6：journal 水位跨运行不回退
  for (final c in store.clients) {
    final prev = store.state.journalSeq[c.id];
    if (prev != null) {
      expect(c.journal.nextSeq, greaterThanOrEqualTo(prev),
          reason: 'gen $gen I6 水位回退：${c.id} 的 journal nextSeq '
              '从 $prev 退到 ${c.journal.nextSeq}');
    }
  }

  // I7：本地 keyring 与远端 header 的密钥纪元一致
  final header = await store.remoteHeader();
  for (final c in store.clients) {
    expect(c.keyring.keyVersion, header.keyVersion,
        reason: 'gen $gen I7 纪元漂移：${c.id} keyVersion=${c.keyring.keyVersion}，'
            '远端=${header.keyVersion}');
    expect(c.keyring.vaultId, header.vaultId,
        reason: 'gen $gen I7 vaultId 漂移：${c.id}');
  }
}

// ──────────────────────────────────────────────
// 规模指标
// ──────────────────────────────────────────────

Future<Map<String, Object?>> _collectMetrics(LongRunStore store, int gen) async {
  final manifest = await store.remoteManifest();
  final tombstones = manifest.items.values.where((i) => i.deleted).length;
  final blobs = store.blobsDir.existsSync()
      ? store.blobsDir.listSync().whereType<File>().length
      : 0;
  final quarantine = (await store.backend.listOrphanBlobs()).length;

  var journalTotal = 0;
  for (final c in store.clients) {
    journalTotal += (await c.journal.stats())['total'] as int;
  }

  var dbBytes = 0;
  for (final id in kDeviceIds) {
    final f = File(store._dbPath(id));
    if (f.existsSync()) dbBytes += f.lengthSync();
  }

  return {
    'gen': gen,
    'at': DateTime.now().toIso8601String(),
    'live': store.state.notes.length,
    'tombstones': tombstones,
    'manifestItems': manifest.items.length,
    'blobs': blobs,
    'quarantine': quarantine,
    'journalTotal': journalTotal,
    'dbKB': (dbBytes / 1024).round(),
  };
}

/// 打印历史增长表，便于人肉观察「长期使用会不会撑爆」
void _printGrowthTable(LongRunState state) {
  if (state.history.isEmpty) return;
  // ignore: avoid_print
  print('\n--- 长期增长趋势（最近 12 代）---');
  // ignore: avoid_print
  print('gen   live  tomb  items  blobs  quarantine  journal   dbKB');
  for (final h in state.history.skip(max(0, state.history.length - 12))) {
    // ignore: avoid_print
    print('${_pad(h['gen'], 5)}${_pad(h['live'], 6)}${_pad(h['tombstones'], 6)}'
        '${_pad(h['manifestItems'], 7)}${_pad(h['blobs'], 7)}'
        '${_pad(h['quarantine'], 12)}${_pad(h['journalTotal'], 9)}'
        '${_pad(h['dbKB'], 7)}');
  }
  // ignore: avoid_print
  print('累计代数: ${state.generation}，'
      '存储创建于 ${DateTime.fromMillisecondsSinceEpoch(state.createdAt)}');
}

String _pad(Object? v, int w) => '$v'.padLeft(w);
