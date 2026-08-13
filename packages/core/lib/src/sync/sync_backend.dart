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
import 'dart:io';
import 'dart:typed_data';

// Package 导入
import 'package:path/path.dart' as p;

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
  /// - LocalFS：创建 keyring 根目录和 blobs 子目录
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

  /// F1 修复：删除 blob（GC 用）
  ///
  /// 删除远端指定 hash 的 blob。用于垃圾回收：manifest PUT 成功后，
  /// listBlobs() - manifest 引用的 hash = 孤儿 blob，删除。
  ///
  /// 不存在时不应抛异常（幂等删除）。
  /// 默认空实现：后端不支持删除时 no-op，GC 退化为"只标记不清理"。
  Future<void> deleteBlob(String hash) async {}

  /// F1 修复：列出远端所有 blob 的 hash（GC 用）
  ///
  /// 用于垃圾回收：与 manifest 引用的 hash 比对，找出孤儿 blob。
  ///
  /// 返回空列表表示后端不支持枚举（如 SafeServer 未实现 list 端点），
  /// GC 将跳过孤儿清理（保守不删，避免误删）。
  ///
  /// 实现建议：
  ///   - LocalFS：列 blobs/ 目录下的文件名
  ///   - WebDAV：PROPFIND 深度 1 查询 blobs/ 目录
  ///   - SafeServer：GET /api/v2/blobs（若服务端支持）
  Future<List<String>> listBlobs() async => [];

  /// P1-2 修复：软删除 blob（移动到隔离区而非物理删除）
  ///
  /// 孤儿 blob GC 时调用：把 blob 移动到隔离区（保留一段时间可恢复/回放），
  /// 而非立即物理删除，避免"误删其他设备 blob / blob 静默损坏后才发现"的
  /// 不可逆损失。默认实现退化为 [deleteBlob]（硬删除），不支持隔离区的后端
  /// 子类可不覆盖。
  ///
  /// [hash] blob 的 SHA-256 哈希（十六进制字符串）
  Future<void> deleteBlobSoft(String hash) async {
    await deleteBlob(hash);
  }

  /// P1-2 修复：列出隔离区中的孤儿 blob hash
  ///
  /// 供 [purgeOrphans] 与测试/回放使用。返回隔离区 blob 的 hash 列表
  /// （不含时间戳、不含隔离区前缀）。默认返回空列表（后端不支持隔离区）。
  Future<List<String>> listOrphanBlobs() async => [];

  /// P1-2 修复：彻底删除隔离区中超过保留期的 blob
  ///
  /// [retention] 保留期（如 30 天）；早于 `now - retention` 的隔离区 blob 被物理删除。
  /// GC 成功后可调用本方法清理过期隔离项，实现"超期才真删"。
  /// 默认空实现（no-op）：不支持隔离区的后端隔离区本身为空，无需清理。
  Future<void> purgeOrphans(Duration retention) async {}

  /// P1-1 修复：manifest 代际备份（环形 N 份）
  ///
  /// 在每次 PUT manifest 覆盖远端之前调用，把"即将被覆盖的旧 manifest 密文"
  /// 快照到环形备份（最多保留 N 代）。当检测到远端 manifest 损坏/被清空时，
  /// 可从最近一代备份恢复，避免单点故障导致整库元数据丢失。
  ///
  /// [currentManifestBytes] 即将被覆盖的远端 manifest 密文（引擎传入，避免后端
  /// 再发一次网络 GET）。首次上传（无旧 manifest）时传 null，实现应 no-op。
  /// 默认空实现（no-op）：子类按需覆盖
  /// （LocalFS 落地到 keyring 的 `manifest-backup/` 子目录；WebDAV/SafeServer
  /// 落地到各自服务端的 `manifest-backup/` 子目录）。
  Future<void> backupManifest([Uint8List? currentManifestBytes]) async {}

  /// D2 修复：备份损坏的 manifest 文件
  ///
  /// 当 SyncEngine 解析远端 manifest 失败（FormatException / GCM tag 验证失败）
  /// 时调用，把损坏的密文备份到一边，然后用本地数据重建 manifest 上传。
  ///
  /// 实现建议：
  ///   - LocalFS：重命名为 manifest.json.corrupt-{timestamp}
  ///   - WebDAV / SafeServer：MOVE 或 DELETE（HTTP 服务器通常不支持重命名，
  ///     退化为 DELETE，记录日志即可）
  /// 默认空实现（no-op），子类按需覆盖。
  ///
  /// [ciphertext] 损坏的 manifest 密文（仅供备份，不解析）
  Future<void> backupCorruptManifest(Uint8List ciphertext) async {}

  // ──────────────────────────────────────────────
  // P1-1 READ 侧：manifest 代际备份（manifest-reliability-design §7.2 / §11.2）
  // ──────────────────────────────────────────────

  /// 列出远端可用的 manifest 备份文件名，**从新到旧**（最新优先）
  ///
  /// 返回服务端 `manifest-backup/` 子目录中的备份文件名（如 `manifest.bak-3`），
  /// 顺序从新到旧，供损坏恢复流程（§7.1 步骤 2）按槽位优先尝试。无备份或
  /// 后端不支持读侧时返回空列表（恢复退化为本地重建，行为与旧版一致）。
  ///
  /// 默认空实现（no-op）：子类按需覆盖（LocalFS/WebDAV/SafeServer 均已实现）。
  Future<List<String>> listManifestBackups() async => const [];

  /// 读取指定 manifest 备份的密文；不存在时返回 null
  ///
  /// [name] 必须来自 [listManifestBackups]（避免路径穿越）。返回未解析的原始
  /// 密文，由 SyncEngine 用当前 dataKey 验 pubHash（无 key）后解密。
  ///
  /// 默认空实现（no-op）：后端不支持读侧时返回 null，恢复流程跳过该份。
  Future<Uint8List?> readManifestBackup(String name) async => null;

  // ──────────────────────────────────────────────
  // P2 Journal 远端副本（设计 §3.3-4 / §3.6c）
  // ──────────────────────────────────────────────

  /// P2：写入 journal 远端副本对象（防单点故障的第二数据源）
  ///
  /// [name] 对象名（叶子名，如 `android-xxx-archive-1000.json`），
  ///        由 Journal 生成并按设备隔离，后端只需拼到自己的 `journal/` 目录下。
  /// [ciphertext] **已由 Journal 用 `AES-GCM(dataKey)` 整体加密的密文**——
  ///        后端不解析、不解密，远端永不落明文。
  ///
  /// 默认空实现（no-op）：后端不支持资源层时 journal 保持本地-only，
  /// 同步主流程不受影响。
  Future<void> putJournalObject(String name, Uint8List ciphertext) async {}

  /// P2：读取 journal 远端副本对象；不存在返回 null
  Future<Uint8List?> getJournalObject(String name) async => null;

  /// P2：列举远端 journal 副本对象名（含所有设备的副本）
  ///
  /// 返回空列表表示后端不支持枚举，恢复流程将跳过"远端第二数据源"。
  Future<List<String>> listJournalObjects() async => [];

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
  ConflictException([
    this.message = 'Manifest version conflict (ETag mismatch)',
  ]);

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

