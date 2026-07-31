# SafeNotes 代码审查报告

**日期**：2026-07-29 19:21:33
**范围**：全量 Flutter 客户端代码 (`lib/`) + 服务端实现 (`server/`) + 设计文档 (`docs/`)
**审查重点**：业务逻辑、同步流程、复杂交互、多端协同、改密码场景、数据一致性、安全性

---

## 1. 架构概览

### 1.1 整体分层

| 层级 | 核心文件 | 职责 |
|------|----------|------|
| 入口/生命周期 | `main.dart`, `app.dart`, `authwall.dart` | 应用启动、路由守卫、会话超时 |
| 认证/解锁 | `views/authentication/login.dart`, `set_passphrase.dart`, `change_passphrase.dart` | 密码输入、生物识别、Vault 初始化 |
| 同步服务层 | `sync/sync_service.dart` | 单例、互斥锁、状态广播、autoSync debounce |
| 同步引擎层 | `sync/sync_engine.dart` | 5步同步流程、LWW 冲突解决、dataKey 迁移、乐观锁重试 |
| 密钥管理层 | `sync/vault.dart` | MK/dataKey 分层、createNew/unlockLocal/changePassword/迁移 |
| 加密原语层 | `sync/crypto.dart` | PBKDF2-HMAC-SHA256(200k)、AES-256-GCM、dataKey wrap/unwrap |
| 数据持久层 | `data/database_handler.dart` | SQLite schema v2、字段级加密、软删除、meta 表 |
| 后端抽象层 | `sync/sync_backend.dart` + 3实现 | WebDAV/LocalFS/SafeServer 统一接口 |
| 服务端 | `server/go/internal/...` | manifest/blob CRUD、ETag 乐观锁、原子写、速率限制 |

### 1.2 核心设计亮点

1. **两层密钥架构**：MK (Master Key，派生自密码) 仅加密 dataKey；dataKey (32字节随机) 加密所有笔记内容。改密码 O(1)，只重 wrap dataKey。
2. **per-vault 随机 salt**：每个 vault 创建时生成独立 salt，写入 manifest header 明文，新设备按 header 中 salt 派生 MK，跨用户预计算失效。
3. **密钥纪元守卫**：manifest header 包含 `keyFingerprint=H(MK)` 和 `keyVersion`，SyncEngine 能检测他端改密码，防止旧密码设备回滚远端 `encryptedDataKey`。
4. **后端无关设计**：SyncEngine 依赖 `SyncBackend` 抽象，WebDAV/SafeServer/LocalFS 任选，零服务端开发成本（MVP 用 WebDAV）。
5. **内容寻址 blob**：SHA-256 hash 做 blob 键名，天然去重、幂等上传。

---

## 2. 业务逻辑与核心流程审查

### 2.1 首次设置密码流程

**路径**：`SetEncryptionPhrasePage` → `_initVault` → `SyncService.initVaultFromPassword` → `Vault.createNew`

**验证点**：
- ✅ `Vault.createNew` 生成 `vaultId` + `dataKey` + 随机 `salt` + PBKDF2 派生 MK + wrap dataKey
- ✅ 持久化 `vaultId` / `encryptedDataKey` / `kdfSalt` / `keyFingerprint` / `keyVersion=1` / `createdAt` 到 meta 表
- ✅ `database.setDataKey(vault.dataKey)` 注入 database，后续读写自动加解密
- ✅ 守卫：`Vault.isInitialized` 检查防止覆盖已有 vault（`set_passphrase.dart:358`）
- ✅ 成功后 `Session.onPasswordSet` 更新 `PhraseHandler` + biometric secure storage

**风险**：无。流程完整、加密参数正确、无竞态。

---

### 2.2 登录/解锁流程

**路径**：`EncryptionPhraseLoginPage` → `_login` → `SyncService.initVaultFromPassword` → `Vault.unlockLocal`

