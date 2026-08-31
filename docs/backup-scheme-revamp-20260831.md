# 备份方案重构设计（v2，简洁可靠）

- 设计时间：2026-08-31 (GMT+8)
- 状态：**已实现并验证（批A + 批B）**——2026-08-31 落地，详见 `docs/CHANGES-20260831.md`
- 关联：替代既有"事件触发型自动备份"；为 `docs/review-open-issues-20260831.md` 的 H-4 简化、vault 迁移安全兜底提供前提。

***

## 一、改动理由（现状问题）

1. **"自动备份"是事件触发、且默认关闭**：`isBackupOn` 默认 `false`（`preference_and_config.dart` 里 `?? false`，注释掉的 `//true` 说明曾想默认开而未启）。开启时也只在 **切后台 / 登出 / App 升级** 三个事件点触发（`main.dart:198` / `session.dart:56` / `main.dart:530`）。**没有"每日"或任何定时器**（全仓无 `Duration(days)` / 相应 `Timer.periodic`）。
2. **触发点语义混乱**：后台/登出/升级这些点"以为 App 会活动才有数据变化"，实际与数据是否变化无关；用户印象里"设置了自动备份就安全"，却既非每日也非默认开。
3. **缺少 vault 迁移前的备份兜底**：**改密码前已有强制备份**（`change_passphrase.dart:475`），但 **scenario-d 自动整库迁移（`_executeMigrationVault`→`migrateToRemoteVault`）前无任何备份**。该迁移会全量重加密 + 换账本，是不可逆改写，一旦判断失误/中途失败，本地数据可能损坏且无可恢复备份。
4. **无去重**：任何一次触发都全量导出写新文件，同一数据重复产生冗余备份文件，无意义占用磁盘。

> 结论：自动备份"看似有、实则弱"；强制备份覆盖不全（缺迁移）。

***

## 二、目标

建立\*\*"变化才写 + 强制保底"\*\*两个简单可靠机制，替代"凭事件触发"：

* **自动备份**：用户登录进去后自动备份一次（受开关 + 去重控制）；数据无变化不重复写盘。

* **强制备份**：不查开关、不重复去重，关键操作前必定落一份新鲜备份：改密码前 / **数据 vault 迁移前** / 手动"立即备份"。

* **文件名按备份场景区分**，便于识别与排查。

***

## 三、新方案

### 3.1 统一入口（两个）

| 入口                                   | 查 `isBackupOn` | 去重         | 用途                   |
| ------------------------------------ | -------------- | ---------- | -------------------- |
| `ScheduledTask.backup()`             | ✅              | ✅（指纹相同则跳过） | **登录后自动备份一次**        |
| `ScheduledTask.forceBackup({scene})` | ❌ 绕过           | ❌ 总是写      | 改密前 / vault 迁移前 / 手动 |

### 3.2 触发点（重构后）

**自动**（`backup()`，受开关 + 去重）：

* 登录成功 `_onLoginSuccess` 后 `unawaited(ScheduledTask.backup())`

**强制**（`forceBackup({scene})`，always）：

* a. 改密码前（保留，改为传 `scene: changepw`）

* b. **数据 vault 迁移前（新增）**：scenario-d `_executeMigrationVault` / `migrateToRemoteVault` 之前

* c. 手动"立即备份"（保留，传 `scene: manual`）

**移除**（废弃事件触发）：

* 切后台（`main.dart:198` inactiveCallBack）

* 登出（`session.dart:56`）

* App 升级后（`main.dart:530`）

> 设计判断：用户不打开 App 时没有本地数据变化，无需后台/登出/升级备份；真正需要备份的是"会话进入"（登录）与"高风险改写前"（改密/迁移）。这比事件触发更贴合数据语义。

### 3.3 去重机制

