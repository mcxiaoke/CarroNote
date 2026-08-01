// 集成测试：WebDavBackend vs hacdias/webdav 真实服务器
//
// 测试策略：
//   1. setUpAll：清理残留进程 → 生成配置文件 → 启动 webdav.exe 服务器
//   2. 用真实的 WebDavBackend + SyncEngine 跑完整同步流程
//   3. 每个测试前清理服务器数据目录；tearDownAll 停服务器
//
// 服务器：hacdias/webdav v5.14.1（Go 实现的标准 WebDAV 服务器）
//   - 完整支持 ETag / If-Match / MKCOL / PROPFIND / DELETE
//   - 配置通过 YAML 文件传入
//
// 运行：
//   flutter test test/sync/webdav_integration_test.dart
//
// 如果 webdav.exe 不在 C:\Home\Develop\tools\ 下，测试自动跳过。

// 库级注解：启动服务器可能需要时间
@Timeout(Duration(seconds: 120))
library;

// Dart 原生导入
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// Package 导入
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:safenotes/data/database_handler.dart';
import 'package:safenotes/models/safenote.dart';
import 'package:safenotes/sync/crypto.dart';
import 'package:safenotes/sync/sync_engine.dart';
import 'package:safenotes/sync/sync_models.dart';
import 'package:safenotes/sync/webdav_backend.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// 测试公共支撑（P2：Keyring/Journal 构造 + FakeBackend journal 存储）
import 'sync_test_support.dart';

/// webdav.exe 路径（hacdias/webdav）
const String kWebDavBinary = r'C:\Home\Develop\tools\webdav.exe';

/// 测试用固定端口（避开 6065 默认端口和 8090 SafeServer 端口）
const int kTestPort = 6090;

/// 测试用账号
const String kTestUser = 'testuser';
const String kTestPass = 'testpass';

/// 测试基础设施根目录
final String kTestRoot = '${Directory.systemTemp.path}\\safenotes-webdav-test';

/// 配置文件路径
String get kConfigPath => '$kTestRoot\\config.yaml';

/// server 子进程管理
class WebDavServerProcess {
  final Process process;
  final int port;
  final String dataDir;
  final String logPath;

  WebDavServerProcess(this.process, this.port, this.dataDir, this.logPath);

  /// server 基地址
  String get baseUrl => 'http://127.0.0.1:$port';

  /// 停止 server（可靠地杀进程树）
  Future<void> stop() async {
    // 1. 先尝试 graceful shutdown（SIGTERM）
    try {
      process.kill(ProcessSignal.sigterm);
    } catch (_) {}

    // 等待最多 3 秒让进程优雅退出
    bool exited = false;
    try {
      await process.exitCode.timeout(
        const Duration(seconds: 3),
        onTimeout: () => -1,
      );
      exited = true;
    } catch (_) {
      exited = false;
    }

    // 2. 如果还没退出，用 taskkill /T /F 强杀进程树
    if (!exited && Platform.isWindows) {
      try {
        await Process.run(
          'taskkill',
          ['/T', '/F', '/PID', process.pid.toString()],
        );
      } catch (_) {}
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
  }

  /// 等待 server 就绪（轮询 PROPFIND）
  Future<bool> waitReady({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final req = http.Request('PROPFIND', Uri.parse(baseUrl));
        req.headers['Authorization'] =
            'Basic ${base64Encode(utf8.encode('$kTestUser:$kTestPass'))}';
        req.headers['Depth'] = '0';
        req.headers['Content-Type'] = 'application/xml; charset=utf-8';
        req.body = '<?xml version="1.0"?>'
            '<propfind xmlns="DAV:"><prop><resourcetype/></prop></propfind>';
        final streamedRes = await _httpClient.send(req).timeout(
              const Duration(seconds: 2),
            );
        final res = await http.Response.fromStream(streamedRes);
        if (res.statusCode == 207 || res.statusCode == 200) {
          return true;
        }
      } catch (_) {
        // server 还没起来，继续等
      }
      await Future.delayed(const Duration(milliseconds: 300));
    }
    return false;
  }

  /// 清理 keyring 子目录（让每个测试从干净状态开始）
  ///
  /// WebDavBackend 会在用户 baseUrl 下自动附加 safenotes-vault 子目录。
  /// 清理该子目录可重置到干净状态。
  Future<void> clearData() async {
    final vaultDir = Directory('$dataDir\\safenotes-vault');
    if (vaultDir.existsSync()) {
      try {
        await vaultDir.delete(recursive: true);
      } catch (_) {
        // Windows 偶发文件占用，忽略
      }
    }
  }

  /// 复用 HTTP client（避免每次轮询新建）
  static final http.Client _httpClient = http.Client();
}

/// 生成 webdav 配置文件（YAML 格式）
Future<void> generateConfig({
  required int port,
  required String dataDir,
}) async {
  final config = '''
# WebDAV 测试服务器配置（自动生成）
address: 127.0.0.1
port: $port
debug: false
prefix: /
directory: ${dataDir.replaceAll(r'\', '/')}
permissions: RCUD

log:
  format: console
  colors: false
  outputs:
    - stderr

users:
  - username: $kTestUser
    password: $kTestPass
''';
  await File(kConfigPath).writeAsString(config);
}

/// 清理残留 webdav.exe 进程 + 端口占用
Future<void> cleanupResidual() async {
  if (!Platform.isWindows) return;
  try {
    // 杀残留 webdav.exe 进程
    final result = await Process.run(
      'pwsh',
      ['-NoProfile', '-Command',
        "Get-Process webdav -ErrorAction SilentlyContinue | Stop-Process -Force; " +
        "Get-NetTCPConnection -LocalPort $kTestPort -ErrorAction SilentlyContinue | " +
        "ForEach-Object { Stop-Process -Id \$_.OwningProcess -Force -ErrorAction SilentlyContinue }"],
    );
    // 忽略错误
    if (result.exitCode != 0) {
      // pwsh 不可用就跳过
    }
  } catch (_) {}
}

/// 启动 webdav server
Future<WebDavServerProcess?> startServer(int port, String dataDir) async {
  // 检查二进制是否存在
  if (!File(kWebDavBinary).existsSync()) {
    return null;
  }

  // 生成配置文件
  await generateConfig(port: port, dataDir: dataDir);

  final logFile = '$kTestRoot\\webdav-$port.log';
  try {
    final process = await Process.start(
      kWebDavBinary,
      ['-c', kConfigPath],
      workingDirectory: dataDir,
    );

    // 转发 stderr 到日志文件（便于调试）
    final log = File(logFile);
    final sink = log.openWrite();
    process.stderr.listen((data) => sink.add(data));
    process.stdout.listen((data) => sink.add(data));
    // 进程退出时关闭 sink
    process.exitCode.then((_) => sink.close());

    return WebDavServerProcess(process, port, dataDir, logFile);
  } catch (e) {
    print('Failed to start webdav server: $e');
    return null;
  }
}

