# SafeNotes CLI 客户端设计（功能完备的非 GUI 测试客户端）

> 生成日期：2026-08-03 08:35
> 目标：把 `bin/safenotes_cli.dart` 从冒烟验证空壳升级为**功能完备的 CLI 客户端**，
> 覆盖 Flutter App 的大部分业务功能（增删改查、密钥管理、同步、备份导入、诊断），
> 后续主要用它来做**真实流程测试**（多目录多设备同步、密钥迁移、冲突、改密码等）。
>
> 依据的功能点清单：`docs/app-feature-inventory-20260803.md`。
> 架构约束：CLI 是 core 的第二个前端，纯 Dart 可编译（编译不过即说明有人往 core
> 塞了 Flutter 依赖）。

---

## 1. 设计原则

1. **每条命令是独立进程**：CLI 不像 App 常驻内存，没有全局登录态。每次调用都要能
   独立恢复出「解锁 → 装配同步引擎」的能力，因此密钥与后端配置必须**持久化到数据目录**。
2. **数据目录 = 一个"设备实例"**：`--data-dir` 目录下自含数据库 + 日志 + journal + 配置。
   用**两个不同的 data-dir** 即可模拟两台设备做同步/冲突/迁移测试（等价于 App 的两台机器）。
3. **密码不落库、不落进程列表**：dataKey 由密码实时派生。密码来源优先级：
   `--password` 参数 > `--password-file` 文件 > 环境变量 `SN_PASSWORD`。
4. **敏感凭据不进 SQLite**：WebDAV 密码 / SafeServer Token 走参数或环境变量
   （`SN_WEBDAV_PASSWORD` / `SN_SAFESERVER_TOKEN`），或 `backend-credentials.json`
   （明示"仅测试用途"）。SQLite 里只存非敏感配置。
5. **人读文本默认、`--json` 可切机器可读**：文本便于人看，JSON 便于测试脚本断言
   （`note list --json` / `note get --json` / `sync status --json` 等）。
6. **退出码语义**：成功 `0`，用户可预期错误（缺密码、未初始化、笔记不存在等）`1`，
   异常崩溃 `2`。脚本可直接 `if ($LASTEXITCODE -ne 0)` 判断。
7. **直接复用 core，不绕 SyncService**：App 的 `SyncService` 依赖 path_provider /
   shared_preferences（插件），CLI 无法用。CLI 直接装配
   `Keyring + SyncBackend + Journal + SyncEngine`（与 `sync_test_support.dart` 同构），
   这正好验证 core 的可嵌入性。

---

## 2. 数据目录布局

> **构建与运行（推荐编译产物）**：
> 每次 `dart run` 都要重新解释/编译源码且有 "Running build hooks" 噪声；SDK ≥3.12 的
> `dart compile exe` 不支持 build hooks（sqlite3 有 hook），因此用新式 AOT 构建命令：
>
> ```bash
> dart build cli -t bin/safenotes_cli.dart -o build/cli
> # 产物：build/cli/bundle/bin/safenotes_cli.exe + build/cli/bundle/lib/sqlite3.dll（bundle 需整体分发）
> build/cli/bundle/bin/safenotes_cli.exe <命令> [子命令] [--data-dir DIR] [--password P]
> ```
>
> 实测 `keyring status` 从 `dart run` ≈3.5s 降到 ≈60ms（约 58x），且无进度文本噪声。
> 测试脚本 `scripts/cli-e2e-test.ps1` 自动优先用编译产物，缺失时回退 `dart run`。

```
<data-dir>/                      # 例如 temp/dev-a、temp/dev-b
├── safenotes_sync.db            # SQLite（schema v4，与 App 完全一致）
├── safenotes-YYYYMMDD.log       # 核心日志（AppLogFile，纯 Dart）
├── journal/                     # Journal 操作日志（Journal.open(baseDir=data-dir)）
└── backend-credentials.json     # 【可选】WebDAV 密码 / SafeServer Token（仅测试）
```

meta 表新增 CLI 专用键（非敏感）：

| meta key | 含义 |
|---|---|
| `cli_device_id` | 设备 ID（首次生成 `cli-<8hex>` 持久化，可用 `--device-id` 覆盖） |
| `cli_backend_type` | `localfs` \| `webdav` \| `safeserver` \| `none` |
| `cli_backend_localfs_path` | LocalFS 根目录绝对路径 |
| `cli_backend_webdav_url` / `cli_backend_webdav_username` | WebDAV 服务根 URL / 用户名 |
| `cli_backend_safeserver_url` | SafeServer 服务 URL |

