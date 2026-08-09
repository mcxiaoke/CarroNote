# Manifest 文件格式规范（上传到服务端的密文）

> 适用范围：本文件描述 SafeNotes 同步引擎上传到远端后端（SafeServer / WebDAV /
> LocalFs）的 **manifest 文件** 的二进制与 JSON 格式。
>
> 权威实现：`packages/core/lib/src/sync/sync_models.dart`
> （`Manifest` / `ManifestHeader` / `ManifestItem` / `ManifestCrypto`）。
> 协议 schema 版本常量：`kManifestSchemaVersion = 5`。
>
> 关联的其它格式规范：
> - blob 格式见 [spec-blob.md](spec-blob.md)
> - journal 格式见 [spec-journal.md](spec-journal.md)

---

## 1. 角色与设计动机

manifest 是同步的"索引/目录"：每条笔记只占一条**不含内容**的元数据，
笔记正文以独立 blob 形式按内容哈希寻址存储（见 spec-blob.md）。
多端通过合并 manifest 决定需要上传/下载哪些 blob。

设计要点：

- **header 明文**：新设备加入时无需 `dataKey` 即可读取 header，从中拿到
  `encryptedDataKey`、KDF 参数和密钥纪元，用密码派生 `MK` 解开
  `encryptedDataKey` 得到 `dataKey`，再解密 items。这是多端 join 的关键。
- **items 加密**：笔记元数据虽不含内容，但仍用 `dataKey` 加密，
  以防泄露笔记数量与更新模式。
- **KDF 参数随 header 传播**：per-vault 随机 salt 写入 header，新设备按相同
  salt + 相同密码派生出相同的 `MK`，实现跨设备一致（同时跨用户盐不同，
  使预计算彩虹表失效）。
- **密钥纪元三元组**（`keyFingerprint` / `keyVersion` / `dataKeyEpoch`）：
  用于检测他端改密码、防止"翻转战争"。

---

## 2. 二进制容器布局（v5 容器）

manifest 在线上是以 **v5 二进制容器** 形式存储的（`ManifestCrypto.serialize` 产出）。
布局如下：

```
 0         4        6        8        12
 ┌─────────┬────────┬────────┬────────┬──────────────┬──────────────┬──────────────┐
 │  magic   │fileVer│schemaV │headerLen│    header    │     items    │    pubHash   │
 │  4 字节   │ 2 字节 │ 2 字节 │ 4 字节  │   明文 JSON   │  AES-GCM 密文 │   SHA-256 32B │
 └─────────┴────────┴────────┴────────┴──────────────┴──────────────┴──────────────┘
                                          │                │                │
                                          ▼                ▼                ▼
                                    UTF-8 JSON      AES-256-GCM       SHA-256(容器[0, pubHash起点))
                                                   (dataKey,           覆盖除 pubHash 外的
                                                    AAD='manifest-items') 全部字节
```

### 2.1 各字段说明

| 偏移 | 字段        | 长度  | 编码        | 说明                                                          |
|------|-------------|-------|-------------|---------------------------------------------------------------|
| 0    | `magic`     | 4 B   | ASCII       | 容器家族标识：`'SMNT'`（0x53 0x4D 0x4E 0x54），不带版本数字 |
| 4    | `fileVer`   | 2 B   | 大端 uint16 | 文件级容器布局版本，当前固定为 `1`，与 `schemaVersion` 解耦   |
| 6    | `schemaV`   | 2 B   | 大端 uint16 | 协议语义版本，等于 `header.schemaVersion`                    |
| 8    | `headerLen` | 4 B   | 大端 uint32 | `header` 明文 JSON 的字节长度                                |
| 12   | `header`    | 变长  | UTF-8 JSON  | 明文头部（见 §3）                                            |
| …    | `items`     | 变长  | AES-GCM 密文| `AES-256-GCM(dataKey, AAD='manifest-items', items JSON)`（见 §4）|
| 末尾 | `pubHash`   | 32 B  | 原始字节    | `SHA-256(容器 [0, pubHash 起点) 的全部字节)`，无密钥损坏校验 |

- 固定头总长度 = 4 + 2 + 2 + 4 = **12 字节**。
- 最小合法文件长度 = 12（`_kFixedHeaderLen`）+ 32（`_kPubHashLen`）= **44 字节**。
- `pubHash` 覆盖从文件开头到 `pubHash` 起点（即 `header + items` 之后）的全部字节，
  **不含密钥**，用于区分"数据损坏"与"密钥不匹配"两类失败（见 §6）。

### 2.2 编解码细节（来自 `ManifestCrypto`）

- 整数一律 **大端（big-endian）** 编码。
- `pubHash` 校验使用**常量时间**字节比较（`_constTimeEquals`），防时序侧信道。
- 序列化顺序（`serialize`）：
  1. `header` → `jsonEncode` → UTF-8 字节；
  2. `items` → `jsonEncode({ 'items': {...} })` → UTF-8 字节 →
     `SyncCrypto.seal(dataKey, 'manifest-items', itemsBytes)`；
  3. 拼接固定头 + header + items；
  4. `pubHash = SHA-256(前缀)`；
  5. 返回 `固定头 ‖ header ‖ items ‖ pubHash`。

