/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

/*
 * 同步引擎核心
 *
 * 实现 5 步同步流程（参考 simplified-sync-design.md §6.1）：
 *   Step 1  GET /manifest → 仅解析 header（明文）
 *           → 检查是否需要 dataKey 迁移（本地 encryptedDataKey vs 远端）
 *           → 若需要迁移：用 MK 解开远端 encryptedDataKey → reEncryptAllNotes
 *           → 用 dataKey 解析完整 manifest（header + items）
 *   Step 2  构建本地 manifest（从数据库读取所有笔记元数据）
 *   Step 3  逐条比对：仅本地有→上传，仅远端有→下载，双方有→LWW
 *   Step 4  加密合并后的 manifest → PUT /manifest（带 ETag 乐观锁）
 *   Step 5  更新本地状态（manifest version + 标记 synced）
 *
 * dataKey 迁移流程（新设备加入已存在的同步组）：
 *   1. GET 远端 manifest → deserializeHeaderOnly 拿到 remote.encryptedDataKey
 *   2. keyring.checkMigrationNeeded(remote.encryptedDataKey)
 *      - 不需要迁移（本地与远端一致）→ 继续正常同步
 *      - 需要迁移 → keyring.migrateToRemote(...) 重新加密所有本地笔记
 *      - 失败（MK 不匹配）→ 抛 WrongPasswordException
 *   3. 迁移成功后，用新 dataKey 重建 SyncEngine 并重新同步
 *
 * 乐观锁重试：
 *   PUT manifest 时如果 ETag 不匹配（其他设备先 PUT 了），抛 ConflictException。
 *   SyncEngine 回到 Step 1 重新拉取并重试，最多 3 次。
 *
 * LWW 冲突解决（参考 §6.2）：
 *   remote.updatedAt > local.updatedAt → 远端胜（下载覆盖本地）
 *   remote.updatedAt < local.updatedAt → 本地胜（上传覆盖远端）
 *   相等但 hash 不同 → 保留 hash 字典序小的（兜底，极少触发）
 *
 * 依赖关系：
 *   - SyncBackend：远端存储（LocalFS / WebDAV / SafeServer）
 *   - NotesDatabase：本地 SQLite
 *   - Keyring：密钥管理（dataKey + MK 缓存 + 迁移能力）
 *   - Journal：操作日志（P2，审计 + 可恢复；记录点见 §3.5）
 *   - DeviceIdProvider：manifest header.lastModifiedBy
 */

// Dart 原生导入
import 'dart:convert';
import 'dart:typed_data';

// Project 导入
import 'package:core/src/db/database_handler.dart';
import 'package:core/src/models/note_meta.dart';
import 'package:core/src/models/safenote.dart';
import 'package:core/src/crypto/crypto.dart';
import 'package:core/src/sync/journal.dart';
import 'package:core/src/sync/note_meta_sync.dart';
import 'package:core/src/sync/sync_backend.dart';
import 'package:core/src/sync/sync_error.dart';
import 'package:core/src/logger/app_logger.dart';
import 'package:core/src/sync/sync_models.dart';
import 'package:core/src/sync/keyring.dart';

/// 同步引擎
///
/// 状态：持有 keyring 引用（用于 dataKey 迁移）。
/// 线程安全：SyncService 通过互斥锁保证同一时间只有一个 sync() 在执行。
class SyncEngine {
  /// 安全截断字符串用于日志显示（防止测试中短 hash 越界）
  static String _short(String? s, [int len = 8]) {
    if (s == null || s.isEmpty) return 'null';
    return s.length > len ? '${s.substring(0, len)}…' : s;
  }

  /// 远端后端
  final SyncBackend backend;

  /// 本地数据库
  final NotesDatabase database;

  /// Keyring 引用（用于 dataKey 迁移检查）
  ///
  /// sync() 期间可能因迁移而更新 keyring.dataKey 和 keyring.encryptedDataKey，
  /// 因此不能缓存 dataKey 副本，需每次通过 keyring.dataKey 获取。
  /// 非 final：_executeMigration 后会用 migrateToRemote 返回的新 Keyring 替换。
  Keyring keyring;

  /// 设备 ID（写入 manifest header.lastModifiedBy）
  final String deviceId;

  /// 用户密码提供者（场景 d 判别用）
  ///
  /// 场景 d：两设备独立 createNew → 不同 salt → 本地 MK 解不开远端
  /// encryptedDataKey。此时需要用远端 salt + 用户密码重新派生 MK 来验证
  /// 密码是否相同（比对 keyFingerprint）。
  ///
  /// 生产环境由 SyncService 注入 `() => PhraseHandler.getPass`；
  /// 测试时可直接传入密码字符串；
  /// 为 null 时退回原逻辑（直接报 dataKey 迁移失败）。
  final String? Function()? passphraseProvider;

  /// 最大重试次数（乐观锁冲突时）
  static const int maxRetries = 3;

  // 注：原冲突副本保留阈值 kConflictPreserveThresholdMs（updatedAt 差值 5 分钟）
  // 已废弃并移除。判据改为「共同祖先 base hash」——时间差衡量内容新旧，无法
  // 区分「单边更新」与「真并发冲突」，是删除复活 / 副本增殖 / 并发丢数据的根因。
  // 现判据见 _mergeManifests 冲突分支的 localChanged/remoteChanged。

  /// F1 修复：墓碑 GC 阈值（30 天，单位毫秒）
  ///
  /// 软删除超过此阈值的墓碑将从 manifest 移除并硬删除本地数据库记录，
  /// 防止墓碑无限累积。30 天保证离线设备重新上线后能同步到删除操作。
  static const int kTombstoneGcThresholdMs = 30 * 24 * 60 * 60 * 1000;

  /// P1-2 修复：隔离区 blob 保留期（30 天）
  ///
  /// 软删除（[SyncBackend.deleteBlobSoft]）到隔离区的孤儿 blob 超过此期限后，
  /// 才由 [_gcOrphanBlobs] 调用 [SyncBackend.purgeOrphans] 彻底删除。
  /// "超期才真删"给误删 / blob 静默损坏留出恢复窗口，避免不可逆数据损失。
  ///
  /// 默认 30 天；测试可经构造函数 [SyncEngine.orphanRetention] 注入更短保留期，
  /// 在压缩时间内驱动「隔离 → 超期 → purge」完整链路（longrun I9 不变量依赖它，
  /// 否则测试时间尺度下隔离项永不超期，purge 路径成为盲区）。
  static const Duration _orphanRetention = Duration(days: 30);

  /// 本实例生效的隔离区保留期（默认 [_orphanRetention]，测试可注入缩短）
  final Duration _orphanRetentionEffective;

  /// P2：操作日志（设计 §3.5，本阶段必填不可为空）
  ///
  /// 为什么必填而非可空：可空会让每个记录点都要写 `journal?.append(...)`，
  /// 漏写不报错、覆盖率无法保证。测试可传 [Journal.inMemory]（零 I/O），
  /// 生产由 SyncService 用 [Journal.open] 构造。
  final Journal journal;

  /// B2 修复（epoch 消除 P0 五项）：迁移成功后新 keyring 的回调出口。
  ///
  /// dataKey 迁移（scenario-d / 场景 d）会让 SyncEngine 内部的 keyring 引用
  /// 被替换为 migrateToRemote/migrateToRemoteVault 返回的**新实例**，但持有
  /// 同一 Keyring 引用的上层（SyncService._keyring）不会自动同步——若不回写，
  /// 后续「改密码 / 重新登录 / 再次迁移」会用旧 keyring（旧 dataKey 已失效）
  /// 导致全库不可解（B2 生产事故）。
  ///
  /// 由 SyncService 注入 `(k) => _keyring = k`；测试可不传。
  final void Function(Keyring keyring)? onKeyringChanged;

  SyncEngine({
    required this.backend,
    required this.database,
    required this.keyring,
    required this.deviceId,
    required this.journal,
    this.passphraseProvider,
    this.onKeyringChanged,
    Duration orphanRetention = _orphanRetention,
  }) : _orphanRetentionEffective = orphanRetention;

  /// 当前密钥状态快照（写入 key.* journal 条目）
  JournalKeyState get _keyStateSnapshot => JournalKeyState(
    keyVersion: keyring.keyVersion,
    dataKeyEpoch: keyring.dataKeyEpoch,
    keyFingerprint: keyring.keyFingerprint,
    encryptedDataKey: keyring.encryptedDataKey,
  );

  /// 当前 dataKey（便捷访问器，每次从 keyring 获取最新值）
  ///
  /// P2 收敛后 encryptedDataKey / vaultId 不再由 SyncEngine 直接拼装 header，
  /// 统一走 [Keyring.toManifestHeader]，故此处只保留加解密所需的 dataKey。
  Uint8List get _dataKey => keyring.dataKey;

  /// 把本地 journal 的加密副本推送到远端（设计 §3.3-4 / §3.6c）。
  ///
  /// 契约：**永不抛异常、永不阻断同步**。journal 是可观测/可恢复的辅助设施，
  /// 它自己坏掉不能反过来把用户的正常同步搞挂——这是 §3.6b 的硬约束。
  /// 内存降级模式下 [Journal.syncToRemote] 自身即为 no-op。
  Future<void> _uploadJournal() async {
    try {
      await journal.syncToRemote(backend, _dataKey);
    } catch (e, st) {
      Log.sync.w('journal 远端副本上传失败（不影响同步结果）', error: e, stackTrace: st);
    }
  }

  // ──────────────────────────────────────────────
  // 笔记元数据同步（items.meta + per-note LWW，docs/note-meta-sync-plan.md）
  // ──────────────────────────────────────────────

  /// 笔记元数据同步段（items.meta），由 [sync] 在主链路成功后调用一次。
  ///
  /// 契约（对齐 [_uploadJournal]）：**永不抛异常、永不阻断同步主链路**。
  /// 元数据是次要数据，meta 段失败只记日志与 journal 留痕，下次同步重试。
  ///
  /// 流程（Q1a/Q3a 定案见 docs/note-meta-sync-plan.md §5）：
  ///   1. GET items.meta → 解密 → 解析：
  ///      - 后端不支持（supportsMetaObjects=false）→ 整段跳过；
  ///      - 解密失败（dataKey 迁移残留 / 文件损坏）→ 自愈：忽略远端内容，
  ///        journal 留痕，下方用本地全量覆盖上传（能走到这里说明 manifest
  ///        主链路刚成功、本端 dataKey 与远端一致，故覆盖恒正确）；
  ///      - wire 版本高于本端 → 整体跳过本轮（不下也不上，防降级覆盖）。
  ///   2. per-note LWW 合并入本地（远端胜出才写；synced=1 表「刚与远端
  ///      对齐」，不产生新脏数据）。
  ///   3. 本地有 synced=0 脏行或处于自愈场景 → 序列化全量（含待上报墓碑）
  ///      → 上传 → 条件置 synced → 墓碑 GC；无脏行且非自愈不上传空文件。
  Future<void> _syncNoteMeta() async {
    if (!backend.supportsMetaObjects) return;
    var forceUpload = false; // 自愈场景：即使无脏行也上传（覆盖坏文件）
    try {
      // ── 1. 下载与解析 ──
      Map<String, NoteMeta>? remote;
      var skipRound = false;
      final ciphertext = await backend.getMetaObject();
      if (ciphertext != null && ciphertext.isNotEmpty) {
        Uint8List? plaintext;
        var failureNote = '';
        try {
          plaintext = await NoteMetaSyncCodec.open(_dataKey, ciphertext);
        } on SyncDecryptionException catch (e) {
          failureNote = 'decrypt failed (${ciphertext.length} bytes)';
          Log.sync.w('items.meta 解密失败，走自愈重建', error: e);
        }
        NoteMetaRemoteFile? parsed;
        if (plaintext != null) {
          parsed = NoteMetaSyncCodec.decode(plaintext);
          if (parsed == null) {
            failureNote = 'malformed wire json';
            Log.sync.w('items.meta 结构损坏，走自愈重建');
          } else if (parsed.version > kNoteMetaWireVersion) {
            Log.sync.w(
              'items.meta 为更新格式 (v${parsed.version})，跳过本轮 meta 同步'
              '（防降级覆盖，请升级客户端）',
            );
            skipRound = true;
          }
        }
        if (failureNote.isNotEmpty) {
          journal.append(
            type: JournalEventType.syncNoteMeta,
            phase: JournalPhase.failed,
            dataKeyEpoch: keyring.dataKeyEpoch,
            note: '$failureNote, self-heal by local snapshot',
          );
          forceUpload = true;
        } else if (!skipRound) {
          remote = parsed?.metas ?? const {};
        }
      }
      if (skipRound) {
        journal.append(
          type: JournalEventType.syncNoteMeta,
          phase: JournalPhase.done,
          dataKeyEpoch: keyring.dataKeyEpoch,
          note: 'future wire version, skipped',
        );
        return;
      }

      // ── 2. per-note LWW 合并 ──
      var applied = 0;
      if (remote != null && remote.isNotEmpty) {
        applied = await database.mergeRemoteNoteMetas(remote.values.toList());
      }

      // ── 3. 上传（有脏行或自愈才传）──
      final all = await database.readAllNoteMetaIncludingTombstones();
      final hasDirty = all.values.any((m) => !m.synced);
      if (!hasDirty && !forceUpload) {
        journal.append(
          type: JournalEventType.syncNoteMeta,
          phase: JournalPhase.done,
          dataKeyEpoch: keyring.dataKeyEpoch,
          note: 'merged=$applied uploaded=0(clean)',
        );
        return;
      }
      final sealed = await NoteMetaSyncCodec.seal(
        _dataKey,
        NoteMetaSyncCodec.encode(all),
      );
      await backend.putMetaObject(sealed);
      await database.markNoteMetasSynced(all.values);
      final gc = await database.purgeReportedNoteMetaTombstones();
      Log.sync.i(
        'note_meta 同步完成: merged=$applied '
        'uploaded=${all.length} tombstoneGc=$gc',
      );
      journal.append(
        type: JournalEventType.syncNoteMeta,
        phase: JournalPhase.done,
        dataKeyEpoch: keyring.dataKeyEpoch,
        note: 'merged=$applied uploaded=${all.length} tombstoneGc=$gc',
      );
    } on Exception catch (e, st) {
      Log.sync.w('note_meta 同步失败（不影响同步结果）', error: e, stackTrace: st);
      journal.append(
        type: JournalEventType.syncNoteMeta,
        phase: JournalPhase.failed,
        dataKeyEpoch: keyring.dataKeyEpoch,
        note: 'sync failed: $e',
      );
    } on Error catch (e, st) {
      Log.sync.w('note_meta 同步异常（不影响同步结果）', error: e, stackTrace: st);
      journal.append(
        type: JournalEventType.syncNoteMeta,
        phase: JournalPhase.failed,
        dataKeyEpoch: keyring.dataKeyEpoch,
        note: 'sync error: $e',
      );
    }
  }

  /// dataKey 迁移完成后用**新** dataKey 重封重传 items.meta 全量快照（Q2a）。
  ///
  /// 保住「迁移后一切远端对象都用新 key」不变式，避免迁移窗口期他端 meta 段
  /// 解密失败。失败不阻断迁移流程（[_syncNoteMeta] 的自愈路径兜底）。
  Future<void> _uploadNoteMetaSnapshot(String reason) async {
    if (!backend.supportsMetaObjects) return;
    try {
      final all = await database.readAllNoteMetaIncludingTombstones();
      final sealed = await NoteMetaSyncCodec.seal(
        _dataKey,
        NoteMetaSyncCodec.encode(all),
      );
      await backend.putMetaObject(sealed);
      Log.sync.i('note_meta 快照已重传 (reason=$reason, entries=${all.length})');
    } on Object catch (e, st) {
      Log.sync.w('note_meta 快照重传失败（下次同步自愈兜底）', error: e, stackTrace: st);
    }
  }

