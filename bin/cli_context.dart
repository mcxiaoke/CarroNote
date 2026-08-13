// SafeNotes CLI 运行时上下文（纯 Dart，无 Flutter 依赖）。
//
// CLI 是核心逻辑的第二个前端（App 是第一个）。本文件只依赖纯 Dart 包
// （core + sqflite_common_ffi + args + path），任何 Flutter 依赖都会导致
// 编译失败——这是架构约束的守卫。
//
// 职责：
//   1. 数据目录引导（sqflite FFI / 日志目录 / 数据库 / 持久化设备 ID）
//   2. 密钥解锁（Keyring.unlockLocal → setDataKey）
//   3. 后端与同步引擎装配（等价于 App SyncService 的 initialize，但不依赖
//      path_provider / shared_preferences，直接构造 core 对象）
//
// 数据目录 = 一个"设备实例"，两个不同 data-dir 即可模拟两台设备做同步/冲突
// /迁移测试。密码 / WebDAV 凭据 / SafeServer Token 均不入 SQLite。

// Dart 原生导入

// Dart imports:
import 'dart:convert';
import 'dart:io';

// Package imports:
import 'package:args/args.dart';
import 'package:core/core.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Package 导入

/// CLI 用户可预期错误：打印消息后退出码 1（不打印堆栈）。
class CliException implements Exception {
  final String message;
  CliException(this.message);

  @override
  String toString() => message;
}

/// CLI 配置在 sync_meta 表中的键名（非敏感；敏感凭据不入库）。
///
/// meta 表与 App 共享同一 SQLite（schema v4），此处新增的键名带 `cli_` 前缀，
/// 与 App 侧键（keyring / purged_uuids / blob_reupload_pending 等）互不冲突。
class CliConfigKeys {
  /// 设备 ID：首次生成并持久化，保证同一数据目录跨命令调用设备身份稳定
  ///（manifest lastModifiedBy / journal 按设备隔离都依赖它）。
  static const String deviceId = 'cli_device_id';

  static const String backendType = 'cli_backend_type';
  static const String localFsPath = 'cli_backend_localfs_path';
  static const String webdavUrl = 'cli_backend_webdav_url';
  static const String webdavUsername = 'cli_backend_webdav_username';
  static const String safeServerUrl = 'cli_backend_safeserver_url';
}

/// CLI 后端类型（写 sync_meta 的 cli_backend_type）
class CliBackendType {
  static const String none = 'none';
  static const String localFs = 'localfs';
  static const String webdav = 'webdav';
  static const String safeServer = 'safeserver';
}

/// 从全局参数解析解锁密码，优先级：--password > --password-file > SN_PASSWORD。
///
/// 密码不落库、不进进程列表（读取自文件 / 环境变量时）；明文参数仅用于
/// 交互式终端，脚本自动化请用 --password-file 或环境变量。
String? resolveCliPassword(ArgResults global) {
  final flag = global['password'] as String?;
  if (flag != null && flag.isNotEmpty) return flag;

  final file = global['password-file'] as String?;
  if (file != null && file.isNotEmpty) {
    try {
      final content = File(file).readAsStringSync().trim();
      if (content.isNotEmpty) return content;
    } on Object {
      throw CliException('读取密码文件失败: $file');
    }
  }

  final env = Platform.environment['SN_PASSWORD'];
  return (env != null && env.isNotEmpty) ? env : null;
}

/// 从全局参数引导一个 CLI 上下文（读取 --data-dir / --device-id）。
Future<CliContext> bootstrapCtx(ArgResults global) async {
  final dataDir = global['data-dir'] as String;
  return CliContext.bootstrap(
    dataDir: dataDir,
    deviceIdOverride: global['device-id'] as String?,
  );
}

/// CLI 运行时上下文：一条命令 = 一个进程，因此每次都要在此恢复完整状态。
class CliContext {
  /// 数据目录绝对路径（数据库 + 日志 + journal + 可选凭据文件）
  final String dataDir;

  /// 本地数据库（schema v4，与 App 完全一致）
  final NotesDatabase database;

  /// 持久化的设备 ID（manifest lastModifiedBy / journal 隔离用）
  final String deviceId;

  /// 会话密码：用于 SyncEngine.passphraseProvider（场景 d 判别）与改密码
  String? password;

  /// 解锁后的 Keyring（未解锁为 null）
  Keyring? keyring;