---

## 3. header（明文 JSON）

字段（`ManifestHeader.toJson`）如下。方括号 `[]` 表示**仅当非空/非 null 时才出现**
（条件字段，缺失时由 `fromJson` 给默认值）。

| 字段                | 类型    | 必含 | 说明                                                                       |
|---------------------|---------|------|----------------------------------------------------------------------------|
| `schemaVersion`     | int     | 是   | 协议语义版本，当前 = `5`（`kManifestSchemaVersion`）                      |
| `version`           | int     | 是   | manifest 版本号，每次成功 PUT 后 +1；调试用，非乐观锁依据（ETag 才是）   |
| `vaultId`           | string  | 是   | keyring 唯一标识（UUIDv4），所有设备共享同一 vaultId                       |
| `createdAt`         | int     | 是   | keyring 创建时间（Unix 毫秒）                                             |
| `updatedAt`         | int     | 是   | manifest 自身更新时间（Unix 毫秒）                                        |
| `keyFingerprint`    | string  | 是   | `H(MK)`（SHA-256 指纹），跨设备一致；用于检测他端改密码                    |
| `keyVersion`        | int     | 是   | 密钥版本号，单调递增（`createNew=1`，改密码 +1）                           |
| `encryptedDataKey`  | string  | 是   | 用 MK 加密后的 `dataKey`，base64 字符串；改密码时只更新此字段             |
| `kdf`               | object  | 是   | KDF 参数（见下）                                                          |
| `dataKeyWrap`       | string  | 是   | dataKey 包装算法，当前为 `'AES-256-GCM'`                                  |
| `dataKeyEpoch`      | int     | 是   | dataKey 纪元（v4 后仅作审计/元数据，不再驱动同步）                        |
| `dataKeyFingerprint`| string  | 否   | `H(dataKey)`（SHA-256 指纹），自描述当前 dataKey 身份                      |
| `dataKeyCreatedAt`  | int     | 否   | 当前 dataKey 创建时间（Unix 毫秒）                                        |
| `dataKeyCreatedBy`  | string  | 否   | 当前 dataKey 创建设备 ID                                                   |
| `lastModifiedBy`    | string  | 是   | 最后修改此 manifest 的设备 ID（如 `'android-xxx'`）                       |

`kdf` 子对象（`KdfParams.toJson`）：

| 字段        | 类型   | 说明                                         |
|-------------|--------|----------------------------------------------|
| `algorithm` | string | KDF 算法，当前为 `'PBKDF2-HMAC-SHA256'`      |
| `salt`      | string | PBKDF2 salt，base64（`per-vault` 随机 16 字节）|
| `iterations`| int    | PBKDF2 迭代次数，当前为 `200000`             |

示例（来自源码文档注释，字段名一致）：

```json
{
  "schemaVersion": 5,
  "version": 42,
  "vaultId": "uuid-xxx",
  "createdAt": 1719470000000,
  "updatedAt": 1719470000000,
  "keyFingerprint": "hex(MK)",
  "keyVersion": 1,
  "encryptedDataKey": "base64...",
  "kdf": {
    "algorithm": "PBKDF2-HMAC-SHA256",
    "salt": "base64(per-vault-random)",
    "iterations": 200000
  },
  "dataKeyWrap": "AES-256-GCM",
  "dataKeyEpoch": 1,
  "dataKeyFingerprint": "hex",
  "lastModifiedBy": "android-xxx"
}
```

---

## 4. items（加密 JSON）

外层结构为 `{ "items": { <uuid>: <item>, ... } }`。整个对象用
`AES-256-GCM(dataKey, AAD='manifest-items', itemsJsonUtf8)` 加密，
online 上是 §2 容器中的 `items` 密文段。

每条 item 的字段（`ManifestItem.toJson`）：

| 字段                | 类型    | 必含 | 说明                                                                          |
|---------------------|---------|------|-------------------------------------------------------------------------------|
| `hash`              | string  | 是   | 笔记内容的 SHA-256 哈希（十六进制），同时是 blob 的**文件名/键名**           |
| `deleted`           | bool    | 是   | 是否已软删除（墓碑标记）                                                      |
| `updatedAt`         | int     | 是   | 最后更新时间（Unix 毫秒），用于 LWW 冲突解决                                  |
| `updatedBy`         | string  | 是   | 最后修改此笔记的设备 ID，明文                                                 |
| `createdAt`         | int     | 是   | 笔记创建时间（Unix 毫秒）                                                     |
| `deletedAt`         | int     | 否   | 软删除时间（Unix 毫秒），null 表示未删除                                      |
| `contentSize`       | int     | 是   | 笔记内容大小（payload JSON 字节长，含 `"v"` 字段）                            |
| `blobKeyEpoch`      | int     | 是   | blob 密钥纪元（v4 后为"加密版本标签"纯审计元数据）                            |
| `dataKeyFingerprint`| string  | 否   | 加密该 blob 的 dataKey 指纹（精确区分"旧 key"与"真损坏"）                     |
| `createdBy`         | string  | 否   | 创建此笔记的设备 ID                                                           |
| `dataKeyCreatedAt`  | int     | 否   | 加密该 blob 的 dataKey 创建时间                                               |
| `dataKeyCreatedBy`  | string  | 否   | 加密该 blob 的 dataKey 创建设备 ID                                            |

