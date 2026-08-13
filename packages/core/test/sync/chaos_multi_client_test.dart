// 重型随机混沌测试：多客户端 + 随机时序 + 随机改密码
//
// 设计文档：docs/chaos-test-plan-20260729.md
//
// 目标：用 3 个客户端、随机交织的操作流（新建/编辑/删除/同步/改密码）+ 随机延迟，
// 验证同步引擎在乱序数据流下：不丢数据、不腐内容、最终收敛、密钥纪元正确协调。
//
// 关键纪律：
//   1. 每次运行先克隆 118 测试副本（temp/safenotes-vault）到 temp/chaos/run-<seed>/，
//      绝不读写原件，也不触碰 192.168.1.118 远端。
//   2. 种子化 Random(seed)，所有随机选择可复现；失败打印 seed + 全操作轨迹。
//   3. 断言"不变量"而非精确终态（随机时序下终态不可预测）。
//   4. 维护逻辑真值模型（LogicalModel），并区分基线（真实 118 数据）与混沌操作。

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:core/core.dart';

// ──────────────────────────────────────────────
// 常量
// ──────────────────────────────────────────────

/// 118 测试副本（项目内 temp/safenotes-vault），运行前克隆，绝不修改原件。
const String kSourceVaultRel = 'temp/safenotes-vault';

/// 克隆目标根目录（运行目录内 temp/chaos）。
const String kChaosRootRel = 'temp/chaos';

/// 打开真实 keyring 的候选密码（当前密码放首位省 PBKDF2）。
/// 当前真实流程数据集（Android 模拟器 + Windows 应用交互产生）：
/// 初始密码 safe-a-2026 → 改密 safe-a-2026aaa → safe-a-2026bbb（**当前密码放首位**）。
const List<String> kRealVaultPasswords = [
  'safe-a-2026bbb',
  'hello.123',
  'hello.1234',
];

// ──────────────────────────────────────────────
// 逻辑真值模型
// ──────────────────────────────────────────────

/// 逻辑真值模型。
///
/// 随机并发下"哪个编辑胜出"由引擎冲突解决（LWW）决定，模型无法预测精确终态，
/// 因此不记录"唯一正确值"，而是记录**合法性边界**：
///   - hashes[uuid]  = 该 uuid 曾被任何客户端合法写入过的所有 contentHash（含基线）。
///     终态 hash 必须 ∈ 此集合，否则就是真腐坏（内容被引擎改烂了）。
///   - everDeleted   = 曾被删除过的 uuid。终态 deleted=true 的笔记必须在此集合中，
///     否则是"幽灵删除"。
/// 收敛性（各端一致）由跨客户端互比断言，与模型无关。
class LogicalModel {
  final Map<String, Set<String>> hashes = {};
  final Set<String> everDeleted = {};

  void addHash(String uuid, String contentHash) {
    hashes.putIfAbsent(uuid, () => <String>{}).add(contentHash);
  }

  void markDeleted(String uuid) => everDeleted.add(uuid);
}

// ──────────────────────────────────────────────
// 客户端
// ──────────────────────────────────────────────

class ChaosClient {
  ChaosClient(
    this.id,
    this.db,
    this.keyring,
    this.engine,
    this.currentPassword, {
    required this.journal,
    required this.journalBaseDir,
  });

  final String id;
  final Database db; // 各自独立文件型 SQLite（通过 setDatabaseForTesting 切换活跃）
  Keyring keyring;
  SyncEngine engine;
  String currentPassword; // 该客户端当前用于开库的密码

  /// P2：真实**文件模式** Journal（不是内存模式）
  ///
  /// 为什么混沌里必须用文件模式：内存 journal 跑不到滚动归档、崩溃后重开、
  /// 日志损坏隔离、远端副本上传这几条真实失效路径——而这些恰恰是 P2 给
  /// Journal 定的「可恢复」职责。内存模式只能证明"不崩"，证明不了"能恢复"。
  Journal journal;

  /// journal 落盘基目录（重启/损坏注入后按同一目录重开，验证水位延续）
  final String journalBaseDir;
}

// ──────────────────────────────────────────────
// 混沌驱动
// ──────────────────────────────────────────────

class ChaosHarness {
  final List<String> trace = [];
  final LogicalModel model = LogicalModel();
  final Set<String> knownPasswords = <String>{};

  /// 本次运行中被注入过 journal 损坏的客户端 id
  ///
  /// 损坏会导致该端 journal 的 seq 水位从归档重算（当前日志被隔离），
  /// 因此"seq 严格递增"这条不变量只对未被损坏的端成立。
  final Set<String> journalCorruptedClients = <String>{};

  /// 影子远端：uuid → 上次观察到的远端 manifest hash（fail-fast 对账用）。
  final Map<String, String> _shadowRemote = {};

  late final LocalFsBackend backend;
  late final Uint8List sharedDataKey;
  late final List<ChaosClient> clients;

  /// 把当前客户端设为"活跃"（切全局 DB + 注入共享 dataKey）。
  void _activate(ChaosClient c) {
    NotesDatabase.setDatabaseForTesting(c.db);
    NotesDatabase.instance.setDataKey(sharedDataKey);
  }

  /// 递归删除目录，忽略不存在/失败（用于清理克隆目录）。
  static Future<void> _removeDir(String path) async {
    try {
      await Directory(path).delete(recursive: true);
    } catch (_) {
      // 忽略：目录可能不存在或仍被占用
    }
  }

  /// 上传初始空 manifest（兜底全新 keyring 用）。
  static Future<void> _uploadEmptyManifest(
    LocalFsBackend backend,
    Keyring keyring,
  ) async {
    final header = ManifestHeader(
      // v4：schemaVersion 真值化，测试构造也写当前协议版本
      schemaVersion: kManifestSchemaVersion,
      version: 1,
      vaultId: keyring.vaultId,
      createdAt: keyring.createdAt,
      updatedAt: keyring.createdAt,
      keyFingerprint: keyring.keyFingerprint,
      keyVersion: keyring.keyVersion,
      encryptedDataKey: keyring.encryptedDataKey,
      kdf: keyring.kdf,
      dataKeyWrap: 'AES-256-GCM',
      lastModifiedBy: 'chaos-seed',
    );
    final manifest = Manifest(header: header, items: <String, ManifestItem>{});
    final bytes = await ManifestCrypto.serialize(keyring.dataKey, manifest);
    await backend.putManifest(bytes, '');
  }

  /// 克隆源 keyring 到目标目录（递归复制 manifest.json + blobs/）。
  static Future<void> _cloneVault(String src, String dst) async {
    final srcDir = Directory(src);
    if (!srcDir.existsSync()) {
      throw StateError('源 keyring 不存在: $src');
    }
    await Directory(dst).create(recursive: true);
    await for (final entity in srcDir.list(recursive: false)) {
      final name = p.basename(entity.path);
      final target = p.join(dst, name);
      if (entity is File) {
        await File(entity.path).copy(target);
      } else if (entity is Directory) {
        await _cloneVault(entity.path, target);
      }
    }
  }

