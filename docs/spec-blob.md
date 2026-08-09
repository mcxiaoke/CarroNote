# Blob 文件格式规范（上传到服务端的密文）

> 适用范围：本文件描述 SafeNotes 同步引擎上传到远端后端的 **blob 文件** 格式。
> blob 是笔记正文的密文载体，按内容哈希内容寻址（文件名/键名 = 内容哈希）。
>
> 权威实现：
> - 加密/解密：`packages/core/lib/src/crypto/crypto.dart`（`SyncCrypto.seal` / `open`）
> - payload 序列化：`packages/core/lib/src/models/safenote.dart`（`toContentBytes` / `fromContentBytes` / `computeHash`）
> - 内容哈希：`SyncCrypto.contentHash` / `hashString`
>
> 关联格式规范：
> - manifest 格式见 [spec-manifest.md](spec-manifest.md)
> - journal 格式见 [spec-journal.md](spec-journal.md)

---

## 1. 角色与设计动机

- **内容寻址**：每个 blob 的文件名/键名就是笔记正文的 SHA-256 哈希
  （十六进制 64 字符）。相同内容的两条笔记共享同一 blob，实现**天然去重**。
- **纯数据、无元数据**：blob 里**只装笔记正文**，不含 uuid、时间戳等元数据；
  这些元数据放在 manifest 的 item（`hash` / `updatedAt` / `deleted` …）里。
- **blob 纯化（v4 epoch 消除）**：blob 信封的 AAD 恒为裸 `id`（内容哈希），
  **不再携带 epoch**。解密只问"dataKey 对不对"——能解开即当前 key，解不开即
  "非当前 key 或损坏"，epoch 不参与判定，避免"同 key 解不开"的假性失败放大器。

---

## 2. 内容哈希（blob 寻址键）

blob 的文件名/键名 = 笔记内容的 SHA-256 哈希（十六进制字符串，64 字符）。

计算方式（`SafeNote.computeHash`）：

```dart
hash = SHA-256( title + "\n" + description )
     = SyncCrypto.hashString('$title\n$description')
```

- 哈希输入是 `title` 与 `description` 用 `"\n"` 拼接后的 UTF-8 字节。
- 该哈希是**逻辑内容身份**，与 blob 存储字节（payload 含 `"v"` 字段）属不同域。
- **已知非单射**：`"A\nB" + "C"` 与 `"A" + "B\nC"` 的哈希相同（概率极低，
  改动牵连面广，保留现状）。这不影响寻址正确性，仅理论边界。
- 相同明文必然产生相同哈希，与加密 nonce 无关 → 去重有效。

远端路径/键名由后端拼接（例如 SafeServer `PUT /api/v2/blob/<hash>`）。

---

## 3. 信封加密算法（AES-256-GCM）

blob 是一个**纯 AES-256-GCM 信封**，不附加任何长度前缀、magic 或版本头。
整个 blob 文件就是信封字节。

### 3.1 信封布局

```
 0            12               len-16    len
 ┌────────────┬─────────────────────┬──────────┐
 │   nonce    │      ciphertext     │   tag    │
 │  12 字节   │     变长（明文长）   │  16 字节  │
 └────────────┴─────────────────────┴──────────┘
```

| 段         | 长度  | 说明                                                |
|------------|-------|-----------------------------------------------------|
| `nonce`    | 12 B  | AES-GCM 推荐 12 字节随机 nonce（`SyncCrypto.generateNonce`）|
| `ciphertext`| 变长 | 明文 payload 的密文                                |
| `tag`      | 16 B  | AES-GCM 认证标签（GCM mac）                         |

- 算法：`AES-256-GCM`（`AesGcm.with256bits()`）。
- 密钥：固定的 32 字节 `dataKey`（所有笔记共用同一把；`dataKey` 永不变化，
  仅改密码时 `encryptedDataKey` 用新 `MK` 重新包裹）。
- **AAD（附加认证数据）**：笔记内容的 SHA-256 哈希（即 blob 文件名/键名）。
  即 `AAD = id = contentHash`。用同一 `dataKey` + 同一 `id` 才能通过 GCM 校验。
