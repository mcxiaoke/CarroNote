# code-review-20260829 逐条核实报告

* 核实日期：2026-08-29 (GMT+8)

* 针对文档：`docs/code-review-20260829.md`

* 核实方式：全部 7 个 P0 + 全部 22 个 P1 **回到源码逐行复验**；P2 仅抽查（P2-18 / P2-29 / P2-30）

* 关键文件：`packages/core/lib/src/db/database_handler.dart`、`packages/core/lib/src/sync/sync_engine.dart`、`packages/core/lib/src/sync/keyring.dart`、`packages/core/lib/src/sync/backends/*`、`packages/core/lib/src/models/note_meta.dart`、`lib/views/*`、`lib/models/editor_state.dart`、`lib/sync/sync_service.dart`、`lib/sync/sync_config.dart`

***

## 总体结论

原评审的**代码引用准确率高**：绝大多数"注释与代码不符 / 缺少收尾"的判断都经得起回溯。但它在两类地方定级偏重：

1. **把已成文的既有设计取舍当成"必须修的 bug"**（P0-2、P0-6）；
2. **安全叙述 / 影响面评估被夸大**（P1-2 的"一次密码猜测=全库泄露"、P1-8 的"必判冲突丢数据"、P1-5 的"降级即崩"机理存疑）。

判定汇总：

| 类别            | 数量        | 明细                            |
| ------------- | --------- | ----------------------------- |
| ✅ 真实且必修       | P0×4、P1×6 | P0-1/3/5/7；P1-3/9/11/14/15/16 |
| ⚠️ 真实但定级/理由夸大 | P0×3、P1×3 | P0-2/4/6；P1-2/8/10            |
| ❌ 接近误报 / 机理存疑 | P1×1      | P1-5                          |
| 其余            | —         | 见各节                           |

***

## 一、P0 逐条核实

### P0-1 墓碑 GC 未登记 purgedUuids —— ✅ 真实，必修

* [sync\_engine.dart:1690](path) 硬删除过期墓碑后只 `continue`，无任何 `addPurgedUuids`；而注释 `:1674-1689` 明写"并加入 purgedUuids"。**注释与代码不符，写漏了。**

* 真实现象：因不在 purgedSet，远端墓碑每轮经"仅远端有"分支被重新下载 → **F1 墓碑 GC 永远清不了远端**；离线删除 >30 天未同步时，活笔记会从远端复活。

* 修复极小：补一行 `await database.addPurgedUuids(note.uuid)`。注：数据"复活"场景需 30 天离线且删除未同步才触发，属窄路径，但代码-注释不一致是确凿缺陷。

### P0-2 读路径物理 DELETE 解密失败行 —— ✅ 描述真实，但属既定设计（非"新 bug"）

* [database\_handler.dart:563](path) 阈值、`:571` `_deleteBrokenRows`、`:642` `_decryptRowWithGuard` 单行直接删——**代码事实与评审描述完全一致**。

* **但这是 M1 迭代中用户已明确拍板的设计取舍**（删除坏行、不进 purgedUuids、靠云端/备份自愈；隔离落盘被判定为过度设计）。注释 `:548-557` 已记载权衡。

* 判定：**不是评审发现的新缺陷，而是对既定决策的质疑**。"必须修"的定性与项目现状冲突。维持现状即可；如需进一步，最低限度可把坏行密文落盘 `temp/recovered-*.bin`。

### P0-3 迁移守卫 TOCTOU —— ✅ 真实，必修

* [storeNote:953](path) 守卫在 await 之前、`_dataKey` 读取在嵌套 await 之后；**`upsertNoteMeta`(2539) 等 8 处写路径一行守卫都没有**。

* 迁移窗口（秒级、逐行重加密）内并发写会用旧 key 加密 → 迁移后不可解。

* 过渡修复：至少给 `upsertNoteMeta` / 写路径补守卫；理想是异步互斥锁与迁移串行化。