/// manifest 代际备份环形份数（三个后端保持一致）
const int kManifestBackupRingCount = 5;

/// 远端 manifest / journal 密文的读取大小上限（F-M04）
///
/// 防止恶意/损坏的服务端返回超大响应体打爆客户端内存。manifest 是全市笔记
/// 元数据，正常远小于该值（万条笔记约几 MB）；journal 单文件受滚动阈值
/// （100KB×3 份）约束。超限时视为「远端数据不合法」，抛异常中止本次读取。
const int kRemoteManifestMaxBytes = 64 * 1024 * 1024; // 64 MB
const int kRemoteJournalMaxBytes = 64 * 1024 * 1024; // 64 MB

/// F-M04：校验远端响应体大小，超限抛 [BackendUnavailableException]
void checkRemoteReadSize(Uint8List bytes, String what, int maxBytes) {
  if (bytes.length > maxBytes) {
    throw BackendUnavailableException(
      '$what 响应体过大（${bytes.length} bytes > $maxBytes），'
      '已中止读取，请检查远端数据',
    );
  }
}

/// P1-1 通用环形备份写入
///
/// 把 [bytes] 写入 [dir] 下的环形备份文件 `manifest.bak-0` ..
/// `manifest.bak-{count - 1}`，轮转位置记录在 [dir]/.manifest-bak-index 中。
/// 多个后端共用此函数，保证"环形 N 份"语义一致（LocalFS 传入 keyring 的
/// `manifest-backup/` 子目录；WebDAV/SafeServer 传入各自服务端的 `manifest-backup/`
/// 子目录，旧版 SafeServer 兜底时传入客户端临时目录）。备份失败由调用方
/// try-catch，不抛异常。
///
/// 原子写（manifest-reliability-design §9）：先写同目录临时文件再 rename，
/// 避免"备份本身是半写坏文件"——半写备份是恢复路径的隐患（5 份 bak 可能全是坏的，
/// 回退等于盲试）。与 putManifest / putBlob 的 tmp+rename 模式一致
/// （local_fs_backend.dart:116-123 / 156-164）。rename 在同一文件系统内原子
/// （POSIX / Windows NTFS 均保证）。
Future<String> writeRingBackup(
  Directory dir,
  Uint8List bytes, {
  int count = 5,
}) async {
  await dir.create(recursive: true);
  final indexFile = File(p.join(dir.path, '.manifest-bak-index'));
  var slot = 0;
  try {
    if (await indexFile.exists()) {
      slot = int.tryParse(await indexFile.readAsString()) ?? 0;
    }
  } on Exception {
    slot = 0;
  }
  slot = (slot + 1) % count;
  try {
    await indexFile.writeAsString(slot.toString());
  } on Exception {
    // 索引写入失败不阻断备份
  }
  final path = p.join(dir.path, 'manifest.bak-$slot');
  // 原子写：tmp + rename。tmp 文件名带微秒时间戳，避免极端场景下的并发碰撞。
  final tmpPath = '$path.tmp-${DateTime.now().microsecondsSinceEpoch}';
  final tmpFile = File(tmpPath);
  try {
    await tmpFile.writeAsBytes(bytes, flush: true);
    await tmpFile.rename(path);
  } on Exception {
    // rename 失败时清理 tmp 残留，避免堆积；目标文件保持旧内容（要么旧完整、要么空）。
    try {
      if (await tmpFile.exists()) await tmpFile.delete();
    } on Exception {
      // 清理失败忽略，下次备份会覆盖同名 tmp
    }
    rethrow;
  }
  return path;
}
