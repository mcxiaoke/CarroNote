# 重型随机混沌测试方案（多客户端 + 改密码随机交织）

> 状态：设计文档（待评审后实现）
> 日期：2026-07-29
> 目标：用"2–3 个客户端 + 随机时序 + 随机改密码"的混沌驱动，验证同步引擎在乱序/交织数据流下不丢数据、不腐内容、最终收敛，并重点压测刚落地的密钥纪元（keyVersion / dataKeyEpoch / blobKeyEpoch）与迁移/repair 逻辑。

## 0. 已确认的范围决策（来自用户）

1. **先出设计文档**，确认后再实现。
2. 数据用**克隆的 118 测试副本**（`temp/safenotes-vault`），不碰 192.168.1.118 远端；用户明确"那是测试服务器上的测试数据，随便用"。
3. **包含随机改密码混沌**（高价值、最易暴露 bug）。

## 1. 为什么需要这个测试

同步引擎的状态空间极小但组合极复杂：

- `keyVersion`：改密码 +1，**dataKey 不变**。
- `dataKeyEpoch`：仅 dataKey **值**真正变化（迁移场景）才 +1。
- `blobKeyEpoch`：每项 blob 的现代化标记。
- MK 缓存、密码纪元不匹配检测、`migrateToRemote`、`repairRemote`、冲突处理、孪生自愈。

确定性场景测试（Layer 1/2a/2b/3、孪生、repair）覆盖"已知剧本"，但抓不到**涌现式排序 bug**——典型就是"改密码与一次在途 push/pull 撞车""两端几乎同时 PUT manifest"。混沌测试是这套密钥逻辑最合适的安全网。

**关键纪律**（无此则测试是噪音）：
- 种子可复现（`Random(seed)`，失败打印 seed + 全轨迹，同 seed 重跑）。
- 断言**不变量**而非精确终态（随机时序下终态不可预测）。
- 每次运行**克隆**后端目录，绝不污染原件。
- 带"冷却收敛尾"（无操作只同步若干轮）后再断言。

## 2. 架构总览

```
ChaosHarness
 ├─ sharedBackend : LocalFsBackend(rootPath = cloneDir)   // 克隆的 118 副本
 ├─ sharedDataKey : Uint8List                              // vault 级，改密码不变
 ├─ knownPasswords : Set<String>                           // 改密后广播，供他端重派生
 ├─ model : LogicalModel                                  // 逻辑真值（uuid→{contentHash,deleted}）
 ├─ clients : List<ChaosClient>  (2–3 个)
 └─ run(seed): 随机驱动 N 步 → 冷却 → assertInvariants()

ChaosClient
 ├─ id : String ('A'/'B'/'C')
 ├─ db : NotesDatabase (独立 in-memory SQLite)
 ├─ vault : Vault (各自本地 meta 状态)
 └─ activate(): NotesDatabase.setDatabaseForTesting(db) + setDataKey(sharedDataKey)
```

### 2.1 后端与数据隔离

- 每次 `run(seed)` 先把 `temp/safenotes-vault` 深拷贝到 `temp/chaos/run-<seed>/safenotes-vault`。
- `final backend = LocalFsBackend(rootPath: cloneDir);` —— 其布局正是 `manifest.json` + `blobs/<hash>`，与克隆目录一致。
- **原件永不读写**：所有操作只针对克隆目录。

### 2.2 打开真实库（118 副本）

```
final resp = await backend.getManifest();          // 取远端 manifest 字节
final header = ManifestCrypto.parseHeader(resp.bytes); // 解析 header
Vault vault;
for (final pw in ['hello.3333', 'hello.4444']) {
  try {
    vault = await Vault.unlockFromRemoteManifest(
      password: pw,
      remoteVaultId: header.vaultId,
      remoteEncryptedDataKey: header.encryptedDataKey,
      remoteKdf: header.kdf,
      remoteKeyFingerprint: header.keyFingerprint,
      remoteKeyVersion: header.keyVersion,
      remoteDataKeyEpoch: header.dataKeyEpoch,
      remoteCreatedAt: header.createdAt,
      database: clientDbA,
    );
    break;
  } on WrongPasswordException {
    // 试下一个密码
  }
}
sharedDataKey = vault.dataKey;   // vault 级 dataKey，所有客户端共享同一字节
```

