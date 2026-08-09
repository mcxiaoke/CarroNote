# Journal 文件格式规范（本地日志 + 远端加密副本）

> 适用范围：本文件描述 SafeNotes 同步 **操作日志（Journal）** 的格式。
> Journal 承担双角色：审计/可观测 + 可恢复（防服务端 manifest 单点故障的第二数据源）。
>
> 权威实现：`packages/core/lib/src/sync/journal.dart`
> （`Journal` / `JournalEntry` / `JournalKeyState` / `JournalEventType` / `JournalPhase`）。
> 协议版本常量：`kJournalSchemaVersion = 1`。

---

## 1. 角色与设计边界

### 1.1 职责

- **审计/可观测**：记录"谁、何时、用哪个 dataKey 纪元"做了什么，使冲突与自愈可诊断
  （替代"blob 自描述"方案，不污染 blob 格式）。
- **可恢复**：作为跨边界部分写的兜底（blob 已重写但 manifest item 未更新）、
  本地库被清、服务端 manifest 损坏、坏纪元污染 key state 时的第二数据源。

### 1.2 边界（非常重要）

- **进程内崩溃原子性由 SQLite 事务负责，Journal 不替代它**。
  `reEncryptAllNotes` 等批量写已在单事务内，事务内崩溃自动回滚，Journal 不参与。
- Journal 覆盖 SQLite 管不到的失效模式：跨边界部分写、本地库被清、
  服务端 manifest 损坏、坏纪元污染 key state。

### 1.3 写入约束

- **不在 DB 事务内写**（事务回滚会让 journal 与 DB 不一致）；采用
  "记录意图(start) → DB 事务提交后记录完成(done)"两段式，恢复时以 DB 实际状态为准。
- 内存缓冲 + 批量异步 flush（累积 50 条或 100ms），不阻塞同步主流程。
- **绝不抛异常**：journal 自身任何故障都不得打断同步主流程。

---

## 2. 本地存储布局

```
<baseDir>/journal/
├── log.json              # 当前日志（明文 JSON）
├── log-<seq>.json        # 归档（保留最近 3 个，<seq> 为归档时最后一条 seq）
└── .journal-state.json   # 本地状态（远端上传水位 uploadedSeq）
```

- 滚动阈值：**1000 条** 或 **100KB**（先到者），归档保留 **3 份**
  （`kJournalMaxEntries` / `kJournalMaxBytes` / `kJournalArchiveKeep`）。
- flush 阈值：累积 **50 条**（`kJournalFlushBatchSize`）或 **100ms**
  （`kJournalFlushInterval`）落盘。
- 写盘原子性：先写 `log.json.tmp` 再 `rename`，避免半写损坏。
- 损坏处理：当前日志解析失败时重命名为 `log.json.corrupt-<ts>` 保留取证，
  以空日志继续工作（journal 自身的损坏绝不能阻断同步）。

---

## 3. 当前日志文件格式（明文 JSON）

`log.json` 顶层结构（`Journal._writeLogFile`）：

```json
{
  "schemaVersion": 1,
  "vaultId": "<vaultId>",
  "deviceId": "<deviceId>",
  "entries": [ <JournalEntry>, ... ]
}
```

| 顶层字段      | 类型     | 说明                                          |
|---------------|----------|-----------------------------------------------|
| `schemaVersion`| int     | 日志文件格式版本，当前 `1`                   |
| `vaultId`     | string   | 所属 vault，用于防串库（不匹配则隔离重开）    |
| `deviceId`    | string   | 记录者设备 ID                                  |
| `entries`     | array    | 日志条目数组（按 seq 升序）                   |

---

## 4. JournalEntry 条目格式

每条 `JournalEntry.toJson`：

```json
{
  "seq": 12,
  "ts": 1719470000000,
  "type": "note.upsert",
  "phase": "start",
  "uuid": "uuid-xxx",
  "hash": "sha256hex...",
  "dataKeyEpoch": 1,
  "by": "android-xxx",
  "opId": "1719470000000-abcdef",
  "keyState": { "keyVersion": 1, "dataKeyEpoch": 1, "keyFingerprint": "hex", "encryptedDataKey": "base64" },
  "note": "人类可读说明"
}
```

| 字段           | 类型    | 必含 | 说明                                                                 |
|----------------|---------|------|----------------------------------------------------------------------|
| `seq`          | int     | 是   | 设备内全局单调递增序号（跨归档文件连续，不 per-file 重置）            |
| `ts`           | int     | 是   | 事件时间戳（Unix 毫秒）                                              |
| `type`         | string  | 是   | 事件类型（见 §5 枚举表）                                             |
| `phase`        | string  | 否   | 事件阶段，默认 `"none"`；见 §6                                       |
| `uuid`         | string  | 否   | 相关笔记 uuid（笔记类事件）                                          |
| `hash`         | string  | 否   | 相关 blob 内容 hash                                                   |
| `dataKeyEpoch` | int     | 否   | 事件发生时所用的 dataKey 纪元（仅记录，不参与 journal 内部时序判断） |
| `by`           | string  | 是   | 记录者设备 ID                                                         |
| `opId`         | string  | 否   | 跨步操作关联 id（start/done 配对用）                                 |
| `keyState`     | object  | 否   | 仅 key.* 事件携带（见 §7）                                          |
| `note`         | string  | 否   | 可选人类可读说明（**不参与任何机器判定**）                           |

- 解析容错：`fromJson` 对格式不合法或未知类型的条目返回 `null`，跳过坏条目而非整体失败。
- 安全边界：条目只含 uuid / contentHash / 纪元号 / 设备号，**不含笔记明文**；
  `key.*` 条目携带的 `encryptedDataKey` 是 MK 包裹态，暴露面与本地 `sync_meta`
  的 `keyring` 键、远端 manifest 明文 header 完全一致，不引入新泄露面。

