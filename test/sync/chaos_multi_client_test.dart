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

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:safenotes/models/safenote.dart';
import 'package:safenotes/data/database_handler.dart';
import 'package:safenotes/sync/sync_engine.dart';
import 'package:safenotes/sync/vault.dart';
import 'package:safenotes/sync/sync_models.dart';
import 'package:safenotes/sync/local_fs_backend.dart';

// ──────────────────────────────────────────────
// 常量
// ──────────────────────────────────────────────

/// 118 测试副本（项目内 temp/safenotes-vault），运行前克隆，绝不修改原件。
const String kSourceVaultRel = 'temp/safenotes-vault';

/// 克隆目标根目录（运行目录内 temp/chaos）。
const String kChaosRootRel = 'temp/chaos';

/// 打开真实 vault 的候选密码（已探测确认 hello.5555 为当前密码，放首位省 PBKDF2）。
const List<String> kRealVaultPasswords = ['hello.5555'];

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
  ChaosClient(this.id, this.db, this.vault, this.engine, this.currentPassword);

  final String id;
  final Database db; // 各自独立文件型 SQLite（通过 setDatabaseForTesting 切换活跃）
  Vault vault;
  SyncEngine engine;
  String currentPassword; // 该客户端当前用于开库的密码
}

// ──────────────────────────────────────────────
// 混沌驱动
// ──────────────────────────────────────────────

class ChaosHarness {
  final List<String> trace = [];
  final LogicalModel model = LogicalModel();
  final Set<String> knownPasswords = <String>{};

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

  /// 上传初始空 manifest（兜底全新 vault 用）。
  static Future<void> _uploadEmptyManifest(
    LocalFsBackend backend,
    Vault vault,
  ) async {
    final header = ManifestHeader(
      schemaVersion: 1,
      version: 1,
      vaultId: vault.vaultId,
      createdAt: vault.createdAt,
      updatedAt: vault.createdAt,
      keyFingerprint: vault.keyFingerprint,
      keyVersion: vault.keyVersion,
      encryptedDataKey: vault.encryptedDataKey,
      kdf: vault.kdf,
      dataKeyWrap: 'AES-256-GCM',
      lastModifiedBy: 'chaos-seed',
    );
    final manifest = Manifest(header: header, items: <String, ManifestItem>{});
    final bytes = ManifestCrypto.serialize(vault.dataKey, manifest);
    await backend.putManifest(bytes, '');
  }