**验证点**：
- ✅ 本地 vault 存在时走 `unlockLocal`：读取本地 meta 中的 `salt`/`encryptedDataKey`/`keyFingerprint`，用输入密码派生 MK，unwrap dataKey
- ✅ GCM tag 验证失败抛 `WrongPasswordException`，作为密码错误的真实信号
- ⚠️ **关键问题**：`login.dart:267/380` 仍保留 `sha256(passphrase) == passPhraseHash` 本地 hash 门禁
  - 该 hash 是**设备本地**存储，A 改密码后 B 设备的 hash 不会更新
  - B 输入新密码 P2 → 本地 hash 比对失败 → 直接报错"密码错误"，**连 vault 都走不到**
  - B 输入旧密码 P1 → 本地 hash 通过 → `unlockLocal` 成功（本地 meta 还是 enc1）→ 进入首页
  - 后续同步会触发"场景 b"误判（见 2.5），把旧 `encryptedDataKey` 推回远端，**导致改密码实质失效**

- ⚠️ `login.dart:397-401` `_initVault` 失败后仍无条件 `pushReplacementNamed('/home')`，dataKey 未注入 → 首页读取抛 `DataKeyNotSetException` 白屏

**修复建议**：
1. 移除或降级本地 sha256 hash 门禁，改为"快速通道"：hash 通过 → 直接走 vault；hash 失败 → 尝试 `Vault.unlockLocal`（真正的密码验证器）；再失败 → 若配置同步 → GET 远端 manifest header → `unlockFromRemoteManifest`；最后才报错
2. `_initVault` 失败时停留登录页，不导航

---

### 2.3 改密码流程

**路径**：`ChangePassphrase` → `_finalSublmitChange` → `vault.verifyPassword` → `_preChangeCheck` → `vault.changePassword` → `SyncService.updateVault` → `Session.onPasswordSet` → `SyncService.sync()`

**验证点**：
- ✅ 前置验证：`verifyPassword` 只验证不持久化，避免先备份/同步再发现旧密码错
- ✅ `_preChangeCheck`：强制备份 + ping 服务器 + 强制同步（把本地未推送变更先推上去）+ 检查未同步笔记
- ✅ `Vault.changePassword`：旧 MK 解 dataKey → 新 MK wrap dataKey → 新 `keyFingerprint` + `keyVersion+1` → 持久化 meta
- ✅ 改密码后立即同步：把新 `encryptedDataKey` 推送到远端 manifest
- ✅ `Session.onPasswordSet` 更新 `PhraseHandler` + biometric（关键：否则指纹登录仍用旧密码解 vault 失败）

**风险**：
- 若改密码后同步失败（网络不可达），本地已更新 meta，远端仍是旧 `encryptedDataKey`。下次同步时引擎会检测到版本差异并推送新包裹，**最终一致性有保障**，但期间他端用旧密码登录会触发翻转（见 2.5）。建议在 UI 明确提示"改密码成功，正在同步到云端..."，同步完成前不要登出。

---

### 2.4 同步主流程 (SyncEngine.sync)

**5步流程**（`sync_engine.dart:125-460`）：

1. **GET manifest**：下载远端 manifest 密文 → `deserializeHeaderOnly` 仅解析 header（明文，无需 dataKey）
2. **密钥纪元比对**：
   - 远端 `keyVersion > 本地` → 他端改密码 → `epochMismatch=true`，`overrideEncryptedDataKey=远端值`
   - 远端 `keyVersion < 本地` → 本端改密码，正常推送新包裹
3. **dataKey 迁移检查**：`vault.checkMigrationNeeded(remoteEncryptedDataKey)`
   - 无需迁移（本地 dataKey 能解远端 manifest）→ 继续
   - 需迁移且 MK 能解远端包裹 → `migrateToRemote` 重新加密所有本地笔记（事务保护） → 抛 `_MigrationRequiredException` 触发重试
   - MK 解不开远端包裹 → 场景 c/d 判别：用 `keyFingerprint` 比对。匹配 → 场景 d（两设备独立 createNew，同密码不同 salt）→ `migrateToRemoteVault` 完整迁移；不匹配 → 场景 c（真密码不匹配）→ 失败
