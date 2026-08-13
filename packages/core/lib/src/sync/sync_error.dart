/*
 * 同步子系统统一错误类型体系
 *
 * 设计目标：
 *   - 替代散落在 sync_engine.dart 的 `on Object` 兜底捕获，让错误类型信息
 *     在 catch 处可见，便于 debug。
 *   - 提供 sealed class 体系让 exhaustive switch 成为可能（Dart 3.0+）。
 *   - 与现有异常类型（ConflictException / BackendUnavailableException /
 *     WrongPasswordException 等）共存：底层异常类型不变，本体系主要面向
 *     "引擎层捕获后包装成可观测错误"的场景。
 *
 * 与 SyncAction 的关系：
 *   SyncAction.error 字段持有 SyncError，SyncAction.message 仍保留（向后兼容
 *   旧 UI），由 error.toDisplayString() 派生。
 *
 * 与 SyncLogging 的关系：
 *   引擎层 catch 到具体 SyncError 后通过 Log.sync 记录（带堆栈），
 *   同时塞入 SyncAction 供调试面板查看。
 */

// Dart 导入
// （本文件不直接使用 dart:typed_data，但保留以备未来扩展 keyFingerprint 字段）

/// 同步错误基类（sealed，强制子类穷举）
///
/// 所有子类共享 [operation] / [noteUuid] / [cause] 三个上下文字段，
/// 便于日志聚合和调试面板展示。
sealed class SyncError {
  /// 发生错误的操作名（如 'getManifest' / 'putBlob' / 'decryptEnvelope'）
  final String operation;

  /// 涉及的笔记 UUID（可空，如 manifest 解析失败时无具体笔记）
  final String? noteUuid;

  /// 原始异常/错误对象（可空，编程 bug 兜底时可能没有）
  final Object? cause;

  /// 原始堆栈（可空）
  final StackTrace? stackTrace;

  const SyncError({
    required this.operation,
    this.noteUuid,
    this.cause,
    this.stackTrace,
  });

  /// 错误分类简短标签（用于 UI 标签、日志 level 字段）
  String get label;

  /// 用户可读的错误描述（中文，含上下文）
  ///
  /// 用于 SyncAction.message 派生和调试面板展示。
  String toDisplayString();

  /// 机器可读的 JSON 表示（用于结构化日志/导出）
  Map<String, Object?> toJson() => {
    'type': runtimeType.toString(),
    'label': label,
    'operation': operation,
    if (noteUuid != null) 'noteUuid': noteUuid,
    if (cause != null) 'cause': cause.toString(),
  };

  @override
  String toString() =>
      '$runtimeType($label, op=$operation${noteUuid != null ? ', uuid=$noteUuid' : ''})';
}

/// 解密失败（GCM tag 校验失败 / AAD 不匹配 / dataKey 错误）
///
/// 替代 sync_engine.dart 行 1254 / 1295 / 1301 / 1513 / 1570 / 1619 等
/// `on Object` 兜底。
class DecryptionError extends SyncError {
  /// 涉及的 blob hash（可空，manifest 解密失败时无）
  final String? blobHash;

  /// 尝试的 dataKey 纪元（Layer 3 诊断用）
  final int? attemptedEpoch;

  const DecryptionError({
    required super.operation,
    super.noteUuid,
    this.blobHash,
    this.attemptedEpoch,
    super.cause,
    super.stackTrace,
  });

  @override
  String get label => '解密失败';

  @override
  String toDisplayString() {
    final parts = <String>['$label（$operation）'];
    if (noteUuid != null) parts.add('uuid=$noteUuid');
    if (blobHash != null) parts.add('hash=${blobHash!.substring(0, 8)}…');
    if (attemptedEpoch != null) parts.add('epoch=$attemptedEpoch');
    if (cause != null) parts.add('cause=${_truncateCause(cause!)}');
    return parts.join(' ');
  }

  @override
  Map<String, Object?> toJson() => {
    ...super.toJson(),
    if (blobHash != null) 'blobHash': blobHash,
    if (attemptedEpoch != null) 'attemptedEpoch': attemptedEpoch,
  };
}

/// manifest 解析/损坏错误
///
/// 替代 sync_engine.dart 行 217 的 `on FormatException`。
/// 区分"JSON 格式错误"和"header 长度字段错误"等子场景。
class ManifestCorruptError extends SyncError {
  /// 损坏的具体子类型（如 'json_parse' / 'header_length' / 'truncated'）
  final String subtype;

  const ManifestCorruptError({
    required super.operation,
    required this.subtype,
    super.cause,
    super.stackTrace,
  });

  @override
  String get label => 'manifest 损坏';

  @override
  String toDisplayString() {
    final parts = ['$label（$operation, $subtype）'];
    if (cause != null) parts.add('cause=${_truncateCause(cause!)}');
    return parts.join(' ');
  }