### P0-4 迁移跳过解密失败行 —— ⚠️ 事实属实，风险推理有误

* `_readMetaPayloadsPlain`(:2813) / `_readAllVersionsPlain`(:2844) 确实 `on Object catch` 吞异常继续，跳过的行不重加密，事务照常提交。

* **但推理漏洞**：迁移前 `_readAllNotesStrict`(:2007) 已严格解密，若 oldKey 错误会**先抛异常中止**，根本走不到 meta 跳过。能走到跳过的只有"单行元数据/版本独立损坏"，此时跳过其余继续迁移是**合理降级**，而非评审声称的"oldKey 可能不对 → 半迁移丢数据"。

* 判定：真实缺口，但定级应降为 P1；"失败即中止"可作兜底，非紧急。

### P0-5 远端 manifest 损坏重建丢条目 —— ✅ 真实

* [sync\_engine.dart:684](path) `recoveredManifest=null` 走 [remote==null 分支:1769](path) 以纯本地 items 覆盖 PUT，其他设备独有的条目从索引消失。

* GC 不在此轮触发，但后续轮 `skipGc=false` 会把被丢弃 blob 当孤儿隔离——评审"2 轮后隔离"表述准确（当轮无 GC）。

* 触发需"远端损坏 + re-GET/bak 全不可用"，属损坏恢复路径下的多设备数据丢失。

### P0-6 LWW 依赖对端时钟 —— ⚠️ 真实关切，定级偏高

* `_resolveConflict`(:2272) 仅比 `updatedAt`；`shouldPreserveCopy`(:1971-1972) 两端都非删除才留副本——事实属实。

* **但这是 LWW 的固有架构限制，并非本次引入的编码 bug**；引入 HLC/版本向量是动核心同步架构的大改，应视为产品级改进而非"P0 紧急修复"。"一端删一端活"不留副本也是合理取舍（防止删除复活+无限增殖）。

### P0-7 编辑页退出保存误判成功 —— ✅ 真实，必修（最实际）

* 页面局部 `_isSaving` 与 `NoteEditorState._isSaving` 静态守卫[editor\_state.dart:70](path)是**两套**。后台/定时/超时保存直接置静态守卫、不置页面局部；此时按返回 → `_onPopInvoked` 放行 → `_performAutoSave` 命中静态守卫返回 null → `failed:false` → `_closePage()`。

* 结论：`T1..T2` 的用户内容静默丢失且无提示，是 7 个 P0 里对用户最致命、最实际的。

**P0 小结：4 个必修真缺陷（P0-1/3/5/7），3 个为既有设计或推理/定级问题（P0-2/4/6）。**

***

## 二、P1 逐条核实

### ✅ 真实且值得修（高价值）

| #         | 结论与要点                                                                                                                                                                                    |
| --------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **P1-9**  | [sync\_engine.dart:2821](path)：收敛白名单要求"当前==merged"才 `markSynced`。上传成功但同步期间又被编辑 → base 不刷新 → 下轮把"本设备自己上一版"当冲突，`shouldPreserveCopy` 四项全真 → 复制错误副本。**机制准确，副本增殖 bug，应修。**                    |
| **P1-11** | [http\_util.dart:136](path) body 读取 `await for` 无超时；[sync\_service.dart:547](path) 无总超时，`_syncInProgress` 只在 finally(\~584) 复位 → 响应头先发、body 慢吐可永久卡死同步且不释放互斥锁。**应修。**                     |
| **P1-3**  | [database\_handler.dart:234](path) `SELECT *` 只藏 3 列，`sync_meta.value`（keyring JSON：encryptedDataKey+salt+iterations）原样吐出，与 [inspectMetadata:254](path) 的"不展开 keyring value"口径矛盾。**应修。** |
| **P1-14** | [safe\_server\_backend.dart:428](path) move 非 204/404 即硬 `DELETE manifest`，且 `ciphertext` 未真正写备份。**激进的删除兜底，应修。**                                                                         |
| **P1-15** | `dispose`/`logout`(:374/:419) 等 `waitForSyncCompletion` 最多 10s 后硬关 backend/journal；`updateKeyring`(:301) 确无 `_syncInProgress` 检查。属实，与 P1-11 叠加。                                          |
| **P1-16** | [home.dart:233](path) 每次 `success/error&&lastResult!=null` 都 `refreshNotes()`，[`:311`](path) 无条件 `isLoading=true` → 每次自动同步完成都闪骨架屏+滚动回顶。真实 UX 缺陷。                                         |