4. **构建本地 manifest**：`_buildLocalManifest(overrideEncryptedDataKey)`，含 F1 墓碑 GC（>30天软删除硬删+加入 purgedUuids）
5. **比对合并传输** (`_mergeAndTransfer`)：
   - 仅本地有 → 上传 blob
   - 仅远端有 → 下载 blob + 写本地（M1：purgedSet 中的跳过，防硬删复活）
   - 双方有 hash 相同 → skip
   - 双方有 hash 不同 → LWW：`updatedAt` 大者胜；E1：差值>5分钟且 hash 不同 → 败方另存为新笔记（冲突副本保留）
6. **D3 有效变更判断** (`_hasEffectiveChange`)：无实际变更（actions 仅 skip/conflict + items 一致 + header 关键字段未变 + 无 epochMismatch）→ 跳过 PUT，避免 version 无意义递增
7. **PUT manifest**（带 ETag 乐观锁）→ 412 冲突重试最多 3 次
8. **更新本地状态**：manifest version + `markAllSynced` + 清理已上传的 purgedUuids
9. **F1 孤儿 blob GC**：`listBlobs() - manifest引用的hash` → 删除孤儿

**亮点**：
- ✅ 乐观锁重试机制完善，最多 3 次
- ✅ 密钥纪元守卫防止翻转战争（B1 修复）
- ✅ 冲突副本保留（E1 修复）避免 LWW 静默丢数据
- ✅ 墓碑 GC (F1) + 硬删不复活 (M1) + blob GC (F1) 形成闭环
- ✅ D3 跳过无效 PUT 避免 version 攀升

**风险**：
- ⚠️ `listBlobs()` 依赖后端实现。WebDAV 需 PROPFIND，当前 `webdav_backend.dart` 未实现 → GC 静默跳过。建议补全或文档声明。
- ⚠️ 并发同步场景下 GC 可能误删他端正在上传的 blob（`sync_engine.dart:1011-1014` 已有注释说明风险，PUT blob 幂等可重试，风险可控）。

---

### 2.5 多端改密码场景深度推演（核心风险点）

#### 场景 A：设备 A 改密码 P1→P2，立即同步 → 远端 manifest 更新为 `enc2=wrap(MK_P2, dataKey)`

#### 场景 B：设备 B 用**新密码 P2** 登录
- **当前代码**：`login.dart` 本地 sha256 hash 比对失败 → 直接报错"密码错误"，**用户被锁在登录页，无法进入**
- **预期行为**：应走 `unlockFromRemoteManifest` 远端辅助解锁（当前为死代码 `vault.dart:255`，全工程无调用）

#### 场景 C：设备 B 用**旧密码 P1** 登录
- 本地 hash 通过 → `unlockLocal` 成功（本地 meta 仍是 `enc1`）→ 进入首页
- 后台自动同步：`checkMigrationNeeded(enc2)` → enc2 != enc1 → 用 MK_P1 解 enc2 失败 → 兜底分支尝试用本地 dataKey 解远端 manifest items → **成功**（改密码不动 dataKey！）
- 引擎判定为"场景 b：本端改密码还没推送" → `_buildLocalManifest` 用**本地 enc1** 构建 header → PUT 覆盖远端 enc2
- **结果**：A 的新密码包裹被 B 的旧包裹顶掉。A 下次同步同样走"场景 b"再顶回来 → **enc1/enc2 永久翻转**
- 若 A 此时卸载/不再同步：远端停留在 enc1，攻击者拿远端数据 + P1 即可解开 dataKey，**改密码实质失效**

#### 场景 D：两设备并发改密码
- A 推 `enc(MK_P2a)`，B 推 `enc(MK_P2b)`，dataKey 相同，都能解对方 manifest items
- 双方都走"场景 b"认为自己是合法推送方 → encryptedDataKey 永久翻转

