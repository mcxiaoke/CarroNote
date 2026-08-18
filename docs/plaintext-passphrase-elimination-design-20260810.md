# 去密码明文方案设计（内存与生物认证不存明文密码）

*日期：2026-08-10 · 状态：设计评审稿 · 关联：`backup-encryption-design-20260810.md` / `crypto-overview.md`*

> **落地状态（2026-08-16 代码复核）**：本稿为**设计评审稿，整份提案未实施**。
> 现状代码仍为「内存驻留明文密码」，本稿 §4–§9 全部为「提案」：
> - `PhraseHandler` 仍持 `_passphrase` 明文（`preference_and_config.dart`），`initPass` / `getPass` 原样保留；
> - `Session.login(String passphrase)` / `Session.onPasswordSet` 仍接收并注入明文（`session.dart`）；
> - `SyncService` 三处仍注入 `passphraseProvider: () => PhraseHandler.getPass`，`SyncEngine` 场景 c/d 判别仍消费（`sync_service.dart` / `sync_engine.dart`）；
> - 自动备份 / 加密导入试解仍用 `PhraseHandler.getPass`（`scheduled_task.dart` / `file_handler.dart`）；
> - 备份文件仍为 v1 单层派生（`kBackupFormatVersion = 1`），无 BackupSeed / v2 / `encodeEncryptedFromSeed`。
> 因此，§2 的现状盘点**属实**（明文确仍在内存），§4–§9 描述的是目标态，请勿据此判断线上行为。
>
> **与本稿提案采用不同机制的现状改动（2026-08-11 起）**：
> - **KDF 默认迁移 Argon2id**：新 vault / 新备份 `m=32MiB, t=3, p=2`，存量 PBKDF2 按文件头 `algorithm` 字段回退。经 `deriveKeyFromKdf` 派发 + `KdfParams` 落地。→ **本稿 §4.4「两层复用 `kPbkdf2Iterations=200000` / `deriveMasterKey`」已过时**，落地须对齐 Argon2id（已修订，见 §4.4）。
> - **生物识别凭据刷新**：已实现于 `Session.login(passphrase)` + `Session.onPasswordSet`，均读取 `PhraseHandler.getPass` 重新包裹。→ 本稿 §5.4 `setAuthKey({required String password})` 显式传参改签名**未采用**（`setAuthKey()` 仍从 `PhraseHandler.getPass` 取明文）。
>
> **设计评审修订（2026-08-18，依据代码复核）**：本稿 §5.2/§5.4 的「`Session.login` 去明文参数 + `setAuthKey` 显式传参刷新凭据」**进一步收紧为「生物认证凭据不随密码自动刷新，密码变更后一律失效并自动关闭」**（见 §5.6 新策略）：
> - `Session.login` **彻底无参**（不再接收密码，也不刷新 biometric）——原 §5.2 第 3 点「删除明文参数」保留，原保留参数仅用于刷新的备选**放弃**；
> - 凭据写入只发生在「用户在设置页主动重新启用并输入密码」时；
> - 任何密码变更（本地改密 / 他端改密）后既有凭据一律失效：本地改密在 `onPasswordSet` 内自动 `BiometricAuth.disable()`；他端改密在指纹登录失败或远端重登成功路径自动关闭（见 §5.6 关闭时机）。
> - 同步场景 c/d 改造补充实施注意：`sync_engine.dart` 无密码提供者分支须显式携带 `requiresRelogin: true`（现状该分支未带，见 §5.7）。
> - **场景 d 判别前移到登录流程（2026-08-18 复核发现原推演缺陷）**：初稿「重登后走 `_tryVerifyPassphraseViaRemote`」不成立——场景 d 密码相同，重登时本地 `unlockLocal` 先成功、走不到远端路径，会陷入「登录成功 → 同步 requiresRelogin → 强制弹窗踢出」无限循环。修正：`_login` 本地解锁成功后做远端 vault 一致性检查，场景 d 在密码调用栈内弹确认并迁移，场景 c 提示仅本地使用（见 §5.7）。
> - 备份 v2 头 `seedKdf.*` 由「可选增强」升级为**必写字段**（见 §4.4 / §6.1），避免未来 KDF 参数升级的双重兼容。
> - 改动清单补 `bin/cli_context.dart`（CLI 的 `passphraseProvider` 注入，见 §9）。
>
> 全文行内引用统一为「符号 + 文件」形式（不依赖行号），避免随代码演进失准。

## 1. 背景与目标

当前 `PhraseHandler._passphrase`（`lib/data/preference_and_config.dart` `PhraseHandler`）在会话期内**长期驻留明文密码**，且历史版本生物认证曾把明文密码直接写入 secure storage。本方案目标是：

1. **内存不驻留明文密码**：密码只用于「一次性派生密钥」，派生完成后立即丢弃。
2. **生物认证不存明文密码**：secure storage 只存密码的包裹态（现状 v1 已达成），且**指纹登录路径不再把解包出的明文注入会话内存**。
3. 不降低现有安全性、不破坏现有功能（同步/备份/导入/改密码/生物认证全部保持可用）。

## 2. 现状盘点：明文密码的全部使用点

> 本节经 2026-08-16 代码复核**全部属实**：明文密码当前仍驻留内存（与 §0 落地状态一致）。

### 2.1 内存驻留（核心问题）

| # | 位置 | 说明 |
|---|---|---|
| M1 | `PhraseHandler._passphrase`（`preference_and_config.dart` `PhraseHandler`） | 静态字段，会话期持有明文 |
| M2 | 写入：`Session.login(passphrase)`（`session.dart`） | 密码登录成功后注入 |
| M3 | 写入：`Session.onPasswordSet(passphrase)`（`session.dart`） | 设置/改密码成功后注入 |
| M4 | 清除：`Session.logout` → `PhraseHandler.destroy`（`session.dart`） | 仅登出/空闲锁定时清除 |
| M5 | 消费：`SyncService` 三处注入 `passphraseProvider: () => PhraseHandler.getPass`（`sync_service.dart`） | 同步引擎取明文重派生 |
| M6 | 消费：`SyncEngine` 场景 c/d 判别（`sync_engine.dart` `passphraseProvider?.call()`） | 后台取内存明文重派生判别 |
| M7 | 消费：`BiometricAuth.setAuthKey()`（`biometric_auth.dart`） | 取明文包裹写入 secure storage |
| M8 | 消费：自动备份（`scheduled_task.dart` `unitBackupAttempt` 三处 `encryptedOutputBackupContent(password: ...)`） | 取明文派生 B-KEY |
| M9 | 消费：加密导入自动试解（`file_handler.dart` `_resolveEncryptedRecords`） | 取明文试解加密备份 |

### 2.2 生物认证持久化（部分达成）