  /// 用候选密码打开真实 keyring，返回首个成功的解锁结果。
  static Future<({Keyring keyring, String password})> _openRealVault(
    LocalFsBackend backend,
    List<String> passwords,
  ) async {
    final resp = await backend.getManifest();
    final header = ManifestCrypto.deserializeHeaderOnly(resp.ciphertext);
    for (final pw in passwords) {
      try {
        final keyring = await Keyring.unlockFromRemoteManifest(
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
        return (keyring: keyring, password: pw);
      } on WrongPasswordException {
        // 试下一个候选密码
      }
    }
    throw StateError('所有候选密码都无法打开真实 keyring: $passwords');
  }

  /// 远端 manifest 的 keyVersion。
  static Future<int> _remoteKeyVersion(LocalFsBackend backend) async {
    final resp = await backend.getManifest();
    final header = ManifestCrypto.deserializeHeaderOnly(resp.ciphertext);
    return header.keyVersion;
  }

  /// 同步 + 详细动作记账（heal/conflict/corrupt/download 全部进 trace）。
  ///
  /// 对带 `conflict-copy from <srcUuid>` 标记的 upload action：把新 uuid 的
  /// contentHash 纳入 model。原因：_preserveConflictCopy 会在引擎内部生成
  /// 新 UUID 笔记（内容=败方内容 → hash=败方 hash），harness 的 _applyOp
  /// 看不到这个新 UUID 的诞生，若不补充 model，fail-fast 检查会误判为
  /// "跨 uuid 错位"——实际上两条笔记内容相同 → hash 相同是合法的。
  ///
  /// 其他 action（普通 upload/download/delete）不在此补充，保持严格检查，
  /// 以便真正抓到引擎的跨 uuid 错位 bug。
  Future<SyncResult> _sync(ChaosClient c, {String tag = ''}) async {
    final r = await c.engine.sync();
    for (final a in r.actions) {
      final t = a.type.toString().split('.').last;
      if (t == 'skip') continue;
      trace.add(
        '    SYNC${tag.isEmpty ? '' : '($tag)'} client=${c.id} '
        '$t uuid=${a.uuid} hash=${a.hash == null ? '-' : a.hash!.substring(0, 10)} '
        '${a.message ?? ''}',
      );
      // 仅对引擎明确标记的冲突副本补充 model（避免误判合法 hash 共享）
      if (a.message != null && a.message!.startsWith('conflict-copy from ')) {
        model.addHash(a.uuid, a.hash!);
      }
    }
    return r;
  }

  /// 纪元不匹配协调：用 knownPasswords 中某个密码重新解锁远端 keyring，刷新本地 keyring。
  ///
  /// v4（epoch 消除）起引擎不再设置 [SyncResult.passwordEpochMismatch]（恒
  /// false），scenario-b「他端改了密码」改用 [SyncResult.requiresRelogin]
  /// 表达「必须重新登录」（sync_engine.dart:466-471 / 516-521）。因此两种
  /// 信号都要触发协调，否则他端改密后本端同步被永久冻结（零动作）。
  Future<void> _reconcile(
    ChaosClient c,
    SyncResult result,
    LocalFsBackend backend,
  ) async {
    var current = result;
    for (
      var attempt = 0;
      attempt < 4 && (current.passwordEpochMismatch || current.requiresRelogin);
      attempt++
    ) {
      final resp = await backend.getManifest();
      final header = ManifestCrypto.deserializeHeaderOnly(resp.ciphertext);
      final remoteKv = header.keyVersion;
      if (remoteKv <= c.keyring.keyVersion) {
        current = await _sync(c, tag: "reconcile-retry");
        continue;
      }
      var unlocked = false;
      // 倒序：最新密码最可能是远端当前密码，避免逐个 PBKDF2 浪费
      for (final pw in knownPasswords.toList().reversed) {
        try {
          final v = await Keyring.unlockFromRemoteManifest(
            password: pw,
            remoteVaultId: header.vaultId,
            remoteEncryptedDataKey: header.encryptedDataKey,
            remoteKdf: header.kdf,
            remoteKeyFingerprint: header.keyFingerprint,
            remoteKeyVersion: remoteKv,
            remoteDataKeyEpoch: header.dataKeyEpoch,
            remoteCreatedAt: header.createdAt,
            database: NotesDatabase.instance,
          );
          c.keyring = v;
          c.engine.keyring = v;
          c.currentPassword = pw;
          unlocked = true;
          break;
        } on WrongPasswordException {
          continue;
        }
      }
      if (!unlocked) {
        throw StateError(
          'client ${c.id} 无法用已知密码重解锁远端 keyVersion=$remoteKv (known=$knownPasswords)',
        );
      }
      current = await _sync(c, tag: "reconcile-post");
    }
  }

  Future<void> run({
    required int seed,
    int ops = 120,
    int cooldown = 8,
    int clientCount = 3,
  }) async {
    final rng = Random(seed);
    final runDir = p.join(Directory.current.path, kChaosRootRel, 'run-$seed');
    final vaultDir = p.join(runDir, 'safenotes-vault');

    // 1. 克隆真实 keyring（绝不碰原件）
    await _removeDir(runDir);
    await _cloneVault(
      p.join(Directory.current.path, kSourceVaultRel),
      vaultDir,
    );

    // 2. 先探测真实克隆 keyring 能否用候选密码打开（用指向克隆的临时 backend）。
    final probeBackend = LocalFsBackend(rootPath: vaultDir);
    await probeBackend.init();
    // 先用临时 DB 激活（unlock 内部用 NotesDatabase.instance 持久化 meta）
    final probeDb = await _newDb(p.join(runDir, 'probe.db'));
    NotesDatabase.setDatabaseForTesting(probeDb);

    bool usingRealData = true;
    String? workingPassword;
    try {
      final opened = await _openRealVault(probeBackend, kRealVaultPasswords);
      workingPassword = opened.password;
    } on StateError {
      usingRealData = false;
    }

    // 3+4. 构建多客户端（各自独立 DB + 各自 keyring）。
    // 真实数据模式：复用克隆 backend，打开真实 118 keyring，载入基线模型。
    // 兜底模式：真实密码不匹配，改用全新空 keyring（独立目录，绝不覆盖克隆）。
    clients = <ChaosClient>[];
    if (usingRealData && workingPassword != null) {
      backend = probeBackend;
      knownPasswords.add(workingPassword);
      // 共享 dataKey（keyring 级，改密码不变）+ 基线模型（真实 118 数据）
      final probeResp = await backend.getManifest();
      final probeVault = (await _openRealVault(backend, [
        workingPassword,
      ])).keyring;
      sharedDataKey = probeVault.dataKey;
      final baseline = await ManifestCrypto.deserialize(
        sharedDataKey,
        probeResp.ciphertext,
      );
      for (final entry in baseline.items.entries) {
        model.addHash(entry.key, entry.value.hash);
        if (entry.value.deleted) model.markDeleted(entry.key);
      }
      trace.add(
        'MODE=real-data kv=${probeVault.keyVersion} '
        'baseline=${baseline.items.length}',
      );
      for (var i = 0; i < clientCount; i++) {
        final id = String.fromCharCode(65 + i); // A, B, C, ...
        final db = await _newDb(p.join(runDir, 'client-$id.db'));
        NotesDatabase.setDatabaseForTesting(db);
        final cOpened = await _openRealVault(backend, [workingPassword]);
        final jBase = p.join(runDir, 'journal-$id');
        final journal = await Journal.open(
          baseDir: jBase,
          vaultId: cOpened.keyring.vaultId,
          deviceId: id,
        );
        clients.add(
          ChaosClient(
            id,
            db,
            cOpened.keyring,
            _buildEngine(cOpened.keyring, id, journal),
            cOpened.password,
            journal: journal,
            journalBaseDir: jBase,
          ),
        );
      }
    } else {
      // 兜底：全新空 keyring（独立目录），仍完整验证引擎的密钥纪元/迁移/repair 逻辑。
      print(
        'WARN seed 模式: 真实 keyring 打不开（密码不匹配），'
        '回退到全新空 keyring 跑混沌（真实数据校验需正确密码）。',
      );
      final freshDir = p.join(runDir, 'fresh-keyring');
      await Directory(freshDir).create(recursive: true);
      backend = LocalFsBackend(rootPath: freshDir);
      await backend.init();
      workingPassword = 'chaos-seed-pw';
      knownPasswords.add(workingPassword);
      // 首个客户端创建新 keyring 并上传初始空 manifest
      final db0 = await _newDb(p.join(runDir, 'creator.db'));
      NotesDatabase.setDatabaseForTesting(db0);
      final newKeyring = await Keyring.createNew(
        password: workingPassword,
        database: NotesDatabase.instance,
      );
      sharedDataKey = newKeyring.dataKey;
      await _uploadEmptyManifest(backend, newKeyring);
      await db0.close(); // creator DB 只用于建 keyring，用完即关
      trace.add('MODE=fresh-keyring (真实密码不匹配，回退)');
      for (var i = 0; i < clientCount; i++) {
        final id = String.fromCharCode(65 + i);
        final db = await _newDb(p.join(runDir, 'client-$id.db'));
        NotesDatabase.setDatabaseForTesting(db);
        // 每个客户端（含 A）都从远端 manifest 解锁，保证 keyring meta 落到各自 DB。
        final keyring = (await _openRealVault(backend, [
          workingPassword,
        ])).keyring;
        final jBase = p.join(runDir, 'journal-$id');
        final journal = await Journal.open(
          baseDir: jBase,
          vaultId: keyring.vaultId,
          deviceId: id,
        );
        clients.add(
          ChaosClient(
            id,
            db,
            keyring,
            _buildEngine(keyring, id, journal),
            workingPassword,
            journal: journal,
            journalBaseDir: jBase,
          ),
        );
      }
    }

    // 诊断：setup 结束后各端本地笔记数（raw query，避免触发解密）
    for (final c in clients) {
      final n = await c.db.query('safe_notes');
      trace.add('POST-SETUP client=${c.id} rawNotes=${n.length}');
    }

    // 5. 主驱动循环：随机选客户端 + 随机操作 + 随机延迟
    // changePassword 权重压低（~5%）：PBKDF2 200k 极贵，高频改密会拖爆运行时长；
    // 现实中改密码本来就是低频操作。
    //
    // P2 新增两个故障注入（只挑**绝对安全**的两类混进随机流）：
    //   restart(3%)       —— 模拟 App 被杀/重启：journal 关闭后按同目录重开
    //   journalCorrupt(2%)—— 模拟 journal 文件损坏：journal 是辅助设施，
    //                        它烂掉必须不影响任何同步语义
    // 破坏性更强的注入（远端 manifest 损坏、坏纪元污染、keyring 回滚）会改变
    // "什么是合法终态"，塞进随机流会让不变量断言失去意义 → 放到下面的
    // 「P2 定向故障注入」独立 group，用可控前置条件精确验证。
    for (var step = 0; step < ops; step++) {
      final c = clients[rng.nextInt(clients.length)];
      final roll = rng.nextInt(100);
      final String op;
      if (roll < 28) {
        op = 'create';
      } else if (roll < 52) {
        op = 'edit';
      } else if (roll < 66) {
        op = 'delete';
      } else if (roll < 90) {
        op = 'sync';
      } else if (roll < 95) {
        op = 'changePassword';
      } else if (roll < 98) {
        op = 'restart';
      } else {
        op = 'journalCorrupt';
      }
      await Future.delayed(Duration(milliseconds: rng.nextInt(50)));
      _activate(c);
      try {
        await _applyOp(c, op, rng);
      } catch (e) {
        trace.add('[step $step] ERROR client=${c.id} op=$op : $e');
        try {
          final rows = await c.db.query('safe_notes');
          trace.add(
            '  rawNotes=${rows.length} '
            'sharedKey=${sharedDataKey.join(',')} '
            'vaultKey=${c.keyring.dataKey.join(',')} '
            'keysEqual=${_bytesEq(sharedDataKey, c.keyring.dataKey)}',
          );
          for (final r in rows.take(5)) {
            final title = r['title'];
            trace.add(
              '  row uuid=${r['uuid']} deleted=${r['deleted']} '
              'titleType=${title.runtimeType} titleLen=${title is String ? title.length : '?'}',
            );
          }
          final rm = await backend.getManifest();
          try {
            final rmManifest = await ManifestCrypto.deserialize(
              sharedDataKey,
              rm.ciphertext,
            );
            trace.add(
              '  backendPath=${backend.rootPath} '
              'remoteItems=${rmManifest.items.length}',
            );
          } on Object catch (de) {
            trace.add(
              '  backendPath=${backend.rootPath} '
              'remoteDeserializeFAIL=$de',
            );
          }
        } catch (e2) {
          trace.add('  rawQueryErr=$e2');
        }
        rethrow;
      }
      trace.add(
        '[step $step] client=${c.id} op=$op kv=${c.keyring.keyVersion} '
        'known=${knownPasswords.length}',
      );
      // fail-fast 本地对账：每步检查所有客户端本地行（含墓碑），
      // 若某行 hash 不在自己 uuid 的合法集合、却属于其他 uuid → 本地错位现场。
      for (final cc in clients) {
        NotesDatabase.setDatabaseForTesting(cc.db);
        NotesDatabase.instance.setDataKey(sharedDataKey);
        final rows = await NotesDatabase.instance
            .readAllNotesIncludingDeleted();
        for (final n in rows) {
          final legal = model.hashes[n.uuid];
          if (legal == null || legal.contains(n.contentHash)) continue;
          final owners = model.hashes.entries
              .where((x) => x.value.contains(n.contentHash))
              .map((x) => x.key)
              .toList();
          if (owners.isEmpty) continue; // 未知 hash（如冲突副本重算）另案处理
          trace.add(
            '[step $step] LOCAL-MISWIRE 发现于 client=${cc.id} '
            '(本步操作 client=${c.id} op=$op) uuid=${n.uuid} '
            'hash=${n.contentHash.substring(0, 10)} deleted=${n.deleted} '
            'hash属于=$owners',
          );
          fail(
            '本地跨 uuid 错位 @step $step 库=${cc.id} 操作端=${c.id} op=$op '
            'uuid=${n.uuid}',
          );
        }
      }
      _activate(c);
      // fail-fast 影子对账：远端 manifest 中任何 uuid 的 hash 变化，
      // 必须落在该 uuid 的合法写入集合内（或是引擎冲突副本的新 uuid）。
      // 第一时间抓住"跨 uuid 内容错位"被写上远端的精确 step + 客户端。
      try {
        final rm = await ManifestCrypto.deserialize(
          sharedDataKey,
          (await backend.getManifest()).ciphertext,
        );
        for (final e in rm.items.entries) {
          final prev = _shadowRemote[e.key];
          if (prev == e.value.hash) continue; // 未变化
          final legal = model.hashes[e.key];
          if (legal != null && !legal.contains(e.value.hash)) {
            final owners = model.hashes.entries
                .where((x) => x.value.contains(e.value.hash))
                .map((x) => x.key)
                .toList();
            trace.add(
              '[step $step] REMOTE-MISWIRE client=${c.id} op=$op '
              'uuid=${e.key} prev=${prev?.substring(0, 10)} '
              'now=${e.value.hash.substring(0, 10)} deleted=${e.value.deleted} '
              'updatedBy=${e.value.updatedBy} hash属于=$owners',
            );
            fail(
              '远端 manifest 跨 uuid 错位 @step $step client=${c.id} op=$op '
              'uuid=${e.key}',
            );
          }
          _shadowRemote[e.key] = e.value.hash;
        }
      } on TestFailure {
        rethrow;
      } catch (_) {
        // manifest 暂不可解析（正在被并发写）不作为失败
      }
    }

    // 6. 冷却收敛尾：无操作只同步若干轮，确保全端收敛
    for (var i = 0; i < cooldown; i++) {
      for (final c in clients) {
        await Future.delayed(Duration(milliseconds: rng.nextInt(40)));
        _activate(c);
        final r = await _sync(c, tag: "cooldown");
        await _reconcile(c, r, backend);
      }
    }
    // 7. 最终各端再同步一次
    for (final c in clients) {
      _activate(c);
      await _sync(c, tag: "final");
    }

    // 8. 不变量断言
    await _assertInvariants();

    // 成功则关闭各 DB / journal 并清理克隆目录（失败时保留以便排查）
    for (final c in clients) {
      try {
        await c.journal.close();
      } catch (_) {}
      try {
        await c.db.close();
      } catch (_) {}
    }
    try {
      await probeDb.close();
    } catch (_) {}
    await _removeDir(runDir);
  }

  SyncEngine _buildEngine(Keyring keyring, String deviceId, Journal journal) =>
      SyncEngine(
        backend: backend,
        database: NotesDatabase.instance,
        keyring: keyring,
        deviceId: deviceId,
        journal: journal,
      );

  /// 新建独立文件型 DB（避免 :memory: 在同一进程内被多个 openDatabase 共享导致串库）。
  static Future<Database> _newDb(String path) => openDatabase(
    path,
    version: 2,
    onCreate: NotesDatabase.createDBForTesting,
  );

  static bool _bytesEq(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _applyOp(ChaosClient c, String op, Random rng) async {
    switch (op) {
      case 'create':
        final note = SafeNote.create(
          title: 'chaos-t-${rng.nextInt(1 << 30)}',
          description: 'chaos-d-${rng.nextInt(1 << 30)}',
        );
        await NotesDatabase.instance.storeNote(note);
        model.addHash(note.uuid, note.contentHash);
        if (rng.nextBool()) {
          final r = await _sync(c);
          await _reconcile(c, r, backend);
        }
        break;

      case 'edit':
        final locals = await NotesDatabase.instance.readAllNotes();
        if (locals.isEmpty) return;
        final target = locals[rng.nextInt(locals.length)];
        final newTitle = 'chaos-e-${rng.nextInt(1 << 30)}';
        final newDesc = 'chaos-f-${rng.nextInt(1 << 30)}';
        final updated = target.copyWith(
          title: newTitle,
          description: newDesc,
          contentHash: SafeNote.computeHash(newTitle, newDesc),
          updatedAt: DateTime.now().millisecondsSinceEpoch,
          synced: false,
        );
        await NotesDatabase.instance.updateNoteByUuid(updated);
        model.addHash(target.uuid, updated.contentHash);
        if (rng.nextBool()) {
          final r = await _sync(c);
          await _reconcile(c, r, backend);
        }
        break;

      case 'delete':
        final locals = await NotesDatabase.instance.readAllNotes();
        if (locals.isEmpty) return;
        final target = locals[rng.nextInt(locals.length)];
        await NotesDatabase.instance.softDelete(target.id!);
        model.markDeleted(target.uuid);
        if (rng.nextBool()) {
          final r = await _sync(c);
          await _reconcile(c, r, backend);
        }
        break;

      case 'sync':
        final r = await _sync(c);
        await _reconcile(c, r, backend);
        break;

      case 'changePassword':
        // 改密前先确保本端已是最新纪元（用已知密码重解锁）
        final r0 = await _sync(c, tag: "pre-pw");
        await _reconcile(c, r0, backend);
        final newPw = 'chaos-pw-${rng.nextInt(1 << 30)}';
        final newKeyring = await c.keyring.changePassword(
          oldPassword: c.currentPassword,
          newPassword: newPw,
          database: NotesDatabase.instance,
        );
        c.keyring = newKeyring;
        c.engine.keyring = newKeyring;
        c.currentPassword = newPw;
        knownPasswords.add(newPw);
        final r = await _sync(c, tag: "post-pw");
        await _reconcile(c, r, backend);
        break;

      case 'restart':
        // 模拟 App 被系统杀掉后重启：journal 关闭 → 按同一目录重开 → 重建引擎。
        // 断言 seq 水位不回退（journal 必须能从磁盘续上，否则远端副本会
        // 出现 seq 重复，"第二数据源"的时序就废了）。
        final seqBefore = c.journal.nextSeq;
        await c.journal.close();
        c.journal = await Journal.open(
          baseDir: c.journalBaseDir,
          vaultId: c.keyring.vaultId,
          deviceId: c.id,
        );
        _expect(
          c.journal.nextSeq >= seqBefore,
          'restart 后 journal seq 水位回退了（会造成远端副本 seq 冲突）',
        );
        c.engine = _buildEngine(c.keyring, c.id, c.journal);
        trace.add(
          '    RESTART client=${c.id} seq $seqBefore -> ${c.journal.nextSeq}',
        );
        break;

      case 'journalCorrupt':
        // 模拟磁盘/进程异常把 journal 写坏：截断 + 追加垃圾。
        // 契约：journal 自身损坏**绝不能**影响同步（它只是辅助设施）。
        await c.journal.flush();
        final logFile = File(p.join(c.journalBaseDir, 'journal', 'log.json'));
        if (await logFile.exists()) {
          final raw = await logFile.readAsString();
          // 截半 + 追加垃圾：既非合法 JSON，也不是空文件
          await logFile.writeAsString(
            '${raw.substring(0, raw.length ~/ 2)}\u0000<<CHAOS-CORRUPT>>',
          );
        }
        await c.journal.close();
        c.journal = await Journal.open(
          baseDir: c.journalBaseDir,
          vaultId: c.keyring.vaultId,
          deviceId: c.id,
        );
        journalCorruptedClients.add(c.id);
        c.engine = _buildEngine(c.keyring, c.id, c.journal);
        // 损坏后仍必须能追加 + 同步
        c.journal.append(
          type: JournalEventType.noteUpsert,
          uuid: 'post-corrupt',
        );
        final rc = await _sync(c, tag: "post-journal-corrupt");
        await _reconcile(c, rc, backend);
        trace.add('    JOURNAL-CORRUPT client=${c.id} 已隔离并继续');
        break;
    }
  }

  /// 7 条不变量断言。
  Future<void> _assertInvariants() async {
    // 收集每客户端本地状态
    final states =
        <String, Map<String, ({String contentHash, bool deleted})>>{};
    for (final c in clients) {
      _activate(c);
      final all = await NotesDatabase.instance.readAllNotesIncludingDeleted();
      final m = <String, ({String contentHash, bool deleted})>{};
      for (final n in all) {
        m[n.uuid] = (contentHash: n.contentHash, deleted: n.deleted);
      }
      states[c.id] = m;
    }

    // 不变量 1：无丢失 —— model 中每个 uuid 必须在所有客户端存在（含墓碑行）。
    // 不变量 2：无腐坏 —— 终态 contentHash 必须 ∈ 该 uuid 的合法写入集合。
    //   （并发编辑谁胜出由 LWW 决定，无法预测；但胜者必须是"某个客户端真写过的值"）
    // 不变量 2b：删除合法性 —— 终态 deleted=true 的笔记必须真的被删除过。
    for (final entry in model.hashes.entries) {
      final uuid = entry.key;
      final legalHashes = entry.value;
      for (final c in clients) {
        final got = states[c.id]![uuid];
        if (got == null) {
          // 缺席仅在该笔记曾被删除时合法：远端墓碑对"从未见过该 uuid"的客户端
          // 不要求落地本地墓碑行。活跃状态互斥由不变量3（活跃集互比）保证。
          _expect(
            model.everDeleted.contains(uuid),
            '不变量1 失败: client ${c.id} 缺失从未被删除的笔记 $uuid(真丢失)',
          );
          continue;
        }
        if (!legalHashes.contains(got.contentHash)) {
          // 反查：这个"非法"hash 属于哪些 uuid 的合法集合？（跨 uuid 错位诊断）
          final owners = model.hashes.entries
              .where((e) => e.value.contains(got.contentHash))
              .map((e) => e.key)
              .toList();
          // 远端 manifest 对该 uuid 的记录
          String remoteInfo = '?';
          try {
            final rm = await ManifestCrypto.deserialize(
              sharedDataKey,
              (await backend.getManifest()).ciphertext,
            );
            final ri = rm.items[uuid];
            remoteInfo = ri == null
                ? 'absent'
                : 'hash=${ri.hash} deleted=${ri.deleted} '
                      'updatedBy=${ri.updatedBy} updatedAt=${ri.updatedAt}';
          } catch (_) {}
          fail(
            '不变量2 失败: client ${c.id} 笔记 $uuid 终态 hash '
            '${got.contentHash} 不在合法集合 legal=$legalHashes\n'
            '  该 hash 属于其他 uuid: $owners\n'
            '  远端 manifest: $remoteInfo',
          );
        }
        if (got.deleted) {
          _expect(
            model.everDeleted.contains(uuid),
            '不变量2b 失败: client ${c.id} 笔记 $uuid 被标删除但从未有删除操作(幽灵删除)',
          );
        }
      }
    }

    // 不变量 4：无幽灵笔记（客户端存在但 model 从未见过该 uuid）
    for (final c in clients) {
      for (final uuid in states[c.id]!.keys) {
        _expect(
          model.hashes.containsKey(uuid),
          '不变量4 失败: client ${c.id} 存在幽灵笔记 $uuid',
        );
      }
    }

    // 不变量 3：活跃笔记集合（非删除）跨客户端收敛
    Map<String, String>? ref;
    for (final c in clients) {
      final live = <String, String>{};
      for (final e in states[c.id]!.entries) {
        if (!e.value.deleted) live[e.key] = e.value.contentHash;
      }
      if (ref == null) {
        ref = live;
      } else {
        _expect(
          _stringMapEquals(live, ref),
          '不变量3 失败: client ${c.id} 活跃笔记集合未与首端收敛',
        );
      }
    }

    // 不变量 5：密钥一致性（keyVersion 全网一致）
    final keyVersions = clients.map((c) => c.keyring.keyVersion).toSet();
    _expect(
      keyVersions.length == 1,
      '不变量5 失败: 各客户端 keyVersion 未收敛 $keyVersions',
    );

    // 不变量 6：manifest 完整性（远端可解析 + keyVersion 与客户端一致）
    final remoteKv = await _remoteKeyVersion(backend);
    _expect(
      remoteKv == clients.first.keyring.keyVersion,
      '不变量6 失败: 远端 keyVersion 与客户端不一致',
    );

    // 不变量 7：无遗留坏 blob（最终同步后 failedNoteUuids 为空）
    for (final c in clients) {
      _activate(c);
      final r = await _sync(c, tag: "inv7");
      _expect(
        r.failedNoteUuids.isEmpty,
        '不变量7 失败: client ${c.id} 仍有失败 blob ${r.failedNoteUuids}',
      );
    }

    await _assertJournalInvariants();
  }

  /// P2 新增的 journal 不变量（8 / 9 / 10）
  ///
  /// 这三条守的是 Journal 的**可恢复**承诺，不是"日志好看"：
  ///   8  本地 journal 始终可读、seq 有序 —— 否则重放序列本身不可信
  ///   9  远端加密副本存在且能用 dataKey 解开 —— 否则"第二数据源"是空头支票
  ///   10 从 journal 重放出的 keyState 与终态 keyring 一致 —— 否则坏纪元
  ///      污染时拿 journal 取真会取到错的
  Future<void> _assertJournalInvariants() async {
    // ── 不变量 8：本地 journal 可读 + seq 有序 ──
    for (final c in clients) {
      final all = await c.journal.readAll();
      var prev = 0;
      for (final e in all) {
        _expect(e.seq > 0, '不变量8 失败: client ${c.id} journal 出现非法 seq=${e.seq}');
        if (!journalCorruptedClients.contains(c.id)) {
          _expect(
            e.seq > prev,
            '不变量8 失败: client ${c.id} journal seq 非严格递增 '
            '($prev -> ${e.seq})',
          );
        }
        prev = e.seq;
      }
      // 悬挂的跨步操作：收敛后不应残留（两段式 start 都该有 done/failed）
      final incomplete = await c.journal.findIncompleteOperations();
      _expect(
        incomplete.isEmpty,
        '不变量8 失败: client ${c.id} 收敛后仍有未完成跨步操作 $incomplete',
      );
    }

    // ── 不变量 9：远端 journal 副本可解密 ──
    final names = await backend.listJournalObjects();
    _expect(names.isNotEmpty, '不变量9 失败: 同步多轮后远端竟无任何 journal 副本（第二数据源缺失）');
    final remote = await Journal.fetchRemoteEntries(backend, sharedDataKey);
    _expect(remote.isNotEmpty, '不变量9 失败: 远端 journal 副本无法用 dataKey 解出任何条目');
    // 远端副本必须是密文（抽查一个对象，不得出现明文事件名）
    final sample = await backend.getJournalObject(names.first);
    _expect(
      !String.fromCharCodes(sample!).contains('note.upsert'),
      '不变量9 失败: 远端 journal 副本落了明文',
    );

    // ── 不变量 10：journal 重放出的 keyVersion 不落后于终态 ──
    // 用 >= 而非 ==：某端可能在别端改密后尚未产生自己的 key 事件，
    // 但**绝不允许**重放出比终态更新的纪元（那意味着记录了从未生效的密钥态）。
    final finalKv = clients.first.keyring.keyVersion;
    for (final c in clients) {
      final replayed = await c.journal.replayKeyState();
      if (replayed == null) continue; // 该端从未参与密钥变更，合法
      _expect(
        replayed.keyVersion <= finalKv,
        '不变量10 失败: client ${c.id} journal 重放出超前的 keyVersion '
        '${replayed.keyVersion} > 终态 $finalKv',
      );
    }
    // 全网合并视角：远端副本里最新的 key 事件应当就是终态 keyVersion
    JournalKeyState? newest;
    var newestTs = -1;
    for (final e in remote) {
      if (!e.type.isKeyEvent || e.keyState == null) continue;
      if (e.phase == JournalPhase.start || e.phase == JournalPhase.failed) {
        continue;
      }
      if (e.ts > newestTs) {
        newestTs = e.ts;
        newest = e.keyState;
      }
    }
    if (newest != null) {
      // 同样用 <=：chaos 的改密码走 _reconcile（Keyring.unlockFromRemoteManifest），
      // 不经过引擎的 adoptRemoteEpoch，因此远端 journal 里最新的 key 事件
      // 合法地可能落后于终态。要守的底线是**绝不超前**——超前意味着
      // journal 记录了一个从未真正生效的密钥纪元，坏纪元取真时会取错。
      _expect(
        newest.keyVersion <= finalKv,
        '不变量10 失败: 远端 journal 合并后的 keyVersion '
        '${newest.keyVersion} 超前于终态 $finalKv',
      );
    }
  }
}

// ──────────────────────────────────────────────
// P2 定向故障注入夹具
// ──────────────────────────────────────────────

/// 轻量、可控的多端夹具（不依赖 118 真实数据）
///
/// 与 [ChaosHarness] 的分工：
///   ChaosHarness   —— 随机时序、真实数据、断言"不变量"（不预测终态）
///   P2FaultFixture —— **确定性**时序，注入单一破坏性故障，断言精确终态
///
/// 之所以需要后者：manifest 损坏、坏纪元污染、keyring 账本回滚这类故障会
/// 直接改变"什么是合法终态"。把它们塞进随机流只会让不变量断言失去判别力
/// （任何结果都能被解释成"随机时序导致的"），真正的回归反而抓不到。
class P2FaultFixture {
  late final Directory root;
  late final LocalFsBackend backend;
  late final Uint8List dataKey;
  late final String vaultId;
  late final KdfParams kdf;
  String password;
  final List<ChaosClient> clients = <ChaosClient>[];

  P2FaultFixture({this.password = 'p2-fault-pw'});

  String get vaultDir => p.join(root.path, 'vault');

  /// 远端 manifest 文件（用于直接注入损坏）
  File get remoteManifestFile => File(p.join(vaultDir, 'manifest.json'));

  Future<void> setUp({int clientCount = 2}) async {
    root = await Directory.systemTemp.createTemp('p2_fault_');
    backend = LocalFsBackend(rootPath: vaultDir);
    await backend.init();

    // 建库者：创建 keyring + 上传初始空 manifest
    final creatorDb = await ChaosHarness._newDb(
      p.join(root.path, 'creator.db'),
    );
    NotesDatabase.setDatabaseForTesting(creatorDb);
    final created = await Keyring.createNew(
      password: password,
      database: NotesDatabase.instance,
    );
    dataKey = created.dataKey;
    vaultId = created.vaultId;
    kdf = created.kdf;
    await ChaosHarness._uploadEmptyManifest(backend, created);
    await creatorDb.close();

    for (var i = 0; i < clientCount; i++) {
      await addClient(String.fromCharCode(65 + i));
    }
  }

  /// 新设备入网：全新空库 + 用密码从远端 manifest 解出 keyring + 全新 journal。
  ///
  /// 用于「新装设备第一次同步」这类场景——它与已有客户端的关键差别是
  /// **本机没有任何明文**，因此所有依赖"本机明文兜底"的自愈路径都走不通，
  /// 能真实暴露远端数据缺失对新用户的影响。
  Future<ChaosClient> addClient(String id) async {
    final db = await ChaosHarness._newDb(p.join(root.path, 'client-$id.db'));
    NotesDatabase.setDatabaseForTesting(db);
    final keyring = await _unlockFromRemote(password);
    final jBase = p.join(root.path, 'journal-$id');
    final journal = await Journal.open(
      baseDir: jBase,
      vaultId: vaultId,
      deviceId: id,
    );
    final c = ChaosClient(
      id,
      db,
      keyring,
      buildEngine(keyring, id, journal),
      password,
      journal: journal,
      journalBaseDir: jBase,
    );
    clients.add(c);
    return c;
  }

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

  SyncEngine buildEngine(Keyring keyring, String deviceId, Journal journal) =>
      SyncEngine(
        backend: backend,
        database: NotesDatabase.instance,
        keyring: keyring,
        deviceId: deviceId,
        journal: journal,
      );

  void activate(ChaosClient c) {
    NotesDatabase.setDatabaseForTesting(c.db);
    NotesDatabase.instance.setDataKey(dataKey);
  }

  Future<SyncResult> sync(ChaosClient c) async {
    activate(c);
    return c.engine.sync();
  }

  /// 在指定客户端建一条笔记
  Future<SafeNote> createNote(ChaosClient c, String title) async {
    activate(c);
    final note = SafeNote.create(title: title, description: 'desc-$title');
    await NotesDatabase.instance.storeNote(note);
    return note;
  }

  /// 读取指定客户端的活跃笔记标题集合
  Future<Set<String>> liveTitles(ChaosClient c) async {
    activate(c);
    final notes = await NotesDatabase.instance.readAllNotes();
    return notes.map((n) => n.title).toSet();
  }

  /// 模拟 App 重启：关闭并按同目录重开 journal，重建引擎
  Future<void> restart(ChaosClient c) async {
    await c.journal.close();
    c.journal = await Journal.open(
      baseDir: c.journalBaseDir,
      vaultId: vaultId,
      deviceId: c.id,
    );
    activate(c);
    c.engine = buildEngine(c.keyring, c.id, c.journal);
  }

  /// journal 目录下匹配前缀的文件名
  List<String> journalFiles(ChaosClient c, {String prefix = ''}) {
    final dir = Directory(p.join(c.journalBaseDir, 'journal'));
    if (!dir.existsSync()) return [];
    return dir
        .listSync()
        .map((e) => p.basename(e.path))
        .where((n) => n.startsWith(prefix))
        .toList()
      ..sort();
  }

  /// 让两端来回同步直到收敛（确定性夹具下 3 轮足够）
  Future<void> converge({int rounds = 3}) async {
    for (var i = 0; i < rounds; i++) {
      for (final c in clients) {
        await sync(c);
      }
    }
  }

  Future<void> tearDown() async {
    for (final c in clients) {
      try {
        await c.journal.close();
      } catch (_) {}
      try {
        await c.db.close();
      } catch (_) {}
    }
    try {
      await root.delete(recursive: true);
    } on FileSystemException {
      // Windows 句柄未释放，交给系统回收
    }
  }
}

/// 在独立 isolate 中运行单个 seed 的混沌。
///
/// 并行化的依据：harness 依赖全局单例 [NotesDatabase.setDatabaseForTesting]，
/// 同一 isolate 内并行必然互相污染；而 [Isolate.run] 每次生成全新 isolate，
/// 全局状态彼此隔离，配合「每个 seed 独立目录 temp/chaos/run-$seed」即可安全
/// 并发。同时子 isolate 内需自建 sqflite FFI 环境（factory 不跨 isolate 共享）。
///
/// 返回 null 表示通过；失败时返回包含 trace 的诊断字符串。
Future<String?> _runChaosSeedIsolate(int seed) async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final harness = ChaosHarness();
  try {
    await harness.run(seed: seed, ops: 120, cooldown: 8, clientCount: 3);
    return null;
  } catch (e) {
    return '=== CHAOS FAIL seed=$seed ===\n$e\n--- trace ---\n'
        '${harness.trace.join('\n')}';
  }
}

/// 断言辅助：与 `expect` 语义一致但不依赖测试 zone。
///
/// seed 运行在独立 isolate 中（无测试 zone），直接调用 `expect` 会抛
/// OutsideTestException；这里改用抛 [TestFailure]（与现有 `fail()` 同型，
/// 且 harness 内部本就 `on TestFailure` 捕获）。
void _expect(bool condition, String message) {
  if (!condition) {
    throw TestFailure(message);
  }
}

/// 两个 `Map<String, String>` 的相等比较（替代 matcher 的 `equals`，供隔离
/// isolate 内使用）。
bool _stringMapEquals(Map<String, String> a, Map<String, String> b) {
  if (a.length != b.length) return false;
  for (final e in a.entries) {
    if (b[e.key] != e.value) return false;
  }
  return true;
}

/// 并行运行一批 seed：每个 seed 一个独立 isolate，全部完成后汇总。
/// 返回失败 seed 列表。
Future<List<int>> _runSeedsParallel(List<int> seeds) async {
  final futures = <Future<MapEntry<int, String?>>>[];
  for (final seed in seeds) {
    futures.add(
      Isolate.run(() => _runChaosSeedIsolate(seed)).then((detail) {
        print('─── seed=$seed ${detail == null ? '通过' : '失败'} ───');
        if (detail != null) print(detail);
        return MapEntry(seed, detail);
      }),
    );
  }
  final results = await Future.wait(futures);
  return [
    for (final r in results)
      if (r.value != null) r.key,
  ];
}

// ──────────────────────────────────────────────
// 测试
// ──────────────────────────────────────────────

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('混沌 - 真实数据(118克隆) + 改密码随机交织', () {
    // 并行运行多个 seed：每个 seed 在独立 isolate + 独立目录（temp/chaos/run-$seed）
    // 中执行，避免全局 NotesDatabase 单例互踩，耗时≈最慢单个 seed 而非累加。
    // 单个 seed 失败不会中断其余 seed，全部跑完后统一报告失败列表。
    //
    // v4（epoch 消除）曾 SKIP：当时 temp/safenotes-vault 为旧格式（epoch-AAD）真实数据，
    // v4 blob 纯化（AAD=hash）与其不兼容，解密必失败。2026-08-02 已用 v4 新格式
    // 重建 temp/safenotes-vault（schemaVersion=4，密码 safe-a-2026bbb），故恢复运行。
    test('并行混沌（多 seed 独立 isolate 同时运行）', () async {
      const seeds = [12, 345, 6789];
      final sw = Stopwatch()..start();
      final failures = await _runSeedsParallel(seeds);
      print(
        '总计: ${seeds.length} 个 seed，${seeds.length - failures.length} '
        '通过，${failures.length} 失败，耗时 ${sw.elapsed.inSeconds}s',
      );
      if (failures.isNotEmpty) {
        fail('失败的 seed: $failures');
      }
    }, timeout: const Timeout(Duration(minutes: 30)));

    // 命令行自定义 seed：通过环境变量 CHAOS_SEEDS 传入逗号分隔的 seed 列表。
    // 用法（pwsh）:
    //   $env:CHAOS_SEEDS="123,456,789"; flutter test test/sync/chaos_multi_client_test.dart --plain-name "自定义"
    // 用法（bash）:
    //   CHAOS_SEEDS=123,456 flutter test test/sync/chaos_multi_client_test.dart --plain-name "自定义"
    // 不传时此 test 直接跳过，不影响默认 seed 的运行。
    // 多个 seed 同样并行（独立 isolate + 独立目录）；单个失败不中断其余。
    test('自定义 seed（环境变量 CHAOS_SEEDS）', () async {
      final raw = Platform.environment['CHAOS_SEEDS'] ?? '';
      if (raw.isEmpty) {
        print('SKIP: 未设置环境变量 CHAOS_SEEDS（示例: CHAOS_SEEDS=123,456）');
        return;
      }
      final seeds = raw
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .map((s) => int.tryParse(s))
          .whereType<int>()
          .toList();
      if (seeds.isEmpty) {
        print('WARN: CHAOS_SEEDS="$raw" 未解析出任何有效数字');
        return;
      }
      print('自定义 seed 并行运行: $seeds（共 ${seeds.length} 个）');
      final sw = Stopwatch()..start();
      final failures = await _runSeedsParallel(seeds);
      print(
        '总计: ${seeds.length} 个 seed，${seeds.length - failures.length} '
        '通过，${failures.length} 失败，耗时 ${sw.elapsed.inSeconds}s',
      );
      if (failures.isNotEmpty) {
        fail('失败的 seed: $failures');
      }
    }, timeout: const Timeout(Duration(minutes: 30)));
  });

