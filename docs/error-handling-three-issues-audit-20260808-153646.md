# SafeNotes 错误处理三项结构性问题详尽分析报告

> 扫描范围：`lib/` + `packages/core/lib/`（78 个 Dart 源文件，17,179 行有效代码 / 35,613 行含测试，不含测试文件）
> 生成时间：2026-08-08 15:36 (GMT+8)
> 工具：`temp/analyze_eh.py`、`analyze_eh2.py`、`analyze_eh3.py`、`analyze_eh4.py`（均为静态扫描脚本，可复跑）
> 目的：针对"宽捕获 `on Object` 残留 / 大量 catch 只记日志不处理 / `sync_engine.dart` 单文件 god file"三项问题做精确、可据以改代码的审计。

---

## 0. 摘要与结论

整体错误处理的**数量**对"端到端加密 + 多后端同步"应用属**合理偏高，并非病态**：全局约 **15.1%** 的代码行位于 `try/catch/finally` 区域内，且 95% 的异常处理集中在同步（SYNC）与数据库（DB）子系统，UI 层（`lib/`）仅 4.8%——分层是干净的。

真正的结构性问题在**质量与一致性**，而非占比：

1. **宽捕获 `on Object` 残留 31 处**（早前统计的 33 含 `sync_error.dart` 中 2 处文档注释示例，非编译代码）。其中仅 1 处（`crypto.dart:335`）是设计本身要求的 `Error→Exception` 桥；3 处是日志系统自保护；9 处 `rethrow`（危害低）；3 处是合法的"typed-catch 后接 `on Object` 兜底"（但违反本项目自己的契约）；**剩余 15 处是 sole 吞掉异常的真正反模式**，其中 10 处在 `sync_engine.dart`。
2. **"只记日志不处理"的 catch 共 41 处**——但经逐条核对，约 30 处是同步/GC/Journal 层的"尽力而为降级"（不阻断主流程，设计正确）；**真正有掩盖风险的是少数几处**，最典型是 `lib/views/home.dart:206` 把任何错误都清空笔记列表，可能掩盖 `dataKey` 不匹配 / 数据库损坏等完整性故障。
3. **`sync_engine.dart` 是 god file**：约 2,883 行（1,849 行有效），26 个 `try`、32 个 `catch`、13 个 `on Object`、63 个分段注释，单个文件混入了**同步编排、冲突解决、scenario 状态机、bak 选择、manifest 自修复、密钥迁移、孤儿 blob GC、下载自愈**等 6+ 类职责，难以维护与单测。

**一句话**：数量不过量，问题在"该精确的没精确、该上抛的被吞掉、该拆分的没拆分"。

---

## 1. 方法与总览数据

### 1.1 扫描方法

- 用 Python 解析每个 `.dart` 源文件，做**括号级配对的块追踪**（忽略字符串/注释内的括号），定位 `try` 块及其 `catch`/`on X catch`/`finally` 子句，提取每个 catch 块的**异常类型**与**代码体**。
- 对 `on Object catch` 额外判定其为 **sole（块内无前置 typed catch）** 还是 **chained（前置有 `on <类型> catch`）**，以区分"真反模式"与"Dart 习惯的默认兜底"。
- catch 体分类：rethrow / log-only（仅日志、无 rethrow/return/fallback 控制流）/ recovery（含 retry/return/fallback/`??`）/ other。
- 对 `sync_engine.dart` 做文件级结构统计（行数、方法数、分段注释数、`scenario/conflict/bak/re-GET/recover` 等关键词密度）。

### 1.2 全量指标

| 指标 | 数值 |
|---|---|
| 源文件数 | 78 |
| 有效代码行（去空行/注释） | 17,179 |
| `try` 块 | 171 |
| `catch` 子句 | 152 |
| `throw` | 82 |
| `finally` | 9（全局仅 9 个，I/O 资源释放偏薄弱） |
| 自定义异常/错误类 | 18 |
| 位于 try/catch/finally 的代码行占比 | **15.1%** |
| `on Object catch`（可执行代码） | **31**（含 1 处合理桥、3 处日志自保护、9 处 rethrow、3 处 chained、15 处 sole 吞掉） |
| 仅记日志的 catch | **41** |

### 1.3 分子系统错误密度

| 子系统 | 文件 | LOC | try | catch | 异常代码行占比 |
|---|---|---|---|---|---|
| 同步 SYNC | 13 | 7,636 | 114 | 113 | **24.1%** |
| DB 层 | 1 | 877 | 13 | 10 | **29.8%** |
| 其他 core | 6 | 1,053 | 18 | 5 | 11.9% |
| Crypto | 1 | 140 | 1 | 1 | 6.4% |
| APP (lib/) UI | 57 | 7,473 | 25 | 23 | 4.8% |

