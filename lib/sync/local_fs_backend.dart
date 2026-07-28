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
import 'package:safenotes/sync/crypto.dart';
import 'package:safenotes/sync/sync_backend.dart';

/// 本地文件系统后端
///
/// [rootPath] 必须是绝对路径，由上层（SyncService/Vault）使用 path_provider
/// 解析后传入。LocalFsBackend 自身不依赖 path_provider，便于单元测试。
class LocalFsBackend implements SyncBackend {
  /// vault 根目录绝对路径
  final String rootPath;

  bool _initialized = false;

  LocalFsBackend({required this.rootPath});

  @override
  String get displayName => '本地文件夹';

  /// providerKey：基于路径哈希，切换路径时 manifest version 自动隔离
  @override
  String get providerKey =>
      SyncCrypto.hashString('localFs:$rootPath').substring(0, 16);

  /// vault 内 manifest 文件路径
  String get _manifestPath => p.join(rootPath, 'manifest.json');

  /// vault 内 blobs 目录路径
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

    // 写入新 manifest（flush: true 立即落盘，避免崩溃导致半写）
    await file.writeAsBytes(ciphertext, flush: true);
    return _computeEtag(ciphertext);
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
    await file.writeAsBytes(data, flush: true);
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