| # | 位置 | 现状 |
|---|---|---|
| B1 | `_secureBiometricAuthKey` | `v1:<base64(nonce‖ct‖tag)>`，密码已包裹（非裸明文）✅ |
| B2 | `_secureBiometricWrapKey` | 包裹密钥，**与密文同库** ⚠️ |
| B3 | `authKey` getter（`biometric_auth.dart`） | **解包返回明文密码**，指纹登录路径 `login.dart` `_login(await BiometricAuth.authKey)` 用它解锁 keyring ❌ |
| B4 | 旧版无前缀兼容（`biometric_auth.dart` `authKey` getter） | 无前缀值直接当明文返回——历史明文记录未升级则一直躺 secure storage ⚠️ |

### 2.3 其它临时明文（可接受，本文档不动）

- 登录/设置/改密码页的 `TextEditingController`：用户输入阶段必然在内存，一次性，不驻留。
- `ImportPassPhraseHandler`（`preference_and_config.dart`）：导入弹框输入的口令，导入路径已有 `destroyImportCredentials`（`file_handler.dart`）清理。
- 改密码流程 `change_passphrase.dart` `_finalSubmitChange` 内的 `oldPassword`/`newPassword`：表单栈内局部变量，用后即弃。

### 2.4 持久化侧（无明文，本方案不改）

- 数据库：dataKey 仅内存（`database_handler.dart` `NotesDatabase._dataKey`，登出时 `clearDataKey` 清除），keyring 账本仅存包裹态 `encryptedDataKey`。
- 登录不再写 passPhraseHash（简化方案已删）。

## 3. 设计原则与关键约束

### 3.1 原则

1. **密码零驻留**：密码仅存在于「输入框 → 派生调用」的短暂调用栈内，派生后不可再经任何静态字段访问。
2. **密钥分类持有**：内存中按职责持有派生密钥，互不复用：
   - `MK`（Master Key）→ 由 `Keyring` 持有（现状已如此）
   - `dataKey` → 由 `NotesDatabase` 持有（现状已如此）
   - `BackupSeed`（备份专用）→ 由 `PhraseHandler` 改造后持有（本次新增）
3. **备份密钥独立于 vault 密钥链**：不受 MK/dataKey/vault salt 的任何变化影响。
4. **备份「密码即凭证」**：任何备份文件都能凭「密码 + 文件头参数」跨设备/离线恢复，不依赖任何当前会话状态。

### 3.2 关键约束（经推演确认）

**C1（dataKey 会变，不能作为生物认证凭据）**：dataKey 不是永久不变的。同步的 scenario c/d 迁移中：
- `migrateToRemote`（`keyring.dart`，同 keyring 换远端 dataKey）→ dataKey 变
- `migrateToRemoteVault`（`keyring.dart`，场景 d 整体切远端 vault）→ dataKey 变

因此**生物认证不能存 dataKey**（指纹登录可能拿到已失效的 key）。

**C2（MK 会变，不能作为生物认证凭据）**：MK 随「改密码」变化，也随场景 d 迁移（salt 切换）变化。同样不可作生物认证凭据。

**C3（密码是最稳定的凭据）**：密码跨所有同步迁移稳定（scenario c/d 中密码不变）；改密码是用户显式操作。因此生物认证**仍须存「密码的等价物」**（包裹态密码），这正是现状 v1 已采用的方式。**2026-08-18 修订**：密码变更（本地/他端）后凭据即失效，**不自动刷新、自动关闭**，由用户主动重新启用（重输密码）——见 §5.6。

**C4（备份密钥不能依赖「当前密钥状态」）**：任何把「当前 MK 或 dataKey 或 vault salt」引入备份密钥派生链的做法，都会导致「改密码后旧备份无法用新密码恢复」。推演反例：
- 用 MK 直接加密备份 → 改密码 MK 变 → 旧备份需旧密码 ❌
- 备份头存当前 MK 包裹的 encryptedDataKey → 改密码后新 MK 解不开旧头 ❌

**唯一自洽解**：备份密钥派生链的输入**只含「密码」与「文件头参数」**。现状 `B-KEY = KDF(密码, 文件头参数)`（Argon2id 新 / PBKDF2 回退）已满足 C4。

**C5（改密码后旧备份需旧密码是固有现实）**：密码管理器的主密码即数据根密钥。改密码后，用旧密钥加密的历史备份自然需要旧密码。**现状方案同样如此**（B-KEY 依赖密码原文），不是本方案新引入的缺陷，接受并在 UI 提示中说明。

## 4. 核心设计：BackupSeed 独立派生链

### 4.1 动机

自动备份（M8）是唯一「后台无感运行且需要密码源」的消费点，不能弹窗打断。内存去掉明文后，需要一个「密码派生的、独立于 vault 密钥链的」备份种子。

### 4.2 派生链定义

```
┌─ 会话期派生一次（登录/设置/改密码时），内存驻留，用后即弃密码：
│   BackupSeed = KDF(password, kBackupSeedSalt)
│               // kBackupSeedSalt = 固定 16B 常量（代码硬编码，见 §4.3）
│               // KDF = 当前新备份默认（Argon2id），见 §4.4
│
├─ 每份备份派生一次：
│   B-KEY_n    = deriveBackupKey(base64(BackupSeed), 文件头.kdf)   // 复用现有入口
│
└─ 恢复（任意设备，仅凭密码 + 文件头）：
    BackupSeed = KDF(password, kBackupSeedSalt)          // 固定常量，代码内置
    B-KEY_n    = deriveBackupKey(base64(BackupSeed), 文件头.kdf)
```

要点：
- 第一层 `BackupSeed` 是「密码的一次性加固态」，**跨备份共享**（同一密码下），内存只驻留它。
- 第二层 `B-KEY_n` 复用现有 `SyncCrypto.deriveBackupKey`——把 `base64(BackupSeed)` 作为其 `password` 入参即可，**签名零改动**；第二层按文件头 KDF 派发（Argon2id 新 / PBKDF2 回退）。
- 第二层提供**域分离**（备份密钥与 BackupSeed 用途区分），并让离线爆破成本 ≈ 两层 KDF（每猜测两层成本叠加），不弱于现状。

### 4.3 backupSeedSalt 的来源（关键决策）

`backupSeedSalt` 必须满足：**跨设备一致（否则同密码派生出的 BackupSeed 不同、备份恢复断链）、跨备份一致（同一密码下 BackupSeed 恒定）、不随同步迁移/改密码变化**。

**否决：由 vaultId 确定性派生（初稿方案，已推翻）**

初稿曾设计 `backupSeedSalt = SHA-256(domain || vaultId)[0:16]`，意图「零存储、跨端一致」。**经推演否决，理由**：