- `sharedDataKey` 由解锁得到，所有客户端共用（dataKey 是 vault 级，与设备/密码无关，改密码也不变）。
- 每个客户端各自 `unlockFromRemoteManifest`（用同一密码）得到**各自**的 `Vault` 对象（各自维护本地 keyVersion/epoch 认知）。

### 2.3 为什么是"串行多客户端"驱动

`NotesDatabase` 是单例（`setDatabaseForTesting` 全局唯一），现有多端测试也是串行切换单例 DB 跑的。这与真实部署一致——**每台设备各自本地库、共享远端后端**。因此混沌驱动采用：

> 每一步：选一个客户端 → `client.activate()`（切全局 DB + dataKey）→ 执行该客户端的随机操作（await）→ 进入下一步。

后端（克隆目录）看到的是来自不同"设备"、随机交织、随机延迟的操作流，正是多设备乱序的本质。真·异步并发（不等 await 同时发 sync）因单例 DB 不可用，但**乱序交织的价值已覆盖**，且避免了单例重构风险。

## 3. 操作模型（Op）

`Op` 枚举 + 参数，由种子化 RNG 选取：

| Op | 说明 | 对 model 的影响 |
|---|---|---|
| `create` | 随机标题/正文 → `storeNote` → 可选随即 `sync` | 新增 uuid→{contentHash, deleted:false} |
| `edit` | 随机选该客户端本地已知 uuid → 改内容 → `storeNote` | 更新该 uuid 的 contentHash |
| `delete` | 随机选本地已知 uuid → 标删 → `storeNote` | 标记 deleted:true（墓碑） |
| `push`/`pull` | 显式 `engine.sync()`（随机决定本步是否同步，以制造分歧） | 无（仅同步） |
| `changePassword` | 随机新密码 → `vault.changePassword` → **广播**到 `knownPasswords` | 触发 keyVersion+1；dataKey 不变 |

- **随机延迟**：每步 `await Future.delayed(Duration(milliseconds: rng.nextInt(120)))` 交错异步，激发布局并发（如两端接近同时 PUT manifest，引擎须靠合并保持正确）。
- **操作权重**：`create/edit/delete/sync/changePassword` 各有概率，可配置；`changePassword` 概率较低（如 5–8%）以避免全在改密码。

### 3.1 改密码如何模拟（关键）

真实中 A 改密后，B（旧密码会话）解不开 A 的新 meta → 引擎报 `passwordEpochMismatch` 并需用户重输。测试中：

1. A 调用 `vault.changePassword(newPw)` → keyVersion+1、重新包裹 encryptedDataKey、`appendDataKeyHistory` 归档旧 wrappedDataKey。
2. 把 `newPw` 加入全局 `knownPasswords`（模拟"用户在所有设备上更新了密码"）。
3. 其他客户端下次 `sync()` 若遇 `passwordEpochMismatch`（SyncResult.passwordEpochMismatch == true）， harness 用 `knownPasswords` 中某个密码重新 `unlockFromRemoteManifest` 刷新本地 Vault 的 keyVersion/encryptedDataKey，再继续。

这正好把刚写的**密钥纪元 / 迁移 / repair** 路径全跑一遍。

## 4. 逻辑真值模型（LogicalModel）

为避免"精确终态不可预测"的问题，harness 维护一个**逻辑真值**：

- 初始化：打开克隆库后，读远端 manifest 的 items，把每个 uuid 的 `{contentHash, deleted}` 作为基线写进 model（真实 118 数据本来就有笔记，必须纳入，否则会被判"幽灵"）。
- 每次 `create/edit/delete` 操作后，**乐观更新** model 中该 uuid 的最终意图状态。
- `changePassword` 不影响 model 的笔记内容（dataKey 不变）。

> 注意：`edit` 只能作用于"该客户端本地已知"的 uuid（从 `readAllNotes` 取），保证不会出现凭空编辑不存在的 uuid。

## 5. 不变量断言（核心断言）

冷却尾结束后，对每个客户端执行最终 `sync()`，然后逐条检查：

