// 集成测试：SafeServerBackend vs Go/Node.js 参考 server
//
// 测试策略：
//   1. setUpAll：调用 PS 清理脚本 → 构建 Go 二进制 → 生成配置文件 → 启动 server
//   2. 启动 server（Go 二进制 / Node.js 脚本）作为子进程，用配置文件配置
//   3. 轮询 /api/v2/health 等待 server 就绪
//   4. 用真实的 SafeServerBackend + SyncEngine 跑完整同步流程
//   5. 每个测试前清理 server 数据目录；tearDownAll 停 server + 调用 PS 清理脚本
//
// 清理脚本（test/scripts/test-cleanup.ps1）负责：
//   - 杀残留 server 进程（safeserver.exe / safenotes-server.exe / node server.js）
//   - 杀占用测试端口的进程
//   - 清理临时数据目录（$TEMP\safenotes-test, $TEMP\sn-test-*）
//   - 清理项目 temp/ 下的 server 日志文件
//
// 环境变量：
//   SN_SERVER=node  → 使用 Node.js server（默认用 Go）
//   SN_GO_DEBUG=1   → 启用 debug 日志
//   SN_GO_BIN=path  → 使用指定的 Go 二进制（跳过构建）
//
// 运行：
//   flutter test test/sync/safe_server_integration_test.dart
//
// 如果 go 和 node 都不在 PATH 中，测试自动跳过。

// 库级注解：构建二进制 + 启动 server 可能需要时间
@Timeout(Duration(seconds: 180))
library;

// Dart 原生导入
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// Package 导入
import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:core/core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// 测试公共支撑（P2：Keyring/Journal 构造 + FakeBackend journal 存储）
import 'sync_test_support.dart';

/// 测试用固定 Token
const String kTestToken = 'test-token-12345';

/// 测试用固定端口（PS 清理脚本会杀掉占用此端口的进程）
const int kTestPort = 8090;

/// 测试基础设施根目录（所有临时文件放这里，便于统一清理）
final String kTestRoot = '${Directory.systemTemp.path}\\safenotes-test';

/// 清理脚本路径
String get kCleanupScriptPath =>
    '${Directory.current.path}\\test\\scripts\\test-cleanup.ps1';

/// Go 二进制路径（setUpAll 时构建）
String? _goBinaryPath;

/// 临时配置文件路径（setUpAll 时生成）
String? _configFilePath;

/// server 子进程管理
class ServerProcess {
  final Process process;
  final int port;
  final String dataDir;
  final String logPath; // server 日志文件路径（调试用）

  ServerProcess(this.process, this.port, this.dataDir, this.logPath);

  /// server 基地址
  String get baseUrl => 'http://localhost:$port';

  /// 健康检查 URL
  String get healthUrl => 'http://localhost:$port/api/v2/health';

  /// 停止 server（可靠地杀进程树）
  ///
  /// 三级降级策略：
  ///   1. graceful shutdown（SIGTERM → Go/Node server 触发 graceful shutdown）
  ///   2. taskkill /T /F（杀进程树，包括子进程）
  ///   3. 兜底：PS 清理脚本会在 tearDownAll 中再清理一次
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
    if (!exited) {
      if (Platform.isWindows) {
        // taskkill /T /F：杀进程树（包括子进程），/F 强制
        try {
          await Process.run(
            'taskkill',
            ['/T', '/F', '/PID', process.pid.toString()],
          );
        } catch (_) {}
      } else {
        try {
          process.kill(ProcessSignal.sigkill);
        } catch (_) {}
      }
      // 等待进程真正退出
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
  }

  /// 等待 server 就绪（轮询 /api/v2/health）
  Future<bool> waitReady({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final res = await http.get(Uri.parse(healthUrl)).timeout(
              const Duration(seconds: 2),
            );
        if (res.statusCode == 200 && res.body == 'ok') {
          return true;
        }
      } catch (_) {
        // server 还没起来，继续等
      }
      await Future.delayed(const Duration(milliseconds: 300));
    }
    return false;
  }

  /// 清理 server 数据目录（vaults/ 下所有内容），让每个测试从干净状态开始
  ///
  /// 新存储布局：`<dataDir>/vaults/keyring-default/{manifest, blobs/}`
  /// 清理整个 vaults/ 目录即可重置到干净状态。
  Future<void> clearData() async {
    final vaultsDir = Directory('$dataDir\\vaults');

    if (vaultsDir.existsSync()) {
      try {
        await vaultsDir.delete(recursive: true);
      } catch (_) {
        // Windows 偶发文件占用，忽略
      }
    }
  }
}