---

## 2. 问题一：宽捕获 `on Object` 残留

### 2.1 为什么是反模式（结合本项目自身契约）

项目已建立 `sealed class SyncError` 体系（`sync_error.dart`），并在文件头注释中明确：

> "替代散落在 sync_engine.dart 的 `on Object` 兜底捕获，让错误类型信息在 catch 处可见"
> "任何 `on Object catch` 兜底层都必须先分流这两种异常（ManifestAuthException / ManifestKeyMismatchException），否则新异常被吞掉、问题被掩盖。"

`Object` 是 Dart 中所有类型的根，**`on Object catch` 会连 `Error` 子类（`StateError`、`UnsupportedError`、以及 pointycastle 的 `InvalidTag` 等编程/库错误）一起捕获**。后果：
- 新引入的异常类型被静默吞掉，无法走既有分流契约；
- 编程错误（空指针、越界、断言失败）被当成普通同步异常"降级"，掩盖真实 bug；
- 无法做 `exhaustive` 分流，调试时丢失类型信息。

### 2.2 完整清单（31 处，按严重程度分类）

| # | 位置 | 类型 | 处理 | 严重度 | 说明 |
|---|---|---|---|---|---|
| 1 | `crypto/crypto.dart:335` | SOLE | 包装后 `throw` | ✅合理 | **设计要求的 `Error→Exception` 桥**（pointycastle `InvalidTag` 继承 `Error`），全代码库唯一应保留的 `on Object` |
| 2 | `logger/app_logger.dart:334` | SOLE | `print` | ✅可接受 | 日志系统自保护，绝不能因记日志失败崩溃 |
| 3 | `logger/app_logger.dart:591` | SOLE | `print` | ✅可接受 | 同上 |
| 4 | `logger/log_webserver.dart:193` | SOLE | 忽略 | ✅可接受 | 响应已关闭，二次写入失败忽略 |
| 5 | `db/database_handler.dart:337` | SOLE | 日志+`rethrow` | 低 | 抛错前留痕，错误仍上抛 |
| 6 | `db/database_handler.dart:477` | SOLE | 日志+`rethrow` | 低 | 同上 |
| 7 | `db/database_handler.dart:647` | SOLE | 日志+`rethrow` | 低 | 同上 |
| 8 | `db/database_handler.dart:670` | SOLE | 日志+`rethrow` | 低 | 同上 |
| 9 | `db/database_handler.dart:704` | SOLE | 日志+`rethrow` | 低 | 同上 |
| 10 | `db/database_handler.dart:873` | SOLE | 日志+`rethrow` | 低 | 同上 |
| 11 | `db/database_handler.dart:1357` | SOLE | 日志+`rethrow`+`finally` | 低 | 同上，且正确释放 |
| 12 | `sync/keyring.dart:227` | SOLE | 吞掉→`return null` | 中 | 账本 JSON 损坏视为"未初始化"——语义刻意，但用 `on Object` 过宽 |
| 13 | `sync/sync_engine.dart:1225` | SOLE | 日志+`rethrow` | 中 | 迁移失败，错误上抛 |
| 14 | `sync/sync_engine.dart:1304` | SOLE | 日志+`rethrow` | 中 | scenario-d 迁移失败，错误上抛 |
| 15 | `sync/sync_engine.dart:642` | CHAINED | 吞掉→`failure` | 中 | typed `ManifestKeyMismatch`/`ManifestAuth` 之后的默认兜底（Dart 习惯，但违反本项目契约） |
| 16 | `sync/sync_engine.dart:993` | CHAINED | 吞掉→`failure` | 中 | typed `ManifestKeyMismatch`/`ManifestAuth` 之后的默认兜底 |
| 17 | `sync/sync_engine.dart:1075` | CHAINED | 吞掉→进修复分支 | 中 | typed `SyncDecryptionException` 之后的默认兜底 |
| 18 | `sync/sync_engine.dart:369` | SOLE | 吞掉→本地重建 | 中 | re-GET 失败降级 |
| 19 | `sync/sync_engine.dart:394` | SOLE | 吞掉→试下一份 | 中 | bak 选择循环跳过 |
| 20 | `sync/sync_engine.dart:401` | SOLE | 吞掉→本地重建 | 中 | bak 读取失败降级 |
| 21 | `sync/sync_engine.dart:1861` | SOLE | 吞掉 | 中 | 冲突副本保留失败（不阻断） |
| 22 | `sync/sync_engine.dart:1990` | SOLE | 吞掉→记失败 action | 中 | blob 上传未预期异常 |
| 23 | `sync/sync_engine.dart:2214` | SOLE | 吞掉→自愈 | 中 | 下载未预期异常 |
| 24 | `sync/sync_engine.dart:2288` | SOLE | 吞掉 | 中 | 本机明文自愈重传失败 |
| 25 | `sync/sync_engine.dart:2348` | SOLE | 吞掉 | 中 | 孪生笔记自愈重传失败 |
| 26 | `lib/main.dart:190` | SOLE | 吞掉（日志） | 低 | 停止日志 Web 服务器失败 |
| 27 | `lib/main.dart:366` | SOLE | 吞掉（日志） | 低 | 升级后自动备份失败 |
| 28 | `lib/models/biometric_auth.dart:124` | SOLE | 吞掉→`return ''` | 中 | 指纹凭据解包失败→指纹登录不可用（注释已说明不回退明文，OK，但 `on Object` 过宽） |
| 29 | `lib/views/home.dart:100` | SOLE | 吞掉（日志） | 低 | 启动日志 Web 服务器失败 |
| 30 | `lib/views/settings/sync_diagnostics_page.dart:757` | SOLE | UI `setState` | 低 | 诊断页启动失败 |
| 31 | `logger/log_webserver.dart:303` | SOLE | 吞掉（写错误响应） | 低 | 诊断快照获取失败 |