> 注意：item 的 `hash` 是**逻辑内容身份**（由 `title + "\n" + description` 计算，
> 见 safenote.dart `computeHash`），与 blob payload 字节不同域。二者多对一，
> 天然去重。`ContentSize` 是 payload 字节长，与 hash 是不同维度。

---

## 5. 信封加密算法（AES-256-GCM）

manifest items 信封采用与 blob 一致的 AES-256-GCM 方案（见 spec-blob.md §3），
仅 AAD 不同：

- 算法：`AES-256-GCM`（`AesGcm.with256bits()`）。
- 信封格式：`nonce(12) ‖ ciphertext ‖ tag(16)`，其中 tag = 16 字节认证标签。
- AAD（附加认证数据）：固定常量 `'manifest-items'`。
- nonce 为每次加密随机生成的 12 字节（`SyncCrypto.generateNonce`）。
- 解密时同一把 `dataKey` + 同一 `AAD` 才能通过 GCM tag 校验。

---

## 6. 解析与验证（三阶段）

`ManifestCrypto.deserialize` / `deserializeHeaderOnly` 通过 `_parseAndVerifyContainer`
做三阶段校验，把"损坏"与"密钥不匹配"两类失败**一次性区分开**：

1. **结构校验**：文件长度 ≥ 44 字节；`magic == 'SMNT'`；`fileVer == 1`；
   `headerLen` 不能让 items 起点越过 pubHash 起点；固定头 `schemaV` 与
   `header.schemaVersion` 一致。
   - 失败 → 抛 `ManifestAuthException`（结构/数据损坏类）。
2. **损坏校验（无密钥）**：`pubHash == SHA-256(容器 [0, pubHash 起点))`。
   - 失败 → 抛 `ManifestAuthException`（位翻转 / 截断 / 半写）。
3. **密钥校验**：用 `dataKey` + AAD 解密 items。
   - GCM 失败（`SyncDecryptionException`）→ 抛 `ManifestKeyMismatchException`
     （pubHash 已通过 ⇒ 数据未损坏，是密钥不匹配 / 旧密钥数据）。

此外，下载侧由 `SyncEngine._checkSchemaVersion` 做**协议降级拒绝**：
若 `header.schemaVersion < kManifestSchemaVersion`（当前 5），拒绝解读、
不迁移、不覆盖，返回"远端使用旧版协议，请升级全部设备"的提示。

### 6.1 异常契约（上层分流）

| 异常                              | 触发条件                          | 上层流向                         |
|-----------------------------------|-----------------------------------|----------------------------------|
| `FormatException`                 | 数据过短（< 44 字节）             | 统一恢复编排（§7）               |
| `ManifestAuthException`           | magic/fileVer/headerLen 非法 或 pubHash 失败 | 统一恢复编排（数据损坏） |
| `ManifestKeyMismatchException`    | pubHash 通过但 items GCM 失败     | scenario-b 密钥/迁移流程         |

---

## 7. 版本历史

协议 schema 版本演进（见 `sync_models.dart` 顶部注释）：

- **v1**：初始（历史上 `schemaVersion` 从未被真实写入，恒默认 1）。
- **v3**：移除遗留兼容，blob 仅支持 `AAD = hash`（纸面版本）。
- **v4**：epoch 消除——blob 纯化 AAD=hash，新增 item/header 自描述元数据
  （`dataKeyFingerprint` / `createdBy` / `dataKeyCreatedAt` / `dataKeyCreatedBy`）。
- **v5（当前）**：可靠性容器重构——manifest 二进制容器加入
  `magic 'SMNT' + fileVer + schemaV` 固定头 + 尾部无密钥 `pubHash`（SHA-256）
  损坏校验，彻底区分"数据损坏"与"密钥不匹配"，并新增具名异常替代"全靠 GCM 抛错再猜"。
  不兼容旧 v4 二进制（开发中未发布，已废弃重建）。

> 所有新写出的 manifest 显式写入 `kManifestSchemaVersion`（如 `Manifest.empty`、
> `_buildLocalManifest`、repair），不再是"从不真实写入、恒默认 1"。

---

## 8. 远端存放位置

由后端实现决定 manifest 的远端路径，客户端不关心路径前缀的具体形式：

- SafeServer：`PUT /api/v2/manifest`（带 `If-Match`/`If-None-Match` 乐观锁，
  必须返回 `ETag`）。
- WebDAV / LocalFs：`manifest` 文件（单用户 keyring 根目录）。

manifest 还由后端产生代际备份（如 `manifest-backup/manifest.bak-*`）与
损坏隔离（`.corrupt-<ts>`），这些是后端侧运维结构，不影响本格式规范。