// ──────────────────────────────────────────────
// 测试基础设施：清理脚本调用、构建、配置文件生成、进程管理
// ──────────────────────────────────────────────

/// 调用 PowerShell 清理脚本
///
/// 脚本负责：杀残留进程 + 端口清理 + 临时文件清理 + 日志清理。
/// 清理失败不抛异常（不应阻塞测试），只输出警告。
Future<void> runCleanupScript({
  List<int> ports = const [kTestPort],
  bool skipFileCleanup = false,
  bool detailed = false,
}) async {
  if (!Platform.isWindows) return; // Unix 可扩展用 pkill

  final args = <String>[
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', kCleanupScriptPath,
    '-Ports', ports.join(','),
    if (skipFileCleanup) '-SkipFileCleanup',
    if (detailed) '-Detailed',
  ];

  try {
    final result = await Process.run('pwsh', args);
    if (result.exitCode != 0) {
      print('Warning: cleanup script exited with ${result.exitCode}');
      if (result.stderr.toString().isNotEmpty) {
        print(result.stderr);
      }
    }
  } catch (e) {
    print('Warning: cleanup script failed to run: $e');
  }
}

/// 生成 Go server 配置文件（JSON）
///
/// Go server 通过 `-config <path>` 加载，包含所有运行参数。
/// 这样启动命令只需要 `safeserver.exe -config config.json`，整洁易调试。
Future<String> generateGoConfig({
  required int port,
  required String dataDir,
  required String token,
  required String logFile,
  String logLevel = 'info',
}) async {
  final config = <String, dynamic>{
    'addr': ':$port',
    'dataDir': dataDir,
    'token': token,
    'logLevel': logLevel,
    'logFile': logFile,
    'logJSON': false,
  };
  final configPath = '$kTestRoot\\go-config.json';
  await File(configPath).writeAsString(
    const JsonEncoder.withIndent('  ').convert(config),
  );
  return configPath;
}

/// 生成 Node.js server 配置文件（JSON）
///
/// Node server 通过 `--config <path>` 加载，字段名与 Go 不同（port vs addr）。
Future<String> generateNodeConfig({
  required int port,
  required String dataDir,
  required String token,
  required String logFile,
  String logLevel = 'info',
}) async {
  final config = <String, dynamic>{
    'port': port,
    'dataDir': dataDir,
    'token': token,
    'logLevel': logLevel,
    'logFile': logFile,
    'logJSON': false,
  };
  final configPath = '$kTestRoot\\node-config.json';
  await File(configPath).writeAsString(
    const JsonEncoder.withIndent('  ').convert(config),
  );
  return configPath;
}

/// 构建测试基础设施（setUpAll 调用一次）
///
/// 步骤：
///   1. 调用 PS 清理脚本（杀残留进程 + 清理临时文件）
///   2. 创建测试根目录
///   3. 构建 Go 二进制（如果用 Go server）
///   4. 返回是否就绪
Future<bool> setupTestInfra({required bool useGo}) async {
  // 1. 调用 PS 清理脚本：杀残留进程 + 清理临时文件 + 清理日志
  //    详细模式输出进程命令行，便于排查
  await runCleanupScript(detailed: true);

  // 2. 创建测试根目录（清理脚本可能已删除它）
  final testRoot = Directory(kTestRoot);
  if (!testRoot.existsSync()) {
    await testRoot.create(recursive: true);
  }

  // 3. 构建 Go 二进制
  if (useGo) {
    _goBinaryPath = await buildGoBinary();
    if (_goBinaryPath == null) {
      return false;
    }
  }

  return true;
}