- `vaultId` 是 `Keyring.createNew` 时**本地生成的 UUID**（`keyring.dart`），只在同步场景下才随 keyring 账本传播。
- **未启用同步的本地 vault**，其 vaultId 不离开本机；恢复备份的「其它设备」只有备份文件 + 密码，**无从得知 vaultId** → 无法复现 `backupSeedSalt` → **离线恢复断链**。这是备份的核心承诺（仅凭密码恢复），不可牺牲。
- 若改为「备份头携带 seedSalt」绕过此问题，则 seedSalt 已随文件导出，「由 vaultId 派生」便失去意义——直接随机/固定即可，多此一举。

**方案甲（推荐）：固定常量 salt**

```dart
const Uint8List kBackupSeedSalt = <16 字节固定值，代码硬编码>;
```

- **跨设备/跨备份/跨 vault 天然一致**：所有端同一常量，密码相同即 BackupSeed 相同。
- **零存储、零传播、零竞态**：不新增任何账本/协议字段；固定 salt 无需写入文件头（恢复时代码内置）。**第一层 KDF 参数写入 v2 头 `seedKdf.*`（2026-08-18 定案，见 §4.4「演进负担」）**，仅文件头加字段、不涉账本/同步协议。
- **改密码不变**：BackupSeed 只依赖「密码 + 常量」，与 MK/dataKey/salt 状态无关。
- **安全性不劣于现状**：离线爆破每份备份 ≈ `KDF₂(seed, 每份独立备份salt)`（BackupSeed 层可预计算，查表 O(1) 命中后仍须对每份文件的独立 salt 跑一层 KDF₂，2026-08-18 评审修正表述）。BackupSeed 层跨用户可预计算（固定 salt 的通病），但**第二层的备份 salt 每份随机**（`encodeEncrypted` 每份 `generateSalt()` 的现有行为）——每份备份的爆破成本与现状单层等价，不劣化。第一层固定 salt 的跨用户预计算收益被第二层完全稀释（KDF 选择见 §4.4）。
- 与 `crypto.dart` 头注释所述历史教训（v1 全局固定 salt 被改掉）不冲突：那个全局 salt 是**唯一且唯一层**（跨用户共享派生 MK 的预计算收益大）；本方案固定 salt 只是第一层，第二层独立 salt 兜底。

**方案乙（备选，更强但更复杂）：随机 salt，导出时写入备份头**

- `backupSeedSalt` 随机生成，存 keyring 账本（内存侧稳定用）+ 每份备份头（恢复侧用）。
- 离线爆破两层均 per-vault 独立，强度高于方案甲。
- 代价：账本/备份头加字段、存量升级的多端惰性生成竞态、协议变更。**复杂度收益不成比例**。

**本文档推荐方案甲**：实现最简、零协议变更、安全性不劣于现状。方案乙列为可选增强（若未来威胁模型要求 per-vault 隔离的第二层）。

### 4.4 KDF 选择与成本（对齐 Argon2id 迁移的修订）

> 初稿此处写「两层均复用 `kPbkdf2Iterations = 200000` 的 PBKDF2」，那是 2026-08-10 设计时点的现状。2026-08-11 起**新 vault / 新备份默认已是 Argon2id（`m=32MiB, t=3, p=2`）**，备份 KDF 经 `deriveKeyFromKdf` 按文件头 `algorithm` 派发（`crypto.dart`）。两层都写死 PBKDF2 会让新备份相对现状单层 Argon2id 成为**安全回退**，故修订如下：

- **第一层 BackupSeed**：采用与当前新备份默认一致的 KDF——Argon2id `m=32MiB, t=3, p=2`，走 `deriveKeyFromKdf` 派发（而非 `deriveMasterKey`，后者仅 PBKDF2 回退分支）。盐与参数由代码内置（固定契约，见下「演进负担」）。
- **第二层 B-KEY**：复用现有 `deriveBackupKey`，按文件头 KDF 派发（签名零改动）。

成本估算（两层均 Argon2id 默认参数）：
- 自动备份：会话内第一层只算一次，每份备份第二层一次 ≈ 现状每份备份一次 Argon2id 的成本，**持平**。
- 恢复：两层 ≈ 2×一次 Argon2id（Windows 实测单次约 200–330ms；移动端纯 Dart 更慢），恢复是低频大操作，可接受。

**演进负担（2026-08-18 评审修订：`seedKdf.*` 由可选升级为必写）**：固定 salt 与参数不进文件头意味着第一层 KDF 参数 + salt 是「冻结契约」——未来 Argon2id 参数升级会让旧 v2 备份恢复断链。**定案：v2 头必写第一层 KDF 参数（`seedKdf.algorithm`/`iterations`/`memoryKiB`/`parallelism`，salt 仍代码内置）**，既保留「恢复端零依赖当前会话」，又留演进空间；该改动仅备份文件头加字段，不涉 keyring 账本 / 同步协议。**理由**：v2 尚未发布，一次写入成本极低；若先零字段上线、后补参数，需处理「已发布的无参 v2 头」双重兼容，得不偿失。恢复端按 `seedKdf` 字段存在与否兼容（有 → 按文件参数派生第一层；无 → 按代码内置默认参数，防御性兜底）。

## 5. 模块级改造详述

### 5.1 PhraseHandler 改造（`lib/data/preference_and_config.dart` `PhraseHandler`，现状见 §2.1 M1）

不再持有明文密码，改为持有「会话派生密钥」：

```dart
class PhraseHandler {
  static Uint8List? _backupSeed;        // 备份专用种子（32B，密码派生态）
  static bool get isSessionActive => _backupSeed != null;

  /// 会话期注入 BackupSeed（登录/设置/改密码时由调用方派生后传入）
  static void initSession(Uint8List backupSeed) { _backupSeed = backupSeed; }

  /// 取 BackupSeed（自动备份/导入试解用）；未登录返回 null
  static Uint8List? get backupSeed => _backupSeed;

  static void destroy() { _backupSeed = null; }
}
```

- 删除：`initPass` / `getPass` / `_passphrase`。
- **编译期强制**：所有 `PhraseHandler.getPass` / `initPass` 调用点（M2-M9）必须同步改造，杜绝遗漏。

### 5.2 登录流程（`login.dart` / `session.dart`）

**改造前**：`_login(passphrase)` → `initKeyringFromPassword(password)` → `_onLoginSuccess` → `Session.login(passphrase)` → `PhraseHandler.initPass`（明文驻留）。

**改造后**：

