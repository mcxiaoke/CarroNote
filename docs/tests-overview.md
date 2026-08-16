# 测试文件综合介绍

> 本文汇总 SafeNotes 仓库中的各类测试文件，说明各自的定位、覆盖点与运行方式，
> 便于快速找到"该在哪个文件加断言"。
>
> 测试分两类目录：
> - **`packages/core/test/`**：纯 Dart 核心包（`core`）的测试，涵盖加密、同步引擎、
>   keyring、journal、各后端。纯 Dart，**用 `dart test` 跑（无需 Flutter SDK）**；
>   `flutter test` 亦可但更重，不推荐作为核心测试常规手段。
> - **`test/`**：Flutter 应用层测试（widget、同步配置、真实数据库生成工具等），需 Flutter。
> - **`integration_test/`**：端到端集成测试（见 §2.5）。
>
> 公共支撑文件：
> - `packages/core/test/sync/sync_test_support.dart`：造 `Keyring` / `Journal`、
>   持久化账本断言、`FakeJournalStore` mixin（给 FakeBackend 补真实存储的
>   journal 三件套）。所有 core 同步测试都 `import` 它。
> - `test/sync/sync_test_support.dart`：app 侧对 core 测试支撑的 re-export（唯一引用点，避免两处代码漂移）。

---

## 1. 核心包测试（`packages/core/test/`）

### 1.1 `sync/crypto_test.dart` —— 加密层单元测试

纯 Windows 可跑、秒级反馈。验证：

- PBKDF2 确定性：相同密码 + salt → 相同 MK；不同密码/不同 salt → 不同 MK。
- Argon2id 派生（2026-08-11 新增）：确定性、与 PBKDF2 互异、wrap/unwrap、经 `deriveMasterKeyAsync` 派发；新 vault / 新备份默认 Argon2id（`m=32MiB, t=3, p=2`）。
- MK 长度恒为 32 字节（AES-256）；自定义迭代次数生效。
- AES-256-GCM 往返、dataKey wrap/unwrap。
- 错误密码 / 错误 AAD 导致解密失败。
- `contentHash` 确定性。

### 1.2 `sync/sync_engine_test.dart` —— SyncEngine 单元测试

用 `FakeBackend`（内存实现）+ 真实 in-memory SQLite 验证同步主流程：

- 首次同步（本地有、远端空）；新设备同步（本地空、远端有）；增量同步。
- LWW 冲突解决；墓碑同步（软删除传播）；跳过已同步（hash 一致不重复传输）。
- 乐观锁重试（PUT manifest 冲突后重试成功）。
- 含 P1-B 钩子 `onBeforePutManifestWrite`，模拟"同步期间用户编辑"竞态。

### 1.3 `sync/keyring_test.dart` —— Keyring 单元测试

两层密钥架构核心流程：

- `createNew`：首次创建 keyring（vaultId + dataKey + encryptedDataKey）。
- `unlockLocal`：本地解锁（正确/错误密码、未初始化）。
- `unlockFromRemoteManifest`：新设备从远端 manifest 解锁。
- `changePassword`：改密码（dataKey 不变、旧密码验证、新密码可解锁）。
- 多设备协调：设备 A 改密码 → 设备 B 用新密码解锁。

### 1.4 `sync/journal_test.dart` —— Journal 单元测试

锁死 Journal 作为"审计 + 可恢复第二数据源"的不可退化行为：

1. 追加与 seq：单调递增、跨归档连续、重开后水位不回退。
2. 滚动归档：1000 条 / 100KB 双阈值、归档保留 3 份。
3. 容错：日志损坏、vaultId 串库、坏条目、未知事件类型。
4. 恢复线索：`findIncompleteOperations`（只报不修）、`replayKeyState`。
5. 远端加密副本：密文不落明文、跨设备去重合并、错误 dataKey 拒绝。
6. 故障行为：沙盒目录不可用时 `Journal.open` 抛异常（不再降级内存模式）。
7. 内存模式：裁剪到上限、不产生文件、不上传远端。