  // ════════════════════════════════════════════
  // P2 定向故障注入
  // ════════════════════════════════════════════
  group('混沌 - P2 定向故障注入', () {
    late P2FaultFixture f;

    setUp(() async {
      f = P2FaultFixture();
      await f.setUp();
    });

    tearDown(() async => f.tearDown());

    // ── 故障 1：journal 自身损坏 ──
    test('journal 日志损坏 → 隔离取证，同步语义零影响', () async {
      final a = f.clients[0];
      final b = f.clients[1];

      await f.createNote(a, 't1');
      expect((await f.sync(a)).success, isTrue);

      // 注入：截半 + 追加二进制垃圾
      await a.journal.flush();
      final log = File(p.join(a.journalBaseDir, 'journal', 'log.json'));
      final raw = await log.readAsString();
      await log.writeAsString(
        '${raw.substring(0, raw.length ~/ 2)}\u0000<<CORRUPT>>',
      );
      await a.journal.close();
      a.journal = await Journal.open(
        baseDir: a.journalBaseDir,
        vaultId: f.vaultId,
        deviceId: a.id,
      );
      f.activate(a);
      a.engine = f.buildEngine(a.keyring, a.id, a.journal);

      expect(
        f.journalFiles(a, prefix: 'log.json.corrupt-'),
        isNotEmpty,
        reason: '损坏日志必须改名保留取证，而不是被静默覆盖',
      );

      // 损坏之后一切照旧
      await f.createNote(a, 't2');
      final r = await f.sync(a);
      expect(r.success, isTrue, reason: 'journal 损坏不得让同步失败');
      await f.sync(b);
      expect(await f.liveTitles(b), {
        't1',
        't2',
      }, reason: 'journal 损坏不得造成任何数据丢失');
    });

    test('journal 目录被整体删除（用户清缓存）→ 同步照常', () async {
      final a = f.clients[0];
      final b = f.clients[1];
      await f.createNote(a, 't1');
      await f.sync(a);

      await a.journal.close();
      await Directory(
        p.join(a.journalBaseDir, 'journal'),
      ).delete(recursive: true);
      a.journal = await Journal.open(
        baseDir: a.journalBaseDir,
        vaultId: f.vaultId,
        deviceId: a.id,
      );
      f.activate(a);
      a.engine = f.buildEngine(a.keyring, a.id, a.journal);
      expect(a.journal.nextSeq, 1, reason: '目录没了，水位从头开始（可接受的降级）');

      await f.createNote(a, 't2');
      expect((await f.sync(a)).success, isTrue);
      await f.sync(b);
      expect(await f.liveTitles(b), {'t1', 't2'});
    });

    // ── 故障 2：进程重启 ──
    test('App 重启 → journal seq 水位延续，远端副本无 seq 冲突', () async {
      final a = f.clients[0];
      await f.createNote(a, 't1');
      await f.sync(a);
      final seqBefore = a.journal.nextSeq;
      expect(seqBefore, greaterThan(1), reason: '同步应已产生 journal 条目');

      await f.restart(a);
      expect(a.journal.nextSeq, seqBefore, reason: '重启后水位必须精确延续');

      await f.createNote(a, 't2');
      await f.sync(a);

      // 远端副本里 A 的 seq 必须互不重复——重复即意味着覆盖丢事件
      final remote = await Journal.fetchRemoteEntries(f.backend, f.dataKey);
      final aSeqs = remote.where((e) => e.by == 'A').map((e) => e.seq).toList();
      expect(
        aSeqs.toSet().length,
        aSeqs.length,
        reason: 'seq 重复会让远端副本按 by#seq 去重时静默丢事件',
      );
      final localSeqs = (await a.journal.readAll()).map((e) => e.seq).toSet();
      expect(
        aSeqs.toSet(),
        localSeqs,
        reason: '远端副本应完整覆盖本地 journal（第二数据源不能有缺口）',
      );
    });

    // ── 故障 3：远端 manifest 损坏 ──
    test('远端 manifest 损坏 → 重建后数据不丢，journal 留下重建证据', () async {
      final a = f.clients[0];
      final b = f.clients[1];
      await f.createNote(a, 'from-a');
      await f.sync(a);
      await f.sync(b);
      await f.createNote(b, 'from-b');
      await f.converge();
      expect(await f.liveTitles(a), {'from-a', 'from-b'});

      // 注入：把远端 manifest 写成垃圾（GCM 校验必失败）
      await f.remoteManifestFile.writeAsBytes(
        Uint8List.fromList(List<int>.generate(256, (i) => i % 251)),
      );

      final r = await f.sync(a);
      expect(r.success, isTrue, reason: 'manifest 损坏应触发重建而非同步失败');

      await f.converge();
      expect(await f.liveTitles(a), {
        'from-a',
        'from-b',
      }, reason: '重建不得丢数据（A 本地有全量）');
      expect(await f.liveTitles(b), {
        'from-a',
        'from-b',
      }, reason: '重建后 B 仍应收敛到同一集合');

      // journal 必须留下 manifest 重建事件——这正是"第二数据源"最该记的一笔
      final events = await a.journal.readAll();
      expect(
        events.any((e) => e.type == JournalEventType.syncManifestRebuild),
        isTrue,
        reason: 'manifest 重建未被记录，事后无法解释远端为何换了一份',
      );

      // 重建后远端 journal 副本仍可解密（恢复链路没被一起打断）
      final remote = await Journal.fetchRemoteEntries(f.backend, f.dataKey);
      expect(remote, isNotEmpty);
    });

    // ── 故障 4：坏纪元污染 keyring ──
    test('坏纪元污染 keyring.current → journal 重放可取回真值', () async {
      final a = f.clients[0];
      await f.createNote(a, 't1');
      await f.sync(a);
      f.activate(a);

      // 记录一笔"已完成的密钥变更"，内容与真实 keyring 一致。
      // 这正是 SyncService.updateKeyring 在生产里写的那条条目
      // （此处直写是因为 SyncService 依赖 path_provider，不属于本测试范围）。
      final good = JournalKeyState(
        keyVersion: a.keyring.keyVersion,
        dataKeyEpoch: a.keyring.dataKeyEpoch,
        keyFingerprint: a.keyring.keyFingerprint,
        encryptedDataKey: a.keyring.encryptedDataKey,
      );
      a.journal.append(
        type: JournalEventType.keyChangePassword,
        phase: JournalPhase.done,
        dataKeyEpoch: good.dataKeyEpoch,
        keyState: good,
      );
      await a.journal.flush();

      // 注入：把落盘账本的 current 换成坏纪元（epoch 飞到 999，edk 是垃圾）
      final ledger = (await KeyringLedger.load(NotesDatabase.instance))!;
      final polluted = KeyringLedger(
        vaultId: ledger.vaultId,
        kdf: ledger.kdf,
        createdAt: ledger.createdAt,
        current: ledger.current.copyWith(
          encryptedDataKey: base64Encode(
            Uint8List.fromList(List<int>.filled(60, 0xAB)),
          ),
          dataKeyEpoch: 999,
          keyVersion: 999,
        ),
      );
      await polluted.persist(NotesDatabase.instance);

      // 污染确实生效：本地解锁挂了
      await expectLater(
        Keyring.unlockLocal(
          password: f.password,
          database: NotesDatabase.instance,
        ),
        throwsA(isA<WrongPasswordException>()),
      );

      // §3.6c 恢复：从 journal 重放取真
      final replayed = await a.journal.replayKeyState();
      expect(replayed, isNotNull, reason: '重放不出 keyState，恢复链路就是空的');
      expect(replayed!.keyVersion, good.keyVersion);
      expect(replayed.encryptedDataKey, good.encryptedDataKey);

      // 用重放结果修复账本后，本地解锁恢复正常，且 dataKey 与原来一致
      final repaired = KeyringLedger(
        vaultId: polluted.vaultId,
        kdf: polluted.kdf,
        createdAt: polluted.createdAt,
        current: polluted.current.copyWith(
          encryptedDataKey: replayed.encryptedDataKey,
          keyFingerprint: replayed.keyFingerprint,
          keyVersion: replayed.keyVersion,
          dataKeyEpoch: replayed.dataKeyEpoch,
        ),
      );
      await repaired.persist(NotesDatabase.instance);
      final recovered = await Keyring.unlockLocal(
        password: f.password,
        database: NotesDatabase.instance,
      );
      expect(
        recovered.dataKey,
        equals(f.dataKey),
        reason: '恢复出的 dataKey 必须与原 dataKey 逐字节相同，否则所有 blob 都废了',
      );
    });

    // ── 故障 5：keyring 账本回滚（备份还原 / 文件翻转）──
    test('keyring 账本被回滚到改密前 → 绝不把远端纪元一起回滚', () async {
      final a = f.clients[0];
      final b = f.clients[1];
      await f.createNote(a, 't1');
      await f.converge();

      // 改密前的账本快照（模拟"用户从旧备份恢复了一份 App 数据"）
      f.activate(a);
      final snapshotJson = jsonEncode(
        (await KeyringLedger.load(NotesDatabase.instance))!.toJson(),
      );

      // A 改密码 → v2，并推到远端
      const newPw = 'p2-fault-pw-v2';
      a.keyring = await a.keyring.changePassword(
        oldPassword: f.password,
        newPassword: newPw,
        database: NotesDatabase.instance,
      );
      a.engine.keyring = a.keyring;
      await f.sync(a);
      final remoteKvAfterChange = ManifestCrypto.deserializeHeaderOnly(
        (await f.backend.getManifest()).ciphertext,
      ).keyVersion;
      expect(remoteKvAfterChange, 2);

      // 注入：把 A 的账本回滚到改密之前
      f.activate(a);
      await KeyringLedger.fromJson(
        jsonDecode(snapshotJson) as Map<String, dynamic>,
      ).persist(NotesDatabase.instance);
      a.keyring = await Keyring.unlockLocal(
        password: f.password,
        database: NotesDatabase.instance,
      );
      expect(a.keyring.keyVersion, 1, reason: '回滚注入应生效');
      a.engine = f.buildEngine(a.keyring, a.id, a.journal);

      // 关键断言：A 用旧纪元同步，**远端 keyVersion 不得被拉回 1**
      final r = await f.sync(a);
      final remoteKvAfterRollback = ManifestCrypto.deserializeHeaderOnly(
        (await f.backend.getManifest()).ciphertext,
      ).keyVersion;
      expect(remoteKvAfterRollback, 2, reason: '本地账本回滚把远端纪元也带回旧值 = 所有其他设备被踢下线');
      // v4（epoch 消除 §8.2[I] 选项 B）：scenario-b 中止 + 提示重登录
      expect(r.success, isFalse, reason: 'A 旧纪元（回滚后）同步应中止（他端改了密码）');
      expect(r.errorMessage, contains('密码已在其他设备修改'), reason: '应明确提示用户用新密码重新登录');

      // 用新密码从远端重新解锁后收敛
      f.activate(a);
      a.keyring = await f._unlockFromRemote(newPw);
      a.engine = f.buildEngine(a.keyring, a.id, a.journal);
      expect(a.keyring.keyVersion, 2);
      await f.sync(a);
      await f.sync(b);
      expect(await f.liveTitles(a), contains('t1'));
    });

    // ── 故障 6：本地全丢，靠远端第二数据源 ──
    test('本地 journal 全丢 → 远端副本仍能还原两端的事件序列', () async {
      final a = f.clients[0];
      final b = f.clients[1];
      await f.createNote(a, 'from-a');
      await f.sync(a);
      await f.sync(b);
      await f.createNote(b, 'from-b');
      await f.converge();

      // 模拟重装 App：两端本地 journal 目录全删
      for (final c in [a, b]) {
        await c.journal.close();
        final dir = Directory(p.join(c.journalBaseDir, 'journal'));
        if (dir.existsSync()) await dir.delete(recursive: true);
      }

      final remote = await Journal.fetchRemoteEntries(f.backend, f.dataKey);
      expect(remote, isNotEmpty, reason: '本地没了，远端就是唯一线索');
      final devices = remote.map((e) => e.by).toSet();
      expect(
        devices,
        containsAll(<String>{'A', 'B'}),
        reason: '两端的副本都应在远端，且互不覆盖',
      );
      expect(
        remote.any((e) => e.type == JournalEventType.noteUpsert),
        isTrue,
        reason: '还原不出任何笔记事件，第二数据源就没有恢复价值',
      );
      // 重开 journal 不得抛异常（重装后首次启动）
      for (final c in [a, b]) {
        c.journal = await Journal.open(
          baseDir: c.journalBaseDir,
          vaultId: f.vaultId,
          deviceId: c.id,
        );
      }
    });

    // ── 故障 7：blob 丢失（远端被误删）──
    //
    // 这里锁定的是引擎的**真实契约**，不是想当然的期望：
    //   1. 增量 sync 不做远端物理体检（不逐条 getBlob，否则每次同步都要全量
    //      下载），所以已收敛的老设备不会自动发现 blob 悬空 → 不会重传；
    //   2. 新设备下载到缺失 blob 时按"可能是别人还没传完"处理，记 skip 并
    //      下次重试，绝不删本地、不写坏 manifest、不让整次同步失败；
    //   3. 物理层自愈的正式入口是 repairRemote（全量体检 + 本机明文重传）。
    // 把这三条钉死，才能防止以后有人误改成"sync 里偷偷全量体检"或
    // "拉不到就当成删除"。
    test('远端 blob 丢失 → 增量 sync 不做物理体检（契约锁定，不丢数据）', () async {
      final a = f.clients[0];
      final b = f.clients[1];
      await f.createNote(a, 'heal-me');
      await f.sync(a);
      await f.sync(b);
      expect(await f.liveTitles(b), {'heal-me'});

      // 注入：删掉远端所有 blob（保留 manifest → 制造"引用悬空"）
      final blobsDir = Directory(p.join(f.vaultDir, 'blobs'));
      expect(blobsDir.listSync().length, greaterThan(0));
      for (final e in blobsDir.listSync()) {
        if (e is File) await e.delete();
      }

      // 老设备（已收敛）再同步：成功，但按设计不会去体检物理 blob
      final r = await f.sync(a);
      expect(r.success, isTrue, reason: 'blob 悬空不得让同步失败');
      await f.converge();
      expect(
        blobsDir.listSync(),
        isEmpty,
        reason:
            '增量 sync 不做物理体检——若这里变成非空，说明有人在 sync 里'
            '加了全量 getBlob，性能契约被破坏，需重新评审',
      );

      // 关键：本地数据一条都不能少（远端坏了不能反向污染本地）
      expect(await f.liveTitles(a), {'heal-me'});
      expect(await f.liveTitles(b), {'heal-me'});

      // 新设备入网：拉不到内容，但必须"安全地拉不到"——
      // 记 skip 留待重试，而不是把远端条目当成删除、也不能崩
      final c = await f.addClient('C');
      final rc = await f.sync(c);
      expect(rc.success, isTrue, reason: '新设备遇到悬空引用不得整次失败');
      expect(
        rc.failedNoteUuids,
        isEmpty,
        reason: 'blob 缺失走 skip（可能是他端没传完）而非 corrupt，不该报数据损坏',
      );
      expect(
        rc.actions.any(
          (x) =>
              x.type == SyncActionType.skip &&
              (x.message ?? '').contains('blob missing'),
        ),
        isTrue,
        reason: '必须显式记录 skip 动作，否则悬空引用会变成静默数据丢失',
      );
      expect(await f.liveTitles(c), isEmpty, reason: '拉不到就是拉不到，不许编造内容');
      await c.journal.close();
    });

    test('远端 blob 丢失 → repairRemote 才是自愈入口，新设备随后能拉全', () async {
      final a = f.clients[0];
      final b = f.clients[1];
      await f.createNote(a, 'heal-me');
      await f.createNote(a, 'heal-me-2');
      await f.sync(a);
      await f.sync(b);
      expect(await f.liveTitles(b), {'heal-me', 'heal-me-2'});

      final blobsDir = Directory(p.join(f.vaultDir, 'blobs'));
      final before = blobsDir.listSync().length;
      expect(before, 2, reason: '两条笔记应有两个内容寻址 blob');
      for (final e in blobsDir.listSync()) {
        if (e is File) await e.delete();
      }

      // A 本地持有全部明文 → 全量体检应把两个 blob 都补回来
      f.activate(a);
      final repair = await a.engine.repairRemote();
      expect(repair.success, isTrue);
      expect(
        repair.actions.where((x) => x.type == SyncActionType.heal).length,
        2,
        reason: 'repairRemote 必须为每个缺失 blob 触发一次 heal 重传',
      );
      expect(blobsDir.listSync().length, before, reason: '自愈后 blob 数量应完全恢复');

      // 真正的验收：一台从没见过这些数据的新设备能不能拉全
      final c = await f.addClient('C');
      final rc = await f.sync(c);
      expect(rc.success, isTrue);
      expect(await f.liveTitles(c), {
        'heal-me',
        'heal-me-2',
      }, reason: '自愈的意义就在于新设备能重新拿到完整内容');

      // 老设备不受影响
      await f.converge();
      expect(await f.liveTitles(a), {'heal-me', 'heal-me-2'});
      expect(await f.liveTitles(b), {'heal-me', 'heal-me-2'});
      await c.journal.close();
    });

    test('远端 blob 丢失且全网无明文 → 标记损坏，绝不静默删除', () async {
      final a = f.clients[0];
      await f.createNote(a, 'orphan');
      await f.sync(a);

      // 制造"全网都没有明文"：删远端 blob + 抹掉 A 本地这条笔记的物理记录
      final blobsDir = Directory(p.join(f.vaultDir, 'blobs'));
      for (final e in blobsDir.listSync()) {
        if (e is File) await e.delete();
      }
      f.activate(a);
      await a.db.delete(tableNotes); // 直接删表行：模拟本地库损坏/被清

      // 体检：无处可救 → 必须"保留远端条目 + 标记跳过"，不能把条目抹掉
      final repair = await a.engine.repairRemote();
      expect(repair.success, isTrue, reason: '救不回来也不能让修复流程崩掉');
      expect(
        repair.actions.any(
          (x) =>
              x.type == SyncActionType.skip &&
              (x.message ?? '').contains('无本机明文'),
        ),
        isTrue,
        reason: '无明文可救时必须显式跳过并保留条目，等其他设备来救',
      );

      // 远端条目仍在（新设备下次仍会尝试，其他设备仍有机会自愈）
      final resp = await f.backend.getManifest();
      final m = await ManifestCrypto.deserialize(f.dataKey, resp.ciphertext);
      expect(m.items.length, 1, reason: '救不回来就删条目 = 用"修复"的名义造成永久数据丢失，绝对禁止');
      expect(
        m.items.values.single.deleted,
        isFalse,
        reason: '不得把救不回来的笔记标记为已删除',
      );
    });

    // ── 墓碑 GC：超期才清，且清完不许复活 ──────────────────────
    //
    // 为什么单独写：墓碑 GC 是「有意的数据删除」，与本组其他用例（严禁删除）
    // 方向相反，最容易在重构中把阈值方向写反或漏写 purgedUuids。而它的触发
    // 条件是「软删除满 30 天」，随机混沌与 longrun 都跑不到那个时间点，
    // 只能靠回填 updated_at 直接把时间推过去。
    test('墓碑超 30 天 → GC 清除，且不会被其他端复活', () async {
      final a = f.clients[0];
      final b = f.clients[1];

      final keep = await f.createNote(a, 'keep-me');
      final doomed = await f.createNote(a, 'delete-me');
      await f.converge();
      expect(await f.liveTitles(b), {'keep-me', 'delete-me'});

      // A 端删除 → B 端收到墓碑并应用
      f.activate(a);
      final row = await NotesDatabase.instance.readNoteByUuid(doomed.uuid);
      await NotesDatabase.instance.softDelete(row!.id!);
      await f.converge();
      expect(await f.liveTitles(b), {'keep-me'}, reason: '删除应先正常同步到 B');

      // 墓碑此刻是"近期的"：必须还留在 manifest 里（离线设备还没来取）
      var m = await ManifestCrypto.deserialize(
        f.dataKey,
        (await f.backend.getManifest()).ciphertext,
      );
      expect(
        m.items[doomed.uuid]?.deleted,
        isTrue,
        reason: '近期墓碑必须保留，否则离线设备永远收不到这条删除',
      );

      // 把两端的墓碑时间戳回填到 31 天前（直接改行，等价于"时间过去了"）
      final longAgo =
          DateTime.now().millisecondsSinceEpoch -
          SyncEngine.kTombstoneGcThresholdMs -
          const Duration(days: 1).inMilliseconds;
      for (final c in [a, b]) {
        f.activate(c);
        await c.db.update(
          tableNotes,
          {NoteFields.updatedAt: longAgo},
          where: '${NoteFields.uuid} = ?',
          whereArgs: [doomed.uuid],
        );
      }

      // A 同步 → 超期墓碑被 GC：本地硬删 + 远端 manifest 条目消失
      await f.sync(a);
      m = await ManifestCrypto.deserialize(
        f.dataKey,
        (await f.backend.getManifest()).ciphertext,
      );
      expect(
        m.items.containsKey(doomed.uuid),
        isFalse,
        reason: '超期墓碑应被 GC 出 manifest，否则墓碑无限累积',
      );
      expect(
        m.items.containsKey(keep.uuid),
        isTrue,
        reason: 'GC 只能清墓碑，不许误伤活跃笔记',
      );

      f.activate(a);
      expect(
        await NotesDatabase.instance.readNoteByUuid(doomed.uuid),
        isNull,
        reason: 'GC 后本地记录应被硬删除',
      );

      // 关键：B 端再同步不能把这条"复活"成活跃笔记
      await f.converge();
      expect(await f.liveTitles(a), {'keep-me'}, reason: 'GC 后不得复活为活跃笔记');
      expect(await f.liveTitles(b), {'keep-me'}, reason: 'GC 后不得复活为活跃笔记');
      m = await ManifestCrypto.deserialize(
        f.dataKey,
        (await f.backend.getManifest()).ciphertext,
      );
      expect(
        m.items.containsKey(doomed.uuid),
        isFalse,
        reason: 'B 端本地墓碑也已超期，不得把条目重新写回 manifest',
      );
    });
  });
}