---

## 5. 事件类型（`JournalEventType`）

wire 值即下方字符串，沿用设计文档的点分命名空间：

| 类型 wire 值            | 含义                                                         |
|-------------------------|--------------------------------------------------------------|
| `note.upsert`           | 笔记新增/更新（上传 blob 或下载落库）                        |
| `note.delete`           | 笔记删除（墓碑）                                             |
| `note.conflict`         | LWW 冲突裁决（谁赢、是否保留败方副本）                       |
| `note.heal`             | 自愈：用历史密钥解密并重新上传                               |
| `blob.reupload`         | blob 重传（纪元变化后的重新加密上传）                        |
| `key.changePassword`    | 改密码（MK 变化，dataKey 不变）                              |
| `key.migrate`           | dataKey 迁移（scenario-c/d，dataKey 真的变了）               |
| `key.adoptEpoch`        | 采纳远端纪元（他端改密码后本端同步纪元三元组）               |
| `sync.gcOrphan`         | 孤儿 blob 垃圾回收                                           |
| `sync.manifestRebuild`  | 远端 manifest 损坏并重建（第二数据源价值最高的事件）         |
| `sync.manifestPut`      | manifest PUT 成功/失败（常规路径节点）                       |
| `sync.optimisticLockRetry`| 乐观锁冲突重试（ETag 不匹配回退重试）                     |

> 解析时 `JournalEventType.fromWire` 对未知值返回 `null`（跳过而非崩溃）。
> 其中 `key.changePassword` / `key.migrate` / `key.adoptEpoch` 为密钥事件
> （`isKeyEvent`），用于 `replayKeyState` 过滤。

---

## 6. 事件阶段（`JournalPhase`）

机器可读阶段字段（替代设计文档中括号写法的脆弱自然语言）：

| phase wire 值 | 含义                                                       |
|---------------|------------------------------------------------------------|
| `none`        | 无阶段（一次性事件）                                      |
| `start`       | 意图已记录，副作用尚未确认完成                            |
| `done`        | 副作用已完成（DB 事务已提交）                             |
| `failed`      | 操作失败/放弃（避免 start 悬挂被误判为需重放）            |
| `isolated`    | GC：已移入隔离区（软删除）                               |
| `purged`      | GC：隔离区超期结算，物理删除                             |

两段式记录示例：`key.migrate(start)` → DB 事务提交 → `key.migrate(done)`。

---

## 7. keyState（密钥状态三元组 + 包裹态）

仅 `key.*` 事件携带（`JournalKeyState.toJson`）：

```json
{
  "keyVersion": 1,
  "dataKeyEpoch": 1,
  "keyFingerprint": "hex(MK)",
  "encryptedDataKey": "base64..."
}
```

| 字段             | 类型   | 说明                                              |
|------------------|--------|---------------------------------------------------|
| `keyVersion`     | int    | 密钥版本号                                        |
| `dataKeyEpoch`   | int    | dataKey 纪元                                      |
| `keyFingerprint` | string | `H(MK)` 指纹                                      |
| `encryptedDataKey`| string| 包裹态 `AES-GCM(MK, dataKey)`，不含 raw dataKey/MK |

用途：`replayKeyState()` 从所有 `key.*` 事件中取**最新一条已完成**的 `keyState`
（按 seq），作为坏纪元污染 key state 时取真来源。注意：调用方**必须验证**
还原出的 `encryptedDataKey` 能被当前 MK 解开，再决定是否采纳。

---

## 8. 远端加密副本

### 8.1 上传

同步成功后，把"未上传的归档 + 当前日志尾部"整体 `AES-GCM(dataKey)` 加密
（AAD = `'journal-archive'`，`kJournalAad`），经 `SyncBackend` 的 journal 资源接口
写到远端 `journal/` 目录（`journal.dart.syncToRemote`）。**远端永不写明文。**

- 后端不支持 journal 资源接口时**静默降级**（journal 保持本地-only）。
- **绝不抛异常**：失败只记日志。
- 远端对象命名（按设备隔离，防多端互相覆盖）：
  - 当前日志：`<deviceId>-current.json`
  - 归档：`<deviceId>-archive-<seq>.json`

### 8.2 远端副本文件格式

远端副本是**本地 `log.json` 的密文**（即 §3 的明文结构先 `jsonEncode`，
再 `SyncCrypto.seal(dataKey, 'journal-archive', bytes)`）。解密后得到与本地
一致的 `{ schemaVersion, vaultId, deviceId, entries }` 结构。

### 8.3 拉取合并（第二数据源）

`Journal.fetchRemoteEntries(backend, dataKey)` 列举远端所有 `journal/*.json`，
解密后按 `(by, seq)` 去重、按 `ts` 升序合并。解密失败的对象被跳过
（可能是别的 vault / 旧 dataKey 纪元的副本）。用于本地库与本地 journal 均丢失
（重装 App）且服务端 manifest 不可信时，重建 key state 与近期变更序列。

---

## 9. 关键常量速查

| 常量                          | 值    | 含义                          |
|-------------------------------|-------|-------------------------------|
| `kJournalSchemaVersion`       | 1     | 日志文件格式版本              |
| `kJournalMaxEntries`          | 1000  | 单文件最大条目数              |
| `kJournalMaxBytes`            | 100KB | 单文件最大字节数              |
| `kJournalArchiveKeep`         | 3     | 归档保留份数                  |
| `kJournalFlushBatchSize`      | 50    | 批量 flush 条目阈值           |
| `kJournalFlushInterval`       | 100ms | 批量 flush 时间阈值           |
| `kJournalAad`                 | `'journal-archive'` | 远端副本 AES-GCM AAD |