1. `_login(passphrase)` 内 `passphrase` 仍是局部变量（输入框读出的，不可避免）。
2. `initKeyringFromPassword(password)`（`sync_service.dart`）内部 `Keyring.unlockLocal` / `createNew` 拿到 `keyring` 后，**追加派生 BackupSeed 并注入 PhraseHandler**：

   ```dart
   final backupSeed = await SessionKeys.deriveBackupSeed(password);
   PhraseHandler.initSession(backupSeed);
   ```

   密码在此调用栈内用完即弃，不再向上传递。
3. `Session.login(String passphrase)`（`session.dart`）**删除明文参数，改为无参状态方法**（仅记录会话状态与日志）；登录流程在步骤 2 已注入 BackupSeed，`Session.login` 不再接触任何密码。
4. `_onLoginSuccess(String passphrase)`（`login.dart`）不再把 passphrase 传给 Session；日志仍只记长度。
5. **生物认证凭据不再随登录刷新**（2026-08-18 评审修订，见 §5.6）：登录成功不再写 secure storage——消除「密码自动写入凭据」的路径。凭据只在用户于设置页主动重新启用时写入。

**指纹登录路径**（`login.dart` `_login(await BiometricAuth.authKey)`）：保持调用，但 `_login` 内部不再把明文注入 PhraseHandler（改动点 2 已覆盖）——解包出的密码只在解锁调用栈内存活。
**指纹登录失败路径**（2026-08-18 评审修订）：若指纹验证通过但 `initKeyringFromPassword` 抛 `WrongPasswordException`（凭据解包成功但密码已过期，即他端改密后本地凭据未刷新），**自动 `BiometricAuth.disable()`**（清空 secure storage 凭据 + 关闭开关），并提示用户「生物识别凭据已失效，请用密码登录；如需指纹，可在设置中重新启用」。凭据失效 ≠ 用户指纹问题（后者由 `LocalAuthentication.authenticate` 层返回 false，不触发关闭）。

### 5.3 设置密码（`set_passphrase.dart` `_loginController` / `_initKeyring`）

`_loginController` 中 `_initKeyring(enteredPassphrase)` 成功后调 `Session.onPasswordSet(enteredPassphrase)`。改造：
- `Session.onPasswordSet` 改为接收「新密码」（vaultId 不需要，见 5.4）。
- `enteredPassphrase` 仍在 `_initKeyring` 调用栈内用于派生，用后即弃。

### 5.4 Session 改造（`lib/models/session.dart`）

```dart
class Session {
  // 密码登录：不接收明文。登录流程已注入 BackupSeed；不刷新 biometric（2026-08-18）。
  static void login() { Log.auth.i('会话登录: 派生密钥已装载'); }

  // 设置/改密码副作用：重派生 BackupSeed + 关闭生物认证（凭据已失效，见 §5.6）
  static Future<void> onPasswordSet({
    required String newPassword,   // 调用栈内即用即弃
  }) async {
    final backupSeed = await SessionKeys.deriveBackupSeed(newPassword);
    PhraseHandler.initSession(backupSeed);
    if (PreferencesStorage.isBiometricAuthEnabled) {
      Log.auth.i('密码已变更: 生物识别凭据失效, 自动关闭');
      await BiometricAuth.disable();      // 用户可在设置中重新启用（需重输密码）
    }
    // 密码不再驻留
  }

  static Future<void> logout() async {
    // ... 现有清理 ...
    PhraseHandler.destroy();
  }
}
```

其中 `SessionKeys`（新增，`lib/models/session_keys.dart`）封装派生：

```dart
class SessionKeys {
  /// 备份种子盐：固定 16B 常量（方案甲，见 §4.3）
  static const Uint8List kBackupSeedSalt = Uint8List.fromList([...]);

  /// 第一层 BackupSeed 派生（KDF 与当前新备份默认一致，见 §4.4）
  static Future<Uint8List> deriveBackupSeed(String password) =>
      SyncCrypto.deriveKeyFromKdf(
        password,
        kdf: KdfParams(
          algorithm: kArgon2idAlgorithm,
          salt: base64Encode(kBackupSeedSalt),
          iterations: kArgon2idIterations,
          memoryKiB: kArgon2idMemoryKib,
          parallelism: kArgon2idParallelism,
        ),
      );
}
```

> 说明：`deriveBackupSeed` 复用 `deriveKeyFromKdf` 派发（第一层 KDF 与当前新备份默认一致，不写死 PBKDF2，见 §4.4），不经过任何 MK/dataKey，独立派生链（满足原则 3）。入参不需要 vaultId（固定 salt）。

### 5.5 改密码流程（`change_passphrase.dart` `_finalSubmitChange`）

- `keyring.verifyPassword(oldPassword)` / `changePassword(oldPassword, newPassword)`：两个密码都在调用栈内，用后即弃，**零改动**。
- 末尾 `Session.onPasswordSet(newPassword)`（`change_passphrase.dart`）改为传新密码（5.4 签名），内部完成 BackupSeed 重派生 + **关闭生物认证**（凭据随密码变更失效，见 §5.6），newPassword 用后即弃。
- **UX 提示**（2026-08-18 修订）：改密码成功后弹提示「生物识别登录已关闭，如需使用请到设置中重新启用（需重新输入密码）」——替代原「刷新凭据」的静默行为，让用户知晓指纹已失效。

### 5.6 生物认证改造（`biometric_auth.dart`）

**2026-08-18 评审修订——凭据策略收紧为「不自动刷新，失效即关闭」**：

原设计（初稿）在密码变更后仍用新密码刷新 secure storage 凭据（`setAuthKey` 显式传参）。评审认为：刷新路径意味着「密码 → secure storage 写路径」在登录/改密时被自动触发，违背「密码只在用户主动输入时出现」的纯粹性；且他端改密后本地凭据必然过期，刷新与否都需用户介入。**最终策略**：

1. **凭据写入只发生在「用户主动启用」时**：设置页开启生物认证 = 指纹验证 + 输入当前密码 → `enable({required String password})` → `setAuthKey(password: ...)`（用完即弃）。**任何自动化路径不再写 secure storage 凭据**（登录、改密均不写）。
2. **凭据失效即自动关闭**，关闭时机：
   - **本地改密**：`Session.onPasswordSet` 内若 biometric 已启用 → `BiometricAuth.disable()`（§5.4）；
   - **他端改密 → 本地指纹登录**：指纹验证通过但解 keyring 失败（`WrongPasswordException`）→ 凭据过期 → `_login` 指纹路径自动 `BiometricAuth.disable()` 并提示（§5.2）；
   - **他端改密 → 本地密码重登（远端路径）**：`_tryVerifyPassphraseViaRemote` 成功（`unlockFromRemoteManifest` 覆盖本地 vault，本地密码已切换）→ 凭据（旧密码）必然失效 → 登录流程自动 `BiometricAuth.disable()` 并提示。
   - 普通本地密码登录（`unlockLocal` 成功、密码未变）→ 凭据仍有效 → **不关闭**。