/// 创建测试用笔记
SafeNote _makeNote({
  required String uuid,
  String title = 'Test Title',
  String description = 'Test Description',
  bool deleted = false,
  int? updatedAt,
}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return SafeNote(
    uuid: uuid,
    title: title,
    description: description,
    contentHash: SafeNote.computeHash(title, description),
    deleted: deleted,
    createdTime: DateTime.now(),
    updatedAt: updatedAt ?? now,
    synced: false,
  );
}

/// 构造 SyncEngine
SyncEngine _makeEngine({
  required WebDavBackend backend,
  required NotesDatabase database,
  required Uint8List dataKey,
  required String encryptedDataKey,
  String deviceId = 'test-device',
  int dataKeyEpoch = 1,
}) {
  final keyring = makeTestKeyring(
    vaultId: 'test-keyring-id',
    dataKey: dataKey,
    encryptedDataKey: encryptedDataKey,
    keyFingerprint: '',
    keyVersion: 1,
    dataKeyEpoch: dataKeyEpoch,
    kdf: KdfParams.create(salt: SyncCrypto.generateSalt()),
    createdAt: DateTime.now().millisecondsSinceEpoch,
  );
  return SyncEngine(
    backend: backend,
    database: database,
    keyring: keyring,
    deviceId: deviceId,
    journal: makeTestJournal(),
  );
}

/// 用指定 dataKey 构造并上传一个远端 manifest（仅含给定 items）
///
/// [dataKey] 用于加密 manifest 的 items 部分（必须与消费方引擎的解密 key 一致）。
/// [encryptedDataKey] 写入 header 明文（用于触发/跳过 dataKey 迁移分支）。
/// [expectedEtag] 上传时使用的乐观锁 etag；传空字符串表示"首次上传"
/// （后端会发 If-None-Match: *，已存在则失败），覆盖已有 manifest 时须传真实 etag。
Future<void> _uploadRemoteManifest({
  required WebDavBackend backend,
  required Uint8List dataKey,
  required Map<String, ManifestItem> items,
  required String encryptedDataKey,
  required KdfParams kdf,
  String vaultId = 'remote-keyring-id',
  int keyVersion = 1,
  String keyFingerprint = '',
  int version = 1,
  int createdAt = 1700000000000,
  String expectedEtag = '',
}) async {
  final header = ManifestHeader(
    schemaVersion: 1,
    version: version,
    vaultId: vaultId,
    createdAt: createdAt,
    updatedAt: createdAt,
    keyFingerprint: keyFingerprint,
    keyVersion: keyVersion,
    encryptedDataKey: encryptedDataKey,
    kdf: kdf,
    dataKeyWrap: kDataKeyWrapAlgorithm,
    lastModifiedBy: 'seed',
  );
  final manifest = Manifest(header: header, items: items);
  final bytes = ManifestCrypto.serialize(dataKey, manifest);
  await backend.putManifest(bytes, expectedEtag);
}

