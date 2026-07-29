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
import 'dart:convert';
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

  /// E1 修复：冲突副本保留阈值（5 分钟，单位毫秒）
  ///
  /// 当冲突双方的 updatedAt 差值超过此阈值时，视为真冲突（非并发编辑），
  /// 败方内容另存为新笔记保留，避免 LWW 覆盖导致数据丢失。
  /// 差值小于此阈值视为并发编辑，走原 LWW 覆盖逻辑。
  static const int kConflictPreserveThresholdMs = 5 * 60 * 1000;

  /// F1 修复：墓碑 GC 阈值（30 天，单位毫秒）
  ///
  /// 软删除超过此阈值的墓碑将从 manifest 移除并硬删除本地数据库记录，
  /// 防止墓碑无限累积。30 天保证离线设备重新上线后能同步到删除操作。
  static const int kTombstoneGcThresholdMs = 30 * 24 * 60 * 60 * 1000;

  SyncEngine({
    required this.backend,
    required this.database,
    required this.vault,
    required this.deviceId,
    this.passphraseProvider,
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
  ///
  /// 密钥纪元守卫（B1 修复）：
  ///   下载远端 header 后比对 keyVersion。如果远端更高（他端改了密码），
  ///   本地旧密码设备不会把旧 encryptedDataKey 写回远端（避免翻转战争），
  ///   同步仍然完成（拉取远端笔记），但 SyncResult.passwordEpochMismatch=true，
  ///   UI 应提示用户输入新密码重新登录。
  Future<SyncResult> sync() async {
    final allActions = <SyncAction>[];
    int totalMigrated = 0;
    bool epochMismatch = false;

    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        final result = await _syncOnce(attempt);
        // 累积迁移计数（迁移可能发生在 _syncOnce 内部）
        totalMigrated += result.migrated;
        allActions.addAll(result.actions);
        epochMismatch = epochMismatch || result.passwordEpochMismatch;

        // 迁移后需要重新同步一次（用新 dataKey），但 _syncOnce 已处理
        return result.copyWith(
          migrated: totalMigrated,
          passwordEpochMismatch: epochMismatch,
        );
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

    Manifest? remoteManifest;
    // 密钥纪元不匹配标志：远端 keyVersion > 本地 → 他端改了密码
    bool epochMismatch = false;
    // 纪元不匹配时，构建 manifest 整体使用远端的密钥纪元三元组
    // （encryptedDataKey + keyFingerprint + keyVersion），不回滚远端新纪元。
    // B1-2 修复：原实现只 override encryptedDataKey，keyVersion/fingerprint
    // 仍取本地旧值，导致 B 第一次同步就把远端 keyVersion 回滚（守卫下次失效），
    // 第二次同步把旧 encryptedDataKey 整体写回远端（翻转战争）。
    String? overrideEncryptedDataKey;
    String? overrideKeyFingerprint;
    int? overrideKeyVersion;

    if (remoteResponse.ciphertext.isNotEmpty) {
      // 1a. 仅解析 header（明文，不需要 dataKey）
      //
      // D2 修复：header 解析失败（FormatException）时备份损坏文件，
      // 跳过远端 manifest 处理，用本地数据重建 manifest 上传。
      // 注意：GCM tag 验证失败不属于"损坏"，是密码不匹配，仍走迁移流程。
      ManifestHeader remoteHeader;
      try {
        remoteHeader =
            ManifestCrypto.deserializeHeaderOnly(remoteResponse.ciphertext);
      } on FormatException catch (e) {
        // 远端 manifest 格式损坏（数据截断、header 长度字段错误等）
        // 备份损坏文件，用本地数据重建 manifest 上传覆盖
        await backend.backupCorruptManifest(remoteResponse.ciphertext);
        final localManifest = await _buildLocalManifest(
          overrideEncryptedDataKey: null,
        );
        final actions = <SyncAction>[];
        actions.add(SyncAction(
          type: SyncActionType.skip,
          uuid: '',
          message: '远端 manifest 损坏已备份：$e',
        ));
        final merged = await _mergeAndTransfer(
          localManifest,
          null,
          actions,
          overrideEncryptedDataKey: null,
        );
        // PUT manifest：用原 etag 做乐观锁（覆盖损坏文件）
        final newCiphertext = ManifestCrypto.serialize(_dataKey, merged);
        await backend.putManifest(newCiphertext, remoteResponse.etag);
        await _updateLocalState(merged);
        return SyncResult.success(
          uploaded: _countActions(actions, SyncActionType.upload),
          downloaded: _countActions(actions, SyncActionType.download),
          deleted: _countActions(actions, SyncActionType.delete),
          skipped: _countActions(actions, SyncActionType.skip),
          conflicts: _countActions(actions, SyncActionType.conflict),
          actions: actions,
          attempts: attempt,
          passwordEpochMismatch: false,
        );
      }

      // 1b. 密钥纪元守卫：比对 keyVersion
      //   - 远端 > 本地 → 他端改了密码，本地密码过期
      //   - 远端 < 本地 → 本端改了密码还没推送（正常流程）
      //   - 相等 → 正常流程
      if (remoteHeader.keyVersion > vault.keyVersion) {
        // 他端改了密码，本地旧密码设备不应回滚远端新纪元。
        // B1-2 修复：三元组整体采用远端值（不只是 encryptedDataKey）。
        epochMismatch = true;
        overrideEncryptedDataKey = remoteHeader.encryptedDataKey;
        overrideKeyFingerprint = remoteHeader.keyFingerprint;
        overrideKeyVersion = remoteHeader.keyVersion;
      }

      // 1c. 检查是否需要 dataKey 迁移
      final migrationResult =
          vault.checkMigrationNeeded(remoteHeader.encryptedDataKey);
      if (migrationResult.needsMigration) {
        if (!migrationResult.success) {
          // MK 解不开远端 encryptedDataKey，可能是三种场景：
          //   a) 远端密码已变（他端改密码并上传）→ 本地密码过期，需用户重新输入
          //   b) 本地密码已变（本端改密码但还没推送）→ 本地 dataKey 仍有效，
          //      应继续同步把新 encryptedDataKey 推送到远端
          //   c) 真正的密码不匹配
          //   d) 两设备独立 createNew（相同密码、不同 salt）→ 本地 MK 解不开，
          //      但密码其实相同，需用远端 salt 重新派生 MK 验证
          // 区分方法：
          //   1. 先尝试用本地 dataKey 解析远端 manifest items
          //      - 成功 → 场景 b（或纪元不匹配场景 a），继续同步
          //      - 失败 → 场景 c 或 d
          //   2. 用 keyFingerprint 判别 c vs d：
          //      用远端 salt + 用户密码派生 MK_remote，比 H(MK_remote) 与远端 fingerprint
          //      - 匹配 → 场景 d（密码相同、salt 不同）→ 迁移
          //      - 不匹配 → 场景 c（密码真的不同）→ 失败
          try {
            ManifestCrypto.deserialize(_dataKey, remoteResponse.ciphertext);
            // 本地 dataKey 能解远端 manifest → 场景 b，继续同步
          } on Exception {
            // 场景 c 或 d：用 keyFingerprint 判别
            final password = passphraseProvider?.call();
            if (password == null || password.isEmpty) {
              // 无密码提供者（旧测试或未注入），退回原失败逻辑
              return SyncResult.failure(
                'dataKey 迁移失败：${migrationResult.error}',
                attempts: attempt,
              );
            }

            // 用远端 KDF 参数派生 MK_remote，比对 keyFingerprint
            final remoteResult = await Vault.tryDeriveRemoteDataKey(
              password: password,
              remoteKdf: remoteHeader.kdf,
              remoteEncryptedDataKey: remoteHeader.encryptedDataKey,
              remoteKeyFingerprint: remoteHeader.keyFingerprint,
            );

            if (remoteResult == null) {
              // 场景 c：密码真的不匹配
              return SyncResult.failure(
                '密码不匹配，无法同步：${migrationResult.error}',
                attempts: attempt,
              );
            }

            // 场景 d：密码相同、salt 不同 → 完整 vault 迁移
            // 用远端 dataKey 重新加密所有本地笔记，更新本地 vault 元数据
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
            remoteManifest = ManifestCrypto.deserialize(
              _dataKey,
              remoteResponse.ciphertext,
            );

            // 抛特殊异常，触发外层重试（用新 dataKey 重新同步）
            throw _MigrationRequiredException(migratedCount);
          }
          // 继续走正常同步流程（不做迁移）
          // - 场景 b（本端改密码）：本地 encryptedDataKey 是新值，
          //   _buildLocalManifest 会用本地新值推送
          // - 纪元不匹配（他端改密码）：overrideEncryptedDataKey 已设置，
          //   _buildLocalManifest 会用远端新值，不回滚远端包裹
          remoteManifest = ManifestCrypto.deserialize(
            _dataKey,
            remoteResponse.ciphertext,
          );
        } else if (migrationResult.remoteDataKey != null &&
            _bytesEqual(migrationResult.remoteDataKey!, _dataKey)) {
          // MK 能解开远端 encryptedDataKey，且 remoteDataKey == 本地 dataKey
          // 场景：他端改密码后上传新 encryptedDataKey，本端用新密码登录
          //   dataKey 没变，只是 wrap dataKey 的 MK 变了
          //   不需要 reEncryptAllNotes
          if (remoteHeader.keyVersion >= vault.keyVersion) {
            // B3 修复：整体采用远端纪元（encryptedDataKey + fingerprint +
            // keyVersion），而不是只回写 encryptedDataKey。
            // 原实现只更新 encryptedDataKey，本地 keyVersion/fingerprint
            // 停留在旧值 → 每次同步都误报 epochMismatch（纪元永不收敛），
            // 且构建 header 时把远端 keyVersion/fingerprint 回滚。
            await vault.adoptRemoteEpoch(
              remoteEncryptedDataKey: migrationResult.remoteEncryptedDataKey!,
              remoteKeyFingerprint: remoteHeader.keyFingerprint,
              remoteKeyVersion: remoteHeader.keyVersion,
              remoteDataKeyEpoch: remoteHeader.dataKeyEpoch,
              database: database,
            );
            // 本地纪元已与远端一致：本端持有的就是新密码派生的 MK，
            // 不需要提示用户重新登录，清除纪元不匹配标志与 override
            epochMismatch = false;
            overrideEncryptedDataKey = null;
            overrideKeyFingerprint = null;
            overrideKeyVersion = null;
          } else {
            // 防御分支：远端纪元反而更旧（理论上不可达——本地 MK 能解开
            // 远端包裹意味着远端包裹就是本地 MK 包的）。保守起见只回写
            // encryptedDataKey，不动本地纪元。
            await vault.updateEncryptedDataKey(
              migrationResult.remoteEncryptedDataKey!,
              database,
            );
            overrideEncryptedDataKey = null;
          }
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

    // Step 2: 构建本地 manifest（纪元不匹配时整体用远端密钥纪元）
    final localManifest = await _buildLocalManifest(
      overrideEncryptedDataKey: overrideEncryptedDataKey,
      overrideKeyFingerprint: overrideKeyFingerprint,
      overrideKeyVersion: overrideKeyVersion,
    );

    // Step 3: 比对 + 传输（上传/下载/删除）
    final actions = <SyncAction>[];
    final merged = await _mergeAndTransfer(
      localManifest,
      remoteManifest,
      actions,
      overrideEncryptedDataKey: overrideEncryptedDataKey,
      overrideKeyFingerprint: overrideKeyFingerprint,
      overrideKeyVersion: overrideKeyVersion,
    );

    // D3 修复：判断是否需要 PUT manifest
    //
    // 若 merged 与 remote 在语义上完全等价（items 一致 + header 关键字段一致），
    // 且无纪元不匹配/encryptedDataKey override，则跳过 PUT——避免 blob 持续下载
    // 失败时 manifest version 每次同步无意义 +1 攀升。
    //
    // 判定"有实际变更"的条件（任一满足即需要 PUT）：
    //   1. actions 中存在 upload/download/delete 类型（有成功的传输或墓碑应用）
    //   2. purgedUuids 非空（本地硬删除需要从远端 manifest 清除墓碑）
    //   3. 纪元不匹配（需推送远端新 encryptedDataKey）
    //   4. merged.items 与 remote.items 不一致（键集或任一条目字段不同）
    final hasEffectiveChange = _hasEffectiveChange(
      actions: actions,
      merged: merged,
      remote: remoteManifest,
      epochMismatch: epochMismatch,
      overrideEncryptedDataKey: overrideEncryptedDataKey,
    );

    if (!hasEffectiveChange) {
      // 无实际变更：跳过 PUT manifest，version 不递增
      // 此时 remoteManifest 一定非空（_hasEffectiveChange 在 remote==null 时返回 true）
      await _updateLocalState(merged.copyWithHeader(
        version: remoteManifest!.header.version,
        updatedAt: remoteManifest.header.updatedAt,
      ));

      // F1 修复：即使跳过 PUT，也执行孤儿 blob GC
      // 场景：上次同步上传了 blob，本次同步无变更但远端有孤儿 blob 需清理
      await _gcOrphanBlobs(merged);

      return SyncResult.success(
        uploaded: 0,
        downloaded: 0,
        deleted: 0,
        skipped: _countActions(actions, SyncActionType.skip) +
            _countActions(actions, SyncActionType.conflict),
        conflicts: _countActions(actions, SyncActionType.conflict),
        actions: actions,
        attempts: attempt,
        passwordEpochMismatch: epochMismatch,
        failedNoteUuids: _failedUuids(actions),
      );
    }

    // Step 4: 加密 + PUT manifest（乐观锁）
    final newCiphertext = ManifestCrypto.serialize(_dataKey, merged);
    await backend.putManifest(
      newCiphertext,
      remoteResponse.etag,
    );

    // Step 5: 更新本地状态
    await _updateLocalState(merged);

    // F1 修复：孤儿 blob GC（manifest PUT 成功后）
    // listBlobs() - manifest 引用的 hash = 孤儿，删除。
    // GC 失败不阻断同步（try-catch），下次同步会重试。
    await _gcOrphanBlobs(merged);

    // 密钥变更后的首次同步已将 pending 笔记的 blob 用新密钥重新上传，
    // 成功后清除待重传标记（Layer 2a）。
    await database.clearAllPendingReupload();

    // 统计结果
    return SyncResult.success(
      uploaded: _countActions(actions, SyncActionType.upload),
      downloaded: _countActions(actions, SyncActionType.download),
      deleted: _countActions(actions, SyncActionType.delete),
      skipped: _countActions(actions, SyncActionType.skip) +
          _countActions(actions, SyncActionType.conflict),
      conflicts: _countActions(actions, SyncActionType.conflict),
      actions: actions,
      attempts: attempt,
      passwordEpochMismatch: epochMismatch,
      failedNoteUuids: _failedUuids(actions),
    );
  }

  /// 全面校验并修复远端 blob 数据（设置页「修复同步数据」按钮调用）。
  ///
  /// 与 [sync] 的区别：sync 是增量对账，repair 是「全量体检 + 治愈」——
  /// 逐条验证每个远端 blob 能否被当前/历史 dataKey 解密，不能的尝试用本机
  /// 明文（同 uuid 或同内容孪生笔记）重传覆盖，仍不能的标记为损坏。
  ///
  /// 背景：用户常同时记得新旧密码。改密码在该设计中 dataKey 不变，但历史上
  /// scenario-d 合并（两设备独立 dataKey）会产生用「非当前 dataKey」加密的旧 blob。
  /// 提供 [oldPassword] 时，会用它派生旧 MK 解开归档的 wrappedDataKey，把历史
  /// dataKey 加入候选集，从而能修复这些遗留坏 blob。
  ///
  /// 全程只读远端 + 必要时重传覆盖，不删除任何笔记；无法修复的只标记不丢弃。
  ///
  /// 返回 [SyncResult]：uploaded 含 heal 计数，failedNoteUuids 为仍损坏的 uuid。
  Future<SyncResult> repairRemote({String? oldPassword}) async {
    final actions = <SyncAction>[];
    final failed = <String>[];

    // Step 1: 拉取远端 manifest（用当前 dataKey 解密 items）
    final remoteResponse = await backend.getManifest();
    if (remoteResponse.ciphertext.isEmpty) {
      return SyncResult.success(actions: actions, attempts: 1);
    }
    final remoteHeader = ManifestCrypto.deserializeHeaderOnly(
      remoteResponse.ciphertext,
    );
    final Manifest remoteManifest;
    try {
      remoteManifest = ManifestCrypto.deserialize(
        _dataKey,
        remoteResponse.ciphertext,
      );
    } on Object {
      // 当前 dataKey 解不开 manifest（密码不匹配/纪元过期），无法枚举远端条目。
      return SyncResult.failure(
        '无法解密远端 manifest（dataKey 不匹配），修复中止：请先用正确密码登录',
        attempts: 1,
      );
    }

    // Step 2: 构建候选 dataKey 集合
    //   - 始终包含当前 dataKey
    //   - 提供 oldPassword 时：派生旧 MK，尝试解开归档的历史 wrappedDataKey
    final candidates = <Uint8List>[_dataKey];
    if (oldPassword != null && oldPassword.isNotEmpty) {
      try {
        final oldMk = SyncCrypto.deriveMasterKey(
          oldPassword,
          salt: vault.kdf.saltBytes,
        );
        final history = await database.getDataKeyHistory();
        for (final entry in history) {
          final wrapped = base64.decode(entry['wrappedDataKey'] as String);
          try {
            final dk = SyncCrypto.unwrapDataKey(oldMk, wrapped);
            if (!candidates.any((c) => _sameKey(c, dk))) candidates.add(dk);
          } on Object {
            // 该历史条目不是用 oldPassword 的 MK 包裹的，跳过
          }
        }
      } on Object {
        // 派生失败，忽略历史候选
      }
    }

    // Step 3: 逐条校验/修复
    final repairedItems = <String, ManifestItem>{};
    for (final entry in remoteManifest.items.entries) {
      final uuid = entry.key;
      final item = entry.value;
      if (item.deleted) {
        repairedItems[uuid] = item; // 墓碑原样保留
        continue;
      }

      final blob = await backend.getBlob(item.hash);
      if (blob == null) {
        // blob 缺失：保留远端条目，标记跳过（下次同步重试）
        repairedItems[uuid] = item;
        actions.add(SyncAction(
          type: SyncActionType.skip,
          uuid: uuid,
          hash: item.hash,
          message: 'repair: blob 缺失，跳过',
        ));
        continue;
      }

      // 3a. 用候选 dataKey 依次尝试解密
      Uint8List? workingKey;
      for (final key in candidates) {
        try {
          _openBlobEnvelope(
            uuid,
            item.hash,
            blob,
            blobKeyEpoch: item.blobKeyEpoch,
            dataKeyOverride: key,
          );
          workingKey = key;
          break;
        } on Object {
          // 试下一个候选
        }
      }

      if (workingKey != null) {
        final needsModernize =
            !_sameKey(workingKey, _dataKey) ||
                item.blobKeyEpoch != vault.dataKeyEpoch;
        if (needsModernize) {
          final plaintext = _openBlobEnvelope(
            uuid,
            item.hash,
            blob,
            blobKeyEpoch: item.blobKeyEpoch,
            dataKeyOverride: workingKey,
          );
          final content = SafeNote.fromContentBytes(plaintext);
          final note = SafeNote(
            uuid: uuid,
            title: content.title,
            description: content.description,
            contentHash: item.hash,
            deleted: false,
            createdTime: DateTime.fromMillisecondsSinceEpoch(item.createdAt),
            updatedAt: item.updatedAt,
            synced: true,
          );
          await _uploadNote(note, actions); // 用当前密钥重传（现代化）
          actions.add(SyncAction(
            type: SyncActionType.heal,
            uuid: uuid,
            hash: item.hash,
            message: 'repair: 用历史/旧密钥解密并重新上传为当前密钥',
          ));
        }
        repairedItems[uuid] = item.copyWith(blobKeyEpoch: vault.dataKeyEpoch);
        continue;
      }

      // 3b. 候选密钥全部失败 → 回退本机明文（同 uuid 或同内容孪生）
      final local = await database.readNoteByUuid(uuid);
      final twin =
          local == null ? await database.readNoteByContentHash(item.hash) : null;
      final source = local ?? twin;
      if (source != null && !source.deleted) {
        await _uploadNote(source, actions);
        repairedItems[uuid] = item.copyWith(blobKeyEpoch: vault.dataKeyEpoch);
        actions.add(SyncAction(
          type: SyncActionType.heal,
          uuid: uuid,
          hash: item.hash,
          message: local != null
              ? 'repair: 本机有明文，重传修复'
              : 'repair: 本机有同内容孪生笔记，重传修复',
        ));
        continue;
      }

      // 3c. 无法修复：保留远端条目，标记损坏（不丢弃，等待其他设备/手动处理）
      failed.add(uuid);
      repairedItems[uuid] = item;
      actions.add(SyncAction(
        type: SyncActionType.corrupt,
        uuid: uuid,
        hash: item.hash,
        message: 'repair: 所有密钥/明文均无法解密，标记损坏',
      ));
    }

    // Step 4: 用修复后的 items + 当前 header 重新 PUT manifest（乐观锁 etag）
    final header = ManifestHeader(
      schemaVersion: remoteHeader.schemaVersion,
      version: remoteHeader.version + 1,
      vaultId: remoteHeader.vaultId,
      createdAt: remoteHeader.createdAt,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      keyFingerprint: remoteHeader.keyFingerprint,
      keyVersion: remoteHeader.keyVersion,
      encryptedDataKey: remoteHeader.encryptedDataKey,
      kdf: remoteHeader.kdf,
      dataKeyWrap: remoteHeader.dataKeyWrap,
      lastModifiedBy: deviceId,
      dataKeyEpoch: vault.dataKeyEpoch,
    );
    final manifest = Manifest(header: header, items: repairedItems);
    final ciphertext = ManifestCrypto.serialize(_dataKey, manifest);
    await backend.putManifest(ciphertext, remoteResponse.etag);

    return SyncResult.success(
      uploaded: _countActions(actions, SyncActionType.upload) +
          _countActions(actions, SyncActionType.heal),
      downloaded: 0,
      deleted: 0,
      skipped: _countActions(actions, SyncActionType.skip),
      conflicts: 0,
      actions: actions,
      attempts: 1,
      failedNoteUuids: failed,
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

  /// 场景 d 迁移：调用 vault.migrateToRemoteVault
  ///
  /// 与 [_executeMigration] 的区别：
  ///   - _executeMigration：同 vault、dataKey 不同（他端改密码）
  ///   - _executeMigrationVault：不同 vault、salt 不同（两设备独立 createNew）
  ///     需要更新本地 vault 的全部元数据（kdf/keyFingerprint/keyVersion/createdAt）
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
    // migrateToRemoteVault 返回新 Vault，需要更新 self.vault
    vault = await vault.migrateToRemoteVault(
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

    // 读取迁移的笔记数量（用于结果统计）
    final notes = await database.readAllNotesIncludingDeleted();
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
  /// [overrideEncryptedDataKey] / [overrideKeyFingerprint] /
  /// [overrideKeyVersion]：纪元不匹配时（他端改密码），传入远端的密钥纪元
  /// 三元组以避免回滚远端新纪元（B1-2 修复）。null 时用本地 vault 的值。
  Future<Manifest> _buildLocalManifest({
    String? overrideEncryptedDataKey,
    String? overrideKeyFingerprint,
    int? overrideKeyVersion,
  }) async {
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
        blobKeyEpoch: vault.dataKeyEpoch,
      );
    }
    final localVersion = await database.getManifestVersion(backend.providerKey);

    return Manifest(
      header: ManifestHeader(
        schemaVersion: 1,
        version: localVersion,
        vaultId: _vaultId,
        createdAt: vault.createdAt,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        // B1-2 修复：纪元不匹配时三元组整体采用远端值，避免回滚远端新纪元
        keyFingerprint: overrideKeyFingerprint ?? vault.keyFingerprint,
        keyVersion: overrideKeyVersion ?? vault.keyVersion,
        encryptedDataKey: overrideEncryptedDataKey ?? _encryptedDataKey,
        kdf: vault.kdf,
        dataKeyWrap: kDataKeyWrapAlgorithm,
        dataKeyEpoch: vault.dataKeyEpoch,
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
    List<SyncAction> actions, {
    String? overrideEncryptedDataKey,
    String? overrideKeyFingerprint,
    int? overrideKeyVersion,
  }) async {
    // M1 修复：读取待清理的 uuid 列表（用户硬删除的笔记）
    final purgedUuids = await database.getPurgedUuids();
    final purgedSet = purgedUuids.toSet();

    // Layer 2a: 读取密钥变更后需强制重传 blob 的 uuid 集合。
    // 这些笔记的本地 DB 已用新 dataKey 重加密，但服务器 blob 可能仍是旧密钥，
    // 必须强制用新密钥重新 PUT 覆盖（即使 manifest hash 相同）。
    final pendingReupload = await database.getPendingReuploadUuids();

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
          if (pendingReupload.contains(uuid)) {
            // Layer 2a: 密钥已变更，即使 hash 相同也强制用新 dataKey 重传 blob，
            // 覆盖服务器上可能用旧密钥加密的残留 blob。
            final note = await database.readNoteByUuid(uuid);
            if (note != null) {
              await _uploadNote(note, actions);
            }
            mergedItems[uuid] = localItem;
          } else {
            // 完全一致：跳过
            mergedItems[uuid] = localItem;
            actions.add(SyncAction(type: SyncActionType.skip, uuid: uuid));
          }
        } else {
          // 冲突：LWW 解决
          final winner = _resolveConflict(localItem, remoteItem);
          // E1 修复：冲突副本保留
          // 当 updatedAt 差值 > 5 分钟且 hash 不同时，说明是真冲突（非并发编辑），
          // 败方内容应作为新笔记保留，避免数据丢失。
          // 差值 <= 5 分钟视为并发编辑，走原 LWW 覆盖逻辑。
          final timeDiff = (localItem.updatedAt - remoteItem.updatedAt).abs();
          final shouldPreserveCopy = timeDiff > kConflictPreserveThresholdMs;
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
            // 本地胜：上传覆盖远端
            final note = await database.readNoteByUuid(uuid);
            if (note != null) {
              await _uploadNote(note, actions);
              mergedItems[uuid] = localItem;
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
          actions.add(SyncAction(
            type: SyncActionType.conflict,
            uuid: uuid,
            message: winner == localItem
                ? 'local won (LWW: local newer'
                    '${shouldPreserveCopy ? ', remote preserved as copy' : ''})'
                : 'remote won (LWW: remote newer'
                    '${shouldPreserveCopy ? ', local preserved as copy' : ''})',
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
        schemaVersion: 1,
        version: remote.version + 1,
        vaultId: _vaultId,
        createdAt: vault.createdAt,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        // B1-2 修复：纪元不匹配时密钥纪元三元组整体采用远端值，
        // 避免回滚远端新纪元（keyVersion 回滚会导致守卫下次失效 → 翻转战争）
        keyFingerprint: overrideKeyFingerprint ?? vault.keyFingerprint,
        keyVersion: overrideKeyVersion ?? vault.keyVersion,
        encryptedDataKey: overrideEncryptedDataKey ?? _encryptedDataKey,
        kdf: vault.kdf,
        dataKeyWrap: kDataKeyWrapAlgorithm,
        dataKeyEpoch: vault.dataKeyEpoch,
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
        final envelope = await backend.getBlob(loserItem.hash);
        if (envelope == null) {
          // blob 不存在：无法保留副本，跳过
          return;
        }
        // Layer 1 容错：败方 blob 解密失败（错误 dataKey）时无法保留副本，跳过
        // v1/v2/epoch AAD 三重兼容解密
        final plaintext = _openBlobEnvelope(
          uuid,
          loserItem.hash,
          envelope,
          blobKeyEpoch: loserItem.blobKeyEpoch,
        );
        final content = SafeNote.fromContentBytes(plaintext);

        // 生成新笔记（新 UUID + 新 hash），保留原始创建时间
        final newNote = SafeNote(
          uuid: SafeNote.generateUuid(),
          title: content.title,
          description: content.description,
          contentHash: SafeNote.computeHash(content.title, content.description),
          createdTime: DateTime.fromMillisecondsSinceEpoch(
            loserItem.createdAt,
          ),
          updatedAt: DateTime.now().millisecondsSinceEpoch,
          synced: false,
        );

        // 存入本地数据库
        await database.storeNote(newNote);
        // 上传 blob（新 hash）
        await _uploadNote(newNote, actions);
        // 加入 merged（新 UUID）
        mergedItems[newNote.uuid] = ManifestItem(
          hash: newNote.contentHash,
          deleted: false,
          updatedAt: newNote.updatedAt,
          updatedBy: deviceId,
          createdAt: newNote.createdTime.millisecondsSinceEpoch,
          contentSize: newNote.toContentBytes().length,
        );
      } else {
        // 败方是本地：读取本地笔记，生成新 UUID 存为新笔记
        final localNote = await database.readNoteByUuid(uuid);
        if (localNote == null) return;

        // 生成新笔记（新 UUID + 新 hash），保留原始创建时间和内容
        final newNote = SafeNote(
          uuid: SafeNote.generateUuid(),
          title: localNote.title,
          description: localNote.description,
          contentHash: SafeNote.computeHash(
            localNote.title,
            localNote.description,
          ),
          createdTime: localNote.createdTime,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
          synced: false,
        );

        // 更新本地数据库（新 UUID 的新笔记）
        await database.storeNote(newNote);
        // 上传 blob（新 hash）
        await _uploadNote(newNote, actions);
        // 加入 merged（新 UUID）
        mergedItems[newNote.uuid] = ManifestItem(
          hash: newNote.contentHash,
          deleted: false,
          updatedAt: newNote.updatedAt,
          updatedBy: deviceId,
          createdAt: newNote.createdTime.millisecondsSinceEpoch,
          contentSize: newNote.toContentBytes().length,
        );
      }
    } on Exception {
      // 副本保留失败不阻断主同步流程，记录日志即可
    }
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

    // 加密笔记内容为 envelope（Layer 1：单个 blob 上传失败不应中断整次同步）
    //
    // 协议 v2：AAD 使用内容 hash（与 blob 内容寻址一致）而非 uuid。
    // 原因：blob 按内容 hash 去重，两条内容相同的笔记共享同一个 blob 文件；
    // 若 AAD 绑定 uuid，则该 blob 只能被"上传者的 uuid"解开，
    // 其他引用同一 hash 的笔记在别的设备上永远解密失败（GCM tag 不匹配）。
    // AAD=hash 后任何引用该 hash 的笔记都能解开；防信封错位由下载侧的
    // "解密内容 hash == manifest 记录 hash"校验保证（manifest items 本身
    // 由 dataKey 加密认证，服务器无法伪造）。
    //
    // 注意：新上传的 blob 固定用 v2 AAD（hash，epoch 不写入信封），保证与
    // 旧客户端向后兼容（旧客户端只认 v2/v1 AAD，解不开 "N|hash"）。
    // dataKey 纪元（blobKeyEpoch）只记录在 manifest item 中作为"现代化标记"，
    // 下载侧据此判断是否需重传，blob 信封本身始终用 v2 AAD。
    try {
      final envelope = SyncCrypto.seal(
        _dataKey,
        note.contentHash,
        note.toContentBytes(),
      );
      await backend.putBlob(note.contentHash, envelope);
    } on Object {
      actions.add(SyncAction(
        type: SyncActionType.uploadFailed,
        uuid: note.uuid,
        hash: note.contentHash,
        message: 'blob 上传失败（网络/存储错误），将重试',
      ));
      return;
    }

    actions.add(SyncAction(
      type: SyncActionType.upload,
      uuid: note.uuid,
      hash: note.contentHash,
    ));
  }

  /// 解密 blob 信封（Layer 3 + 协议 v1/v2 三重兼容）
  ///
  /// 尝试顺序：
  ///   1. 若 [blobKeyEpoch] > 0（Layer 3 新格式）→ AAD = '$epoch|$hash'
  ///      —— 用 blob 自己的纪元解开，与「当前 dataKey 纪元」无关；
  ///   2. v2（当前）：AAD = 内容 hash —— 与 blob 内容寻址自洽；
  ///   3. v1（存量）：AAD = 笔记 uuid —— 兼容旧客户端上传的 blob。
  ///
  /// 全部失败则向上抛出（调用方进入 Layer 1/2b/3 容错自愈流程）。
  ///
  /// [dataKeyOverride] 可选：用指定的 dataKey 解密（默认当前 _dataKey）。
  /// repair 流程用它尝试历史密钥（旧 dataKey）。
  Uint8List _openBlobEnvelope(
    String uuid,
    String hash,
    Uint8List envelope, {
    int blobKeyEpoch = 0,
    Uint8List? dataKeyOverride,
  }) {
    final key = dataKeyOverride ?? _dataKey;
    if (blobKeyEpoch > 0) {
      try {
        return SyncCrypto.open(key, hash, envelope, epoch: blobKeyEpoch);
      } on Object {
        // 该 dataKey 解不开该纪元 blob，继续尝试遗留格式兜底
      }
    }
    try {
      return SyncCrypto.open(key, hash, envelope);
    } on Object {
      // 回退旧格式（AAD=uuid）
      return SyncCrypto.open(key, uuid, envelope);
    }
  }

  /// 比较两个 dataKey（字节级相等）
  static bool _sameKey(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
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
      return const _DownloadSuccess();
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
      return _DownloadFailed(uuid);
    }

    // 解密（Layer 1 容错 + Layer 2b 自愈；Layer 3 epoch + v1/v2 AAD 三重兼容）
    try {
      final plaintext = _openBlobEnvelope(
        uuid,
        item.hash,
        envelope,
        blobKeyEpoch: item.blobKeyEpoch,
      );
      final content = SafeNote.fromContentBytes(plaintext);

      // M7 修复：校验解密后内容的 hash 与 manifest 中记录的 hash 一致
      // 防止服务端返回"对的上 uuid、但内容不同"的合法信封
      // 注意：hash 计算使用 SafeNote.computeHash（title\ndescription 格式），
      // 而不是 SyncCrypto.contentHash(plaintext)（JSON 字节格式），两者不一致。
      final actualHash = SafeNote.computeHash(content.title, content.description);
      if (actualHash != item.hash) {
        // 内容 hash 与 manifest 记录不符：blob 内容被篡改/错位（能解密但内容不对）。
        // 这不是密钥问题，不走 _handleDownloadFailure 的自愈/失败流程；
        // 按原 HEAD 行为记为 skip 并保留远端条目供下次重试（M7 回归契约）。
        actions.add(SyncAction(
          type: SyncActionType.skip,
          uuid: uuid,
          hash: item.hash,
          message: 'blob 内容 hash 校验失败（内容被篡改），跳过',
        ));
        return _DownloadFailed(uuid);
      }

      // Layer 3：显式「旧密钥 blob」检测（区分「错密钥可修」与「真损坏不可修」）。
      // 若 manifest 记录的 blobKeyEpoch 与当前 dataKey 纪元不符（且非遗留 0），
      // 说明该 blob 是用「非当前 dataKey」加密的旧密钥 blob（或纪元标记过期）。
      // 内容虽能解开（dataKey 实际一致），仍用当前纪元重传一次以现代化（自愈），
      // 并让合并 manifest 改为引用修复后的纪元，避免后续每次同步重复告警/重试。
      // 遗留 blob（blobKeyEpoch==0）按向后兼容处理：能解开即接受，不强制重传，
      // 避免对存量海量 blob 造成一次性全量 churn。
      if (item.blobKeyEpoch > 0 && item.blobKeyEpoch != vault.dataKeyEpoch) {
        // 用当前纪元重传 blob（现代化），需把 record 还原成 SafeNote 再上传
        final note = SafeNote(
          uuid: uuid,
          title: content.title,
          description: content.description,
          contentHash: item.hash,
          deleted: false,
          createdTime: DateTime.fromMillisecondsSinceEpoch(item.createdAt),
          updatedAt: item.updatedAt,
          synced: true,
        );
        await _uploadNote(note, actions);

        // 物化到本地（与正常下载路径一致），避免本地库缺失该笔记，
        // 同时让本次同步的 downloaded 计数反映已获取到的内容。
        final existing = await database.readNoteByUuid(uuid);
        final stored = SafeNote(
          id: existing?.id,
          uuid: uuid,
          title: content.title,
          description: content.description,
          contentHash: item.hash,
          deleted: false,
          createdTime: existing?.createdTime ??
              DateTime.fromMillisecondsSinceEpoch(item.createdAt),
          updatedAt: item.updatedAt,
          synced: true,
        );
        if (existing == null) {
          await database.storeNote(stored);
        } else {
          await database.updateNoteByUuid(stored);
        }
        actions.add(SyncAction(
          type: SyncActionType.download,
          uuid: uuid,
          hash: item.hash,
        ));
        actions.add(SyncAction(
          type: SyncActionType.heal,
          uuid: uuid,
          hash: item.hash,
          message: 'blob 纪元(${item.blobKeyEpoch})与当前(${vault.dataKeyEpoch})'
              '不符，已用当前纪元重传',
        ));
        return _DownloadHealed(ManifestItem(
          hash: item.hash,
          deleted: item.deleted,
          updatedAt: item.updatedAt,
          updatedBy: deviceId,
          createdAt: item.createdAt,
          deletedAt: item.deletedAt,
          contentSize: item.contentSize,
          blobKeyEpoch: vault.dataKeyEpoch,
        ));
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
        createdTime: existing?.createdTime ??
            DateTime.fromMillisecondsSinceEpoch(item.createdAt),
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
      return _DownloadSuccess(item);
    } on Object {
      // Layer 1 容错：解密/解析/校验失败（坏 blob、错误 dataKey、数据损坏）
      // 不应中断整次同步。转交自愈逻辑处理（本地有明文则重传覆盖，否则记录失败）。
      final healed = await _handleDownloadFailure(uuid, item, actions);
      return healed != null
          ? _DownloadHealed(healed)
          : _DownloadFailed(uuid);
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
    final local = await database.readNoteByUuid(uuid);
    if (local != null && !local.deleted) {
      try {
        await _uploadNote(local, actions);
        actions.add(SyncAction(
          type: SyncActionType.heal,
          uuid: uuid,
          hash: local.contentHash,
          message: 'blob 密钥不匹配，已用本机明文自愈重传',
        ));
        // 返回修复后的 manifest 条目：hash 取本地明文 hash，
        // 使合并后的 manifest 指向刚重传的（好）blob，避免修复后的 blob 成孤儿。
        // blobKeyEpoch 取当前纪元（重传时已用当前纪元加密）。
        return ManifestItem(
          hash: local.contentHash,
          deleted: false,
          updatedAt: local.updatedAt,
          updatedBy: deviceId,
          createdAt: local.createdTime.millisecondsSinceEpoch,
          contentSize: local.toContentBytes().length,
          blobKeyEpoch: vault.dataKeyEpoch,
        );
      } on Object {
        // 自愈上传也失败：退化为记录失败，不抛
      }
    }

    // 去重自愈：本机没有该 uuid 的明文，但可能存在"内容相同"的孪生笔记。
    //
    // 场景：blob 按内容 hash 寻址去重，两条内容相同的笔记（不同 uuid）
    // 共享同一个 blob；旧协议（AAD=uuid）下该 blob 只能被上传者的 uuid
    // 解开，其他 uuid 在本机必然解密失败。若本机恰好持有内容相同的
    // 孪生笔记（content_hash == remoteItem.hash），则：
    //   1. 用孪生明文在本地物化该 uuid 的笔记（保留远端时间戳元数据）；
    //   2. 用当前协议（AAD=hash）重传 blob，让所有设备都能解开。
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
            createdTime: existing?.createdTime ??
                DateTime.fromMillisecondsSinceEpoch(remoteItem.createdAt),
            updatedAt: remoteItem.updatedAt,
            synced: true,
          );
          if (existing == null) {
            await database.storeNote(materialized);
          } else {
            await database.updateNoteByUuid(materialized);
          }

          // 2) 重传 blob（_uploadNote 现用 AAD=hash，重传后全网可解）
          await _uploadNote(materialized, actions);
          actions.add(SyncAction(
            type: SyncActionType.heal,
            uuid: uuid,
            hash: remoteItem.hash,
            message: '共享 blob 旧格式解密失败，已用本机同内容孪生笔记自愈',
          ));
          // hash 不变（内容相同），保留远端条目即可正确引用重传后的 blob。
          // blobKeyEpoch 更新为当前纪元（重传时已用当前纪元加密）。
          return remoteItem.copyWith(blobKeyEpoch: vault.dataKeyEpoch);
        }
      } on Object {
        // 孪生自愈失败：退化为记录失败，不抛
      }
    }

    // 无本地明文可用：记录失败，保留远端条目供下次重试。
    // Layer 3 区分：若 blob 纪元与当前不符，说明是「旧密钥 blob」（可用旧密码
    // 经 repair 流程修复）；否则是「真损坏」不可自动修复。两种情况均记入
    // failedNoteUuids，UI 提示用户运行「修复同步数据」。
    final isOldKey = remoteItem.blobKeyEpoch > 0 &&
        remoteItem.blobKeyEpoch != vault.dataKeyEpoch;
    actions.add(SyncAction(
      type: SyncActionType.corrupt,
      uuid: uuid,
      hash: remoteItem.hash,
      message: isOldKey
          ? 'blob 为旧密钥加密（纪元 ${remoteItem.blobKeyEpoch}≠当前'
              ' ${vault.dataKeyEpoch}），无本地明文，需用旧密码运行修复'
          : 'blob 下载失败（数据损坏且无本地明文，将重试）',
    ));
    return null;
  }

  /// 从操作记录中提取"未能同步且无本地明文可自愈"的笔记 uuid 列表
  List<String> _failedUuids(List<SyncAction> actions) =>
      actions.where((a) => a.type == SyncActionType.corrupt).map((a) => a.uuid).toList();

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

  /// F1 修复：孤儿 blob 垃圾回收
  ///
  /// manifest PUT 成功后调用。流程：
  ///   1. listBlobs() 获取远端所有 blob hash
  ///   2. merged.items 中的 hash 集合 = 当前引用的 blob
  ///   3. 远端有但 manifest 不引用的 = 孤儿 blob，删除
  ///
  /// 安全性：
  ///   - listBlobs 返回空（后端不支持枚举）时跳过 GC，保守不删
  ///   - 单个 blob 删除失败不阻断整体 GC
  ///   - 整体 GC 失败不阻断同步（下次同步重试）
  ///
  /// 注意：并发同步场景下，A 设备正在 GC 时 B 设备可能正在上传新 blob。
  /// 此时 A 设备的 listBlobs 可能包含 B 刚上传但还未写入 manifest 的 blob，
  /// 误判为孤儿删除。缓解：manifest 引用的 blob 一定不会被删（referenced 集合保护）。
  /// 极端情况下删除了 B 正在上传的 blob，B 下次同步会重新上传（putBlob 幂等）。
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
      final orphans = remoteBlobs.where((h) => !referenced.contains(h));
      for (final hash in orphans) {
        try {
          await backend.deleteBlob(hash);
        } on Exception {
          // 单个 blob 删除失败不阻断整体 GC
        }
      }
    } on Exception {
      // GC 失败不阻断同步，下次同步重试
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

  /// D3 修复：判断本次同步是否有实际变更需要 PUT manifest
  ///
  /// 返回 false 时跳过 PUT，避免 blob 持续下载失败等场景下 manifest version
  /// 无意义 +1 攀升。判定"有实际变更"的条件（任一满足即需 PUT）：
  ///   1. actions 中存在 upload/download/delete 类型（有成功的传输或墓碑应用）
  ///   2. 纪元不匹配或需推送新 encryptedDataKey（overrideEncryptedDataKey != null）
  ///   3. merged.items 与 remote.items 不一致（键集或任一条目字段不同）
  ///   4. header 关键字段变化（encryptedDataKey / keyFingerprint / keyVersion）
  bool _hasEffectiveChange({
    required List<SyncAction> actions,
    required Manifest merged,
    required Manifest? remote,
    required bool epochMismatch,
    String? overrideEncryptedDataKey,
  }) {
    // 纪元不匹配或需推送新 encryptedDataKey：必须 PUT
    if (epochMismatch || overrideEncryptedDataKey != null) {
      return true;
    }

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
      if (merged.items[key] != remoteItem) {
        return true; // 条目字段不同
      }
    }

    // items 完全一致且无传输操作：无实际变更，跳过 PUT
    return false;
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