3. **重新启用**：用户到设置页手动开启 → 指纹验证 + 输入当前密码（**复用通用密码输入模板 `showAppPassword`，`lib/widgets/app_dialogs.dart`**，全 app 密码/口令输入已统一该入口，见 2026-08-18 变更）→ 凭据以新密码重写。

| 项 | 现状 | 改造 |
|---|---|---|
| `setAuthKey()` | `PhraseHandler.getPass` 取明文 | `setAuthKey({required String password})` 显式传参；仅 `enable(password)` 内部调用 |
| `enable()` | 无参，内部 `setAuthKey()` 取明文 | `enable({required String password})`；`biometric_setting.dart` 开启时先指纹验证、再弹密码框取密码传入 |
| `authKey` getter | 解包返回明文 | **保留**（指纹登录仍需要密码解锁 keyring，这是 C3 决定的），但调用方 `_login` 不再注入 PhraseHandler（§5.2），且失败路径自动关闭（§5.2 指纹失败分支） |
| 旧版明文兼容 | 无前缀直接当明文返回 | 保留读取兼容；`setAuthKey` 写入时已是 v1 包裹（现状已自动升级）。**可选增强**：应用启动时若检测到旧版明文记录，提示用户重新输入密码以升级 |
| wrap key 与密文同库（B2） | 两者同 FlutterSecureStorage | **可选增强**：wrap key 改存平台 Keystore/Keychain 不可导出密钥（需原生代码）。文档说明：若信任 secure storage 本身，同库包裹是纵深防御；若要抵御「secure storage 整体被导出」，需硬件级 wrap key |

**核心结论**：生物认证的持久化已是「密码的包裹态」（非明文），本次改造的重点是：
1. **登录路径不把解包明文注入内存**（§5.2）；
2. **彻底移除「密码自动写入 secure storage」的所有路径**（登录刷新、改密刷新均删除）——凭据只在用户主动启用时写入；
3. **密码变更后凭据失效一律自动关闭**，用户可自行重新启用（重输密码）；
4. 消除旧版明文记录（可选增强）。

### 5.7 同步改造（`sync_service.dart` + `sync_engine.dart`）

**移除 `passphraseProvider`**（M5/M6）：
- `sync_service.dart` 三处 `passphraseProvider: () => PhraseHandler.getPass` 删除（`SyncEngine` 构造函数参数相应删除）。
- `sync_engine.dart` 场景 c/d 判别改造：

**改造前**：分支 2（dataKey 不同）→ 本地 MK 解不开远端包裹 → `passphraseProvider` 取当前密码 → `tryDeriveRemoteDataKey` 判别场景 c（密码不同→requiresRelogin）/ d（密码相同→自动迁移）。

**改造后**：移除 provider 后，该分支**统一返回 `requiresRelogin: true`**。

> **实施注意（2026-08-18 评审补充）**：现状 `sync_engine.dart` 「无密码提供者」分支（`passphraseProvider == null || 为空`）返回的 `SyncResult.failure` **未携带 `requiresRelogin`**，改造时必须显式加上 `requiresRelogin: true`，否则 UI 不会跳转重登，用户会卡在无提示的同步失败。改造后的分支 2 结构：
> ```dart
> // 本地 MK 解不开远端包裹（密码不同 或 salt 不同）：
> // 移除 passphraseProvider 后无法后台判别场景 c/d → 统一要求重登
> Log.sync.w('dataKey 迁移失败：需重新登录以完成场景 c/d 判别');
> return SyncResult.failure(
>   'dataKey 迁移失败：${migrationResult.error}',
>   attempts: attempt,
>   requiresRelogin: true,   // 关键：显式携带
> );
> ```

**2026-08-18 评审修正——场景 d 判别前移到登录流程（原推演有缺陷）**：

初稿推演「重登后走 `_tryVerifyPassphraseViaRemote` → `unlockFromRemoteManifest` 完成迁移」**不成立**：`_tryVerifyPassphraseViaRemote` 只在 `initKeyringFromPassword` **失败**时才被调用（`login.dart` `_login` 步骤 2），而场景 d **密码相同**，重登时本地 `unlockLocal` 必然**先成功**（本地 keyring 未变），直接进入 `_onLoginSuccess`，根本到不了远端路径。于是：登录成功 → 后台同步又遇分支 2 → `requiresRelogin` → `home.dart` **强制弹窗**踢出 → 再重登 → 再成功 → 再踢出——**无限循环**。

**修正方案：场景 c/d 判别与迁移前置到登录流程（密码仍在其调用栈内）**。`_login` 本地解锁成功分支、进入 `_onLoginSuccess` 之前，若同步已启用（`SyncConfig.isSyncReady`），先做轻量「远端 vault 一致性检查」（仅拉 manifest header，不拉全量，几百字节一次 GET）：

```
本地解锁成功（keyring 已注入）
 └─ 同步未启用 / 远端无 manifest / 远端 vaultId == 本地 vaultId
      → 正常登录（现状行为，本地 vault 将首次上传或同 vault 同步）
 └─ 远端 vaultId != 本地 vaultId（两设备独立建 vault 后互通）
      ├─ 用密码 P + 远端 KDF 参数派生 MK，fingerprint 匹配 → 场景 d
      │    → 弹确认「检测到另一设备创建的保险库，将迁移到远端保险库」
      │    → Keyring.unlockFromRemoteManifest(P, ...)（调用栈内即用即弃）
      │    → 迁移完成，登录成功（后续同步不再触发 requiresRelogin）
      └─ fingerprint 不匹配 → 场景 c（密码不同）
           → 提示「远端保险库密码不同，无法同步」，允许「仅本地使用」登录
             （本地数据照常，同步不可用；用户可改密码或放弃同步）
```

行为变化：
- **场景 d**：原后台自动迁移 → 改造后「一次重登 + 一次显式迁移确认」，迁移在密码调用栈内完成，**无死循环、零内存留密码**。功能可达，行为更保守。
- **场景 c**：原每次同步强制踢出（现状即如此）→ 改造后登录时即提示，用户可选择仅本地使用，不再无限踢出（体验改善）。
- **新设备首次加入**：本地无 keyring → `isInitialized == false` → 走既有 `_tryVerifyPassphraseViaRemote` 路径，不受影响。
- 一致性检查失败（网络不可达）→ 不阻断本地登录（现状行为：后台同步自行处理）。

> 注：`tryDeriveRemoteDataKey` / `migrateToRemoteVault` 方法保留（供 CLI 或未来显式迁移复用）；同步引擎分支 2 仍统一 `requiresRelogin: true` 作为兜底（登录时未完成判别、运行时密钥变化的防御）。