  /// P3-a：blob 操作重试退避（网络抖动鲁棒性）
  ///
  /// 对 backend.putBlob / getBlob 调用做指数退避重试。仅对
  /// [BackendUnavailableException] 重试（网络/存储临时不可用），其他异常
  /// （加密失败、格式错误等）与 getBlob 返回 null 的合法语义都不重试。
  ///
  /// 设计要点：
  ///   - **仅重试 BackendUnavailableException**：ConflictException 是 manifest
  ///     层语义，不应在 blob 层吞掉；其他 Object 异常直接抛出，避免把不可重试
  ///     的逻辑错误掩盖成「网络问题」。
  ///   - **重试次数 2 次（共 3 次尝试）**：与 [sync] 的 [maxRetries] 对齐，
  ///     单 blob 失败不应让整次同步被一个偶发抖动阻塞太久。
  ///   - **指数退避 200ms → 400ms**：小步长避免同步时长被放大太多；WebDAV
  ///     请求本身一般几百 ms，200ms 等待足够让瞬时连接重置恢复。
  ///   - **putBlob 幂等**：[SyncBackend.putBlob] 契约保证相同 hash+data 多次
  ///     调用结果一致，重试覆盖写安全。
  ///   - **getBlob null 不重试**：null 是「blob 不存在」的合法语义，重试无意义。
  ///
  /// 不改变上层 catch 行为：仍把最终失败抛给 [_uploadNote] / [_downloadNote]
  /// 的现有 catch 分支，由它们映射为 uploadFailed / skip 动作。
  Future<T> _withBlobRetry<T>(
    Future<T> Function() op, {
    required String opName,
    required String hash,
  }) async {
    const maxAttempts = 3; // 1 次初试 + 2 次重试
    const baseDelay = Duration(milliseconds: 200);
    Object? lastError;
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await op();
      } on BackendUnavailableException catch (e) {
        lastError = e;
        // T-23 修复：认证失效（401/403）等确定性失败不重试
        if (!e.retryable) {
          Log.sync.w(
            'blob $opName 失败（不可重试，如认证失效），放弃重试 '
            '(hash=${_short(hash)})',
            error: e,
          );
          break;
        }
        if (attempt == maxAttempts) break;
        final delay = baseDelay * (1 << (attempt - 1)); // 200ms, 400ms
        Log.sync.w(
          'blob $opName 临时不可用，${delay.inMilliseconds}ms 后重试 '
          '(attempt=$attempt/$maxAttempts, hash=${_short(hash)})',
          error: e,
        );
        await Future<void>.delayed(delay);
      }
    }
    // 重试耗尽，抛回原始 BackendUnavailableException 由上层 catch 处理
    throw lastError!;
  }

  /// 执行一次完整同步
  ///
  /// 返回 [SyncResult]，包含上传/下载/删除/冲突/迁移统计。
  /// 如果乐观锁冲突超过 maxRetries 次，返回 failure 结果。
  ///
  /// 注意：远端不可用时的 `BackendUnavailableException` **直接抛出**，
  /// 不返回 failure（文档修正，见评审 #16）；由上层 SyncService 兜底捕获。
  ///
  /// v4（epoch 消除 §8.2[I]）：scenario-b（他端改密码）不再「继续同步 +
  /// passwordEpochMismatch 标志」，而是由 _syncOnce **中止并返回 failure**，
  /// errorMessage 提示「他端改了密码，请重新输入密码」。
  Future<SyncResult> sync() async {
    final allActions = <SyncAction>[];
    int totalMigrated = 0;

    Log.sync.i(
      '同步开始 (backend=${backend.runtimeType}, '
      'deviceId=$deviceId, keyVersion=${keyring.keyVersion}, '
      'dataKeyEpoch=${keyring.dataKeyEpoch})',
    );

    // F-H05: 迁移重试与乐观锁冲突重试分开计数。
    // 修复前两者共用同一个 attempt 计数（maxRetries），迁移成功后的重试
    // 会提前耗尽乐观锁冲突的预算，时序上可能让迁移后首轮同步意外失败。
    int conflictAttempts = 0;
    int migrationAttempts = 0;

    // 循环上界用两者的总预算（maxRetries*2）兜底，保证永远以 return 收束；
    // 实际退出取决于冲突/迁移各自的独立计数。
    for (int attempt = 1; attempt <= maxRetries * 2; attempt++) {
      try {
        final result = await _syncOnce(attempt);
        // 累积迁移计数（迁移可能发生在 _syncOnce 内部）
        totalMigrated += result.migrated;
        allActions.addAll(result.actions);

        // skipped 为聚合统计：替代此前逐条 uuid 的 skip 日志（噪音治理）
        Log.sync.i(
          '同步完成 (attempt=$attempt, success=${result.success}, '
          'uploaded=${result.uploaded}, downloaded=${result.downloaded}, '
          'deleted=${result.deleted}, conflicts=${result.conflicts}, '
          'skipped=${result.skipped}, migrated=$totalMigrated)',
        );

        // 迁移后需要重新同步一次（用新 dataKey），但 _syncOnce 已处理
        return result.copyWith(migrated: totalMigrated);
      } on ConflictException catch (e, st) {
        // 乐观锁冲突：回到 Step 1 重试（独立计数，不与迁移共用预算）
        conflictAttempts++;
        Log.sync.w(
          '乐观锁冲突 (attempt=$attempt, conflict='
          '$conflictAttempts/$maxRetries)',
          error: e,
          stackTrace: st,
        );
        // P3-c：记录乐观锁重试，便于诊断多设备高并发写入竞争
        journal.append(
          type: JournalEventType.syncOptimisticLockRetry,
          dataKeyEpoch: keyring.dataKeyEpoch,
          note: 'conflict=$conflictAttempts/$maxRetries: $e',
        );
        if (conflictAttempts >= maxRetries) {
          return SyncResult.failure(
            '乐观锁冲突超过 $maxRetries 次：$e',
            attempts: conflictAttempts,
          );
        }
        // 否则 continue 重试
      } on _MigrationRequiredException catch (e) {
        // 迁移后需要重新拉取并同步，回到 Step 1 重试（独立计数）
        // 迁移已成功，但 manifest 中的 encryptedDataKey 已变化，
        // 需要重新 GET 远端 manifest（用新 dataKey 解密）
        migrationAttempts++;
        Log.sync.i('dataKey 迁移完成 (migratedCount=${e.migratedCount})，重新同步');
        totalMigrated += e.migratedCount;
        allActions.add(
          const SyncAction(
            type: SyncActionType.migrate,
            uuid: '',
            message: 'dataKey 迁移完成，重新同步',
          ),
        );
        // 继续重试（不计入乐观锁冲突次数）
        if (migrationAttempts >= maxRetries) {
          return SyncResult.failure(
            '迁移后重试同步超过 $maxRetries 次',
            attempts: migrationAttempts,
          );
        }
      }
    }
    Log.sync.w('同步流程异常退出（超出重试次数）');
    return SyncResult.failure('Unexpected sync flow exit');
  }

  /// 远端 manifest 损坏后的统一恢复路径（manifest-reliability-design §7.1）
  ///
  /// 触发条件：`deserializeHeaderOnly` 抛 [FormatException]（结构损坏）或
  /// [ManifestAuthException]（v5 容器 magic/fileVer/headerLen 非法 / pubHash 失败）。
  ///
  /// 流程：
  ///   1. 备份损坏文件（`backupCorruptManifest`）
  ///   2. journal 留痕（`syncManifestRebuild`，含 keyState）
  ///   3. 用本地数据重建 manifest（`_buildLocalManifest` + `_mergeAndTransfer`）
  ///   4. PUT 覆盖远端（用原 etag 乐观锁）
  ///   5. 更新本地状态 + 推送 journal
  ///
  /// 这是 §3.4 现路径的提取复用，供 `_syncOnce` 的两个 catch 子句共用，
  /// 并为 §7 统一恢复编排（re-GET → 验 pubHash 挑 bak → 重建）的后续扩展预留入口。
  ///
  /// **异常分流契约（§11.1）**：本方法仅处理「数据损坏」，不处理「密钥不匹配」
  /// （后者走 scenario-b / 迁移流程）。调用方需确保只在 catch
  /// `FormatException` / `ManifestAuthException` 时调用，**绝不**在 catch
  /// `ManifestKeyMismatchException` 时调用。
  Future<SyncResult> _recoverFromCorruptRemoteManifest(
    ({Uint8List ciphertext, String etag}) remoteResponse,
    Object error,
    StackTrace stackTrace,
    int attempt,
  ) async {
    Log.sync.w(
      '远端 manifest 损坏，尝试恢复（§7.1 统一恢复编排）',
      error: error,
      stackTrace: stackTrace,
    );

    // ── §7.1 步骤 1：re-GET（防瞬时坏 / 半写） ──────────────────────
    // 远端文件可能只是瞬时损坏（网络截断、半写、磁盘抖动），重新 GET 一次
    // 大概率拿到完好版本。re-GET 成功则 merge 保留远端数据（避免直接本地
    // 重建丢失其他设备的更新）；失败才走步骤 2/3。
    Manifest? recoveredManifest;
    ({Uint8List ciphertext, String etag})? recoveredResponse;
    // 恢复来源追踪：re-get / bak / local（用于 notes 与日志区分路径）
    var recoveredSource = 'local';
    try {
      final retryResponse = await backend.getManifest();
      if (retryResponse.ciphertext.isNotEmpty) {
        // 完整解析（含 pubHash + GCM）；通过则远端完好
        recoveredManifest = await ManifestCrypto.deserialize(
          _dataKey,
          retryResponse.ciphertext,
        );
        recoveredResponse = retryResponse;
        recoveredSource = 'reget';
        Log.sync.i('re-GET 成功，远端 manifest 完好，merge 保留远端数据');
      } else {
        Log.sync.w('re-GET 返回空 manifest，走本地重建');
      }
    } on ManifestAuthException catch (e) {
      Log.sync.w('re-GET 仍损坏（pubHash 失败），走本地重建', error: e);
    } on ManifestKeyMismatchException {
      // re-GET 密钥不匹配——这不是「损坏恢复」的职责（§11.1 异常分流），
      // 抛出让上层走 scenario-b 密钥/迁移流程。
      rethrow;
    } on Object catch (e) {
      Log.sync.w('re-GET 失败（网络/后端错误），走本地重建', error: e);
    }

    // ── §7.1 步骤 2：bak 循环（re-GET 失败时） ─────────────────────
    // manifest-reliability-design §7.2 + §11.2：从最新 bak 开始，先验 pubHash
    //（无 key、免费、粗损检测），验过才 GCM 解密。任何异常都跳过当前份试下一份
    // —— 包括 ManifestKeyMismatchException（pubHash 过 + GCM 败 = 旧 dataKey 数据，
    // 不是损坏）。全部 bak 试完仍无可用版本才走本地重建（步骤 3），
    // 绝不因 bak 解密失败误触发 scenario-b 强制重登。
    if (recoveredManifest == null) {
      try {
        final bakNames = await backend.listManifestBackups();
        for (final name in bakNames) {
          try {
            final bakBytes = await backend.readManifestBackup(name);
            if (bakBytes == null || bakBytes.isEmpty) continue;
            // pubHash 预验 + GCM 解密都在 deserialize 内完成（§7.2）
            recoveredManifest = await ManifestCrypto.deserialize(
              _dataKey,
              bakBytes,
            );
            recoveredSource = 'bak';
            Log.sync.i('从 bak 恢复 manifest 成功 name=$name');
            break;
          } on Object catch (e) {
            // §11.2：bak 循环中任何异常（含 ManifestKeyMismatchException）
            // 都跳过当前份试下一份，绝不触发 scenario-b。
            recoveredManifest = null;
            Log.sync.w('manifest bak 不可用 name=$name，试下一份', error: e);
          }
        }
      } on Object catch (e) {
        // 后端读取失败（网络/未实现读侧）：不阻断，走本地重建
        recoveredManifest = null;
        Log.sync.w('manifest bak 读取失败，走本地重建', error: e);
      }
    }

    // ── §7.1 步骤 3：本地重建（re-GET 失败且无可用 bak） ──────────
    // 仅当 re-GET 失败且 bak 全不可用时才备份损坏文件：
    //   - re-GET 成功说明损坏是瞬态（网络/半写），远端已是完好 manifest，
    //     backupCorruptManifest 会把它移走/删除（LocalFS rename / SafeServer move
    //     / WebDAV DELETE），随后 PUT 也因文件已不在而 412/Conflict 失败——
    //     白白丢失刚 re-GET 到的远端数据。
    //   - bak 恢复说明已有完好代际本，无需再动远端损坏文件（直接用其 etag 覆盖）。
    // 用原始损坏的 remoteResponse（非 re-GET），保证归因对象是首次观测到的坏体。
    if (recoveredManifest == null) {
      await backend.backupCorruptManifest(remoteResponse.ciphertext);
    }
    // P2 journal §3.6c：manifest 单点故障是 journal「第二数据源」角色的
    // 核心场景，这一刻必须留痕（含当时 keyState，便于事后取真）
    journal.append(
      type: JournalEventType.syncManifestRebuild,
      phase: JournalPhase.done,
      dataKeyEpoch: keyring.dataKeyEpoch,
      keyState: _keyStateSnapshot,
      note: 'remote manifest corrupt, recovered via $recoveredSource: $error',
    );
    final localManifest = await _buildLocalManifest();
    final actions = <SyncAction>[];
    _addAction(
      actions,
      SyncAction(
        type: SyncActionType.skip,
        uuid: '',
        message: recoveredSource == 'local'
            ? '远端 manifest 损坏，已备份损坏文件并本地重建'
            : '远端 manifest 损坏，已从 $recoveredSource 恢复，正常合并',
      ),
    );
    // merge：reget/bak 成功用 recoveredManifest（保留远端数据），否则 null（纯本地重建）
    final merged = (await _mergeAndTransfer(
      localManifest,
      recoveredManifest,
      actions,
    )).merged;
    // PUT：本地重建（recoveredSource == 'local'，且 backupCorruptManifest 已把损坏
    // 文件 move/DELETE 移除，远端已无文件）时，必须用空 etag（If-None-Match /
    // 首传语义）重建；仍沿用旧 etag 会因文件已不存在而 412/Conflict 报错（F-H01）。
    // re-GET 成功：远端文件已是完好版本，用其新 etag；bak 恢复：未动远端损坏
    // 文件，用首次 GET 的 etag 覆盖即可。
    final putEtag = recoveredSource == 'local'
        ? ''
        : (recoveredResponse?.etag ?? remoteResponse.etag);
    final newCiphertext = await ManifestCrypto.serialize(_dataKey, merged);
    await backend.putManifest(newCiphertext, putEtag);
    // P3-c：损坏重建路径的 manifest PUT（与正常路径区分）
    Log.sync.i(
      'PUT manifest ok (rebuild after corrupt, '
      'items=${merged.items.length}, '
      'source=$recoveredSource)',
    );
    journal.append(
      type: JournalEventType.syncManifestPut,
      phase: JournalPhase.done,
      dataKeyEpoch: keyring.dataKeyEpoch,
      note:
          'rebuild-after-corrupt items=${merged.items.length} '
          'source=$recoveredSource',
    );
    await _updateLocalState(
      merged,
      excludeSynced: {
        for (final a in actions)
          if (a.type == SyncActionType.uploadFailed) a.uuid,
      },
    );
    // 重建路径也要把 journal 推到远端——这正是「manifest 丢了还能取真」
    // 的那份第二数据源
    //
    // L-2 修复：恢复轮同样执行 meta 段——重建可能发生在 dataKey 迁移窗口，
    // items.meta 或为旧 key 残留，等下一轮才自愈会拉长解密失败窗口；
    // 且恢复轮本身可能有未上报的 meta 脏行。与常规轮同序：meta 在前、
    // journal 副本收尾（meta 留痕随本轮上传）。
    await _syncNoteMeta();
    await _uploadJournal();
    return SyncResult.success(
      uploaded: _countActions(actions, SyncActionType.upload),
      downloaded: _countActions(actions, SyncActionType.download),
      deleted: _countActions(actions, SyncActionType.delete),
      skipped: _countActions(actions, SyncActionType.skip),
      conflicts: _countActions(actions, SyncActionType.conflict),
      actions: actions,
      attempts: attempt,
    );
  }

  /// 执行一次同步尝试（不含重试逻辑）
  ///
  /// [attempt] 当前重试次数（用于诊断）
  /// 返回同步结果。远端不可用或密码不匹配时返回 failure。
  ///
  /// 密钥纪元守卫（B1 修复）：
  ///   解析远端 header 后比对 keyVersion。如果远端更高（他端改了密码），
  ///   本地旧密码设备不会把旧 encryptedDataKey 写回远端，
  ///   而是保留远端的新 encryptedDataKey，SyncResult.passwordEpochMismatch=true。
  Future<SyncResult> _syncOnce(int attempt) async {
    // Step 1: GET 远端 manifest
    final remoteResponse = await backend.getManifest();
    // P3-log：manifest GET 结果（debug 级，稳态噪音治理）
    // version 在 header 解析后补打（见下方 remoteHeader 获取后）
    Log.sync.d(
      'GET manifest empty=${remoteResponse.ciphertext.isEmpty} '
      'etag=${remoteResponse.etag.isEmpty ? "-" : "present"} '
      'attempt=$attempt',
    );

    Manifest? remoteManifest;

    if (remoteResponse.ciphertext.isNotEmpty) {
      // 1a. 仅解析 header（明文，不需要 dataKey）
      //
      // D2 修复：header 解析失败（FormatException）时备份损坏文件，
      // 跳过远端 manifest 处理，用本地数据重建 manifest 上传。
      // 注意：GCM tag 验证失败不属于"损坏"，是密码不匹配，仍走迁移流程。
      ManifestHeader remoteHeader;
      try {
        remoteHeader = ManifestCrypto.deserializeHeaderOnly(
          remoteResponse.ciphertext,
        );
      } on FormatException catch (e, st) {
        // 远端 manifest 结构损坏（数据过短等结构性问题）
        // → 备份后用本地数据重建 manifest 上传覆盖（§7.1 统一恢复编排）
        return _recoverFromCorruptRemoteManifest(
          remoteResponse,
          e,
          st,
          attempt,
        );
      } on ManifestAuthException catch (e, st) {
        // v5 容器（§5.5）：magic/fileVer/headerLen 非法 或 pubHash 校验失败
        // → 数据损坏（位翻转/截断/半写）。走同一重建路径。
        // **绝不走 scenario-b 强制重登**（§11.1 异常分流契约）——
        // 损坏与密钥不匹配在此已被 pubHash 正交区分。
        return _recoverFromCorruptRemoteManifest(
          remoteResponse,
          e,
          st,
          attempt,
        );
      }

      // [G] 协议降级拒绝（§8.2[G]）：远端 schemaVersion 低于当前协议版本
      // 时拒绝解读、不迁移、不覆盖，提示升级（与不兼容策略 §0 对齐）。
      final schemaReject = rejectOldSchemaVersion(remoteHeader);
      if (schemaReject != null) {
        return SyncResult.failure(schemaReject, attempts: attempt);
      }

      // P0-log：远端 manifest version（排查多端竞争的关键指标）
      Log.sync.d(
        'GET manifest version=${remoteHeader.version} '
        'fp=${_short(remoteHeader.dataKeyFingerprint)}',
      );

      // P0-journal：同步轮次 start 边界
      // 携带 attempt + 远端 version/fp，为 journal 中后续事件提供时序锚点
      journal.append(
        type: JournalEventType.syncRound,
        phase: JournalPhase.start,
        dataKeyEpoch: keyring.dataKeyEpoch,
        note:
            'attempt=$attempt remoteVersion=${remoteHeader.version} '
            'fp=${_short(remoteHeader.dataKeyFingerprint)}',
      );

      // 1b. v4（epoch 消除 §8.2[I]）：用 header.dataKeyFingerprint 精确判定
      // 「dataKey 是否相同」，替代旧「keyVersion 守卫 + 本地 MK 解不开 + items
      // 能解」的间接信号（原 4 分支收敛为 2 分支）。scenario-b（他端改密码）→
      // **中止同步 + 强制重登录**（选项 B 定案），不 PUT、不 echo——彻底堵死
      // header 层翻转战争（B1/B1-2 当年修掉的问题），与 v4「只读解密、不自动
      // 改写」精神一致。
      final localDataKeyFp = SyncCrypto.computeDataKeyFingerprint(_dataKey);
      final remoteDataKeyFp = remoteHeader.dataKeyFingerprint;
      // 远端无指纹字段（旧协议 manifest）→ 保守按「dataKey 相同」处理
      final sameDataKey =
          remoteDataKeyFp.isEmpty || remoteDataKeyFp == localDataKeyFp;

      if (sameDataKey) {
        // ── 分支 1：同一 dataKey（正常同步 / 改密码 / scenario-b）──
        if (remoteHeader.encryptedDataKey == keyring.encryptedDataKey) {
          // 包裹完全相同 → 正常同步
          remoteManifest = await ManifestCrypto.deserialize(
            _dataKey,
            remoteResponse.ciphertext,
          );
        } else {
          // 包裹不同：本地 MK 能否解开远端包裹？
          // （AES-GCM wrap 用随机 nonce，同一 MK+dataKey 每次包裹也不同，
          //   不能仅凭字符串不同判定密码不一致，必须实际 unwrap 验证）
          final mk = keyring.mk;
          Uint8List? remoteDk;
          if (mk != null) {
            try {
              remoteDk = await SyncCrypto.unwrapDataKey(
                mk,
                base64Decode(remoteHeader.encryptedDataKey),
              );
            } on Object {
              remoteDk = null;
            }
          }
          if (remoteDk != null && SyncCrypto.bytesEqual(remoteDk, _dataKey)) {
            // 能解开 + 解出的 dataKey 与本地一致 → 两端同 MK（密码一致）、
            // 同 dataKey，包裹差异仅来自 nonce 随机性或远端重新 wrap。
            // 本地包裹合法（能解开本地全部 blob），
            // 不 adopt、不 echo（§0 只读解密）→ 正常同步。
            remoteManifest = await ManifestCrypto.deserialize(
              _dataKey,
              remoteResponse.ciphertext,
            );
          } else if (remoteDk != null) {
            // F-M05：能解开远端包裹但 dataKey 与本地不一致（同 MK 却不同
            // dataKey，与 fingerprint 判定矛盾的防御分支）。远端 manifest
            // 按别的 dataKey 加密，本地无法正解其内容，保守失败且不写任何值。
            Log.sync.w('远端包裹可解开但 dataKey 与本地不一致，中止同步');
            return SyncResult.failure(
              '远端 manifest 使用其他 dataKey 加密，与本地不一致，无法同步',
              attempts: attempt,
            );
          } else if (mk == null) {
            // MK 未缓存（测试构造 / 异常状态，真实登录必有 MK）：无法 unwrap
            // 验证远端包裹。用「本地 dataKey 能否解远端 manifest items」兜底：
            //   - 能解 → dataKey 相同 → 保守继续同步（无法确认他端改密码，
            //     不中止；同步零 echo——本地包裹不采用远端值）
            //   - 不能解 → 无法判定 → 保守失败，避免向远端写任何值
            try {
              await ManifestCrypto.deserialize(
                _dataKey,
                remoteResponse.ciphertext,
              );
              Log.sync.w(
                'MK 未缓存，无法验证远端包裹；本地 dataKey 可解远端 '
                'manifest items，保守继续同步（零 echo）',
              );
              remoteManifest = await ManifestCrypto.deserialize(
                _dataKey,
                remoteResponse.ciphertext,
              );
            } on ManifestKeyMismatchException catch (e) {
              // pubHash 已通过（数据未损坏），GCM 失败 = 密钥不匹配。
              // 保守失败，避免向远端写任何值（与原 `on Object` 行为一致）。
              Log.sync.w('MK 未缓存且本地 dataKey 解不开远端 manifest，中止同步', error: e);
              return SyncResult.failure(
                '密钥验证信息不足，无法同步（MK 未缓存且 dataKey 不匹配）',
                attempts: attempt,
              );
            } on ManifestAuthException catch (e, st) {
              // 防御性（§11.1）：pubHash 应在 deserializeHeaderOnly 阶段已验过，
              // 此处理论不再抛损坏异常；若 bytes 并发修改导致 pubHash 失败，走重建。
              return _recoverFromCorruptRemoteManifest(
                remoteResponse,
                e,
                st,
                attempt,
              );
            } on Object catch (e) {
              Log.sync.w('MK 未缓存且解析远端 manifest 未预期异常，中止同步', error: e);
              return SyncResult.failure(
                '密钥验证信息不足，无法同步（MK 未缓存且解析失败：$e）',
                attempts: attempt,
              );
            }
          } else if (remoteHeader.keyVersion < keyring.keyVersion) {
            // 解不开 + 远端 keyVersion 更低 → **本端改了密码还没推送**：
            // dataKey 未变（改密码不换 dataKey，§2.1），本地包裹是新 MK 包的
            // （合法值）→ 正常同步，_buildLocalManifest 会用本地新包裹推送。
            // 注：keyVersion 仅用于「谁改了密码」的方向判定，绝不采用远端任何值。
            Log.sync.i(
              '本端改密码未推送（远端 keyVersion=${remoteHeader.keyVersion}'
              ' < 本地 ${keyring.keyVersion}），正常同步推送本地新包裹',
            );
            remoteManifest = await ManifestCrypto.deserialize(
              _dataKey,
              remoteResponse.ciphertext,
            );
          } else {
            // 解不开 + 远端 keyVersion >= 本地 → **他端改了密码（scenario-b）**：
            // 本地密码已过期。中止同步，报「他端改了密码，请重新输入密码」，
            // 不 PUT、不 echo（拒绝向远端写入任何值，防翻转）。
            // requiresRelogin=true 通知 UI 强制登出并要求重新登录
            // （v4 选项 B 定案，§8.2[I]）。
            Log.sync.w(
              'scenario-b：他端改了密码，本地 MK 解不开远端包裹'
              '（远端 keyVersion=${remoteHeader.keyVersion} >= 本地 '
              '${keyring.keyVersion}），中止同步强制重登录',
            );
            // P1-journal：scenario-b 留痕，便于多端密码变更排查
            journal.append(
              type: JournalEventType.syncRound,
              phase: JournalPhase.failed,
              dataKeyEpoch: keyring.dataKeyEpoch,
              note:
                  'scenario-b: remote keyVersion=${remoteHeader.keyVersion} '
                  '>= local ${keyring.keyVersion}, requiresRelogin=true',
            );
            return SyncResult.failure(
              '检测到同步密码已在其他设备修改，请退出登录并使用新密码重新登录'
              '（本地笔记未丢失，未同步的更改已保留）',
              attempts: attempt,
              requiresRelogin: true,
            );
          }
        }
      } else {
        // ── 分支 2：dataKey 不同（新设备加入 / scenario-d 迁移）──
        final migrationResult = await keyring.checkMigrationNeeded(
          remoteHeader.encryptedDataKey,
        );
        if (migrationResult.success && migrationResult.remoteDataKey != null) {
          // 本地 MK 能解开远端包裹 → 同密码同 salt：
          if (SyncCrypto.bytesEqual(migrationResult.remoteDataKey!, _dataKey)) {
            // remoteDataKey == 本地 dataKey 但指纹不同（理论上矛盾，防御处理）
            remoteManifest = await ManifestCrypto.deserialize(
              _dataKey,
              remoteResponse.ciphertext,
            );
          } else {
            // remoteDataKey != 本地 → dataKey 真变 → 迁移（同 keyring 换 dataKey）
            final migratedCount = await _executeMigration(
              migrationResult,
              remoteHeader,
            );
            remoteManifest = await ManifestCrypto.deserialize(
              _dataKey,
              remoteResponse.ciphertext,
            );
            throw _MigrationRequiredException(migratedCount);
          }
        } else {
          // 本地 MK 解不开远端包裹（密码不同 或 salt 不同）：
          // 用远端 KDF + 用户密码重派生 MK 判别（场景 c vs d）
          final password = passphraseProvider?.call();
          if (password == null || password.isEmpty) {
            // 无密码提供者（旧测试或未注入），退回原失败逻辑
            Log.sync.w('dataKey 迁移失败：无密码提供者');
            return SyncResult.failure(
              'dataKey 迁移失败：${migrationResult.error}',
              attempts: attempt,
            );
          }
          final remoteResult = await Keyring.tryDeriveRemoteDataKey(
            password: password,
            remoteKdf: remoteHeader.kdf,
            remoteEncryptedDataKey: remoteHeader.encryptedDataKey,
            remoteKeyFingerprint: remoteHeader.keyFingerprint,
          );
          if (remoteResult == null) {
            // 场景 c：密码真的不匹配
            Log.sync.w('密码不匹配，无法同步（密码不同）');
            return SyncResult.failure(
              '密码不匹配，无法同步：${migrationResult.error}',
              attempts: attempt,
              requiresRelogin: true,
            );
          }
          // 场景 d：密码相同、salt 不同 → 完整 keyring 迁移
          // 用远端 dataKey 重新加密所有本地笔记，更新本地 keyring 元数据
          Log.sync.i('检测到场景 d（密码相同、salt 不同），开始完整 keyring 迁移');
          final migratedCount = await _executeMigrationVault(
            remoteDataKey: remoteResult.dataKey,
            remoteEncryptedDataKey: remoteHeader.encryptedDataKey,
            remoteVaultId: remoteHeader.vaultId,
            remoteKdf: remoteHeader.kdf,
            remoteKeyFingerprint: remoteHeader.keyFingerprint,
            remoteKeyVersion: remoteHeader.keyVersion,
            remoteCreatedAt: remoteHeader.createdAt,
            remoteMk: remoteResult.mk,
          );

          // 迁移后用新 dataKey 解析完整 manifest
          remoteManifest = await ManifestCrypto.deserialize(
            _dataKey,
            remoteResponse.ciphertext,
          );

          // 抛特殊异常，触发外层重试（用新 dataKey 重新同步）
          throw _MigrationRequiredException(migratedCount);
        }
      }
    }

    // P0-1 修复：远端 manifest 为空（首次同步 / 远端被清空 / 损坏重建分支已在
    // 上面 early-return）时，本地 merged 只包含本端笔记，无法得知远端还有哪些
    // 内容寻址 blob 被其他设备引用。此时执行孤儿 blob GC 会误删其他设备残留在
    // 服务端的内容，造成不可逆数据丢失。因此跳过本次 GC，等待下次同步拿到远端
    // manifest 后再安全清理（next sync 时 remoteManifest != null）。
    final bool skipGc = remoteManifest == null;

    // P0-journal：同步轮次 start 边界（空 manifest 路径）
    // 远端 manifest 为空时上面的 start journal 不会执行，在此补一条
    if (skipGc) {
      journal.append(
        type: JournalEventType.syncRound,
        phase: JournalPhase.start,
        dataKeyEpoch: keyring.dataKeyEpoch,
        note: 'attempt=$attempt remoteManifest=empty',
      );
    }

    // Step 2: 构建本地 manifest（纪元不匹配时整体用远端密钥纪元）
    final localManifest = await _buildLocalManifest();

    // Step 3: 比对 + 传输（上传/下载/删除）
    final actions = <SyncAction>[];
    final mergeResult = await _mergeAndTransfer(
      localManifest,
      remoteManifest,
      actions,
    );
    final merged = mergeResult.merged;
    // P1 修复：本轮成功重传的待重传 uuid（供 PUT 成功后移除 pending 标记）
    final reuploadedOk = mergeResult.reuploadedOk;

    // D3 修复：判断是否需要 PUT manifest
    //
    // 若 merged 与 remote 在语义上完全等价（items 一致 + header 关键字段一致），
    // 则跳过 PUT——避免 blob 持续下载失败时 manifest version 每次同步无意义 +1
    // 攀升。
    //
    // 判定"有实际变更"的条件（任一满足即需要 PUT）：
    //   1. actions 中存在 upload/download/delete 类型（有成功的传输或墓碑应用）
    //   2. purgedUuids 非空（本地硬删除需要从远端 manifest 清除墓碑）
    //   3. merged.items 与 remote.items 不一致（键集或任一条目字段不同）
    //   4. header 密钥字段变化（本端改密码推送新包裹 / 迁移后新 keyVersion）
    //      ——由 _hasEffectiveChange 内的 header 字段比对兜住
    final hasEffectiveChange = _hasEffectiveChange(
      actions: actions,
      merged: merged,
      remote: remoteManifest,
    );

    if (!hasEffectiveChange) {
      // 无实际变更：跳过 PUT manifest，version 不递增
      // 此时 remoteManifest 一定非空（_hasEffectiveChange 在 remote==null 时返回 true）
      await _updateLocalState(
        merged.copyWithHeader(
          version: remoteManifest!.header.version,
          updatedAt: remoteManifest.header.updatedAt,
        ),
        excludeSynced: {
          for (final a in actions)
            if (a.type == SyncActionType.uploadFailed) a.uuid,
        },
      );

      // F1 修复：即使跳过 PUT，也执行孤儿 blob GC
      // 场景：上次同步上传了 blob，本次同步无变更但远端有孤儿 blob 需清理
      // P0-1：远端 manifest 为空时跳过 GC（见上方 skipGc 说明）
      if (!skipGc) await _gcOrphanBlobs(merged);

      // P0-journal：同步轮次 done 边界（skip-PUT 路径）
      final skipConflicts = _countActions(actions, SyncActionType.conflict);
      journal.append(
        type: JournalEventType.syncRound,
        phase: JournalPhase.done,
        dataKeyEpoch: keyring.dataKeyEpoch,
        note:
            'attempt=$attempt skipPut=true conflicts=$skipConflicts '
            'version=${merged.header.version}',
      );

      // 笔记元数据同步段：skip-PUT 路径同样执行（meta 独立于 manifest 是否
      // PUT；自身永不抛异常，见 _syncNoteMeta 文档）。
      //
      // L-1 修复：补推 journal 远端副本。skip-PUT 轮次刚追加了 syncRound done
      // 与可能的 sync.noteMeta 条目，若不推送会延后一轮才入副本，拉宽
      // 「本地有、副本无」的缺口窗口（chaos「远端副本完整覆盖本地」不变式）。
      // syncToRemote 有水位控制：无新条目时 no-op，重复调用无害。
      await _syncNoteMeta();
      await _uploadJournal();

      return SyncResult.success(
        uploaded: 0,
        downloaded: 0,
        deleted: 0,
        skipped: _countActions(actions, SyncActionType.skip) + skipConflicts,
        conflicts: skipConflicts,
        actions: actions,
        attempts: attempt,
        failedNoteUuids: _failedUuids(actions),
      );
    }

    // Step 4: 加密 + PUT manifest（乐观锁）
    final newCiphertext = await ManifestCrypto.serialize(_dataKey, merged);
    // P1-1 修复：覆盖远端前先备份"即将被覆盖的旧 manifest"（环形 N 份）
    if (remoteResponse.ciphertext.isNotEmpty) {
      await backend.backupManifest(remoteResponse.ciphertext);
    }
    await backend.putManifest(newCiphertext, remoteResponse.etag);
    // P3-c：manifest PUT 成功——同步流程最关键的落地点，留 log + journal
    Log.sync.i(
      'PUT manifest ok (version=${merged.header.version}, '
      'attempt=$attempt, items=${merged.items.length})',
    );
    journal.append(
      type: JournalEventType.syncManifestPut,
      phase: JournalPhase.done,
      dataKeyEpoch: keyring.dataKeyEpoch,
      note:
          'version=${merged.header.version} attempt=$attempt '
          'items=${merged.items.length} '
          'backedUp=${remoteResponse.ciphertext.isNotEmpty}',
    );

    // Step 5: 更新本地状态
    await _updateLocalState(
      merged,
      excludeSynced: {
        for (final a in actions)
          if (a.type == SyncActionType.uploadFailed) a.uuid,
      },
    );

    // F1 修复：孤儿 blob GC（manifest PUT 成功后）
    // listBlobs() - manifest 引用的 hash = 孤儿，删除。
    // GC 失败不阻断同步（try-catch），下次同步会重试。
    // P0-1：远端 manifest 为空（首次同步/远端被清空）时跳过，避免误删其他设备 blob。
    if (!skipGc) await _gcOrphanBlobs(merged);

    // 密钥变更后的首次同步已将 pending 笔记的 blob 用新密钥重新上传。
    // P1 修复：仅移除本轮「成功重传」的 uuid；上传失败的保留标记，下次同步
    // 继续强制重传（原 clearAllPendingReupload 会把失败的也清掉 → 旧密钥 blob
    // 永久残留、无重试路径）。
    await database.removePendingReuploadUuids(reuploadedOk);

    // P0-journal：同步轮次 done 边界
    // 携带本轮统计，与 start 配对，构成完整的 sync 轮次边界
    // 必须在 _uploadJournal() 之前追加，否则本轮远端副本会缺少这条
    final uploaded = _countActions(actions, SyncActionType.upload);
    final downloaded = _countActions(actions, SyncActionType.download);
    final deleted = _countActions(actions, SyncActionType.delete);
    final conflicts = _countActions(actions, SyncActionType.conflict);
    journal.append(
      type: JournalEventType.syncRound,
      phase: JournalPhase.done,
      dataKeyEpoch: keyring.dataKeyEpoch,
      note:
          'attempt=$attempt uploaded=$uploaded downloaded=$downloaded '
          'deleted=$deleted conflicts=$conflicts '
          'version=${merged.header.version}',
    );

    // P2 journal §3.3-4 / §3.6c：同步成功后把本地 journal 的加密副本推到远端。
    // 这是 journal「第二数据源」角色的落地点：本机沙盒被清、manifest 损坏时，
    // 仍能从远端 journal 还原出 keyState 与操作序列。失败不阻断同步。
    //
    // 注意顺序：_syncNoteMeta 的 journal 留痕必须发生在 _uploadJournal **之前**，
    // 否则 meta 条目会晚一轮才进远端副本，造成「本地有、副本无」的缺口
    // （chaos 测试「远端副本应完整覆盖本地 journal」锁定的不变式）。
    await _syncNoteMeta();
    await _uploadJournal();

    // 统计结果
    return SyncResult.success(
      uploaded: uploaded,
      downloaded: downloaded,
      deleted: deleted,
      skipped: _countActions(actions, SyncActionType.skip) + conflicts,
      conflicts: _countActions(actions, SyncActionType.conflict),
      actions: actions,
      attempts: attempt,
      failedNoteUuids: _failedUuids(actions),
    );
  }

  /// 全面校验并修复远端 blob 数据（设置页「修复同步数据」按钮调用）。
  ///
  /// 与 [sync] 的区别：sync 是增量对账，repair 是「全量体检 + 治愈」——
  /// 逐条验证每个远端 blob 能否被当前 dataKey 解密，不能的尝试用本机
  /// 明文（同 uuid 或同内容孪生笔记）重传覆盖，仍不能的标记为损坏。
  ///
  /// 全程只读远端 + 必要时重传覆盖，不删除任何笔记；无法修复的只标记不丢弃。
  ///
  /// 返回 [SyncResult]：uploaded 含 heal 计数，failedNoteUuids 为仍损坏的 uuid。
  ///
  /// P1 修复（DS001）：修复过程遇到乐观锁冲突（他端在 GET 与 PUT 之间修改了
  /// manifest）时，重试整个修复流程（重新 GET 最新 manifest 再逐条体检），
  /// 与 [sync] 的乐观锁重试语义对齐；重试上限 [maxRetries] 次后返回 failure。
  Future<SyncResult> repairRemote() async {
    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        return await _repairRemoteOnce(attempt);
      } on ConflictException catch (e, st) {
        Log.sync.w(
          'repairRemote 乐观锁冲突 (attempt=$attempt/$maxRetries)',
          error: e,
          stackTrace: st,
        );
        if (attempt == maxRetries) {
          return SyncResult.failure(
            '修复时乐观锁冲突超过 $maxRetries 次：$e',
            attempts: attempt,
          );
        }
        // 否则 continue：重新 GET 最新 manifest 并逐条重检
      }
    }
    Log.sync.w('repairRemote 异常退出（超出重试次数）');
    return SyncResult.failure('Unexpected repair flow exit');
  }

  /// 单次修复尝试（不含乐观锁重试，[repairRemote] 负责重试）
  Future<SyncResult> _repairRemoteOnce(int attempt) async {
    final actions = <SyncAction>[];
    final failed = <String>[];

    // Step 1: 拉取远端 manifest（用当前 dataKey 解密 items）
    final remoteResponse = await backend.getManifest();
    if (remoteResponse.ciphertext.isEmpty) {
      return SyncResult.success(actions: actions, attempts: attempt);
    }
    final ManifestHeader remoteHeader;
    try {
      remoteHeader = ManifestCrypto.deserializeHeaderOnly(
        remoteResponse.ciphertext,
      );
    } on ManifestAuthException catch (e, st) {
      // v5 容器：远端 manifest 数据损坏（magic/fileVer/headerLen 非法 / pubHash 失败）。
      // repair 流程只负责修 blob 缺失，不负责 manifest 重建（那是 sync 的 §7 职责）。
      // 返回明确失败，提示触发一次同步以走统一恢复编排。
      Log.sync.e('repairRemote: 远端 manifest 数据损坏', error: e, stackTrace: st);
      return SyncResult.failure(
        '远端 manifest 数据损坏，修复中止：请触发一次同步以自动重建',
        attempts: attempt,
      );
    } on FormatException catch (e, st) {
      Log.sync.e('repairRemote: 远端 manifest 结构损坏', error: e, stackTrace: st);
      return SyncResult.failure(
        '远端 manifest 结构损坏，修复中止：请触发一次同步以自动重建',
        attempts: attempt,
      );
    }
    // [G] 协议降级拒绝：远端 schemaVersion 低于当前协议版本时拒绝解读
    final schemaReject = rejectOldSchemaVersion(remoteHeader);
    if (schemaReject != null) {
      return SyncResult.failure(schemaReject, attempts: attempt);
    }
    final Manifest remoteManifest;
    try {
      remoteManifest = await ManifestCrypto.deserialize(
        _dataKey,
        remoteResponse.ciphertext,
      );
    } on ManifestKeyMismatchException catch (e, st) {
      // pubHash 已通过（数据未损坏），GCM 失败 = 密钥不匹配。
      // v5 容器异常分流（§5.5）：原 `on SyncDecryptionException` 改为捕获
      // `ManifestKeyMismatchException`（deserialize 内部已包装）。
      Log.sync.e('repairRemote: 远端 manifest 密钥不匹配', error: e, stackTrace: st);
      return SyncResult.failure(
        '无法解密远端 manifest（dataKey 不匹配），修复中止：请先用正确密码登录',
        attempts: attempt,
      );
    } on ManifestAuthException catch (e, st) {
      // 防御性：pubHash 已在 deserializeHeaderOnly 验过，此处理论不会再抛损坏
      // 异常；但若 bytes 在两次调用间被并发修改，保守按损坏处理（§11.1）。
      Log.sync.e(
        'repairRemote: 远端 manifest 数据损坏（防御性）',
        error: e,
        stackTrace: st,
      );
      return SyncResult.failure(
        '远端 manifest 数据损坏，修复中止：请触发一次同步以自动重建',
        attempts: attempt,
      );
    } on Object catch (e, st) {
      // 未预期异常（如 JSON 解析失败、字段缺失），记录堆栈便于排查
      Log.sync.e('repairRemote: 解析远端 manifest 未预期异常', error: e, stackTrace: st);
      return SyncResult.failure('解析远端 manifest 失败：$e', attempts: attempt);
    }

    // Step 2: 逐条校验/修复（仅使用当前 dataKey）
    final repairedItems = <String, ManifestItem>{};
    for (final entry in remoteManifest.items.entries) {
      final uuid = entry.key;
      final item = entry.value;
      if (item.deleted) {
        repairedItems[uuid] = item; // 墓碑原样保留
        continue;
      }

      // P3-a：getBlob 加重试退避（仅对网络错误重试，null 不重试）
      final blob = await _withBlobRetry(
        () => backend.getBlob(item.hash),
        opName: 'getBlob(repair)',
        hash: item.hash,
      );
      if (blob == null) {
        // P0-3 修复：blob 缺失时先尝试本机明文/孪生兜底重传，而不是直接跳过。
        // 本机持有该笔记的明文（同 uuid 且 hash 一致，或同内容孪生）→ 用当前
        // 密钥重新上传，恢复远端缺失的 blob；本机也无明文才标记跳过。
        // 注意：只有当 local.contentHash == item.hash 才用本机明文，防止并发编辑
        // 导致 upload 错误内容（与 P0-4 的 canHealLocal 对齐）。
        final local = await database.readNoteByUuid(uuid);
        final canHealLocal =
            local != null && !local.deleted && local.contentHash == item.hash;
        final twin = canHealLocal
            ? null
            : await database.readNoteByContentHash(item.hash);
        final source = canHealLocal ? local : twin;
        if (source != null && !source.deleted) {
          // P1 修复：重传失败时不声明 heal 成功（repairedItems 保持原条目、
          // 进入失败列表），下次 repairRemote 重试。
          if (await _uploadNote(source, actions)) {
            // v4：blob 纯化后 blobKeyEpoch 是纯审计元数据，重传不改写声明
            // （item 自描述、解密端不纠正，§4）
            repairedItems[uuid] = item;
            _addAction(
              actions,
              SyncAction(
                type: SyncActionType.heal,
                uuid: uuid,
                hash: item.hash,
                message: local != null
                    ? 'repair: blob 缺失，本机有明文重传修复'
                    : 'repair: blob 缺失，本机有同内容孪生重传修复',
              ),
            );
            continue;
          }
        }
        // 本机也无明文 / 重传失败：保留远端条目，标记跳过（下次同步重试）
        repairedItems[uuid] = item;
        _addAction(
          actions,
          SyncAction(
            type: SyncActionType.skip,
            uuid: uuid,
            hash: item.hash,
            message: 'repair: blob 缺失且无本机明文，跳过',
          ),
        );
        continue;
      }

      // 3a. 用当前 dataKey 解密（blob 纯化 v4：AAD=hash，无纪元探测）
      Uint8List? workingKey;
      try {
        await _openBlobEnvelope(item.hash, blob, dataKeyOverride: _dataKey);
        workingKey = _dataKey;
      } on SyncDecryptionException {
        // 解密失败：当前 key 解不开（非当前 key 或损坏），进入下方修复分支
      } on Object catch (e, st) {
        // 其他异常（数据损坏），记录后进入修复分支
        Log.sync.d(
          'repairRemote: 当前密钥解密异常 uuid=$uuid',
          error: e,
          stackTrace: st,
        );
      }

      if (workingKey != null) {
        // blob 能由当前 dataKey 解开：内容有效，直接采用
        repairedItems[uuid] = item;
        continue;
      }

      // 3b. 解密失败 → 回退本机明文（同 uuid 或同内容孪生）
      final local = await database.readNoteByUuid(uuid);
      final twin = local == null
          ? await database.readNoteByContentHash(item.hash)
          : null;
      final source = local ?? twin;
      // P4 修复（DS002）：必须校验 source.contentHash == item.hash 才可用本机明文兜底。
      // 原实现只判「本机有明文」，若本地已编辑（hash ≠ item.hash）则 _uploadNote
      // 上传的是新 hash 的 blob，而 repairedItems 仍保留旧 hash → 既修不好（manifest
      // 仍引用解不开的旧 blob）、又制造孤儿（新 hash 无人引用被 GC 隔离）。与
      // _downloadNote / _handleDownloadFailure 的「仅 hash 一致才兜底」保持一致。
      if (source != null &&
          !source.deleted &&
          source.contentHash == item.hash) {
        // P1 修复：重传失败不声明 heal（保持原条目 + 进入失败列表），下次重试。
        if (await _uploadNote(source, actions)) {
          repairedItems[uuid] = item;
          _addAction(
            actions,
            SyncAction(
              type: SyncActionType.heal,
              uuid: uuid,
              hash: item.hash,
              message: local != null
                  ? 'repair: 本机有明文，重传修复'
                  : 'repair: 本机有同内容孪生笔记，重传修复',
            ),
          );
          continue;
        }
      }

      // 3c. 无法修复：保留远端条目，标记损坏（不丢弃，等待其他设备/手动处理）
      failed.add(uuid);
      repairedItems[uuid] = item;
      _addAction(
        actions,
        SyncAction(
          type: SyncActionType.corrupt,
          uuid: uuid,
          hash: item.hash,
          message: 'repair: 所有密钥/明文均无法解密，标记损坏',
        ),
      );
    }

    // Step 4: 用修复后的 items + 当前 header 重新 PUT manifest（乐观锁 etag）
    //
    // P2 收敛：header 投影统一由 keyring.toManifestHeader 产出（唯一出口）。
    // v4：不再保留远端密钥三元组——repair 的前提是用户已用当前密码登录
    // （否则 _repairRemoteOnce 在 manifest 解密处即失败返回），本地 keyring
    // 即权威，只读不 echo 远端（§0）。
    final header = keyring.toManifestHeader(
      // v4：schemaVersion 真值化（§7.1），repair 也写当前协议版本
      schemaVersion: kManifestSchemaVersion,
      version: remoteHeader.version + 1,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      lastModifiedBy: deviceId,
      dataKeyWrap: remoteHeader.dataKeyWrap,
      dataKeyCreatedBy: deviceId,
    );
    final manifest = Manifest(header: header, items: repairedItems);
    final ciphertext = await ManifestCrypto.serialize(_dataKey, manifest);
    // P1-1 修复：覆盖远端前先备份"即将被覆盖的旧 manifest"（环形 N 份）
    if (remoteResponse.ciphertext.isNotEmpty) {
      await backend.backupManifest(remoteResponse.ciphertext);
    }
    await backend.putManifest(ciphertext, remoteResponse.etag);
    // P3-c：repair 路径的 manifest PUT 也留痕，与正常 sync 路径区分
    // （phase=done；note 中标 repair，便于 replay 时识别这是「修复」落地，
    // 而非常规同步推进——repair 跳过 LWW 直接收敛，统计口径不同）
    Log.sync.i(
      'PUT manifest ok (repair, version=${header.version}, '
      'attempt=$attempt, items=${manifest.items.length})',
    );
    journal.append(
      type: JournalEventType.syncManifestPut,
      phase: JournalPhase.done,
      dataKeyEpoch: keyring.dataKeyEpoch,
      note:
          'repair version=${header.version} attempt=$attempt '
          'items=${manifest.items.length} '
          'backedUp=${remoteResponse.ciphertext.isNotEmpty}',
    );

    return SyncResult.success(
      uploaded:
          _countActions(actions, SyncActionType.upload) +
          _countActions(actions, SyncActionType.heal),
      downloaded: 0,
      deleted: 0,
      skipped: _countActions(actions, SyncActionType.skip),
      conflicts: 0,
      actions: actions,
      attempts: attempt,
      failedNoteUuids: failed,
    );
  }

  /// 执行 dataKey 迁移：调用 keyring.migrateToRemote
  ///
  /// 返回迁移的笔记数量。
  /// 迁移成功后，keyring 引用更新为新实例（含新 dataKey 和 encryptedDataKey），
  /// database._dataKey 也已通过 database.setDataKey 更新。
  Future<int> _executeMigration(
    MigrationResult migrationResult,
    ManifestHeader remoteHeader,
  ) async {
    // P3-log：迁移入口（全库重加密是高风险操作，sync.log 应能独立还原迁移路径）
    Log.sync.i('_executeMigration: 开始 dataKey 迁移（同 vault）');

    // P2 journal §3.6b 两段式：**先记意图**再动手。
    // 注意职责边界：reEncryptAllNotes 自身的原子性由 SQLite 单事务保证，
    // journal 不替代事务；这里记录的是"跨边界步骤"（本地重加密 + 远端
    // manifest 推进 + blob 重传）的意图，崩溃后可据此诊断停在哪一步。
    final opId = journal.newOpId();
    journal.append(
      type: JournalEventType.keyMigrate,
      phase: JournalPhase.start,
      opId: opId,
      dataKeyEpoch: keyring.dataKeyEpoch,
      keyState: _keyStateSnapshot,
      note: 'migrate to remote dataKey (same vault)',
    );

    // migrateToRemote 返回新 Keyring，需要更新 self.keyring
    // 否则后续 _syncOnce 重试时仍用旧 keyring.dataKey 解密会失败
    try {
      keyring = await keyring.migrateToRemote(
        result: migrationResult,
        database: database,
      );
      // B2：迁移成功后把新 keyring 回写上层（SyncService._keyring），
      // 消除「改密码/迁移后上层持旧 keyring → 全库不可解」窗口
      onKeyringChanged?.call(keyring);
    } on Object catch (e, st) {
      // 记 failed，避免 start 悬挂被 findIncompleteOperations 误判为"需重放"
      Log.sync.e('_executeMigration: 迁移失败', error: e, stackTrace: st);
      journal.append(
        type: JournalEventType.keyMigrate,
        phase: JournalPhase.failed,
        opId: opId,
        note: 'migrateToRemote failed',
      );
      rethrow;
    }

    journal.append(
      type: JournalEventType.keyMigrate,
      phase: JournalPhase.done,
      opId: opId,
      dataKeyEpoch: keyring.dataKeyEpoch,
      keyState: _keyStateSnapshot,
      note: 'migrate to remote dataKey done',
    );

    // Q2a：dataKey 已变更，用新 key 重封重传 items.meta，
    // 保住「迁移后一切远端对象都用新 key」不变式（失败不阻断迁移）。
    await _uploadNoteMetaSnapshot('post-migration');

    // 读取迁移的笔记数量（用于结果统计）
    final notes = await database.readAllNotesIncludingDeleted();
    // P3-log：迁移出口（携带新纪元与笔记数，便于审计）
    Log.sync.i(
      '_executeMigration: 完成，迁移笔记数=${notes.length} '
      '(new epoch=${keyring.dataKeyEpoch})',
    );
    return notes.length;
  }

  /// 场景 d 迁移：调用 keyring.migrateToRemoteVault
  ///
  /// 与 [_executeMigration] 的区别：
  ///   - _executeMigration：同 keyring、dataKey 不同（他端改密码）
  ///   - _executeMigrationVault：不同 keyring、salt 不同（两设备独立 createNew）
  ///     需要更新本地 keyring 的全部元数据（kdf/keyFingerprint/keyVersion/createdAt）
  Future<int> _executeMigrationVault({
    required Uint8List remoteDataKey,
    required String remoteEncryptedDataKey,
    required String remoteVaultId,
    required KdfParams remoteKdf,
    required String remoteKeyFingerprint,
    required int remoteKeyVersion,
    required int remoteCreatedAt,
    required Uint8List remoteMk,
  }) async {
    // P3-log：scenario-d 入口（整库改嫁到远端 vault，风险最高的一步）
    Log.sync.i(
      '_executeMigrationVault: 开始 scenario-d 整库迁移 '
      '(vaultId=$remoteVaultId, keyVersion=$remoteKeyVersion)',
    );

    // P2 journal §3.6b 两段式（场景 d：整库改嫁到远端 vault，风险最高的一步）
    final opId = journal.newOpId();
    journal.append(
      type: JournalEventType.keyMigrate,
      phase: JournalPhase.start,
      opId: opId,
      dataKeyEpoch: keyring.dataKeyEpoch,
      keyState: _keyStateSnapshot,
      note: 'scenario-d: migrate to remote vault $remoteVaultId',
    );

    // migrateToRemoteVault 返回新 Keyring，需要更新 self.keyring
    try {
      keyring = await keyring.migrateToRemoteVault(
        remoteDataKey: remoteDataKey,
        remoteEncryptedDataKey: remoteEncryptedDataKey,
        remoteVaultId: remoteVaultId,
        remoteKdf: remoteKdf,
        remoteKeyFingerprint: remoteKeyFingerprint,
        remoteKeyVersion: remoteKeyVersion,
        remoteCreatedAt: remoteCreatedAt,
        remoteMk: remoteMk,
        database: database,
      );
      // B2：迁移成功后把新 keyring 回写上层（SyncService._keyring）
      onKeyringChanged?.call(keyring);
    } on Object catch (e, st) {
      // P3-log：scenario-d 迁移失败
      Log.sync.e(
        '_executeMigrationVault: scenario-d 迁移失败',
        error: e,
        stackTrace: st,
      );
      journal.append(
        type: JournalEventType.keyMigrate,
        phase: JournalPhase.failed,
        opId: opId,
        note: 'scenario-d migrate failed',
      );
      rethrow;
    }

    journal.append(
      type: JournalEventType.keyMigrate,
      phase: JournalPhase.done,
      opId: opId,
      dataKeyEpoch: keyring.dataKeyEpoch,
      keyState: _keyStateSnapshot,
      note: 'scenario-d migrate done',
    );

    // Q2a：dataKey 已变更，用新 key 重封重传 items.meta
    // （与 _executeMigration 尾部同理由；失败不阻断迁移）。
    await _uploadNoteMetaSnapshot('post-migration-vault');

    // 读取迁移的笔记数量（用于结果统计）
    final notes = await database.readAllNotesIncludingDeleted();
    // P3-log：scenario-d 出口
    Log.sync.i(
      '_executeMigrationVault: 完成，迁移笔记数=${notes.length} '
      '(new vaultId=$remoteVaultId, new epoch=${keyring.dataKeyEpoch})',
    );
    return notes.length;
  }

  /// 从本地数据库构建 manifest
  ///
  /// 包含所有笔记（含墓碑）。manifest 是全量的。
  /// 填充所有新增字段：keyFingerprint / keyVersion / schemaVersion / createdAt
  /// 以及 ManifestItem 的 updatedBy / createdAt / deletedAt / contentSize。
  ///
  /// F1 修复：过期墓碑（软删除超 30 天）不放入 manifest，硬删除本地记录
  /// 并加入 purgedUuids，让 _mergeAndTransfer 的 M1 逻辑阻止其从远端复活。
  /// PUT manifest 成功后远端墓碑也被清除，实现墓碑 GC。
  ///
  /// v4（epoch 消除）：不再有 override 三元组——header 恒用本地 keyring 值
  /// （本地包裹永远合法，只读不 echo 远端，§0）。scenario-b（他端改密码）在
  /// _syncOnce 即中止，不会走到这里。
  Future<Manifest> _buildLocalManifest() async {
    final notes = await database.readAllNotesIncludingDeleted();
    final items = <String, ManifestItem>{};
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final note in notes) {
      // F1 修复：过期墓碑 GC
      // 软删除超 30 天的墓碑不再放入 manifest，硬删除本地记录并加入 purgedUuids。
      // 风险：若本次 PUT 失败重试，本地墓碑已删但 purgedUuids 阻止复活，
      // 下次同步仍能正常清除远端墓碑。30 天阈值保证离线设备已同步到删除操作。
      if (note.deleted && (now - note.updatedAt) > kTombstoneGcThresholdMs) {
        await database.hardDeleteByUuid(note.uuid);
        continue;
      }
      items[note.uuid] = ManifestItem(
        hash: note.contentHash,
        deleted: note.deleted,
        updatedAt: note.updatedAt,
        updatedBy: deviceId,
        createdAt: note.createdTime.millisecondsSinceEpoch,
        deletedAt: note.deleted ? note.updatedAt : null,
        contentSize: note.toContentBytes().length,
        // v4（epoch 消除）：item 自描述字段恒为「当前 dataKey 指纹」——
        // 本地所有 blob 均由迁移单事务重加密为当前 dataKey（§4.1），
        // 声明即事实，不是乐观声明；解密端不比较、不纠正。
        // blobKeyEpoch 保留为「加密版本标签」纯审计元数据（§7.1）。
        blobKeyEpoch: keyring.dataKeyEpoch,
        dataKeyFingerprint: SyncCrypto.computeDataKeyFingerprint(_dataKey),
        createdBy: deviceId,
        dataKeyCreatedAt: keyring.createdAt,
        dataKeyCreatedBy: deviceId,
      );
    }
    final localVersion = await database.getManifestVersion(backend.providerKey);

    return Manifest(
      // P2 收敛：header 由 keyring 投影，字段完整性由 Keyring 单点保证
      // v4：不再 override（本地包裹恒合法，只读不 echo 远端，§0）；
      // schemaVersion 真值化（§7.1），显式写入当前协议版本
      header: keyring.toManifestHeader(
        schemaVersion: kManifestSchemaVersion,
        version: localVersion,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        lastModifiedBy: deviceId,
        dataKeyCreatedBy: deviceId,
      ),
      items: items,
    );
  }

  /// 比对本地与远端 manifest，执行传输，返回合并后的 manifest
  ///
  /// 这是同步的核心逻辑，处理 3 种情况：
  /// - 仅本地有 → 上传 blob
  /// - 仅远端有 → 下载 blob
  /// - 双方都有 → LWW 冲突解决
  ///
  /// M1 修复：待清理的 uuid（用户硬删除的笔记）会从 merged items 中移除，
  /// 这样下次 PUT manifest 后远端墓碑也被清除，硬删除真正永久生效。
  ///
  /// 返回值是记录类型：`merged` 为合并后的 manifest；`reuploadedOk` 为本轮
  /// 成功完成「密钥变更后强制重传」的 uuid 集合（供同步成功后从 pending 移除，
  /// P1 修复：失败项保留标记、下次继续重传）。
  Future<({Manifest merged, Set<String> reuploadedOk})> _mergeAndTransfer(
    Manifest local,
    Manifest? remote,
    List<SyncAction> actions,
  ) async {
    // P1-log：合并入口摘要（核心合并逻辑此前零日志，是诊断盲区）
    Log.sync.d(
      '_mergeAndTransfer start: '
      'local=${local.items.length} '
      'remote=${remote?.items.length ?? 0} '
      'purged=${(await database.getPurgedUuids()).length}',
    );

    // M1 修复：读取待清理的 uuid 列表（用户硬删除的笔记）
    final purgedUuids = await database.getPurgedUuids();
    final purgedSet = purgedUuids.toSet();

    // Layer 2a: 读取密钥变更后需强制重传 blob 的 uuid 集合。
    // 这些笔记的本地 DB 已用新 dataKey 重加密，但服务器 blob 可能仍是旧密钥，
    // 必须强制用新密钥重新 PUT 覆盖（即使 manifest hash 相同）。
    final pendingReupload = await database.getPendingReuploadUuids();
    // P1 修复：本轮成功重传的 uuid 集合（供同步成功后从 pending 中移除；
    // 失败的保留标记，下次同步继续强制重传）
    final reuploadedOk = <String>{};

    // 远端无 manifest：首次上传，直接用本地 manifest（移除待清理的）
    if (remote == null) {
      final notes = await database.readAllNotesIncludingDeleted();
      // P1 修复：记录上传失败的 uuid，从首次 manifest 中剔除，
      // 避免 manifest 引用从未成功上传的 blob（幽灵引用）；下次同步自动重试。
      final failedUploads = <String>{};
      for (final note in notes) {
        if (purgedSet.contains(note.uuid)) continue;
        if (!await _uploadNote(note, actions)) {
          failedUploads.add(note.uuid);
        }
      }
      final filteredItems = Map<String, ManifestItem>.from(local.items)
        ..removeWhere(
          (uuid, _) => purgedSet.contains(uuid) || failedUploads.contains(uuid),
        );
      return (
        merged: local.copyWithHeader(version: 1, items: filteredItems),
        reuploadedOk: reuploadedOk,
      );
    }

    // 双方都有 manifest：逐条比对
    final mergedItems = <String, ManifestItem>{};
    final allUuids = <String>{...local.items.keys, ...remote.items.keys};

    for (final uuid in allUuids) {
      final localItem = local.items[uuid];
      final remoteItem = remote.items[uuid];

      if (localItem == null && remoteItem != null) {
        // M1 修复：本地硬删除的笔记不要从远端重新下载
        // purgedSet 中的 uuid 是用户主动硬删除的，应从远端 manifest 清除，
        // 而不是重新下载回来。下面的 M1 cleanup 会从 mergedItems 中移除这些 uuid。
        if (purgedSet.contains(uuid)) {
          _addAction(
            actions,
            SyncAction(
              type: SyncActionType.skip,
              uuid: uuid,
              message: 'locally purged (hard-deleted on this device)',
            ),
          );
          continue;
        }
        // 仅远端有：下载（失败时仍保留 remoteItem 进 merged，见 D3 修复）
        final outcome = await _downloadNote(uuid, remoteItem, actions);
        if (outcome is _DownloadHealed) {
          // Layer 2b：自愈成功，manifest 改用本地修复后的 hash
          mergedItems[uuid] = outcome.healedItem;
        } else if (outcome is _DownloadSuccess && outcome.item != null) {
          mergedItems[uuid] = outcome.item!;
        } else {
          // D3 修复：下载失败（blob missing / 坏 blob 无本地明文）时保留
          // remoteItem 进 merged，避免下次 PUT manifest 后该条目从远端消失。
          // 这样下次同步时仍能重试下载（远端其他设备可能还未上传 blob）。
          mergedItems[uuid] = remoteItem;
        }
      } else if (localItem != null && remoteItem == null) {
        // M1 修复：本地硬删除的笔记不要重新上传
        // 正常情况下 hardDelete 后 readNoteByUuid 返回 null 不会走到这里，
        // 但为防止边缘情况（如笔记被重新下载后又在 purgedSet 中），加保护。
        if (purgedSet.contains(uuid)) {
          _addAction(
            actions,
            SyncAction(
              type: SyncActionType.skip,
              uuid: uuid,
              message: 'locally purged, skip upload',
            ),
          );
          continue;
        }
        // 仅本地有：上传
        final note = await database.readNoteByUuid(uuid);
        if (note != null) {
          // P1 修复：上传失败时不写入 merged——manifest 不引用失败 blob，
          // 下次同步「仅本地有」分支自动重试；写入了会成幽灵引用且永不重传。
          if (await _uploadNote(note, actions)) {
            mergedItems[uuid] = localItem;
          }
        }
        // note 已被硬删除：不加入 mergedItems（从 manifest 移除）
      } else if (localItem != null && remoteItem != null) {
        // 双方都有：判断是否一致
        if (_itemsEqual(localItem, remoteItem)) {
          if (pendingReupload.contains(uuid)) {
            // Layer 2a: 密钥已变更，即使 hash 相同也强制用新 dataKey 重传 blob，
            // 覆盖服务器上可能用旧密钥加密的残留 blob。
            final note = await database.readNoteByUuid(uuid);
            if (note != null) {
              // P1 修复：重传失败时保留待重传标记（不写入 reuploadedOk），
              // 下次同步继续强制重传，避免旧密钥 blob 永久残留。
              if (await _uploadNote(note, actions)) {
                reuploadedOk.add(uuid);
              }
            }
            mergedItems[uuid] = localItem;
          } else {
            // 完全一致：跳过
            mergedItems[uuid] = localItem;
            _addAction(
              actions,
              SyncAction(type: SyncActionType.skip, uuid: uuid),
            );
          }
        } else {
          // 不一致：用三方合并（base = synced_hash + synced_deleted）判定
          // 是 fast-forward（单边变更）还是真冲突（双方都偏离 base）。
          //
          // BUG-P0（三次修复，2026-08）：原实现 _itemsEqual 返回 false 即走
          // 「冲突：LWW 解决」分支并**无条件**记 conflict action。但单客户端
          // 删除/编辑已同步笔记时，远端从未改动，本属于 fast-forward，被误
          // 标为 conflict 导致：
          //   · 同步日志/journal 满屏 WARN，淹没真冲突
          //   · SyncResult.conflicts 计数虚高，UI 误报
          //   · docs/conflict-analysis-20260802.md 详述
          //
          // 正解：先算 localChanged/remoteChanged（含 deleted 维度——softDelete
          // 不改 content_hash，必须用 synced_deleted 才能识别本地删除为变更），
          // 据此三分流：
          //   1. localChanged && !remoteChanged → 本地单边变更，直接上传覆盖
          //   2. !localChanged && remoteChanged → 远端单边变更，直接下载
          //   3. 双方都偏离 base 或 base==null → 真冲突，沿用 LWW + 副本保留
          final localNote = await database.readNoteByUuid(uuid);
          final base = localNote?.syncedHash;
          final baseDeleted = localNote?.syncedDeleted ?? false;
          // base==null：本地无同步基线（新笔记 / 迁移前未同步）。保守视为双方
          // 都可能改过，退化为「内容不同即保留副本」——绝不丢数据（顶多多留一份，
          // 且仍要求双方活跃），也绝不复活删除。
          final localChanged =
              base == null ||
              localItem.hash != base ||
              localItem.deleted != baseDeleted;
          final remoteChanged =
              base == null ||
              remoteItem.hash != base ||
              remoteItem.deleted != baseDeleted;

          if (base != null && localChanged && !remoteChanged) {
            // Fast-forward：本地单边变更（编辑或删除），远端未动
            // 直接上传覆盖，不记 conflict。_uploadNote 内部对墓碑/普通笔记
            // 分别记 delete/upload action；失败时保留旧条目进 merged（P1 修复）。
            Log.sync.d(
              'fast-forward local: uuid=${_short(uuid)} '
              'base=${_short(base)} local=${_short(localItem.hash)} '
              'remote=${_short(remoteItem.hash)} '
              'deleted=${localItem.deleted}',
            );
            if (localNote != null) {
              if (await _uploadNote(localNote, actions)) {
                mergedItems[uuid] = localItem;
              } else {
                mergedItems[uuid] = remoteItem;
              }
            } else {
              // localNote 为 null（已被硬删除但未进 purgedSet 的边缘场景）：
              // 保留远端条目，避免本地无效状态污染 manifest。
              mergedItems[uuid] = remoteItem;
            }
          } else if (base != null && !localChanged && remoteChanged) {
            // Fast-forward：远端单边变更，本地未动
            // 直接下载覆盖，不记 conflict。_downloadNote 内部对远端墓碑/普通
            // 笔记分别记 delete/download action；失败时保留远端条目（D3 修复）。
            Log.sync.d(
              'fast-forward remote: uuid=${_short(uuid)} '
              'base=${_short(base)} local=${_short(localItem.hash)} '
              'remote=${_short(remoteItem.hash)} '
              'deleted=${remoteItem.deleted}',
            );
            final outcome = await _downloadNote(uuid, remoteItem, actions);
            if (outcome is _DownloadHealed) {
              mergedItems[uuid] = outcome.healedItem;
            } else if (outcome is _DownloadSuccess && outcome.item != null) {
              mergedItems[uuid] = outcome.item!;
            } else {
              mergedItems[uuid] = remoteItem;
            }
          } else {
            // 真冲突：双方都偏离 base，或 base==null（保守退化）
            // 沿用原 LWW + shouldPreserveCopy + conflict action 逻辑
            final winner = _resolveConflict(localItem, remoteItem);
            // P0-log：冲突判定三元组（排查虚假冲突的关键证据）
            // base/local/remote 三值若 base 不同于 local 且不同于 remote，
            // 说明双方都改过（真冲突）；若 base==remote 但仍判冲突，
            // 说明 syncedHash 被错误回退（虚假冲突）
            Log.sync.w(
              '⚡ conflict uuid=$uuid '
              'base=${_short(base)} '
              'local=${_short(localItem.hash)} '
              'remote=${_short(remoteItem.hash)} '
              'localChanged=$localChanged remoteChanged=$remoteChanged '
              '→ ${winner == localItem ? "local won" : "remote won"}',
            );
            // 保留副本四条缺一不可：
            //   1. 本地偏离 base（本地确实改过）
            //   2. 远端偏离 base（远端确实改过）—— 与 1 合起来才是「双方都改」的真并发
            //   3. 双方都活跃：一端删一端活是删除传播，交给 LWW，绝不另存副本
            //      （否则被删内容以新 uuid 复活并每端各复活一份 → 无限增殖）
            //   4. 内容确实不同：hash 相同则无败方内容需要保留
            final shouldPreserveCopy =
                localChanged &&
                remoteChanged &&
                !localItem.deleted &&
                !remoteItem.deleted &&
                localItem.hash != remoteItem.hash;
            if (shouldPreserveCopy) {
              await _preserveConflictCopy(
                uuid: uuid,
                winner: winner,
                localItem: localItem,
                remoteItem: remoteItem,
                actions: actions,
                mergedItems: mergedItems,
              );
            }
            if (winner == localItem) {
              // 本地胜：上传覆盖远端（复用上面已读的 localNote，避免二次读库）
              final note = localNote;
              if (note != null) {
                // P1 修复：上传失败时保留远端条目（旧的有效 blob）进 merged，
                // 避免该笔记从 manifest 消失（他端保留旧内容，无数据抖动）；
                // 下次同步 LWW 本地仍胜出 → 自动重试上传。
                if (await _uploadNote(note, actions)) {
                  mergedItems[uuid] = localItem;
                } else {
                  mergedItems[uuid] = remoteItem;
                }
              }
            } else {
              // 远端胜：下载覆盖本地
              final outcome = await _downloadNote(uuid, remoteItem, actions);
              if (outcome is _DownloadHealed) {
                // Layer 2b：远端 blob 损坏但本机有明文，自愈后 manifest 改用本地 hash
                mergedItems[uuid] = outcome.healedItem;
              } else if (outcome is _DownloadSuccess && outcome.item != null) {
                mergedItems[uuid] = outcome.item!;
              } else {
                // D3 修复：下载失败时保留 remoteItem 进 merged，不回滚到本地旧版本。
                // 原实现用 localItem 覆盖远端会导致远端较新数据被回滚。
                // 保留 remoteItem 让下次同步可重试下载，本地旧版本暂时保留不动。
                mergedItems[uuid] = remoteItem;
              }
            }
            _addAction(
              actions,
              SyncAction(
                type: SyncActionType.conflict,
                uuid: uuid,
                hash: winner.hash,
                message:
                    '${winner == localItem ? "local won" : "remote won"} '
                    '(LWW: ${winner == localItem ? "local" : "remote"} newer'
                    '${shouldPreserveCopy ? ', copy preserved' : ''}) '
                    'base=${_short(base)} '
                    'local=${_short(localItem.hash)} '
                    'remote=${_short(remoteItem.hash)}',
              ),
            );
          }
        }
      }
    }

    // M1 修复：从 merged items 中移除待清理的 uuid
    // 这些是用户硬删除的笔记，需要从远端 manifest 中清除墓碑
    if (purgedSet.isNotEmpty) {
      mergedItems.removeWhere((uuid, _) => purgedSet.contains(uuid));
    }

    final manifest = Manifest(
      // P2 收敛：header 由 keyring 投影（唯一出口）
      // v4：不再 override（本地包裹恒合法，只读不 echo 远端，§0）
      header: keyring.toManifestHeader(
        // v4：schemaVersion 真值化（§7.1），合并后 PUT 也写当前协议版本
        schemaVersion: kManifestSchemaVersion,
        version: remote.version + 1,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        lastModifiedBy: deviceId,
        dataKeyCreatedBy: deviceId,
      ),
      items: mergedItems,
    );
    // P1-log：合并出口摘要（与入口配对，诊断合并结果）
    Log.sync.d(
      '_mergeAndTransfer done: merged=${mergedItems.length} '
      'actions=${actions.length} '
      'reuploadedOk=${reuploadedOk.length} '
      'purged=${purgedSet.length}',
    );
    return (merged: manifest, reuploadedOk: reuploadedOk);
  }

  /// 判断两个 ManifestItem 是否完全一致（hash + deleted）
  ///
  /// 完全一致时跳过传输。注意：updatedAt 相同但 hash 不同不算一致（会走冲突流程）。
  bool _itemsEqual(ManifestItem a, ManifestItem b) {
    return a.hash == b.hash && a.deleted == b.deleted;
  }

  /// D3 修复：判断两个 ManifestItem 是否「语义等价」（用于决定是否需 PUT manifest）
  ///
  /// 与 [_itemsEqual] 不同，这里比较全部**影响数据语义**的字段，但**排除
  /// `updatedBy`**：`updatedBy` 记录的是「最后修改者设备」，多设备各自构建本地
  /// manifest 时该字段天然不同（每端都写自己的 deviceId）。若把它纳入比对，
  /// 任意两台设备每次同步都会判定「有变更」→ 无条件 PUT，导致：
  ///   1. manifest version 无限攀升（D3 修复在多设备下完全失效）
  ///   2. 审计信息被每次同步的设备覆盖，失去「最后修改者」语义
  ///   3. 多设备自动同步接近并发 PUT，ETag 冲突概率上升
  ///
  /// **v4（epoch 消除，§7.1）同样排除 `blobKeyEpoch` 与 v4 新增的自描述元数据**
  /// （`dataKeyFingerprint`/`createdBy`/`dataKeyCreatedAt`/`dataKeyCreatedBy`）：
  /// 各端加密时用的纪元/指纹天然可能不同（同一数据被不同端的 key 声明标记），
  /// 那是「标签不同」不是「内容有变更」。纳入比较会让两端声明不同标签时每次
  /// 同步判定「有变更」→ 无条件 PUT manifest（版本空涨 + ETag 竞争）。仅比对
  /// hash / deleted / 时间戳 / contentSize——这些才决定数据语义。
  bool _semanticItemsEqual(ManifestItem a, ManifestItem b) {
    return a.hash == b.hash &&
        a.deleted == b.deleted &&
        a.updatedAt == b.updatedAt &&
        a.createdAt == b.createdAt &&
        a.deletedAt == b.deletedAt &&
        a.contentSize == b.contentSize;
  }

  /// E1 修复：冲突副本保留
  ///
  /// 当冲突双方的 updatedAt 差值超过阈值（5 分钟）时，把败方内容另存为一条新笔记
  /// （新 UUID），避免 LWW 覆盖导致数据丢失。
  ///
  /// 流程：
  ///   - 败方是本地 → 读取本地笔记，生成新 UUID 存为新笔记，上传 blob，加入 merged
  ///   - 败方是远端 → 下载远端 blob，生成新 UUID 存为新笔记，上传 blob（新 hash），加入 merged
  ///
  /// 注意：此方法只是"额外保留一份败方副本"，不影响胜方的正常 LWW 覆盖流程。
  /// 调用方在调用此方法后仍需执行胜方的上传/下载逻辑。
  Future<void> _preserveConflictCopy({
    required String uuid,
    required ManifestItem winner,
    required ManifestItem localItem,
    required ManifestItem remoteItem,
    required List<SyncAction> actions,
    required Map<String, ManifestItem> mergedItems,
  }) async {
    final localIsWinner = winner == localItem;
    final loserItem = localIsWinner ? remoteItem : localItem;

    // 败方是墓碑：不保留副本（删除冲突不需要保留删除版本）
    if (loserItem.deleted) return;

    try {
      if (localIsWinner) {
        // 败方是远端：下载远端内容，存为新笔记
        // P3-a：getBlob 加重试退避（null 不重试，仅网络错误重试）
        final envelope = await _withBlobRetry(
          () => backend.getBlob(loserItem.hash),
          opName: 'getBlob(conflict-copy)',
          hash: loserItem.hash,
        );
        if (envelope == null) {
          // blob 不存在：无法保留副本，跳过
          return;
        }
        // Layer 1 容错：败方 blob 解密失败（错误 dataKey）时无法保留副本，跳过
        final plaintext = await _openBlobEnvelope(loserItem.hash, envelope);
        final content = SafeNote.fromContentBytes(plaintext);

        // 生成新笔记（新 UUID + 新 hash），保留原始创建时间。
        // 标题追加"(冲突副本 N)"：既让用户一眼分辨来源，也让 hash 与原件不同，
        // 从源头切断"同 hash 副本被反复卷入冲突判定"的链式增殖。
        final copyTitle = await _makeConflictCopyTitle(
          content.title,
          content.description,
        );
        final newNote = SafeNote(
          uuid: SafeNote.generateUuid(),
          title: copyTitle,
          description: content.description,
          contentHash: SafeNote.computeHash(copyTitle, content.description),
          createdTime: DateTime.fromMillisecondsSinceEpoch(loserItem.createdAt),
          updatedAt: DateTime.now().millisecondsSinceEpoch,
          synced: false,
        );

        // 存入本地数据库
        await database.storeNote(newNote);
        // 上传 blob（新 hash），标记为冲突副本以便上层（如混沌测试）识别。
        // P1 修复：上传失败时不写入 merged，避免幽灵引用；下次同步自动重试。
        if (await _uploadNote(
          newNote,
          actions,
          message: 'conflict-copy from $uuid',
        )) {
          // 加入 merged（新 UUID，远端败方副本）：补全 v5 自描述字段
          // （与 _buildLocalManifest 一致），解密失败时能精确区分「旧密钥
          // 数据」与「真损坏」，不误判。
          mergedItems[newNote.uuid] = ManifestItem(
            hash: newNote.contentHash,
            deleted: false,
            updatedAt: newNote.updatedAt,
            updatedBy: deviceId,
            createdAt: newNote.createdTime.millisecondsSinceEpoch,
            contentSize: newNote.toContentBytes().length,
            blobKeyEpoch: keyring.dataKeyEpoch,
            dataKeyFingerprint: SyncCrypto.computeDataKeyFingerprint(_dataKey),
            createdBy: deviceId,
            dataKeyCreatedAt: keyring.createdAt,
            dataKeyCreatedBy: deviceId,
          );
        }
      } else {
        // 败方是本地：读取本地笔记，生成新 UUID 存为新笔记
        final localNote = await database.readNoteByUuid(uuid);
        if (localNote == null) return;

        // 生成新笔记（新 UUID + 新 hash），保留原始创建时间和正文。
        // 标题追加"(冲突副本 N)"，理由同上：避免与原件 hash 碰撞后链式增殖。
        final copyTitle = await _makeConflictCopyTitle(
          localNote.title,
          localNote.description,
        );
        final newNote = SafeNote(
          uuid: SafeNote.generateUuid(),
          title: copyTitle,
          description: localNote.description,
          contentHash: SafeNote.computeHash(copyTitle, localNote.description),
          createdTime: localNote.createdTime,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
          synced: false,
        );

        // 更新本地数据库（新 UUID 的新笔记）
        await database.storeNote(newNote);
        // 上传 blob（新 hash），标记为冲突副本以便上层（如混沌测试）识别。
        // P1 修复：上传失败时不写入 merged，避免幽灵引用；下次同步自动重试。
        if (await _uploadNote(
          newNote,
          actions,
          message: 'conflict-copy from $uuid',
        )) {
          // 加入 merged（新 UUID，本地败方副本）：补全 v5 自描述字段（同上）
          mergedItems[newNote.uuid] = ManifestItem(
            hash: newNote.contentHash,
            deleted: false,
            updatedAt: newNote.updatedAt,
            updatedBy: deviceId,
            createdAt: newNote.createdTime.millisecondsSinceEpoch,
            contentSize: newNote.toContentBytes().length,
            blobKeyEpoch: keyring.dataKeyEpoch,
            dataKeyFingerprint: SyncCrypto.computeDataKeyFingerprint(_dataKey),
            createdBy: deviceId,
            dataKeyCreatedAt: keyring.createdAt,
            dataKeyCreatedBy: deviceId,
          );
        }
      }
      // P5 修复（DS002）：`on Exception` 捕获不住 `RangeError`（Error 子类，
      // 如截断的 blob 信封在 _openBlobEnvelope → envelope.sublist(0, 12) 抛出的
      // RangeError）。用 `on Object` 兜底，确保单条坏 blob 不炸掉整次同步，
      // 与 _downloadNote 的 Layer 1 容错语义一致。
    } on Object catch (e, st) {
      // 副本保留失败不阻断主同步流程，记录日志即可
      Log.sync.w(
        '_preserveConflictCopy: 冲突副本保留失败 uuid=$uuid',
        error: e,
        stackTrace: st,
      );
    }
  }

  /// 为冲突副本生成带序号的标题，确保内容 hash 不与本机既有笔记碰撞
  ///
  /// 背景（增殖缺陷根因）：早期实现直接复制原标题与正文，副本的 contentHash
  /// 与原件**完全相同**。由于 blob 按内容 hash 寻址、孪生自愈按 hash 反查笔记
  /// （`readNoteByContentHash` 是 limit:1 的 1:1 假设），同 hash 副本会不断被
  /// 冲突判定与孪生匹配重新卷入，副本再生副本，形成链式增殖。
  /// 实测曾出现一份内容对应 13 个活跃 uuid。
  ///
  /// 这里从 1 开始递增探测序号，直到该「标题+正文」组合的 hash 在本机
  /// （含墓碑）不存在为止，副本因此成为内容独立的实体。
  /// 附带收益：用户与调试者能一眼看出这是系统生成的冲突副本及其来源设备。
  ///
  /// 后缀必须带设备标识：多端会各自对同一个冲突生成副本，若只用序号，
  /// 每端都从 1 开始探测、在本机都不碰撞，同步汇合后却是同名同内容，
  /// hash 再次相同，增殖链并未真正切断（实测三端各生成一份"冲突副本 1"）。
  Future<String> _makeConflictCopyTitle(
    String baseTitle,
    String description,
  ) async {
    final dev = deviceId.length > 6 ? deviceId.substring(0, 6) : deviceId;
    for (var n = 1; n <= 99; n++) {
      final candidate = '$baseTitle (冲突副本 $n·$dev)';
      final hash = SafeNote.computeHash(candidate, description);
      if (!await database.existsContentHash(hash)) return candidate;
    }
    // 极端兜底：99 个序号全部碰撞时退化为时间戳，保证唯一性优先
    return '$baseTitle (冲突副本 $dev-${DateTime.now().millisecondsSinceEpoch})';
  }

  /// LWW 冲突解决：返回胜出的 item
  ///
  /// 规则：
  ///   1. updatedAt 大的胜（更新时间晚的覆盖早的）
  ///   2. updatedAt 相同但 hash 不同：保留 hash 字典序小的（兜底，避免无限冲突）
  ManifestItem _resolveConflict(ManifestItem local, ManifestItem remote) {
    if (remote.updatedAt > local.updatedAt) return remote;
    if (remote.updatedAt < local.updatedAt) return local;
    // updatedAt 相同：保留 hash 字典序小的
    return remote.hash.compareTo(local.hash) < 0 ? remote : local;
  }

  /// 上传单条笔记的 blob 到远端
  ///
  /// 墓碑不需要 blob（只在 manifest 里标记 deleted=true）。
  /// 非墓碑：加密笔记内容为 envelope，PUT 到 blobs/`<hash>`。
  ///
  /// 返回是否成功：
  ///   - 墓碑：视为成功（manifest 只引用标记，无 blob 依赖）
  ///   - 非墓碑上传成功：true
  ///   - blob 上传失败（网络/存储/其他异常）：false，并记录
  ///     [SyncActionType.uploadFailed] action
  ///
  /// P1 修复（幽灵引用）：调用方必须根据返回值决定是否把该条目写入 merged
  /// manifest——上传失败时写入会在 manifest 里产生一个**从未成功上传的 blob 引用**
  /// （其他设备拉取时 404 → 永久 corrupt），且失败无重试路径。返回值让调用方
  /// 在上传失败时跳过该条目，下次同步自动重试。
  Future<bool> _uploadNote(
    SafeNote note,
    List<SyncAction> actions, {
    String? message,
  }) async {
    if (note.deleted) {
      // 墓碑：不传 blob，只在 manifest 里标记
      _addAction(
        actions,
        SyncAction(
          type: SyncActionType.delete,
          uuid: note.uuid,
          message: 'tombstone (no blob)',
        ),
      );
      return true;
    }

    // 加密笔记内容为 envelope（Layer 1：单个 blob 上传失败不应中断整次同步）
    //
    // AAD 使用内容 hash（blob 纯化 v4：AAD=hash，不再携带 epoch）。
    // 原因：blob 按内容 hash 去重，两条内容相同的笔记共享同一个 blob 文件；
    // 若 AAD 绑定 uuid，则该 blob 只能被"上传者的 uuid"解开，
    // 其他引用同一 hash 的笔记在别的设备上永远解密失败（GCM tag 不匹配）。
    // AAD=hash 后任何引用该 hash 的笔记都能解开；防信封错位由下载侧的
    // "解密内容 hash == manifest 记录 hash"校验保证（manifest items 本身
    // 由 dataKey 加密认证，服务器无法伪造）。
    try {
      final envelope = await SyncCrypto.seal(
        _dataKey,
        note.contentHash,
        note.toContentBytes(),
      );
      // P3-a：putBlob 加重试退避，吸收瞬时网络抖动；幂等覆盖写，重试安全
      await _withBlobRetry(
        () => backend.putBlob(note.contentHash, envelope),
        opName: 'putBlob',
        hash: note.contentHash,
      );
    } on BackendUnavailableException catch (e, st) {
      // 网络/存储不可用（可重试）
      Log.sync.w(
        'uploadNote: blob 上传失败（后端不可用）uuid=${note.uuid}',
        error: e,
        stackTrace: st,
      );
      _addAction(
        actions,
        SyncAction(
          type: SyncActionType.uploadFailed,
          uuid: note.uuid,
          hash: note.contentHash,
          message: 'blob 上传失败（网络/存储错误），将重试',
          error: NetworkError(
            operation: 'putBlob',
            noteUuid: note.uuid,
            cause: e,
            stackTrace: st,
            // T-23：跟随异常的 retryable 语义，认证失效不再标记为可重试
            retryable: e.retryable,
          ),
        ),
      );
      return false;
    } on Object catch (e, st) {
      // 其他异常（加密失败、序列化错误等），记录详细堆栈便于排查
      Log.sync.e(
        'uploadNote: blob 上传未预期异常 uuid=${note.uuid}',
        error: e,
        stackTrace: st,
      );
      _addAction(
        actions,
        SyncAction(
          type: SyncActionType.uploadFailed,
          uuid: note.uuid,
          hash: note.contentHash,
          message: 'blob 上传失败（${e.runtimeType}），将重试',
          error: UnexpectedError(
            operation: 'putBlob',
            noteUuid: note.uuid,
            cause: e,
            stackTrace: st,
          ),
        ),
      );
      return false;
    }

    _addAction(
      actions,
      SyncAction(
        type: SyncActionType.upload,
        uuid: note.uuid,
        hash: note.contentHash,
        message: message,
      ),
    );
    return true;
  }

  /// 解密 blob 信封（blob 纯化 v4：AAD=hash，无纪元）
  ///
  /// AAD = hash（用 blob 自己的内容 hash 解开，与「当前 dataKey 纪元」无关）。
  /// 解密失败向上抛出（调用方进入 Layer 1/2b 容错自愈流程）。
  ///
  /// [dataKeyOverride] 可选：用指定的 dataKey 解密（默认当前 _dataKey）。
  Future<Uint8List> _openBlobEnvelope(
    String hash,
    Uint8List envelope, {
    Uint8List? dataKeyOverride,
  }) async {
    final key = dataKeyOverride ?? _dataKey;
    return await SyncCrypto.open(key, hash, envelope);
  }

  /// 从远端下载单条笔记并写入本地数据库
  ///
  /// 返回 [_DownloadOutcome]：
  ///   - [_DownloadSuccess]：下载并写入成功（[item] 为被采用的 manifest 条目，
  ///     墓碑场景为 null）
  ///   - [_DownloadHealed]：远端 blob 损坏，但本机持有明文并自愈重传成功；
  ///     此时 manifest 应改用本地明文对应的 hash，否则修复后的 blob 会成为孤儿
  ///   - [_DownloadFailed]：blob 缺失或解密失败且无本地明文可自愈
  ///     （保留远端条目供下次重试）
  ///
  /// 墓碑（item.deleted）：只标记本地为软删除，不需要下载 blob，视为成功。
  ///
  /// 设计要点（Layer 1 + Layer 2b）：
  ///   cryptography 包的 InvalidTag 继承自 Error 而非 Exception，
  ///   故解密处用 `on Object` 兜底，确保单个坏 blob 不中断整次同步。
  Future<_DownloadOutcome> _downloadNote(
    String uuid,
    ManifestItem item,
    List<SyncAction> actions,
  ) async {
    if (item.deleted) {
      // 远端是墓碑：本地也标记为软删除
      final local = await database.readNoteByUuid(uuid);
      // 仅在真正产生本地变更（本地存在且未删除）时记录 delete action：
      // 本地无此笔记或已是墓碑时无状态要改，不记 action → 无变更同步可跳过 PUT
      // （否则墓碑条目在远端 manifest 存续期间，每台设备每次同步都判定"有变更"
      //   而空转 PUT，version 无意义递增 + ETag 竞争 + backup/journal 冗余）。
      if (local != null && !local.deleted) {
        await database.updateNoteByUuid(
          local.copyWith(
            deleted: true,
            updatedAt: item.updatedAt,
            synced: true,
          ),
        );
        _addAction(
          actions,
          SyncAction(
            type: SyncActionType.delete,
            uuid: uuid,
            message: 'remote tombstone applied',
          ),
        );
      }
      return const _DownloadSuccess();
    }

    // 下载 blob
    // P3-a：getBlob 加重试退避（null 不重试，仅网络错误重试）
    final envelope = await _withBlobRetry(
      () => backend.getBlob(item.hash),
      opName: 'getBlob(download)',
      hash: item.hash,
    );
    if (envelope == null) {
      // P0-4 修复：blob 在远端缺失（被静默删除/损坏）时，先尝试本机明文兜底重传。
      // 本机持有该笔记的明文（同 uuid 且内容 hash 一致，或同内容孪生）→ 用当前
      // 密钥重新上传，恢复远端缺失的 blob，本次视为自愈成功。
      // 注意：只有内容 hash 与 item.hash 一致时才兜底，避免并发编辑导致本地 uuid
      // 笔记内容已变时把错误内容写回远端 blob（自愈方向错误）。
      final local = await database.readNoteByUuid(uuid);
      final canHealLocal =
          local != null && !local.deleted && local.contentHash == item.hash;
      final twin = canHealLocal
          ? null
          : await database.readNoteByContentHash(item.hash);
      final source = canHealLocal ? local : twin;
      if (source != null && !source.deleted) {
        // P1 修复：自愈重传失败时不声明 heal（避免 healedItem 引用缺失 blob
        // 成为幽灵引用），退化为「blob missing」跳过、下次同步重试。
        if (await _uploadNote(source, actions)) {
          _addAction(
            actions,
            SyncAction(
              type: SyncActionType.heal,
              uuid: uuid,
              hash: item.hash,
              message: (local != null && local.uuid == uuid)
                  ? 'download: blob 缺失，本机有明文重传修复'
                  : 'download: blob 缺失，本机有同内容孪生重传修复',
            ),
          );
          // 自愈成功：重传后 item.hash 对应的 blob 已恢复，保留 item 进 merged
          return _DownloadHealed(item);
        }
      }
      // blob 不存在且本机无可用明文：可能是其他设备还没上传完，跳过本次
      _addAction(
        actions,
        SyncAction(
          type: SyncActionType.skip,
          uuid: uuid,
          hash: item.hash,
          message: 'blob missing on remote (will retry next sync)',
        ),
      );
      return _DownloadFailed(uuid);
    }

    // 解密（blob 纯化 v4：AAD=hash，解密只问「dataKey 对不对」）
    // 不再探测/比较 epoch（_probeBlobEpoch 已删）：用当前 dataKey 直接 open，
    // 能解开即当前 key，解不开进入 _handleDownloadFailure 自愈/失败流程。
    // 删除的 heal 分支曾「用当前纪元重传覆盖他人数据」——正是翻转事故的
    // 制度性根源（见 docs/epoch-elimination-design-20260801.md §5.4）。
    try {
      final plaintext = await _openBlobEnvelope(item.hash, envelope);
      final content = SafeNote.fromContentBytes(plaintext);

      // M7 修复：校验解密后内容的 hash 与 manifest 中记录的 hash 一致
      // 防止服务端返回"对的上 uuid、但内容不同"的合法信封
      // 注意：hash 计算使用 SafeNote.computeHash（title\ndescription 格式），
      // 而不是 SyncCrypto.sha256Hex(plaintext)（JSON 字节格式），两者不一致。
      // 前者是 blob 身份的唯一来源，改口径会让存量 blob 全部失联；
      // 不变量见 test/sync/blob_addressing_test.dart。
      final actualHash = SafeNote.computeHash(
        content.title,
        content.description,
      );
      if (actualHash != item.hash) {
        // 内容 hash 与 manifest 记录不符：blob 内容被篡改/错位（能解密但内容不对）。
        // 这不是密钥问题，不走 _handleDownloadFailure 的自愈/失败流程；
        // 按原 HEAD 行为记为 skip 并保留远端条目供下次重试（M7 回归契约）。
        Log.sync.w(
          'blob 内容 hash 校验失败: uuid=$uuid '
          'expected=${_short(item.hash)} '
          'actual=${_short(actualHash)}',
        );
        journal.append(
          type: JournalEventType.noteHeal,
          phase: JournalPhase.failed,
          uuid: uuid,
          hash: item.hash,
          dataKeyEpoch: keyring.dataKeyEpoch,
          note:
              'blob hash mismatch: expected=${_short(item.hash)} '
              'actual=${_short(actualHash)} (content tampered)',
        );
        _addAction(
          actions,
          SyncAction(
            type: SyncActionType.skip,
            uuid: uuid,
            hash: item.hash,
            message: 'blob 内容 hash 校验失败（内容被篡改），跳过',
          ),
        );
        return _DownloadFailed(uuid);
      }

      // 写入本地数据库（upsert）
      // R10 修复：用 remoteItem.createdAt 保留原始创建时间，
      // 而非用下载时刻 DateTime.now()
      final existing = await database.readNoteByUuid(uuid);
      final note = SafeNote(
        id: existing?.id,
        uuid: uuid,
        title: content.title,
        description: content.description,
        contentHash: item.hash,
        deleted: false,
        createdTime:
            existing?.createdTime ??
            DateTime.fromMillisecondsSinceEpoch(item.createdAt),
        updatedAt: item.updatedAt,
        synced: true,
      );
      if (existing == null) {
        await database.storeNote(note);
      } else {
        // 版本捕获：同步覆盖前保存本地内容快照
        // contentHash 去重由 saveVersion 内部处理，内容未变时自动跳过
        if (!existing.deleted) {
          await database.saveVersion(existing);
        }
        await database.updateNoteByUuid(note);
      }

      _addAction(
        actions,
        SyncAction(type: SyncActionType.download, uuid: uuid, hash: item.hash),
      );
      return _DownloadSuccess(item);
    } on SyncDecryptionException catch (e, st) {
      // Layer 1 容错：解密失败（坏 blob、错误 dataKey）
      // 不应中断整次同步。转交自愈逻辑处理（本地有明文则重传覆盖，否则记录失败）。
      Log.sync.w(
        'downloadNote: blob 解密失败，进入自愈流程 '
        'uuid=$uuid hash=${_short(item.hash)}',
        error: e,
        stackTrace: st,
      );
      final healed = await _handleDownloadFailure(uuid, item, actions);
      return healed != null ? _DownloadHealed(healed) : _DownloadFailed(uuid);
    } on Object catch (e, st) {
      // 其他异常（解析/校验失败/数据损坏），记录详细堆栈后进入自愈流程
      Log.sync.e('downloadNote: 下载未预期异常 uuid=$uuid', error: e, stackTrace: st);
      final healed = await _handleDownloadFailure(uuid, item, actions);
      return healed != null ? _DownloadHealed(healed) : _DownloadFailed(uuid);
    }
  }

  /// 下载失败的统一处理（Layer 1 容错 + Layer 2b 自愈）
  ///
  /// 触发场景：blob 解密失败（错误 dataKey / 数据损坏）或解密后 hash 校验不一致。
  ///
  /// 处理策略：
  ///   - 若本机数据库持有该 uuid 的明文副本 → 用当前 _dataKey 重新加密并上传，
  ///     覆盖服务器上的坏 blob（自愈）。自愈成功后返回修复后的 [ManifestItem]
  ///     （hash 取本地明文 hash，使合并后的 manifest 指向修复后的 blob），
  ///     记为 [SyncActionType.heal]，不计入失败列表。
  ///   - 若本机无该 uuid 的明文，但存在内容相同的孪生笔记
  ///     （content_hash == remoteItem.hash，共享 blob 去重场景）→
  ///     用孪生明文物化该 uuid 并按当前协议（AAD=hash）重传 blob（去重自愈）。
  ///   - 若本机无明文（该笔记从未在本机创建/下载过）→ 无法自愈，记为
  ///     [SyncActionType.corrupt] 并保留远端条目（mergedItems 中保留 remoteItem），
  ///     下次同步继续重试下载；该 uuid 进入 [SyncResult.failedNoteUuids]。
  ///
  /// 无论哪种情况都不抛异常，保证单个坏 blob 不中断整次同步。
  ///
  /// 返回：自愈成功时为修复后的 [ManifestItem]；否则为 null。
  Future<ManifestItem?> _handleDownloadFailure(
    String uuid,
    ManifestItem remoteItem,
    List<SyncAction> actions,
  ) async {
    // Layer 2b: 本机持有明文 → 自愈重传
    //
    // F-H02 修复：必须校验本机明文 hash 与远端条目一致，才允许自愈重传。
    // 否则本机旧内容会把旧 blob 覆盖远程新内容并整体改写索引，
    // 绕过 shouldPreserveCopy，丢失远端 LWW 胜者（与 _downloadNote/_repairRemote 对齐）。
    final local = await database.readNoteByUuid(uuid);
    if (local != null &&
        !local.deleted &&
        local.contentHash == remoteItem.hash) {
      try {
        // P1 修复：自愈重传失败不声明 heal（避免 healedItem 引用缺失 blob
        // 成为幽灵引用），退化为下方失败处理。
        if (await _uploadNote(local, actions)) {
          _addAction(
            actions,
            SyncAction(
              type: SyncActionType.heal,
              uuid: uuid,
              hash: local.contentHash,
              message: 'blob 密钥不匹配，已用本机明文自愈重传',
            ),
          );
          // 返回修复后的 manifest 条目：hash 取本地明文 hash，
          // 使合并后的 manifest 指向刚重传的（好）blob，避免修复后的 blob 成孤儿。
          // v4：blob 纯化后 blobKeyEpoch 是纯审计元数据，自愈重传不改写声明（§4）。
          //
          // §6.3 修订 3：补全自描述字段（与 _buildLocalManifest 一致）。
          // heal 后的条目必须携带 dataKeyFingerprint，否则 §5.3 验证矩阵的
          // 「密钥不匹配」判据在 heal 路径上失效——无法归因"旧 key vs 真损坏"。
          return ManifestItem(
            hash: local.contentHash,
            deleted: false,
            updatedAt: local.updatedAt,
            updatedBy: deviceId,
            createdAt: local.createdTime.millisecondsSinceEpoch,
            contentSize: local.toContentBytes().length,
            dataKeyFingerprint: SyncCrypto.computeDataKeyFingerprint(_dataKey),
            createdBy: deviceId,
            dataKeyCreatedAt: keyring.createdAt,
            dataKeyCreatedBy: deviceId,
          );
        }
      } on Object catch (e, st) {
        // 自愈上传也失败：退化为记录失败，不抛
        Log.sync.e(
          'handleDownloadFailure: 本机明文自愈重传失败 uuid=$uuid',
          error: e,
          stackTrace: st,
        );
      }
    }

    // 去重自愈：本机没有该 uuid 的明文，但可能存在"内容相同"的孪生笔记。
    //
    // 场景：blob 按内容 hash 寻址去重，两条内容相同的笔记（不同 uuid）
    // 共享同一个 blob；若本机恰好持有内容相同的孪生笔记
    // （content_hash == remoteItem.hash），则：
    //   1. 用孪生明文在本地物化该 uuid 的笔记（保留远端时间戳元数据）；
    //   2. 用当前 dataKey 重传 blob（blob 纯化 v4：AAD=hash），让所有设备都能解开。
    if (!remoteItem.deleted) {
      try {
        final twin = await database.readNoteByContentHash(remoteItem.hash);
        if (twin != null) {
          // 1) 物化：以孪生内容 + 远端元数据落地该 uuid 的笔记
          final existing = await database.readNoteByUuid(uuid);
          final materialized = SafeNote(
            id: existing?.id,
            uuid: uuid,
            title: twin.title,
            description: twin.description,
            contentHash: remoteItem.hash,
            deleted: false,
            createdTime:
                existing?.createdTime ??
                DateTime.fromMillisecondsSinceEpoch(remoteItem.createdAt),
            updatedAt: remoteItem.updatedAt,
            synced: true,
          );
          if (existing == null) {
            await database.storeNote(materialized);
          } else {
            await database.updateNoteByUuid(materialized);
          }

          // 2) 重传 blob（_uploadNote 用当前 dataKey + AAD=hash，重传后全网可解）。
          //    P1 修复：重传失败不声明 heal（避免引用缺失 blob），
          //    退化为下方失败处理，下次同步重试。
          if (await _uploadNote(materialized, actions)) {
            _addAction(
              actions,
              SyncAction(
                type: SyncActionType.heal,
                uuid: uuid,
                hash: remoteItem.hash,
                message: '共享 blob 解密失败，已用本机同内容孪生笔记自愈',
              ),
            );
            // hash 不变（内容相同），保留远端条目即可正确引用重传后的 blob。
            // v4：blob 纯化后 blobKeyEpoch 是纯审计元数据，自愈重传不改写声明（§4）。
            return remoteItem;
          }
        }
      } on Object catch (e, st) {
        // 孪生自愈失败：退化为记录失败，不抛
        Log.sync.e(
          'handleDownloadFailure: 孪生笔记自愈重传失败 uuid=$uuid',
          error: e,
          stackTrace: st,
        );
      }
    }

    // 无本地明文可用：记录失败，保留远端条目供下次重试。
    // v4（epoch 消除 §8.2[D]）用「dataKey 指纹」本地精确判定「旧 key vs 损坏」，
    // 替代旧的 epoch 比较（item 声明本身可错，纪元比较会误分类——正是历史事故
    // 「声明 epoch2、blob 实为 epoch1」的教训）：
    //   - item.dataKeyFingerprint 非空且 == 当前指纹 → 本应能解，解不开 = 真损坏
    //   - item.dataKeyFingerprint 非空且 != 当前指纹 → 旧密钥数据，提示修复线索
    //   - 字段为空（旧协议 manifest 无此字段）→ 无判定依据，按损坏保守处理
    // 两种情况均记入 failedNoteUuids，UI 提示用户运行「修复同步数据」；
    // 均只读提示，绝不自动重传（§0 / §3.2 第 1 条业界共识）。
    final currentFp = SyncCrypto.computeDataKeyFingerprint(_dataKey);
    final declaredFp = remoteItem.dataKeyFingerprint;
    final isOldKey = declaredFp.isNotEmpty && declaredFp != currentFp;
    final keyInfo = declaredFp.isNotEmpty
        ? (remoteItem.dataKeyCreatedBy ?? '未知设备') +
              (remoteItem.dataKeyCreatedAt != null
                  ? ' @ ${DateTime.fromMillisecondsSinceEpoch(remoteItem.dataKeyCreatedAt!).toIso8601String()}'
                  : '')
        : '未知来源';
    _addAction(
      actions,
      SyncAction(
        type: SyncActionType.corrupt,
        uuid: uuid,
        hash: remoteItem.hash,
        message: isOldKey
            ? 'blob 由更早的密钥加密（dataKey 指纹不符，由 $keyInfo），'
                  '无本地明文，需输旧密码或运行修复'
            : 'blob 下载失败（数据损坏且无本地明文，将重试）',
      ),
    );
    return null;
  }

  /// 从操作记录中提取"未能同步且无本地明文可自愈"的笔记 uuid 列表
  ///
  /// P1 修复：除下载失败的 [SyncActionType.corrupt] 外，同时纳入上传失败的
  /// [SyncActionType.uploadFailed]——两者都是「本地与他端未能收敛」的笔记，
  /// 都应进入 [SyncResult.failedNoteUuids] 供 UI 提示用户处理/重试。
  List<String> _failedUuids(List<SyncAction> actions) => actions
      .where(
        (a) =>
            a.type == SyncActionType.corrupt ||
            a.type == SyncActionType.uploadFailed,
      )
      .map((a) => a.uuid)
      .toSet()
      .toList();

  /// 同步完成后更新本地状态
  ///
  /// - 写入 manifest version 到 sync_meta 表
  /// - 标记本轮真正收敛的笔记为已同步（synced=1）
  /// - 清理已从远端 manifest 移除的墓碑 uuid（M1 修复）
  ///
  /// P1-A 修复（白名单模式，docs/conflict-analysis-20260802.md §P1-A）：
  ///   原实现 [NotesDatabase.markAllSyncedExcept] 是全量 UPDATE（NOT IN exclude），
  ///   会把同步期间被用户编辑的笔记也一并标记 synced=1 并把 synced_hash 写成
  ///   「远端没有的新 hash」。下次同步 fast-forward 远端单边会把远端旧内容下载
  ///   覆盖本地新编辑 → 丢数据。
  ///
  ///   现判据：只 markSynced 那些「当前 (content_hash, deleted) == merged.items[uuid]」
  ///   的笔记。merged 基于同步开始的本地快照构建，同步期间被改的笔记当前 hash
  ///   ≠ merged → 跳过，保持 synced=0、synced_hash=旧 base，下次同步重新处理。
  ///   下载覆盖的笔记 _downloadNote 已把本地 DB 更新为远端内容 → 当前 == merged → 标记。
  ///
  /// [excludeSynced]：本轮「上传失败」的笔记 uuid 集合。即便它们的当前状态
  /// 碰巧等于 merged（理论上不会，但兜底），也排除——本地是新内容、远端是旧内容，
  /// 未真正收敛，不能标记 synced=1（DS002 P6）。
  Future<void> _updateLocalState(
    Manifest merged, {
    Set<String> excludeSynced = const {},
  }) async {
    await database.setManifestVersion(backend.providerKey, merged.version);

    // 按白名单逐条比对，只标记真正收敛的 uuid
    final localNotes = await database.readAllNotesIncludingDeleted();
    final converged = <String>{};
    for (final note in localNotes) {
      if (excludeSynced.contains(note.uuid)) continue;
      final item = merged.items[note.uuid];
      if (item == null) continue; // 已从 manifest 移除（purged 等）
      // 当前 (hash, deleted) == merged 期望值 → 本轮真正收敛
      if (note.contentHash == item.hash && note.deleted == item.deleted) {
        converged.add(note.uuid);
      }
      // 否则：同步期间被编辑（当前 ≠ merged 快照）→ 跳过，下次同步重传
    }
    // P0-log + P0-journal：converged 中每个笔记的 syncedHash 刷新值
    // 排查虚假冲突的关键：若某笔记的 syncedHash 未被正确刷新到收敛值，
    // 下次同步会误判为冲突。只对 syncedHash 实际发生变化的条目打日志和
    // journal（避免稳态噪音）。
    for (final note in localNotes) {
      if (!converged.contains(note.uuid)) continue;
      final item = merged.items[note.uuid];
      if (item != null && note.syncedHash != item.hash) {
        final oldHash = _short(note.syncedHash);
        final newHash = _short(item.hash);
        Log.sync.d(
          'markSynced: uuid=${_short(note.uuid)} '
          'syncedHash $oldHash → $newHash',
        );
        journal.append(
          type: JournalEventType.noteUpsert,
          uuid: note.uuid,
          hash: item.hash,
          dataKeyEpoch: keyring.dataKeyEpoch,
          note: 'markSynced: syncedHash $oldHash → $newHash',
        );
      }
    }

    await database.markSyncedForUuids(converged);

    // M1 修复：清理已从远端 manifest 移除的 uuid
    // merged.items 中已不包含这些 uuid（_mergeAndTransfer 中已移除）
    // 本次 PUT manifest 成功 → 远端已确认清理 → 从本地待清理列表移除
    final purged = await database.getPurgedUuids();
    if (purged.isNotEmpty) {
      final cleaned = purged
          .where((uuid) => !merged.items.containsKey(uuid))
          .toList();
      if (cleaned.isNotEmpty) {
        await database.removePurgedUuids(cleaned);
      }
    }

    // P3-log：本地状态落地结果（同步流程的最后一步，决定哪些笔记被标记 synced）
    // debug 级，避免稳态噪音；converged < localNotes 时可能同步期间被编辑，
    // 调试时可据此判断 P1-A 白名单逻辑是否正常工作
    final excluded = localNotes.length - converged.length;
    Log.sync.d(
      '_updateLocalState: version=${merged.version}, '
      'local=${localNotes.length}, converged=${converged.length}, '
      'skipped=$excluded (excluded=${excludeSynced.length}, '
      'purged=${purged.where((u) => !merged.items.containsKey(u)).length})',
    );
  }

  /// F1 修复：孤儿 blob 垃圾回收
  ///
  /// manifest PUT 成功后调用。流程：
  ///   1. listBlobs() 获取远端所有 blob hash
  ///   2. merged.items 中的 hash 集合 = 当前引用的 blob
  ///   3. 远端有但 manifest 不引用的 = 孤儿 blob，两阶段确认后软删除到隔离区
  ///
  /// P2 修复（DS002，两阶段 GC）：并发同步下 A 设备的 listBlobs 可能包含
  /// 「B 设备刚 putBlob、尚未 putManifest」的 blob。若单次观察就隔离，
  /// B 随后提交的 manifest 会引用一个已进隔离区的 blob（他端 404，且 hash
  /// 相同导致 `_itemsEqual` 跳过、B 永不重传——注释曾声称的「putBlob 幂等
  /// 恢复路径」不存在）。
  ///
  /// 两阶段方案（候选观察制）：
  ///   - 首次观察：只把孤儿 hash 登记进本地候选表（DB meta，hash→首次观察时间），
  ///     **不隔离**——给他端一个完整同步周期的窗口把 blob 提交进 manifest；
  ///   - 连续第二次观察仍为孤儿：才 deleteBlobSoft 隔离。
  ///   - 候选变成引用（他端 manifest 落地）或被删除后：从候选表清除。
  /// 这使「正在上传」的 blob 至少获得一个同步周期保护，误隔离窗口从「同一次
  /// 同步内」缩小到「他端跨越两次本端同步仍未提交 manifest」的极端情况。
  ///
  /// 安全性：
  ///   - listBlobs 返回空（后端不支持枚举）时跳过 GC，保守不删
  ///   - 单个 blob 删除失败不阻断整体 GC
  ///   - 整体 GC 失败不阻断同步（下次同步重试）
  ///
  /// P1-2 修复：孤儿 blob 不再立即物理删除，而是软删除到隔离区（deleteBlobSoft），
  /// 保留 [_orphanRetention] 后才由 purgeOrphans 彻底删除，避免"误删其他设备 blob
  /// / blob 静默损坏后才发现"的不可逆损失。
  Future<void> _gcOrphanBlobs(Manifest merged) async {
    try {
      final remoteBlobs = await backend.listBlobs();
      if (remoteBlobs.isEmpty) return; // 后端不支持枚举，跳过 GC

      // 当前 manifest 引用的所有 blob hash
      final referenced = <String>{};
      for (final item in merged.items.values) {
        // 墓碑没有 blob（deleted=true 时不引用 blob）
        if (!item.deleted) {
          referenced.add(item.hash);
        }
      }

      // 孤儿 = 远端有但 manifest 不引用的
      final orphans = remoteBlobs.where((h) => !referenced.contains(h)).toSet();

      // P3-log：GC 入口与扫描结果（GC 是删除远端数据的唯一路径，必须留痕）
      Log.sync.i(
        '_gcOrphanBlobs: 扫描完成 '
        '(remote=${remoteBlobs.length}, referenced=${referenced.length}, '
        'orphans=${orphans.length})',
      );

      // 两阶段 GC：更新候选表
      final candidates = await database.getGcOrphanCandidates();
      final now = DateTime.now().millisecondsSinceEpoch;
      // 下一轮候选 = 本轮孤儿（保留首见时间；新候选记为当前时间）
      final nextCandidates = <String, int>{
        for (final h in orphans) h: candidates[h] ?? now,
      };
      // 清理已不再是孤儿的候选（他端已把 blob 提交进 manifest / 已删除）
      nextCandidates.removeWhere((h, _) => !orphans.contains(h));
      await database.setGcOrphanCandidates(nextCandidates);

      // 本轮隔离 = 上一轮已是候选、本轮仍为孤儿（连续两次观察）
      final toQuarantine = <String>{
        for (final h in orphans)
          if (candidates.containsKey(h)) h,
      };
      // 已隔离的 hash 从候选表移除：若将来他端重传同名 blob，会重新获得一轮
      // 保护，而不是因陈旧的候选记录被立即隔离
      if (toQuarantine.isNotEmpty) {
        nextCandidates.removeWhere((h, _) => toQuarantine.contains(h));
        await database.setGcOrphanCandidates(nextCandidates);
      }

      // P3-log：隔离决策（debug 级，稳态可能频繁）
      if (toQuarantine.isNotEmpty) {
        Log.sync.d(
          '_gcOrphanBlobs: 本轮隔离 ${toQuarantine.length} 个孤儿 blob '
          '(候选表剩 ${nextCandidates.length})',
        );
      }

      for (final hash in toQuarantine) {
        try {
          await backend.deleteBlobSoft(hash); // P1-2：软删除到隔离区
          // P2 journal §3.4：软删除时记录被隔离的 hash + 时间，
          // 与超期结算的 purged 条目共同构成可审计、可重放的自愈闭环
          journal.append(
            type: JournalEventType.syncGcOrphan,
            phase: JournalPhase.isolated,
            hash: hash,
            dataKeyEpoch: keyring.dataKeyEpoch,
            note: 'orphan blob moved to quarantine',
          );
        } on Exception catch (e) {
          // P3-log：单个 blob 软删除失败不阻断整体 GC，但需留痕便于排查
          Log.sync.w(
            '_gcOrphanBlobs: 单个 blob 软删除失败 '
            'hash=${hash.substring(0, 8)}…',
            error: e,
          );
        }
      }

      // P1-2：清理隔离区中超过保留期的 blob（超期才真删）
      try {
        // 先记录本轮将被结算的隔离项（purgeOrphans 之后就查不到了）
        final beforePurge = await backend.listOrphanBlobs();
        await backend.purgeOrphans(_orphanRetentionEffective);
        final afterPurge = (await backend.listOrphanBlobs()).toSet();
        final purgedCount = beforePurge.length - afterPurge.length;
        // P3-log：purge 结算结果（info 级，超期才删的关键事件）
        if (beforePurge.isNotEmpty) {
          Log.sync.i(
            '_gcOrphanBlobs: 隔离区结算 '
            '(before=${beforePurge.length}, purged=$purgedCount, '
            'remaining=${afterPurge.length})',
          );
        }
        for (final hash in beforePurge) {
          if (afterPurge.contains(hash)) continue;
          journal.append(
            type: JournalEventType.syncGcOrphan,
            phase: JournalPhase.purged,
            hash: hash,
            note: 'quarantined blob purged after retention',
          );
        }
      } on Exception catch (e) {
        // P3-log：隔离区清理失败不阻断同步，但需留痕
        Log.sync.w('_gcOrphanBlobs: purgeOrphans 失败（下次同步重试）', error: e);
      }
    } on Object catch (e) {
      // P3-log：整体 GC 失败不阻断同步，下次同步重试，但需留痕
      // 评审 #16：外层用 on Object（与全文解密兜底一致），
      // 防止非 Exception 的 Error（如 RangeError/FormatException）中断同步主流程
      Log.sync.w('_gcOrphanBlobs: 整体 GC 失败（下次同步重试）', error: e);
    }
  }

  /// 统计指定类型的操作数量
  int _countActions(List<SyncAction> actions, SyncActionType type) {
    int count = 0;
    for (final a in actions) {
      if (a.type == type) count++;
    }
    return count;
  }

  /// 添加操作记录并同步输出日志（含笔记 uuid，便于调试追踪）
  ///
  /// 所有 SyncAction 的创建都应通过此方法，确保每条操作都有对应的日志行，
  /// 方便从日志中按 uuid 检索同步行为。
  void _addAction(List<SyncAction> actions, SyncAction action) {
    actions.add(action);
    _logAction(action);
    _journalAction(action);
  }

  /// P2：把笔记级 action 投影为 journal 条目（设计 §3.5 的 _mergeAndTransfer /
  /// _repairBlob / _healBlob 记录点）
  ///
  /// **为什么统一在 `_addAction` 这个漏斗里记录，而不是散落在各调用点**：
  /// 全引擎所有笔记级事件都必须经过 `_addAction`（既有约定，见其文档注释），
  /// 在此处一次性投影可保证覆盖率 100%，且未来新增分支自动被覆盖；
  /// 散落式 `journal.append` 漏写不报错，覆盖率无法保证。
  ///
  /// 不记录 [SyncActionType.skip]（稳态下占 99%，纯噪音）与
  /// [SyncActionType.migrate]（由 key.migrate 条目携带完整 keyState 单独记录）。
  void _journalAction(SyncAction action) {
    final epoch = keyring.dataKeyEpoch;
    switch (action.type) {
      case SyncActionType.skip:
      case SyncActionType.migrate:
        return;
      case SyncActionType.upload:
        journal.append(
          type: JournalEventType.noteUpsert,
          uuid: action.uuid,
          hash: action.hash,
          dataKeyEpoch: epoch,
          note: 'upload${action.message == null ? '' : ': ${action.message}'}',
        );
      case SyncActionType.download:
        journal.append(
          type: JournalEventType.noteUpsert,
          uuid: action.uuid,
          hash: action.hash,
          dataKeyEpoch: epoch,
          note:
              'download${action.message == null ? '' : ': ${action.message}'}',
        );
      case SyncActionType.delete:
        journal.append(
          type: JournalEventType.noteDelete,
          uuid: action.uuid,
          hash: action.hash,
          dataKeyEpoch: epoch,
          note: action.message,
        );
      case SyncActionType.heal:
        journal.append(
          type: JournalEventType.noteHeal,
          phase: JournalPhase.done,
          uuid: action.uuid,
          hash: action.hash,
          dataKeyEpoch: epoch,
          note: action.message,
        );
      case SyncActionType.corrupt:
        // 自愈尝试失败：标记 failed，供诊断与后续人工/多端修复追踪
        journal.append(
          type: JournalEventType.noteHeal,
          phase: JournalPhase.failed,
          uuid: action.uuid,
          hash: action.hash,
          dataKeyEpoch: epoch,
          note: action.message,
        );
      case SyncActionType.uploadFailed:
        journal.append(
          type: JournalEventType.noteUpsert,
          phase: JournalPhase.failed,
          uuid: action.uuid,
          hash: action.hash,
          dataKeyEpoch: epoch,
          note: action.message,
        );
      case SyncActionType.conflict:
        journal.append(
          type: JournalEventType.noteConflict,
          uuid: action.uuid,
          hash: action.hash,
          dataKeyEpoch: epoch,
          note: action.message,
        );
    }
  }

  /// 输出单条操作的日志（按类型分级别，含 uuid 和 hash）
  ///
  /// 注意：[SyncActionType.skip] 不产生任何日志。
  /// skip 表示"本地与远端一致、无需处理"，在稳态下占全部 action 的 99%，
  /// 逐条打印会用无信息量的 `skip uuid=...` 淹没真正重要的日志。
  /// skip 的数量已经通过 SyncResult.skipped 聚合统计并在同步结束时汇总输出。
  void _logAction(SyncAction action) {
    // 快速返回：skip 不记日志（噪音治理）
    if (action.type == SyncActionType.skip) return;

    final uuid = action.uuid.isNotEmpty ? action.uuid : '-';
    // hash 截断前 8 位，足够辨识又避免日志过长
    final hash = action.hash != null && action.hash!.isNotEmpty
        ? _short(action.hash)
        : '';
    final msg = action.message ?? '';
    final hashPart = hash.isNotEmpty ? ' hash=$hash' : '';
    final msgPart = msg.isNotEmpty ? ' $msg' : '';

    switch (action.type) {
      case SyncActionType.upload:
        Log.sync.i('↑ upload uuid=$uuid$hashPart$msgPart');
      case SyncActionType.download:
        Log.sync.i('↓ download uuid=$uuid$hashPart$msgPart');
      case SyncActionType.delete:
        Log.sync.i('✗ delete uuid=$uuid$msgPart');
      case SyncActionType.skip:
        // 已在方法开头提前返回，此分支不会执行（保留以满足穷尽性检查）
        break;
      case SyncActionType.conflict:
        Log.sync.w('⚡ conflict uuid=$uuid$hashPart$msgPart');
      case SyncActionType.migrate:
        Log.sync.i('⇄ migrate uuid=$uuid$msgPart');
      case SyncActionType.uploadFailed:
        // uploadFailed 已在调用处用 Log.sync.e/w 记录详细错误，
        // 这里只补一条操作级别日志，避免重复
        Log.sync.w('✗ uploadFailed uuid=$uuid$hashPart$msgPart');
      case SyncActionType.corrupt:
        Log.sync.e('⚠ corrupt uuid=$uuid$hashPart$msgPart');
      case SyncActionType.heal:
        Log.sync.i('✚ heal uuid=$uuid$hashPart$msgPart');
    }
  }

  /// D3 修复：判断本次同步是否有实际变更需要 PUT manifest
  ///
  /// 返回 false 时跳过 PUT，避免 blob 持续下载失败等场景下 manifest version
  /// 无意义 +1 攀升。判定"有实际变更"的条件（任一满足即需 PUT）：
  ///   1. actions 中存在 upload/download/delete 类型（有成功的传输或墓碑应用）
  ///   2. merged.items 与 remote.items 不一致（键集或任一条目字段不同）
  ///   3. header 关键字段变化（encryptedDataKey / keyFingerprint / keyVersion）
  ///     ——兜住「本端改密码推送新包裹」「迁移后 keyVersion 变化」等无 items
  ///     变化但 header 必须更新的场景（v4 起不再有 epochMismatch/override）
  bool _hasEffectiveChange({
    required List<SyncAction> actions,
    required Manifest merged,
    required Manifest? remote,
  }) {
    // 有成功的传输操作：必须 PUT
    for (final a in actions) {
      if (a.type == SyncActionType.upload ||
          a.type == SyncActionType.download ||
          a.type == SyncActionType.delete) {
        return true;
      }
    }

    // 远端无 manifest（首次同步）：必须 PUT
    if (remote == null) {
      return true;
    }

    // header 关键字段变化：必须 PUT
    // 场景：改密码后 encryptedDataKey 变了，但 items 可能没变
    if (merged.header.encryptedDataKey != remote.header.encryptedDataKey ||
        merged.header.keyFingerprint != remote.header.keyFingerprint ||
        merged.header.keyVersion != remote.header.keyVersion) {
      return true;
    }

    // merged.items 与 remote.items 不一致：必须 PUT
    // 比较 keys 集合
    if (merged.items.length != remote.items.length) {
      return true;
    }
    for (final key in merged.items.keys) {
      final remoteItem = remote.items[key];
      if (remoteItem == null) {
        return true; // 本地新增的条目
      }
      final mergedItem = merged.items[key];
      if (mergedItem == null) return true;
      if (!_semanticItemsEqual(mergedItem, remoteItem)) {
        return true; // 条目字段不同（updatedBy 除外，见 _semanticItemsEqual 注释）
      }
    }

    // items 完全一致且无传输操作：无实际变更，跳过 PUT
    return false;
  }

  /// [G] 协议降级拒绝（§8.2[G] / §3.4[G]）
  ///
  /// 下载侧校验 `header.schemaVersion`：低于 [kManifestSchemaVersion]（当前
  /// 协议版本）时**拒绝解读**——不迁移、不覆盖、不做任何兼容处理，返回升级提示。
  /// 与业界「拒绝旧协议防降级」共识（Joplin 等）一致，补全不兼容策略 §0 的
  /// 下载侧执行细节；同时堵住「老客户端写覆盖新协议」的最后窗口（老客户端
  /// 按 §0 不共存，全量升级）。
  ///
  /// 返回 null 表示版本兼容（可继续）；否则返回用户可读的拒绝原因。
  static String? rejectOldSchemaVersion(ManifestHeader header) {
    if (header.schemaVersion < kManifestSchemaVersion) {
      return '远端同步数据使用旧版协议（schema v${header.schemaVersion}，'
          '当前 v$kManifestSchemaVersion）。请将全部设备升级到最新版本后重试'
          '（旧协议数据不做兼容解读/迁移/覆盖）';
    }
    return null;
  }
}