**分布**：`sync_engine.dart` 13 处（10 SOLE + 3 CHAINED），`database_handler.dart` 7 处（均 rethrow），其余散落。

### 2.3 改造方案

**A. 真正 sole 吞掉的路径（#12, #18–#25, #28, #31 等）改为捕获具体类型或 `SyncError`**：

改造前（`sync_engine.dart:642` 一带）：
```dart
} on ManifestKeyMismatchException catch (e) { ... }
} on ManifestAuthException catch (e, st) { ... }
} on Object catch (e) {                      // ← 反模式：吞掉所有 Error
    Log.sync.w('MK 未缓存且解析远端 manifest 未预期异常，中止同步', error: e);
    return SyncResult.failure('...解析失败：$e', attempts: attempt);
}
```
改造后（遵守 §11.1 分流契约，未预期错误显式包装为 `UnexpectedError`）：
```dart
} on ManifestKeyMismatchException catch (e) { ... }
} on ManifestAuthException catch (e, st) { ... }
} on SyncDecryptionException catch (e, st) {            // 具体类型
    return _recoverFromCorruptRemoteManifest(remoteResponse, e, st, attempt);
} catch (e, st) {                                       // 仅捕获 Exception（不含 Error）
    Log.sync.e('MK 未缓存且解析远端 manifest 未预期异常', error: e, stackTrace: st);
    return SyncResult.failure('...解析失败：$e',
        attempts: attempt,
        error: UnexpectedError(operation: 'deserializeRemoteManifest', cause: e, stackTrace: st));
}
```
> 要点：用 `catch (e)`（等价于 `on Exception catch`）替代 `on Object catch`，使 `Error` 子类（编程 bug）**上浮而非被吞**；确需兜底时显式包 `UnexpectedError` 并记录堆栈，满足 `sync_error.dart` 对"兜底必须记录堆栈"的要求。

**B. `database_handler.dart` 的 7 处**：因均为"日志后 `rethrow`"，危害低，但同样建议把 `on Object` 改为 `catch (e)` 以保留错误类型；`rethrow` 行为不变。

**C. `crypto.dart:335`**：**保留**——这是契约里明确要求的 `Error→Exception` 桥，是全代码库唯一合法的 `on Object`。

**D. 日志系统（#2–#4）与 `log_webserver.dart:193`**：**保留**——日志/诊断服务自身不能因异常崩溃，属合理自保护。

---

## 3. 问题二：catch 只记日志不处理（41 处）

### 3.1 判定方法与分布

按"catch 体含日志调用、且无 `rethrow`/`return` 兜底值/`continue`/`break`/retry 控制流"判定为 log-only。分布：

