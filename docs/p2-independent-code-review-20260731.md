# SafeNotes P2 大改动 独立代码审查报告

- **审查对象**：Keyring 取代 Vault + 新增 Journal（P2 大改动）
- **审查方式**：独立代码审查（首次接触该改动，所有结论基于静态阅读 `lib/` 实现代码，不采信任何自述）
- **审查日期**：2026-07-31
- **验收基准**：代码实际遵循 `docs/p2-keyring-journal-design-fixed.md`（v2 方案 B），而非用户最初指定的 Draft `docs/p2-keyring-journal-design.md`。详见「一致性核对」。
- **环境约束**：本次审查**未运行** `flutter test` / `flutter analyze`（按用户要求），结论均来自源码与测试代码的静态阅读。

---

## 一、结论摘要

本次 P2 改动整体架构合理、防护意识到位：采用 Keyring 单键原子持久化、两层密钥解耦（MK 包裹 dataKey）、Journal 只报告不重放的保守恢复策略，并配套了混沌测试与跨运行长期不变量测试。

**未发现 P0（致命 / 数据丢失级）缺陷。** 自愈逻辑（下载失败重试、孪生物化重传、绝不静默删除）、墓碑 GC 的 `referenced` 保护、purgedUuids 防复活闭环、无明文密钥进入日志，这些关键不变量在静态阅读下均成立。

但存在 **1 个 P1（生产路径功能性缺陷）**：旧密码恢复路径 `repairRemote(oldPassword:)` 在 P2 后已失效（读取已废弃的 `data_key_history` 表，新设计的 `keyring.unwrapHistoryWith` 未接线），会在特定场景下使"改密码前用旧密钥加密的远端 blob"不可治愈。另有若干 P3（注释/测试覆盖缺口），不影响功能正确性。

---

## 二、问题清单

### [P0] 未发现 P0

经对数据丢失关键路径（`_handleDownloadFailure`、`_gcOrphanBlobs`、`reEncryptAllNotes` 事务保护、purgedUuids 防复活、`repairRemote` 自愈兜底）的逐行核对，**未发现有 P0 级缺陷**。以下为关键安全结论的支撑点：

- 下载自愈（`sync_engine.dart:1660-1836`）三态处理：有本机明文→重传；无非明文但有孪生→重传；无明文→标 corrupt 但**绝不抛异常、绝不静默删**。
- 孤儿 blob GC（`sync_engine.dart` 中 `_gcOrphanBlobs`）有 `referenced` 保护 + 软删隔离，不会删除仍被引用的 blob。
- 墓碑 GC 软删超 30 天墓碑不入 manifest，并写入 `purgedUuids` 防止后续远端墓碑"复活"已删笔记。

---

### [P1] repairRemote 旧密码恢复路径断裂（生产功能性缺陷）

**文件 / 行号**：`lib/sync/sync_engine.dart:661`（在 `repairRemote` 方法内，约 617-850）

**问题本质**：
P2 改动后，`Keyring.changePassword` / 迁移逻辑**只写新 `keyring.history`，永不再写旧的 `MetaKeys.dataKeyHistory` 表**（已 grep 确认：`appendDataKeyHistory` 在生产代码中有 **0 个调用方**，仅 `database_handler.dart` 内部 `getDataKeyHistory` 自引用、`keyring.dart:316/983` 注释、以及测试代码引用）。

但 `repairRemote` 在 Step 2 构建"候选 dataKey 集合"时，仍调用：
```dart
final history = await database.getDataKeyHistory();   // sync_engine.dart:661
```
读取的是已废弃、且 P2 后**永不再被写入**的旧表。新设计本应接线的替代方案 `Keyring.unwrapHistoryWith(Uint8List oldMk)`（`keyring.dart:985-1001`，遍历 `keyring.history` 用旧 MK 解包 `entry.encryptedDataKey`）**在全部生产代码中从未被调用**（仅 `keyring.dart:982-983` 注释引用）。

**触发条件**：
1. 用户在 P2 版本下**修改过密码**（产生旧 MK → 旧 dataKey 加密的历史 blob 残留于远端）；
2. 远端存在至少一个用"旧密码对应 dataKey"加密的遗留 blob；
3. 调用 `repairRemote(oldPassword:)`，意图用旧密码治愈这些 blob。
→ 结果：候选 dataKey 集合仅含当前 `keyring.current`，不含旧 dataKey → 旧密钥 blob 解不开 → 被标 `corrupt`。**数据不丢**（笔记 manifest/本地仍存），但**用旧密码已无法恢复**，与设计意图（旧密码 recover）相悖。

**测试掩盖**：`webdav_integration_test.dart:1721` 在测试 repair 时手工调用 `database.appendDataKeyHistory(...)` 注入旧历史，使 `getDataKeyHistory` 能取到数据，因此测试 PASS——但这条路径在真实生产代码中永远不会写入旧表，掩盖了生产缺口。

**建议修复方向**（任选其一，需在修复后补测）：
- 在 `repairRemote` 中改用 `keyring.unwrapHistoryWith(oldMk)` 构建候选集（接线已设计但未接的函数）；
- 或从 `keyring.history` 直接读取全部 `encryptedDataKey` 候选，用当前 `current.mk` 与各 `history` 条目尝试解包。