  /// 克隆源 vault 到目标目录（递归复制 manifest.json + blobs/）。
  static Future<void> _cloneVault(String src, String dst) async {
    final srcDir = Directory(src);
    if (!srcDir.existsSync()) {
      throw StateError('源 vault 不存在: $src');
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

  /// 用候选密码打开真实 vault，返回首个成功的解锁结果。
  static Future<({Vault vault, String password})> _openRealVault(
    LocalFsBackend backend,
    List<String> passwords,
  ) async {
    final resp = await backend.getManifest();
    final header = ManifestCrypto.deserializeHeaderOnly(resp.ciphertext);
    for (final pw in passwords) {
      try {
        final vault = await Vault.unlockFromRemoteManifest(
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
        return (vault: vault, password: pw);
      } on WrongPasswordException {
        // 试下一个候选密码
      }
    }
    throw StateError('所有候选密码都无法打开真实 vault: $passwords');
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
      trace.add('    SYNC${tag.isEmpty ? '' : '($tag)'} client=${c.id} '
          '$t uuid=${a.uuid} hash=${a.hash == null ? '-' : a.hash!.substring(0, 10)} '
          '${a.message ?? ''}');
      // 仅对引擎明确标记的冲突副本补充 model（避免误判合法 hash 共享）
      if (a.message != null && a.message!.startsWith('conflict-copy from ')) {
        model.addHash(a.uuid, a.hash!);
      }
    }
    return r;
  }

  /// 纪元不匹配协调：用 knownPasswords 中某个密码重新解锁远端 vault，刷新本地 vault。
  Future<void> _reconcile(
    ChaosClient c,
    SyncResult result,
    LocalFsBackend backend,
  ) async {
    var current = result;
    for (var attempt = 0; attempt < 4 && current.passwordEpochMismatch; attempt++) {
      final resp = await backend.getManifest();
      final header = ManifestCrypto.deserializeHeaderOnly(resp.ciphertext);
      final remoteKv = header.keyVersion;
      if (remoteKv <= c.vault.keyVersion) {
        current = await _sync(c, tag: "reconcile-retry");
        continue;
      }
      var unlocked = false;
      // 倒序：最新密码最可能是远端当前密码，避免逐个 PBKDF2 浪费
      for (final pw in knownPasswords.toList().reversed) {
        try {
          final v = await Vault.unlockFromRemoteManifest(
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
          c.vault = v;
          c.engine.vault = v;
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

    // 1. 克隆真实 vault（绝不碰原件）
    await _removeDir(runDir);
    await _cloneVault(
      p.join(Directory.current.path, kSourceVaultRel),
      vaultDir,
    );

    // 2. 先探测真实克隆 vault 能否用候选密码打开（用指向克隆的临时 backend）。
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

    // 3+4. 构建多客户端（各自独立 DB + 各自 vault）。
    // 真实数据模式：复用克隆 backend，打开真实 118 vault，载入基线模型。
    // 兜底模式：真实密码不匹配，改用全新空 vault（独立目录，绝不覆盖克隆）。
    clients = <ChaosClient>[];
    if (usingRealData && workingPassword != null) {
      backend = probeBackend;
      knownPasswords.add(workingPassword!);
      // 共享 dataKey（vault 级，改密码不变）+ 基线模型（真实 118 数据）
      final probeResp = await backend.getManifest();
      final probeVault = (await _openRealVault(backend, [workingPassword!])).vault;
      sharedDataKey = probeVault.dataKey;
      final baseline =
          ManifestCrypto.deserialize(sharedDataKey, probeResp.ciphertext);
      for (final entry in baseline.items.entries) {
        model.addHash(entry.key, entry.value.hash);
        if (entry.value.deleted) model.markDeleted(entry.key);
      }
      trace.add('MODE=real-data kv=${probeVault.keyVersion} '
          'baseline=${baseline.items.length}');
      for (var i = 0; i < clientCount; i++) {
        final id = String.fromCharCode(65 + i); // A, B, C, ...
        final db = await _newDb(p.join(runDir, 'client-$id.db'));
        NotesDatabase.setDatabaseForTesting(db);
        final cOpened = await _openRealVault(backend, [workingPassword!]);
        clients.add(ChaosClient(
          id,
          db,
          cOpened.vault,
          _buildEngine(cOpened.vault, id),
          cOpened.password,
        ));
      }
    } else {
      // 兜底：全新空 vault（独立目录），仍完整验证引擎的密钥纪元/迁移/repair 逻辑。
      print('WARN seed 模式: 真实 vault 打不开（密码不匹配），'
          '回退到全新空 vault 跑混沌（真实数据校验需正确密码）。');
      final freshDir = p.join(runDir, 'fresh-vault');
      await Directory(freshDir).create(recursive: true);
      backend = LocalFsBackend(rootPath: freshDir);
      await backend.init();
      workingPassword = 'chaos-seed-pw';
      knownPasswords.add(workingPassword!);
      // 首个客户端创建新 vault 并上传初始空 manifest
      final db0 = await _newDb(p.join(runDir, 'creator.db'));
      NotesDatabase.setDatabaseForTesting(db0);
      final newVault = await Vault.createNew(
        password: workingPassword!,
        database: NotesDatabase.instance,
      );
      sharedDataKey = newVault.dataKey;
      await _uploadEmptyManifest(backend, newVault);
      await db0.close(); // creator DB 只用于建 vault，用完即关
      trace.add('MODE=fresh-vault (真实密码不匹配，回退)');
      for (var i = 0; i < clientCount; i++) {
        final id = String.fromCharCode(65 + i);
        final db = await _newDb(p.join(runDir, 'client-$id.db'));
        NotesDatabase.setDatabaseForTesting(db);
        // 每个客户端（含 A）都从远端 manifest 解锁，保证 vault meta 落到各自 DB。
        final vault = (await _openRealVault(backend, [workingPassword!])).vault;
        clients.add(ChaosClient(
          id,
          db,
          vault,
          _buildEngine(vault, id),
          workingPassword!,
        ));
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
    for (var step = 0; step < ops; step++) {
      final c = clients[rng.nextInt(clients.length)];
      final roll = rng.nextInt(100);
      final String op;
      if (roll < 30) {
        op = 'create';
      } else if (roll < 55) {
        op = 'edit';
      } else if (roll < 70) {
        op = 'delete';
      } else if (roll < 95) {
        op = 'sync';
      } else {
        op = 'changePassword';
      }
      await Future.delayed(Duration(milliseconds: rng.nextInt(50)));
      _activate(c);
      try {
        await _applyOp(c, op, rng);
      } catch (e, st) {
        trace.add('[step $step] ERROR client=${c.id} op=$op : $e');
        try {
          final rows = await c.db.query('safe_notes');
          trace.add('  rawNotes=${rows.length} '
              'sharedKey=${sharedDataKey.join(',')} '
              'vaultKey=${c.vault.dataKey.join(',')} '
              'keysEqual=${_bytesEq(sharedDataKey, c.vault.dataKey)}');
          for (final r in rows.take(5)) {
            final title = r['title'];
            trace.add('  row uuid=${r['uuid']} deleted=${r['deleted']} '
                'titleType=${title.runtimeType} titleLen=${title is String ? title.length : '?'}');
          }
          final rm = await backend.getManifest();
          try {
            final rmManifest =
                ManifestCrypto.deserialize(sharedDataKey, rm.ciphertext);
            trace.add('  backendPath=${backend.rootPath} '
                'remoteItems=${rmManifest.items.length}');
          } on Object catch (de) {
            trace.add('  backendPath=${backend.rootPath} '
                'remoteDeserializeFAIL=$de');
          }
        } catch (e2) {
          trace.add('  rawQueryErr=$e2');
        }
        rethrow;
      }
      trace.add(
        '[step $step] client=${c.id} op=$op kv=${c.vault.keyVersion} '
        'known=${knownPasswords.length}',
      );
      // fail-fast 本地对账：每步检查所有客户端本地行（含墓碑），
      // 若某行 hash 不在自己 uuid 的合法集合、却属于其他 uuid → 本地错位现场。
      for (final cc in clients) {
        NotesDatabase.setDatabaseForTesting(cc.db);
        NotesDatabase.instance.setDataKey(sharedDataKey);
        final rows =
            await NotesDatabase.instance.readAllNotesIncludingDeleted();
        for (final n in rows) {
          final legal = model.hashes[n.uuid];
          if (legal == null || legal.contains(n.contentHash)) continue;
          final owners = model.hashes.entries
              .where((x) => x.value.contains(n.contentHash))
              .map((x) => x.key)
              .toList();
          if (owners.isEmpty) continue; // 未知 hash（如冲突副本重算）另案处理
          trace.add('[step $step] LOCAL-MISWIRE 发现于 client=${cc.id} '
              '(本步操作 client=${c.id} op=$op) uuid=${n.uuid} '
              'hash=${n.contentHash.substring(0, 10)} deleted=${n.deleted} '
              'hash属于=$owners');
          fail('本地跨 uuid 错位 @step $step 库=${cc.id} 操作端=${c.id} op=$op '
              'uuid=${n.uuid}');
        }
      }
      _activate(c);
      // fail-fast 影子对账：远端 manifest 中任何 uuid 的 hash 变化，
      // 必须落在该 uuid 的合法写入集合内（或是引擎冲突副本的新 uuid）。
      // 第一时间抓住"跨 uuid 内容错位"被写上远端的精确 step + 客户端。
      try {
        final rm = ManifestCrypto.deserialize(
            sharedDataKey, (await backend.getManifest()).ciphertext);
        for (final e in rm.items.entries) {
          final prev = _shadowRemote[e.key];
          if (prev == e.value.hash) continue; // 未变化
          final legal = model.hashes[e.key];
          if (legal != null && !legal.contains(e.value.hash)) {
            final owners = model.hashes.entries
                .where((x) => x.value.contains(e.value.hash))
                .map((x) => x.key)
                .toList();
            trace.add('[step $step] REMOTE-MISWIRE client=${c.id} op=$op '
                'uuid=${e.key} prev=${prev?.substring(0, 10)} '
                'now=${e.value.hash.substring(0, 10)} deleted=${e.value.deleted} '
                'updatedBy=${e.value.updatedBy} hash属于=$owners');
            fail('远端 manifest 跨 uuid 错位 @step $step client=${c.id} op=$op '
                'uuid=${e.key}');
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

    // 成功则关闭各 DB 并清理克隆目录（失败时保留以便排查）
    for (final c in clients) {
      try {
        await c.db.close();
      } catch (_) {}
    }
    try {
      await probeDb.close();
    } catch (_) {}
    await _removeDir(runDir);
  }

  SyncEngine _buildEngine(Vault vault, String deviceId) => SyncEngine(
        backend: backend,
        database: NotesDatabase.instance,
        vault: vault,
        deviceId: deviceId,
      );

  /// 新建独立文件型 DB（避免 :memory: 在同一进程内被多个 openDatabase 共享导致串库）。
  static Future<Database> _newDb(String path) =>
      openDatabase(path, version: 2, onCreate: NotesDatabase.createDBForTesting);

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
        final newVault = await c.vault.changePassword(
          oldPassword: c.currentPassword,
          newPassword: newPw,
          database: NotesDatabase.instance,
        );
        c.vault = newVault;
        c.engine.vault = newVault;
        c.currentPassword = newPw;
        knownPasswords.add(newPw);
        final r = await _sync(c, tag: "post-pw");
        await _reconcile(c, r, backend);
        break;
    }
  }

  /// 7 条不变量断言。
  Future<void> _assertInvariants() async {
    // 收集每客户端本地状态
    final states = <String, Map<String, ({String contentHash, bool deleted})>>{};
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
          expect(model.everDeleted.contains(uuid), isTrue,
              reason: '不变量1 失败: client ${c.id} 缺失从未被删除的笔记 $uuid(真丢失)');
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
            final rm = ManifestCrypto.deserialize(
                sharedDataKey, (await backend.getManifest()).ciphertext);
            final ri = rm.items[uuid];
            remoteInfo = ri == null
                ? 'absent'
                : 'hash=${ri.hash} deleted=${ri.deleted} '
                    'updatedBy=${ri.updatedBy} updatedAt=${ri.updatedAt}';
          } catch (_) {}
          fail('不变量2 失败: client ${c.id} 笔记 $uuid 终态 hash '
              '${got.contentHash} 不在合法集合 legal=$legalHashes\n'
              '  该 hash 属于其他 uuid: $owners\n'
              '  远端 manifest: $remoteInfo');
        }
        if (got.deleted) {
          expect(model.everDeleted.contains(uuid), isTrue,
              reason: '不变量2b 失败: client ${c.id} 笔记 $uuid 被标删除但从未有删除操作(幽灵删除)');
        }
      }
    }

    // 不变量 4：无幽灵笔记（客户端存在但 model 从未见过该 uuid）
    for (final c in clients) {
      for (final uuid in states[c.id]!.keys) {
        expect(model.hashes.containsKey(uuid), isTrue,
            reason: '不变量4 失败: client ${c.id} 存在幽灵笔记 $uuid');
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
        expect(live, equals(ref),
            reason: '不变量3 失败: client ${c.id} 活跃笔记集合未与首端收敛');
      }
    }

    // 不变量 5：密钥一致性（keyVersion 全网一致）
    final keyVersions = clients.map((c) => c.vault.keyVersion).toSet();
    expect(keyVersions.length, 1,
        reason: '不变量5 失败: 各客户端 keyVersion 未收敛 $keyVersions');

    // 不变量 6：manifest 完整性（远端可解析 + keyVersion 与客户端一致）
    final remoteKv = await _remoteKeyVersion(backend);
    expect(remoteKv, clients.first.vault.keyVersion,
        reason: '不变量6 失败: 远端 keyVersion 与客户端不一致');

    // 不变量 7：无遗留坏 blob（最终同步后 failedNoteUuids 为空）
    for (final c in clients) {
      _activate(c);
      final r = await _sync(c, tag: "inv7");
      expect(r.failedNoteUuids, isEmpty,
          reason: '不变量7 失败: client ${c.id} 仍有失败 blob ${r.failedNoteUuids}');
    }
  }
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
    for (final seed in const [1, 7, 42, 2026, 99999]) {
      test('seed=$seed 三客户端随机混沌', () async {
        final harness = ChaosHarness();
        try {
          await harness.run(seed: seed, ops: 120, cooldown: 8, clientCount: 3);
        } catch (e, st) {
          // 失败后保留克隆目录以便排查；打印 seed + 轨迹
          print('=== CHAOS FAIL seed=$seed ===');
          print('trace:\n${harness.trace.join('\n')}');
          rethrow;
        }
        // 关键：不给 timeout 会用默认 30s。超时的测试其异步循环不会被杀死，
        // 残留循环会通过全局 DB 单例污染下一个测试（已实际踩坑）。
      }, timeout: const Timeout(Duration(minutes: 10)));
    }

    // 命令行自定义 seed：通过环境变量 CHAOS_SEEDS 传入逗号分隔的 seed 列表。
    // 用法（pwsh）:
    //   $env:CHAOS_SEEDS="123,456,789"; flutter test test/sync/chaos_multi_client_test.dart --plain-name "自定义"
    // 用法（bash）:
    //   CHAOS_SEEDS=123,456 flutter test test/sync/chaos_multi_client_test.dart --plain-name "自定义"
    // 不传时此 test 直接跳过，不影响默认 5 个 seed 的运行。
    // 单个 seed 失败不会中断后续 seed，所有 seed 跑完后统一报告失败列表。
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
      print('自定义 seed 运行: $seeds（共 ${seeds.length} 个）');
      final failures = <int>[];
      final sw = Stopwatch()..start();
      for (var i = 0; i < seeds.length; i++) {
        final seed = seeds[i];
        final seedSw = Stopwatch()..start();
        print('─── [${i + 1}/${seeds.length}] seed=$seed 开始 ───');
        final harness = ChaosHarness();
        try {
          await harness.run(seed: seed, ops: 120, cooldown: 8, clientCount: 3);
          print('─── [${i + 1}/${seeds.length}] seed=$seed 通过'
              '（${seedSw.elapsed.inSeconds}s，累计 ${sw.elapsed.inSeconds}s）───');
        } catch (e, st) {
          failures.add(seed);
          print('=== CHAOS FAIL seed=$seed ===');
          print('trace:\n${harness.trace.join('\n')}');
          print('─── [${i + 1}/${seeds.length}] seed=$seed 失败'
              '（${seedSw.elapsed.inSeconds}s，累计 ${sw.elapsed.inSeconds}s）───');
        }
      }
      print('总计: ${seeds.length} 个 seed，${seeds.length - failures.length} 通过，'
          '${failures.length} 失败，耗时 ${sw.elapsed.inSeconds}s');
      if (failures.isNotEmpty) {
        fail('失败的 seed: $failures');
      }
    }, timeout: const Timeout(Duration(minutes: 30)));
  });
}