### 5.8 自动备份改造（`scheduled_task.dart` + `file_handler.dart` + `crypto.dart`）

**改造前**：`unitBackupAttempt` → `PhraseHandler.getPass.isEmpty` 判空 → `encryptedOutputBackupContent(password: PhraseHandler.getPass)` → `BackupFileCodec.encodeEncrypted(password: ...)` → `deriveBackupKey(password)`。

**改造后**：

1. `scheduled_task.dart`：判空改为 `PhraseHandler.backupSeed == null`；`encryptedOutputBackupContent` 传入 `backupSeed`（字节）。
2. `file_handler.dart` `encryptedOutputBackupContent`：签名改为接收 `Uint8List backupSeed`（或统一传 `String`），内部 `BackupFileCodec.encodeEncryptedFromSeed`。
3. `backup_file.dart` 新增 `encodeEncryptedFromSeed`：内部 `B-KEY = deriveBackupKey(base64Encode(seed), kdf: 文件头KDF参数)`，**formatVersion 写 2**（派生链变为两层，见 §6）。
4. `crypto.dart`：`deriveBackupKey` 签名零改动（传入 base64 字节串即可）。新增常量 `kBackupSeedSalt`（16B 固定值，与 5.4 共用）。

**手动导出**（`backup_setting.dart` / `export_backup_dialog.dart`）：用户自定义口令也统一走两层派生（`encodeEncrypted` 升级为两层，formatVersion=2）；默认「当前会话密码」预填逻辑（`export_backup_dialog.dart` 已改为不静默填密码）保持——若用户选择用会话密码，走 `encodeEncryptedFromSeed`。

### 5.9 加密导入改造（`file_handler.dart` `_resolveEncryptedRecords`）

**改造前**：`PhraseHandler.getPass` 自动试解 → 失败弹框。

**改造后**：优先级改为：
1. **v2 格式 + 内存有 BackupSeed**：用 `backupSeed` 推导 B-KEY 试解（免弹框）。
2. **失败 / v1 旧格式 / 独立备份口令 / 其它 vault**：弹框让用户输入密码，按文件头参数派生（v1 单层 / v2 两层）。
3. 兼容：`decryptEncrypted` 按 `formatVersion` 分流（v2 → 两层派生；v1 → 现状单层）。

### 5.10 其它

- `main.dart`：用 `NotesDatabase.instance.isEncryptionEnabled` 判断登录状态，不依赖 PhraseHandler.getPass —— **零改动**。
- `ImportPassPhraseHandler` / `destroyImportCredentials`：维持现状（临时值 + 用完清理）。

## 6. 备份文件格式变更（v2）

### 6.1 头字段变更

| 字段 | v1（现状） | v2（新） |
|---|---|---|
| `format` | `snbak` | `snbak`（不变） |
| `formatVersion` | `1` | `2` |
| `enc.kdf.salt` | 备份 salt（16B，每份随机） | 不变（第二层派生用） |
| `enc.kdf.algorithm`/`iterations`/`memoryKiB`/`parallelism` | Argon2id 默认 / PBKDF2 回退 | 不变（第二层派生用） |
| `seedKdf.algorithm`/`iterations`/`memoryKiB`/`parallelism` | —（无） | **第一层 KDF 参数（必写，2026-08-18 定案；salt 仍代码内置）**——见 §4.4「演进负担」 |
| `payload` | AES-GCM(B-KEY, nonce, aad='backup-v1', plaintext) | 不变（B-KEY 由两层派生链得出） |

**v2 核心变更：`formatVersion = 2`，表示 B-KEY 由「两层派生链」得出（第一层固定 `kBackupSeedSalt`，见 §4.2）。固定 salt 不写入文件头（恢复时代码内置）；第一层 KDF 参数写入 `seedKdf.*`（恢复端按文件参数派生，留演进空间，见 §4.4）。**

### 6.2 格式兼容矩阵

| 场景 | formatVersion | 解密路径 |
|---|---|---|
| v1 旧备份（历史导出） | 1 | 输入密码 → 按文件头 KDF 派生 B-KEY（现状单层，Argon2id 新 / PBKDF2 回退） |
| v2 新备份（自动/默认导出，登录密码） | 2 | 输入密码 → `KDF(密码, 固定salt)` → BackupSeed → `deriveBackupKey(seed, 文件头.kdf)` → B-KEY |
| v2 + 独立备份口令 | 2 | 输入自定义口令 → `KDF(口令, 固定salt)` → BackupSeed → `deriveBackupKey(seed, 文件头.kdf)` → B-KEY（同一公式，口令即密码） |

> 独立备份口令语义不变：口令即文件头的「密码」。v2 统一两层派生，无论口令是登录密码还是自定义口令。

## 7. 兼容性与数据迁移

1. **PhraseHandler API 变更**：编译期强制，所有消费点（M2-M9）一次性改造，无运行时兼容负担。
2. **生物认证旧明文记录**：读取兼容保留；写入时已自动升级 v1（现状行为）。可选一次性迁移：启动检测到旧格式记录时提示用户重新录入。
3. **备份 v1 文件**：导入路径按 `formatVersion` 分流，v1 照常可恢复（需密码原文弹框）。
4. **存量 keyring（无任何新增字段）**：方案甲用固定 `kBackupSeedSalt`，**与 keyring 状态无关，存量用户零迁移**——下次登录即自动获得 BackupSeed。
5. **同步协议**：固定 salt 不涉及任何协议字段，manifest header / keyring 账本 **零变更**。
6. **测试更新**：
   - `test/sync/change_password_multi_client_test.dart` 的 `PhraseHandler.initPass/destroy` 改 `initSession/destroy`。
   - `test/sync/sync_test_support.dart` 等处的 `passphraseProvider` 构造参数移除。
   - 新增用例见 §10。

## 8. 威胁模型与残余风险

### 8.1 本方案消除的泄露面

| 泄露面 | 消除方式 |
|---|---|
| 内存 dump / 日志 / 崩溃转储拿到「密码原文」 | 密码只存在于输入框→派生调用的调用栈；日志只记长度（现状已脱敏） |
| 密码被二次利用（用户多处复用密码，撞库他站） | 内存/持久化均无密码，攻击者只能拿到派生密钥 |
| 生物认证 secure storage 泄露出密码原文 | 已是包裹态（现状 v1），且登录路径不再把解包明文驻留内存 |

### 8.2 残余风险（明确说明，不承诺消除）