| 位置 | 数量 | 性质 |
|---|---|---|
| `backends/webdav_backend.dart` | 11 | GC / 备份 / 孤儿清理"尽力而为"，不阻断同步 ✅设计正确 |
| `sync/journal.dart` | 12 | 日志损坏→隔离→以空日志继续，自愈 ✅设计正确 |
| `backends/safe_server_backend.dart` | 5 | 同上（GC/备份）✅ |
| `backends/local_fs_backend.dart` | 2 | 同上 ✅ |
| `sync_engine.dart` | 4 | GC / 副本保留失败，注释明确"不阻断主同步"✅ |
| `sync/sync_service.dart` | 3 | Journal 自检/关闭/后端切换拒绝 ✅ |
| `lib/views/home.dart` | 1 | ⚠️ **清空笔记列表** |
| `lib/views/change_passphrase.dart` | 1 | 推送新密钥失败，本地已生效、下次重试（边界 OK） |
| `lib/views/authentication/login.dart` | 1 | 指纹失败留痕（失败由返回 false 处理）✅ |
| `lib/utils/scheduled_task.dart` | 1 | 备份目录回退私有目录 ✅ |

### 3.2 诚实结论：多数并非"粗心跳过"

逐条核对后，**约 30/41 是同步/GC/Journal 层的刻意降级**：这些操作（孤儿 blob 清理、损坏日志隔离、manifest 服务端备份）本就不该阻断主同步流程，catch 后记日志降级是正确设计，不应改成 `rethrow`。

**真正需要修的是少数会掩盖"数据完整性/安全"信号的路径**：

1. **`lib/views/home.dart:206`（高危）**——任何异常（含 `DataKeyNotSetException`、迁移进行中、DB 损坏）都被吞掉并**清空笔记列表**，仅提示"刷新失败"。对加密笔记应用，这会把"密钥不匹配/数据库损坏"这类严重故障伪装成"空列表"，用户无法区分是真没笔记还是完整性故障。
   - 建议：至少要区分异常类型——`MigrationInProgressException` 等待、`DataKeyNotSetException` 引导重新登录，而非一律清空。

2. **`lib/views/change_passphrase.dart:417`（中）**——改密码后推送新密钥失败被吞，靠"下次同步重试"。若重试也因密钥状态不一致持续失败，用户无感知。建议至少把失败写入可观测状态（诊断页/上次同步错误），而非仅 `Log.auth.w`。

3. **加密/解密成功路径上的 log-only**：如 `sync_engine.dart:2214/2288/2348` 的自愈失败分支，当前"吞掉+记日志"，建议改为附 `UnexpectedError`/失败 `SyncAction`，让诊断页能呈现，而非仅靠日志。

### 3.3 改造原则（给后续改代码用）

- **I/O 尽力而为（GC/备份/孤儿清理/日志隔离）**：保持 log-only，但统一在日志里带 `error:` 与 `stackTrace:`，并确认诊断页可检索。
- **数据完整性/密钥/加密路径**：**宁可 `rethrow` 或包 `UnexpectedError` 上抛**，也不要静默吞。
- **UI 层吞异常做降级**：必须**按异常类型分流**，绝不用"清空数据/空列表"作为通用兜底。

---

## 4. 问题三：`sync_engine.dart` 单文件 god file

### 4.1 规模指标

| 指标 | 数值 |
|---|---|
| 总行数 | 2,883（有效 1,849） |
| `try` / `catch` / `on Object` | 26 / 32 / 13 |
| 分段/步骤注释 | 63 |
| `scenario` 关键词 | 21 |
| `conflict` 关键词 | 34 |
| `bak` 选择循环 | 22 |
| `re-GET` 自修复 | 15 |
| `recover`/`rebuild` | 27 / 2 |
| `ManifestAuthException` / `ManifestKeyMismatchException` 引用 | 各 7 |

### 4.2 单文件内耦合的职责（6+ 类）

1. **同步主编排**：`_syncFromManifest` 等主流程，含乐观锁重试（conflictAttempts）、迁移重试（migrationAttempts）独立计数。
2. **冲突解决**：34 处 `conflict` 引用，乐观锁冲突回到 Step 1 重试。
3. **scenario 状态机**：21 处 `scenario`（scenario-b 密钥/迁移、scenario-d 迁移），本质是状态机却用 `if/else` + 顺序 `on` 链平铺。
4. **bak 选择循环**：22 处 `bak`，§11.2 要求"任何异常跳过当前份试下一份"，嵌套在多个方法里。
5. **manifest 自修复**：`re-GET`、损坏重建 `_recoverFromCorruptRemoteManifest`、§7 统一恢复编排。
6. **密钥迁移 + 孤儿 blob GC + 下载自愈**：`_executeMigration` / `_executeMigrationVault` / `_gcOrphanBlobs` / `_handleDownloadFailure` 全部同文件。

