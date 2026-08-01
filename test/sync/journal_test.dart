/*
 * Journal 单元测试（P2 设计 §3）
 *
 * 覆盖 Journal 作为「审计 + 可恢复第二数据源」的全部承诺：
 *   1. 追加与 seq：单调递增、跨归档连续、重开后水位不回退
 *   2. 滚动归档：1000 条 / 100KB 双阈值、归档保留 3 份
 *   3. 容错：日志损坏、vaultId 串库、坏条目、未知事件类型
 *   4. 恢复线索：findIncompleteOperations（只报不修）、replayKeyState
 *   5. 远端加密副本：密文不落明文、跨设备去重合并、错误 dataKey 拒绝
 *   6. 降级：内存模式、沙盒目录不可用时 openOrMemory 不抛异常
 *
 * 设计立场（这些测试锁死的是"绝不能退化"的行为）：
 *   - Journal 是辅助设施，它自身的任何故障都不得抛异常打断同步主流程；
 *   - findIncompleteOperations 只回答"哪些没记完成"，永不自动重放；
 *   - 远端副本永不落明文。
 */

// Dart 导入
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// Package 导入
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:safenotes/sync/crypto.dart';
import 'package:safenotes/sync/journal.dart';
import 'package:safenotes/sync/sync_backend.dart';

// 测试公共支撑（FakeJournalStore：真存的远端 journal 对象表）
import 'sync_test_support.dart';

// ──────────────────────────────────────────────
// 测试替身
// ──────────────────────────────────────────────

/// 只提供 journal 资源能力的最小后端替身
///
/// 继承 SyncBackend（而非 implements）以复用其余方法的默认实现，
/// journal 三件套由 [FakeJournalStore] 提供真实内存存储。
class _FakeBackend extends SyncBackend with FakeJournalStore {
  @override
  String get displayName => 'fake';

  @override
  String get providerKey => 'fake';

  @override
  Future<void> init() async {}

  @override
  Future<bool> ping() async => true;

  @override
  Future<({Uint8List ciphertext, String etag})> getManifest() async =>
      (ciphertext: Uint8List(0), etag: '');

  @override
  Future<String> putManifest(Uint8List ciphertext, String expectedEtag) async =>
      'etag-1';

  @override
  Future<Uint8List?> getBlob(String hash) async => null;

  @override
  Future<void> putBlob(String hash, Uint8List data) async {}

  @override
  Future<void> close() async {}
}

