# 评审报告核实结论（code-review-20260829.md）

- 核实日期：2026-08-29
- 方法：**逐条回到源码通读核对**，未运行测试/构建（与评审方一致，仅做静态源码核实）。
- 结论总览：**报告质量很高，所提问题基本都是真实存在的缺陷，未发现明显误报；主要问题是严重性标定偏激进（多个 P0 实为窄触发条件的 P1），以及个别数字/机制描述小误差。**

---

## 一、7 个 P0 的逐项核实

| 编号 | 评审结论 | 源码核实 | 判定 |
|---|---|---|---|
| P0-1 | 墓碑 GC 漏 `addPurgedUuids`，删除的笔记会从远端复活 | `sync_engine.dart:1690-1693` 确实 `hardDeleteByUuid` + `continue`，**无** `addPurgedUuids`；且 `:1686-1687` 注释明确写了"并加入 purgedUuids"，与代码矛盾。 | **真实缺陷**，但非"正文复活"——远端是 `deleted:true` 墓碑，复活的是墓碑（已删笔记重新出现在回收站），且服务端元数据永久保留。必须修（一行即可），严重性偏 P1。 |
| P0-2 | 读路径物理 DELETE 解不开的行，无备份无确认 | `database_handler.dart:564-565` 阈值、`572-596 _deleteBrokenRows`（不进 purgedUuids）、`643-660 _decryptRowWithGuard`（**不判阈值**，单行即删）全部属实。 | **真实且最该优先**。纯本地用户/从未同步的笔记，解不开即永久丢失。这是 7 个 P0 里唯一"常见路径即可触发静默丢数据"的，P0 标定合理。 |
| P0-3 | 迁移守卫是 TOCTOU 空转，未加守卫的写路径用旧 key 加密 | `_checkNotMigrating`（467-471）是"抛异常式"检查；`reEncryptAllNotesAtomically` 在 `1997` 置 `_isMigrating`、`:2001` 换 oldKey、`:2020` 才换 newKey；`softDelete(1543)`/`hardDelete(1588)`/`restoreNote(1790)`/`upsertNoteMeta(2539)`/`markSynced(2130)` 等**确实无守卫**。 | **真实缺陷**。链路（新行躲过重加密→旧 key 密文→P0-2 删）成立。但触发前提是"改密码/换账本迁移进行中用户并发写"，窗口由 UI 遮罩收窄。必须修，但标定 P0 略激进，更像 P1。 |
| P0-4 | 迁移吞掉解密异常的 meta/version 行却报告成功 | `_readMetaPayloadsPlain(2814-2834)` 与 `_readAllVersionsPlain(2844-2868)` 均 `on Object catch` 吞异常、跳过、`Log.w`，事务照常提交。属实。 | **真实缺陷**。但仅在"oldKey 不对"时才会批量跳过（错误密码迁移），属防御性正确性缺口。应修，标定 P0 偏激进。 |
| P0-5 | 远端 manifest 损坏重建丢"仅远端有"条目并 GC 他端 blob | `recoveredManifest == null` 时 `remote==null` 分支以 `local.items` 为 merged（1769-1788），随后 `:694-698` 空 etag PUT。属实。 | **真实设计弱点**，但触发前提极严：re-GET 失败**且**全部 bak 均不可解密——此时远端已是彻底不可恢复状态，"丢他端条目"在前提内近乎必然。属 P1，非 P0（常态不会触发）。 |
| P0-6 | LWW 纯依赖对端本地时钟，删除场景连副本都不留 | `_resolveConflict(2272-2277)` 仅比较 `updatedAt` 数值；`shouldPreserveCopy(1968-1973)` 要求两端都非删除。属实。 | **真实同步正确性缺陷**。需"时钟偏差设备 + 跨端并发编辑 + 一端删除"才丢数据。建议采用 HLC/保留副本，但标定 P0 偏激进（P1~P2 更合适）。 |
| P0-7 | 编辑页保存被"防重入返回 null"误判成功→静默丢改动 | `editor_state.dart:71-74/89-91` 两处返回 `null`；`add_edit_note.dart:362` `saved==null` 一律 `failed:false`；`:319/324` 据此直接关页。属实。 | **真实逻辑缺陷**（跳过保存被当作成功）。触发需"并发保存持静态 `_isSaving` 时用户恰在此时返回"，窗口窄。应修，标定 P0 偏激进。 |

**P0 小结**：7 项**全部为真实代码缺陷，无一误报**。但"P0=立即数据丢失"的标定对 5 项（P0-1/3/4/5/6/7，按本表为 6 项除 P0-2 外）偏激进——它们多为窄触发条件或仅特定场景下丢数据。**真正应按 P0 立即修的只有 P0-2**（读路径无差别物理删行）。其余建议作为 P1 一批处理。

