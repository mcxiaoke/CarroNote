# PIN Lock 设计方案

时间：2026-08-18
状态：已评审，待实施
关联：`lib/models/biometric_auth.dart`（平行架构）、`lib/models/session.dart`、`lib/views/authentication/login.dart`、`lib/views/settings/`

## 1. 背景与目标

safenotes 现有「生物识别登录」（`BiometricAuth`）：把 vault 密码用随机包裹密钥封存进
`flutter_secure_storage`，解锁时通过设备生物识别放行后取回密码，复用现有
`_login(passphrase)` 流程。

需求：新增 **PIN Lock** 作为与生物识别**平行**的第二种解锁方式。

- 用户可在设置中独立启用/关闭 PIN（与生物识别互不依赖、可同时启用）。
- 启用 PIN 时选择长度：**4 / 6 / 8 位，默认 6 位**。
- 解锁走自定义数字键盘（非系统键盘，防输入法记录、防截屏、体验统一）。
- **连续失败达到阈值后自动关闭 PIN**，回退到要求输入原始 vault 密码。
- 数据层与键盘**预留字符集扩展**（当前仅数字，未来可支持字母+数字），不推翻数据结构。

## 2. 设计原则

1. **与 `BiometricAuth` 架构平行**：同样的「包裹密钥 + 信封」模式，同样的存储位置与
   生命周期联动点（`Session.login` / `Session.onPasswordSet`），代码心智负担最小。
2. **PIN 是低熵用户可猜值，绝不能直接当密钥**：必须经 KDF（Argon2id）派生后再使用；
   且必须配合**失败限流/关闭**机制，否则 4 位 PIN 可被离线穷举。
3. **解锁成功后完全复用现有登录链路**：PIN 验证通过 → 取回 vault 密码 →
   `_login(passphrase)`（keyring 解锁 / 远端验证逻辑一行不改）。
4. **数据层与 UI 解耦**：字符集、长度是「策略」而非「实现细节」，方便未来扩展。

## 3. 总体架构

```
┌─────────────┐   ┌──────────────┐   ┌──────────────┐   ┌──────────────┐
│ 自定义键盘    │ → │ PinAuth       │ → │ _login(      │ → │ Home         │
│ PinKeyboard  │   │ verifyPin(pin)│   │ passphrase)  │   │ Keyring 解锁  │
└─────────────┘   └──────────────┘   └──────────────┘   └──────────────┘
                        │
                        ├─ 失败：PinAuth.onFailed() → 计数 +1
                        │       达到阈值 → PinAuth.disable() + 提示密码登录
                        └─ 成功：计数清零，取回密码
```

与生物识别平行关系（登录页）：

| 生物识别 | PIN | 登录页行为 |
|---|---|---|
| 关 | 关 | 密码输入（现状） |
| 开 | 关 | 生物识别按钮（现状） |
| 关 | 开 | PIN 键盘 |
| 开 | 开 | 自动触发生物识别 → 失败回退 PIN 键盘 |

## 4. 存储设计（核心）

### 4.1 存储介质与密钥层次

全部存放于 `flutter_secure_storage`（系统级加密存储，与 `BiometricAuth` 一致）：

| key | 内容 | 说明 |
|---|---|---|
| `_securePinKdfKey` | `KdfParams` 的 JSON（明文，含随机盐） | 派生 PIN 密钥所需参数，盐非机密 |
| `_securePinEnvelopeKey` | `v1:<base64(nonce‖ct‖tag)>` | PIN 派生密钥 seal 的**包裹密钥** |
| `_securePinWrapKey` | base64(随机 32B)（明文） | 包裹密钥副本，用于改密码联动 |
| `_securePinAuthKey` | `v1:<base64(nonce‖ct‖tag)>` | 包裹密钥 seal 的 **vault 密码**（与 `BiometricAuth._secureBiometricAuthKey` 同构） |

信封格式与 `BiometricAuth` 完全一致：`v1:` 前缀 + AES-256-GCM 信封
（nonce 12B ‖ ciphertext ‖ tag 16B），AAD 域分隔符固定 `'pin-auth'`。