/// putJournalObject 永远失败的后端（验证"上传失败不抛异常"）
class _FailingJournalBackend extends _FakeBackend {
  @override
  Future<void> putJournalObject(String name, Uint8List ciphertext) async {
    throw const FileSystemException('journal 上传失败（注入）');
  }
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('journal_test_');
  });

  tearDown(() async {
    try {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    } on FileSystemException {
      // Windows 上偶发文件句柄未释放，忽略即可（临时目录由系统回收）
    }
  });

  /// journal 实际落盘目录
  String journalDir() => p.join(tmp.path, 'journal');

  /// 直接写一份原始 log.json（用于构造损坏 / 串库 / 陈旧时间戳等场景）
  Future<void> writeRawLog(String content) async {
    await Directory(journalDir()).create(recursive: true);
    await File(p.join(journalDir(), 'log.json')).writeAsString(content);
  }

  /// 列出 journal 目录下匹配前缀的文件名
  Future<List<String>> listFiles({String prefix = ''}) async {
    final dir = Directory(journalDir());
    if (!await dir.exists()) return [];
    final names = <String>[];
    await for (final e in dir.list()) {
      final name = p.basename(e.path);
      if (name.startsWith(prefix)) names.add(name);
    }
    names.sort();
    return names;
  }

  Future<Journal> openJournal({
    String vaultId = 'vault-1',
    String deviceId = 'dev-a',
  }) =>
      Journal.open(baseDir: tmp.path, vaultId: vaultId, deviceId: deviceId);

  // ════════════════════════════════════════════
  group('Journal - 追加与 seq 水位', () {
    test('append 返回单调递增 seq，flush 后落盘可读回', () async {
      final j = await openJournal();
      final s1 = j.append(type: JournalEventType.noteUpsert, uuid: 'n1');
      final s2 = j.append(type: JournalEventType.noteDelete, uuid: 'n2');
      expect(s1, 1);
      expect(s2, 2);
      expect(j.pendingCount, 2, reason: 'append 只入缓冲，不同步落盘');

      await j.flush();
      expect(j.pendingCount, 0);
      expect(j.entries.length, 2);

      final raw = jsonDecode(
          await File(p.join(journalDir(), 'log.json')).readAsString()) as Map;
      expect(raw['schemaVersion'], kJournalSchemaVersion);
      expect(raw['vaultId'], 'vault-1');
      expect(raw['deviceId'], 'dev-a');
      expect((raw['entries'] as List).length, 2);
      await j.close();
    });

    test('重开后 seq 水位不回退，且历史条目仍在', () async {
      final j1 = await openJournal();
      j1.append(type: JournalEventType.noteUpsert, uuid: 'n1');
      j1.append(type: JournalEventType.noteUpsert, uuid: 'n2');
      await j1.close();

      final j2 = await openJournal();
      expect(j2.nextSeq, 3, reason: '水位应从落盘最大 seq + 1 续起');
      final s = j2.append(type: JournalEventType.noteUpsert, uuid: 'n3');
      expect(s, 3);
      final all = await j2.readAll();
      expect(all.map((e) => e.uuid).toList(), ['n1', 'n2', 'n3']);
      await j2.close();
    });

    test('readAll(sinceSeq) 只返回增量', () async {
      final j = await openJournal();
      for (var i = 0; i < 5; i++) {
        j.append(type: JournalEventType.noteUpsert, uuid: 'n$i');
      }
      final tail = await j.readAll(sinceSeq: 3);
      expect(tail.map((e) => e.seq).toList(), [4, 5]);
      await j.close();
    });

    test('close 之后 append 返回 -1（不抛异常）', () async {
      final j = await openJournal();
      await j.close();
      expect(j.append(type: JournalEventType.noteUpsert), -1);
    });

    test('条目字段完整往返（含 keyState / opId / phase）', () async {
      final j = await openJournal();
      final opId = j.newOpId();
      j.append(
        type: JournalEventType.keyMigrate,
        phase: JournalPhase.start,
        opId: opId,
        dataKeyEpoch: 2,
        hash: 'deadbeef',
        note: '人类可读说明',
        keyState: const JournalKeyState(
          keyVersion: 2,
          dataKeyEpoch: 2,
          keyFingerprint: 'fp-2',
          encryptedDataKey: 'edk-2',
        ),
      );
      await j.close();

      final reopened = await openJournal();
      final e = (await reopened.readAll()).single;
      expect(e.type, JournalEventType.keyMigrate);
      expect(e.phase, JournalPhase.start);
      expect(e.opId, opId);
      expect(e.dataKeyEpoch, 2);
      expect(e.hash, 'deadbeef');
      expect(e.note, '人类可读说明');
      expect(e.by, 'dev-a');
      expect(e.keyState?.keyVersion, 2);
      expect(e.keyState?.encryptedDataKey, 'edk-2');
      await reopened.close();
    });
  });

  // ════════════════════════════════════════════
  group('Journal - 滚动归档', () {
    test('达到 1000 条阈值后归档，readAll 仍返回全量', () async {
      final j = await openJournal(deviceId: 'd');
      for (var i = 0; i < kJournalMaxEntries; i++) {
        j.append(type: JournalEventType.noteUpsert);
      }
      await j.flush();

      final archives = await listFiles(prefix: 'log-');
      expect(archives.length, 1, reason: '应产生 1 个归档');
      expect(archives.single, 'log-$kJournalMaxEntries.json');
      expect(j.entries, isEmpty, reason: '归档后当前日志清空');
      expect(await File(p.join(journalDir(), 'log.json')).exists(), isTrue,
          reason: '空的新日志必须立即建立，保证文件恒存在');

      final all = await j.readAll();
      expect(all.length, kJournalMaxEntries);
      expect(all.first.seq, 1);
      expect(all.last.seq, kJournalMaxEntries);
      await j.close();

      // 归档中的最大 seq 也要参与水位计算
      final reopened = await openJournal(deviceId: 'd');
      expect(reopened.nextSeq, kJournalMaxEntries + 1);
      await reopened.close();
    });

    test('达到 100KB 阈值后归档（条数未到上限）', () async {
      final j = await openJournal();
      final bigNote = 'x' * 30000; // 单条约 30KB → 4 条即超 100KB
      for (var i = 0; i < 4; i++) {
        j.append(type: JournalEventType.noteUpsert, note: bigNote);
        await j.flush();
      }
      final archives = await listFiles(prefix: 'log-');
      expect(archives.length, 1,
          reason: '条数远未到 1000，应由字节阈值触发归档');
      expect((await j.readAll()).length, 4);
      await j.close();
    });

    test('归档只保留最近 3 份，更早的被淘汰', () async {
      final j = await openJournal();
      final bigNote = 'x' * 30000;
      // 5 轮 × 4 条 → 触发 5 次归档
      for (var i = 0; i < 20; i++) {
        j.append(type: JournalEventType.noteUpsert, note: bigNote);
        await j.flush();
      }
      final archives = await listFiles(prefix: 'log-');
      expect(archives.length, kJournalArchiveKeep,
          reason: '保留份数应恒为 $kJournalArchiveKeep');

      // 被淘汰的是 seq 最小的那些
      final seqs = archives
          .map((n) => int.parse(n.replaceAll(RegExp(r'\D'), '')))
          .toList()
        ..sort();
      expect(seqs.first, greaterThan(4),
          reason: '最早的归档（seq=4）应已被淘汰');
      await j.close();
    });
  });

  // ════════════════════════════════════════════
  group('Journal - 容错与隔离', () {
    test('日志文件损坏 → 隔离取证 + 以空日志继续（不抛异常）', () async {
      await writeRawLog('{ 这不是合法 JSON');
      final j = await openJournal();
      expect(j.entries, isEmpty);
      final quarantined = await listFiles(prefix: 'log.json.corrupt-');
      expect(quarantined.length, 1, reason: '损坏文件应被改名保留取证');

      // 仍可正常工作
      expect(j.append(type: JournalEventType.noteUpsert), 1);
      await j.close();
    });

    test('vaultId 不匹配（串库）→ 隔离并重新开始', () async {
      await writeRawLog(jsonEncode({
        'schemaVersion': 1,
        'vaultId': 'OTHER-VAULT',
        'deviceId': 'dev-a',
        'entries': [
          {'seq': 7, 'ts': 1, 'type': 'note.upsert', 'by': 'dev-a'},
        ],
      }));
      final j = await openJournal(vaultId: 'vault-1');
      expect(j.entries, isEmpty, reason: '别的库的 journal 不得混入');
      expect((await listFiles(prefix: 'log.json.vault-mismatch-')).length, 1);
      await j.close();
    });

    test('坏条目被跳过，好条目保留（不整体失败）', () async {
      await writeRawLog(jsonEncode({
        'schemaVersion': 1,
        'vaultId': 'vault-1',
        'deviceId': 'dev-a',
        'entries': [
          {'seq': 1, 'ts': 1, 'type': 'note.upsert', 'by': 'dev-a'},
          {'seq': 'not-an-int', 'ts': 2, 'type': 'note.upsert', 'by': 'x'},
          'garbage',
          {'ts': 3, 'type': 'note.upsert', 'by': 'x'}, // 缺 seq
          {'seq': 4, 'ts': 4, 'type': 'note.delete', 'by': 'dev-a'},
        ],
      }));
      final j = await openJournal();
      expect(j.entries.map((e) => e.seq).toList(), [1, 4]);
      expect(j.nextSeq, 5);
      await j.close();
    });

    test('未知事件类型被跳过（前向兼容：新版写的新类型不让旧版崩）', () async {
      await writeRawLog(jsonEncode({
        'schemaVersion': 99,
        'vaultId': 'vault-1',
        'deviceId': 'dev-a',
        'entries': [
          {'seq': 1, 'ts': 1, 'type': 'note.upsert', 'by': 'dev-a'},
          {'seq': 2, 'ts': 2, 'type': 'future.newEvent', 'by': 'dev-a'},
        ],
      }));
      final j = await openJournal();
      expect(j.entries.length, 1);
      expect(j.entries.single.type, JournalEventType.noteUpsert);
      await j.close();
    });

    test('未知 phase 退化为 none 而非崩溃', () async {
      await writeRawLog(jsonEncode({
        'schemaVersion': 1,
        'vaultId': 'vault-1',
        'deviceId': 'dev-a',
        'entries': [
          {
            'seq': 1,
            'ts': 1,
            'type': 'note.upsert',
            'phase': 'weird-phase',
            'by': 'dev-a',
          },
        ],
      }));
      final j = await openJournal();
      expect(j.entries.single.phase, JournalPhase.none);
      await j.close();
    });

    test('归档文件损坏时被跳过，当前日志仍可读', () async {
      final j = await openJournal();
      final bigNote = 'x' * 30000;
      for (var i = 0; i < 4; i++) {
        j.append(type: JournalEventType.noteUpsert, note: bigNote);
        await j.flush();
      }
      j.append(type: JournalEventType.noteDelete, uuid: 'alive');
      await j.flush();

      // 把唯一的归档写坏
      final archive = (await listFiles(prefix: 'log-')).single;
      await File(p.join(journalDir(), archive)).writeAsString('%%%broken%%%');

      final all = await j.readAll();
      expect(all.map((e) => e.uuid).whereType<String>().toList(), ['alive'],
          reason: '坏归档整份跳过，但不能影响当前日志');
      await j.close();
    });

    test('openOrMemory：沙盒目录不可用时降级内存模式，不抛异常', () async {
      // 用一个"文件"当 baseDir → 其下无法创建 journal 目录
      final blocker = File(p.join(tmp.path, 'not-a-dir'));
      await blocker.writeAsString('x');

      final j = await Journal.openOrMemory(
        baseDir: blocker.path,
        vaultId: 'vault-1',
        deviceId: 'dev-a',
      );
      expect(j.append(type: JournalEventType.noteUpsert), 1);
      await j.flush();
      expect((await j.readAll()).length, 1,
          reason: '降级后语义不变，只是不落盘');
      await j.close();
    });
  });

  // ════════════════════════════════════════════
  group('Journal - 恢复线索（只报不修）', () {
    test('findIncompleteOperations 报告悬挂的 start', () async {
      final j = await openJournal();
      final op = j.newOpId();
      j.append(
        type: JournalEventType.keyMigrate,
        phase: JournalPhase.start,
        opId: op,
      );
      final found = await j.findIncompleteOperations(minAge: Duration.zero);
      expect(found.length, 1);
      expect(found.single.start.opId, op);
      expect(found.single.start.type, JournalEventType.keyMigrate);
      await j.close();
    });

    test('done / failed 配对后不再报告', () async {
      final j = await openJournal();
      final opDone = j.newOpId();
      final opFailed = j.newOpId();
      j.append(
          type: JournalEventType.keyMigrate,
          phase: JournalPhase.start,
          opId: opDone);
      j.append(
          type: JournalEventType.keyMigrate,
          phase: JournalPhase.done,
          opId: opDone);
      j.append(
          type: JournalEventType.blobReupload,
          phase: JournalPhase.start,
          opId: opFailed);
      j.append(
          type: JournalEventType.blobReupload,
          phase: JournalPhase.failed,
          opId: opFailed);

      expect(await j.findIncompleteOperations(minAge: Duration.zero), isEmpty);
      await j.close();
    });

    test('minAge 过滤掉"正在进行"的操作（默认 30s）', () async {
      final j = await openJournal();
      j.append(
        type: JournalEventType.keyMigrate,
        phase: JournalPhase.start,
        opId: j.newOpId(),
      );
      expect(await j.findIncompleteOperations(), isEmpty,
          reason: '刚发生的 start 是"正在进行"，不应被当成中断');
      await j.close();
    });

    test('陈旧的 start（跨进程重启）会被报告，且 age 正确', () async {
      final old = DateTime.now()
          .subtract(const Duration(hours: 2))
          .millisecondsSinceEpoch;
      await writeRawLog(jsonEncode({
        'schemaVersion': 1,
        'vaultId': 'vault-1',
        'deviceId': 'dev-a',
        'entries': [
          {
            'seq': 1,
            'ts': old,
            'type': 'blob.reupload',
            'phase': 'start',
            'opId': 'op-old',
            'by': 'dev-a',
          },
        ],
      }));
      final j = await openJournal();
      final found = await j.findIncompleteOperations();
      expect(found.length, 1);
      expect(found.single.age.inMinutes, greaterThanOrEqualTo(119));
      await j.close();
    });

    test('findIncompleteOperations 绝不修改日志（只读语义）', () async {
      final j = await openJournal();
      j.append(
        type: JournalEventType.keyMigrate,
        phase: JournalPhase.start,
        opId: j.newOpId(),
      );
      await j.flush();
      final before = await File(p.join(journalDir(), 'log.json')).readAsString();
      await j.findIncompleteOperations(minAge: Duration.zero);
      final after = await File(p.join(journalDir(), 'log.json')).readAsString();
      expect(after, before, reason: '恢复以 DB 为准，journal 永不自动重放');
      await j.close();
    });
  });

  // ════════════════════════════════════════════
  group('Journal - replayKeyState', () {
    JournalKeyState ks(int v, int epoch) => JournalKeyState(
          keyVersion: v,
          dataKeyEpoch: epoch,
          keyFingerprint: 'fp-$v',
          encryptedDataKey: 'edk-$v',
        );

    test('无 key.* 事件时返回 null', () async {
      final j = await openJournal();
      j.append(type: JournalEventType.noteUpsert, uuid: 'n1');
      expect(await j.replayKeyState(), isNull);
      await j.close();
    });

    test('取 seq 最大的已完成 key 事件', () async {
      final j = await openJournal();
      j.append(
        type: JournalEventType.keyChangePassword,
        phase: JournalPhase.done,
        keyState: ks(2, 1),
      );
      j.append(
        type: JournalEventType.keyAdoptEpoch,
        phase: JournalPhase.done,
        keyState: ks(3, 2),
      );
      final replayed = await j.replayKeyState();
      expect(replayed?.keyVersion, 3);
      expect(replayed?.dataKeyEpoch, 2);
      expect(replayed?.encryptedDataKey, 'edk-3');
      await j.close();
    });

    test('start / failed 阶段不被采纳（避免坏纪元污染）', () async {
      final j = await openJournal();
      j.append(
        type: JournalEventType.keyMigrate,
        phase: JournalPhase.done,
        keyState: ks(2, 2),
      );
      j.append(
        type: JournalEventType.keyMigrate,
        phase: JournalPhase.start,
        keyState: ks(9, 9),
      );
      j.append(
        type: JournalEventType.keyMigrate,
        phase: JournalPhase.failed,
        keyState: ks(8, 8),
      );
      final replayed = await j.replayKeyState();
      expect(replayed?.keyVersion, 2,
          reason: '只有已完成的密钥变更才是可信的取真来源');
      await j.close();
    });

    test('非 key 事件即使带 keyState 也不参与', () async {
      final j = await openJournal();
      j.append(
        type: JournalEventType.keyChangePassword,
        phase: JournalPhase.done,
        keyState: ks(2, 1),
      );
      j.append(
        type: JournalEventType.noteUpsert,
        keyState: ks(7, 7),
      );
      expect((await j.replayKeyState())?.keyVersion, 2);
      await j.close();
    });

    test('跨归档重放：key 事件在旧归档里也能取到', () async {
      final j = await openJournal();
      j.append(
        type: JournalEventType.keyChangePassword,
        phase: JournalPhase.done,
        keyState: ks(5, 3),
      );
      // 把它挤进归档
      final bigNote = 'x' * 30000;
      for (var i = 0; i < 4; i++) {
        j.append(type: JournalEventType.noteUpsert, note: bigNote);
        await j.flush();
      }
      expect((await listFiles(prefix: 'log-')).length, 1);
      final replayed = await j.replayKeyState();
      expect(replayed?.keyVersion, 5, reason: '归档不应丢失密钥事件');
      await j.close();
    });
  });

  // ════════════════════════════════════════════
  group('Journal - 远端加密副本（第二数据源）', () {
    test('syncToRemote 上传当前日志，密文不含明文', () async {
      final dk = SyncCrypto.generateDataKey();
      final backend = _FakeBackend();
      final j = await openJournal();
      j.append(type: JournalEventType.noteUpsert, uuid: 'secret-uuid');
      await j.syncToRemote(backend, dk);

      expect(backend.journalObjects.keys.toList(), ['dev-a-current.json']);
      final ct = backend.journalObjects['dev-a-current.json']!;
      final asText = String.fromCharCodes(ct);
      expect(asText.contains('note.upsert'), isFalse);
      expect(asText.contains('secret-uuid'), isFalse,
          reason: '远端永不落明文');
      await j.close();
    });

    test('fetchRemoteEntries 解密还原条目', () async {
      final dk = SyncCrypto.generateDataKey();
      final backend = _FakeBackend();
      final j = await openJournal();
      j.append(type: JournalEventType.noteUpsert, uuid: 'n1');
      j.append(
        type: JournalEventType.keyChangePassword,
        phase: JournalPhase.done,
        keyState: const JournalKeyState(
          keyVersion: 2,
          dataKeyEpoch: 1,
          keyFingerprint: 'fp',
          encryptedDataKey: 'edk',
        ),
      );
      await j.syncToRemote(backend, dk);

      final remote = await Journal.fetchRemoteEntries(backend, dk);
      expect(remote.length, 2);
      expect(remote.first.uuid, 'n1');
      expect(remote.last.keyState?.keyVersion, 2);
      await j.close();
    });

    test('错误 dataKey 无法解密，安全返回空列表', () async {
      final dk = SyncCrypto.generateDataKey();
      final wrong = SyncCrypto.generateDataKey();
      final backend = _FakeBackend();
      final j = await openJournal();
      j.append(type: JournalEventType.noteUpsert, uuid: 'n1');
      await j.syncToRemote(backend, dk);

      expect(await Journal.fetchRemoteEntries(backend, wrong), isEmpty);
      await j.close();
    });

    test('多设备副本合并去重（by#seq 为键）', () async {
      final dk = SyncCrypto.generateDataKey();
      final backend = _FakeBackend();

      final dirA = await Directory(p.join(tmp.path, 'a')).create();
      final dirB = await Directory(p.join(tmp.path, 'b')).create();
      final ja = await Journal.open(
          baseDir: dirA.path, vaultId: 'vault-1', deviceId: 'dev-a');
      final jb = await Journal.open(
          baseDir: dirB.path, vaultId: 'vault-1', deviceId: 'dev-b');

      ja.append(type: JournalEventType.noteUpsert, uuid: 'from-a');
      jb.append(type: JournalEventType.noteUpsert, uuid: 'from-b');
      await ja.syncToRemote(backend, dk);
      await jb.syncToRemote(backend, dk);
      // 重复上传不应产生重复条目
      await ja.syncToRemote(backend, dk);

      expect(backend.journalObjects.length, 2,
          reason: '按设备隔离对象名，互不覆盖');
      final merged = await Journal.fetchRemoteEntries(backend, dk);
      expect(merged.map((e) => e.uuid).toSet(), {'from-a', 'from-b'});
      await ja.close();
      await jb.close();
    });

    test('归档也会上传，且上传水位持久化后不重复上传', () async {
      final dk = SyncCrypto.generateDataKey();
      final backend = _FakeBackend();
      final j = await openJournal();
      final bigNote = 'x' * 30000;
      for (var i = 0; i < 4; i++) {
        j.append(type: JournalEventType.noteUpsert, note: bigNote);
        await j.flush();
      }
      await j.syncToRemote(backend, dk);
      expect(
        backend.journalObjects.keys.any((k) => k.contains('archive')),
        isTrue,
        reason: '归档必须上传，否则超期淘汰即永久丢失',
      );
      final uploadedAfterFirst = j.uploadedSeq;
      expect(uploadedAfterFirst, greaterThan(0));

      // 水位落盘
      final state = jsonDecode(
          await File(p.join(journalDir(), '.journal-state.json'))
              .readAsString()) as Map;
      expect(state['uploadedSeq'], uploadedAfterFirst);

      // 无新增时再次同步：对象集合不变
      final snapshot = Map<String, Uint8List>.from(backend.journalObjects);
      await j.syncToRemote(backend, dk);
      expect(backend.journalObjects.length, snapshot.length);
      await j.close();

      // 重开后水位不回退
      final reopened = await openJournal();
      expect(reopened.uploadedSeq, uploadedAfterFirst);
      await reopened.close();
    });

    test('远端上传失败不抛异常（journal 故障不得打断同步）', () async {
      final dk = SyncCrypto.generateDataKey();
      final backend = _FailingJournalBackend();
      final j = await openJournal();
      j.append(type: JournalEventType.noteUpsert, uuid: 'n1');
      await expectLater(j.syncToRemote(backend, dk), completes);
      expect(j.uploadedSeq, 0, reason: '失败不得推进水位，下次仍会重传');
      await j.close();
    });

    test('内存模式不上传远端（无文件可传）', () async {
      final dk = SyncCrypto.generateDataKey();
      final backend = _FakeBackend();
      final j = Journal.inMemory(vaultId: 'vault-1', deviceId: 'mem');
      j.append(type: JournalEventType.noteUpsert, uuid: 'n1');
      await j.syncToRemote(backend, dk);
      expect(backend.journalObjects, isEmpty);
      await j.close();
    });
  });

  // ════════════════════════════════════════════
  group('Journal - 内存模式与统计', () {
    test('内存模式不产生任何文件', () async {
      final j = Journal.inMemory(vaultId: 'vault-1', deviceId: 'mem');
      j.append(type: JournalEventType.noteUpsert, uuid: 'n1');
      await j.flush();
      expect((await j.readAll()).length, 1);
      expect(await Directory(journalDir()).exists(), isFalse);
      await j.close();
    });

    test('内存模式条目数被裁剪到上限，防内存无限增长', () async {
      final j = Journal.inMemory(vaultId: 'vault-1', deviceId: 'mem');
      for (var i = 0; i < kJournalMaxEntries + 120; i++) {
        j.append(type: JournalEventType.noteUpsert);
      }
      await j.flush();
      expect(j.entries.length, kJournalMaxEntries);
      expect(j.entries.last.seq, kJournalMaxEntries + 120,
          reason: '裁剪应保留最近的条目');
      await j.close();
    });

    test('stats 汇总类型分布与归档数', () async {
      final j = await openJournal();
      j.append(type: JournalEventType.noteUpsert, uuid: 'n1');
      j.append(type: JournalEventType.noteUpsert, uuid: 'n2');
      j.append(type: JournalEventType.noteConflict, uuid: 'n1');
      final s = await j.stats();
      expect(s['total'], 3);
      expect(s['pending'], 0);
      expect(s['archives'], 0);
      expect((s['byType']! as Map)['note.upsert'], 2);
      expect((s['byType']! as Map)['note.conflict'], 1);
      await j.close();
    });
  });

  // ════════════════════════════════════════════
  group('Journal - 枚举 wire 契约', () {
    test('事件类型 wire 值与设计文档一致（改动即破坏兼容）', () {
      expect(JournalEventType.noteUpsert.wire, 'note.upsert');
      expect(JournalEventType.noteDelete.wire, 'note.delete');
      expect(JournalEventType.noteConflict.wire, 'note.conflict');
      expect(JournalEventType.noteHeal.wire, 'note.heal');
      expect(JournalEventType.blobReupload.wire, 'blob.reupload');
      expect(JournalEventType.keyChangePassword.wire, 'key.changePassword');
      expect(JournalEventType.keyMigrate.wire, 'key.migrate');
      expect(JournalEventType.keyAdoptEpoch.wire, 'key.adoptEpoch');
      expect(JournalEventType.syncGcOrphan.wire, 'sync.gcOrphan');
      expect(JournalEventType.syncManifestRebuild.wire, 'sync.manifestRebuild');
    });

    test('isKeyEvent 只覆盖三类密钥事件', () {
      final keyEvents = JournalEventType.values.where((e) => e.isKeyEvent);
      expect(keyEvents.toSet(), {
        JournalEventType.keyChangePassword,
        JournalEventType.keyMigrate,
        JournalEventType.keyAdoptEpoch,
      });
    });

    test('fromWire 未知值返回 null；phase 未知值退化 none', () {
      expect(JournalEventType.fromWire('nope'), isNull);
      expect(JournalPhase.fromWire(null), JournalPhase.none);
      expect(JournalPhase.fromWire('nope'), JournalPhase.none);
      expect(JournalPhase.fromWire('isolated'), JournalPhase.isolated);
    });
  });
}