#### 根因（三件套，缺一不可）
| # | 根因 | 位置 |
|---|------|------|
| 1 | manifest header 缺密钥纪元字段，无法区分"我密码错"vs"他端改密码" | `sync_models.dart:178` |
| 2 | `unlockFromRemoteManifest` 是死代码，新密码重登无入口 | `vault.dart:255` 无调用 |
| 3 | 登录口令体系(sha256本地hash)与同步密钥体系(PBKDF2/vault)互不通信，本地hash门禁把合法新密码挡在外面 | `login.dart:267/380` |

#### 已有修复框架（需落地）
- `sync_engine.dart:154-160` 注释已承认需用 `keyFingerprint` 区分
- `ManifestHeader` 已预留 `keyFingerprint`/`keyVersion` 字段（`sync_models.dart:257-267`）
- `Vault.changePassword` 已生成新 fingerprint + 递增 version
- **缺口**：引擎下载 header 后未做纪元比对守卫；`_buildLocalManifest` 纪元不匹配分支未强制用远端 `encryptedDataKey`；登录页未激活远端辅助解锁

---

### 2.6 同步触发器缺失（P0 级功能性缺陷）

| 触发点 | 现状 | 影响 |
|--------|------|------|
| 新增/编辑笔记后 | `editor_state.dart:53 addOrUpdateNote` **未调用** `autoSync()` | A 编辑笔记，B 永远看不到，除非手动点同步 |
| 软删除(移入回收站) | `deleted_notes.dart` 未触发同步 | A 删到回收站，B 列表仍在，用户感知不一致 |
| 恢复笔记 | `deleted_notes.dart:109` **仅此处** 调用了 `autoSync()` | 不一致 |
| 永久删除 | `deleted_notes.dart:118 hardDelete` 未触发同步 | 远端墓碑不传播 |
| 登录后 | `_initVault → initBackend` 仅初始化，**不拉取远端数据** | 新设备登录看不到任何笔记，需手动同步 |
| App 回前台 | `main.dart:55-59` 有 `resumeCallBack: SyncService.instance.autoSync` ✅ | 已有但依赖前两条触发器工作 |

**修复成本极低**：在 `addOrUpdateNote` / `softDelete` / `hardDelete` / `restoreNote` 各加一行 `SyncService.instance.autoSync()`；登录成功后加一行 `autoSync()`。

---

### 2.7 数据一致性与冲突处理

| 机制 | 实现 | 评价 |
|------|------|------|
| LWW 冲突解决 | `sync_engine.dart:845-850` 比较 `updatedAt` | ✅ 正确，兜底 hash 字典序 |
| 冲突副本保留 | `sync_engine.dart:663-674` 差值>5分钟且 hash 不同 → 败方另存新笔记 | ✅ E1 修复，避免静默丢数据 |
| 乐观锁 | manifest PUT 带 ETag，412 重试最多 3 次 | ✅ 完善 |
| 回声过滤 | 无显式 baseRev，**manifest 全量比对天然无回声** | ✅ 简化设计优势 |
| 墓碑传播 | `deleted=true` 项进入 manifest，下载时本地标记软删 | ✅ 正确 |
| 硬删不复活 | `purgedUuids` 列表 + `_mergeAndTransfer` 过滤 + 同步成功后清理 | ✅ M1 修复闭环 |
| 墓碑 GC | >30天软删除硬删本地 + 从 manifest 移除 | ✅ F1 修复 |
| 孤儿 blob GC | `listBlobs() - manifest引用hash` 删除 | ⚠️ 依赖 `listBlobs` 实现，WebDAV 待补全 |

---

## 3. 复杂交互与同步场景审查

### 3.1 dataKey 迁移（新设备加入已存在同步组）