### ⚠️ 真实但定级/理由夸大

| #         | 说明                                                                                                                                                                                                           |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **P1-2**  | scenario-d 机理属实（依赖未认证明文 header、指纹匹配即无条件整库迁移、无确认、无 vaultId 校验）。**但"恶意服务端一次密码猜测=全库泄露"不成立**——要让指纹匹配必须先猜中用户密码，猜中即本可解密真 dataKey，无能力跃升。修复价值在防"静默误迁移/改嫁"，非堵新漏洞。                                                     |
| **P1-8**  | 下载构造 [sync\_engine.dart:2563](path) 确实不带 `syncedHash`；但正常轮 `_updateLocalState`(:2858) 会按收敛白名单补齐 base，只有 PUT 中断才留 NULL；且 `shouldPreserveCopy` 的 `hash 不同`(:1973) 使同内容不产生副本。**"必判真冲突丢数据"被夸大，实际≈一轮冗余冲突日志、可自愈。** |
| **P1-10** | bak 循环(:622-643)取首个可解份即 break，无代际比较、未剔除 purgedUuids——机制属实。但该路径只在远端 manifest 已损坏不可读时才走，bak 本就是当时唯一可用全量状态；本地新内容经 LWW 胜出，"覆盖回滚"相对损坏端无从谈起。真正新增风险是"硬删笔记从旧 bak 复活"，属加固项而非紧急。                                       |

### ❌ 接近误报 / 机理存疑

| #        | 说明                                                                                                                                                                                                                |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **P1-5** | 正常升级路径的 `else if (oldVersion<6)`（:927）在 <5 建表（已含 locked）、==5 才 ALTER 补列——**处理正确**，注释也写明防重复。评审"降级再升级即崩"依赖"无 onDowngrade 时 sqflite 静默回写低版本号"，而主流实现默认 `onDowngrade` 是**抛异常拒绝**而非静默降版。机理存疑 + 需 v7→v5→v7 特定降级，实际接近不可达。 |

### ✅ 其余属实（中低危，非误报）

* **P1-1**（unlockFromRemoteManifest 采用远端 dataKey、零重加密）——代码属实；触发面窄（需本地账本损坏/只恢复 notes 表 + 本地另一 dataKey），设计意图是 dataKey 跨设备不变，正常"他端改密码"路径安全。建议加"采用前校验本地库可解性"加固。

* **P1-4**（note\_meta 解密失败降级为空后，被任意写用 NULL 覆盖）——全链路证实（:232 `encodePayload` 空 map 返回 null → payload 写 NULL 销毁原密文）；需"该行先解不开 + 用户再编辑 meta"双重触发，中危。

* **P1-6**（无 WAL/busy\_timeout）——[OpenDatabaseOptions:697](path) 确无 `onConfigure`/`onDowngrade`。并发健壮性缺口，中危（与 P0-3/P1-15 相关）。

* **P1-7**（SafeServer listBlobs 不校验 hash）——确凿：webdav(:519)/local\_fs(:209) 有 `^[a-f0-9]{64}$` 过滤，**独 SafeServer(:483) 无**。但服务端本就是威胁模型内对手，属纵深防御/一致性缺口，非"远端被毁"升级。

* **P1-12**（URL 内嵌凭据明文进日志）——[sync\_config.dart:176](path) `setWebdavUrl` 原样打日志无脱敏，与诊断快照 `_redactUrl` 矛盾；需用户把凭据嵌 URL 才触发，低-中危。

