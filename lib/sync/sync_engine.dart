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
 *   2. vault.checkMigrationNeeded(remote.encryptedDataKey)
 *      - 不需要迁移（本地与远端一致）→ 继续正常同步
 *      - 需要迁移 → vault.migrateToRemote(...) 重新加密所有本地笔记
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
 *   - Vault：密钥管理（dataKey + MK 缓存 + 迁移能力）
 *   - DeviceIdProvider：manifest header.lastModifiedBy
 */

// Dart 原生导入
import 'dart:typed_data';

// Project 导入
import 'package:safenotes/data/database_handler.dart';
import 'package:safenotes/models/safenote.dart';
import 'package:safenotes/sync/crypto.dart';
import 'package:safenotes/sync/sync_backend.dart';
import 'package:safenotes/sync/sync_models.dart';
import 'package:safenotes/sync/vault.dart';

/// 同步引擎
///
/// 状态：持有 vault 引用（用于 dataKey 迁移）。
/// 线程安全：SyncService 通过互斥锁保证同一时间只有一个 sync() 在执行。
class SyncEngine {
  /// 远端后端
  final SyncBackend backend;

  /// 本地数据库
  final NotesDatabase database;

  /// Vault 引用（用于 dataKey 迁移检查）
  ///
  /// sync() 期间可能因迁移而更新 vault.dataKey 和 vault.encryptedDataKey，
  /// 因此不能缓存 dataKey 副本，需每次通过 vault.dataKey 获取。
  /// 非 final：_executeMigration 后会用 migrateToRemote 返回的新 Vault 替换。
  Vault vault;

  /// 设备 ID（写入 manifest header.lastModifiedBy）
  final String deviceId;

  /// 最大重试次数（乐观锁冲突时）
  static const int maxRetries = 3;

  SyncEngine({
    required this.backend,
    required this.database,
    required this.vault,
    required this.deviceId,
  });

  /// 当前 dataKey（便捷访问器，每次从 vault 获取最新值）
  Uint8List get _dataKey => vault.dataKey;

  /// 当前 encryptedDataKey（便捷访问器）
  String get _encryptedDataKey => vault.encryptedDataKey;

  /// 当前 vaultId（便捷访问器）
  String get _vaultId => vault.vaultId;