### 4.2 关键流程

**启用 / 修改 PIN**（用户已登录，内存中有 vault 密码）：
1. 生成随机包裹密钥 wrapKey（32B）与随机盐（16B），记录 `KdfParams`（Argon2id 默认参数）。
2. 用 wrapKey seal vault 密码 → `_securePinAuthKey`；wrapKey 明文备份 → `_securePinWrapKey`。
3. 用 PIN 派生密钥 seal wrapKey → `_securePinEnvelopeKey`。
4. 写入 `KdfParams`、打开 `PreferencesStorage.isPinAuthEnabled`。

**验证 PIN**：
1. 读 `KdfParams`，`deriveMasterKeyAsync(pin, kdf)` 派生 PIN 密钥。
2. 解开 `_securePinEnvelopeKey` → wrapKey。
3. 用 wrapKey 解开 `_securePinAuthKey` → vault 密码，返回。
4. 任一步失败（GCM tag 校验失败）→ PIN 错误。

**修改 vault 密码联动**（`Session.onPasswordSet`，无需 PIN）：
1. 若 PIN 已启用，读 `_securePinWrapKey`（明文副本）。
2. 用该 wrapKey 重新 seal 新密码 → 覆写 `_securePinAuthKey`。
   PIN 信封与 PIN 本身完全不变。

### 4.3 为什么包裹密钥要存明文副本（安全权衡）

PIN 信封保护的是「不知道 PIN 的人无法在应用内解锁」，包裹密钥副本受
`flutter_secure_storage` 的系统级保护（Keychain / Keystore / DPAPI）。该威胁模型与
`BiometricAuth._secureBiometricWrapKey` **完全同级**——项目已接受。换取的能力是：
改密码后无需 PIN 即可自动联动刷新凭据，避免「改一次密码就要重设一次 PIN」的体验
倒退。若未来要求防「secure storage 完全导出」级攻击，可把 wrapKey 改为
Keystore 不可导出密钥（Android）并放弃自动联动，属可演进的边界。

## 5. KDF 选型：Argon2id

- **算法**：复用 core 包 `SyncCrypto.deriveMasterKeyAsync`（按 `KdfParams` 自动派发），
  参数与 vault 主密钥一致：`ARGON2ID`，memory 32 MiB，t=3，p=2，输出 32B。
- **理由**：
  - 内存硬化（memory-hard），对 GPU/ASIC 暴力破解的抗性远强于 PBKDF2。
  - 项目已有该实现且 Windows 实测约 200–330ms，比 PBKDF2 200k 迭代（约 788ms）更快，
    登录延迟可接受（现有登录页已在使用同一派生）。
  - 零新增依赖，无新密码学原语引入。
- **盐**：PIN 信封独立随机盐（16B），不复用 vault 盐，避免跨用途预计算。
- **注意**：PIN 空间小（10⁴ ~ 10⁸），KDF 只能拖慢而非根除离线穷举，因此
  **失败关闭策略（§6）是 PIN 方案安全性的必要组成**，两者缺一不可。

## 6. 失败关闭策略

- **阈值**：连续失败 **5 次**（常量 `kPinMaxFailedAttempts`，未来可配置）。
- **计数**：`PreferencesStorage.pinFailedCount`，失败 +1、成功清零；开关关闭时清零。
- **达阈值行为**：
  1. `PinAuth.disable()`：删除全部 4 个 PIN 存储 key，关闭 `isPinAuthEnabled`。
  2. 登录页提示「PIN 已因多次尝试失败而关闭，请使用密码登录」，回退到密码输入。
  3. 用户之后可在设置页重新启用 PIN（重新设置）。
- **为什么是「关闭」而非「锁定一段时间」**：用户明确要求关闭 + 回退密码；且 PIN 被
  连续失败说明可能已泄露，关闭比临时锁定更安全。关闭后唯一入口是原始 vault 密码
  （keyring 解锁），不降低整体安全性。

## 7. UI 设计

### 7.1 设置页 `PinSetting`（新路由 `/pinSetting`）

