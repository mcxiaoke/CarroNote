/*
 * 本地文件系统后端实现
 *
 * 用途：
 *   - 单机测试：无需部署 WebDAV 服务器即可验证 SyncEngine 流程
 *   - 离线沙箱：开发期隔离测试数据，不污染真实云盘
 *   - 跨平台：dart:io 在 Android/iOS/桌面端均可用（Web 平台不支持，本项目不涉及）
 *
 * 存储布局：
 *   <rootPath>/
 *   ├── manifest.json     # manifest 密文二进制
 *   └── blobs/
 *       ├── <hash-1>
 *       └── <hash-2>
 *
 * ETag 策略：
 *   使用文件内容的 SHA-256（强 ETag），与 WebDAV 语义一致。
 *   manifest 文件每次写入后 ETag 必然变化，保证乐观锁正确性。
 */

// Dart 原生导入
import 'dart:io';
import 'dart:typed_data';

// Package 导入
import 'package:crypto/crypto.dart' show sha256;
import 'package:path/path.dart' as p;

// Project 导入
import 'package:core/src/crypto/crypto.dart';
import 'package:core/src/sync/sync_backend.dart';
import 'package:core/src/logger/app_logger.dart';

/// 本地文件系统后端
///
/// [rootPath] 必须是绝对路径，由上层（SyncService/Keyring）使用 path_provider
/// 解析后传入。LocalFsBackend 自身不依赖 path_provider，便于单元测试。
class LocalFsBackend implements SyncBackend {
  /// keyring 根目录绝对路径
  final String rootPath;

  bool _initialized = false;

  LocalFsBackend({required this.rootPath});

  @override
  String get displayName => '本地文件夹';

  /// providerKey：基于路径哈希，切换路径时 manifest version 自动隔离
  @override
  String get providerKey =>
      SyncCrypto.hashString('localFs:$rootPath').substring(0, 16);

  /// keyring 内 manifest 文件路径
  String get _manifestPath => p.join(rootPath, 'manifest.json');

  /// keyring 内 blobs 目录路径
  String get _blobsDirPath => p.join(rootPath, 'blobs');

  @override
  Future<void> init() async {
    // 创建根目录和 blobs 子目录（recursive: true 幂等，已存在不报错）
    final rootDir = Directory(rootPath);
    await rootDir.create(recursive: true);
    await Directory(_blobsDirPath).create(recursive: true);
    _initialized = true;
  }

  /// 检查已初始化，否则抛异常
  void _ensureInitialized() {
    if (!_initialized) {
      throw BackendNotInitializedException();
    }
  }

  @override
  Future<({Uint8List ciphertext, String etag})> getManifest() async {
    _ensureInitialized();
    final file = File(_manifestPath);
    if (!await file.exists()) {
      // 首次同步：远端无 manifest
      return (ciphertext: Uint8List(0), etag: '');
    }
    final bytes = await file.readAsBytes();
    return (ciphertext: bytes, etag: _computeEtag(bytes));
  }

  @override
  Future<String> putManifest(
    Uint8List ciphertext,
    String expectedEtag,
  ) async {
    _ensureInitialized();
    final file = File(_manifestPath);

    if (expectedEtag.isEmpty) {
      // 首次上传：远端必须不存在 manifest
      if (await file.exists()) {
        throw ConflictException(
            'LocalFs: manifest already exists (first upload expected empty remote)');
      }
    } else {
      // 乐观锁：远端 ETag 必须匹配
      if (!await file.exists()) {
        throw ConflictException(
            'LocalFs: manifest missing on remote (expected etag=$expectedEtag)');
      }
      final currentBytes = await file.readAsBytes();
      final currentEtag = _computeEtag(currentBytes);
      if (currentEtag != expectedEtag) {
        throw ConflictException(
            'LocalFs: etag mismatch (expected=$expectedEtag, actual=$currentEtag)');
      }
    }

    // D5 修复：原子写——先写 .tmp 文件，再 rename 为正式文件。
    // 避免写入过程中崩溃导致 manifest 损坏（半写状态）。
    // rename 在同一文件系统内是原子的（POSIX / Windows NTFS 均保证）。
    final tmpPath = '$_manifestPath.tmp';
    final tmpFile = File(tmpPath);
    await tmpFile.writeAsBytes(ciphertext, flush: true);
    await tmpFile.rename(_manifestPath);
    return _computeEtag(ciphertext);
  }

  @override
  Future<void> backupCorruptManifest(Uint8List ciphertext) async {
    // D2 修复：把损坏的 manifest 备份为 .corrupt-{timestamp} 文件
    // 不删除原文件，由调用方（SyncEngine）用本地数据重建后覆盖。
    try {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final corruptPath = '$_manifestPath.corrupt-$ts';
      final file = File(_manifestPath);
      if (await file.exists()) {
        await file.rename(corruptPath);
      }
    } on Exception {
      // 备份失败不阻断重建流程
    }
  }

  @override
  Future<Uint8List?> getBlob(String hash) async {
    _ensureInitialized();
    final file = File(p.join(_blobsDirPath, hash));
    if (!await file.exists()) return null;
    return await file.readAsBytes();
  }

