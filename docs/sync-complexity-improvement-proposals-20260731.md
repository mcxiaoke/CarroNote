# SafeNotes 同步复杂度改进建议

> 生成时间：2026-07-31 15:58:40（Asia/Shanghai）
> 配套文档：[sync-complexity-analysis-20260731.md](./sync-complexity-analysis-20260731.md)（分析报告）
> 目标：在不破坏核心架构（三层分离 + 抽象 backend + ETag 乐观锁 + 两层密钥 MK/dataKey）的前提下，降低同步子系统的复杂度，重点是让 debug 变容易。
> 原则：增量改造、可回退、不破坏协议。所有方案按"投入产出比"排序，可独立实施。

---

## 0. 复杂度根源（速览）

详情见分析报告，这里只列与改进直接相关的四点：

1. **`sync_engine.dart` 单文件 1800+ 行**，注释里能看到 20+ 个编号补丁（B1/B3/D2/D3/E1/F1/H1/H3/H4/L3/M1/M7/P0-x/P1-x/R10）。
2. **错误处理混乱**（debug 难的直接原因）：
   - 8+ 处 `on Object` 兜底吞掉所有错误类型信息（pointycastle 的 `InvalidTag` 继承 `Error` 而非 `Exception`）
   - 中英文消息混用，`SyncAction.message` 字段格式不统一
   - 多处静默吞异常（备份失败、GC 失败、跨文件系统 rename 失败）
3. **可观测性差**：状态机和操作记录都有，但诊断信息塞在 `SyncAction.message` 字符串里，无机器可解析 schema，无历史 metrics，无统一日志。`webdav_backend.dart` 有 logger，其他 4 个核心文件完全没日志。
4. **隐藏状态分散**：DB 的 `sync_meta` 表 7+ 个键、文件系统 4 类辅助文件、内存 6+ 个非 final 可变字段、3 个全局单例。

---

## 1. 改进方向总览

| 方向 | 收益 | 代价 | 推荐度 |
|------|------|------|--------|
| **A. 统一错误类型 + 结构化日志** | debug 立刻变容易，最高 ROI | ~200 行改动 | ⭐⭐⭐⭐⭐ 立即做 |
| **E. 调试面板** | 排查问题不用打日志重跑 | ~150 行 | ⭐⭐⭐⭐⭐ 立即做 |
| **B. 拆分 sync_engine.dart** | 单文件可读性、单点测试 | 纯重构，中等 | ⭐⭐⭐⭐ 第二阶段 |
| **C. 隐藏状态收拢** | 减少"为什么这个状态变了"的排查 | 中等 | ⭐⭐⭐ 第二阶段 |
| **D. 砍掉部分容错层** | 显著减少代码 | 需评估用户场景 | ⭐⭐ 谨慎评估 |

建议执行顺序：**A + E 先做**（合计 ~350 行，立刻见效）→ B + C 结构性重构 → D 谨慎评估。

---

## 2. 方向 A：统一错误类型 + 结构化日志

### 2.1 问题

当前错误处理有三个具体毛病：