  /// 按 meta 配置构建的同步后端（未配置为 null）
  SyncBackend? backend;

  /// 操作日志：engine 生命周期内单实例（改密码/换后端不重开，seq 连续）
  Journal? journal;

  /// 同步引擎（解锁 + 后端配置齐备后装配）
  SyncEngine? engine;

  CliContext._({
    required this.dataDir,
    required this.database,
    required this.deviceId,
  });

  /// 引导：建数据目录 → sqflite FFI → 日志目录 → 打开数据库 → 恢复设备 ID。
  static Future<CliContext> bootstrap({
    required String dataDir,
    String? deviceIdOverride,
  }) async {
    // sqflite_common_ffi 对相对路径会解析到其默认 databases 目录
    //（.dart_tool/.../databases），必须统一为绝对路径，否则 --data-dir 错位。
    final abs = Directory(dataDir).absolute.path;
    final dir = Directory(abs);
    await dir.create(recursive: true);

    // 纯 Dart SQLite：与 App 桌面端同一注入点（dbFactoryOverride）
    sqfliteFfiInit();
    NotesDatabase.dbFactoryOverride = databaseFactoryFfi;
    NotesDatabase.dbPathOverride = abs;

    // CLI 侧日志目录注入（核心日志逻辑保持纯 Dart）。
    // 关闭 console 输出：核心 Log 走 print() 会污染命令 stdout（尤其 --json）。
    // 文件日志与内存缓冲仍启用，`log cat` / 诊断面板可正常使用。
    logDirResolverOverride = () async => abs;
    AppLogFile.consoleEnabled = false;
    AppLogFile.preferLogDirOverride = true;
    await AppLogFile.init();

    final db = NotesDatabase.instance;
    await db.database;

    // 设备 ID：显式覆盖优先；否则读持久化；都没有则生成并落库
    var did = deviceIdOverride;
    if (did == null || did.isEmpty) {
      did = await db.getMeta(CliConfigKeys.deviceId);
    }
    if (did == null || did.isEmpty) {
      did = 'cli-${SafeNote.generateUuid().substring(0, 8)}';
      await db.setMeta(CliConfigKeys.deviceId, did);
    }

    return CliContext._(dataDir: dataDir, database: db, deviceId: did);
  }

  // ──────────────────────────────────────────────
  // 密钥管理
  // ──────────────────────────────────────────────

  /// 是否已初始化 keyring（无需解锁，读包裹态账本）
  Future<bool> isKeyringInitialized() => Keyring.isInitialized(database);

  /// 首次设置密码：Keyring.createNew → 注入 dataKey → 装配引擎。
  Future<Keyring> keyringInit(String password) async {
    if (await isKeyringInitialized()) {
      throw CliException('keyring 已初始化，请使用 keyring unlock 解锁');
    }
    final k = await Keyring.createNew(password: password, database: database);
    _adoptKeyring(k, password: password);
    return k;
  }

  /// 解锁本地 keyring：unlockLocal → 注入 dataKey → 装配引擎。
  ///
  /// 密码错误抛 WrongPasswordException（由调用方转为友好报错）。
  Future<Keyring> unlock(String password) async {
    final k = await Keyring.unlockLocal(password: password, database: database);
    _adoptKeyring(k, password: password);
    return k;
  }

  /// 校验密码是否正确（不改任何状态）。
  Future<void> verifyPassword(String password) async {
    final k = keyring;
    if (k != null) {
      await k.verifyPassword(password);
      return;
    }
    // 未解锁：直接尝试解锁派生（丢弃实例，不注入 dataKey / 不持久化）
    await Keyring.unlockLocal(password: password, database: database);
  }

  /// 修改密码：verify(旧) → changePassword(旧→新) → 重建引擎。
  ///
  /// dataKey 不变 → epoch 不变，无需重加密笔记（O(1)，对齐 App 5 步流程）。
  Future<Keyring> changePassword({
    required String oldPassword,
    required String newPassword,
  }) async {
    final k = keyring ?? await unlock(oldPassword);
    final updated = await k.changePassword(
      oldPassword: oldPassword,
      newPassword: newPassword,
      database: database,
    );
    _adoptKeyring(updated, password: newPassword);
    return updated;
  }