### 1.5 `sync/multi_device_test.dart` —— 多设备交互场景测试

验证 P0/P1/P2 修复：

- 设备 A 改密码后推送新 encryptedDataKey，设备 B 同步后回写本地 meta（H1）。
- 硬删除后下次同步从远端 manifest 清理墓碑，不复活（M1）。
- blob hash 校验拒绝内容不一致的信封（M7）。
- 多设备并发同步最终一致性。

数据库隔离：因 `NotesDatabase` 是单例，采用 "close → recreate" 模式模拟多设备；
`FakeBackend` 在内存中跨设备切换持久化远端数据。

### 1.6 `sync/p0p1_self_heal_test.dart` —— 自愈 / 混沌 / 回归测试

覆盖本轮改动：

- P0-1 重建路径跳过 GC（远端 manifest 为空/损坏时，绝不误删其他设备 blob）。
- P0-3 `repairRemote`：远端 blob 缺失 → 本机持有明文则重传自愈。
- P0-4 普通下载：远端 blob 缺失 → 本机持有明文/孪生则自愈重传。
- P1-1 manifest 代际备份（环形 N 份，可恢复）。
- P1-2 GC 软删除隔离区（`blobs-orphan/`，超期才真删）。
- 混沌：运行中随机删/翻转一个远端 blob，断言最终被 heal 补回或进入
  `failedNoteUuids`（绝不静默丢失）。

### 1.7 `sync/chaos_multi_client_test.dart` —— 重型随机混沌测试

设计要点见本节下文（早期混沌测试计划文档 `docs/chaos-test-plan-20260729.md` 已不在仓库中，以本文本节为准）。

- 3 个客户端 + 随机交织操作流（新建/编辑/删除/同步/改密码）+ 随机延迟。
- 纪律：每次运行先克隆 `temp/safenotes-vault` 到 `temp/chaos/run-<seed>/`，
  **绝不读改写原件**；种子化 `Random(seed)` 可复现；断言"不变量"而非精确终态；
  维护逻辑真值模型（LogicalModel）区分基线（真实 118 数据）与混沌操作。

### 1.8 `sync/longrun_persistent_store_test.dart` —— 长期存续测试

- 客户端 DB + 服务端目录**跨进程、跨运行持续累积**，模拟真实用户"装上就再也不删"。
- 落点在 `temp/longrun-store/`，**测试结束不清理**，下次运行接着用。
- 每代把"应当存在的 uuid → contentHash"写进 `state.json`，下次运行逐条核对。
- 锁死不变量 I1~I9：收敛一致、历史不丢、墓碑保留、引用完整、GC 有效、水位不退、
  密钥自洽、明文自洽、隔离区有界。
- 运行：`LONGRUN_GENS=5` / `LONGRUN_RESET=1` 环境变量控制代次与重置。

### 1.9 `sync/local_fs_backend_test.dart` —— LocalFsBackend 单元测试

验证本地文件系统后端：

- `init` 创建目录结构；`getManifest` 首次返回空；`putManifest` 首次上传成功。
- 读取一致性；乐观锁冲突检测；`putBlob`/`getBlob` 幂等性；`getBlob` 不存在返回 null。
- ETag 一致性；隔离区 `deleteBlobSoft` → `blobs-orphan`、超期 purge（I9 链路）。

### 1.10 `sync/safe_server_integration_test.dart` —— SafeServer 集成测试

- 驱动真实 SafeServer（Go / Node.js 参考实现）跑完整同步流程。
- `setUpAll` 调 PS 清理脚本 → 构建 Go 二进制 → 启动 server → 轮询
  `/api/v2/health`；`tearDownAll` 停 server + 清理。
- 环境变量：`SN_SERVER=node`（默认 Go）、`SN_GO_DEBUG=1`、`SN_GO_BIN=path`。
- 库级 `@Timeout(180s)`；go/node 不在 PATH 时自动跳过。

### 1.11 `sync/webdav_integration_test.dart` —— WebDavBackend 集成测试