1. **内存攻击者仍能拿到派生密钥**：`MK` / `dataKey` / `BackupSeed` 及解密后的笔记明文本就驻留内存。Flutter/Dart 单进程模型下，「能读内存的攻击者」可拿到一切——本方案的目标不是防这种攻击者，而是**消除「密码原文」这一可复用凭证**。
2. **生物认证 wrap key 与密文同库**：secure storage 被整体导出时两者同泄，包裹退化为纵深防御。彻底解决需硬件级 wrap key（原生代码），列为可选增强。**Windows 上的具体结论见 §8.4**。
3. **改密码后旧备份需旧密码**：C5 固有现实，UI 在改密码前弹窗提示（现状 `_preChangeCheck` 已强制备份，需补充提示文案）。
4. **BackupSeed 泄露可解同 vault 全部备份**：BackupSeed 是密码的加固态，等价「密码的离线爆破结果」。其泄露路径与 MK/dataKey 相同（读内存），不构成新增风险。
5. **固定 salt 的跨用户预计算**：BackupSeed 层 salt 为固定常量，攻击者可为常见密码预计算 BackupSeed 表。**但第二层备份 salt 每份随机**，爆破单份备份的实际成本 ≈ **1×KDF₂ + 预计算表摊销**（查表 O(1) 命中后仍须对每份文件的独立 salt 跑一层 KDF₂），**与现状单层等价、不弱化**（2026-08-18 评审修正：初稿「两层成本叠加」表述偏乐观，预计算后不是 2×；结论不变——不劣于现状）。

### 8.3 安全强度对比

| 项 | 现状 | 本方案 |
|---|---|---|
| 备份离线爆破成本（每猜测/每份） | 1×KDF（Argon2id 默认） | ≈1×KDF₂ + 预计算摊销，与现状持平（不弱化） |
| 生物认证持久化 | 包裹态（v1），登录/改密时自动刷新 | 包裹态（v1）不变；**凭据不再自动刷新**，密码变更后失效即关闭，仅用户主动启用时写入 |
| 内存明文密码 | 有（会话期驻留） | 无（仅输入框→派生调用栈） |
| 密码 → secure storage 自动写路径 | 有（`Session.login`/`onPasswordSet` 刷新） | **无**（写入仅发生在设置页主动启用） |
| 同步场景 c/d 自动迁移 | 后台自动 | 需重登一次（更保守） |
| 密码变更后的生物认证体验 | 自动刷新（无感） | 自动关闭（需手动重新启用，更保守） |

### 8.4 Windows 平台 secure storage 实现查证（回应「拿到文件能否解密」）

对 flutter_secure_storage_windows **4.1.0（本项目锁定版本）源码查证**（`windows/flutter_secure_storage_windows_plugin.cpp`）：

**存储机制**：
- 数据文件：`%APPDATA%\{CompanyName}\{ProductName}\<key>.secure`（由 exe 版本资源的 Company/Product 决定目录）。
- 文件内容：`IV(12B) ‖ authTag(16B) ‖ AES-256-GCM ciphertext`（BCrypt，nonce 随机）。
- **AES 密钥**：16B 随机，存 **Windows Credential Manager**（`CredWriteW`，TargetName=`key_<prefix>`，`CRED_PERSIST_LOCAL_MACHINE`）。加解密时经 `CredReadW` 取出。
- 旧版本（<2.0.0）曾把值直接写入 Credential Manager，本实现保留向后兼容读取路径。

**结论——别人拿到 `.secure` 文件能否解密**：

| 攻击者能力 | 结果 |
|---|---|
| 仅拿到 `.secure` 文件（离线，无该 Windows 用户凭据） | **不能解密**。文件是 AES-GCM 密文，密钥在 Credential Manager 中，受 Windows 用户凭据（DPAPI 主密钥）保护。无该用户登录凭据/会话上下文，无法取出 AES 密钥 |
| 以该 Windows 用户身份运行任意程序（登录会话内 / 恶意进程 / 拿到用户凭据） | **能解密一切**。进程可调用 `CredReadW` 取出 AES 密钥 → 解密所有 `.secure` → 拿到 `_secureBiometricWrapKey` 与密码密文 → **解出密码明文** |

**对生物认证 v1 包裹的含义**：Windows 上「secure storage 被攻破」与「能拿到密码明文」是同一件事（wrap key 与密文同库同保护边界）。v1 包裹的防御对象是「仅拿到文件的离线攻击者」，而非「持有用户凭据的在线攻击者」——后者已经越过操作系统安全边界，任何应用层方案（包括本方案）都无法在纯 Dart 层防御。这与 §8.2 第 2 点结论一致，是**操作系统用户凭据边界的固有上限**，非本方案引入的缺陷。

## 9. 改动清单（实施参考）

| 文件 | 改动 |
|---|---|
| `lib/data/preference_and_config.dart` | `PhraseHandler` 重构：删除 `_passphrase`/`initPass`/`getPass`；新增 `_backupSeed`/`initSession`/`backupSeed`/`isSessionActive` |
| `lib/models/session_keys.dart`（新增） | `kBackupSeedSalt`（固定 16B 常量）+ `deriveBackupSeed(password)` |
| `lib/models/session.dart` | `Session.login` 去明文参数（无参，**不再刷新 biometric**）；`onPasswordSet` 改为接收新密码并重派生 BackupSeed + **关闭生物认证**（凭据失效）；`logout` 不变（destroy 已清 BackupSeed） |
| `lib/views/authentication/login.dart` | `_onLoginSuccess` 不再传明文给 Session；`_login` 流程派生 BackupSeed 后丢弃密码；**指纹登录解 keyring 失败路径自动 `BiometricAuth.disable()` 并提示**；`_tryVerifyPassphraseViaRemote` 成功路径（远端重登覆盖本地 vault）同样自动关闭生物认证；**新增「远端 vault 一致性检查」：本地解锁成功后、同步启用时比对远端 vaultId，场景 d 在调用栈内弹确认并 `unlockFromRemoteManifest` 迁移，场景 c 提示仅本地使用（2026-08-18 修订）** |
| `lib/views/authentication/set_passphrase.dart` | `_initKeyring` 成功后按新 `onPasswordSet` 签名调用 |
| `lib/views/change_passphrase.dart` | 末尾 `onPasswordSet` 传新密码（+ 旧备份需旧密码提示 + 生物认证已关闭提示） |
| `lib/models/biometric_auth.dart` | `setAuthKey({required String password})` 显式传参；`enable({required String password})`；读旧明文兼容保留；（可选）wrap key 硬件化 |
| `lib/views/settings/biometric_setting.dart` | 开启生物认证流程：指纹验证后**复用通用密码输入模板 `showAppPassword` 弹框输入当前密码**，再 `enable(password)`（2026-08-18 新增） |
| `lib/sync/sync_service.dart` | 删除三处 `passphraseProvider` 注入；`initKeyringFromPassword` 内派生 BackupSeed 注入 PhraseHandler |
| `packages/core/lib/src/sync/sync_engine.dart` | 删除 `passphraseProvider` 参数与消费；场景 c/d 分支统一 `requiresRelogin: true`（**含现状无密码提供者分支，需显式加标志**） |
| `packages/core/lib/src/sync/sync_models.dart` | `SyncEngine` 构造签名同步（若参数在 engine 而非 service） |
| `bin/cli_context.dart` | `_rebuildEngine` 移除 `passphraseProvider` 注入（2026-08-18 补充，否则 CLI 编译失败）；CLI 场景 d 同样退化为 requiresRelogin |
| `lib/utils/scheduled_task.dart` | `unitBackupAttempt` 判空改 `backupSeed == null`；三平台备份传 BackupSeed |
| `lib/models/file_handler.dart` | `encryptedOutputBackupContent` 改收 BackupSeed；`_resolveEncryptedRecords` 先试 BackupSeed 后弹框 |
| `packages/core/lib/src/models/backup_file.dart` | `encodeEncrypted` 升级为两层派生（formatVersion=2，**头写 `seedKdf.*` 第一层参数**）；新增 `encodeEncryptedFromSeed`（自动备份用）；`decryptEncrypted` 按 formatVersion 分流 |
| `packages/core/lib/src/models/parse_import.dart` | `BackupHeader` 允许 `formatVersion = 2`（仅校验上限）；解析 `seedKdf.*` 字段 |
| `packages/core/lib/src/crypto/crypto.dart` | 新增 `kBackupSeedSalt` 常量；`deriveBackupKey` 零改动 |
| `test/sync/change_password_multi_client_test.dart` 等 | PhraseHandler API、passphraseProvider 参数更新 |
| `bin/cli_commands.dart` | `import` 按 formatVersion 分流（与 App 同逻辑） |