  /// 确保已解锁；未解锁则用 [password]（全局参数解析结果）尝试解锁。
  Future<void> ensureUnlocked([String? password]) async {
    if (keyring != null) return;
    final pw = password ?? this.password;
    if (pw == null || pw.isEmpty) {
      throw CliException(
        '需要密码解锁：--password / --password-file / 环境变量 SN_PASSWORD',
      );
    }
    await unlock(pw);
  }

  /// 取当前 keyring；未解锁抛错（需要密钥的命令统一走这里）。
  Keyring requireKeyring() {
    final k = keyring;
    if (k == null) throw CliException('请先解锁：keyring unlock <password>');
    return k;
  }

  void _adoptKeyring(Keyring k, {String? password}) {
    keyring = k;
    database.setDataKey(k.dataKey);
    if (password != null) this.password = password;
  }

  // ──────────────────────────────────────────────
  // 同步引擎装配
  // ──────────────────────────────────────────────

  /// 后端配置是否存在（无需解锁即可判断）。
  Future<bool> isBackendConfigured() async {
    final type = await database.getMeta(CliConfigKeys.backendType);
    return type != null && type != CliBackendType.none && type.isNotEmpty;
  }

  /// 保存后端非敏感配置（type / 路径 / URL / 用户名）到 meta 表。
  Future<void> saveBackendConfig({
    required String type,
    String? localFsPath,
    String? webdavUrl,
    String? webdavUsername,
    String? safeServerUrl,
  }) async {
    await database.setMeta(CliConfigKeys.backendType, type);
    if (localFsPath != null) {
      await database.setMeta(CliConfigKeys.localFsPath, localFsPath);
    }
    if (webdavUrl != null) {
      await database.setMeta(CliConfigKeys.webdavUrl, webdavUrl);
    }
    if (webdavUsername != null) {
      await database.setMeta(CliConfigKeys.webdavUsername, webdavUsername);
    }
    if (safeServerUrl != null) {
      await database.setMeta(CliConfigKeys.safeServerUrl, safeServerUrl);
    }
    // 配置变化后旧引擎失效，下次同步重新装配
    await reloadEngine();
  }

  /// 清除后端配置（--type none 时）。
  Future<void> clearBackendConfig() async {
    await database.setMeta(CliConfigKeys.backendType, CliBackendType.none);
    await reloadEngine();
  }

  /// 按 meta 配置构建后端实例（null = 未配置）。
  ///
  /// 凭据优先级：显式参数 > backend-credentials.json > 环境变量。
  Future<SyncBackend?> buildBackend({
    String? webdavPassword,
    String? safeServerToken,
  }) async {
    final type = await database.getMeta(CliConfigKeys.backendType);
    switch (type) {
      case CliBackendType.localFs:
        final path = await database.getMeta(CliConfigKeys.localFsPath);
        if (path == null || path.isEmpty) return null;
        return LocalFsBackend(rootPath: path);
      case CliBackendType.webdav:
        final url = await database.getMeta(CliConfigKeys.webdavUrl);
        final user = await database.getMeta(CliConfigKeys.webdavUsername);
        if (url == null || url.isEmpty || user == null || user.isEmpty) {
          return null;
        }
        return WebDavBackend(
          baseUrl: url,
          username: user,
          password:
              webdavPassword ??
              _readCredentials()['webdav_password'] ??
              Platform.environment['SN_WEBDAV_PASSWORD'] ??
              '',
        );
      case CliBackendType.safeServer:
        final url = await database.getMeta(CliConfigKeys.safeServerUrl);
        if (url == null || url.isEmpty) return null;
        return SafeServerBackend(
          baseUrl: url,
          token:
              safeServerToken ??
              _readCredentials()['safeserver_token'] ??
              Platform.environment['SN_SAFESERVER_TOKEN'] ??
              '',
        );
      default:
        return null;
    }
  }