- 驱动真实 `hacdias/webdav` v5.14.1 服务器跑完整同步流程。
- 服务器路径 `C:\Home\Develop\tools\webdav.exe`；`setUpAll` 启动、`tearDownAll` 停止。
- 库级 `@Timeout(120s)`；webdav.exe 不在指定路径时自动跳过。

### 1.12 其他核心测试文件（未在以上小节逐一展开）

以下 `packages/core/test/sync/` 下的测试文件同样存在，覆盖额外回归点：

- `backend_redirect_test.dart` —— WebDavBackend / SafeServerBackend 重定向防护（B-H1 HTTP 重定向修复）。
- `http_util_test.dart` —— `sendWithRedirectPolicy` 单元测试（B-H1 HTTP 重定向修复）。
- `http_util_live_test.dart` —— `sendWithRedirectPolicy` 真实网络集成测试（B-H1，默认跳过）。
- `database_import_test.dart` —— 备份导入 `storeNotesInTransaction` 的 uuid 幂等去重（避免导出再导回撞唯一约束整体回滚）。
- `backup_file_test.dart` —— 备份文件编解码（明文 plaintext-v1 + 加密 snbak v1）：格式往返、错误密码/篡改 salt/iterations 失败、旧格式兼容、未知格式拒绝、版本保护、B-KEY 原语往返。
- `blob_addressing_test.dart` —— blob 寻址不变量测试。
- `hard_delete_all_test.dart` —— `hardDeleteAllDeleted` 批量硬删除（回收站清空单事务回归）。

---

## 2. 应用层测试（`test/`）

### 2.1 `test/sync/sync_config_test.dart` —— 同步配置单元测试

覆盖三层逻辑：

1. `SyncBackendDraft` 值对象：`isComplete` / `connectionSignature` / `buildBackend`，
   切换类型不丢配置。
2. 同步总开关语义：`isSyncEnabled` / `hasBackendConfig` / `isSyncReady`，
   旧版本（无 `sync_enabled` 键）迁移默认值。
3. `SyncService.testBackendConfig`：对 localFs 后端做真实临时目录连通性测试。
- 用 `setMockInitialValues` 注入 SharedPreferences mock；用内存 Map 模拟
  `flutter_secure_storage` 的 MethodChannel（避免 `MissingPluginException`）。

### 2.2 `test/sync/change_password_multi_client_test.dart` —— 改密码多端回归测试

- 背景：用户报告的"某端改密码 → 另一端无提示 → 重启后旧密码无法登录"。
- 固化为 BUG-1~BUG-4 修复后的正确行为断言：
  - B1-2（sync_engine）：密钥纪元守卫触发时上传 header 的密钥三元组整体采用远端值，
    翻转战争不再发生（S1/S2）。
  - B3（keyring.adoptRemoteEpoch）：他端改密码 + 本端新密码登录，本地 meta 整体收敛（S5）。
  - B4（home.dart）：监听 `SyncResult.passwordEpochMismatch` 弹窗提示（UI 层，无单测）。

### 2.3 `test/generate_real_db_test.dart` —— 真实数据库生成工具

- 生成两份**可直接替换客户端数据库**的真实 `safenotes_sync.db`，供多端/大笔记/联调测试。
- 全程走真实接口（`Keyring.createNew` / `NotesDatabase.storeNote` / `unlockLocal` /
  `readAllNotes`），不 mock。
- 两个独立 keyring（各自 vaultId/salt/dataKey/密码）；笔记内容默认从
  `temp/rfc4918.txt` 随机截取（1KB~100KB）。
- 环境变量：`GEN_DB_OUT` / `GEN_DB_PASSWORD_A` / `GEN_DB_PASSWORD_B` /
  `GEN_DB_COUNT` / `GEN_DB_SEED` / `GEN_DB_CORPUS`。

### 2.4 `test/widget_test.dart` —— Widget 冒烟测试

- 仅验证 `login_button.dart` 的 `ButtonWidget` 能正确渲染 `FilledButton`、
  文案，点击触发 `onClicked`。最小 Flutter widget 测试。