* **指纹** = `sha256( UTF8( jsonEncode(明文 records) ) )`——只对笔记数据（`exportAll` 的解密记录数组）计算，不含备份头/导出时间戳；因而同一数据集指纹稳定（也不受 AES-GCM 每次随机 nonce 影响，可对明文指纹统一去重，无论明文/加密导出）。

* `backup()` 写盘前算指纹，与 `PreferencesStorage.lastBackupFingerprint` 比对：

  * **相同 → 不写文件、直接返回**；

  * **不同 → 写文件 + 更新指纹**。

* **强制路径不去重**：改密/迁移/手动必须落一份新鲜备份（改密后会话密码已换，新备份用新密码可解；去重会因明文指纹相同而错误跳过）。

* 恢复/导入/改密后，指纹随下一次自动备份自然重建，无需额外维护。

### 3.4 文件名命名规范（按场景区分）

统一格式：`carronote_<scene>_<yyyyMMdd_HHMMSS>.snbak`

| 场景        | scene 短词   | 示例                                         | 触发                             |
| --------- | ---------- | ------------------------------------------ | ------------------------------ |
| 登录后自动     | `auto`     | `carronote_auto_20260831_105500.snbak`     | `backup()`                     |
| 改密码前      | `changepw` | `carronote_changepw_20260831_105500.snbak` | `forceBackup(scene: changepw)` |
| vault 迁移前 | `migrate`  | `carronote_migrate_20260831_105500.snbak`  | `forceBackup(scene: migrate)`  |
| 手动立即备份    | `manual`   | `carronote_manual_20260831_105500.snbak`   | `forceBackup(scene: manual)`   |

> 统一带时间戳避免同目录覆盖；前缀从旧的 `secure_notes_backup` 统一到 `carronote_`，并去掉旧的 `redundancyCounter` 轮转命名（由场景 + 时间戳 + 去重取代）。文件管理器/诊断日志里可一眼识别备份来源。

### 3.5 边界与取舍

* 备份只含**笔记**（沿用现有 `exportAll`），不含 note\_meta（标签/置顶/锁定）——这是既有行为，本次不改；若要纳入元数据，需另议。

* 强制路径不做去重（理由见 3.3），保证高风险操作前必有新备份。

* `kIsWeb` 仍跳过备份（不改）。

***

## 四、影响面

* `lib/utils/scheduled_task.dart`：`backup()` 改去重 + `forceBackup({scene})` 接文件名

* `lib/models/file_handler.dart`：提供明文 records 指纹计算

* `lib/data/preference_and_config.dart`：`lastBackupFingerprint` 存取；`isBackupOn` 默认 `true`；统一文件名生成（scene + 时间戳）

* `lib/main.dart` / `lib/models/session.dart`：移除 3 处事件触发备份

* `lib/views/authentication/login.dart`：登录成功补 `backup()`

* vault 迁移前备份：`lib/sync/sync_service.dart` 注入 `preMigrationHook` → `forceBackup(scene: migrate)`（core 的 `sync_engine.dart` 不依赖 lib，仅新增钩子回调）

* 测试：`scheduled_task` / 文件名 / 去重指纹 / 迁移前触发

***

## 五、实施计划

**批A（自动备份重做 + 去重）**

1. `isBackupOn` 默认改 `true`；`preference_and_config` 加 `lastBackupFingerprint`
2. `file_handler` 暴露 records 指纹；`scheduled_task.backup()` 去重
3. `login.dart` 登录成功补 `backup()`
4. 移除 `main.dart` / `session.dart` 3 处事件触发
5. 统一文件名（scene + 时间戳）

**批B（vault 迁移前强制备份）**
6\. `sync_engine` 增 `preMigrationHook` 回调，`sync_service` 注入 `forceBackup(scene: migrate)`
7\. 改密前 / 手动改传 scene
8\. 回归测试

***

## 六、验证（实现后执行）

* `dart format` / `flutter analyze` 无 issue

* `dart test packages/core/test` + `flutter test` 通过

* 新增：去重（同指纹跳过 / 变更重写）、文件名 scene、迁移前触发