`deviceId` 落库的理由：同一 data-dir 重复运行命令时设备 ID 必须稳定
（manifest `lastModifiedBy` / journal 隔离按设备），否则每次都是"新设备"。

---

## 3. 命令树（总览）

```
safenotes_cli [全局参数] <命令> <子命令> [子命令参数]

全局参数（必须写在命令名之前，args CommandRunner 约定）：
  --data-dir <dir>        数据目录（默认 temp/cli-data）
  --password <p>          解锁密码（交互式终端用）
  --password-file <path>  从文件读解锁密码（首行，自动去空白；自动化推荐）
  --device-id <id>        覆盖设备 ID（不落库）
  -h, --help              帮助

├── db                       数据库管理
│   ├── info                 数据库/schema/meta 概览
│   └── wipe --yes           忘记密码逃生通道（删除 db + journal，全量销毁）
│
├── keyring                  认证与密钥管理
│   ├── init [--json]        首次设置密码（密码取自全局参数，Keyring.createNew）
│   ├── unlock [--json]      解锁本地 keyring（unlockLocal → 注入 dataKey）
│   ├── status               密钥状态（vaultId/keyVersion/epoch/fingerprint/reason）
│   ├── verify               校验密码是否正确（不持久化）
│   └── change-password --old <p> --new <p> [--json]   修改密码（O(1)，keyVersion+1）
│
├── note                     笔记 CRUD
│   ├── add --title --body | --file [--json]    新增
│   ├── list [--deleted] [--query] [--limit] [--json]    列表（更新时间倒序）
│   ├── get <id|uuid> [--json]         查看单条（含正文）
│   ├── update <id|uuid> [--title] [--body|--file] [--json]    更新
│   ├── delete <id|uuid>               软删除（进回收站）
│   ├── restore <id|uuid>              恢复（撤回墓碑）
│   ├── hard-delete <id|uuid> --yes    永久删除（写 purged，防远端复活）
│   └── purge-deleted --yes            清空回收站
│
├── export [--out <path>]    导出备份（与 App 备份同格式，可互导）
├── import --in <file>       导入备份（ImportParser → storeNote；已存在 uuid 跳过）
│
├── sync                      同步子系统
│   ├── setup                配置后端（localfs/webdav/safeserver/none）
│   │     --type <t> --path <dir> | --url <u> --username <u> [--backend-password] [--backend-token]
│   ├── run [--backend-password] [--backend-token] [--json]    手动同步（SyncEngine.sync）
│   ├── repair [--backend-password] [--backend-token] [--json] 修复远端数据（repairRemote）
│   └── status               同步状态（后端/providerKey/manifest version，无需解锁）
│
├── journal
│   ├── status               条目统计（目录/总条目/nextSeq/pending）
│   └── cat [--tail N] [--json]    查看操作日志（审计/可观测）
│
├── log
│   ├── path                 显示当前日志文件路径
│   └── cat [--tail N]       直接 cat 日志文件（无需 Web 服务）
│
└── meta                      高级元数据操作（测试/排障用）
    ├── list                 列出 meta 表所有键值
    ├── get <key>            读单个 meta
    └── set <key> <value>    写单个 meta
```

---

## 4. 功能点 ↔ App 对照

| 命令 | 对应 App 功能（页面/流程） | 复用的 core API |
|---|---|---|
| `keyring init` | 首次设置密码 `/signup` | `Keyring.createNew` → `database.setDataKey` |
| `keyring unlock` | 密码登录 `/login` | `Keyring.unlockLocal` → `setDataKey` |
| `keyring verify` | 登录密码校验 | `Keyring.unlockLocal` / `verifyPassword` |
| `keyring change-password` | 修改密码 `/changepassphrase` 5 步 | `verifyPassword` → `changePassword` → 重建 engine → 可选 sync |
| `keyring status` | 调试面板"状态"页 | `KeyringLedger.load` / `Keyring.getVaultId` |
| `db wipe` | 忘记密码逃生通道 | `close` + `deleteDbFile` |
| `note add` | 新建笔记 `add_edit_note` | `SafeNote.create` → `storeNote` |
| `note list` | 主页列表 `home.dart` | `readAllNotes` / `readDeletedNotes` / `readUnsyncedNotes` / `readAllNotesIncludingDeleted` |
| `note get` | 查看详情 `note_view` | `readNote` / `readNoteByUuid` |
| `note update` | 编辑保存 | 读回 → `updateNoteByUuid`（重算 hash + updatedAt=now + synced=false） |
| `note delete` | 删除（回收站） | `softDelete(id)` |
| `note restore` | 回收站恢复 | `restoreNote(id)` |
| `note hard-delete` | 回收站永久删除 | `hardDelete(id)` / `hardDeleteByUuid(uuid)` |
| `note purge-deleted` | 回收站清空 | 循环 `hardDelete` |
| `export` | 自动/手动备份 | `exportAll`（包装为 `{records, recordHandlerHash, total}`） |
| `import` | 备份导入 `confirm_import` | `ImportParser.fromJson` → `storeNote` |
| `sync setup/config` | 同步设置页 `sync_settings` | meta 表 + 后端工厂（替代 SharedPreferences） |
| `sync run` | 立即同步 / 自动同步 | `SyncEngine.sync()` |
| `sync repair` | "修复同步数据" | `SyncEngine.repairRemote()` |
| `sync status` | 调试面板状态/同步结果 | keyring + backend.providerKey + `getManifestVersion` |
| `journal cat` | 诊断面板（审计） | `Journal.open` + `readAll` |
| `log cat` | 诊断面板"日志"页 | `AppLogFile` 日志文件直接 cat |
| `meta *` | （测试排障专用） | `getMeta` / `setMeta` |