### 4.3 为什么难维护 / 难测

- **单方法超长**：`_syncFromManifest` 等主方法跨数百行，含多层 `try/on/catch` 嵌套，一处改动易牵动冲突/迁移/自愈多条路径。
- **恢复逻辑平铺**：`scenario`/`bak`/`re-GET` 以 `if/else` + 顺序 catch 表达，新增恢复分支需通读全文，回归风险高（设计文档 §3.2、§11.1 反复强调的分流契约正是为约束这一点）。
- **测试耦合**：所有恢复路径在同一文件，单测需构造完整引擎实例；混沌测试（`chaos_multi_client_test`）已覆盖但难以针对单条恢复分支隔离。
- **`finally` 偏少**（全局 9 个）：长方法内 I/O（blob 流、manifest 响应）释放依赖调用方，易泄漏。

### 4.4 拆分方案（建议）

把 `sync_engine.dart` 按职责拆为子模块（仍属 `packages/core/lib/src/sync/`）：

- `sync_orchestrator.dart`：主流程编排，只负责步序与重试预算，不含恢复细节。
- `conflict_resolver.dart`：乐观锁冲突重试 + scenario-b/d 状态机（可用显式 `SyncPhase` enum + `Map<SyncPhase, Handler>` 替代 `if/else`）。
- `manifest_recovery.dart`：`re-GET`、损坏重建、§7 统一恢复编排、`bak` 选择循环（抽成独立 `selectRecoverableManifest()`）。
- `download_selfheal.dart`：`_handleDownloadFailure` 及孪生/明文自愈。
- `orphan_gc.dart`：`_gcOrphanBlobs` 与隔离区清理。
- `key_migration.dart`：`_executeMigration` / `_executeMigrationVault`。

拆分后每个文件 < 400 行、单一职责，`on Object` 收敛到 `manifest_recovery` 等确需兜底处，并按 §11.1 契约改为具体 `SyncError` 类型。

---

## 5. 综合优先级与改造路线图

| 优先级 | 项 | 范围 | 收益 | 风险 |
|---|---|---|---|---|
| **P0** | 修 `home.dart:206` 清空列表吞异常 | 1 文件 | 消除"完整性故障被伪装成空列表"的高危隐患 | 低 |
| **P0** | `sync_engine.dart` 的 10 处 sole `on Object` 改 `catch (e)`/具体 `SyncError` | sync_engine | 让编程错误上浮、遵守 §11.1 分流契约 | 中（需回归测试） |
| **P1** | `database_handler.dart` 7 处 + 其余 sole `on Object` 改 `catch (e)` | db + 散点 | 保留错误类型、统一契约 | 低 |
| **P1** | 加密/自愈失败路径补 `UnexpectedError`/`SyncAction` | sync_engine | 诊断页可观测，不靠日志盲查 | 低 |
| **P2** | 拆分 `sync_engine.dart` 为 6 子模块 | 架构 | 可维护/可测性质变 | 中（大改，需配套测试） |
| **P2** | 增加 `finally`/作用域释放（DB/网络 I/O） | 全局 | 减少资源泄漏 | 低 |

**建议落地顺序**：先做 P0（2 项，机械改动 + 回归测试即可），再 P1（批量改 `on Object` + 补可观测性），最后 P2 架构拆分。所有改动建议配合现有 `packages/core/test/sync/*` 混沌/多设备测试验证。

---

## 6. 附录

### 6.1 31 处 `on Object catch` 全表（已含于 §2.2）
### 6.2 41 处 log-only catch 分布（已含于 §3.1）
### 6.3 复用脚本

- `temp/analyze_eh.py`：块级 try/catch/finally 行覆盖率 + 分文件密度。
- `temp/analyze_eh2.py`：分子系统聚合 + catch 用途分类（初版，heuristic 偏宽）。
- `temp/analyze_eh3.py`：逐 catch 块提取与分类（最终采用：on_object=32 / log_only=41 / recovery=47 / rethrow=3 / other=29，合计 152 = 全局 catch 数）。
- `temp/analyze_eh4.py`：`on Object` 的 sole/chained 判定 + `sync_engine.dart` 结构统计。

> 注：§2.2 的"31 处可执行 `on Object`"已剔除 `sync_error.dart:329`、`:366` 两处文档注释示例（早前"33"统计的来源）。`crypto.dart:335` 为设计要求的唯一合法 `on Object`，改造时**务必保留**。