  /// 读数据目录下 backend-credentials.json（可选，仅测试用途）。
  Map<String, String> _readCredentials() {
    try {
      final file = File(p.join(dataDir, 'backend-credentials.json'));
      if (!file.existsSync()) return {};
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map) return {};
      return {for (final e in raw.entries) '${e.key}': '${e.value}'};
    } on Object {
      return {};
    }
  }

  /// 写数据目录下 backend-credentials.json（--backend-password/--backend-token）。
  Future<void> writeCredentials({
    String? webdavPassword,
    String? safeServerToken,
  }) async {
    if (webdavPassword == null && safeServerToken == null) return;
    final merged = _readCredentials();
    if (webdavPassword != null) merged['webdav_password'] = webdavPassword;
    if (safeServerToken != null) merged['safeserver_token'] = safeServerToken;
    await File(
      p.join(dataDir, 'backend-credentials.json'),
    ).writeAsString(jsonEncode(merged), flush: true);
  }

  /// 关闭旧后端/journal/引擎（换后端配置时调用），之后按需重建。
  Future<void> reloadEngine() async {
    await backend?.close();
    backend = null;
    await journal?.close();
    journal = null;
    engine = null;
    if (keyring != null) await _rebuildEngine();
  }

  /// 装配 SyncEngine（对齐 App SyncService.initialize，但不依赖插件）。
  ///
  /// [passphraseProvider] 返回会话密码——场景 d（两设备独立建 vault 后互通）
  /// 需要它判别远端密码是否与本地一致；[onKeyringChanged] 在 dataKey 迁移后
  /// 回写引用（B2：防止上层持旧 keyring / 旧 dataKey）。
  Future<void> _rebuildEngine({
    String? webdavPassword,
    String? safeServerToken,
  }) async {
    final k = keyring;
    if (k == null) return;

    backend ??= await buildBackend(
      webdavPassword: webdavPassword,
      safeServerToken: safeServerToken,
    );
    final b = backend;
    if (b == null) return;

    journal ??= await Journal.open(
      baseDir: dataDir,
      vaultId: k.vaultId,
      deviceId: deviceId,
    );

    engine = SyncEngine(
      backend: b,
      database: database,
      keyring: k,
      deviceId: deviceId,
      journal: journal!,
      passphraseProvider: () => password,
      onKeyringChanged: (nk) {
        keyring = nk;
        // 迁移后同步注入新 dataKey，保证后续 CRUD 用新 key 解密
        database.setDataKey(nk.dataKey);
      },
    );
  }

  /// 手动同步：确保引擎装配 + 后端就绪（幂等 init，离线时可重试），然后跑。
  Future<SyncResult> sync({
    String? webdavPassword,
    String? safeServerToken,
  }) async {
    final eng = await _getEngine(
      webdavPassword: webdavPassword,
      safeServerToken: safeServerToken,
    );
    return eng.sync();
  }

  /// 修复远端数据（对齐 App 设置页「修复同步数据」）。
  Future<SyncResult> repairRemote({
    String? webdavPassword,
    String? safeServerToken,
  }) async {
    final eng = await _getEngine(
      webdavPassword: webdavPassword,
      safeServerToken: safeServerToken,
    );
    return eng.repairRemote();
  }

  Future<SyncEngine> _getEngine({
    String? webdavPassword,
    String? safeServerToken,
  }) async {
    await _rebuildEngine(
      webdavPassword: webdavPassword,
      safeServerToken: safeServerToken,
    );
    final eng = engine;
    if (eng == null) {
      throw CliException('未配置同步后端，请先运行 sync setup');
    }
    await backend?.init(); // 幂等；网络后端离线时下次同步重试
    return eng;
  }

  /// 关闭资源（进程退出前调用）：journal → backend → database。
  Future<void> close() async {
    await journal?.close();
    journal = null;
    await backend?.close();
    backend = null;
    engine = null;
    keyring = null;
    await database.close();
    await AppLogFile.close();
  }

  // ──────────────────────────────────────────────
  // 元数据 / 状态便捷访问
  // ──────────────────────────────────────────────

  /// 当前后端 providerKey（不构造实例，仅按配置计算）。
  Future<String?> backendProviderKey() async {
    final type = await database.getMeta(CliConfigKeys.backendType);
    switch (type) {
      case CliBackendType.localFs:
        final path = await database.getMeta(CliConfigKeys.localFsPath);
        if (path == null || path.isEmpty) return null;
        return SyncCrypto.hashString('localFs:$path').substring(0, 16);
      case CliBackendType.webdav:
        final url = await database.getMeta(CliConfigKeys.webdavUrl);
        if (url == null || url.isEmpty) return null;
        return SyncCrypto.hashString('webdav:$url').substring(0, 16);
      case CliBackendType.safeServer:
        final url = await database.getMeta(CliConfigKeys.safeServerUrl);
        if (url == null || url.isEmpty) return null;
        return SyncCrypto.hashString('safeServer:$url').substring(0, 16);
      default:
        return null;
    }
  }
}
