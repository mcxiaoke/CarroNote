/*
 * blob 寻址不变量测试
 *
 * 存在理由：blob 的身份（远端文件名 + GCM AAD）只有一个合法来源——
 * `SafeNote.computeHash(title, description)`。而 payload 是另一套编码
 * （`toContentBytes()` 的 JSON，含 `"v"` 版本字段），两者刻意解耦，这样
 * payload 加字段不会让已寻址的 blob 失效。
 *
 * 这个解耦不是自解释的：`SyncCrypto` 里有个通用 SHA-256 原语，历史上叫
 * `contentHash`，与 `SafeNote.contentHash` 字段、DB 列 `content_hash` 三者
 * 重名而语义不同，很容易让人"顺手统一"成对 payload 字节求哈希。一旦改了，
 * 全部存量 blob 立刻不可寻址（新 id 与远端已有文件名对不上，且 AAD 变化后
 * GCM 校验失败），且**不会有任何编译错误**。2026-08-10 已把该原语更名为
 * `sha256Hex` 消歧，本文件负责把不变量钉死在测试里，让下次误改直接红灯。
 *
 * 锁定四条不变量：
 *   I1 putBlob 的键 == manifest.hash == SafeNote.computeHash(title, desc)
 *   I2 该键同时是 GCM AAD——用它能解开，解出内容重算 hash 仍等于它
 *   I3 payload 字节哈希 != blob id，且不能被当作 id 使用（反向护栏）
 *   I4 blob 身份与 payload 的 "v" 版本字段无关（身份/payload 域分离）
 *
 * 运行：dart test test/sync/blob_addressing_test.dart
 */

// Dart 原生导入
import 'dart:convert';
import 'dart:typed_data';

// Package 导入
import 'package:test/test.dart';
import 'package:core/core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// 测试公共支撑（Keyring/Journal 构造 + FakeBackend journal 存储）
import 'sync_test_support.dart';

/// 最小 FakeBackend：只保留断言 blob 寻址所需能力
///
/// 与 sync_engine_test.dart 里的 FakeBackend 不同点：[blobs] 公开可读，
/// 测试要直接检查「远端到底以什么键存了什么字节」。
class _AddressingBackend with FakeJournalStore implements SyncBackend {
  /// 远端 blob 存储：键即 blob id，值即 GCM 信封
  final Map<String, Uint8List> blobs = {};

  Uint8List? _manifest;
  String _etag = '';

  @override
  String get displayName => 'AddressingBackend';

  @override
  String get providerKey => 'addressing-test-backend';

  @override
  Future<void> init() async {}

  @override
  Future<({Uint8List ciphertext, String etag})> getManifest() async {
    if (_manifest == null) return (ciphertext: Uint8List(0), etag: '');
    return (ciphertext: _manifest!, etag: _etag);
  }

  @override
  Future<String> putManifest(Uint8List ciphertext, String expectedEtag) async {
    _manifest = ciphertext;
    _etag = 'etag-${DateTime.now().microsecondsSinceEpoch}';
    return _etag;
  }

  @override
  Future<Uint8List?> getBlob(String hash) async => blobs[hash];

  @override
  Future<void> putBlob(String hash, Uint8List data) async {
    blobs[hash] = data;
  }

  @override
  Future<void> deleteBlob(String hash) async {
    blobs.remove(hash);
  }

  @override
  Future<List<String>> listBlobs() async => blobs.keys.toList();

  @override
  Future<void> backupCorruptManifest(Uint8List ciphertext) async {}

  @override
  Future<List<String>> listManifestBackups() async => [];

  @override
  Future<Uint8List?> readManifestBackup(String name) async => null;

  @override
  Future<void> close() async {}

  @override
  Future<bool> ping() async => true;

  @override
  Future<void> deleteBlobSoft(String hash) async => deleteBlob(hash);

  @override
  Future<List<String>> listOrphanBlobs() async => [];

  @override
  Future<void> purgeOrphans(Duration retention) async {}

  @override
  Future<void> backupManifest([Uint8List? currentManifestBytes]) async {}
}