  /// 执行一次完整同步
  ///
  /// 返回 [SyncResult]，包含上传/下载/删除/冲突/迁移统计。
  /// 如果远端不可用（网络错误），返回 failure 结果。
  /// 如果乐观锁冲突超过 maxRetries 次，返回 failure 结果。
  Future<SyncResult> sync() async {
    final allActions = <SyncAction>[];
    int totalMigrated = 0;

    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        final result = await _syncOnce(attempt);
        // 累积迁移计数（迁移可能发生在 _syncOnce 内部）
        totalMigrated += result.migrated;
        allActions.addAll(result.actions);

        // 迁移后需要重新同步一次（用新 dataKey），但 _syncOnce 已处理
        return result.copyWith(migrated: totalMigrated);
      } on ConflictException catch (e) {
        // 乐观锁冲突：回到 Step 1 重试
        if (attempt == maxRetries) {
          return SyncResult.failure(
            '乐观锁冲突超过 $maxRetries 次：$e',
            attempts: attempt,
          );
        }
        // 否则 continue 重试
      } on _MigrationRequiredException catch (e) {
        // 迁移后需要重新拉取并同步，回到 Step 1 重试
        // 迁移已成功，但 manifest 中的 encryptedDataKey 已变化，
        // 需要重新 GET 远端 manifest（用新 dataKey 解密）
        totalMigrated += e.migratedCount;
        allActions.add(const SyncAction(
          type: SyncActionType.migrate,
          uuid: '',
          message: 'dataKey 迁移完成，重新同步',
        ));
        // 继续重试（不计入乐观锁冲突次数，但复用重试循环）
        if (attempt == maxRetries) {
          return SyncResult.failure(
            '迁移后重试同步超过 $maxRetries 次',
            attempts: attempt,
          );
        }
      }
    }
    return SyncResult.failure('Unexpected sync flow exit');
  }

  /// 执行一次同步尝试（不含重试逻辑）
  Future<SyncResult> _syncOnce(int attempt) async {
    // Step 1: GET 远端 manifest
    final remoteResponse = await backend.getManifest();

    Manifest? remoteManifest;
    if (remoteResponse.ciphertext.isNotEmpty) {
      // 1a. 仅解析 header（明文，不需要 dataKey）
      final remoteHeader =
          ManifestCrypto.deserializeHeaderOnly(remoteResponse.ciphertext);

      // 1b. 检查是否需要 dataKey 迁移
      final migrationResult =
          vault.checkMigrationNeeded(remoteHeader.encryptedDataKey);
      if (migrationResult.needsMigration) {
        if (!migrationResult.success) {
          // MK 解不开远端 encryptedDataKey，可能是两种场景：
          //   a) 远端密码已变（他端改密码并上传）→ 本地密码过期，需用户重新输入
          //   b) 本地密码已变（本端改密码但还没推送）→ 本地 dataKey 仍有效，
          //      应继续同步把新 encryptedDataKey 推送到远端
          // 区分方法：尝试用本地 dataKey 解析远端 manifest items
          //   - 成功 → 场景 b，无需迁移，继续正常同步（会上传新 encryptedDataKey）
          //   - 失败 → 场景 a，真正的密码不匹配
          try {
            ManifestCrypto.deserialize(_dataKey, remoteResponse.ciphertext);
            // 本地 dataKey 能解远端 manifest → 场景 b，继续同步
          } on Exception {
            // 本地 dataKey 也解不开 → 真正的密码不匹配
            return SyncResult.failure(
              'dataKey 迁移失败：${migrationResult.error}',
              attempts: attempt,
            );
          }
          // 场景 b：继续走正常同步流程（不做迁移）
          // 本地 encryptedDataKey 是新值（改密码后），远端是旧值。
          // 继续同步后 _buildLocalManifest 会用本地新值，
          // PUT manifest 时把新 encryptedDataKey 推送到远端。
          remoteManifest = ManifestCrypto.deserialize(
            _dataKey,
            remoteResponse.ciphertext,
          );
        } else if (migrationResult.remoteDataKey != null &&
            _bytesEqual(migrationResult.remoteDataKey!, _dataKey)) {
          // MK 能解开远端 encryptedDataKey，且 remoteDataKey == 本地 dataKey
          // 场景：他端改密码后上传新 encryptedDataKey，本端用新密码登录
          //   dataKey 没变，只是 wrap dataKey 的 MK 变了
          //   不需要 reEncryptAllNotes，只更新本地 encryptedDataKey
          await database.setMeta(
            MetaKeys.encryptedDataKey,
            migrationResult.remoteEncryptedDataKey!,
          );
          await vault.updateEncryptedDataKey(
            migrationResult.remoteEncryptedDataKey!,
            database,
          );
          remoteManifest = ManifestCrypto.deserialize(
            _dataKey,
            remoteResponse.ciphertext,
          );
        } else {
          // MK 能解开远端 encryptedDataKey，且 remoteDataKey != 本地 dataKey
          // 场景：新设备加入已存在同步组，本地 dataKey 与远端不同
          //   需要执行 reEncryptAllNotes 迁移所有本地笔记
          final migratedCount = await _executeMigration(
            migrationResult,
            remoteHeader,
          );

          // 迁移后用新 dataKey 解析完整 manifest
          remoteManifest = ManifestCrypto.deserialize(
            _dataKey,
            remoteResponse.ciphertext,
          );

          // 抛特殊异常，触发外层重试（用新 dataKey 重新同步）
          throw _MigrationRequiredException(migratedCount);
        }
      } else {
        // 无需迁移：用当前 dataKey 解析完整 manifest
        remoteManifest = ManifestCrypto.deserialize(
          _dataKey,
          remoteResponse.ciphertext,
        );
      }
    }

    // Step 2: 构建本地 manifest
    final localManifest = await _buildLocalManifest();

    // Step 3: 比对 + 传输（上传/下载/删除）
    final actions = <SyncAction>[];
    final merged = await _mergeAndTransfer(
      localManifest,
      remoteManifest,
      actions,
    );

    // Step 4: 加密 + PUT manifest（乐观锁）
    final newCiphertext = ManifestCrypto.serialize(_dataKey, merged);
    await backend.putManifest(
      newCiphertext,
      remoteResponse.etag,
    );

    // Step 5: 更新本地状态
    await _updateLocalState(merged);

    // 统计结果
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

  /// 执行 dataKey 迁移：调用 vault.migrateToRemote
  ///
  /// 返回迁移的笔记数量。
  /// 迁移成功后，vault 引用更新为新实例（含新 dataKey 和 encryptedDataKey），
  /// database._dataKey 也已通过 database.setDataKey 更新。
  Future<int> _executeMigration(
    MigrationResult migrationResult,
    ManifestHeader remoteHeader,
  ) async {
    // migrateToRemote 返回新 Vault，需要更新 self.vault
    // 否则后续 _syncOnce 重试时仍用旧 vault.dataKey 解密会失败
    vault = await vault.migrateToRemote(
      result: migrationResult,
      database: database,
    );

    // 读取迁移的笔记数量（用于结果统计）
    final notes = await database.readAllNotesIncludingDeleted();
    return notes.length;
  }

  /// 从本地数据库构建 manifest
  ///
  /// 包含所有笔记（含墓碑）。manifest 是全量的。
  Future<Manifest> _buildLocalManifest() async {
    final notes = await database.readAllNotesIncludingDeleted();
    final items = <String, ManifestItem>{};
    for (final note in notes) {
      items[note.uuid] = ManifestItem(
        hash: note.contentHash,
        deleted: note.deleted,
        updatedAt: note.updatedAt,
      );
    }
    final localVersion = await database.getManifestVersion(backend.providerKey);

    return Manifest(
      header: ManifestHeader(
        version: localVersion,
        vaultId: _vaultId,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        encryptedDataKey: _encryptedDataKey,
        kdf: KdfParams.defaultParams(),
        dataKeyWrap: kDataKeyWrapAlgorithm,
        lastModifiedBy: deviceId,
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
  Future<Manifest> _mergeAndTransfer(
    Manifest local,
    Manifest? remote,
    List<SyncAction> actions,
  ) async {
    // M1 修复：读取待清理的 uuid 列表（用户硬删除的笔记）
    final purgedUuids = await database.getPurgedUuids();
    final purgedSet = purgedUuids.toSet();

    // 远端无 manifest：首次上传，直接用本地 manifest（移除待清理的）
    if (remote == null) {
      final notes = await database.readAllNotesIncludingDeleted();
      for (final note in notes) {
        if (purgedSet.contains(note.uuid)) continue;
        await _uploadNote(note, actions);
      }
      final filteredItems = Map<String, ManifestItem>.from(local.items)
        ..removeWhere((uuid, _) => purgedSet.contains(uuid));
      return local.copyWithHeader(version: 1, items: filteredItems);
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
          actions.add(SyncAction(
            type: SyncActionType.skip,
            uuid: uuid,
            message: 'locally purged (hard-deleted on this device)',
          ));
          continue;
        }
        // 仅远端有：下载
        final downloaded = await _downloadNote(uuid, remoteItem, actions);
        if (downloaded) {
          mergedItems[uuid] = remoteItem;
        }
        // 下载失败（blob missing）时不加入 mergedItems，下次再试
      } else if (localItem != null && remoteItem == null) {
        // M1 修复：本地硬删除的笔记不要重新上传
        // 正常情况下 hardDelete 后 readNoteByUuid 返回 null 不会走到这里，
        // 但为防止边缘情况（如笔记被重新下载后又在 purgedSet 中），加保护。
        if (purgedSet.contains(uuid)) {
          actions.add(SyncAction(
            type: SyncActionType.skip,
            uuid: uuid,
            message: 'locally purged, skip upload',
          ));
          continue;
        }
        // 仅本地有：上传
        final note = await database.readNoteByUuid(uuid);
        if (note != null) {
          await _uploadNote(note, actions);
          mergedItems[uuid] = localItem;
        }
        // note 已被硬删除：不加入 mergedItems（从 manifest 移除）
      } else if (localItem != null && remoteItem != null) {
        // 双方都有：判断是否一致
        if (_itemsEqual(localItem, remoteItem)) {
          // 完全一致：跳过
          mergedItems[uuid] = localItem;
          actions.add(SyncAction(type: SyncActionType.skip, uuid: uuid));
        } else {
          // 冲突：LWW 解决
          final winner = _resolveConflict(localItem, remoteItem);
          if (winner == localItem) {
            // 本地胜：上传覆盖远端
            final note = await database.readNoteByUuid(uuid);
            if (note != null) {
              await _uploadNote(note, actions);
              mergedItems[uuid] = localItem;
            }
          } else {
            // 远端胜：下载覆盖本地
            final downloaded =
                await _downloadNote(uuid, remoteItem, actions);
            if (downloaded) {
              mergedItems[uuid] = remoteItem;
            } else {
              // 下载失败：保留本地版本，下次再试
              final note = await database.readNoteByUuid(uuid);
              if (note != null) {
                await _uploadNote(note, actions);
                mergedItems[uuid] = localItem;
              }
            }
          }
          actions.add(SyncAction(
            type: SyncActionType.conflict,
            uuid: uuid,
            message: winner == localItem
                ? 'local won (LWW: local newer)'
                : 'remote won (LWW: remote newer)',
          ));
        }
      }
    }

    // M1 修复：从 merged items 中移除待清理的 uuid
    // 这些是用户硬删除的笔记，需要从远端 manifest 中清除墓碑
    if (purgedSet.isNotEmpty) {
      mergedItems.removeWhere((uuid, _) => purgedSet.contains(uuid));
    }

    return Manifest(
      header: ManifestHeader(
        version: remote.version + 1,
        vaultId: _vaultId,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        encryptedDataKey: _encryptedDataKey,
        kdf: KdfParams.defaultParams(),
        dataKeyWrap: kDataKeyWrapAlgorithm,
        lastModifiedBy: deviceId,
      ),
      items: mergedItems,
    );
  }

  /// 判断两个 ManifestItem 是否完全一致（hash + deleted）
  ///
  /// 完全一致时跳过传输。注意：updatedAt 相同但 hash 不同不算一致（会走冲突流程）。
  bool _itemsEqual(ManifestItem a, ManifestItem b) {
    return a.hash == b.hash && a.deleted == b.deleted;
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
  /// 非墓碑：加密笔记内容为 envelope，PUT 到 blobs/<hash>。
  Future<void> _uploadNote(
    SafeNote note,
    List<SyncAction> actions,
  ) async {
    if (note.deleted) {
      // 墓碑：不传 blob，只在 manifest 里标记
      actions.add(SyncAction(
        type: SyncActionType.delete,
        uuid: note.uuid,
        message: 'tombstone (no blob)',
      ));
      return;
    }

    // 加密笔记内容为 envelope
    final envelope = SyncCrypto.seal(
      _dataKey,
      note.uuid,
      note.toContentBytes(),
    );
    await backend.putBlob(note.contentHash, envelope);

    actions.add(SyncAction(
      type: SyncActionType.upload,
      uuid: note.uuid,
      hash: note.contentHash,
    ));
  }

  /// 从远端下载单条笔记并写入本地数据库
  ///
  /// 返回 true 表示下载成功，false 表示 blob 不存在（跳过）。
  /// 墓碑：标记本地为软删除，不需要下载 blob。
  Future<bool> _downloadNote(
    String uuid,
    ManifestItem item,
    List<SyncAction> actions,
  ) async {
    if (item.deleted) {
      // 远端是墓碑：本地也标记为软删除
      final local = await database.readNoteByUuid(uuid);
      if (local != null && !local.deleted) {
        await database.updateNoteByUuid(local.copyWith(
          deleted: true,
          updatedAt: item.updatedAt,
          synced: true,
        ));
      }
      actions.add(SyncAction(
        type: SyncActionType.delete,
        uuid: uuid,
        message: 'remote tombstone applied',
      ));
      return true;
    }

    // 下载 blob
    final envelope = await backend.getBlob(item.hash);
    if (envelope == null) {
      // blob 不存在：可能是其他设备还没上传完，跳过本次
      actions.add(SyncAction(
        type: SyncActionType.skip,
        uuid: uuid,
        hash: item.hash,
        message: 'blob missing on remote (will retry next sync)',
      ));
      return false;
    }

    // 解密
    final plaintext = SyncCrypto.open(_dataKey, uuid, envelope);
    final content = SafeNote.fromContentBytes(plaintext);

    // M7 修复：校验解密后内容的 hash 与 manifest 中记录的 hash 一致
    // 防止服务端返回"对的上 uuid、但内容不同"的合法信封
    // 注意：hash 计算使用 SafeNote.computeHash（title\ndescription 格式），
    // 而不是 SyncCrypto.contentHash(plaintext)（JSON 字节格式），两者不一致。
    final actualHash = SafeNote.computeHash(content.title, content.description);
    if (actualHash != item.hash) {
      actions.add(SyncAction(
        type: SyncActionType.skip,
        uuid: uuid,
        hash: item.hash,
        message: 'blob hash mismatch (expected ${item.hash}, got $actualHash)',
      ));
      return false;
    }

    // 写入本地数据库（upsert）
    final existing = await database.readNoteByUuid(uuid);
    final note = SafeNote(
      id: existing?.id,
      uuid: uuid,
      title: content.title,
      description: content.description,
      contentHash: item.hash,
      deleted: false,
      createdTime: existing?.createdTime ?? DateTime.now(),
      updatedAt: item.updatedAt,
      synced: true,
    );
    if (existing == null) {
      await database.storeNote(note);
    } else {
      await database.updateNoteByUuid(note);
    }

    actions.add(SyncAction(
      type: SyncActionType.download,
      uuid: uuid,
      hash: item.hash,
    ));
    return true;
  }

  /// 同步完成后更新本地状态
  ///
  /// - 写入 manifest version 到 sync_meta 表
  /// - 标记所有本地笔记为已同步（synced=1）
  /// - 清理已从远端 manifest 移除的墓碑 uuid（M1 修复）
  Future<void> _updateLocalState(Manifest merged) async {
    await database.setManifestVersion(backend.providerKey, merged.version);
    await database.markAllSynced();

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
  }

  /// 统计指定类型的操作数量
  int _countActions(List<SyncAction> actions, SyncActionType type) {
    int count = 0;
    for (final a in actions) {
      if (a.type == type) count++;
    }
    return count;
  }

  /// 常数时间比较两个字节序列是否相等
  ///
  /// 用于比较 dataKey，避免时序攻击。
  /// 长度不同时直接返回 false（dataKey 长度固定 32 字节，长度泄露无安全意义）。
  bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
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