**流程**：`checkMigrationNeeded` → MK 解远端 `encryptedDataKey` 得到 `remoteDataKey` → `remoteDataKey != 本地dataKey` → `migrateToRemote` 事务重加密所有笔记 → 更新 meta + database dataKey → 抛异常触发重试同步

**验证点**：
- ✅ 事务保护：内存解密全量 → 重加密 → 事务内一次性写入 → 最后切 dataKey
- ✅ Crash 安全：中途崩溃数据库仍为旧密文，dataKey 未切，下次登录恢复一致
- ✅ 迁移后重试：`_MigrationRequiredException` 触发外层循环重新 `_syncOnce`，用新 dataKey 解析远端 manifest
- ⚠️ `vault.dart:341` `checkMigrationNeeded` 返回的 `remoteVaultId` 填的是本地 vaultId，**应填远端 header 的 vaultId**（P2-7 修复注释已在代码中但实参传错）
- ⚠️ `migrateToRemote` 的 `copyWith` 未更新 `vaultId`，未写远端 vaultId 到 meta（R4 翻转风险）

### 3.2 场景 d：两设备独立 createNew（相同密码、不同 salt）

**流程**：本地 MK 解不开远端 `encryptedDataKey` → 用本地 dataKey 试解远端 manifest 失败 → `Vault.tryDeriveRemoteDataKey` 用**远端 salt + 用户密码**派生 MK_remote → 比对 `keyFingerprint` → 匹配 → `migrateToRemoteVault` 完整迁移（含 kdf/salt/fingerprint/version/createdAt 全部切换到远端值）

**验证点**：
- ✅ 正确识别"密码相同、salt不同"，避免误判为密码错误
- ✅ 完整迁移所有 vault 元数据，新设备彻底融入同步组
- ⚠️ 依赖 `keyFingerprint` 字段，需 manifest header 有该字段（当前已有）

### 3.3 生物识别登录与会话超时

- `local_session_timeout` 包管理：inactivity timeout + app focus timeout
- 超时触发 `logout` → 导航到 `/authwall` → `Session.logout()` 清理同步服务 + database dataKey + PhraseHandler
- 生物识别：`BiometricAuth.authKey` 存 secure storage，指纹验证成功后读取明文密码调 `_login`
- **风险**：`change_passphrase.dart:380` 改密码后 `Session.onPasswordSet(newPassword)` 更新了 biometric key，**但若改密码后同步失败，用户在另一设备用旧密码登录，指纹仍存旧密码** → 指纹登录会失败（预期行为，需输入新密码），但 UI 无明确提示。建议改密码成功后提示"指纹已更新，请在其他设备重新录入或输入新密码"。

---

## 4. 安全性审查

### 4.1 加密实现

| 组件 | 算法/参数 | 评价 |
|------|-----------|------|
| MK 派生 | PBKDF2-HMAC-SHA256, 200k 迭代, per-vault 16字节随机 salt | ✅ 符合现代标准，Isolate 异步不阻塞 UI |
| dataKey 生成 | `Random.secure()` 32 字节 | ✅ CSPRNG |
| dataKey wrap | AES-256-GCM(MK, AAD="datakey-wrap") | ✅ 认证加密，防篡改 |
| 笔记加密 | AES-256-GCM(dataKey, AAD=note-uuid) | ✅ 绑定 UUID 防重放 |
| manifest 加密 | AES-256-GCM(dataKey, AAD="manifest-items") | ✅ |
| 信封格式 | nonce(12) || ciphertext || tag(16) | ✅ 标准 |
| 密钥指纹 | SHA-256(MK) 十六进制 | ✅ 等价于 encryptedDataKey 的离线验证能力，不降低安全性 |

### 4.2 密钥管理