### 2.5 其他应用层测试与集成测试

以下 `test/` 下的测试文件同样存在，未在 §2.1–§2.4 逐一展开：

- `test/auth_flow_test.dart` —— 认证流程集成测试：驱动真实 App（AuthWall → 登录 / 首次设置密码），覆盖首次运行设密码、登录、改密码三条主路径。
- `test/export_backup_dialog_test.dart` —— 导出面板（ExportBackupDialog）widget 测试：加密/明文二选一、密码确认、空/不一致密码按钮禁用、明文模式隐藏密码框、提交返回 `ExportOptions`。
- `test/notes_color_contrast_test.dart` —— 笔记卡字体色对比度测试（P1-12）：16 个卡片色主题在「原色」与「浅色模式提亮 0.4」两种背景下的 `getFontColorForBackground` 对比度。
- `test/theme_color_setting_test.dart` —— 主题颜色选择器（ThemeColorPicker）测试：目标色从 `AppThemeSeeds` 动态获取，断言聚焦行为而非硬编码色值。
- `test/sync/sync_test_support.dart` —— app 侧对 core 测试支撑的 re-export（见上文「公共支撑文件」）。

### 2.6 端到端集成测试（`integration_test/`）

- 入口：`integration_test/app_test.dart`（单文件，无需额外 `integration_test.dart` 驱动）。
- 覆盖 note CRUD + 设置页 12 项导航（双视口）冒烟。
- 运行：`flutter test integration_test/ -d windows`（见 `CLAUDE.md`）。
- **状态**：`docs/integration-test-plan.md` 规划的 4 个 flow 文件 + `test_helpers` 改造**仅部分落地**，当前为单文件 `app_test.dart`；登录错误、首次设密码、删除路径等断言尚未覆盖。

---

## 3. 测试支撑与脚本

| 文件/目录                          | 作用                                              |
|------------------------------------|---------------------------------------------------|
| `packages/core/test/sync/sync_test_support.dart` | Keyring/Journal 构造、账本持久化断言、FakeJournalStore |
| `test/scripts/test-cleanup.ps1`    | 清理残留 server 进程/端口/临时目录（集成测试用）  |
| `test/analysis_options.yaml`       | 测试目录的 analysis 选项                          |

---

## 4. 运行速查

```bash
# 核心同步单元测试（纯 Dart，用 dart test，无需 Flutter SDK；内存后端，秒级）
dart test packages/core/test/sync/sync_engine_test.dart
dart test packages/core/test/sync/crypto_test.dart
dart test packages/core/test/sync/keyring_test.dart
dart test packages/core/test/sync/journal_test.dart
dart test packages/core/test/sync/multi_device_test.dart
dart test packages/core/test/sync/p0p1_self_heal_test.dart
dart test packages/core/test/sync/local_fs_backend_test.dart
# 其他核心测试（§1.12）同上改用 dart test

# 集成测试（需 Go / Node.js / webdav.exe 实际存在，否则自动跳过；用 flutter test）
flutter test packages/core/test/sync/safe_server_integration_test.dart
flutter test packages/core/test/sync/webdav_integration_test.dart

# 重型/长期测试（注意文件落盘与克隆纪律；纯 Dart 用 dart test）
dart test packages/core/test/sync/chaos_multi_client_test.dart
LONGRUN_GENS=5 dart test packages/core/test/sync/longrun_persistent_store_test.dart

# 应用层（需 Flutter）
flutter test test/sync/sync_config_test.dart
flutter test test/sync/change_password_multi_client_test.dart
flutter test test/generate_real_db_test.dart
flutter test test/widget_test.dart
flutter test test/auth_flow_test.dart
flutter test test/export_backup_dialog_test.dart
flutter test test/notes_color_contrast_test.dart
flutter test test/theme_color_setting_test.dart

# 端到端集成（见 §2.6）
flutter test integration_test/ -d windows

# 核心全量
dart test packages/core/test
# 应用层全量
flutter test
```