void main() {
  // 初始化 sqflite_ffi（桌面测试环境）
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  // server 进程和资源管理
  late WebDavServerProcess server;
  late NotesDatabase database;
  late Uint8List testDataKey;
  late String testEncryptedDataKey;
  late WebDavBackend backend;

  // setUpAll：清理 → 生成配置 → 启动 server → 等待就绪
  setUpAll(() async {
    // 1. 清理残留进程 + 端口
    await cleanupResidual();

    // 2. 创建测试根目录和数据目录
    final testRoot = Directory(kTestRoot);
    if (!testRoot.existsSync()) {
      await testRoot.create(recursive: true);
    }
    final dataDir = '$kTestRoot\\data';
    final dataDirObj = Directory(dataDir);
    if (dataDirObj.existsSync()) {
      try {
        await dataDirObj.delete(recursive: true);
      } catch (_) {}
    }
    await dataDirObj.create(recursive: true);

    // 3. 启动 webdav server
    final serverProc = await startServer(kTestPort, dataDir);
    if (serverProc == null) {
      throw StateError(
        '无法启动 webdav server（$kWebDavBinary 不存在）',
      );
    }
    server = serverProc;

    // 4. 等待 server 就绪
    final ready = await server.waitReady(timeout: const Duration(seconds: 15));
    if (!ready) {
      await server.stop();
      throw StateError('webdav server 启动超时（15s），检查日志: ${server.logPath}');
    }
  });

  tearDownAll(() async {
    // 停止 server
    try {
      await server.stop();
    } catch (_) {}
    // 最终清理残留进程
    await cleanupResidual();
  });

  setUp(() async {
    // 每个测试前清理 server 数据目录
    await server.clearData();

    // 创建新的 WebDavBackend
    backend = WebDavBackend(
      baseUrl: server.baseUrl,
      username: kTestUser,
      password: kTestPass,
    );
    await backend.init();

    // 创建 in-memory 数据库
    final db = await openDatabase(
      ':memory:',
      version: 2,
      onCreate: NotesDatabase.createDBForTesting,
    );
    NotesDatabase.setDatabaseForTesting(db);
    database = NotesDatabase.instance;

    // 生成测试用 dataKey
    testDataKey = SyncCrypto.generateDataKey();
    database.setDataKey(testDataKey);
    testEncryptedDataKey = base64Encode(
      SyncCrypto.wrapDataKey(testDataKey, testDataKey),
    );
  });

  tearDown(() async {
    await database.close();
    await backend.close();
  });

  // ──────────────────────────────────────────────
  // Group 1: WebDavBackend 单元测试
  // ──────────────────────────────────────────────
  group('WebDavBackend - 初始化与 ping', () {
    test('ping 返回 true（服务器可用）', () async {
      final ok = await backend.ping();
      expect(ok, isTrue);
    });

    test('init 幂等：重复调用不报错', () async {
      await backend.init();
      await backend.init();
    });

    test('init 创建 safenotes-vault 子目录和 blobs 目录', () async {
      // init 已在 setUp 中调用
      // 验证：PROPFIND safenotes-vault/blobs 应返回 207
      final req = http.Request(
        'PROPFIND',
        Uri.parse('${server.baseUrl}/safenotes-vault/blobs'),
      );
      req.headers['Authorization'] =
          'Basic ${base64Encode(utf8.encode('$kTestUser:$kTestPass'))}';
      req.headers['Depth'] = '0';
      final streamedRes = await http.Client().send(req);
      final res = await http.Response.fromStream(streamedRes);
      expect(res.statusCode == 207 || res.statusCode == 200, isTrue);
    });
  });

  group('WebDavBackend - manifest 操作', () {
    test('首次 getManifest 返回空密文和空 etag', () async {
      final result = await backend.getManifest();
      expect(result.ciphertext.length, 0);
      expect(result.etag, '');
    });

    test('putManifest 首次上传成功（expectedEtag 为空）', () async {
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      final etag = await backend.putManifest(data, '');
      expect(etag, isNotEmpty);
    });

    test('putManifest 首次上传后内容可读回', () async {
      final data = Uint8List.fromList([10, 20, 30, 40, 50]);
      await backend.putManifest(data, '');

      final result = await backend.getManifest();
      expect(result.ciphertext, data);
      // ETag 可能是服务器返回的，也可能是内容 hash fallback
      expect(result.etag, isNotEmpty);
    });

    test('putManifest 带正确 etag 可覆盖写入', () async {
      final data1 = Uint8List.fromList([1, 1, 1]);
      final etag1 = await backend.putManifest(data1, '');

      final data2 = Uint8List.fromList([2, 2, 2]);
      await backend.putManifest(data2, etag1);

      // 新内容应有新 etag（或相同 etag，取决于服务器实现）
      final result = await backend.getManifest();
      expect(result.ciphertext, data2);
    });

    test('ETag 一致性：相同内容 getManifest 返回相同 etag', () async {
      final data = Uint8List.fromList([100, 101, 102]);
      await backend.putManifest(data, '');

      final r1 = await backend.getManifest();
      final r2 = await backend.getManifest();
      expect(r1.etag, r2.etag);
      expect(r1.ciphertext, data);
    });

    test('getManifest 返回 404 时视为首次同步（空密文）', () async {
      // 首次 getManifest（无 manifest 文件）
      final result = await backend.getManifest();
      expect(result.ciphertext.length, 0);
      expect(result.etag, '');
    });
  });

  group('WebDavBackend - blob 操作', () {
    test('getBlob 不存在时返回 null', () async {
      final result = await backend.getBlob('nonexistent-hash-12345');
      expect(result, isNull);
    });

    test('putBlob + getBlob 往返', () async {
      final hash = 'abc123def456';
      final data = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);

      await backend.putBlob(hash, data);

      final result = await backend.getBlob(hash);
      expect(result, isNotNull);
      expect(result!, data);
    });

    test('putBlob 幂等：相同 hash 多次上传结果一致', () async {
      final hash = 'idempotent-hash';
      final data1 = Uint8List.fromList([10, 20, 30]);
      final data2 = Uint8List.fromList([10, 20, 30]);

      await backend.putBlob(hash, data1);
      await backend.putBlob(hash, data2);

      final result = await backend.getBlob(hash);
      expect(result, data1);
    });

    test('putBlob 覆盖写：相同 hash 不同内容以后写为准', () async {
      final hash = 'overwrite-hash';
      final data1 = Uint8List.fromList([1, 2, 3]);
      final data2 = Uint8List.fromList([4, 5, 6]);

      await backend.putBlob(hash, data1);
      await backend.putBlob(hash, data2);

      final result = await backend.getBlob(hash);
      expect(result, data2);
    });

    test('多个 blob 并存：不同 hash 互不干扰', () async {
      final hash1 = 'hash-aaa';
      final hash2 = 'hash-bbb';
      final hash3 = 'hash-ccc';

      final data1 = Uint8List.fromList([1]);
      final data2 = Uint8List.fromList([2]);
      final data3 = Uint8List.fromList([3]);

      await backend.putBlob(hash1, data1);
      await backend.putBlob(hash2, data2);
      await backend.putBlob(hash3, data3);

      expect(await backend.getBlob(hash1), data1);
      expect(await backend.getBlob(hash2), data2);
      expect(await backend.getBlob(hash3), data3);
    });
  });

  group('WebDavBackend - deleteBlob / listBlobs (GC)', () {
    test('deleteBlob 删除存在的 blob', () async {
      final hash = 'del-hash-1';
      final data = Uint8List.fromList([1, 2, 3]);
      await backend.putBlob(hash, data);
      expect(await backend.getBlob(hash), isNotNull);

      await backend.deleteBlob(hash);
      expect(await backend.getBlob(hash), isNull);
    });

    test('deleteBlob 幂等：删除不存在的 hash 不抛异常', () async {
      await backend.deleteBlob('nonexistent-delete-hash');
      // 不抛异常即通过
    });

    test('listBlobs 列出所有已上传的 blob hash', () async {
      // 使用符合正则的 64 字符 hex hash（listBlobs 只返回这种格式）
      final hash1 = 'a' * 64;
      final hash2 = 'b' * 64;
      final hash3 = 'c' * 64;

      await backend.putBlob(hash1, Uint8List.fromList([1]));
      await backend.putBlob(hash2, Uint8List.fromList([2]));
      await backend.putBlob(hash3, Uint8List.fromList([3]));

      final blobs = await backend.listBlobs();
      expect(blobs, containsAll([hash1, hash2, hash3]));
      expect(blobs.length, greaterThanOrEqualTo(3));
    });

    test('listBlobs 空目录返回空列表', () async {
      final blobs = await backend.listBlobs();
      expect(blobs, isEmpty);
    });

    test('deleteBlob 后 listBlobs 不再包含该 hash', () async {
      final hash1 = 'd' * 64;
      final hash2 = 'e' * 64;

      await backend.putBlob(hash1, Uint8List.fromList([1]));
      await backend.putBlob(hash2, Uint8List.fromList([2]));

      await backend.deleteBlob(hash1);

      final blobs = await backend.listBlobs();
      expect(blobs, isNot(contains(hash1)));
      expect(blobs, contains(hash2));
    });
  });

  group('WebDavBackend - backupCorruptManifest', () {
    test('backupCorruptManifest 删除损坏的 manifest 文件', () async {
      // 先上传一个 manifest
      await backend.putManifest(
        Uint8List.fromList([1, 2, 3]),
        '',
      );

      // 调用 backupCorruptManifest（应删除该文件）
      await backend.backupCorruptManifest(Uint8List(0));

      // 验证：getManifest 应返回空（文件已删除）
      final result = await backend.getManifest();
      expect(result.ciphertext.length, 0);
    });

    test('backupCorruptManifest 幂等：不存在的 manifest 不抛异常', () async {
      await backend.backupCorruptManifest(Uint8List(0));
      // 不抛异常即通过
    });
  });

  group('WebDavBackend - 认证', () {
    test('错误密码时请求失败（401）', () async {
      final badBackend = WebDavBackend(
        baseUrl: server.baseUrl,
        username: kTestUser,
        password: 'wrong-password',
      );
      // init 时 MKCOL 会因认证失败抛异常
      expect(
        () => badBackend.init(),
        throwsA(isA<Exception>()),
      );
    });
  });

  // ──────────────────────────────────────────────
  // Group 2: SyncEngine + WebDavBackend 端到端测试
  // ──────────────────────────────────────────────
  group('WebDAV 集成 - 首次同步', () {
    test('空数据库首次同步：只上传 manifest', () async {
      final engine = _makeEngine(
        backend: backend,
        database: database,
        dataKey: testDataKey,
        encryptedDataKey: testEncryptedDataKey,
      );

      final result = await engine.sync();

      expect(result.success, isTrue);
      expect(result.uploaded, 0);
      expect(result.downloaded, 0);

      final version = await database.getManifestVersion(backend.providerKey);
      expect(version, 1);
    });

    test('上传 3 条笔记到远端', () async {
      await database.storeNote(_makeNote(uuid: 'uuid-1', title: 'Note 1'));
      await database.storeNote(_makeNote(uuid: 'uuid-2', title: 'Note 2'));
      await database.storeNote(_makeNote(uuid: 'uuid-3', title: 'Note 3'));

      final engine = _makeEngine(
        backend: backend,
        database: database,
        dataKey: testDataKey,
        encryptedDataKey: testEncryptedDataKey,
      );

      final result = await engine.sync();

      expect(result.success, isTrue);
      expect(result.uploaded, 3);
      expect(result.downloaded, 0);

      final version = await database.getManifestVersion(backend.providerKey);
      expect(version, 1);

      // 验证所有笔记标记为已同步
      final notes = await database.readAllNotesIncludingDeleted();
      for (final note in notes) {
        expect(note.synced, isTrue);
      }
    });
  });

  group('WebDAV 集成 - 新设备同步', () {
    test('从远端下载所有笔记', () async {
      // 设备 A：上传 2 条笔记
      await database.storeNote(_makeNote(uuid: 'uuid-a1', title: 'Note A1'));
      await database.storeNote(_makeNote(uuid: 'uuid-a2', title: 'Note A2'));

      final engineA = _makeEngine(
        backend: backend,
        database: database,
        dataKey: testDataKey,
        encryptedDataKey: testEncryptedDataKey,
      );
      await engineA.sync();

      // 设备 B：新数据库（模拟新设备）
      await database.close();
      final dbB = await openDatabase(
        ':memory:',
        version: 2,
        onCreate: NotesDatabase.createDBForTesting,
      );
      NotesDatabase.setDatabaseForTesting(dbB);
      database.setDataKey(testDataKey);

      // 用相同的 dataKey 和 encryptedDataKey
      final engineB = _makeEngine(
        backend: backend,
        database: database,
        dataKey: testDataKey,
        encryptedDataKey: testEncryptedDataKey,
      );

      final result = await engineB.sync();

      expect(result.success, isTrue);
      expect(result.downloaded, 2);
      expect(result.uploaded, 0);

      // 验证本地有 2 条笔记
      final notes = await database.readAllNotes();
      expect(notes.length, 2);
      expect(notes.any((n) => n.uuid == 'uuid-a1'), isTrue);
      expect(notes.any((n) => n.uuid == 'uuid-a2'), isTrue);

      // 验证内容正确
      final downloaded1 = await database.readNoteByUuid('uuid-a1');
      expect(downloaded1!.title, 'Note A1');
    });
  });

  group('WebDAV 集成 - 增量同步', () {
    test('双方各有独占笔记，同步后互相获得', () async {
      // 设备 A：上传 1 条笔记
      await database.storeNote(_makeNote(uuid: 'uuid-a', title: 'Note A'));
      final engineA = _makeEngine(
        backend: backend,
        database: database,
        dataKey: testDataKey,
        encryptedDataKey: testEncryptedDataKey,
      );
      await engineA.sync();

      // 设备 B：已有 1 条不同笔记
      await database.close();
      final dbB = await openDatabase(
        ':memory:',
        version: 2,
        onCreate: NotesDatabase.createDBForTesting,
      );
      NotesDatabase.setDatabaseForTesting(dbB);
      database.setDataKey(testDataKey);

      await database.storeNote(_makeNote(uuid: 'uuid-b', title: 'Note B'));

      final engineB = _makeEngine(
        backend: backend,
        database: database,
        dataKey: testDataKey,
        encryptedDataKey: testEncryptedDataKey,
      );

      final result = await engineB.sync();

      expect(result.success, isTrue);
      expect(result.downloaded, 1);
      expect(result.uploaded, 1);

      // 验证本地同时有 A 和 B
      final notes = await database.readAllNotes();
      expect(notes.length, 2);
      expect(notes.any((n) => n.uuid == 'uuid-a'), isTrue);
      expect(notes.any((n) => n.uuid == 'uuid-b'), isTrue);
    });

    test('已同步笔记不重复上传', () async {
      // 设备 A：上传 1 条笔记
      await database.storeNote(_makeNote(uuid: 'uuid-stable', title: 'Stable'));
      final engineA = _makeEngine(
        backend: backend,
        database: database,
        dataKey: testDataKey,
        encryptedDataKey: testEncryptedDataKey,
      );
      await engineA.sync();

      // 再次同步：不应有上传
      final result = await engineA.sync();
      expect(result.success, isTrue);
      expect(result.uploaded, 0);
      expect(result.downloaded, 0);
    });
  });

  group('WebDAV 集成 - LWW 冲突解决', () {
    test('updatedAt 更大的远端笔记覆盖本地', () async {
      // 设备 A 上传笔记
      final earlyTime = DateTime.now().millisecondsSinceEpoch;
      await database.storeNote(_makeNote(
        uuid: 'uuid-conflict',
        title: 'Original',
        updatedAt: earlyTime,
      ));
      final engineA = _makeEngine(
        backend: backend,
        database: database,
        dataKey: testDataKey,
        encryptedDataKey: testEncryptedDataKey,
      );
      await engineA.sync();

      // 设备 B：本地有同 uuid 但内容不同且 updatedAt 更早
      await database.close();
      final dbB = await openDatabase(
        ':memory:',
        version: 2,
        onCreate: NotesDatabase.createDBForTesting,
      );
      NotesDatabase.setDatabaseForTesting(dbB);
      database.setDataKey(testDataKey);

      await database.storeNote(_makeNote(
        uuid: 'uuid-conflict',
        title: 'Local Edit',
        updatedAt: earlyTime - 1000, // 本地更早 → 远端胜
      ));

      final engineB = _makeEngine(
        backend: backend,
        database: database,
        dataKey: testDataKey,
        encryptedDataKey: testEncryptedDataKey,
      );
      final result = await engineB.sync();

      expect(result.success, isTrue);
      expect(result.conflicts, greaterThan(0));

      // 远端胜：本地内容应被覆盖为 Original
      final note = await database.readNoteByUuid('uuid-conflict');
      expect(note!.title, 'Original');
    });
  });

  group('WebDAV 集成 - 墓碑同步', () {
    test('软删除传播到已下载笔记的设备', () async {
      // 设备 A：上传 1 条笔记（时间戳 T1）
      final t1 = DateTime.now().millisecondsSinceEpoch;
      await database.storeNote(_makeNote(
        uuid: 'uuid-del',
        title: 'To Delete',
        updatedAt: t1,
      ));
      final engineA = _makeEngine(
        backend: backend,
        database: database,
        dataKey: testDataKey,
        encryptedDataKey: testEncryptedDataKey,
      );
      await engineA.sync();

      // 设备 A：软删除笔记并同步（时间戳 T2 > T1）
      await database.close();
      final dbA2 = await openDatabase(
        ':memory:',
        version: 2,
        onCreate: NotesDatabase.createDBForTesting,
      );
      NotesDatabase.setDatabaseForTesting(dbA2);
      database.setDataKey(testDataKey);

      final t2 = t1 + 5000;
      await database.storeNote(_makeNote(
        uuid: 'uuid-del',
        title: 'To Delete',
        deleted: true,
        updatedAt: t2,
      ));
      final engineA2 = _makeEngine(
        backend: backend,
        database: database,
        dataKey: testDataKey,
        encryptedDataKey: testEncryptedDataKey,
      );
      await engineA2.sync();

      // 设备 B：本地已有笔记（updatedAt=T1，模拟之前已下载）
      await database.close();
      final dbB2 = await openDatabase(
        ':memory:',
        version: 2,
        onCreate: NotesDatabase.createDBForTesting,
      );
      NotesDatabase.setDatabaseForTesting(dbB2);
      database.setDataKey(testDataKey);

      await database.storeNote(_makeNote(
        uuid: 'uuid-del',
        title: 'To Delete',
        updatedAt: t1, // 原始时间戳，比删除时间 T2 早
      ));

      final engineB2 = _makeEngine(
        backend: backend,
        database: database,
        dataKey: testDataKey,
        encryptedDataKey: testEncryptedDataKey,
      );
      final result = await engineB2.sync();

      expect(result.success, isTrue);

      // uuid-del 应在本地标记为 deleted（远端墓碑 T2 > 本地 T1）
      final allNotes = await database.readAllNotesIncludingDeleted();
      final deletedNote = allNotes.firstWhere((n) => n.uuid == 'uuid-del');
      expect(deletedNote.deleted, isTrue);

      // readAllNotes 不应返回已删除的笔记
      final activeNotes = await database.readAllNotes();
      expect(activeNotes.any((n) => n.uuid == 'uuid-del'), isFalse);
    });
  });

  group('WebDAV 集成 - 多设备最终一致性', () {
    test('三台设备交替同步后数据一致', () async {
      // 设备 A：上传 2 条笔记
      await database.storeNote(_makeNote(uuid: 'uuid-1', title: 'Note 1'));
      await database.storeNote(_makeNote(uuid: 'uuid-2', title: 'Note 2'));
      final engineA = _makeEngine(
        backend: backend,
        database: database,
        dataKey: testDataKey,
        encryptedDataKey: testEncryptedDataKey,
        deviceId: 'device-a',
      );
      await engineA.sync();

      // 设备 B：下载 + 上传 1 条新笔记
      await database.close();
      final dbB = await openDatabase(
        ':memory:',
        version: 2,
        onCreate: NotesDatabase.createDBForTesting,
      );
      NotesDatabase.setDatabaseForTesting(dbB);
      database.setDataKey(testDataKey);

      await database.storeNote(_makeNote(uuid: 'uuid-3', title: 'Note 3'));
      final engineB = _makeEngine(
        backend: backend,
        database: database,
        dataKey: testDataKey,
        encryptedDataKey: testEncryptedDataKey,
        deviceId: 'device-b',
      );
      await engineB.sync();

      // 设备 C：下载所有笔记
      await database.close();
      final dbC = await openDatabase(
        ':memory:',
        version: 2,
        onCreate: NotesDatabase.createDBForTesting,
      );
      NotesDatabase.setDatabaseForTesting(dbC);
      database.setDataKey(testDataKey);

      final engineC = _makeEngine(
        backend: backend,
        database: database,
        dataKey: testDataKey,
        encryptedDataKey: testEncryptedDataKey,
        deviceId: 'device-c',
      );
      await engineC.sync();

      // 验证设备 C 有 3 条笔记
      var notes = await database.readAllNotes();
      expect(notes.length, 3);

      // 设备 A 再同步：应拿到设备 B 上传的 uuid-3
      await database.close();
      final dbA2 = await openDatabase(
        ':memory:',
        version: 2,
        onCreate: NotesDatabase.createDBForTesting,
      );
      NotesDatabase.setDatabaseForTesting(dbA2);
      database.setDataKey(testDataKey);

      // 先恢复设备 A 的本地状态（重新下载）
      final engineA2 = _makeEngine(
        backend: backend,
        database: database,
        dataKey: testDataKey,
        encryptedDataKey: testEncryptedDataKey,
        deviceId: 'device-a',
      );
      await engineA2.sync();

      notes = await database.readAllNotes();
      expect(notes.length, 3);
      expect(notes.any((n) => n.uuid == 'uuid-1'), isTrue);
      expect(notes.any((n) => n.uuid == 'uuid-2'), isTrue);
      expect(notes.any((n) => n.uuid == 'uuid-3'), isTrue);
    });
  });

  group('WebDAV 集成 - 孤儿 blob GC', () {
    test('同步后 listBlobs 返回所有已上传的 blob', () async {
      // 上传 2 条笔记（产生 2 个 blob）
      await database.storeNote(_makeNote(uuid: 'uuid-gc-1', title: 'GC 1'));
      await database.storeNote(_makeNote(uuid: 'uuid-gc-2', title: 'GC 2'));
      final engine = _makeEngine(
        backend: backend,
        database: database,
        dataKey: testDataKey,
        encryptedDataKey: testEncryptedDataKey,
      );
      await engine.sync();

      // listBlobs 应返回 2 个 blob hash
      final blobs = await backend.listBlobs();
      expect(blobs.length, greaterThanOrEqualTo(2));
    });
  });

  // ──────────────────────────────────────────────
  // 容错与自愈回归（Layer 1 / 2a / 2b）
  // 背景：一个用错误密钥加密的坏 blob 曾导致整次同步抛 InvalidCipherTextException
  // 并卡死所有客户端。以下测试验证：同步不再中断、密钥变更后强制重传、且持有
  // 明文的设备能自愈坏 blob。
  // ──────────────────────────────────────────────

  group('容错与自愈 - Layer 1 故障隔离（毒 blob 不中断同步）', () {
    test('远端一个 blob 用错误密钥加密，同步不抛异常且报告失败 uuid', () async {
      final dataKeyNew = SyncCrypto.generateDataKey();
      final dataKeyWrong = SyncCrypto.generateDataKey();
      final encK = base64Encode(SyncCrypto.wrapDataKey(dataKeyNew, dataKeyNew));
      database.setDataKey(dataKeyNew);

      // 1. 设备 A：上传一条正常笔记，建立干净的远端状态
      await database.storeNote(
        _makeNote(uuid: 'note-good', title: 'Good', description: 'ok'),
      );
      final engineA = _makeEngine(
        backend: backend,
        database: database,
        dataKey: dataKeyNew,
        encryptedDataKey: encK,
      );
      await engineA.sync();

      // 2. 在远端 manifest 追加一条 note-bad，但其 blob 用错误密钥加密（毒 blob）
      final badTitle = 'Bad';
      final badDesc = 'corrupt';
      final badHashForManifest = SafeNote.computeHash(badTitle, badDesc);
      final now = DateTime.now().millisecondsSinceEpoch;
      final badItem = ManifestItem(
        hash: badHashForManifest,
        deleted: false,
        updatedAt: now,
        updatedBy: 'attacker',
        createdAt: now,
        contentSize: badTitle.length + badDesc.length,
      );
      final remoteResp = await backend.getManifest();
      final cur = ManifestCrypto.deserialize(dataKeyNew, remoteResp.ciphertext);
      final newItems = Map<String, ManifestItem>.from(cur.items)
        ..['note-bad'] = badItem;
      await _uploadRemoteManifest(
        backend: backend,
        dataKey: dataKeyNew,
        items: newItems,
        encryptedDataKey: encK,
        kdf: KdfParams.create(salt: SyncCrypto.generateSalt()),
        version: cur.header.version + 1,
        expectedEtag: remoteResp.etag,
      );
      // 用错误密钥覆盖 note-bad 的 blob（解密必失败）
      await backend.putBlob(
        badHashForManifest,
        SyncCrypto.seal(
          dataKeyWrong,
          'note-bad',
          Uint8List.fromList(utf8.encode('garbage')),
        ),
      );

      // 3. 设备 B（空本地库）同步：应下载 note-good，note-bad 被容错处理
      await database.close();
      final dbB = await openDatabase(
        ':memory:',
        version: 2,
        onCreate: NotesDatabase.createDBForTesting,
      );
      NotesDatabase.setDatabaseForTesting(dbB);
      database.setDataKey(dataKeyNew);

      final engineB = _makeEngine(
        backend: backend,
        database: database,
        dataKey: dataKeyNew,
        encryptedDataKey: encK,
      );
      final result = await engineB.sync();

      expect(result.success, isTrue,
          reason: '单个坏 blob 不应中断整次同步');
      expect(result.failedNoteUuids, contains('note-bad'),
          reason: '坏 blob 应被记录为失败 uuid，供下次重试');
      expect(result.failedNoteUuids.length, 1);
      expect(result.downloaded, 1, reason: '正常笔记应成功下载');
      final goodLocal = await database.readNoteByUuid('note-good');
      expect(goodLocal, isNotNull);
      expect(goodLocal!.title, 'Good');
      final badLocal = await database.readNoteByUuid('note-bad');
      expect(badLocal, isNull,
          reason: '无本地明文的坏笔记不应写入本地（避免静默损坏）');
    });
  });

  group('容错与自愈 - Layer 2a 密钥变更触发 blob 重传', () {
    test('pending 重传标记下，相同 hash 的笔记在同步中被强制重传（覆盖旧密钥 blob）',
        () async {
      final dataKeyNew = SyncCrypto.generateDataKey();
      final dataKeyOld = SyncCrypto.generateDataKey();
      final encK = base64Encode(SyncCrypto.wrapDataKey(dataKeyNew, dataKeyNew));
      database.setDataKey(dataKeyNew);

      // 1. 本地有一条笔记（用 dataKeyNew 存储），内容与 hash 记为 H
      final note = _makeNote(
        uuid: 'note-mig',
        title: 'Mig',
        description: 'payload',
      );
      await database.storeNote(note);
      final hash = note.contentHash;

      // 2. 远端 manifest 持有同 hash 的条目（items 用 dataKeyNew 加密，便于引擎解析）
      await _uploadRemoteManifest(
        backend: backend,
        dataKey: dataKeyNew,
        items: {
          'note-mig': ManifestItem(
            hash: hash,
            deleted: false,
            updatedAt: note.updatedAt,
            updatedBy: 'device-x',
            createdAt: note.updatedAt,
            contentSize: note.toContentBytes().length,
          ),
        },
        encryptedDataKey: encK,
        kdf: KdfParams.create(salt: SyncCrypto.generateSalt()),
      );

      // 3. 注入"旧密钥残留 blob"：用 dataKeyOld 加密、同名 hash，模拟密钥变更前的遗留
      await backend.putBlob(
        hash,
        SyncCrypto.seal(dataKeyOld, 'note-mig', note.toContentBytes()),
      );

      // 4. 标记需重传（生产环境由 migrateToRemote 在 dataKey 变更时设置）
      await database.markAllForBlobReupload();

      // 5. 同步：因 pending 含 note-mig 且 hash 相同，引擎应强制用 dataKeyNew 重传覆盖
      final engine = _makeEngine(
        backend: backend,
        database: database,
        dataKey: dataKeyNew,
        encryptedDataKey: encK,
      );
      final result = await engine.sync();

      expect(result.success, isTrue);
      expect(result.uploaded, greaterThanOrEqualTo(1),
          reason: '应触发强制重传');
      expect(result.failedNoteUuids, isEmpty,
          reason: '重传后不应再报告失败');

      // 断言：blob 现在用 dataKeyNew 加密（旧密钥打不开，新密钥能打开并还原内容）
      // 协议 v2：重传后的 blob AAD = '<epoch>|内容 hash'（epoch 为当前 dataKeyEpoch）
      final blob = await backend.getBlob(hash);
      expect(blob, isNotNull);
      final opened = SyncCrypto.open(dataKeyNew, hash, blob!, epoch: 1);
      final content = SafeNote.fromContentBytes(opened);
      expect(content.title, 'Mig');
      expect(
        () => SyncCrypto.open(dataKeyOld, hash, blob, epoch: 1),
        throwsA(isA<Object>()),
        reason: '旧密钥应无法再解开已被重传覆盖的 blob',
      );
    });

    test('migrateToRemote 在 dataKey 变更时标记待重传 uuid（生产路径）', () async {
      // 构造：本地 MK 解开远端 encryptedDataKey 得到 remoteDataKey=R，且 R != 本地
      // dataKey=L → 触发"标记所有本地笔记需重传 blob"。
      final password = 'test-pass-123';
      final localSalt = SyncCrypto.generateSalt();
      final L = SyncCrypto.generateDataKey();
      final R = SyncCrypto.generateDataKey();
      final localMk = SyncCrypto.deriveMasterKey(password, salt: localSalt);
      final localEdk = base64Encode(SyncCrypto.wrapDataKey(localMk, L));
      // 用 localMk 包裹 R，使 checkMigrationNeeded 能解开并拿到 remoteDataKey=R
      final remoteEdk = base64Encode(SyncCrypto.wrapDataKey(localMk, R));

      final keyring = makeTestKeyring(
        vaultId: 'v-test',
        dataKey: L,
        encryptedDataKey: localEdk,
        keyFingerprint: SyncCrypto.computeKeyFingerprint(localMk),
        keyVersion: 1,
        kdf: KdfParams.create(salt: localSalt),
        createdAt: 1700000000000,
        mk: localMk,
      );

      // 本地存两条笔记（用 L 加密）
      database.setDataKey(L);
      await database.storeNote(_makeNote(uuid: 'u1', title: 'One'));
      await database.storeNote(_makeNote(uuid: 'u2', title: 'Two'));

      final migration = keyring.checkMigrationNeeded(remoteEdk);
      expect(migration.needsMigration, isTrue);
      expect(migration.success, isTrue);
      expect(migration.remoteDataKey, isNotNull);

      await keyring.migrateToRemote(result: migration, database: database);
      final pending = await database.getPendingReuploadUuids();
      expect(pending, containsAll(['u1', 'u2']),
          reason: 'dataKey 变更应把所有本地笔记标记为待重传');
    });
  });

  group('容错与自愈 - Layer 2b 持有明文时下载失败自愈重传', () {
    test('本地持有明文、远端 blob 损坏：自愈重传且后续设备可正常下载', () async {
      final dataKeyNew = SyncCrypto.generateDataKey();
      final dataKeyWrong = SyncCrypto.generateDataKey();
      final encK = base64Encode(SyncCrypto.wrapDataKey(dataKeyNew, dataKeyNew));
      database.setDataKey(dataKeyNew);

      final now = DateTime.now().millisecondsSinceEpoch;
      final localTitle = 'Local Version';
      final remoteTitle = 'Remote Version';
      final localHash = SafeNote.computeHash(localTitle, 'desc');
      final remoteHash = SafeNote.computeHash(remoteTitle, 'desc');

      // 本地持有明文（localTitle / localHash），updatedAt 较早。
      // 设定 syncedHash = 远端上一次同步收敛时的 hash（remoteHash）：
      // 表示本机这份笔记"上次同步的就是远端版本"，如今只是本地单方面改成了
      // localTitle。配合 base-hash 冲突判定 → remoteChanged=false、localChanged=true
      // → 单边编辑，走 LWW（远端较新）后自愈重传本地明文，不产生冲突副本。
      // （这正是自愈场景的真实语义：服务器持有上次同步版本，本地编辑后服务器
      //  blob 损坏，自愈把本地明文重新上传覆盖即可，不该多留一份副本。）
      await database.storeNote(_makeNote(
        uuid: 'note-heal',
        title: localTitle,
        description: 'desc',
        updatedAt: now,
      ).copyWith(syncedHash: remoteHash));
      // 远端 manifest 引用 remoteHash（不同内容），updatedAt 较晚 → 远端"赢" → 触发下载
      await _uploadRemoteManifest(
        backend: backend,
        dataKey: dataKeyNew,
        items: {
          'note-heal': ManifestItem(
            hash: remoteHash,
            deleted: false,
            updatedAt: now + 1000,
            updatedBy: 'device-x',
            createdAt: now,
            contentSize: remoteTitle.length + 4,
          ),
        },
        encryptedDataKey: encK,
        kdf: KdfParams.create(salt: SyncCrypto.generateSalt()),
      );
      // 远端 blob 用错误密钥加密（损坏），但 hash 对得上 manifest
      await backend.putBlob(
        remoteHash,
        SyncCrypto.seal(
          dataKeyWrong,
          'note-heal',
          Uint8List.fromList(utf8.encode('garbage')),
        ),
      );

      final engine = _makeEngine(
        backend: backend,
        database: database,
        dataKey: dataKeyNew,
        encryptedDataKey: encK,
      );
      final result = await engine.sync();

      expect(result.success, isTrue);
      expect(result.failedNoteUuids, isEmpty,
          reason: '自愈成功，不应报告失败');
      expect(result.uploaded, greaterThanOrEqualTo(1),
          reason: '应触发自愈重传');
      expect(
        result.actions.any((a) =>
            a.type == SyncActionType.heal && a.uuid == 'note-heal'),
        isTrue,
        reason: '应产生 heal 动作',
      );

      // 修复后的 blob（localHash）现在用 dataKeyNew 加密且内容为本机明文
      // （协议 v2：AAD = '<epoch>|内容 hash'）
      final repaired = await backend.getBlob(localHash);
      expect(repaired, isNotNull);
      final opened = SyncCrypto.open(dataKeyNew, localHash, repaired!, epoch: 1);
      final content = SafeNote.fromContentBytes(opened);
      expect(content.title, localTitle);

      // 端到端：第三台空设备能正常下载到修复后的笔记
      await database.close();
      final dbC = await openDatabase(
        ':memory:',
        version: 2,
        onCreate: NotesDatabase.createDBForTesting,
      );
      NotesDatabase.setDatabaseForTesting(dbC);
      database.setDataKey(dataKeyNew);
      final engineC = _makeEngine(
        backend: backend,
        database: database,
        dataKey: dataKeyNew,
        encryptedDataKey: encK,
      );
      final resultC = await engineC.sync();
      expect(resultC.success, isTrue);
      expect(resultC.downloaded, 1);
      expect(resultC.failedNoteUuids, isEmpty);
      final healed = await database.readNoteByUuid('note-heal');
      expect(healed, isNotNull);
      expect(healed!.title, localTitle);
    });
  });

  group('容错与自愈 - 共享 blob（相同内容多条笔记）', () {
    test('v2 协议：两条内容相同的笔记共享一个 blob，新设备两条都能下载', () async {
      final dataKey = SyncCrypto.generateDataKey();
      final encK = base64Encode(SyncCrypto.wrapDataKey(dataKey, dataKey));
      database.setDataKey(dataKey);

      // 设备 A：两条内容完全相同的笔记（不同 uuid，contentHash 相同 → 共享 blob）
      await database.storeNote(
        _makeNote(uuid: 'twin-1', title: 'Same', description: 'content'),
      );
      await database.storeNote(
        _makeNote(uuid: 'twin-2', title: 'Same', description: 'content'),
      );
      final engineA = _makeEngine(
        backend: backend,
        database: database,
        dataKey: dataKey,
        encryptedDataKey: encK,
      );
      final resultA = await engineA.sync();
      expect(resultA.success, isTrue);

      // 设备 B（空库）：两条都应正常下载（AAD=hash，任何 uuid 都能解开共享 blob）
      await database.close();
      final dbB = await openDatabase(
        ':memory:',
        version: 2,
        onCreate: NotesDatabase.createDBForTesting,
      );
      NotesDatabase.setDatabaseForTesting(dbB);
      database.setDataKey(dataKey);
      final engineB = _makeEngine(
        backend: backend,
        database: database,
        dataKey: dataKey,
        encryptedDataKey: encK,
      );
      final resultB = await engineB.sync();

      expect(resultB.success, isTrue);
      expect(resultB.failedNoteUuids, isEmpty,
          reason: 'v2 协议下共享 blob 不应导致任何一条解密失败');
      expect(resultB.downloaded, 2, reason: '两条同内容笔记都应下载成功');
      final n1 = await database.readNoteByUuid('twin-1');
      final n2 = await database.readNoteByUuid('twin-2');
      expect(n1?.title, 'Same');
      expect(n2?.title, 'Same');
    });

  });

  group('容错与自愈 - Layer 3 显式密钥纪元修复', () {
    test('blob 纪元过期被显式重传现代化（heal）', () async {
      final dataKey = SyncCrypto.generateDataKey();
      final encK = base64Encode(SyncCrypto.wrapDataKey(dataKey, dataKey));
      database.setDataKey(dataKey);
      // 引擎处于第 2 纪元（模拟一次 dataKey 值变更后的状态）
      final engine = _makeEngine(
        backend: backend,
        database: database,
        dataKey: dataKey,
        encryptedDataKey: encK,
        dataKeyEpoch: 2,
      );

      const uuid = 'l3-note';
      const title = 'Layer3';
      const description = 'epoch test';
      final hash = SafeNote.computeHash(title, description);

      await _uploadRemoteManifest(
        backend: backend,
        dataKey: dataKey,
        items: {
          uuid: ManifestItem(
            hash: hash,
            deleted: false,
            updatedAt: 1700000000000,
            updatedBy: 'seed',
            createdAt: 1700000000000,
            contentSize: 64,
            blobKeyEpoch: 1,
          ),
        },
        encryptedDataKey: encK,
        kdf: KdfParams.create(salt: SyncCrypto.generateSalt()),
      );

      // 注入 blob：用当前 dataKey 加密但 AAD 纪元=1（可被当前 key 解开）
      final content =
          _makeNote(uuid: uuid, title: title, description: description);
      final blob =
          SyncCrypto.seal(dataKey, hash, content.toContentBytes(), epoch: 1);
      await backend.putBlob(hash, blob);

      final result = await engine.sync();
      expect(result.success, isTrue, reason: '同步应成功');
      expect(result.downloaded, greaterThanOrEqualTo(1));
      expect(result.failedNoteUuids, isEmpty,
          reason: '纪元过期应被自愈而非失败');

      // 应产生 heal action（纪元不匹配显式修复）
      final healed = result.actions
          .where((a) => a.type == SyncActionType.heal && a.uuid == uuid)
          .toList();
      expect(healed, isNotEmpty, reason: '应产生纪元修复 heal action');

      // 重新拉取远端 manifest，验证 item.blobKeyEpoch 已被修正为 2
      final resp = await backend.getManifest();
      final cur = ManifestCrypto.deserialize(dataKey, resp.ciphertext);
      expect(cur.items[uuid]?.blobKeyEpoch, 2);

      // 重新上传的 blob 用 v2 AAD（'<epoch>|hash'，epoch=当前 dataKeyEpoch=2）可解
      final repaired = await backend.getBlob(hash);
      expect(repaired, isNotNull);
      final opened = SyncCrypto.open(dataKey, hash, repaired!, epoch: 2);
      final c = SafeNote.fromContentBytes(opened);
      expect(c.title, title);
    });
  });

  group('容错与自愈 - repair 全面修复远端数据', () {
    test('无密钥无明文时 repair 标记损坏（不丢数据）', () async {
      final dataKeyNew = SyncCrypto.generateDataKey();
      final dataKeyOld = SyncCrypto.generateDataKey();
      final encK = base64Encode(SyncCrypto.wrapDataKey(dataKeyNew, dataKeyNew));
      database.setDataKey(dataKeyNew);
      final engine = _makeEngine(
        backend: backend,
        database: database,
        dataKey: dataKeyNew,
        encryptedDataKey: encK,
        dataKeyEpoch: 2,
      );

      const uuid = 'doomed-note';
      const title = 'Doomed';
      const description = 'unrecoverable';
      final hash = SafeNote.computeHash(title, description);

      await _uploadRemoteManifest(
        backend: backend,
        dataKey: dataKeyNew,
        items: {
          uuid: ManifestItem(
            hash: hash,
            deleted: false,
            updatedAt: 1700000000000,
            updatedBy: 'seed',
            createdAt: 1700000000000,
            contentSize: 64,
            blobKeyEpoch: 1,
          ),
        },
        encryptedDataKey: encK,
        kdf: KdfParams.create(salt: SyncCrypto.generateSalt()),
      );

      // 坏 blob 用 dataKeyOld 加密，但本机未归档该历史密钥、也无明文
      final content =
          _makeNote(uuid: uuid, title: title, description: description);
      final blob = SyncCrypto.seal(
        dataKeyOld,
        hash,
        content.toContentBytes(),
        epoch: 1,
      );
      await backend.putBlob(hash, blob);

      // 不提供旧密码 → 无历史密钥候选 → 无明文 → 标记损坏
      final result = await engine.repairRemote();
      expect(result.success, isTrue);
      expect(result.failedNoteUuids, contains(uuid));
    });
  });
}