- ✅ MK 仅内存缓存 (`Vault._mk`)，不持久化，登出时清零
- ✅ dataKey 注入 `NotesDatabase._dataKey`，登出时 `clearDataKey()`
- ✅ `encryptedDataKey` 存 meta 表 + manifest header（密文），安全性等价
- ⚠️ `sync_engine.dart:1117-1124` `_bytesEqual` 常数时间比较 dataKey，**好**，但仅用于迁移判断，其它处如 `vault.dart:440` 直接 `==` 比较 `encryptedDataKey`（base64 字符串，长度固定，时序攻击面极小，可接受）

### 4.3 认证与授权

- ✅ WebDAV: HTTP Basic Auth + HTTPS（生产强制）
- ✅ SafeServer: Bearer Token，服务端 constant-time 比对 + 速率限制（LRU 防 OOM）
- ✅ 本地生物识别：`flutter_secure_storage` 存加密密码，硬件隔离
- ⚠️ `login.dart` 本地 sha256 无盐无 KDF，**仅作快速通道**，真验证在 vault（见 2.2 问题）

### 4.4 隐私承诺

- README/privacy-policy 宣称"完全匿名、无入站出站请求"
- 同步为**可选功能，默认关闭**，未配置时零网络请求 ✅
- 启用同步设置页有显著提示 ✅
- 零知识：服务端只存密文，不接触明文/密钥/密码 ✅

---

## 5. 代码质量与工程实践

### 5.1 优点

1. **注释极其详尽**：核心文件（`sync_engine.dart`、`vault.dart`、`crypto.dart`、`sync_models.dart`）均有大量中文注释，解释设计理由、边界条件、修复历史（B1/E1/F1/M1/M7/D3/R10 等编号），可作为文档直接阅读
2. **分层清晰**：SyncEngine 无 UI 依赖，纯 Dart 可在 Windows `flutter test` 运行
3. **测试覆盖**：`test/sync/` 含 SyncEngine 单测、LocalFs 后端测试、SafeServer 集成测试、crypto/vault 单测
4. **错误处理分层**：`WrongPasswordException`/`VaultNotInitializedException`/`MigrationInProgressException`/`DataKeyNotSetException` 语义明确
5. **并发控制**：`SyncService._syncInProgress` 互斥锁 + `database._isMigrating` 守卫 + `Vault.withSaveLockAsync`（服务端）串行化

### 5.2 待改进

| 问题 | 位置 | 建议 |
|------|------|------|
| `_initVault` 失败仍导航首页 | `login.dart:397-401` | 失败时停留登录页，显式报错 |
| 本地 sha256 hash 门禁过强 | `login.dart:267/380` | 降级为快速通道，失败走 vault/远端辅助解锁 |
| `unlockFromRemoteManifest` 死代码 | `vault.dart:255` | 激活并接入登录流程 |
| `checkMigrationNeeded` 远端 vaultId 传错 | `vault.dart:341` | 传入 `remoteVaultId` 参数并回填 meta |
| `migrateToRemote` 未更新 vaultId | `vault.dart:503` | `copyWith(vaultId: remoteVaultId)` + 写 meta |
| WebDAV `listBlobs` 未实现 | `webdav_backend.dart` | 补全 PROPFIND 或文档声明 GC 不可用 |
| `sync_engine.dart:358-362` blob missing 丢弃 remoteItem | 导致远端条目抖动 | 保留 remoteItem 进 merged，标记 pendingBlob |
| 同步触发器缺失 (4处) | `editor_state.dart`, `deleted_notes.dart` | 各加一行 `autoSync()` |
| 登录后无初始同步 | `login.dart:_onLoginSuccess` | `initBackend` 成功后 `autoSync()` |
| LocalFS `putManifest` 非原子写 | `local_fs_backend.dart` | tmp+rename（~5行） |
| `synced` 字段实质死亡 | `database_handler.dart:672` | 或消费做增量同步，或删字段和索引 |
| 登出顺序不一致 | `drawer.dart:288` vs settings | 统一"先导航后清状态" |

---

## 6. 服务端实现审查

### 6.1 SafeServer (Go)