> **移除 `web`（日志 Web 服务器）**：CLI 场景下日志是本地文件、journal 是本地 JSON，
> 直接 `log cat` / `journal cat` / 编辑器 tail 即可，Web 服务器无存在必要（评审确认）。
> `LogWebServer` / `AppLogBuffer` 仍供 App 使用，CLI 不接入。

> 不纳入 CLI 的 App 功能（依赖 Flutter 插件，见 feature-inventory §CLI 可复用性总表）：
> 生物识别、会话超时锁定、共享偏好设置（主题/语言/备份开关等）、平台目录/媒体扫描、
> file_picker 导入选文件。这些是纯 UI / 平台能力，与"核心逻辑真实流程测试"无关。

---

## 5. 关键设计决策与实现要点

### 5.1 解锁语义（note / export / import / sync 系列）
- 所有需要 dataKey 的命令先 `ensureUnlocked(password)`：已解锁则跳过，未解锁用解析出的
  密码 `Keyring.unlockLocal` → `database.setDataKey`。
- 密码来源统一走全局参数：`keyring init` / `unlock` / `verify` 不再收位置参数，
  password 一律经 `--password` / `--password-file` / `SN_PASSWORD` 注入（自动化友好）。
- 密码错误抛 `WrongPasswordException`，CLI 转成 `exit 1` 的友好报错。
- `db info` / `keyring status` / `sync status` / `journal cat` / `log cat` / `meta *`
  无需解锁（只读非密数据）。

### 5.2 同步装配（不依赖 SyncService）
```
Keyring(已解锁) + SyncBackend(按 meta 配置构建) + Journal.open(baseDir=dataDir) + SyncEngine
  passphraseProvider: () => 会话密码      # 场景 d（两设备独立建 vault 后互通）判别用
  onKeyringChanged: (k) => keyring = k    # B2：dataKey 迁移后回写引用，防旧 keyring 悬空
```
- journal 在 engine 生命周期内单实例（改密码/换后端不重开，保持 seq 连续——与 App 一致）。
- `sync run` / `sync repair` 前先 `backend.init()`（幂等；网络后端离线时下次重试，对齐 Bug A 语义）。

### 5.3 `note update` 的同步语义
编辑后必须：重算 `contentHash`（`SafeNote.computeHash`）、`updatedAt = now`、
`synced = false`，否则同步引擎不会把新版本推到远端。用
`updateNoteByUuid`（App 的 `NoteEditorState.addOrUpdateNote` 等效路径）。

### 5.4 `keyring change-password` 流程（对齐 App 5 步）
① 旧密码解锁（验证）→ ② `keyring.changePassword(old, new, db)`（返回新实例，keyVersion+1，
dataKey 不变故 epoch 不变，无需重加密）→ ③ 替换 context 引用 + 重建 engine →
④ 若已配置后端，`sync run` 推送新 encryptedDataKey。
（`forceBackup` / 平台路径探测属 App 平台层，CLI 跳过，不影响密钥语义。）

### 5.5 导出/导入格式与 App 互操作
- `export` 输出：`{records: [...], recordHandlerHash: "plaintext-v1", total: N}`
  （与 App 明文备份格式一致，App 导出的备份可被 CLI `import`，反之亦然——互操作测试点）。
- `import` 不设交互确认（CLI 即显式命令），逐条 `storeNote`，打印成功条数；
  **已存在同 uuid 的笔记跳过**（幂等，可重复导入；App 直接 storeNote 会 UNIQUE 冲突）。

