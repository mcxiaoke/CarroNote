/*
 * 同步后端抽象接口
 *
 * 设计要点：
 *   - 后端无关：SyncEngine 只依赖此接口，不知道底层是 WebDAV / LocalFS / SafeServer
 *   - 纯存储：后端无业务逻辑，只做 KV 存储和文件读写
 *   - 乐观锁：只在 PUT manifest 时用 ETag 做一次 CAS 检查
 *   - 内容寻址：blob 按 hash 命名，相同内容天然幂等去重
 *   - providerKey：每个后端实例的唯一标识（基于类型+配置），用于隔离 manifest version
 *
 * 不同后端类型的存储布局（实现细节，对 SyncEngine 透明）：
 *   localFs:  <rootPath>/manifest.json + <rootPath>/blobs/<hash>
 *   webdav:   <userUrl>/safenotes-vault/manifest.json + .../blobs/<hash>（自动附加子目录）
 *   safeServer: <serverUrl>/api/v2/manifest + <serverUrl>/api/v2/blob/<hash>
 */

// Dart 原生导入
import 'dart:typed_data';

/// 后端抽象接口
///
/// 所有方法都应支持并发调用（SyncEngine 可并行上传/下载多个 blob）。
/// 实现需保证 putBlob 幂等（相同 hash + 内容多次调用结果一致）。
abstract class SyncBackend {
  /// 后端显示名称（用于 UI 状态展示，如"本地文件夹"、"WebDAV"、"SafeServer"）
  String get displayName;

  /// 后端实例的唯一标识（用于隔离本地 manifest version 状态）
  ///
  /// 不同后端类型、不同 URL 的后端应有不同的 providerKey。
  /// 切换后端时 SyncEngine 会用此 key 查找对应的 manifest version，
  /// 实现"切到新后端走首次同步、切回原后端继续增量"。
  ///
  /// 实现建议：`SyncCrypto.hashString('${type}:${url}').substring(0, 16)`
  String get providerKey;

  /// 初始化后端资源
  ///
  /// 在首次同步前调用一次：
  /// - LocalFS：创建 vault 根目录和 blobs 子目录
  /// - WebDAV：MKCOL 创建远端目录，测试连通性
  /// - SafeServer：测试连通性（GET /api/v2/health）
  /// 已初始化时重复调用应是幂等的。
  Future<void> init();

  /// 探测后端是否在线可用（轻量级健康检查）
  ///
  /// 用于改密码等关键操作前确认服务器可达。
  /// 与 [init] 的区别：init 只在初始化时调用一次，ping 可随时调用。
  ///
  /// 返回 true 表示后端在线可用，false 表示不可用（网络故障、服务未启动等）。
  /// 不抛异常：所有错误都转为 false 返回，便于调用方直接判断。
  ///
  /// 实现应尽量轻量：
  /// - SafeServer：GET /api/v2/health（无认证，1 次 HTTP 请求）
  /// - WebDAV：OPTIONS 根目录或 PROPFIND 深度 0
  /// - LocalFS：检查根目录是否存在且可读写
  Future<bool> ping();

  /// 获取远端 manifest 密文和当前 ETag
  ///
  /// 返回值：
  /// - ciphertext：manifest 的密文二进制（已用 dataKey 加密）
  /// - etag：当前版本的标识符（用于后续 putManifest 的乐观锁）
  ///
  /// 首次同步（远端无 manifest）时返回：
  /// - ciphertext = Uint8List(0)（空）
  /// - etag = ''（空字符串）
  Future<({Uint8List ciphertext, String etag})> getManifest();

  /// 上传新 manifest，带 expectedEtag 做乐观锁（CAS）
  ///
  /// [ciphertext] 新 manifest 密文
  /// [expectedEtag] 期望的远端 ETag：
  ///   - 非空：远端当前 ETag 必须等于此值才能写入，否则抛 [ConflictException]
  ///   - 空字符串：表示首次上传（远端必须不存在 manifest），否则抛 [ConflictException]
  ///
  /// 成功返回新的 ETag（供下次乐观锁使用）。
  /// 远端 ETag 不匹配时抛 [ConflictException]，SyncEngine 应重试（最多 3 次）。
  Future<String> putManifest(Uint8List ciphertext, String expectedEtag);

  /// 下载 blob（加密信封二进制）
  ///
  /// [hash] blob 的 SHA-256 哈希（十六进制字符串）
  /// 不存在时返回 null（SyncEngine 据此判断需要上传）。
  Future<Uint8List?> getBlob(String hash);

  /// 上传 blob（幂等）
  ///
  /// [hash] blob 的 SHA-256 哈希（十六进制字符串）
  /// [data] 加密信封二进制
  /// 相同 hash 多次上传结果一致（覆盖写或忽略均可）。
  Future<void> putBlob(String hash, Uint8List data);

  /// 释放后端资源（如关闭 HTTP 连接）
  ///
  /// 通常在应用退出或切换后端时调用。可选实现。
  Future<void> close();
}

/// 乐观锁冲突异常
///
/// 触发场景：
/// - putManifest 时远端 ETag 与 expectedEtag 不一致（其他设备先 PUT 了）
/// - 首次上传时远端已存在 manifest
///
/// SyncEngine 收到此异常后应回到 Step 1（getManifest）重新比对并重试。
class ConflictException implements Exception {
  final String message;
  ConflictException([this.message = 'Manifest version conflict (ETag mismatch)']);

  @override
  String toString() => 'ConflictException: $message';
}

/// 后端不可用异常（网络错误、服务端 5xx、认证失败等）
///
/// SyncEngine 收到此异常后应中止本次同步，等待下次触发（不重试）。
class BackendUnavailableException implements Exception {
  final String message;
  BackendUnavailableException(this.message);

  @override
  String toString() => 'BackendUnavailableException: $message';
}

/// 后端未初始化异常
///
/// 在调用 init() 之前使用后端，或 init() 失败后继续使用。
class BackendNotInitializedException implements Exception {
  @override
  String toString() =>
      'BackendNotInitializedException: Call init() before using the backend';
}
