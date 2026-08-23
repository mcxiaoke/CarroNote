/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*
*/

import 'dart:io';
import 'dart:typed_data';

import 'package:core/core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _DefaultDummyBackend extends SyncBackend {
  @override
  String get displayName => 'dummy';

  @override
  String get providerKey => 'dummy-provider';

  @override
  Future<void> init() async {}

  @override
  Future<bool> ping() async => true;

  @override
  Future<({Uint8List ciphertext, String etag})> getManifest() async =>
      (ciphertext: Uint8List(0), etag: '');

  @override
  Future<String> putManifest(Uint8List ciphertext, String expectedEtag) async =>
      'etag';

  @override
  Future<Uint8List?> getBlob(String hash) async => null;

  @override
  Future<void> putBlob(String hash, Uint8List data) async {}

  @override
  Future<void> close() async {}
}

void main() {
  group('SyncBackend 通用工具与默认实现测试', () {
    test('checkRemoteReadSize 校验大小上限与超限抛错', () {
      final normalBytes = Uint8List(100);
      expect(
        () => checkRemoteReadSize(normalBytes, 'test', 200),
        returnsNormally,
      );

      final oversizedBytes = Uint8List(201);
      expect(
        () => checkRemoteReadSize(oversizedBytes, 'test', 200),
        throwsA(
          isA<BackendUnavailableException>().having(
            (e) => e.message,
            'msg',
            contains('响应体过大'),
          ),
        ),
      );
    });

    test('writeRingBackup 环形槽位轮转与原子写', () async {
      final tempDir = await Directory.systemTemp.createTemp('ring_bak_test_');
      try {
        // 依次写入 7 次备份（count=5，应轮转回 slot 1）
        for (var i = 1; i <= 7; i++) {
          final bytes = Uint8List.fromList([i]);
          await writeRingBackup(tempDir, bytes, count: 5);
        }

        final indexFile = File(p.join(tempDir.path, '.manifest-bak-index'));
        expect(await indexFile.exists(), isTrue);
        final currentSlot = int.parse(await indexFile.readAsString());
        // 初始从 0 轮转 7 次：(0+1)%5=1, 2, 3, 4, 0, 1, 2 -> 最终 slot 应为 2
        expect(currentSlot, equals(2));

        // 索引文件损坏时重置为 0
        await indexFile.writeAsString('invalid-number-string');
        await writeRingBackup(tempDir, Uint8List.fromList([99]), count: 5);
        final resetSlot = int.parse(await indexFile.readAsString());
        expect(resetSlot, equals(1));
      } finally {
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      }
    });

    test('SyncBackend 抽象基类默认实现行为', () async {
      final backend = _DefaultDummyBackend();
      expect(await backend.listBlobs(), isEmpty);
      expect(await backend.listOrphanBlobs(), isEmpty);
      expect(await backend.listManifestBackups(), isEmpty);
      expect(await backend.readManifestBackup('any'), isNull);
      expect(await backend.getJournalObject('any'), isNull);
      expect(await backend.listJournalObjects(), isEmpty);

      // no-op 方法正常完成不抛错
      await expectLater(backend.deleteBlob('hash'), completes);
      await expectLater(backend.deleteBlobSoft('hash'), completes);
      await expectLater(
        backend.purgeOrphans(const Duration(days: 30)),
        completes,
      );
      await expectLater(backend.backupManifest(), completes);
      await expectLater(backend.backupCorruptManifest(Uint8List(0)), completes);
      await expectLater(
        backend.putJournalObject('j1', Uint8List(0)),
        completes,
      );
    });

    test('BackendNotInitializedException 与 ConflictException toString', () {
      final notInit = BackendNotInitializedException();
      expect(notInit.toString(), contains('Call init() before using'));

      final conflict = ConflictException('etag conflict');
      expect(conflict.toString(), contains('ConflictException: etag conflict'));
    });
  });

  group('Journal 水位维护与 state 容错测试', () {
    late Directory tempDir;
    const vaultId = 'test-vault-uuid';
    const deviceId = 'test-device-id';

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('journal_edge_test_');
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('Journal .journal-state.json 损坏时安全降级重置', () async {
      // 1. 正常打开并追加条目
      final journal1 = await Journal.open(
        baseDir: tempDir.path,
        vaultId: vaultId,
        deviceId: deviceId,
      );
      journal1.append(
        type: JournalEventType.syncRound,
        phase: JournalPhase.start,
        note: 'first log',
      );
      await journal1.flush();
      await journal1.close();

      // 2. 故意破坏 .journal-state.json
      final stateFile = File(
        p.join(tempDir.path, 'journal', '.journal-state.json'),
      );
      if (await stateFile.exists()) {
        await stateFile.writeAsString('{ invalid-json-syntax }');
      }

      // 3. 再次打开，必须正常启动不崩溃
      final journal2 = await Journal.open(
        baseDir: tempDir.path,
        vaultId: vaultId,
        deviceId: deviceId,
      );
      expect(journal2.deviceId, equals(deviceId));
      expect(journal2.vaultId, equals(vaultId));

      journal2.append(
        type: JournalEventType.syncRound,
        phase: JournalPhase.done,
        note: 'recovered log',
      );
      await journal2.flush();
      await journal2.close();
    });

    test('Journal 坏日志文件隔离取证与安全自愈', () async {
      final journal = await Journal.open(
        baseDir: tempDir.path,
        vaultId: vaultId,
        deviceId: deviceId,
      );
      journal.append(
        type: JournalEventType.noteUpsert,
        phase: JournalPhase.done,
        uuid: 'uuid-1',
      );
      await journal.flush();
      await journal.close();

      // 注入损坏数据到 log.json
      final logFile = File(p.join(tempDir.path, 'journal', 'log.json'));
      expect(await logFile.exists(), isTrue);
      await logFile.writeAsString('{ invalid corrupted json');

      // 再次打开：损坏文件被隔离为 log.json.corrupt-*，journal 以空日志安全启动
      final reopened = await Journal.open(
        baseDir: tempDir.path,
        vaultId: vaultId,
        deviceId: deviceId,
      );
      expect(reopened.entries, isEmpty);
      await reopened.close();

      // 验证隔离取证文件生成
      final journalDir = Directory(p.join(tempDir.path, 'journal'));
      final files = await journalDir.list().toList();
      expect(files.any((f) => f.path.contains('.corrupt-')), isTrue);
    });
  });
}