/// 构建 Go server 二进制到测试目录
///
/// 返回二进制路径，构建失败返回 null。
/// 如果环境变量 SN_GO_BIN 指定了二进制路径，直接使用（跳过构建）。
Future<String?> buildGoBinary() async {
  final repoRoot = Directory.current.path;
  final goSrcDir = '$repoRoot\\server\\go';
  final binPath = '$kTestRoot\\safeserver.exe';

  // 如果环境变量指定了二进制，直接用
  final envBin = Platform.environment['SN_GO_BIN'];
  if (envBin != null && envBin.isNotEmpty && File(envBin).existsSync()) {
    return envBin;
  }

  // 检查 go 是否可用
  try {
    final result = await Process.run('go', ['version']);
    if (result.exitCode != 0) return null;
  } catch (_) {
    return null;
  }

  // 构建二进制（构建前确保旧二进制已被清理，避免文件占用）
  final oldBin = File(binPath);
  if (oldBin.existsSync()) {
    try {
      await oldBin.delete();
    } catch (_) {
      // 文件被占用（旧 server 还在运行？）—— PS 清理脚本应该已经杀掉了
    }
  }

  final result = await Process.run(
    'go',
    ['build', '-o', binPath, '.'],
    workingDirectory: goSrcDir,
  );

  if (result.exitCode != 0) {
    print('Go build failed:');
    print(result.stderr);
    return null;
  }

  return binPath;
}

/// 启动 Go server（使用配置文件）
Future<ServerProcess?> startGoServer(int port, String dataDir) async {
  if (_goBinaryPath == null || !File(_goBinaryPath!).existsSync()) {
    return null;
  }

  // 调试模式：SN_GO_DEBUG=1 时启用 debug 日志
  final debugMode = Platform.environment['SN_GO_DEBUG'] == '1';
  final logFile = '$kTestRoot\\server-go-$port.log';
  final logLevel = debugMode ? 'debug' : 'info';

  // 生成配置文件
  _configFilePath = await generateGoConfig(
    port: port,
    dataDir: dataDir,
    token: kTestToken,
    logFile: logFile,
    logLevel: logLevel,
  );

  try {
    // 用配置文件启动，无需其他 CLI 参数
    final process = await Process.start(
      _goBinaryPath!,
      ['-config', _configFilePath!],
    );
    return ServerProcess(process, port, dataDir, logFile);
  } catch (e) {
    print('Failed to start Go server: $e');
    return null;
  }
}

/// 启动 Node.js server（使用配置文件）
Future<ServerProcess?> startNodeServer(int port, String dataDir) async {
  // 检查 node 是否可用
  try {
    final result = await Process.run('node', ['--version']);
    if (result.exitCode != 0) return null;
  } catch (_) {
    return null;
  }

  final repoRoot = Directory.current.path;
  final scriptPath = '$repoRoot\\server\\nodejs\\server.js';
  if (!File(scriptPath).existsSync()) return null;

  // 调试模式：SN_GO_DEBUG=1 时启用 debug 日志
  final debugMode = Platform.environment['SN_GO_DEBUG'] == '1';
  final logFile = '$kTestRoot\\server-node-$port.log';
  final logLevel = debugMode ? 'debug' : 'info';

  // 生成配置文件
  _configFilePath = await generateNodeConfig(
    port: port,
    dataDir: dataDir,
    token: kTestToken,
    logFile: logFile,
    logLevel: logLevel,
  );

  try {
    // 用配置文件启动，无需其他 CLI 参数
    final process = await Process.start(
      'node',
      [scriptPath, '--config', _configFilePath!],
    );
    return ServerProcess(process, port, dataDir, logFile);
  } catch (e) {
    print('Failed to start Node.js server: $e');
    return null;
  }
}

/// 根据 SN_SERVER 环境变量选择 server
Future<ServerProcess?> startServer(int port, String dataDir) async {
  final serverType = Platform.environment['SN_SERVER'] ?? 'go';
  if (serverType == 'node') {
    return startNodeServer(port, dataDir);
  }
  return startGoServer(port, dataDir);
}

/// 创建唯一的测试数据目录
String makeTestDataDir(String label) {
  final dir = '$kTestRoot\\data-$label-${DateTime.now().millisecondsSinceEpoch}';
  Directory(dir).createSync(recursive: true);
  return dir;
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
  required SafeServerBackend backend,
  required NotesDatabase database,
  required Uint8List dataKey,
  required String encryptedDataKey,
}) {
  // 与 sync_engine_test.dart 保持一致：通过 Keyring 构造 SyncEngine
  final keyring = makeTestKeyring(
    vaultId: 'test-keyring-id',
    dataKey: dataKey,
    encryptedDataKey: encryptedDataKey,
    keyFingerprint: '',
    keyVersion: 1,
    kdf: KdfParams.create(salt: SyncCrypto.generateSalt()),
    createdAt: DateTime.now().millisecondsSinceEpoch,
  );
  return SyncEngine(
    backend: backend,
    database: database,
    keyring: keyring,
    deviceId: 'test-device',
    journal: makeTestJournal(),
  );
}

