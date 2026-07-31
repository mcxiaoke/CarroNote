# P2 Keyring/Journal 复杂度与可恢复性决策分析

> 配套文档：`docs/p2-keyring-journal-design-fixed.md`（方案 B + Journal 可恢复双角色修订版 v2）
> 目的：记录"去掉向后兼容约束"与"Journal 重新定位为可恢复+审计"两个决策的依据、代码事实与三方案对比。
> 代码基线时间：2026-07-31

---

## 0. 背景：两个被重新放开的约束

在 `p2-keyring-journal-design-fixed.md` 第一版（方案 A）中，有两个妥协是**外部约束**造成的，并非设计最优：

1. **"不动 SyncEngine 任何 vault.xxx 调用点"**：为避免改 SyncEngine，选了方案 A（Vault 持 Keyring 子对象 + 委托访问器）。
2. **"Journal 仅审计/可观测"**：因 `reEncryptAllNotes` 已被 SQLite 事务保护，把 Journal 的崩溃恢复角色降级为诊断。

用户在本轮复核中指出：
- 若开发阶段**不再要求兼容旧数据/旧代码**，约束 1 可移除 → 方案 B（Keyring 直接取代 Vault）可行；
- Journal 的**原意就是防单点故障/可恢复数据**（草案 G2 崩溃安全、§3.5 崩溃恢复、manifest 单点故障），约束 2 是过度修正，应恢复其可恢复定位。

本文用代码事实重新评估这两点，并给出最终决策。

---

## 1. 代码基线事实（量化）

| 事实 | 数值 | 来源 |
|---|---|---|
| `vault.dart` 规模 | 890 行 | `wc -l` |
| `vault.dart` 内 `setMeta(MetaKeys.xxx)` 散落写入 | 33 处 | `grep -c` |
| 全仓 `vault.` 引用 | 56 处 | `grep -rno` |
| 引用 `vault.` 的文件 | 6 个：`sync_engine / sync_service / login / set_passphrase / change_passphrase / main` | `grep -rln` |
| `sync_engine.dart` 规模 | 1847 行 | `wc -l` |
| `database_handler.dart` 规模 | 902 行 | `wc -l` |

关键洞察：
- 56 处 `vault.` 引用中，绝大多数是 `vault.dataKey` / `vault.dataKeyEpoch` / `vault.mk` 这类**只读运行时字段**，是**机械重命名**（改为 `keyring.xxx`），不触及 merge/GC/自愈的编排逻辑。
- 密钥态散落在 `Vault` 字段 + `ManifestHeader` + `DataKeyHistory` 三处，靠 `adoptRemoteEpoch`/`updateEncryptedDataKey`/`appendDataKeyHistory` 手动双向同步——这是 BUG-3/H1 的根因，与"是否兼容旧代码"无关，方案 A/B 都消除它。

---

## 2. 三方案对比

| 维度 | 现状 | 方案 A（fixed v1） | **方案 B（本文决策）** |
|---|---|---|---|
| 密钥层架构 | Vault↔Header↔History 三处互写，33×setMeta | Vault 持 Keyring+委托桥（间接层仍在） | **Keyring 单一真相源，删 Vault，无桥无三处互写** |
| SyncEngine 编排（合并/GC/自愈） | 1847 行 | 不变 | **不变**（与密钥对象位置无关） |
| 密钥层代码量 | vault.dart 890（含 33 setMeta+三处互写+MetaKeys） | vault 890 + keyring≈200 + 桥≈50 ≈ 1140 | **删 890，加 keyring≈450 + journal≈400 ≈ 850** |
| 密钥态写入入口 | 34 处散落 setMeta | 收敛为 keyring.current + persist，但 Vault 委托层保留 | **收敛为 keyring.current + persist，无中间层** |
| 可恢复/防单点 | 无 | 仅审计（无） | **有（审计+重放+离线副本）** |
| 改动面 | — | 几乎不动 SyncEngine（委托），但保留 Vault 全量 | 56 处机械重命名 + 删 Vault + 重写持久化 |
| 向后兼容 | 现状 | 双写镜像 + fromLegacyMeta | **不兼容，干净切断（旧用户重 onboard/一次性转换）** |
| 一次性工程量 | — | 低（不动 SyncEngine） | 中（重构 + 一次性迁移），但无长期双写债 |

> 代码量估算说明：`keyring.dart` ≈450 行（含运行时 dataKey/mk + 账本 + persist + 会话方法，取代 vault.dart 的密钥职责，但去掉了 33×setMeta 与三处互写）；`journal.dart` ≈400 行（方案 B 下含可恢复流程与远端副本，较 v1 审计-only 的 ~250 行增加）。

---

## 3. 决策一：选方案 B（Keyring 取代 Vault）

