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

**C3（密码是最稳定的凭据）**：密码跨所有同步迁移稳定（scenario c/d 中密码不变）；改密码是用户显式操作，生物认证可同步刷新。因此生物认证**仍须存「密码的等价物」**（包裹态密码），这正是现状 v1 已采用的方式。

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
- **零存储、零传播、零竞态**：不新增任何账本/协议字段；固定 salt 无需写入文件头（恢复时代码内置）。第一层 KDF 参数是否写入文件头见 §4.4「演进负担」（可选增强，不改变本节结论）。
- **改密码不变**：BackupSeed 只依赖「密码 + 常量」，与 MK/dataKey/salt 状态无关。
- **安全性不劣于现状**：离线爆破每份备份 = `KDF₁(密码, 固定salt)` + `KDF₂(seed, 每份独立备份salt)`，两层成本叠加。BackupSeed 层跨用户可预计算（固定 salt 的通病），但**第二层的备份 salt 每份随机**（`encodeEncrypted` 每份 `generateSalt()` 的现有行为）——预计算的 BackupSeed 仍需对每份文件单独跑一层 KDF，每份备份的爆破成本与现状单层等价，不劣化。第一层固定 salt 的跨用户预计算收益被第二层完全稀释（KDF 选择见 §4.4）。
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

**演进负担（零字段设计的固有代价）**：固定 salt 与参数不进文件头意味着第一层 KDF 参数 + salt 是「冻结契约」——未来 Argon2id 参数升级会让旧 v2 备份恢复断链。缓解（推荐）：v2 头**写入第一层 KDF 参数（`algorithm`/`iterations`/`memoryKiB`/`parallelism`，salt 仍代码内置）**，既保留「恢复端零依赖当前会话」，又留演进空间；该改动仅备份文件头加字段，不涉 keyring 账本 / 同步协议。若接受参数冻结（未来变更时 bump 版本并保留旧参数读取分支），则维持零字段（方案甲原版）。

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
3. `Session.login(String passphrase)`（`session.dart`）**删除明文参数**，改为无参或仅状态方法（或直接删除，由登录流程注入 PhraseHandler）。
4. `_onLoginSuccess(String passphrase)`（`login.dart`）不再把 passphrase 传给 Session；日志仍只记长度。

**指纹登录路径**（`login.dart` `_login(await BiometricAuth.authKey)`）：保持调用，但 `_login` 内部不再把明文注入 PhraseHandler（改动点 2 已覆盖）——解包出的密码只在解锁调用栈内存活。

### 5.3 设置密码（`set_passphrase.dart` `_loginController` / `_initKeyring`）

`_loginController` 中 `_initKeyring(enteredPassphrase)` 成功后调 `Session.onPasswordSet(enteredPassphrase)`。改造：
- `Session.onPasswordSet` 改为接收「新密码」（vaultId 不需要，见 5.4）。
- `enteredPassphrase` 仍在 `_initKeyring` 调用栈内用于派生，用后即弃。

### 5.4 Session 改造（`lib/models/session.dart`）