  @override
  Map<String, Object?> toJson() => {...super.toJson(), 'subtype': subtype};
}

/// blob 缺失（远端 404）
///
/// 区分"manifest 引用但 blob 不存在"（P0-4 自愈场景）和
/// "GC 删除了正在用的 blob"（不应发生）。
class BlobMissingError extends SyncError {
  final String blobHash;

  const BlobMissingError({
    required this.blobHash,
    super.noteUuid,
    super.operation = 'getBlob',
    super.cause,
    super.stackTrace,
  });

  @override
  String get label => 'blob 缺失';

  @override
  String toDisplayString() =>
      '$label（$operation, hash=${blobHash.substring(0, 8)}…'
      '${noteUuid != null ? ', uuid=$noteUuid' : ''}）';

  @override
  Map<String, Object?> toJson() => {...super.toJson(), 'blobHash': blobHash};
}

/// 网络错误（超时、连接失败、5xx）
///
/// 与 BackendUnavailableException 的关系：
///   BackendUnavailableException 是 backend 层抛出的异常类型（向后兼容），
///   NetworkError 是引擎层包装后的可观测错误（带 operation 上下文）。
///   引擎层 catch BackendUnavailableException 后可包装为 NetworkError 记录。
class NetworkError extends SyncError {
  /// HTTP 状态码（可空，纯网络故障无状态码）
  final int? statusCode;

  /// 是否可重试（网络抖动 vs 永久故障）
  final bool retryable;

  const NetworkError({
    required super.operation,
    this.statusCode,
    this.retryable = true,
    super.noteUuid,
    super.cause,
    super.stackTrace,
  });

  @override
  String get label => '网络错误';

  @override
  String toDisplayString() {
    final parts = ['$label（$operation'];
    if (statusCode != null) parts.add('HTTP $statusCode');
    parts.add(retryable ? '可重试' : '不可重试');
    parts.add(')');
    if (cause != null) parts.add('cause=${_truncateCause(cause!)}');
    return parts.join(' ');
  }

  @override
  Map<String, Object?> toJson() => {
    ...super.toJson(),
    if (statusCode != null) 'statusCode': statusCode,
    'retryable': retryable,
  };
}

/// 密钥不匹配（密码错误 / 旧密钥纪元 / MK 解不开远端包裹）
///
/// 与 WrongPasswordException 的关系：
///   WrongPasswordException 是 keyring 层抛出的异常类型，
///   KeyMismatchError 是引擎层包装后的可观测错误。
class KeyMismatchError extends SyncError {
  /// 本地 keyVersion
  final int? localKeyVersion;

  /// 远端 keyVersion
  final int? remoteKeyVersion;

  /// 本地 dataKeyEpoch
  final int? localEpoch;

  /// 远端 dataKeyEpoch
  final int? remoteEpoch;

  const KeyMismatchError({
    required super.operation,
    this.localKeyVersion,
    this.remoteKeyVersion,
    this.localEpoch,
    this.remoteEpoch,
    super.cause,
    super.stackTrace,
  });

  @override
  String get label => '密钥不匹配';

  @override
  String toDisplayString() {
    final parts = ['$label（$operation'];
    if (localKeyVersion != null && remoteKeyVersion != null) {
      parts.add('keyVersion: $localKeyVersion vs $remoteKeyVersion');
    }
    if (localEpoch != null && remoteEpoch != null) {
      parts.add('epoch: $localEpoch vs $remoteEpoch');
    }
    parts.add(')');
    return parts.join(' ');
  }

  @override
  Map<String, Object?> toJson() => {
    ...super.toJson(),
    if (localKeyVersion != null) 'localKeyVersion': localKeyVersion,
    if (remoteKeyVersion != null) 'remoteKeyVersion': remoteKeyVersion,
    if (localEpoch != null) 'localEpoch': localEpoch,
    if (remoteEpoch != null) 'remoteEpoch': remoteEpoch,
  };
}

/// 兜底错误类型（编程 bug、未预期的异常）
///
/// 仅用于"确实不知道会发生什么"的兜底场景，并且必须记录堆栈。
/// 引擎层捕获此类型时应考虑上报或终止本次同步（视场景）。
class UnexpectedError extends SyncError {
  const UnexpectedError({
    required super.operation,
    super.noteUuid,
    required super.cause,
    required super.stackTrace,
  });

  @override
  String get label => '未预期错误';

  @override
  String toDisplayString() =>
      '$label（$operation${noteUuid != null ? ', uuid=$noteUuid' : ''}）: '
      '${_truncateCause(cause!)}';
}

/// 辅助：截断过长的 cause 字符串（避免日志爆炸）
String _truncateCause(Object cause, {int maxLen = 200}) {
  final s = cause.toString();
  if (s.length <= maxLen) return s;
  return '${s.substring(0, maxLen)}…';
}

