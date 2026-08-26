# 发布前全面 Review 报告（2026-08-26）

> 范围：准备发布到 GitHub Release（非上架）前的代码 / 功能 / UIUX 全面审查。
> 基线：commit `93f72ba`，`flutter analyze` 0 issues，core 测试全过。
> 加密设计确认扎实：Argon2id(32MiB/t3/p2) + per-vault 随机盐 + AES-256-GCM 信封 + AAD
> 域分隔，密码/PIN/生物识别凭证无明文存储，日志无敏感信息泄露。
> 问题集中在**同步并发、删除清理和桌面端编辑器可靠性**三块。

状态标注：✅ 已修复 ｜ ⬜ 未修复

---

## 🔴 发布阻断级（数据丢失）

| # | 状态 | 问题 | 位置 |
|---|------|------|------|
| R1 | ✅ 已修复 | **自动备份一生只执行一次**：备份成功后 `setIsBackupNeeded(false)`，全库无任何代码置回 true，之后所有自动备份（inactive/登出/升级触发）永久跳过，"Last Backup" 时间停在首次 | `lib/utils/scheduled_task.dart:31,188,235,268` |
| R2 | ✅ 已修复 | **桌面端点 X 关窗丢未保存内容**：未实现 `windowManager.setPreventClose/onWindowClose` 拦截；唯一兜底是 `detached` 回调里的异步保存，与进程退出是竞态，基本来不及落库 | `lib/utils/desktop_window_native.dart:37-55`、`lib/main.dart:250-267` |
| R3 | ✅ 已修复 | **"永久删除"不清历史版本**：`hardDelete` / `hardDeleteAllDeleted` 都不调 `deleteVersionsForNote`（只有 GC 路径调），用户以为彻底删了，密文快照+明文 content_hash 实际永久残留磁盘且无限增长 | `packages/core/lib/src/db/database_handler.dart:1408-1449,1487-1528` |
| R4 | ✅ 已修复 | **items.meta 并发整文件覆盖致元数据丢失且不自愈**：meta 无 ETag CAS、LWW 整文件覆盖（注释自认靠下轮合并收敛，但不成立）：A 上传后置 synced=1 → B 用不含 A 条目的快照覆盖远端 → A 的变更因 synced=1 永不再上传。置顶/归档/标签从其他设备永久消失。修复：PUT 带 If-Match CAS + 冲突时重拉合并 | `packages/core/lib/src/sync/sync_engine.dart:266-288`、`note_meta_sync.dart:17-18` |

## 🟠 高优先级（功能错误/安全语义）

- ⬜ **编辑器无周期性自动保存**：只在退出页面/app 前后台切换时保存，崩溃断电即全丢。建议 30s 防抖定时保存 ｜ `lib/views/add_edit_note.dart`
- ⬜ **Markdown 工具栏格式插错字段**：`_activeController` 是 build 时求值的 getter，焦点在标题↔正文切换不触发 rebuild，首次点加粗会插到正文 ｜ `add_edit_note.dart:75-79,235-255`
- ⬜ **版本历史 diff 显示过期结果**：开关只在 `_diffResult == null` 时重算，切换版本后再开 diff 显示旧版本的 diff ｜ `version_history_page.dart:138-146`
- ⬜ **自动保存失败仍无条件关页**：DB 异常只弹 toast 照样 `_closePage()`，改动直接丢 ｜ `add_edit_note.dart:258-282`
- ⬜ **新设备加入完全信任 manifest 明文 header**：恶意 WebDAV 存储端可投喂弱 KDF + 自知 dataKey 的 keyring；且 `KdfParams.fromJson` 无范围校验（iterations 可为 1 或 10⁹ DoS）｜ `keyring.dart:554-595`、`sync_models.dart:343-351`
- ⬜ **"删除 vs 编辑"冲突纯时钟 LWW 不留副本**：时钟偏慢设备的离线编辑会被旧删除覆盖，回收站 30 天后连同版本历史硬删 ｜ `sync_engine.dart:1899-1904,1621-1623`
- ⬜ **无操作自动锁定不识别键盘输入**：`local_session_timeout` 只挂 `onPointerDown`，桌面端连续打字超时被强制登出 ｜ `lib/main.dart:361-367`
- ⬜ **关闭空闲锁定后失焦锁定连带失效**：任何超时事件先 `stopListening` 再查开关，监听死了不会重启 ｜ `main.dart:372,401-409`
- ⬜ **Windows 无单实例保护**：多开实例并发写同一 SQLite 库和固定名备份文件 ｜ `windows/runner/main.cpp`
- ⬜ **WebDAV 软删除 COPY 失败退化为硬删除**：30 天恢复窗口在最常用后端失效 ｜ `webdav_backend.dart:562-589`