---

### [P3] keyring.dart 头注释自指错误（"取代 Keyring" 应为 "取代 Vault"）

**文件 / 行号**：`lib/sync/keyring.dart` 文件头注释（约 line 2、11、20、27、33）及内部注释（约 line 385、411）

**问题本质**：多处注释写为"取代 Keyring""旧 Keyring""原 Keyring"，但本次改动实际是 **Keyring 取代 Vault**（删除 `lib/sync/vault.dart`，新增 `lib/sync/keyring.dart`）。注释自相矛盾地把自己说成"取代自己"。

**影响**：纯文档/注释误导，不影响运行时行为；但会误导后续维护者理解架构演进（Vault→Keyring），属低风险可维护性问题。

**触发条件**：阅读/维护代码时产生混淆，无运行时触发。

---

### [P3] 30 天墓碑 GC 在 longrun 测试中未被真正覆盖（测试覆盖缺口，非代码缺陷）

**文件 / 行号**：`lib/sync/sync_engine.dart:994-1001`（墓碑 GC 阈值 `kTombstoneGcThresholdMs`，约 30 天）；`test/longrun_persistent_store_test.dart`（I3 不变量）

**问题本质**：
`longrun_persistent_store_test.dart` 仅含 1 个 `test`，默认 `LONGRUN_GENS=1`，每删除的笔记属于"近期删除"，远未达到 30 天阈值。I3 不变量只验证"近期墓碑不丢"，**未验证"超期墓碑被 GC 清除"**。代码逻辑本身（`_buildLocalManifest` 中软删超期墓碑 + 写 purgedUuids）正确，但缺乏针对 GC 实际触发的回归测试。

**影响**：墓碑 GC 这条路径一旦在重构中回归（例如阈值比较方向写反、purgedUuids 漏写），长期测试不会告警。属测试有效性缺口，非功能缺陷。

**建议**：在 longrun 或专项测试中注入可调时间源 / 直接将 `kTombstoneGcThresholdMs` 设为极小值，验证超期墓碑确实被软删且不通过 manifest 复活。

---

### [P3] 验收基准文档与代码实际遵循版本不一致（流程性问题，供读者注意）

**文件 / 行号**：`docs/p2-keyring-journal-design.md`（用户指定 Draft） vs `docs/p2-keyring-journal-design-fixed.md`（v2 方案 B，代码头注释实际引用）

**问题本质**：用户最初指定 Draft 为验收基准，但 `keyring.dart` 文件头注释与实现细节（如 §2.5 adoptRemoteEpoch 字段级更新 C2 修正、§2.6 history 上限 20 + 去重、§2.7 干净切断无双写）实际对应更完整的 `-fixed.md`（v2 方案 B）。两者存在多处差异。

**影响**：若以 Draft 为基准审阅，可能误判 `-fixed.md` 已修正的条目为"未实现缺陷"。本报告以 `-fixed.md` 为真正验收基准，避免此类误判。建议统一文档，删除或明确标注 Draft 为废弃版本。

**触发条件**：审阅者以错误文档为基准时产生误判，无运行时触发。

---

## 三、一致性核对（实现 vs 验收基准 `-fixed.md`）

以下逐项核对 `-fixed.md` 关键约束是否在实现中成立：

| 设计约束 | 基准出处 | 实现核对 | 结论 |
|---|---|---|---|
| Keyring 为密钥态唯一真相源，单键 `keyring` 原子持久化 | §2.4 代码映射 | `keyring.dart` `load`/`save`（单键读写）、`MetaKeys.keyring` 为权威键 | ✅ |
| 两层密钥：MK=PBKDF2-HMAC-SHA256(200k)，dataKey=AES-GCM(MK, dataKey) | §2 / §6 | `keyring.dart` create/unwrap 路径 | ✅ |
| 改密码只重新包裹 dataKey，dataKey 本身不变 | §5 方案 B | `changePassword`（860-907）保留 dataKey、仅更新 `encryptedDataKey` 与 mk | ✅ |
| history 上限 20 + 去重（同 keyVersion 一条） | §2.6 | `_normalizeHistory` 实现上限与去重 | ✅ |
| adoptRemoteEpoch 字段级更新，保留 dataKey/mk，防纪元回滚战争 | §2.5 / C2 | `adoptRemoteEpoch` 仅更新包裹态与纪元字段 | ✅ |
| 干净切断无双写（旧 8 键不再写入） | §2.7 | grep 确认 `appendDataKeyHistory` 生产 0 调用 | ✅（除 P1 读的旧表，写已切断） |
| Journal 双角色（审计/可观测 + 跨边界部分写兜底 + 防 manifest 单点故障第二数据源） | §3.1 | `journal.dart` 本地 append + 远端加密副本 `fetchRemoteEntries` | ✅ |
| Journal 只报告不重放（findIncompleteOperations 不自动修复） | §3.3 | `sync_service.dart:260-272` 只写日志 | ✅ |
| 无明文 key/password 进入日志 | §6 安全分析 | grep 验证日志内容均为密文/seq/op 类型，无 mk/dataKey 明文 | ✅ |
| 旧密码 recover 由 `keyring.unwrapHistoryWith` 取代 `getDataKeyHistory` | §5 / 附录 | `unwrapHistoryWith` 已实现但**未接线**（见 P1） | ⚠️ 设计到位，生产未接线 |
| 向后兼容：fromLegacyMeta 一次性转换旧 8 键 + data_key_history | §2.4 | `keyring.dart:246-297` `fromLegacyMeta` 读旧键 | ✅ |