* **P1-13**（允许 http 明文传输）——:382 只判空、无 scheme 校验；但强推 https 会破坏合法局域网 WebDAV，建议按评审"私有网段放行"。

* **P1-17**（编辑器逐键 setState）——:535-549 每次文本变化（含光标/组合）`setState` 重建整页；性能随笔记长度放大，中低危优化项。

* **P1-18**（改密码前置同步异常被吞）——:502 `sync()` 在 :504 的 try 之外，异常向上冒泡无提示。属实。

* **P1-19**（密码框 `enableInteractiveSelection:false`）——:177 属实，禁用粘贴、与 autofill 矛盾，劝退密码管理器用户。低。

* **P1-20**（i18n 不完整）——**完全属实且量化吻合**：实测 en/zh-CN=526，其余 14 语种各 344（差 182≈183），zh-TW=375；hi/bn/it 存在文件但未注册进 `_locales`(:753-769)，为死资源。

* **P1-21**（仅 Android FLAG\_SECURE）——`isFlagSecure` 只 Dart 侧写 pref、仅 Android MainActivity 应用，其它平台（iOS/桌面）为摆设。属实。

* **P1-22**（`_sortAndStoreNotes` 两处裸调用）——home.dart:660/:671 确无 await/catch，排序切换遇系统性解密失败异常直落 Zone。低。

***

## 三、P2 抽查（3 条）

* **P2-30**（Taskfile 引用不存在的 .py）——**确凿属实**。`Taskfile.yml:29` 指向 `scripts/generate_build_info.py`，实测 scripts 目录只有 `generate_build_info.dart`，`.py` 不存在；所有依赖 `gen-build-info` 的任务（get/run/build-\*）必失败。改 `dart run scripts/generate_build_info.dart`。

* **P2-29**（analysis\_options 过松）——大致成立：当前 lint 下 `flutter analyze` 0 issue（原评审已运行验证），确实捕不到本报告任何一条问题；`strict-casts/unawaited_futures` 未提为 error。定性"过松"真实。

* **P2-18**（缓存标题无盐哈希）——[:192](path) 确为无盐 SHA-256 前 8 位，可对常见标题字典反查；但只是哈希非明文、需已获 inspector 权限才能利用，"泄露标题"论述略偏强。低危。

> 注意：除上述抽查外，P2 其余 32 条**未逐条验证**，不在此报告范围内下结论。

***

## 四、综合修复优先级建议

**第一优先（真数据/安全缺陷，改动小）**

1. P0-1 补 `addPurgedUuids`（一行）
2. P0-7 编辑页退出保存区分 `skipped`/`failed`（最实际数据丢失）
3. P1-3 DB Inspector 隐藏 `sync_meta.value`
4. P1-14 SafeServer 非 204/404 不再 DELETE

**第二优先（同步正确性 / 健壮性）**
5\. P1-9 base 刷新与 synced 标记解耦
6\. P1-11 响应体读取超时 + sync 总超时
7\. P0-3 写路径守卫补齐
8\. P0-5 损坏重建保留未知条目
9\. P1-15 取消机制 / 等待超时后不硬关

**第三优先（UX / 工程化）**
10\. P1-16 区分首载与增量刷新
11\. P2-30 修 Taskfile 脚本路径
12\. P1-20 i18n 补齐或裁剪语种

**明确不按"必须修"处理（既有设计 / 夸大）**

* P0-2（维持 M1 隔离删除决策）、P0-6（LWW 架构限制，产品级改进）

* P1-2（安全叙述夸大，价值在防静默误迁移）、P1-5（机理存疑）、P1-8（实际影响小）

***

## 附：评审方法说明（仅陈述本报告与方法无关内容）

* 本报告的代码行号基于核实当日源码快照，行号可能与后续提交漂移。

* 判"真实"的标准是：源码行为与评审描述一致，且后果与所标题级相符；判"夸大"的标准是：行为一致但后果/理由/定级不符，或触发前提被忽略。