**理由**：
1. **密钥层架构更简单**：方案 A 为"不动 SyncEngine"保留了 Vault + 委托桥 + 双写镜像，反而多一层间接（Vault.keyring.current.xxx）。去掉兼容性后，这层间接毫无存在价值。
2. **代码量反而更小**：方案 A 下密钥层 ≈1140 行；方案 B 删 Vault 890，加 keyring+journal ≈850，相对方案 A 省 ~290 行，相对现状持平略减（且新增防单点能力）。
3. **56 处重命名是机械的**：编排逻辑（merge/GC/自愈）不变，仅 `vault.`→`keyring.` 改名，回归风险可控（单测覆盖）。
4. **C1 在方案 B 下自然解决**：dataKey/mk 直接放 Keyring（运行时字段，不持久化），不再需要"Vault 持 Keyring"的折中。

**代价（诚实）**：
- 一次性重构工程量高于方案 A（删 Vault 类 + 改 56 处引用 + 把三处互写重写成 Keyring 单持久化）。
- 不计兼容：旧用户需重 onboard 或跑一次性 `fromLegacyMeta` 转换（不进长期代码）。

**结论**：在"不要求兼容"前提下，方案 B 在架构清晰度、代码量、长期维护性上全面优于方案 A，故采用方案 B。

---

## 4. 决策二：Journal 重新定位为"可恢复 + 审计"双角色

### 4.1 原意确认（草案）

草案明确把 Journal 定义为可恢复层：
- `G2 崩溃安全`：关键批量操作"有可重放/回滚的记录"（原文档第 33 行）
- `§3.5 崩溃恢复`：`reEncryptAllNotes` 前写 `key.migrate(start)`、完成后 `done`，崩溃重启重放/回滚（第 156–166 行）
- `manifest 单点故障`：单一 `manifest.json` 密文是同步脆弱点（第 24 行）
- `P0-2 优雅替代`：blob 自描述污染格式，journal 在外部记录同样信息供自愈查（第 120 行）

### 4.2 之前为何降级（及为何是过度修正）

fixed v1 看到 `reEncryptAllNotes` 已被 SQLite 单事务保护（`database_handler.dart:628-688`，step5 单事务 `:663`），于是把 Journal 的"崩溃重放"判为与事务重叠，降级为诊断。

**问题**：把"进程内崩溃原子性"（SQLite 已覆盖）与"数据丢失/损坏/服务端单点"（SQLite 覆盖不了）混为一谈，把后者也一起扔了——而这正是用户强调的"防单点故障/可恢复数据"。

### 4.3 重新划界

| 失效模式 | 责任方 | 说明 |
|---|---|---|
| 进程内崩溃（事务中途） | **SQLite 事务** | 事务回滚，DB 仍为旧密文；不靠 Journal |
| 事务提交后、更新 _dataKey 前崩溃 | **Keyring 重初始化** | 下次登录用密码重派生 dataKey，状态一致 |
| 跨边界部分写（blob 重写但 manifest item 未更新等跨步状态） | **Journal（兜底）** | SQLite 单事务管不到跨步边界 |
| 本地 DB 被清 / 设备丢失 | **Journal（离线副本）** | 本地库无，需第二数据源重建 |
| 服务端 manifest 损坏/丢失（单点） | **Journal（远端副本）** | manifest SPOF，第二数据源 |
| 坏纪元污染 key history | **Journal（replay/repair）** | 用 journal 重建正确 key state |

**结论**：Journal 不替代 SQLite 的进程内原子性；但作为**可重放运维日志 + 离线/远端第二数据源**，负责 SQLite 与单 manifest 覆盖不了的失效模式。恢复流程见 fixed 文档 §3.6。

### 4.4 代价

- Journal 需新增**重放/修复消费者** + 离线同步 + 恢复流程，复杂度高于纯审计。
- "重放正确性"本身难测——若重放语义有 bug，"恢复"可能变"二次损坏"，需严格单测 + 混沌验证（fixed 文档 §8 混沌项）。

---

## 5. 对 fixed 文档的影响

- §2.1 由方案 A 改为方案 B（删除 Vault 类，Keyring 持 dataKey/mk）。
- §3.1 / §3.6 Journal 由"审计-only"升级为"可恢复+审计"，新增恢复流程与离线副本设计。
- §5 迁移方案简化为"干净切断 + 一次性转换"，无双写镜像。
- §7 决策记录新增"方案 A vs B"与"Journal 角色"两项决策。
- 附录 A 第 1、5 条修正映射更新。

---

## 6. 净评估

- **同步/数据流复杂度**：SyncEngine 编排层（合并/GC/自愈）复杂度一条未减（任何方案都减不掉）；密钥管理层复杂度**下降**（单一真相源，无三处互写、无委托桥）。
- **代码量**：密钥层从现状 890（无 journal）变为 ~850（含 journal），持平略减；相对方案 A 省 ~290 行。Journal 可恢复角色使 journal 代码从 ~250 增至 ~400，但换来真实的防单点能力。
- **收益**：结构更清晰 + 首次具备密钥态可恢复/防单点能力（现状为零）。
- **代价**：一次性重构工程量中等；重放正确性须严格验证。

---

*分析基于 safenotes 代码基线（vault.dart 890 / sync_engine.dart 1847 / database_handler.dart 902 行），决策于 2026-07-31 用���复核后落地。*