  @override
  Future<void> putBlob(String hash, Uint8List data) async {
    _ensureInitialized();
    final file = File(p.join(_blobsDirPath, hash));
    // 幂等：相同内容覆盖写，结果一致
    //
    // B5 修复（epoch 消除 P0 五项）：tmp + 原子 rename 写入，堵半写脏 blob。
    // 直接 writeAsBytes 若中途崩溃（断电/杀进程）会在 blobs/ 留下截断文件，
    // 后续下载该 hash 时解密成功但内容 hash 不匹配 → 永久 corrupt。
    // 先写同目录临时文件再 rename（同文件系统内原子），保证目标文件
    // 要么是旧完整内容、要么是新完整内容，绝不出现半写。
    final tmp = File(
        '${file.path}.tmp-${DateTime.now().microsecondsSinceEpoch}');
    await tmp.writeAsBytes(data, flush: true);
    await tmp.rename(file.path);
  }

  /// F1 修复：删除 blob（GC 用）
  ///
  /// 幂等：文件不存在时不抛异常。
  @override
  Future<void> deleteBlob(String hash) async {
    _ensureInitialized();
    final file = File(p.join(_blobsDirPath, hash));
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// F1 修复：列出所有 blob 的 hash（GC 用）
  ///
  /// 扫描 blobs/ 目录下的文件名。.tmp / .corrupt 等非 hash 文件会被过滤。
  @override
  Future<List<String>> listBlobs() async {
    _ensureInitialized();
    final dir = Directory(_blobsDirPath);
    if (!await dir.exists()) return [];
    final result = <String>[];
    // blob 文件名是 SHA-256 十六进制（64 字符），过滤非 hash 文件
    final hashRegex = RegExp(r'^[a-f0-9]{64}$');
    await for (final entity in dir.list()) {
      if (entity is File) {
        final name = p.basename(entity.path);
        if (hashRegex.hasMatch(name)) {
          result.add(name);
        }
      }
    }
    return result;
  }

  /// P1-2 修复：软删除 blob（移动到 blobs-orphan/ 隔离区）
  ///
  /// 孤儿 blob GC 时调用：rename 到隔离区（文件名附时间戳 `hash.<epochMs>`），
  /// 保留一段时间后可恢复或彻底删除，避免立即物理删除的不可逆损失。
  @override
  Future<void> deleteBlobSoft(String hash) async {
    _ensureInitialized();
    final src = File(p.join(_blobsDirPath, hash));
    if (!await src.exists()) return; // 已不存在，幂等
    final orphanDir = Directory(p.join(rootPath, 'blobs-orphan'));
    await orphanDir.create(recursive: true);
    final ts = DateTime.now().millisecondsSinceEpoch;
    final dst = File(p.join(orphanDir.path, '$hash.$ts'));
    try {
      await src.rename(dst.path);
    } on Exception catch (e) {
      // 重命名失败（跨文件系统）：退化为硬删除
      Log.sync.w('LocalFs deleteBlobSoft: 重命名失败，退化为硬删除 '
          'hash=${hash.substring(0, 8)}…', error: e);
      try {
        await src.delete();
      } on Exception catch (e2) {
        Log.sync.w('LocalFs deleteBlobSoft: 硬删除也失败 '
            'hash=${hash.substring(0, 8)}…', error: e2);
      }
    }
  }

  /// P1-2 修复：列出隔离区孤儿 blob 的 hash
  @override
  Future<List<String>> listOrphanBlobs() async {
    _ensureInitialized();
    final dir = Directory(p.join(rootPath, 'blobs-orphan'));
    if (!await dir.exists()) return [];
    final result = <String>[];
    await for (final entity in dir.list()) {
      if (entity is File) {
        final name = p.basename(entity.path);
        final dot = name.indexOf('.');
        if (dot > 0) result.add(name.substring(0, dot));
      }
    }
    return result;
  }

  /// P1-2 修复：清理隔离区中超过保留期的 blob
  @override
  Future<void> purgeOrphans(Duration retention) async {
    _ensureInitialized();
    final dir = Directory(p.join(rootPath, 'blobs-orphan'));
    if (!await dir.exists()) return;
    final cutoff = DateTime.now().subtract(retention).millisecondsSinceEpoch;
    await for (final entity in dir.list()) {
      if (entity is File) {
        final name = p.basename(entity.path);
        final dot = name.indexOf('.');
        if (dot > 0) {
          final ts = int.tryParse(name.substring(dot + 1));
          if (ts != null && ts < cutoff) {
            try {
              await entity.delete();
            } on Exception {
              // 单个删除失败不阻断整体清理
            }
          }
        }
      }
    }
  }

  /// P1-1 修复：manifest 代际备份（落地到 keyring 的 `manifest-backup/` 子目录环形备份）
  ///
  /// 把即将被覆盖的旧 manifest 密文写入 keyring 下 `manifest-backup/` 子目录的环形备份
  /// `manifest.bak-0`..`manifest.bak-4`（最多保留 5 代），与 webdav/safeServer 后端
  /// 布局一致（均落在各自"服务端"的 `manifest-backup/` 子目录）。
  @override
  Future<void> backupManifest([Uint8List? currentManifestBytes]) async {
    if (currentManifestBytes == null || currentManifestBytes.isEmpty) return;
    _ensureInitialized();
    try {
      await writeRingBackup(
        Directory(p.join(rootPath, 'manifest-backup')),
        currentManifestBytes,
      );
    } on Exception {
      // 备份失败不阻断同步
    }
  }

  /// P1-1 READ 侧：列出 `manifest-backup/` 环形备份，从新到旧
  ///
  /// 与 `writeRingBackup` 的写入布局对应：`.manifest-bak-index` 记录最近写入的
  /// 槽位，从该槽降序（mod N）即「从新到旧」。缺失槽位跳过，只返回存在的名字。
  @override
  Future<List<String>> listManifestBackups() async {
    _ensureInitialized();
    final dir = Directory(p.join(rootPath, 'manifest-backup'));
    if (!await dir.exists()) return const [];
    // 读取最近写入槽位（读取失败按 0 处理，仅影响顺序不影响正确性）
    var newestSlot = 0;
    final indexFile = File(p.join(dir.path, '.manifest-bak-index'));
    try {
      if (await indexFile.exists()) {
        newestSlot = int.tryParse(await indexFile.readAsString()) ?? 0;
      }
    } on Exception {
      newestSlot = 0;
    }
    final result = <String>[];
    // 环形 N 份：从 newestSlot 开始按 -1 步长回退，形成从新到旧顺序
    for (var i = 0; i < kManifestBackupRingCount; i++) {
      final slot = (newestSlot - i + kManifestBackupRingCount) %
          kManifestBackupRingCount;
      final file = File(p.join(dir.path, 'manifest.bak-$slot'));
      if (await file.exists()) result.add('manifest.bak-$slot');
    }
    return result;
  }

  /// P1-1 READ 侧：读取指定 manifest 备份密文；不存在返回 null
  @override
  Future<Uint8List?> readManifestBackup(String name) async {
    _ensureInitialized();
    // 仅接受 listManifestBackups 产出的合法名字，防路径穿越
    final m = RegExp(r'^manifest\.bak-\d+$').firstMatch(name);
    if (m == null) return null;
    final file = File(p.join(rootPath, 'manifest-backup', name));
    if (!await file.exists()) return null;
    return await file.readAsBytes();
  }

  // ──────────────────────────────────────────────
  // P2 Journal 远端副本（落在 keyring 根目录的 `journal/` 子目录）
  // ──────────────────────────────────────────────

  String get _journalDirPath => p.join(rootPath, 'journal');

  /// P2：写入 journal 密文副本（内容已由 Journal 加密，这里只是落盘）
  @override
  Future<void> putJournalObject(String name, Uint8List ciphertext) async {
    _ensureInitialized();
    final dir = Directory(_journalDirPath);
    await dir.create(recursive: true);
    // 原子写：先 .tmp 再 rename，避免半写副本被当作有效数据
    final target = p.join(dir.path, name);
    final tmp = File('$target.tmp');
    await tmp.writeAsBytes(ciphertext, flush: true);
    await tmp.rename(target);
  }

  @override
  Future<Uint8List?> getJournalObject(String name) async {
    _ensureInitialized();
    final file = File(p.join(_journalDirPath, name));
    if (!await file.exists()) return null;
    return await file.readAsBytes();
  }

  @override
  Future<List<String>> listJournalObjects() async {
    _ensureInitialized();
    final dir = Directory(_journalDirPath);
    if (!await dir.exists()) return [];
    final result = <String>[];
    await for (final entity in dir.list()) {
      if (entity is File) {
        final name = p.basename(entity.path);
        // 过滤中间态 .tmp 文件
        if (name.endsWith('.json')) result.add(name);
      }
    }
    return result;
  }

  @override
  Future<void> close() async {
    // LocalFS 无需释放资源（文件句柄在每次操作后自动关闭）
    _initialized = false;
  }

  @override
  Future<bool> ping() async {
    // LocalFS 探测：根目录存在且可读写即视为可用
    // 不依赖 _initialized 标志，允许未 init 时也能探测
    try {
      final rootDir = Directory(rootPath);
      if (!await rootDir.exists()) return false;
      // 写入探测文件验证可写（避免只读挂载等情况）
      final probeFile = File(p.join(rootPath, '.ping'));
      await probeFile.writeAsString('ping', flush: true);
      await probeFile.delete();
      return true;
    } on Exception {
      return false;
    }
  }

  /// 计算文件内容的 SHA-256 作为强 ETag
  ///
  /// 返回十六进制字符串（无引号，与 WebDAV 规范的引号形式不同，
  /// 但 LocalFsBackend 内部使用，对比时保持一致即可）。
  String _computeEtag(Uint8List bytes) {
    return sha256.convert(bytes).toString();
  }
}