**架构**：`main.go` → `internal/config` → `internal/auth` (速率限制+LRU) → `internal/storage` (Vault接口+FS实现) → `internal/server` (handlers+middleware+logging)

**核心能力**：
- ✅ 7 端点：manifest/blob CRUD + health + listBlobs
- ✅ ETag 乐观锁：`If-Match`/`If-None-Match`，Vault 层锁内"校验+写入"防 TOCTOU
- ✅ 原子写：tmp 文件 + fsync + rename
- ✅ 认证：Bearer Token，constant-time compare，速率限制(含 LRU 防 OOM)
- ✅ 中间件链：RequestID → Logging → Recover
- ✅ Graceful shutdown
- ✅ 存储层抽象，预留多 vault 扩展

**代码质量**：结构清晰、分层明确、错误处理完备、日志结构化(slog)。无明显安全问题。

### 6.2 WebDAV 后端

- 客户端 `webdav_backend.dart` ~80 行，实现 `SyncBackend` 接口
- ✅ MKCOL 幂等创建目录
- ✅ GET/PUT manifest 带 ETag/If-Match
- ✅ blob PUT 幂等
- ⚠️ `putManifest` 注释承认：服务器可能静默忽略 `If-Match` → 乐观锁退化为 LWW，**需在 init 时探测 ETag 支持度并警告用户**
- ⚠️ `listBlobs` 未实现 → GC 无法工作
- ⚠️ 无原子写保证（依赖服务器实现），建议客户端用 `manifest.json.tmp` + MOVE 覆盖

---

## 7. 文档一致性核对

| 文档 | 与代码一致性 | 备注 |
|------|--------------|------|
| `sync-protocol-spec.md` v2 | ✅ 高度一致 | manifest 格式、加密、同步算法、后端隔离、providerKey 均对应实现 |
| `sync-feature-design.md` | ⚠️ 部分过时 | 基于 litenotes 协议（rev/baseRev/keystore同步），当前实现已简化为 manifest+LWW，文档未同步更新 |
| `simplified-sync-design.md` | ✅ 高度一致 | 当前实现核心架构即基于此简化方案（dataKey层、manifest、WebDAV优先） |
| `server-api-spec.md` | ✅ 一致 | SafeServer 实现完全符合 v2.1 规范 |
| `同步架构全面分析-20260728.md` | ✅ 深度对应 | 详细指出了改密码翻转、同步触发器缺失、manifest损坏无自愈等真实问题，与代码核对吻合 |

---

## 8. 优先级修复建议汇总

### P0（阻断正确性/安全性）
1. **登录页本地 hash 门禁改造**：移除/降级 sha256 校验，失败时尝试 `Vault.unlockLocal` → 远端辅助解锁 `unlockFromRemoteManifest`，激活死代码
2. **引擎密钥纪元守卫**：`_syncOnce` 下载 header 后比对 `keyVersion`/`keyFingerprint`，远端版本高时强制用远端 `encryptedDataKey` 构建本地 manifest，置 `passwordEpochMismatch` 状态供 UI 提示
3. `_initVault` 失败不导航首页
4. 同步触发器补全：`addOrUpdateNote`/`softDelete`/`hardDelete`/`restoreNote` + 登录后初始同步

### P1（功能完整性/健壮性）
5. `checkMigrationNeeded` 正确传递并持久化远端 `vaultId`
6. `migrateToRemote` 更新 `vaultId` 到 meta
7. blob 下载失败保留 `remoteItem` 进 merged，避免远端条目抖动
8. manifest 损坏自愈：`deserializeHeaderOnly` 抛 `FormatException` 时备份损坏文件，用本地数据重建 manifest 上传覆盖
9. LocalFS `putManifest` 原子写
10. WebDAV `listBlobs` 实现或文档声明 GC 不可用
11. WebDAV init 探测 ETag 支持度并警告