SafeNote _makeNote({
  required String uuid,
  required String title,
  required String description,
}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return SafeNote(
    uuid: uuid,
    title: title,
    description: description,
    contentHash: SafeNote.computeHash(title, description),
    deleted: false,
    createdTime: DateTime.now(),
    updatedAt: now,
    synced: false,
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late _AddressingBackend backend;
  late NotesDatabase database;
  late Uint8List dataKey;

  /// 覆盖面刻意包含换行、Unicode、空正文：这些是拼接式 hash 最容易出岔子的输入
  final samples = <SafeNote>[
    _makeNote(uuid: 'uuid-plain', title: 'Plain', description: 'body'),
    _makeNote(
      uuid: 'uuid-multiline',
      title: 'Multi',
      description: 'line1\nline2\nline3',
    ),
    _makeNote(uuid: 'uuid-unicode', title: '中文标题 🔐', description: 'émoji ✓'),
    _makeNote(uuid: 'uuid-empty-desc', title: 'OnlyTitle', description: ''),
  ];

  setUp(() async {
    backend = _AddressingBackend();
    final db = await openDatabase(
      ':memory:',
      version: 2,
      onCreate: NotesDatabase.createDBForTesting,
    );
    NotesDatabase.setDatabaseForTesting(db);
    database = NotesDatabase.instance;
    dataKey = SyncCrypto.generateDataKey();
    database.setDataKey(dataKey);
  });

  tearDown(() async {
    await database.close();
  });

  SyncEngine makeEngine() => SyncEngine(
        backend: backend,
        database: database,
        keyring: makeTestKeyring(dataKey: dataKey),
        deviceId: 'test-device',
        journal: makeTestJournal(),
      );

  group('blob 寻址不变量', () {
    test('I1/I2: putBlob 键 == manifest.hash == computeHash，且该键即 AAD',
        () async {
      for (final note in samples) {
        await database.storeNote(note);
      }

      final engine = makeEngine();
      final result = await engine.sync();
      expect(result.success, isTrue);
      expect(result.uploaded, samples.length);

      final manifest = await ManifestCrypto.deserialize(
        dataKey,
        (await backend.getManifest()).ciphertext,
      );

      for (final note in samples) {
        final expectedId = SafeNote.computeHash(note.title, note.description);

        // I1-a：blob 确实以 computeHash 为键落在远端
        expect(
          backend.blobs.containsKey(expectedId),
          isTrue,
          reason: 'blob id 必须是 SafeNote.computeHash(title, description)，'
              'uuid=${note.uuid}',
        );

        // I1-b：manifest 记录的 hash 与 blob 键同源（否则 manifest 指向孤儿）
        expect(
          manifest.items[note.uuid]!.hash,
          expectedId,
          reason: 'manifest.hash 必须与 blob 键一致，uuid=${note.uuid}',
        );

        // I2：同一个 id 就是 GCM AAD——用它解得开
        final plaintext = await SyncCrypto.open(
          dataKey,
          expectedId,
          backend.blobs[expectedId]!,
        );
        final content = SafeNote.fromContentBytes(plaintext);
        expect(content.title, note.title);
        expect(content.description, note.description);

        // I2-b：解出内容重算 hash 仍等于 id（下载侧 M7 校验依赖这条闭环）
        expect(
          SafeNote.computeHash(content.title, content.description),
          expectedId,
        );
      }

      // I1-c：远端没有多余 blob（不存在第二套寻址口径同时在写）
      expect(
        backend.blobs.keys.toSet(),
        samples
            .map((n) => SafeNote.computeHash(n.title, n.description))
            .toSet(),
      );
    });

    test('I3: payload 字节哈希不是 blob id，且不能当 id 用', () async {
      final note = samples[1]; // 多行正文，两种口径差异明显
      await database.storeNote(note);
      final engine = makeEngine();
      expect((await engine.sync()).success, isTrue);

      final blobId = SafeNote.computeHash(note.title, note.description);
      final payloadHash = SyncCrypto.sha256Hex(note.toContentBytes());

      // 两个域必须保持不同——若某次改动让它们相等，说明身份口径被改成了
      // payload 字节哈希，存量 blob 会全部失联
      expect(
        payloadHash,
        isNot(blobId),
        reason: 'payload 字节哈希与 blob id 是两个域，不得统一',
      );

      // 远端不存在以 payload 哈希为键的对象
      expect(backend.blobs.containsKey(payloadHash), isFalse);

      // 用 payload 哈希当 AAD 解不开（证明 id 真的进了 AAD，不是摆设）
      expect(
        () => SyncCrypto.open(dataKey, payloadHash, backend.blobs[blobId]!),
        throwsA(isA<SyncDecryptionException>()),
      );
    });

    test('I4: blob 身份与 payload 的 "v" 版本字段无关', () async {
      final note = samples[0];
      final payload =
          jsonDecode(utf8.decode(note.toContentBytes())) as Map<String, dynamic>;

      // payload 确实带版本字段
      expect(payload['v'], isNotNull);

      // 而 id 只由 title\ndescription 决定，与 payload 结构无关：
      // 这正是"payload 加字段不影响已寻址 blob"的形式化表达
      expect(
        SafeNote.computeHash(note.title, note.description),
        SyncCrypto.hashString('${note.title}\n${note.description}'),
      );
    });
  });
}