## 10. 验证计划

1. `dart analyze packages/core` / `flutter analyze lib` 0 issue（编译期强制 PhraseHandler 无明文 API 残留）。
2. 核心包新增测试：
   - `deriveBackupSeed` 往返（固定 salt）+ 与 `deriveMasterKey` 语义隔离（改 MK 不影响 BackupSeed）；
   - v2 备份 `encodeEncrypted → decryptEncrypted` 往返；错误密码 → `SyncDecryptionException`；
   - 头中 `salt`/`iterations` 被篡改 → 解密失败；
   - `formatVersion=1` 旧备份单层恢复路径回归；`formatVersion=2` 双层恢复；
   - **v2 头 `seedKdf.*` 参数解析与缺省兜底（2026-08-18 新增）**；
   - 独立备份口令（自定义口令）v2 导出/导入往返；
   - 同步：移除 passphraseProvider 后 scenario-b / 场景 c 均 `requiresRelogin: true`（**含无密码提供者分支**）；**场景 d 登录时 vault 一致性检查 → 弹确认 → `unlockFromRemoteManifest` 迁移成功 → 后续同步不再 requiresRelogin（无死循环，2026-08-18 修订）**；场景 c 登录时提示可「仅本地使用」。
3. `flutter test` 回归：登录（密码+指纹）、设置/改密码、生物认证开关、自动备份、导入（v1/v2/独立口令）。
4. **生物认证新策略用例（2026-08-18 新增）**：
   - 本地改密码成功后 → `isBiometricAuthEnabled == false`、secure storage 凭据已清除；
   - 他端改密码 → 本地指纹登录失败（解 keyring `WrongPasswordException`）→ 自动关闭生物认证 + 提示；
   - 他端改密码 → 本地用新密码走远端重登成功 → 自动关闭生物认证；
   - 密码未变时普通密码登录 → 生物认证保持启用（凭据仍有效，不误关）；
   - 设置页重新启用 → 指纹验证 + 输入当前密码 → `enable(password)` 成功 → 指纹登录可用。
5. CLI 端到端：v2 导出 → 同机/他机导入；v1 文件导入；明文导出导入；CLI 同步场景 d 退化为 requiresRelogin（`bin/cli_context.dart` 编译与行为）。
6. 手动验证：登录后 `PhraseHandler.getPass` 已不可访问（编译期删除）；日志无任何密码值；指纹登录路径解包密码不注入 PhraseHandler。

## 11. 明确不做的事（范围外）

- 不消除「用户输入阶段」的临时明文（输入框/表单，不可避免且一次性）。
- 不防「能 dump 进程内存的攻击者」拿到派生密钥（MK/dataKey/BackupSeed/笔记明文，技术不可行）。
- 不做生物认证 wrap key 的硬件化（原生工作量，列为可选增强）。
- 不改变同步协议（固定 salt 不涉及任何协议字段）。
- 不为「跨用户预计算」引入 per-vault 随机 seedSalt（方案乙）：收益被第二层独立 salt 稀释，复杂度不成比例。

---

*变更记录：2026-08-10 初稿。基于对话推演：确认 dataKey/MK 均会随同步迁移变化（C1/C2）→ 生物认证维持存「密码包裹态」；确认备份密钥不能依赖当前密钥状态（C4）→ BackupSeed 独立派生链。2026-08-10 修订：经用户指出 vaultId 是本地 UUID、无法跨未同步设备复现，否决「backupSeedSalt 由 vaultId 派生」（方案甲 v1），改为**固定常量 salt**（方案甲 v2），备份格式仅 bump formatVersion 至 2、无新增字段；并查证 Windows secure storage 实现（.secure 文件 = AES-GCM 密文，密钥存 Credential Manager），补充 §8.4 威胁模型。2026-08-16 修订（对齐现状代码）：§0 改为「整份提案未实施」完整状态框；全文行号引用改为符号引用；§4.4 由「两层 PBKDF2 200k」修订为对齐 Argon2id 迁移（第一层走 `deriveKeyFromKdf` 派发）；新增「演进负担」说明与可选 `seedKdf.*` 头字段；§6.1/§6.2/§8.3 相应更新。2026-08-18 修订（设计评审定案）：生物认证策略收紧为「凭据不随密码自动刷新，密码变更后失效即关闭，仅用户主动启用时写入」——`Session.login` 彻底无参、`onPasswordSet` 改关闭凭据、指纹登录失败与远端重登成功路径自动 `disable()`、设置页启用需弹框输密码（§5.2/§5.4/§5.5/§5.6/§8.2/§8.3/§9/§10）；备份 v2 头 `seedKdf.*` 升级为必写字段（§4.4/§6.1）；同步场景 c/d 无密码提供者分支须显式携带 `requiresRelogin: true`（§5.7）；**复核发现并修正场景 d 推演缺陷——判别前移到登录流程（§5.7），避免重登死循环**；改动清单补 `bin/cli_context.dart`（§9）；§8.2 爆破成本表述修正为「≈1×KDF₂ + 预计算摊销，与现状持平」。*