---

## 二、抽样核实的 P1（全部真实，无误报）

| 编号 | 核实结果 |
|---|---|
| P1-1 | `unlockFromRemoteManifest(554-595)` 全程**无** `reEncryptAllNotesAtomically` 调用（仅 `migrateToRemoteVault` 727/828 有）。属实。风险需"本地账本损坏但 notes 表以另一 dataKey 存在"的窄前提，属 P1。 |
| P1-2 | `sync_engine.dart:1009-1021` 场景 d 密码匹配即无条件 `_executeMigrationVault`，无确认、无 vaultId 校验。属实。注：评审"一次密码猜测=全库泄露"的措辞略夸张——攻击者需**正确猜中密码**才能构造合法 fingerprint，门槛等同于一次正常登录；核心是"无确认自动改嫁远端金库"的硬化缺口。 |
| P1-3 | `_inspectorHiddenColumns={'title','description','payload'}`（58 行）**不含 `value`**；`queryTableRows(233-246)` 对 `sync_meta` 执行 `SELECT *` 完整返回 keyring JSON（含 encryptedDataKey+salt+iterations）。属实。LAN 日志服务可达时构成密钥材料泄露。**必须修（一行加 'value'）**。 |
| P1-5 | `OpenDatabaseOptions(698-702)` 确实**无 `onDowngrade`/`onConfigure`**；`_createNoteMetaTable` 已含 `locked`（755），`_onUpgrade` 的 `else if(oldVersion<6)` 仍 `ALTER ADD COLUMN locked`（931-934）。属实。注：评审"sqflite 静默回写 user_version"的机制描述与 sqflite 默认行为不完全一致（通常缺 `onDowngrade` 会抛异常而非静默降级），但"无 onDowngrade + ALTER 无 IF NOT EXISTS 守卫"是真实健壮性缺口。 |
| P1-6 | 同上，`onConfigure` 缺失，无 WAL/`busy_timeout`。属实。长迁移事务冻结读路径、多连接 `SQLITE_BUSY` 真实存在。 |
| P1-12 | `setWebdavUrl(174-177)` 原样 `Log.sync.d('…$url')`，URL 含 `user:pass@` 时密码入日志。属实。 |
| P1-13 | `buildBackend(382-404)` 仅判空，不校验 scheme；`http://` 明文传 Basic/Bearer。属实。 |
| P1-20 | 实测键数：en-US/zh-CN=534（满），15 个语种各=351（缺 183），zh-TW=383。**评审称"13 个缺 183"实为 15 个**（小计数误差，结论不变）。`_locales(753-769)` 确缺 `bn/hi/it`——已翻译却未注册，死资源。全部属实。 |

---

## 三、评审"已确认健康项"（第五节）抽查

- SQL 注入、KDF 边界校验、密文脱敏 `toString`、重定向同源跟随、blob 重试幂等等——与源码抽查一致，描述准确。
- 注意：第五节与 P1-12 不矛盾——"Basic Auth 不拼 URL"指认证构造本身；P1-12 指"用户粘贴含凭据的 URL 进日志"是另一条路径。

---

## 四、整体判定与修复建议

**评级**：报告**可信、务实、覆盖到位**，不是误报堆砌。问题集中在"异常/并发分支收尾"与"安全暴露面"，方向正确。

**必须立即修（真实且高概率/高影响）**：
1. **P0-2**：读路径禁止物理删行，改 `broken` 标记隔离（保留密文）。
2. **P1-3**：`_inspectorHiddenColumns` 加 `'value'`（或 `sync_meta` 直接禁止 `queryTableRows`）。
3. **P0-1**：`_buildLocalManifest` 补 `addPurgedUuids`（一行，注释本就要求）。
4. **P1-5/P1-6**：补 `onDowngrade`（非破坏）+ `onConfigure` 设 WAL/`busy_timeout`。
5. **P1-12/P1-13**：URL 内嵌凭据剥离+日志脱敏；`buildBackend` 强制 https（局域网需显式确认）。

**应修但可按 P1 排期（真实但窄触发/偶发）**：P0-3、P0-4、P0-7、P1-1、P1-2（加确认与 vaultId 校验）、P0-5（损坏重建保留 keep-set）、P0-6（HLC/保留副本）。

**夸大/小误差（不影响结论）**：
- 多个 P0 严重性偏高，实为 P1 级窄触发缺陷（除 P0-2）。
- P1-20 缺键语种数应为 15 而非 13。
- P1-5 对 sqflite downgrade 默认行为的机制描述不精确。
- P1-2"密码猜测即全泄露"措辞夸张（需正确猜中密码）。

**未发现误报**：本次抽样与 7 个 P0 的重点核实中，没有发现与源码不符的虚假问题。