- 信封拼接顺序（`SyncCrypto._aesGcmEncrypt`）：`nonce ‖ ciphertext ‖ tag`
  （与旧的 pointycastle 格式一致，cryptography 库间互操作）。

### 3.2 加解密 API

```dart
// 加密：id = contentHash（内容寻址），plaintext = payload 字节
Uint8List envelope = await SyncCrypto.seal(dataKey, id, payloadBytes);

// 解密：id 必须与加密时一致（即同一 contentHash）
Uint8List payloadBytes = await SyncCrypto.open(dataKey, id, envelope);
```

- 解密失败（密钥不匹配 / AAD 不符 / 数据损坏）统一抛 `SyncDecryptionException`
  （由底层 `SecretBoxAuthenticationError` 包装而来），上层用 `on SyncDecryptionException`
  精确捕获。

---

## 4. Payload（明文内容）

信封内包裹的明文 payload 是笔记正文经 JSON 序列化后的 UTF-8 字节
（`SafeNote.toContentBytes`）：

```json
{ "v": 2, "title": "...", "description": "..." }
```

| 字段         | 类型   | 说明                                                       |
|--------------|--------|------------------------------------------------------------|
| `v`          | int    | payload 版本号，当前 `2`。v=1 为无版本字段的旧格式（开发中未发布已废弃）。|
| `title`      | string | 笔记标题                                                   |
| `description`| string | 笔记正文                                                   |

- 身份与 payload 解耦：加 `"v"` 字段不影响已寻址的 blob（blob 文件名由
  `computeHash(title, description)` 决定，与 payload 字节无关）。
- `v` 字段用于未来格式判别；当前所有版本均只取 `title` / `description`。
- 反序列化（`SafeNote.fromContentBytes`）：`jsonDecode` 后只取
  `title` / `description`。

> `contentSize`（记在 manifest item 中）定义为 payload JSON 的**字节长**（含 `"v"`），
> 与"身份域"哈希解耦——payload 是存储表示，hash 是逻辑身份。

---

## 5. 完整数据流

```
SafeNote(title, description)
   │
   ├─ hash     = SHA-256(title + "\n" + description)      ← blob 文件名/键名
   ├─ payload  = JSON{"v":2,"title","description"}          ← 明文
   │
   └─ envelope = AES-256-GCM(                                ← blob 文件内容
                   key = dataKey,
                   nonce = random(12),
                   AAD = hash,
                   plaintext = payload)
                 = nonce(12) ‖ ciphertext ‖ tag(16)

上传：PUT <backend>/blob/<hash>   body = envelope
下载：GET <backend>/blob/<hash>   → envelope
```

---

## 6. 幂等性与去重

- blob 上传是**幂等**的：相同 `hash` 的 `PUT` 覆盖写同一文件（相同内容自然一致）。
- 内容寻址去重：两条内容相同的笔记 → 同一 `hash` → 同一 blob，无需重复存储。
- manifest item 的 `dataKeyFingerprint` / `blobKeyEpoch` 仅作**审计元数据**，
  不进入 blob 文件本身；解密失败时用于区分"旧 key 数据"（可提示修复）
  与"真损坏"（不可修）。

---

## 7. 远端存放位置

blob 的远端路径/键名形式为 `<hash>`（64 位十六进制），由后端实现决定前缀：

- SafeServer：`PUT /api/v2/blob/<hash>`，`GET /api/v2/blob/<hash>`，
  `DELETE /api/v2/blob/<hash>`（GC），`GET /api/v2/blobs`（列出全部 hash 用于 GC）。
- WebDAV / LocalFs：keyring 根目录下 `blobs/<hash>` 文件；孤儿隔离到
  `blobs-orphan/<hash>.<epochMs>`。

这些路径前缀与布局由后端资源层管理，不影响 blob 文件**自身**的字节格式
（blob 文件永远只有 `nonce ‖ ciphertext ‖ tag` 这一种内容）。