- 列表项「PIN Lock」插入设置页 Security 卡片（生物识别之后）。
- 未启用：
  - 开关「Enable PIN Lock」。
  - 打开开关 → 弹出现场设置流程：选择长度（4 / 6 / 8 位，默认 6）→
    输入新 PIN（自定义键盘）→ 二次确认一致 → 完成启用。
- 已启用：
  - 显示当前长度与状态。
  - 「Change PIN」：先验证当前 PIN → 选择新长度 → 输入两次新 PIN。
  - 「Disable PIN Lock」：先验证当前 PIN → 确认后关闭。
- 开关/操作期间防并发（复用 `biometric_setting.dart` 的 `_isVerifying` 模式）。

### 7.2 登录页集成

- 启用 PIN 且未启用生物识别：`afterFirstLayout` 直接聚焦 PIN 键盘。
- 两者都启用：`afterFirstLayout` 先自动触发生物识别，失败回退 PIN 键盘。
- PIN 键盘区替代原「Biometric」按钮的位置；「Use passphrase」入口保留（现有
  `forcePassphraseInput` 挑战机制可复用）。
- 失败时显示剩余次数，达阈值按 §6 关闭并提示。

### 7.3 键盘 `PinKeyboard`

- 3×4 布局：1-9、空位、0、删除；可选随机布局（预留开关）。
- **字符集可配置**（`PinCharset` 枚举：`digits` 当前唯一；`alphanumeric` 预留）：
  数据层不感知字符集（只处理字符串），键盘按字符集渲染按键。
- 输入展示：`ShadInput`（`obscureText: true`，readOnly）或 `ShadInputOTP` + 自绘圆点。

## 8. 可扩展性预留

| 扩展方向 | 预留方式 |
|---|---|
| 字母+数字 PIN | `PinCharset` 枚举 + 键盘按字符集渲染；`PinAuth` 只收字符串，无需改动 |
| 更多长度 | `pinLength` 选项列表常量化（4/6/8） |
| 随机键盘防偷窥 | 键盘预留 `shuffle: bool` 开关 |
| 失败阈值可配置 | `kPinMaxFailedAttempts` 常量 |
| 未来换 KDF / 加参数 | 盐与参数存 `KdfParams` JSON，读取时自动派发（与 manifest 同机制） |
| wrapKey 提升为 Keystore 密钥 | §4.3 已说明边界，单点替换 |

## 9. 分步实施计划

1. **数据层**：`lib/models/pin_auth.dart`（`PinAuth`）+ `PinPolicy`（长度/字符集）
   + `PreferencesStorage` 增 `isPinAuthEnabled` / `pinLength` / `pinCharset` /
   `pinFailedCount`。
2. **会话联动**：`Session.login` / `Session.onPasswordSet` 增加 PIN 凭据刷新分支
   （与生物识别对称）。
3. **键盘**：`lib/widgets/pin_keyboard.dart`（字符集可配置）。
4. **登录页**：`login.dart` 增加 PIN 解锁分支与失败计数 UI。
5. **设置页**：`lib/views/settings/pin_setting.dart` + 路由注册 + 设置列表项。
6. **翻译**：`zh-CN.json` / `en-US.json` 补齐所有新文案。
7. **验证**：`dart format`（仅改动文件）→ `flutter analyze` → `dart test packages\core\test`
   → `flutter test` → `flutter build windows --debug`；变更记录写入
   `docs/CHANGES-YYYYMMDD.md`。

## 10. 安全边界与已知取舍

- PIN 是低熵凭据，KDF + 失败关闭只能把离线穷举成本推到「不划算」，无法根除；
  高级别威胁用户应使用强 vault 密码且不启用 PIN（设置页文案提示，同生物识别）。
- 包裹密钥明文副本存 secure storage：与生物识别同级威胁模型（§4.3）。
- PIN 信封与密码信封均带 GCM tag：任何位翻转都会导致验证失败，无静默错误路径。
- 日志只记录「失败次数 / 长度 / 是否启用」，绝不记录 PIN 明文或派生密钥。