### 5.6 参数解析用 package:args（不手写 parser）
- 采用 `CommandRunner<String?>` 命令树：全局参数定义在 runner.argParser，
  子命令参数定义在各 Command 上；帮助/用法错误由 args 抛 `UsageException`，入口统一
  捕获并打印（退出码 64）。`help` 命令自动生成。

### 5.7 实现过程中发现并规避的坑（sqflite_common_ffi）
- **相对路径解析错位**：sqflite_common_ffi 会把相对路径解析到
  `.dart_tool/sqflite_common_ffi/databases/` 下，导致 `--data-dir` 相对路径跑偏。
  引导时统一 `Directory(dataDir).absolute.path` 转绝对路径。
- **console 日志污染 stdout**：core `Log` 三路输出中 console 走 `print()`（stdout），
  会破坏 `--json`。给 `AppLogFile` 新增 `consoleEnabled`（默认 true，App 不变）与
  `preferLogDirOverride`（默认 false）两个开关，CLI 引导时置
  `consoleEnabled=false`、`preferLogDirOverride=true`，让日志只落 `--data-dir/logs/`。

### 5.8 多设备真实流程测试脚本
完整端到端脚本：`scripts/cli-e2e-test.ps1`（参照 `longrun_persistent_store_test.dart`
的长期存续思路，用 CLI 驱动：keyring init/unlock、note 增删改恢复、改密码、双 data-dir
LocalFS 双向同步收敛、删除传播、export/import 往返）。运行：`pwsh scripts/cli-e2e-test.ps1`。
**状态：已实现并全绿（43/43 断言）。** 实现要点：
- **二进制优先**：脚本优先调用 AOT 编译产物 `build/cli/bundle/bin/safenotes_cli.exe`，
  缺失时回退 `dart run`（仅在回退分支保留 build-hooks 清洗——`dart run` 的 "Running build
  hooks" 进度文本以 `\r` 与真实输出粘连在同一行，先 `-replace 'Running build hooks\.*'`
  再剥离行首 `\r`/空格，避免误删真实内容）。
- 断言含变量（如 uuid）的正则必须用双引号字符串保证插值；含 `[` `]` 的字面量需转义
  （`\[已删除\]`）。
- 脚本须以 UTF-8（含 BOM）保存，并在开头设 `[Console]::OutputEncoding`/`$OutputEncoding` 为
  UTF-8，否则中文断言与 CLI 输出捕获均失效。

### 5.9 安全红线
- 日志、stdout 绝不打密码 / Token / 笔记正文之外的敏感信息（沿用 core 隐私红线）。
- WebDAV 密码 / SafeServer Token 不入 SQLite；如写 `backend-credentials.json` 必须显式
  `--backend-password`/`--backend-token` 触发，并在输出中警告"仅测试用途"。

---

## 6. 验收标准（自测清单）

1. `keyring init` → `keyring status` → `note add` → `note list` → `note get`（含解密往返）。
2. `note update` / `delete` / `restore` / `hard-delete` / `purge-deleted` 全链路。
3. 双 data-dir + LocalFS 后端：A 建笔记同步 → B join 同步后 `note list` 可见；
   双向编辑 → `sync run` 后 LWW 收敛 / 冲突副本行为符合预期。
4. `export` → 清空 → `import` 往返，字段（uuid/hash/createdAt）保持。
5. `keyring change-password` 后旧密码失效、新密码可解锁、`note get` 仍可解密。
6. `db wipe` 后 keyring 归未初始化、note 全空。
7. `dart analyze bin` 零 error；`dart run` 全命令可用。
8. 自动化：`pwsh scripts/cli-e2e-test.ps1` 全绿（覆盖 1–7 的完整流程）。

---

## 7. 实施拆分（已完成）

| 步骤 | 内容 | 状态 |
|---|---|---|
| 1 | `bin/cli_context.dart`：CliContext（引导 / 解锁 / 后端与引擎装配 / 凭据解析） | ✅ |
| 2 | `bin/cli_commands.dart`：全部命令组实现（args CommandRunner 命令树） | ✅ |
| 3 | `bin/safenotes_cli.dart`：入口 + 全局参数 + 异常/退出码映射 | ✅ |
| 4 | `dart analyze bin` + `dart format bin` + 端到端自测（§6） | ✅ |
| 5 | core 微改：`AppLogFile.consoleEnabled` / `preferLogDirOverride`（默认值不改变 App 行为） | ✅ |
| 6 | `scripts/cli-e2e-test.ps1` 完整测试脚本 | ✅ |