// ──────────────────────────────────────────────
// 异常类型（与 SyncError 配套，用于 throw/catch）
// ──────────────────────────────────────────────

/// 解密异常（GCM tag 验证失败 / AAD 不匹配）
///
/// 由 crypto.dart 的 `_aesGcmDecrypt` 在 pointycastle 抛 `InvalidTag` 时
/// 包装抛出。`InvalidTag` 继承自 `Error` 而非 `Exception`，导致上层只能用
/// `on Object` 兜底；包装为 `SyncDecryptionException`（实现 Exception）后，
/// 上层可用 `on SyncDecryptionException` 精确捕获。
class SyncDecryptionException implements Exception {
  final String message;

  /// 涉及的 AAD 标识（如 blob hash 或 'manifest-items'）
  final String? aadId;

  SyncDecryptionException(this.message, {this.aadId});

  @override
  String toString() =>
      'SyncDecryptionException: $message${aadId != null ? ' (aad=$aadId)' : ''}';
}

/// 把 pointycastle 的解密失败包装为 [SyncDecryptionException]
///
/// 供 crypto.dart 的 `_aesGcmDecrypt` 调用：
/// ```dart
/// try {
///   return cipher.process(ctAndTag);
/// } on InvalidTag catch (e) {
///   throw _wrapInvalidTag(e, aadId);
/// } on Object catch (e, st) {
///   throw SyncDecryptionException('AES-GCM 解密异常: $e', aadId: aadId);
/// }
/// ```
///
/// 注意：pointycastle 的 InvalidTag 继承自 Error，所以必须用 `on Object`
/// 在最底层捕获一次，包装为 Exception 后向上抛出，让上层能用 `on Exception`
/// 系列精确捕获。这是消除引擎层 `on Object` 兜底的关键。
SyncDecryptionException wrapDecryptionError(Object error, {String? aadId}) {
  // pointycastle 的 InvalidTag
  final typeName = error.runtimeType.toString();
  if (typeName == 'InvalidTag' || error.toString().contains('InvalidTag')) {
    return SyncDecryptionException('GCM 认证标签验证失败（密钥错误或数据被篡改）', aadId: aadId);
  }
  return SyncDecryptionException('AES-GCM 解密失败: $error', aadId: aadId);
}

// ──────────────────────────────────────────────
// v5 容器异常类型（manifest-reliability-design §5.5）
// ──────────────────────────────────────────────
//
// 设计目的：彻底区分「数据损坏」与「密钥不匹配」两类失败，消除以往"items GCM
// 解密失败一律按密钥问题处理"导致的「损坏被误判为 scenario-b 强制重登」回归
// （sync_engine.dart:458-471 / 438-445，详见设计文档 §3.2）。
//
// 异常分流契约（实施约束 §11.1，违反会引入回归）：
//   - ManifestAuthException     → 走 §7 统一恢复编排（re-GET → 验 pubHash 挑 bak → 重建）
//   - ManifestKeyMismatchException → 走 scenario-b 密钥/迁移流程（requiresRelogin）
// 任何 `on Object catch` 兜底层都必须先分流这两种异常，否则新异常被吞掉、问题被掩盖。

/// manifest 数据损坏异常（结构错误 / pubHash 校验失败）
///
/// 触发场景：
///   - magic / fileVer / schemaVersion 不匹配或非法
///   - headerLen 越界 / 文件截断
///   - pubHash（无密钥 SHA-256）校验失败 → 位翻转 / 截断 / 半写
///
/// 处理：走统一恢复编排（§7），**绝不**走 scenario-b 强制重登。
class ManifestAuthException implements Exception {
  final String message;

  /// 原始异常（可空，pubHash 失败时无原始异常）
  final Object? cause;

  ManifestAuthException(this.message, {this.cause});

  @override
  String toString() =>
      'ManifestAuthException: $message${cause != null ? ' (cause: $cause)' : ''}';
}

/// manifest 密钥不匹配异常（pubHash 通过但 GCM 解密失败）
///
/// 触发场景：
///   - pubHash 校验通过（数据未损坏）但 items GCM tag 验证失败
///   - 含义：数据完整，但当前 dataKey 解不开 → 旧密钥数据 / 他端改密码 / 迁移后旧 bak
///
/// 处理：走 scenario-b 密钥/迁移流程（与现有 `requiresRelogin` 分支语义一致）。
/// **例外**（§11.2）：bak 选择循环中遇到此异常应跳过当前 bak 试下一份，只有
/// 所有 bak 都解不开才意味着密钥真的不匹配。
class ManifestKeyMismatchException implements Exception {
  final String message;

  /// 原始异常（通常为 SyncDecryptionException）
  final Object? cause;

  ManifestKeyMismatchException(this.message, {this.cause});

  @override
  String toString() =>
      'ManifestKeyMismatchException: $message${cause != null ? ' (cause: $cause)' : ''}';
}