**核对结论**：除 P1（旧密码 recover 设计已实现但未接入生产路径）外，实现与 `-fixed.md` 高度吻合，关键安全约束全部成立。

---

## 四、测试有效性评估

### 总体覆盖评价
测试体系设计质量高，分层合理：
- `keyring_test.dart`：覆盖 create/unlock/changePassword/多设备/dataKey 迁移/adoptRemoteEpoch/legacy 转换，单位层面充分。
- `journal_test.dart`：覆盖 append/seq、滚动归档、容错隔离、findIncompleteOperations（只报不修）、replayKeyState、远端加密副本、内存模式、wire 契约。
- `chaos_multi_client_test.dart`：2 大 group（随机混沌 + P2 定向故障注入 14 项），覆盖 journal 损坏/删除/重启/坏纪元/keyring 回滚/远端 blob 丢失等真实故障。
- `longrun_persistent_store_test.dart`：跨进程累积、I1-I8 不变量，验证长期收敛与密钥自洽，价值很高。

### 对 longrun_persistent_store_test.dart 的专门评价
- **亮点**：跨运行复用 `temp/longrun-store`（gitignored）并以 `state.json` 跨进程持久化账本，I1（收敛一致）/I2（历史不丢）/I4（引用完整）/I5（GC 有效但仅验证近期不丢）/I6（水位不退）/I7（密钥自洽）/I8（明文自洽）设计严谨。每 3 代改密、每 4 代重启的设计能真实暴露 keyring 演进与重启恢复问题。
- **缺口**：仅 1 个 test；默认 1 代，30 天墓碑 GC 阈值在测试中永不满足（见 P3）。建议补充"超期墓碑 GC 实际触发"用例（可调时间源）。
- 不变量 I3（墓碑保留）仅验证了"近期墓碑不丢"，未验证"超期墓碑被清除且不复活"，存在回归盲区。

### 被测试掩盖的生产缺口
- `webdav_integration_test.dart:1721` 的 repair 测试通过手工注入旧 `data_key_history` 表使 `getDataKeyHistory`（sync_engine.dart:661）能取数 → 测试 PASS，但真实生产代码中该表永不再被写入，掩盖了 P1 缺陷。**该 repair 用例需要改写为走 `keyring.unwrapHistoryWith` / `keyring.history` 的真实路径**，否则 P1 将长期无回归保护。

---

## 五、亮点（值得肯定的设计）

1. **Journal 只报告不重放**（`sync_service.dart:260-272`）：`findIncompleteOperations` 仅写日志，避免自动重放可能造成的二次损坏，恢复决策交给人工/上层，保守且安全。
2. **无明文密钥进入日志**（grep 验证）：journal 内容均为密文/seq/op 类型，满足 E2EE 安全要求。
3. **下载自愈绝不静默删**（`sync_engine.dart:1660-1836`）：本机明文重传、孪生物化重传、无明文标 corrupt 并区分 `isOldKey`，三态处理无数据丢失路径。
4. **Keyring 单键原子持久化**：消除旧 8 键 + data_key_history 多键双写的不一致窗口，`MetaKeys.keyring` 为唯一权威，配合 `adoptRemoteEpoch` 字段级更新（C2），无纪元回滚战争。
5. **墓碑 GC 闭环**：超期软删 + `purgedUuids` 防复活，孤儿 blob 有 `referenced` 保护 + 软删隔离，破坏性操作均留痕可审计。
6. **测试体系分层完备**：unit / journal / chaos / longrun 四层，尤其 chaos 与 longrun 对真实故障与长期不变量覆盖到位。

---

## 六、修复优先级建议

| 优先级 | 问题 | 修复成本 | 建议 |
|---|---|---|---|
| P1 | repairRemote 旧密码恢复断裂（sync_engine.dart:661 + keyring.unwrapHistoryWith 未接线） | 低（接线 + 改测试） | 尽快修复并补真实路径测试 |
| P3 | keyring.dart 头注释自指"取代 Keyring" | 极低 | 顺手改注释 |
| P3 | 30 天墓碑 GC 测试覆盖缺口 | 低 | 补可调时间源用例 |
| P3 | 验收基准文档不一致 | 极低 | 统一/归档 Draft |

**总体结论**：P2 架构方向正确、关键安全不变量成立、未发现 P0。唯一需开工的是 P1——旧密码恢复在生产路径上已失效，应在下个迭代接线 `keyring.unwrapHistoryWith` 并修正 repair 测试，使其不再依赖已废弃的旧表。
