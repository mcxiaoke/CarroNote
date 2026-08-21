# SafeNotes 全面代码审查报告（2026-08-21）

审查范围：`lib/`（约 2.25 万行，91 文件）+ `packages/core/`（约 1.39 万行，39 文件）+ 测试（约 2.86 万行，77 文件）。所有发现均经子代理逐文件精读 + 交叉验证。

> 已修复和决定不修复的问题已从本报告中移除，详见 git 提交记录和 `docs/CHANGES-20260821.md`。

---

## 总体评价

- **packages/core 核心层质量持续提升**：B-H1（HTTP 重定向数据丢失）——旧报告最重要的搁置项——已通过 `http_util.dart` 统一重定向策略彻底修复。加密协议（双层密钥、GCM+AAD、常数时间比较）、同步引擎（三方合并、两阶段 GC、原子化迁移）设计成熟。
- **lib/ 应用层显著改善**：旧报告高 2/3/4/5/6/7 全部修复，中 9–18 全部修复。i18n 双轨问题已全面收敛，所有 UI 文案均走 `.tr()`。备份已从明文改为真加密。
- **搁置项**：高 8（明文口令驻留内存）、H-07（本地暴力破解防护——本地优先架构下 KDF 成本是唯一有效防线，冷却机制可被设备持有者 trivially 绕过）、B-M3（401 与 5xx 混为一谈）仍维持原状。

---

## 一、旧报告问题追踪

### 仍未修复

| 编号 | 旧问题 | 当前状态 |
|------|--------|----------|
| 高8 | 明文口令驻留内存 | **搁置** — `PhraseHandler._passphrase` 仍为静态 String，架构性改造暂搁置 |
| B-M3 | 401 与 5xx 混为一谈 | **仍存在** — 401 仍抛 `BackendUnavailableException`，未新增 `AuthenticationException` |
| B-M5 | 非 manifest 响应无大小上限 | **部分改善** — manifest/journal 已加 `checkRemoteReadSize`；`getBlob` 仍未加 |
| 低 | device_id 未知平台用时间戳 | **仍存在** — `device_id.dart:138` |
| 低 | note_widget.dart 死参数+死代码 | **仍存在** — `sessionStateStream` 死参数、`computeMaxLine` 注释死代码 |

---

## 二、新发现 — 中优先级

### M-03 readAllNotesIncludingDeleted 缓存重建竞态

`packages/core/lib/src/db/database_handler.dart:982-992`

在 `await db.query` 和 `await Future.wait` 的 yield 窗口内，若 `storeNote`/`updateNote` 等写操作的事件被调度执行，它们调用 `_upsertCacheEntry` 时看到 `_notesCache == null` 直接 return。随后 `_notesCache = notes` 覆盖写入不含这些新变更的快照。Dart 单线程事件循环下这是真实竞态。

→ 引入 `_cacheRebuilding` 标志或 `Completer` 互斥。

### M-08 logout 与在途保存的竞态

`lib/main.dart:414-427` + `session.dart:51-71` + `editor_state.dart:63-99`

登出流程中 `Session.logout()` 执行 `ScheduledTask.backup()`（await，让出事件循环）时，原始 `addOrUpdateNote()` 可能恢复执行。若 `backup()` 先完成，`clearDataKey()` 被调用，`storeNote()` 在无 dataKey 状态下加密失败。概率低但理论存在数据丢失风险。

→ 在 `clearDataKey()` 之前等待"编辑器空闲"信号。

### M-13 死代码：Style.buttonTextStyle / 公开 State 类

- `lib/utils/styles.dart:20-24`：`Style.buttonTextStyle` 全项目无调用。
- `lib/widgets/drawer.dart:62`：`HomeDrawerState` 公开但无外部引用。
- `lib/dialogs/export_backup_dialog.dart:78`：`ExportBackupDialogState` 同上。
- `lib/widgets/search_widget.dart:35`：`SearchWidgetState` 同上。

→ 删除死代码；公开 State 类改为 private（`_` 前缀）。

---

## 三、新发现 — 低优先级

### 安全与正确性