1. **`on Object` 滥用**（[sync_engine.dart](file:///c:/Home/Projects/safenotes/lib/sync/sync_engine.dart) 行 554、1254、1295、1301、1513、1570、1619、1640）：捕获范围过大，把 `StateError`、`ArgumentError`、`ConcurrentModificationError` 等编程 bug 也当成"解密失败"容错掉了，调试时直接丢失根因。
2. **`SyncAction.message` 是裸字符串**：格式不统一（中英文混用、有的带状态码有的不带、有的带异常链有的不带），UI 显示不一致，也无法做聚合分析。
3. **静默吞异常**：[local_fs_backend.dart](file:///c:/Home/Projects/safenotes/lib/sync/local_fs_backend.dart) 行 137-138、210-212 等，失败完全无记录。

### 2.2 方案

**A1. 用 sealed class 统一错误分类**

```dart
// lib/sync/sync_error.dart（新建，约 80 行）
sealed class SyncError {
  final String operation;   // 'getManifest' / 'putBlob' / 'decryptEnvelope' 等
  final String? noteUuid;   // 涉及的笔记，可空
  final Object? cause;      // 原始异常/错误
  const SyncError({required this.operation, this.noteUuid, this.cause});
}

class DecryptionError extends SyncError {       // GCM tag 校验失败、AAD 不匹配
  const DecryptionError({super.operation, super.noteUuid, super.cause});
}
class ManifestCorruptError extends SyncError {  // manifest JSON 解析失败
  const ManifestCorruptError({super.operation, super.cause});
}
class BlobMissingError extends SyncError {      // 404，blob 不存在
  const BlobMissingError({super.noteUuid, super.cause});
}
class NetworkError extends SyncError {          // 超时、连接失败
  final int? statusCode;
  const NetworkError({super.operation, this.statusCode, super.cause});
}
class KeyMismatchError extends SyncError {      // 密码不匹配 / 旧密钥纪元
  const KeyMismatchError({super.operation, super.cause});
}
```

然后**逐个替换 `on Object`**：

```dart
// 改造前（sync_engine.dart 行 1254）
try {
  envelope = await _openBlobEnvelope(...);
} on Object catch (e) {
  action = SyncAction.uploadFailed(uuid, message: '加密失败：$e');
}

// 改造后
try {
  envelope = await _openBlobEnvelope(...);
} on DecryptionError catch (e) {
  action = SyncAction.uploadFailed(uuid, error: e);
} on Object catch (e) {  // 兜底，但记为 unexpected
  action = SyncAction.uploadFailed(uuid, error: SyncError.unexpected('encrypt', e));
  _logger.e('unexpected error during encrypt', error: e, stackTrace: st);
}
```

**关键**：底层（crypto.dart / vault.dart / backend）抛具体类型，引擎层只 catch 它关心的类型，其他类型让它冒泡到 `SyncEngine.sync()` 顶层统一记 `SyncResult.unexpectedErrors`。

**A2. `SyncAction.message` 升级为结构化字段**

```dart
// sync_models.dart
class SyncAction {
  final SyncActionType type;
  final String? uuid;
  final String? hash;
  final SyncError? error;        // 新增，替代裸 message
  final Map<String, Object?>? extra;  // 新增，扩展字段
  // 旧 message 字段保留为 getter，从 error + extra 生成，向后兼容 UI
  String get message => error?.toDisplayString() ?? extra?['note'] as String? ?? '';
}
```

**A3. 引入统一 logger，贯穿 5 个核心文件**

```dart
// lib/sync/sync_logging.dart（新建，约 30 行）
final syncLogger = Logger(
  printer: PrettyPrinter(methodCount: 0, errorMethodCount: 8),
  output: _SyncLogOutput(),  // 同时输出到 console 和内存环形缓冲
);

// 内存环形缓冲，调试面板用
class _SyncLogOutput extends LogOutput {
  static final ring = RingBuffer<LogEvent>(capacity: 500);
  @override
  void output(OutputEvent event) {
    ring.addAll(event.lines);
    for (final line in event.lines) {
      developer.log(line, name: 'safenotes.sync');
    }
  }
}
```

[webdav_backend.dart](file:///c:/Home/Projects/safenotes/lib/sync/webdav_backend.dart) 已有的 `package:logger` 依赖直接复用，其他 4 个文件统一引用 `syncLogger`。

**A4. 静默 catch 改为显式日志**

```dart
// 改造前（local_fs_backend.dart 行 137-138）
} catch (_) { /* ignore */ }

// 改造后
} catch (e, st) {
  syncLogger.w('manifest backup rename failed, will overwrite on next attempt', error: e, stackTrace: st);
}
```

### 2.3 实施步骤

1. 新建 `lib/sync/sync_error.dart`（sealed class + 子类）
2. 新建 `lib/sync/sync_logging.dart`（统一 logger + 环形缓冲）
3. 改造 `crypto.dart`、`vault.dart`、`sync_models.dart`：把现有抛 `Exception('xxx')` 的位置改为抛具体 `SyncError` 子类
4. 改造 `sync_engine.dart`：8 处 `on Object` 改为 `on 具体类型`，保留兜底但记 unexpected
5. 改造三个 backend：替换静默 catch
6. 改造 `SyncAction`：新增 `error` 字段，保留 `message` getter 兼容
7. 跑 `test/sync/` 下所有测试，确认绿

### 2.4 预期效果

- debug 时根因可见（具体错误类型而非 `on Object`）
- 日志可通过 `adb logcat` 或 Flutter DevTools 直接看，不用重新打 print
- `SyncAction` 携带结构化信息，调试面板和后续 metrics 都能用

### 2.5 风险

- sealed class 在 Dart 3.0+ 才支持，需确认项目 Dart SDK 版本（pubspec.yaml）
- 改造范围大，但每一步可单独 PR、可回退

---

## 3. 方向 E：调试面板

### 3.1 问题

排查同步问题目前需要：加 print → 重新编译 → 重现问题 → 看日志。对偶发问题（如"他端改密码后本端同步异常"）几乎无法定位。`vault.{dataKeyEpoch, keyVersion, keyFingerprint}`、`database` 的所有 meta 键、当前 ETag、远端 manifest version 等关键状态完全没有 UI 可见入口。

### 3.2 方案

在设置页加一个"同步诊断"入口（仅 debug 模式或长按 5 次版本号开启），展示：

**面板 1 — Vault 状态**
- vaultId / vaultCreatedAt
- keyVersion / dataKeyEpoch / keyFingerprint（前 16 字符）
- encryptedDataKey 是否存在 / 长度
- MK 是否在内存（unlock 状态）

**面板 2 — 数据库 meta 全量**
- 读 `sync_meta` 表所有键值，以表格展示
- 重点高亮：`manifest_version:<providerKey>`、`purged_uuids`（数量）、`blob_reupload_pending`（数量）、`data_key_history`（数量）

**面板 3 — Backend 状态**
- 当前 backend 类型 + displayName + providerKey
- `_initialized` / `_etagSupported`（WebDAV）/ `_resourcesSupported`（SafeServer）等内部标志
- 最近一次 `ping()` 结果 + 时间戳

**面板 4 — 最近同步**
- 最近 N 条 `SyncResult` 摘要（status / uploaded / downloaded / conflicts / failedNoteUuids / attempts / 耗时）
- 展开 `actions` 列表，每条显示 type + uuid + error
- "再次同步"按钮

**面板 5 — 日志缓冲**
- 直接展示方向 A 中 `_SyncLogOutput.ring` 的最近 500 条
- 支持按 level 过滤
- "导出"按钮，把日志 + vault 状态 + DB meta 写到 temp 文件供用户反馈

### 3.3 实施步骤

1. 新建 `lib/views/settings/sync_diagnostics.dart`（约 150 行，ListView + ExpansionTile）
2. 在 `lib/views/settings/settings.dart` 加入口（debug 模式可见）
3. `SyncService` 暴露 `getDiagnosticsSnapshot()` 方法，返回结构化状态对象
4. `SyncEngine` 暴露 `lastSyncResult` getter（缓存最近一次结果）
5. 路由注册

### 3.4 预期效果

- 用户反馈"同步异常"时，可以让对方截屏诊断面板，5 分钟定位问题
- 开发期不用反复加 print
- 与方向 A 的统一日志配合，形成完整的可观测性闭环

### 3.5 风险

- 需注意不能泄露敏感信息（如 dataKey、MK、完整 encryptedDataKey），只显示指纹/长度/前 16 字符
- 默认不开启，避免普通用户误触

---

## 4. 方向 B：拆分 sync_engine.dart

### 4.1 问题

[sync_engine.dart](file:///c:/Home/Projects/safenotes/lib/sync/sync_engine.dart) 1800+ 行，单文件包含 5 步同步主流程 + 4 层容错 + 3 种迁移 + 2 种 GC + 冲突解决 + 版本号管理。阅读时需要在 7+ 个方法间跳转，单点测试困难（测试冲突解决必须 mock 整个引擎）。

### 4.2 方案

按职责拆分为 5 个文件，**纯重构、不改逻辑、不动协议**：

| 新文件 | 来源行号 | 职责 | 估算行数 |
|--------|----------|------|----------|
| `sync_engine.dart`（保留） | 行 133-520、823-891、1651-1667 | 5 步主流程 + `_buildLocalManifest` + `_updateLocalState` | ~400 |
| `sync_migrator.dart`（新建） | 行 536-815、1098-1200、1207-1212 | 密钥迁移（scenario-d、adoptRemoteEpoch）+ LWW + 副本保留 | ~400 |
| `sync_self_heal.dart`（新建） | 行 1284-1305、1427-1483、1513-1640 | Layer 2b/3：本机明文自愈 + 孪生笔记去重 + 旧密钥现代化 | ~350 |
| `sync_gc.dart`（新建） | 行 836-839、1689-1722 | 墓碑 GC + 孤儿 blob GC + purged uuid 清理 | ~150 |
| `sync_transfer.dart`（新建） | 行 902-1078、1254-1280 | `_mergeAndTransfer` + `_uploadNote` + `_downloadNote` 骨架 | ~250 |

`SyncEngine` 类作为 facade 持有 4 个子组件，方法委托：

```dart
class SyncEngine {
  late final _migrator = _SyncMigrator(vault, database, backend);
  late final _healer = _SyncSelfHealer(vault, database, backend);
  late final _gc = _SyncGc(backend, database);
  late final _transfer = _SyncTransfer(backend, database, vault, _healer);

  Future<SyncResult> sync() async {
    // 5 步主流程，调用各子组件
  }
}
```

### 4.3 实施步骤

1. 先做"提取 + 委托"重构（不改变行为），每提取一个文件跑一次 `test/sync/`
2. 子组件间通过明确接口通信，不共享可变状态
3. `vault` 字段是非 final（迁移后会被替换），子组件需要通过 getter 访问而非构造时捕获

### 4.4 预期效果

- 单文件 < 500 行，阅读友好
- 单元测试可直接针对 `_SyncMigrator` / `_SyncGc` 等，不用 mock 整个引擎
- 新增容错逻辑时有明确归属文件

### 4.5 风险

- 纯重构看似安全，但 `vault` 非 final 的副作用可能因组件间传递暴露新 bug
- 建议先做 A（错误类型统一），再做 B，因为重构期需要可靠的测试反馈

---

## 5. 方向 C：隐藏状态收拢

### 5.1 问题

分析报告 §7 列出的隐藏状态有 4 类、20+ 个具体项，任何一个异常都会导致同步行为诡异，且没有统一入口查看。

### 5.2 方案

**C1. `SyncStateRepository` 封装 `sync_meta` 表**

把 `sync_meta` 的 7+ 个键收拢到一个 repository 类：

```dart
// lib/sync/sync_state_repository.dart（新建，约 200 行）
class SyncStateRepository {
  final NotesDatabase _db;

  // vault 元数据
  VaultMeta getVaultMeta() { ... }
  Future<void> updateVaultMeta(VaultMeta meta) { ... }

  // manifest version（按 providerKey 隔离）
  int getManifestVersion(String providerKey) { ... }
  Future<void> setManifestVersion(String providerKey, int v) { ... }

  // purged uuids
  Set<String> getPurgedUuids() { ... }
  Future<void> addPurgedUuid(String uuid) { ... }
  Future<void> clearPurgedUuids(Set<String> uuids) { ... }

  // blob reupload pending
  Set<String> getPendingReupload() { ... }
  Future<void> markAllForBlobReupload() { ... }
  Future<void> clearAllPendingReupload() { ... }

  // data key history
  List<WrappedDataKey> getDataKeyHistory() { ... }
  Future<void> appendDataKeyHistory(WrappedDataKey key) { ... }

  // 全量快照（调试面板用）
  Map<String, Object?> snapshot() { ... }
}
```

`vault.dart`、`sync_engine.dart` 不再直接读写 `sync_meta`，全部走 repository。

**C2. `SyncPaths` 集中文件系统路径常量**

```dart
// lib/sync/sync_paths.dart（新建，约 40 行）
class SyncPaths {
  final String root;
  SyncPaths(this.root);

  String get manifest => '$root/manifest.json';
  String get blobsDir => '$root/blobs';
  String get orphanDir => '$root/blobs-orphan';
  String get backupIndex => '$root/.manifest-bak-index';
  String backupSlot(int i) => '$root/manifest-backup/manifest.bak.$i';
  String corruptBackup(int ts) => '$root/.corrupt-$ts';
  String blob(String hash) => '$root/blobs/$hash';
  String orphanBlob(String hash, int ts) => '$root/blobs-orphan/$hash.$ts';
}
```

三个 backend 通过 `SyncPaths` 统一访问，避免路径拼接散落。

**C3. `SyncRuntimeState` 收拢内存可变状态**

把 `Vault` 的 4 个非 final 字段、`WebDavBackend._etagSupported`、`SafeServerBackend._resourcesSupported` 等收拢到一个明确的"运行时状态"对象，状态变更必须通过方法调用（便于打日志、加断言）。

### 5.3 实施步骤

1. 先做 C1（SyncStateRepository），跑测试
2. 再做 C2（SyncPaths），三个 backend 改造
3. C3 谨慎做，因为 Vault 的非 final 字段涉及迁移逻辑，改造风险高

### 5.4 预期效果

- 调试面板直接调 `repository.snapshot()` 即可显示所有持久化状态
- 状态变更有明确入口，便于加日志和断言
- 跨组件共享状态时不会"忘记更新某个副本"

### 5.5 风险

- C1 改动量大，但风险低（纯封装）
- C3 改动量小，但风险高（涉及迁移逻辑），建议最后做

---

## 6. 方向 D：砍掉部分容错层（谨慎评估）

### 6.1 问题

Layer 2b（本机明文自愈 + 孪生笔记去重，行 1542-1640）和 Layer 3（密钥纪元显式标记，行 1284-1305、1427-1483）逻辑很重，但触发场景是否常见没有数据支撑。

### 6.2 方案

**评估阶段**（先做）：

1. 在方向 A 的结构化日志中加入"容错层触发计数器"
2. 灰度发布 1-2 个版本，统计 Layer 2b/3 的实际触发频率
3. 如果某个层从未触发或频率 < 0.1%，考虑降级

**降级方案**（评估后再决定）：

- Layer 2b 本机明文自愈：保留"检测到坏 blob 报错"逻辑，删除"自动重传覆盖"逻辑，让用户手动 `repairRemote()`
- Layer 2b 孪生笔记去重：直接删除（场景极罕见，复杂度高）
- Layer 3 旧密钥现代化：保留"检测旧密钥报错"，删除"自动现代化重传"

### 6.3 风险

- 必须先有数据支撑，不能凭感觉砍
- 降级后用户体验下降（从"自动修复"变"提示错误"），需 UI 配合

### 6.4 不建议砍的部分

- Layer 1（单 blob 故障隔离）：必须保留，否则单条笔记失败会阻断整个同步
- Layer 2a（密钥变更后强制重传）：必须保留，否则迁移后数据不一致
- E1（冲突副本保留）：用户感知强，保留
- M1（purged uuid 阻止复活）：数据安全相关，保留

---

## 7. 实施路线图

### 第一阶段（立即做，1-2 天）

- 方向 A：统一错误类型 + 结构化日志
- 方向 E：调试面板

**产出**：debug 体验提升一个档次，后续重构有可靠反馈。

### 第二阶段（1 周）

- 方向 B：拆分 sync_engine.dart
- 方向 C1+C2：SyncStateRepository + SyncPaths

**产出**：单文件可读性、单点测试能力、状态可见性。

### 第三阶段（评估后决定）

- 方向 C3：SyncRuntimeState
- 方向 D：容错层降级

**产出**：进一步简化，但需数据支撑。

---

## 8. 不在本次改进范围

以下虽然也是复杂度来源，但不在本文档建议范围：

- **多 backend 语义统一**：SafeServer 的双路径、WebDAV 的降级、LocalFS 的简化是历史包袱，强行统一会引入更多抽象层。建议保持现状，靠方向 A 的日志让差异可见即可。
- **三层密钥简化为两层**：当前已是两层（MK + dataKey），没有进一步简化空间。
- **重写同步协议**：现有协议设计合理（见 [simplified-sync-design.md](./simplified-sync-design.md)），复杂度来自实现而非设计。
- **改密钥派生算法**（PBKDF2 → Argon2id）：跨平台互操作风险高，不建议。

---

## 9. 验证标准

每个方向完成后，通过以下方式验证：

| 方向 | 验证方式 |
|------|----------|
| A | `test/sync/` 全绿；手动制造解密失败、网络错误、manifest 损坏三种场景，日志能明确区分 |
| E | 在 debug 模式打开诊断面板，能看到所有 5 个面板的信息；导出日志功能正常 |
| B | `test/sync/` 全绿；`sync_engine.dart` < 500 行；新增 `_SyncMigrator` 单元测试 |
| C1 | `test/sync/` 全绿；诊断面板的"数据库 meta"面板通过 `repository.snapshot()` 渲染 |
| C2 | 三个 backend 单元测试全绿；路径拼接不再散落 |
| D | 灰度数据支撑；降级后 `test/sync/` 中对应测试改为"期望报错"而非"期望自愈" |

---

## 10. 与现有文档的关系

| 现有文档 | 关系 |
|----------|------|
| [simplified-sync-design.md](./simplified-sync-design.md) | 设计层架构，本建议不改动其核心设计 |
| [sync-protocol-spec.md](./sync-protocol-spec.md) | 协议规范，本建议不改动协议 |
| [sync-feature-design.md](./sync-feature-design.md) | 功能设计，本建议是它的实现层重构 |
| [chaos-test-plan-20260729.md](./chaos-test-plan-20260729.md) | 混沌测试，方向 D 的评估数据来源 |
| [p2-keyring-journal-design.md](./p2-keyring-journal-design.md) | 密钥日志，与方向 A 的日志体系可整合 |
| [troubleshooting-bad-blob-20260729.md](./troubleshooting-bad-blob-20260729.md) | 坏 blob 排查案例，方向 A+E 实施后这类排查会大幅简化 |

---

*本建议基于 2026-07-31 的代码状态。实施前请确认 `pubspec.yaml` 的 Dart SDK 版本支持 sealed class（Dart 3.0+）。*