1. **无数据丢失**：model 中 `deleted==false` 的每个 uuid，在**所有**客户端的本地库中均存在，且解密后 `contentHash == model.contentHash`。
2. **无内容腐坏**：任意客户端下载/读取到的笔记明文，其 hash 必等于 model 记录（M7 校验已保证；此处作为端到端兜底）。
3. **收敛性**：所有客户端的 `(uuid → contentHash)` 集合在冷却后**完全一致**（墓碑状态也须一致）。
4. **无幽灵笔记**：任意客户端本地存在、却不在 model 中的 uuid → 判失败（除非是基线里已有的）。
5. **密钥一致性**：改密码 + 冷却后，所有客户端的 `vault.keyVersion` 相等，且都能用 `sharedDataKey` 解密各自 blob（无 `passwordEpochMismatch` 残留）。
6. **manifest 完整性**：每个客户端都能 `getManifest()` + 解密；无客户端陷入不可恢复的纪元不匹配。
7. **（可选）无遗留坏 blob**：冷却后跑一次 `repairRemote` dry-run（或检查 `failedNoteUuids` 为空）。

## 6. 确定性 & 回放

- `run(seed)`：用 `Random(seed)` 驱动所有随机选择；`seed` 打印到测试输出。
- 每步追加 `OpRecord{step, clientId, opType, uuid, arg, keyVersionBefore, passwordEpochBefore}` 到 `trace`。
- 失败时：打印 seed + 完整 trace + 首个不满足的不变量与涉及 client/uuid；提供"回放模式"——传入已记录的 trace 文件，严格按序重放以稳定复现。
- 建议 CI/手动跑多个固定 seed（如 1、7、42、2026、99999）外加每夜一个随机 seed。

## 7. 文件与运行

- 新增 `test/sync/chaos_multi_client_test.dart`，含：
  - `ChaosClient` / `ChaosHarness` / `LogicalModel` / `OpRecord`。
  - `group('混沌 - 真实数据(118克隆)')`：含改密码变体（默认开）。
  - `group('混沌 - 全新空库')`：从空 LocalFsBackend 起（对照变体 A，可选）。
- 共享辅助：`_cloneVault(src, dst)`、`_openRealVault(backend, db)`（试两个密码）、`_activate(client)`。
- 运行：`flutter test test/sync/chaos_multi_client_test.dart`（本地，不触 118）。
- **定位**：先作为手动/定期重型测试，**不立即设为 CI 阻塞门**；稳定若干 seed 后再考虑纳入。

## 8. 风险与边界

- 单例 DB 使"真异步并发"不可行 → 已用串行交织替代，覆盖主要价值。
- 随机测试若频繁失败需先排查是真 bug 还是断言过严；不变量要尽量"宽松但正确"。
- 真实 118 数据若含超大 blob，会拖慢；克隆时按需可只取 manifest + 少量 blob（但为真实恢复场景，建议整目录克隆）。
- `hello.3333/4444` 若都打不开克隆库（副本可能已另设密码），harness 应明确失败并提示，不静默跳过。

## 9. 实现步骤（落地清单）

1. 在 `test/sync/` 加 `chaos_multi_client_test.dart`，先写 fixture 辅助（`_cloneVault` / `_openRealVault`）。
2. 实现 `LogicalModel`（基线播种 + 乐观更新）。
3. 实现 `ChaosClient`（独立 DB + activate + 各 Op 执行）。
4. 实现 `ChaosHarness.run(seed)`：驱动循环 + 随机延迟 + 改密码广播 + trace 记录。
5. 实现 `assertInvariants()`（第 5 节 7 条）。
6. 接 `setUpAll` 初始化 `sqfliteFfi`，`tearDown` 清理克隆目录。
7. 先跑 `seed=1` 单 seed 验证骨架，再扩展到多 seed 与空库对照。
8. 发现 bug → 修引擎 → 同 seed 复现验证 → 记入 `CHANGES-20260729.md`。

## 10. 预期收益

- 在真实 118 数据形态上，端到端验证迁移/纪元/repair 不破坏既有笔记。
- 以最小成本（种子化、不变量、克隆隔离）获得"多设备乱序 + 改密码交织"的健壮性证据。
- 任何失败都带 seed + trace，可一键复现，避免 flaky 噪音。