void main() {
  // 初始化 sqflite_ffi（桌面测试环境）
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  // server 进程和资源管理（setUpAll 启动一次，所有测试共享）
  late ServerProcess server;
  late NotesDatabase database;
  late Uint8List testDataKey;
  late String testEncryptedDataKey;
  late SafeServerBackend backend;

  // setUpAll：清理 → 构建二进制 → 生成配置 → 启动 server → 等待就绪
  setUpAll(() async {
    final serverType = Platform.environment['SN_SERVER'] ?? 'go';
    final useGo = serverType != 'node';

    // 1. 清理残留进程 + 临时文件 + 构建 Go 二进制
    final infraReady = await setupTestInfra(useGo: useGo);
    if (!infraReady) {
      throw StateError(
        useGo
            ? '无法构建 Go server 二进制（go 不在 PATH 或编译失败）'
            : '无法初始化 Node.js 测试环境',
      );
    }

    // 2. 启动 server（固定端口，数据目录用时间戳唯一化）
    final dataDir = makeTestDataDir('main');
    final serverProc = await startServer(kTestPort, dataDir);
    if (serverProc == null) {
      throw StateError('无法启动 server（$serverType 不可用）');
    }
    server = serverProc;

    // 3. 等待 server 就绪（二进制启动很快，15 秒足够）
    final ready = await server.waitReady(timeout: const Duration(seconds: 15));
    if (!ready) {
      await server.stop();
      throw StateError('server 启动超时（15s），检查日志: ${server.logPath}');
    }
  });

  tearDownAll(() async {
    // 1. 停止 server（graceful + force）
    await server.stop();
    // 2. 最终清理：调用 PS 脚本确保没有进程泄漏
    //    跳过文件清理（保留日志供调试），只杀进程
    await runCleanupScript(skipFileCleanup: true);
  });

  setUp(() async {
    // 每个测试前清理 server 数据（比重启 server 快得多）
    await server.clearData();

    // 创建新的 SafeServerBackend（每次测试用新的 HTTP client）
    backend = SafeServerBackend(
      baseUrl: server.baseUrl,
      token: kTestToken,
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
      await SyncCrypto.wrapDataKey(testDataKey, testDataKey),
    );
  });

  tearDown(() async {
    await database.close();
    await backend.close();
  });

  group('SafeServer 集成 - 首次同步', () {
    test('空数据库首次同步：只上传 manifest', () async {
      // ignore: unused_local_variable
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

      // 验证 manifest version
      final version = await database.getManifestVersion(backend.providerKey);
      expect(version, 1);

      // 验证所有笔记标记为已同步
      final notes = await database.readAllNotesIncludingDeleted();
      for (final note in notes) {
        expect(note.synced, isTrue);
      }
    });
  });

  group('SafeServer 集成 - 新设备同步', () {
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

  group('SafeServer 集成 - 增量同步', () {
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
      expect(result.downloaded, 1); // 从远端拉到 A
      expect(result.uploaded, 1);   // 推送 B 到远端

      // 验证本地同时有 A 和 B
      final notes = await database.readAllNotes();
      expect(notes.length, 2);
      expect(notes.any((n) => n.uuid == 'uuid-a'), isTrue);
      expect(notes.any((n) => n.uuid == 'uuid-b'), isTrue);
    });
  });

  group('SafeServer 集成 - LWW 冲突解决', () {
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

  group('SafeServer 集成 - 墓碑同步', () {
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

      // 设备 B：先同步下载笔记（本地 updatedAt = T1）
      await database.close();
      final dbB = await openDatabase(
        ':memory:',
        version: 2,
        onCreate: NotesDatabase.createDBForTesting,
      );
      NotesDatabase.setDatabaseForTesting(dbB);
      database.setDataKey(testDataKey);

      final engineB = _makeEngine(
        backend: backend,
        database: database,
        dataKey: testDataKey,
        encryptedDataKey: testEncryptedDataKey,
      );
      await engineB.sync();

      // 验证设备 B 有这条笔记
      var note = await database.readNoteByUuid('uuid-del');
      expect(note, isNotNull);
      expect(note!.deleted, isFalse);

      // 设备 A：软删除笔记并同步（时间戳 T2 > T1）
      await database.close();
      final dbA2 = await openDatabase(
        ':memory:',
        version: 2,
        onCreate: NotesDatabase.createDBForTesting,
      );
      NotesDatabase.setDatabaseForTesting(dbA2);
      database.setDataKey(testDataKey);

      final t2 = t1 + 5000; // 删除时间晚于创建时间
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

      // 设备 B：再次同步，远端墓碑 updatedAt=T2 > 本地 T1 → 远端胜
      await database.close();
      final dbB2 = await openDatabase(
        ':memory:',
        version: 2,
        onCreate: NotesDatabase.createDBForTesting,
      );
      NotesDatabase.setDatabaseForTesting(dbB2);
      database.setDataKey(testDataKey);

      // 设备 B 本地已有笔记（updatedAt=T1，从上次同步得到）
      await database.storeNote(_makeNote(
        uuid: 'uuid-del',
        title: 'To Delete',
        updatedAt: t1, // 用原始时间戳，比删除时间 T2 早
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

  group('SafeServer 集成 - 幂等性', () {
    test('连续两次同步结果一致（无重复传输）', () async {
      await database.storeNote(_makeNote(uuid: 'uuid-1', title: 'Note 1'));
      await database.storeNote(_makeNote(uuid: 'uuid-2', title: 'Note 2'));

      final engine = _makeEngine(
        backend: backend,
        database: database,
        dataKey: testDataKey,
        encryptedDataKey: testEncryptedDataKey,
      );

      // 第一次同步
      final result1 = await engine.sync();
      expect(result1.success, isTrue);
      expect(result1.uploaded, 2);

      // 第二次同步：应该全部跳过
      final result2 = await engine.sync();
      expect(result2.success, isTrue);
      expect(result2.uploaded, 0);
      expect(result2.downloaded, 0);
      expect(result2.skipped, greaterThan(0));
    });
  });

  group('SafeServer 集成 - 原始 HTTP 协议验证', () {
    test('GET 不存在的 manifest 返回 404', () async {
      final res = await http.get(
        Uri.parse('${server.baseUrl}/api/v2/manifest'),
        headers: {'Authorization': 'Bearer $kTestToken'},
      );
      expect(res.statusCode, 404);
    });

    test('无认证返回 401 + WWW-Authenticate: Bearer', () async {
      final res = await http.get(
        Uri.parse('${server.baseUrl}/api/v2/manifest'),
      );
      expect(res.statusCode, 401);
      expect(
        res.headers['www-authenticate']?.toLowerCase(),
        contains('bearer'),
      );
    });

    test('错误 Token 返回 401', () async {
      final res = await http.get(
        Uri.parse('${server.baseUrl}/api/v2/manifest'),
        headers: {'Authorization': 'Bearer wrong-token'},
      );
      expect(res.statusCode, 401);
    });

    test('PUT manifest 带 If-None-Match: * 首次上传成功，重复返回 412', () async {
      // 首次上传
      final res = await http.put(
        Uri.parse('${server.baseUrl}/api/v2/manifest'),
        headers: {
          'Authorization': 'Bearer $kTestToken',
          'If-None-Match': '*',
          'Content-Type': 'application/octet-stream',
        },
        body: utf8.encode('test-manifest-ciphertext'),
      );

      expect(res.statusCode, anyOf(200, 201));
      expect(res.headers['etag'], isNotNull);

      // 重复 If-None-Match: * → 412
      final res2 = await http.put(
        Uri.parse('${server.baseUrl}/api/v2/manifest'),
        headers: {
          'Authorization': 'Bearer $kTestToken',
          'If-None-Match': '*',
          'Content-Type': 'application/octet-stream',
        },
        body: utf8.encode('test-manifest-ciphertext-2'),
      );
      expect(res2.statusCode, 412);
    });

    test('PUT manifest 带 If-Match 错误 etag 返回 412', () async {
      final res = await http.put(
        Uri.parse('${server.baseUrl}/api/v2/manifest'),
        headers: {
          'Authorization': 'Bearer $kTestToken',
          'If-Match': '"wrong-etag"',
          'Content-Type': 'application/octet-stream',
        },
        body: utf8.encode('test'),
      );
      expect(res.statusCode, 412);
    });

    test('PUT manifest 带 If-Match 正确 etag 成功更新', () async {
      // 先用 If-None-Match: * 上传初始 manifest
      final initRes = await http.put(
        Uri.parse('${server.baseUrl}/api/v2/manifest'),
        headers: {
          'Authorization': 'Bearer $kTestToken',
          'If-None-Match': '*',
          'Content-Type': 'application/octet-stream',
        },
        body: utf8.encode('v1'),
      );
      expect(initRes.statusCode, anyOf(200, 201));
      final etag = initRes.headers['etag'];
      expect(etag, isNotNull);

      // 去掉引号后用 If-Match 更新
      final etagValue = etag!.replaceAll('"', '');
      final updateRes = await http.put(
        Uri.parse('${server.baseUrl}/api/v2/manifest'),
        headers: {
          'Authorization': 'Bearer $kTestToken',
          'If-Match': '"$etagValue"',
          'Content-Type': 'application/octet-stream',
        },
        body: utf8.encode('v2'),
      );
      expect(updateRes.statusCode, anyOf(200, 201));
      expect(updateRes.headers['etag'], isNotNull);
      // 新 ETag 应该与旧的不同
      expect(updateRes.headers['etag'], isNot(etag));
    });

    test('PUT 和 GET blob 端到端', () async {
      const hash = 'abc123testhash';
      final blobData = utf8.encode('test-blob-content');

      // PUT blob
      final putRes = await http.put(
        Uri.parse('${server.baseUrl}/api/v2/blob/$hash'),
        headers: {
          'Authorization': 'Bearer $kTestToken',
          'Content-Type': 'application/octet-stream',
        },
        body: blobData,
      );
      expect(putRes.statusCode, anyOf(200, 201));

      // GET blob
      final getRes = await http.get(
        Uri.parse('${server.baseUrl}/api/v2/blob/$hash'),
        headers: {'Authorization': 'Bearer $kTestToken'},
      );
      expect(getRes.statusCode, 200);
      expect(getRes.bodyBytes, equals(blobData));

      // GET 不存在的 blob → 404
      final notFoundRes = await http.get(
        Uri.parse('${server.baseUrl}/api/v2/blob/nonexistent'),
        headers: {'Authorization': 'Bearer $kTestToken'},
      );
      expect(notFoundRes.statusCode, 404);
    });

    test('GET /api/v2/health 不需要认证', () async {
      final res = await http.get(
        Uri.parse('${server.baseUrl}/api/v2/health'),
      );
      expect(res.statusCode, 200);
      expect(res.body, 'ok');
    });
  });

  // v2.1 新增端点：DELETE blob、GET blobs、DELETE manifest、速率限制
  group('SafeServer 集成 - v2.1 GC 与自愈端点', () {
    test('GET /api/v2/blobs 返回所有 blob hash', () async {
      // 先上传 2 个 blob
      await http.put(
        Uri.parse('${server.baseUrl}/api/v2/blob/gc-hash-1'),
        headers: {
          'Authorization': 'Bearer $kTestToken',
          'Content-Type': 'application/octet-stream',
        },
        body: utf8.encode('blob1'),
      );
      await http.put(
        Uri.parse('${server.baseUrl}/api/v2/blob/gc-hash-2'),
        headers: {
          'Authorization': 'Bearer $kTestToken',
          'Content-Type': 'application/octet-stream',
        },
        body: utf8.encode('blob2'),
      );

      final res = await http.get(
        Uri.parse('${server.baseUrl}/api/v2/blobs'),
        headers: {'Authorization': 'Bearer $kTestToken'},
      );
      expect(res.statusCode, 200);
      final List<dynamic> hashes = jsonDecode(res.body);
      expect(hashes, containsAll(['gc-hash-1', 'gc-hash-2']));
    });

    test('SafeServerBackend.listBlobs() 通过客户端调用返回 blob 列表', () async {
      // 先上传 blob
      await http.put(
        Uri.parse('${server.baseUrl}/api/v2/blob/backend-list-test'),
        headers: {
          'Authorization': 'Bearer $kTestToken',
          'Content-Type': 'application/octet-stream',
        },
        body: utf8.encode('test'),
      );

      // 通过 SafeServerBackend 调用
      final blobs = await backend.listBlobs();
      expect(blobs, contains('backend-list-test'));
    });

    test('GET /api/v2/blobs 空目录时返回空数组', () async {
      // clearData 已在 setUp 中清空 blobs 目录
      final res = await http.get(
        Uri.parse('${server.baseUrl}/api/v2/blobs'),
        headers: {'Authorization': 'Bearer $kTestToken'},
      );
      expect(res.statusCode, 200);
      expect(jsonDecode(res.body), isEmpty);
    });

    test('DELETE /api/v2/blob/<hash> 删除 blob', () async {
      // 先上传
      await http.put(
        Uri.parse('${server.baseUrl}/api/v2/blob/del-test'),
        headers: {
          'Authorization': 'Bearer $kTestToken',
          'Content-Type': 'application/octet-stream',
        },
        body: utf8.encode('test'),
      );

      // DELETE
      final delRes = await http.delete(
        Uri.parse('${server.baseUrl}/api/v2/blob/del-test'),
        headers: {'Authorization': 'Bearer $kTestToken'},
      );
      expect(delRes.statusCode, 204);

      // 验证已删除
      final getRes = await http.get(
        Uri.parse('${server.baseUrl}/api/v2/blob/del-test'),
        headers: {'Authorization': 'Bearer $kTestToken'},
      );
      expect(getRes.statusCode, 404);
    });

    test('DELETE 不存在的 blob 返回 204（幂等）', () async {
      final res = await http.delete(
        Uri.parse('${server.baseUrl}/api/v2/blob/nonexistent'),
        headers: {'Authorization': 'Bearer $kTestToken'},
      );
      expect(res.statusCode, 204);
    });

    test('SafeServerBackend.deleteBlob() 通过客户端调用删除 blob', () async {
      // 先上传
      await http.put(
        Uri.parse('${server.baseUrl}/api/v2/blob/backend-del-test'),
        headers: {
          'Authorization': 'Bearer $kTestToken',
          'Content-Type': 'application/octet-stream',
        },
        body: utf8.encode('test'),
      );

      // 通过 backend 调用
      await backend.deleteBlob('backend-del-test');

      // 验证已删除
      final getRes = await http.get(
        Uri.parse('${server.baseUrl}/api/v2/blob/backend-del-test'),
        headers: {'Authorization': 'Bearer $kTestToken'},
      );
      expect(getRes.statusCode, 404);
    });

    test('DELETE /api/v2/manifest 清理 manifest', () async {
      // 先上传 manifest
      await http.put(
        Uri.parse('${server.baseUrl}/api/v2/manifest'),
        headers: {
          'Authorization': 'Bearer $kTestToken',
          'If-None-Match': '*',
          'Content-Type': 'application/octet-stream',
        },
        body: utf8.encode('corrupt-manifest'),
      );

      // DELETE
      final delRes = await http.delete(
        Uri.parse('${server.baseUrl}/api/v2/manifest'),
        headers: {'Authorization': 'Bearer $kTestToken'},
      );
      expect(delRes.statusCode, 204);

      // 验证已删除
      final getRes = await http.get(
        Uri.parse('${server.baseUrl}/api/v2/manifest'),
        headers: {'Authorization': 'Bearer $kTestToken'},
      );
      expect(getRes.statusCode, 404);
    });

    test('DELETE 不存在的 manifest 返回 204（幂等）', () async {
      final res = await http.delete(
        Uri.parse('${server.baseUrl}/api/v2/manifest'),
        headers: {'Authorization': 'Bearer $kTestToken'},
      );
      expect(res.statusCode, 204);
    });

    test('SafeServerBackend.backupCorruptManifest() 通过客户端调用清理 manifest',
        () async {
      // 先上传 manifest
      await http.put(
        Uri.parse('${server.baseUrl}/api/v2/manifest'),
        headers: {
          'Authorization': 'Bearer $kTestToken',
          'If-None-Match': '*',
          'Content-Type': 'application/octet-stream',
        },
        body: utf8.encode('corrupt'),
      );

      // 通过 backend 调用
      await backend.backupCorruptManifest(Uint8List.fromList(utf8.encode('corrupt')));

      // 验证已删除
      final getRes = await http.get(
        Uri.parse('${server.baseUrl}/api/v2/manifest'),
        headers: {'Authorization': 'Bearer $kTestToken'},
      );
      expect(getRes.statusCode, 404);
    });

    test(
        'SafeServerBackend.deleteBlobSoft/listOrphanBlobs/purgeOrphans 真实 server 隔离与清理链路',
        () async {
      // 64 位 hex 哈希（sha256 空串），满足 purgeOrphans 的 hash 长度过滤（==64）
      const hash =
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

      // 1. 上传一个真实 blob
      await http.put(
        Uri.parse('${server.baseUrl}/api/v2/blob/$hash'),
        headers: {
          'Authorization': 'Bearer $kTestToken',
          'Content-Type': 'application/octet-stream',
        },
        body: utf8.encode('orphan-blob-content'),
      );

      // 2. 上传后：活动 blobs 列表包含该 hash
      expect(await backend.listBlobs(), contains(hash));

      // 3. 软删除（v2.2 资源层 move 到 blobs-orphan/）
      await backend.deleteBlobSoft(hash);

      // 4. 软删除后：活动 blobs 不再包含该 hash，但隔离区包含它
      expect(await backend.listBlobs(), isNot(contains(hash)));
      expect(await backend.listOrphanBlobs(), contains(hash));

      // 5. 隔离区确有物理文件（propfind 可见），证明是 move 而非直接删除
      //    （propfind depth=1 返回目录自身 + 子项，故按文件名是否含 hash 过滤）
      final orphanDir = await http.post(
        Uri.parse('${server.baseUrl}/api/v2/resources/blobs-orphan'),
        headers: {
          'Authorization': 'Bearer $kTestToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'op': 'propfind', 'depth': 1}),
      );
      expect(orphanDir.statusCode, 200);
      final orphanEntries = jsonDecode(orphanDir.body) as List<dynamic>;
      final orphanFiles = orphanEntries
          .where((e) => ((e is Map ? e['name'] : null)?.toString() ?? '')
              .contains(hash))
          .toList();
      expect(orphanFiles.length, 1,
          reason: 'blobs-orphan/ 应恰有一个以该 hash 命名的孤儿文件');

      // 6. 立即 purge（retention=0，孤儿 ts 早于 now 必删）
      await backend.purgeOrphans(Duration.zero);

      // 7. 清理后：隔离区清空，活动 blobs 仍不含该 hash
      expect(await backend.listOrphanBlobs(), isNot(contains(hash)));
      expect(await backend.listBlobs(), isNot(contains(hash)));
    });

    test('未认证访问 GET /api/v2/blobs 返回 401', () async {
      final res = await http.get(
        Uri.parse('${server.baseUrl}/api/v2/blobs'),
      );
      expect(res.statusCode, 401);
    });
  });

  // 速率限制测试：必须放在文件最后！
  // 触发后同 IP 的所有请求会被拒绝 60 秒，后续测试无法继续。
  // health 端点不受限速影响，所以 tearDown/tearDownAll 仍能正常工作。
  group('SafeServer 集成 - v2.1 速率限制', () {
    test('连续认证失败超限后返回 429 Too Many Requests', () async {
      // 默认 rate-limit=10/min
      // 注意：此测试前可能已有少量 401 失败（来自其他测试），阈值可能更早触发
      bool got429 = false;
      for (int i = 0; i < 15; i++) {
        final res = await http.get(
          Uri.parse('${server.baseUrl}/api/v2/manifest'),
          headers: {'Authorization': 'Bearer wrong-token-$i'},
        );
        if (res.statusCode == 429) {
          got429 = true;
          expect(res.headers['retry-after'], isNotNull);
          break;
        }
        expect(res.statusCode, 401,
            reason: '触发限速前应返回 401，第 ${i + 1} 次却返回了 ${res.statusCode}');
      }
      expect(got429, isTrue, reason: '应在达到认证失败阈值后返回 429');
    });
  });
}