## 🟡 中优先级（择要）

- ⬜ 单行解密失败导致整个库不可读（notes 表无降级容错，meta 表有）｜ `database_handler.dart:505-516`
- ⬜ update 系列 rows==0 时仍写缓存产生幻影笔记 ｜ `database_handler.dart:1118-1124`
- ⬜ 导入备份批内 uuid 重复导致整体回滚 ｜ `database_handler.dart:846-867`
- ⬜ `markSynced` 系列 IN 子句超 SQLite 变量上限 ｜ `database_handler.dart:1973-2009`
- ⬜ dev 模式 release 可开，`0.0.0.0` 日志服务器提供 `/api/download/db` 整库下载，注释与实际不符 ｜ `about_page.dart:200`、`log_webserver_io.dart:156,575`
- ⬜ 锁定笔记前未保存改动静默丢弃；新建笔记未落库前"更多"菜单不存在 ｜ `add_edit_note.dart:568-581,217`
- ⬜ 回收站恢复成功无提示、"清空成功"用 error 样式；清空文案暴露 tombstone 技术细节 ｜ `deleted_notes.dart:124-170`
- ⬜ 版本历史/回收站页异常时永久转圈；宽屏无限宽约束无 Scrollbar
- ⬜ 桌面端快捷键几乎为零（仅 Ctrl+Z/Y），缺 Ctrl+S/F/Esc

## ⚪ 低优先级 / 打磨

- ⬜ 品牌不一致：原生窗口标题/exe 属性是 `CarroNote`，Dart 侧是 `SafeNotes`（二选一统一）
- ⬜ `"Yкраїнська"` 首字符是拉丁 Y 不是西里尔 У ｜ `preference_and_config.dart:768`
- ⬜ 打包了 bn/hi/it 等 13 种不可选的翻译 JSON（约 127KB 冗余）
- ⬜ Android SAF 目录 URI 拼接必然无效（有兜底）｜ `backup_setting.dart:329-341`
- ⬜ 生物识别取消弹窗也计入尝试次数消耗 PIN 挑战额度 ｜ `login.dart:847`
- ⬜ 清空缓存主线程同步递归删临时目录卡 UI ｜ `cache_manager.dart:19-24`
- ⬜ 无显式 Semantics/tooltip 无障碍支持；摘要 `substring(0,200)` 可切断 emoji 代理对
- ⬜ 死代码若干（home.dart:530-544、note_widget.dart:146-173 等）

## 建议

🔴 4 项为确定性数据丢失路径，已全部修复（见 CHANGES-20260826.md）。
🟠 中 KDF 参数校验是一行代码的事值得顺手做；"新设备信任锚"和"删除冲突不留副本"
属于产品决策，至少写进 README 安全模型说明。其余可随首个 patch 迭代。

---

## 修复落地记录（2026-08-26 21:10）

| # | 修复方式 | 回归测试 |
|---|---------|---------|
| R1 | `backup()` 移除 `isBackupNeeded` 依赖，只受 `isBackupOn` 约束；三处成功后置 false 调用删除 | `scheduled_task_test.dart`：标记 false 时仍备份 |
| R2 | 新增 `desktop_window_callback.dart` + `setPreventClose` + `onWindowClose` 拦截：先存草稿（`handleUngracefulNoteExit`）再走 `_shutdown()`，10s 兜底超时 | 手动验证路径；widget 层无 window_manager 测试桩 |
| R3 | `hardDelete`/`hardDeleteByUuid`/`hardDeleteAllDeleted` 删除事务内清理版本表（新增 `_deleteVersionsForNoteInTxn`；清空回收站用子查询防 IN 超限） | `note_version_test.dart` 全过（含 hardDeleteByUuid 级联用例） |
| R4 | backend 接口升级：`getMetaObject` 返回 ETag、`putMetaObject` 支持 If-Match/If-None-Match CAS（三后端落实）；引擎冲突重拉合并重试 ≤3 轮 | `note_meta_engine_test.dart` 新增 2 用例：冲突不丢他端条目、超限放弃不误标 synced |

验证结果：`flutter analyze` / core `dart analyze` 0 issues；
根目录 `dart test` 相关 6 个测试文件 90 项全过；`flutter test scheduled_task_test` 5 项全过。
改动明细见 `docs/CHANGES-20260826.md` 顶部。