/// 内部异常：dataKey 迁移已完成，需要重新同步
///
/// 抛出此异常后，外层 sync() 循环会用新 dataKey 重新执行 _syncOnce。
class _MigrationRequiredException implements Exception {
  final int migratedCount;
  _MigrationRequiredException(this.migratedCount);

  @override
  String toString() =>
      '_MigrationRequiredException(migrated $migratedCount notes, retry sync)';
}

/// 单条笔记下载结果（Layer 1 故障隔离 + Layer 2b 自愈）
///
/// [_downloadNote] 用此类型表达一次下载尝试的三种结局，
/// 以便 [_mergeAndTransfer] 据此决定合并后 manifest 应引用哪条条目：
///   - [_DownloadSuccess]：下载并写入成功（[item] 为被采用的 manifest 条目，
///     墓碑场景为 null）
///   - [_DownloadHealed]：远端 blob 损坏，但本机持有明文并自愈重传成功，
///     合并时应改用 [healedItem]（hash 取本地明文 hash），否则修复后的 blob 成孤儿
///   - [_DownloadFailed]：blob 缺失或解密失败且无本地明文可自愈
///     （保留远端条目供下次重试，该 uuid 进入 [SyncResult.failedNoteUuids]）
abstract class _DownloadOutcome {
  const _DownloadOutcome();
}

class _DownloadSuccess extends _DownloadOutcome {
  final ManifestItem? item;
  const _DownloadSuccess([this.item]);
}

class _DownloadHealed extends _DownloadOutcome {
  final ManifestItem healedItem;
  const _DownloadHealed(this.healedItem);
}

class _DownloadFailed extends _DownloadOutcome {
  final String uuid;
  const _DownloadFailed(this.uuid);
}