### P2（安全加固/清理）
12. per-vault 随机 salt（当前已实现，确认创建时写入 header）
13. 清理/废弃 `synced` 字段及索引
14. 统一登出顺序为"先导航后清状态"
15. 冲突副本保留 UI 入口（搜索" (冲突)"过滤）
16. 服务端速率限制生产部署验证

---

## 9. 总体评价

| 维度 | 评分 | 说明 |
|------|------|------|
| 架构设计 | ⭐⭐⭐⭐⭐ | 两层密钥+manifest+后端无关，简洁且可扩展 |
| 加密实现 | ⭐⭐⭐⭐⭐ | 算法选型标准、参数合理、Isolate 异步、跨平台互解有向量测试 |
| 同步引擎 | ⭐⭐⭐⭐ | 5步流程清晰、LWW+冲突副本+乐观锁+GC闭环，核心逻辑正确 |
| 多端协同 | ⭐⭐⭐ | **改密码场景有根理性缺陷**（需落地纪元守卫+登录页改造），其余场景完善 |
| 功能完整性 | ⭐⭐⭐ | 同步触发器严重缺失，导致同步实质全手动 |
| 代码质量 | ⭐⭐⭐⭐⭐ | 注释详尽、分层清晰、测试覆盖好、错误类型语义化 |
| 文档同步 | ⭐⭐⭐⭐ | 核心规范文档与代码一致，设计文档部分过时 |
| 安全性 | ⭐⭐⭐⭐ | 零知识、E2EE、生物识别安全存储、速率限制，仅登录页 hash 门禁降级安全性 |

**结论**：**核心架构优秀，加密与同步引擎实现扎实，文档完善**。但存在**两个关键缺陷**必须优先修复：
1. **改密码多端协同失效**（协议缺纪元字段 + 登录页门禁 + 远端辅助解锁死代码）
2. **同步触发器近乎缺失**（新增/编辑/删除/登录后均不自动同步）

修复上述两点后，产品将达到"多设备同步可用、改密码安全、数据不丢失"的生产就绪状态。建议按 P0→P1→P2 顺序分阶段落地，每阶段完成后运行现有测试套件并补充回归用例。

---

## 附：关键文件行号索引（便于定位）

| 场景 | 文件 | 关键行号 |
|------|------|----------|
| 登录页 hash 门禁 | `lib/views/authentication/login.dart` | 267, 380, 397-401 |
| 远端辅助解锁死代码 | `lib/sync/vault.dart` | 255-376 (`unlockFromRemoteManifest`) |
| 改密码流程 | `lib/views/change_passphrase.dart` | 310-395 (`_finalSublmitChange`, `_preChangeCheck`) |
| 同步引擎主流程 | `lib/sync/sync_engine.dart` | 125-460 (`sync`, `_syncOnce`) |
| 密钥纪元比对 | `lib/sync/sync_engine.dart` | 238-246, 298, 724 |
| dataKey 迁移 | `lib/sync/vault.dart` | 419-515 (`checkMigrationNeeded`, `migrateToRemote`) |
| 场景 d 迁移 | `lib/sync/vault.dart` | 517-615 (`tryDeriveRemoteDataKey`, `migrateToRemoteVault`) |
| 同步触发器缺失 | `lib/models/editor_state.dart` | 53 (`addOrUpdateNote`) |
| 同步触发器缺失 | `lib/views/deleted_notes.dart` | 109, 118 (`restoreNote`, `hardDelete`) |
| manifest header 字段 | `lib/sync/sync_models.dart` | 257-267 (`keyFingerprint`, `keyVersion`) |
| 本地数据库 schema | `lib/data/database_handler.dart` | 283-315 (`_createDB`), 73-81-84 (`MetaKeys`) |
| 服务端 handlers | `server/go/internal/server/handlers.go` | 27-168 (全端点) |
| 服务端存储 | `server/go/internal/storage/fs.go` | (原子写、ETag、锁) |

---

*报告生成时间：2026-07-29 19:21:33*
*审查人：opencode AI Agent*