- **L-04** `database_handler.dart:2042-2047`：`exportAll` 不导出墓碑，重新导入后删除状态无法恢复；`.toString()` 冗余。→ 如需保留墓碑改用 `readAllNotesIncludingDeleted()`。
- **L-05** `database_handler.dart:157-173`：`cachedNoteSummaries` 返回解密标题明文，供 WebServer 使用。→ 确认 WebServer 有鉴权或改为返回标题长度。
- **L-08** `sync_engine.dart:1907-1912`：LWW 冲突解决依赖设备本地时间，时钟不准确时可能选错胜者。→ 同步诊断面板增加时钟偏差检测。
- **L-09** `journal.dart:975-984`：`fetchRemoteEntries` 对远端对象名无格式校验。→ 用正则过滤。
- **L-10** `journal.dart:919,929`：`syncToRemote` 读取本地文件无大小限制。→ 读取前检查 `file.length()`。
- **L-12** `url_launcher.dart:16-26`：无 URI scheme 校验。→ 显式校验 scheme 白名单。
- **L-13** `cache_manager.dart:21-22`：`dir.deleteSync(recursive: true)` 后立即 `dir.create()`，非原子操作且可能影响其他组件。→ 遍历目录内文件逐个删除。

### 代码质量与可维护性

- **L-15** `device_id.dart:138`：未知平台用时间戳当 deviceId，每次启动都变。→ 生成随机 UUID 并持久化。
- **L-16** `app_logger.dart:190-191`：`List.removeAt(0)` 触发 O(n) 元素移动。→ 改用 `Queue` 或环形缓冲。
- **L-19** `editor_state.dart:20-23`：`original`/`title`/`description` 为静态字段，无法支持多窗口/分屏编辑。→ 长期迁移为 Provider 实例。
- **L-20** `note_widget.dart`：`sessionStateStream` 死参数（声明 required 但从未使用）；`computeMaxLine` 28 行注释死代码。→ 删除。
- **L-25** `note_widget.dart:73`：`autofocus: true` 在编辑已有笔记时也自动聚焦标题框。→ 作为参数传入。
- **L-27** `sync_diagnostics_page.dart`：`_buildKVRow` 三处近似重复（:229/:505/:670）。→ 提取共享 Widget。
- **L-28** `login.dart:865`：魔法数字 `5` 控制生物识别挑战间隔。→ 提取为命名常量。
- **L-29** `login.dart:220` / `set_passphrase.dart:191` / `change_passphrase.dart:106`：`scrollToBottomIfOnScreenKeyboard` 三处重复。→ 提取为 mixin。
- **L-30** `login.dart:871-878`：`isPassphraseRememberChallenge()` 为顶层函数，无命名空间。→ 移入 `PreferencesStorage`。
- **L-31** `prefs_store_override.dart:69-74`：并发写入可能丢失更新（仅测试用）。→ 加 Future 互斥锁。
- **L-32** `export_backup_dialog.dart:212`：`minHeight: 122` 魔法数字。→ 提取为常量。
- **L-33** `preference_and_config.dart:688-703`：`_githubUrl`/`_faqsUrl`/`_playStorUrl` 均指向同一 GitHub 地址，可能是占位符。→ 发布前更新为真实链接。

### 可访问性

- **L-34** `search_widget.dart:140-147`：清除按钮缺少 `tooltip` 或 `Semantics`。→ 加 `tooltip`。
- **L-35** `nav_list.dart:231-271`：标签项缺少 `Semantics` 选中状态。→ 用 `Semantics(selected: active)` 包裹。
- **L-36** `states.dart:41`：空状态图标缺少 `semanticLabel`。→ 加 `semanticLabel: text`。

### i18n 残留

- **L-37** `footer.dart:38`：`'DEBUG'` 硬编码英文。→ 低优先级。
- **L-38** `log_webserver.dart:582-768`：内嵌 HTML 页面全中文，不支持多语言。→ 调试工具可接受。
- **L-39** `log_webserver.dart`：日志消息中英混用。→ 统一语言。

---

## 四、架构层面建议（优先级排序）

1. **异常分类体系完善**：401 与 5xx 分离（B-M3），`getBlob` 响应加大小上限（B-M5）。异常分类准确是同步引擎可靠重试的前提。

2. **缓存一致性修复**：缓存重建竞态（M-03）+ `getPendingReuploadUuids` 静默失败链路，共同构成缓存层的数据一致性风险。

