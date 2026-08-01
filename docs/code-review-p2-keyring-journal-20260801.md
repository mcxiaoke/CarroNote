# 代码审查报告：p2-keyring-journal-refact vs dev

- **审查日期**: 2026-08-01
- **审查分支**: `p2-keyring-journal-refact`（HEAD = `a136257 fork: p2-keyring-journal impl and fix`）
- **对比基线**: `dev`（HEAD = `7797507 feat(logging): 重构日志系统...`）
- **审查范围**: 42 个文件，+7803 / -2086（单提交）

---

## 一、改动概览

当前分支相对 dev 只有一个大提交，核心是把 `vault.dart`（890 行）拆分为两个新模块，并强化同步引擎：

| 模块 | 变更 | 说明 |
|---|---|---|
| `lib/sync/keyring.dart` | 新增 1029 行 | 密钥账本单一真相源（取代 Vault）：current/history 收敛为单键 JSON 持久化，消除 33 处散落 setMeta 的 BUG-3/H1 根源 |
| `lib/sync/journal.dart` | 新增 1037 行 | 操作日志：审计 + 防 manifest 单点故障的第二数据源；两段式（start/done/failed）、批量 flush、失败永不阻断同步 |
| `lib/sync/sync_engine.dart` | +534/- | 强制注入 Journal；冲突副本保留判定改为"共同祖先 hash"三方合并（BUG-P0 二次修复）；header 统一由 keyring.toManifestHeader 投影 |
| `lib/data/database_handler.dart` | +128/- | 数据库 v2→v3：新增 `synced_hash` 列（冲突判定的 base），**保留用户数据**（v1→v2 仍是破坏性重建） |
| 三后端 | +55/+92/+67 | LocalFS/WebDAV/SafeServer 新增 journal 远端副本接口，失败静默降级 |
| `lib/sync/sync_service.dart` | +248/- | Journal 生命周期管理（单实例跨 engine 重建）；改密码时记 keyChangePassword 并 flush |
| UI 层 | 少量 | 基本为 Vault→Keyring 重命名与注释更新 |
| 测试 | +5400/-700 | 新增 journal_test/keyring_test/longrun_persistent_store_test；chaos/multi_device 大幅增强；vault_test 删除 |

**未引入新依赖**（pubspec.yaml 零改动）；旧 API（initVaultFromPassword/updateVault/cacheVaultFromLogin）无残留；`data_key_history` 无生产写入方。

## 二、测试验证

`flutter test test/sync/` 全部 **249 个用例通过**（耗时约 6m25s），包括：

- 5 个随机 seed 的"118 克隆真实数据 + 改密码随机交织"三客户端混沌测试
- 11 个 P2 定向故障注入（journal 损坏/目录删除/App 重启/manifest 损坏/坏纪元污染/账本回滚/远端副本还原等）
- 66 代长期存续测试（跨运行复用文件库）
- 关键回归：单边编辑不造副本（sync_engine_test 新增用例）、真并发保留副本、删除不复活

## 三、问题发现

### P1（建议修复）

1. **journal 归档路径无串库保护**（journal.dart:792）
   `Journal.open()` 只隔离当前 `log.json`；`readAll()` 解析归档时忽略 `_parseLogMap` 返回的 `vaultMismatch`，异库归档条目会混入。触发条件：scenario-d 迁移（vaultId 变化）或 keyring 重建后目录残留旧归档。影响：`findIncompleteOperations` 启动自检误报（仅日志警告）；`replayKeyState` 理论上可能取到异库密钥状态（该 API 目前无生产调用方，风险可控，但注释声称的"串库隔离"承诺未覆盖归档路径）。