```dart
class Session {
  // 密码登录：不再接收明文。登录流程已注入 BackupSeed。
  static void login() { Log.auth.i('会话登录: 派生密钥已装载'); }

  // 设置/改密码副作用：重派生 BackupSeed + 刷新生物认证凭据
  static Future<void> onPasswordSet({
    required String newPassword,   // 调用栈内即用即弃
  }) async {
    final backupSeed = await SessionKeys.deriveBackupSeed(newPassword);
    PhraseHandler.initSession(backupSeed);
    if (PreferencesStorage.isBiometricAuthEnabled) {
      await BiometricAuth.setAuthKey(password: newPassword);   // 显式传参
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
- 末尾 `Session.onPasswordSet(newPassword)`（`change_passphrase.dart`）改为传新密码（5.4 签名），内部完成 BackupSeed 重派生 + 生物认证刷新，newPassword 用后即弃。

### 5.6 生物认证改造（`biometric_auth.dart`）

| 项 | 现状 | 改造 |
|---|---|---|
| `setAuthKey()` | `PhraseHandler.getPass` 取明文 | `setAuthKey({required String password})` 显式传参；改密码流程传 `newPassword`（5.4），其余不变 |
| `authKey` getter | 解包返回明文 | **保留**（指纹登录仍需要密码解锁 keyring，这是 C3 决定的），但调用方 `_login` 不再注入 PhraseHandler（5.2） |
| 旧版明文兼容 | 无前缀直接当明文返回 | 保留读取兼容；`setAuthKey` 写入时已是 v1 包裹（现状已自动升级）。**可选增强**：应用启动时若检测到旧版明文记录，提示用户重新输入密码以升级 |
| wrap key 与密文同库（B2） | 两者同 FlutterSecureStorage | **可选增强**：wrap key 改存平台 Keystore/Keychain 不可导出密钥（需原生代码）。文档说明：若信任 secure storage 本身，同库包裹是纵深防御；若要抵御「secure storage 整体被导出」，需硬件级 wrap key |

**核心结论**：生物认证的持久化已是「密码的包裹态」（非明文），改造重点是**登录路径不把解包明文注入内存**（5.2），以及消除旧版明文记录（可选增强）。

### 5.7 同步改造（`sync_service.dart` + `sync_engine.dart`）

**移除 `passphraseProvider`**（M5/M6）：
- `sync_service.dart` 三处 `passphraseProvider: () => PhraseHandler.getPass` 删除（`SyncEngine` 构造函数参数相应删除）。
- `sync_engine.dart` 场景 c/d 判别改造：

**改造前**：分支 2（dataKey 不同）→ 本地 MK 解不开远端包裹 → `passphraseProvider` 取当前密码 → `tryDeriveRemoteDataKey` 判别场景 c（密码不同→requiresRelogin）/ d（密码相同→自动迁移）。

**改造后**：移除 provider 后，该分支**统一返回 `requiresRelogin: true`**。

行为变化推演：
- **场景 d（密码相同、salt/dataKey 不同）**：原自动完成「整体迁移到远端 vault」；改造后提示重登，用户重新输入密码，登录流程走 `_tryVerifyPassphraseViaRemote` → `unlockFromRemoteManifest`（用远端 KDF 参数解锁）→ **同一迁移目标，多一步重登**。功能可达，行为更保守（不在内存留密码）。
- **场景 c（密码不同）**：原就 `requiresRelogin`，行为不变。
- **新设备首次加入**：登录流程本就要求输入密码（用户操作），不受影响。

> 注：`tryDeriveRemoteDataKey` / `migrateToRemoteVault` 方法本身保留（供未来显式重登流程或 CLI 复用），只是不再有「后台自动取内存密码判别」的路径。

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
| `seedKdf.*`（可选增强） | —（无） | 第一层 KDF 参数（不含 salt，salt 代码内置）——是否新增见 §4.4「演进负担」 |
| `payload` | AES-GCM(B-KEY, nonce, aad='backup-v1', plaintext) | 不变（B-KEY 由两层派生链得出） |

**v2 核心变更：`formatVersion = 2`，表示 B-KEY 由「两层派生链」得出（第一层固定 `kBackupSeedSalt`，见 §4.2）。固定 salt 不写入文件头（恢复时代码内置）；第一层 KDF 参数默认也零字段（冻结契约），是否写入见 §4.4「演进负担」。**

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
5. **固定 salt 的跨用户预计算**：BackupSeed 层 salt 为固定常量，攻击者可为常见密码预计算 BackupSeed 表。但**第二层备份 salt 每份随机**，预计算结果仍需对每份文件单独跑一层 KDF——每份备份的爆破成本 = 两层 KDF 成本叠加，**不弱于现状单层**，收益被第二层完全稀释（论证见 §4.3 方案甲 / §4.4）。

### 8.3 安全强度对比

| 项 | 现状 | 本方案 |
|---|---|---|
| 备份离线爆破成本（每猜测） | 1×KDF（Argon2id 默认） | 2×KDF，不弱于现状 |
| 生物认证持久化 | 包裹态（v1） | 包裹态（不变） |
| 内存明文密码 | 有 | 无 |
| 同步场景 c/d 自动迁移 | 后台自动 | 需重登一次（更保守） |

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
| `lib/models/session.dart` | `Session.login` 去明文参数；`onPasswordSet` 改为接收新密码并重派生 BackupSeed+刷新生物认证；`logout` 不变（destroy 已清 BackupSeed） |
| `lib/views/authentication/login.dart` | `_onLoginSuccess` 不再传明文给 Session；`_login` 流程派生 BackupSeed 后丢弃密码 |
| `lib/views/authentication/set_passphrase.dart` | `_initKeyring` 成功后按新 `onPasswordSet` 签名调用 |
| `lib/views/change_passphrase.dart` | 末尾 `onPasswordSet` 传新密码（+ 旧备份需旧密码提示） |
| `lib/models/biometric_auth.dart` | `setAuthKey({required String password})` 显式传参；读旧明文兼容保留；（可选）wrap key 硬件化 |
| `lib/sync/sync_service.dart` | 删除三处 `passphraseProvider` 注入；`initKeyringFromPassword` 内派生 BackupSeed 注入 PhraseHandler |
| `packages/core/lib/src/sync/sync_engine.dart` | 删除 `passphraseProvider` 参数与消费；场景 c/d 分支统一 `requiresRelogin: true` |
| `packages/core/lib/src/sync/sync_models.dart` | `SyncEngine` 构造签名同步（若参数在 engine 而非 service） |
| `lib/utils/scheduled_task.dart` | `unitBackupAttempt` 判空改 `backupSeed == null`；三平台备份传 BackupSeed |
| `lib/models/file_handler.dart` | `encryptedOutputBackupContent` 改收 BackupSeed；`_resolveEncryptedRecords` 先试 BackupSeed 后弹框 |
| `packages/core/lib/src/models/backup_file.dart` | `encodeEncrypted` 升级为两层派生（formatVersion=2）；新增 `encodeEncryptedFromSeed`（自动备份用）；`decryptEncrypted` 按 formatVersion 分流 |
| `packages/core/lib/src/models/parse_import.dart` | `BackupHeader` 允许 `formatVersion = 2`（仅校验上限，无新字段） |
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
   - 独立备份口令（自定义口令）v2 导出/导入往返；
   - 同步：移除 passphraseProvider 后 scenario-b / 场景 c 均 `requiresRelogin: true`；场景 d 重登可解锁（`unlockFromRemoteManifest` 路径）。
3. `flutter test` 回归：登录（密码+指纹）、设置/改密码、生物认证开关、自动备份、导入（v1/v2/独立口令）。
4. CLI 端到端：v2 导出 → 同机/他机导入；v1 文件导入；明文导出导入。
5. 手动验证：登录后 `PhraseHandler.getPass` 已不可访问（编译期删除）；日志无任何密码值。

## 11. 明确不做的事（范围外）

- 不消除「用户输入阶段」的临时明文（输入框/表单，不可避免且一次性）。
- 不防「能 dump 进程内存的攻击者」拿到派生密钥（MK/dataKey/BackupSeed/笔记明文，技术不可行）。
- 不做生物认证 wrap key 的硬件化（原生工作量，列为可选增强）。
- 不改变同步协议（固定 salt 不涉及任何协议字段）。
- 不为「跨用户预计算」引入 per-vault 随机 seedSalt（方案乙）：收益被第二层独立 salt 稀释，复杂度不成比例。

---

*变更记录：2026-08-10 初稿。基于对话推演：确认 dataKey/MK 均会随同步迁移变化（C1/C2）→ 生物认证维持存「密码包裹态」；确认备份密钥不能依赖当前密钥状态（C4）→ BackupSeed 独立派生链。2026-08-10 修订：经用户指出 vaultId 是本地 UUID、无法跨未同步设备复现，否决「backupSeedSalt 由 vaultId 派生」（方案甲 v1），改为**固定常量 salt**（方案甲 v2），备份格式仅 bump formatVersion 至 2、无新增字段；并查证 Windows secure storage 实现（.secure 文件 = AES-GCM 密文，密钥存 Credential Manager），补充 §8.4 威胁模型。2026-08-16 修订（对齐现状代码）：§0 改为「整份提案未实施」完整状态框；全文行号引用改为符号引用；§4.4 由「两层 PBKDF2 200k」修订为对齐 Argon2id 迁移（第一层走 `deriveKeyFromKdf` 派发）；新增「演进负担」说明与可选 `seedKdf.*` 头字段；§6.1/§6.2/§8.3 相应更新。*