3. **logout 与在途保存竞态（M-08）**：登出时 `clearDataKey()` 前需等待编辑器空闲，否则在途保存会因无 dataKey 加密失败。

4. **死代码清理（M-13）**：`note_widget.dart` 死参数/死代码、`Style.buttonTextStyle` 死代码、公开 State 类改 private。降低维护成本。

5. **长期改造（维持搁置）**：明文口令驻留内存（高8）、编辑器静态态迁移为 Provider（L-19）。

---

## 五、测试覆盖评估

| 层级 | 文件数 | 覆盖评估 |
|------|--------|----------|
| core 单元测试 | 19 | 覆盖全面：crypto/sync_engine/journal/keyring/database/各后端均有测试，含 chaos 多客户端、P0P1 自愈、硬删除等复杂场景 |
| app 单元测试 | 19 | 覆盖关键路径：auth_flow/export_backup/home_drawer/note_actions/pin_keyboard/tag_editor/theme 等 |
| 集成测试 | 2 | `app_test.dart` + `first_run_test.dart`，覆盖首次启动和核心流程 |
| 测试支持 | 3 | `harness.dart`/`crypto.dart`/`asset_loader.dart` 提供测试基础设施 |

**测试亮点**：core 包测试质量极高，`chaos_multi_client_test` 和 `p0p1_self_heal_test` 体现了对分布式一致性的深入验证。`backend_redirect_test` 验证了 B-H1 修复。

**测试缺口**：
- 视图层仅覆盖部分页面，`sync_diagnostics_page` 等复杂页面无 widget 测试
- 集成测试仅 2 个，核心同步流程的端到端覆盖偏薄

---

## 六、依赖健康度

`flutter pub outdated` 显示 29 个包有更新版本，均为 minor/patch 升级，无 breaking change：

| 依赖 | 当前 | 最新 | 备注 |
|------|------|------|------|
| device_info_plus | 12.4.0 | 13.2.0 | major 升级，需验证 API 变更 |
| file_picker | 11.0.3 | 12.0.0 | major 升级，注释说明"12.x 仍为 beta" |
| flutter_secure_storage | 10.3.1 | 11.0.0 | major 升级 |
| permission_handler | 12.0.3 | 13.0.1 | major 升级 |
| window_manager | 0.5.1 | 0.5.2 | patch 升级，低风险 |

无已知安全漏洞的依赖。建议在下一个开发周期评估 major 升级。

---

## 七、发现汇总

| 严重程度 | 数量 | 编号 |
|----------|------|------|
| 中（仍未修复） | 3 | M-03、M-08、M-13 |
| 低（仍未修复） | 24 | L-04/05/08/09/10/12/13/15/16/19/20/25/27~39 |
| 旧报告仍未修复 | 5 | 高8、B-M3、B-M5、低优先级 2 项 |

---

## 八、设计亮点（正面确认）

以下设计经审查确认正确，值得保留：

1. **两层密钥架构**（MK → dataKey）：改密码只重加密 32 字节 dataKey（O(1)），dataKey 永不变化。
2. **AAD 域分隔**：blob/dataKey-wrap/note-meta/backup 四类信封 AAD 完全隔离，密文不可互换。
3. **常数时间比较** `SyncCrypto.bytesEqual`：XOR 累积实现正确。
4. **Nonce 随机生成**：每次加密调用 `_secureRandom` 生成全新 nonce，不复用。
5. **HTTP 重定向策略**（B-H1 修复）：`http_util.dart` 统一 `followRedirects=false` + 显式 3xx 决策，杜绝方法降级与凭据泄露。
6. **硬删除 + purged 列表同事务**：防止崩溃窗口导致墓碑从远端复活。
7. **迁移中守卫** `_isMigrating`：阻止 UI 在 dataKey 迁移期间并发读取。
8. **日志隐私红线**：`_hashBrief` 仅输出 hash 前 8 字符，`_inspectorHiddenColumns` 隐藏密文列。
9. **P1-15 卡片重构**：四个卡片外壳退化为薄透传层，统一由 `NoteCardBody` 渲染，消除重复代码。
10. **PIN 键盘**设计完善：shuffle 防偷窥、自适应尺寸、桌面硬件键盘支持。
11. **测试体系**：core 包 19 个测试文件含 chaos 多客户端、自愈、重定向等复杂场景验证。