2. **测试的 v2→v3 迁移覆盖缺口**（database_handler.dart:322-335）
   `_createDBStatic` 忽略 version 参数、始终建含 synced_hash 的 v3 形状表 → longrun/chaos/change_password 等测试在**全新目录**下 `onUpgrade` 永不触发，longrun 声称的"v2→v3 迁移"实际未被执行（仅跨运行复用生产 v2 建库时才触发）。且 `upgradeDBForTesting`/`_upgradeDBStatic` 是生产 `_upgradeDB` 的独立副本，两处逻辑存在漂移风险。生产迁移逻辑本身经验证正确。

3. **关键恢复路径无测试覆盖**
   `Keyring.migrateToRemoteVault`（scenario-d 整库改嫁）、`Keyring.unwrapHistoryWith`（旧密码 repair 候选集）、`Keyring.updateEncryptedDataKey`（H1 回写）在整个 test/ 目录均无直接用例。

### P2（建议改进）

4. **longrun 账本对账会掩盖"副本增殖"回归**（longrun_persistent_store_test.dart:563-591）：`_reconcileLedgerWithLocal` 把一切账本外活跃笔记补登为合法，且每代对账先于不变量核对——若增殖 bug 回归，副本会被吸收进账本，I1/I2 断言依然通过。
5. **keyring_test 清空旧散落键是死代码**（keyring_test:130-131）：P2 后 createNew 只写 `MetaKeys.keyring` 单键，清空 vault_id/encrypted_data_key 不影响状态，"两次创建不同"断言实际靠随机性保证。
6. **多设备测试伪多库**（keyring_test:238-244 等）：传已 close 的 dbA 引用，靠静态单例 `NotesDatabase.instance` 隐式解析到 dbB 才跑通，直连重构后即碎。
7. **"同 hash 副本不增殖"机制无直接断言**：multi_device 真并发用例只断言副本内容，不检查标题含设备标识/序号（sync_engine.dart:1413-1424 的实现）。
8. **SyncService._keyring 与 SyncEngine.keyring 迁移后不同步**（观察点）：engine 内部迁移替换 keyring 后，SyncService 仍持旧引用（诊断面板显示旧纪元）。此为既有行为（旧 Vault 同样），非本次引入；但 updateKeyring 的 journal 判定依赖该引用，建议后续显式同步。
9. **UI 术语从 Vault 改为 Keyring**：'加密 Vault'→'加密 Keyring' 等硬编码中文串（无 .tr() 翻译条目），对普通用户 Keyring 更陌生。低优先级。

### 已确认正确的设计决策

- 冲突三方合并（base = 本地 syncedHash）在串行同步/真并发/删除传播/新笔记等场景推演均正确：单边更新不造副本、真并发双方内容都保留、删除只传播不复活。
- `base == null`（新笔记/未同步数据）保守退化为"内容不同即保留副本"——多留一份但绝不丢数据。
- Journal 不在 DB 事务内写、两段式记录、恢复以 DB 实际状态为准（只报告不重放）——避免"一次故障变二次损坏"。
- 远端 journal 永不落明文（整体 AES-GCM(dataKey)）；失败静默降级本地-only。
- 冲突副本标题追加"(冲突副本 N·设备标识)"，从源头切断同 hash 链式增殖（实测曾出现 1 内容 13 uuid）。

## 四、结论

**整体质量高，可以合并**：

1. **是否解决了问题**：是。修复了真实的 BUG-P0（时间差判据导致单边更新误造副本 → 无限增殖，及真并发被 LWW 静默覆盖丢数据）；密钥态收敛为单键账本消除多键双写不一致；v2→v3 平滑迁移保留用户数据。
2. **是否引入新问题**：未发现 P0 级问题。P1 集中在测试覆盖缺口与 journal 归档串库防护（均不导致数据丢失或同步失效），建议合并前修复 #1（归档串库，改动小），其余列入后续迭代。
3. **遗留风险**：journal 第二数据源的完整恢复链路（fetchRemoteEntries/replayKeyState）目前无生产调用方，属于"设施已建、流程未接"，后续实现"重装恢复"功能时需要补齐端到端验证。
