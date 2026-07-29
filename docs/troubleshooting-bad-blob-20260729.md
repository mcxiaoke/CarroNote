# 排查手记：坏 blob 导致单设备同步失败（2026-07-29）

> 类型：线上故障排查 + 协议缺陷修复（学习/复盘用）
> 环境：SafeNotes 多端同步（Windows 客户端 A / Android 客户端 B / 本地 WebDAV）
> 结论一句话：**这次失败与改密码、与 dataKey 无关，而是「内容寻址去重」与「blob 加密 AAD=uuid」在设计上自相矛盾**导致的协议级缺陷。

---

## 0. 前置知识（看懂本手记所需）

SafeNotes 同步是「两层密钥 + 内容寻址」结构：

```
密码(password)
  └─ MK = PBKDF2-HMAC-SHA256(password, per-vault-salt, 200k)   ← 改密码时变
       └─ encryptedDataKey = AES-GCM(MK, dataKey)             ← 存在 manifest 头
dataKey（随机 32 字节，改密码时【不变】）                       ← 真正加密笔记体

单条笔记 blob：
  文件名 = SHA256(标题\n正文)        ← 按「内容」寻址，内容相同则共用一个文件（去重）
  信封   = AES-GCM(dataKey, AAD, 明文)
  AAD    = ???  （旧协议绑 uuid，新协议绑 hash —— 这是本故障的命门）
```

- `ManifestItem.hash = H(明文 title/description)`，与 dataKey 无关。
- 合并判定「有无变化」只看 `hash`，所以**重加密本地笔记后 hash 不变 → 不会重传 blob**（这正是更早那次「InvalidCipherTextException 卡死所有客户端」的根因，已通过 Layer 1/2a/2b 解决）。

---

## 1. 问题现象

- 客户端 A（Windows）点同步 → 提示「有 **1 条**笔记因密钥不匹配未能同步」，结束进程再开依旧。
- 客户端 B（Android）同步正常、无提示，新加笔记也同步正常。
- 用户**没有动数据、没有改密码**，是旧的那个 vault（密码 `hello.5678`，远端 WebDAV `192.168.1.118:6065/safenotes-vault`）。
- 远端 manifest 共 33 条，其中 32 条 blob 正常；只有 1 条（`a7dddd50`）下载失败。

第一直觉「又是密钥/改密码问题」被**实测否定**——见第 3 节。

---

## 2. 排查原则：只读远端，绝不写

用户明确要求「不要动我那个 webdav 的数据」。整个诊断过程只发 `GET`：

1. 复制 A 的本地 SQLite 到 `temp/diagnose/`（副本，不动原库）：
   ```
   build/windows/x64/runner/Debug/.dart_tool/sqflite_common_ffi/databases/safenotes_sync.db
   ```
2. 用 Python + `cryptography` 库、只发 `HTTP GET`，**对比本地与远端**：
   - 从 A 的 `sync_meta` 读出 `kdf_salt` / `encrypted_data_key`；
   - 用密码 `hello.3333`(新) 和 `hello.5678`(旧) 分别派生 MK，解出 dataKey；
   - 下载远端 manifest（`GET /manifest`），用该 dataKey 解密头，校验 `keyFingerprint`/`keyVersion`；
   - 逐条下载 blob（`GET /blobs/<hash>`），用 dataKey + 对应 AAD 尝试解密。

> 关键纪律：**诊断脚本只读不写**，远端 blob 一个字节都不改，符合用户约束。

---

## 3. 关键认知：这不是密钥问题

| 检查项 | 结果 |
|---|---|
| A 本地 dataKey vs 远端 dataKey | ✅ **完全一致**（指纹相同，keyVersion=4，新密码可解） |
| 远端 32 条正常 blob | ✅ 全部可正常解密 |
| 坏条目 `a7dddd50`（Android 创建） | ❌ A 本地**无此笔记**，blob 解不开 |

→ **排除了 dataKey 不匹配**，问题聚焦到这一条 blob 本身。

---

## 4. 根因：一个文件，两种身份

继续深挖 `a7dddd50` 这个 blob：

- 它的 blob 文件名是 `90d1fe13ca5b2c510b58b2dcda75dd7303f6f47fa7f6fc8621e37623dca6f840`
  （即 `SHA256("android note 1\n...")`）。
- **Android 上有两条内容完全相同的笔记**：`f35fbbdd`（先上传）和 `a7dddd50`（后上传）。
- 因为 blob 按内容 hash 去重 → 两条笔记**共享同一个 blob 文件**。
- 但 blob 加密时的 **AAD 绑定的是 uuid**，且只在「上传者」那次封包时确定——这个 blob 是用 `f35fbbdd` 当 AAD 封的。

实测验证（决定性证据）：

```
用 AAD="f35fbbdd" 解 blob 90d1fe13 → ✅ 成功，内容 title="android note 1"
用 AAD="a7dddd50" 解 blob 90d1fe13 → ❌ InvalidTag（AAD 绑定的不是这个 uuid）
```

**矛盾本质**（ASCII 图）：

```
               内容相同
   note A ──────────────┐
   (uuid=f35f)          │
                         ▼
                   blob 90d1fe13  ← 文件名=contentHash（内容寻址，去重）
                   AAD = f35f     ← 但认证绑定的是「先上传者」的 uuid！
                         ▲
   note B ──────────────┘
   (uuid=a7dd)   B 用自己的 uuid 当 AAD 去解 → 永远 InvalidTag
```

- **A 有 `f35f` 没有 `a7dd`** → 下载 `a7dd` 用自己 uuid 解 → 永远失败；
- A 又没有 `a7dd` 的明文 → 既有的 Layer 2b 自愈（「用本机该 uuid 明文重传」）也接不住；
- **B 两条都有明文，从不下载** → 完全无感知。

> 一句话：**任何两条「内容相同」的笔记，都会让第二台没有先上传那条的设备踩坑。** 这是协议设计缺陷，与改密码无关，也与更早那个坏 blob 是**不同**的事故。

---

## 5. 修复方案（治本 + 治现有坏状态）

### 5.1 协议 v2：blob AAD 从 uuid 改为内容 hash

让「寻址」与「认证」统一到同一个维度（内容），自洽：

| 位置 | 旧 | 新 |
|---|---|---|
| 上传 `_uploadNote` | `SyncCrypto.seal(dataKey, note.uuid, …)` | `SyncCrypto.seal(dataKey, note.contentHash, …)` |
| 下载 `_downloadNote` | 直接用 `uuid` 当 AAD | 先试 `hash` 再回退 `uuid` |
| 冲突副本 `_preserveConflictCopy` | 同上 | 同上 |

下载兼容旧 blob 的「双重尝试」辅助（`sync_engine.dart`）：

```dart
Uint8List _openBlobEnvelope(String uuid, String hash, Uint8List envelope) {
  try {
    return SyncCrypto.open(_dataKey, hash, envelope);   // 新格式：AAD=内容hash
  } on Object {
    return SyncCrypto.open(_dataKey, uuid, envelope);   // 回退旧格式：AAD=uuid
  }
}
```

> **无需迁移数据**：你远端现存的全部旧 blob（AAD=uuid）在下载时靠回退分支照样能解，自愈会在某台设备用新协议重传一次后全网治愈。

**安全性不降级**：旧 AAD=uuid 原本防「服务器把 X 的信封挪给 Y」。改成 AAD=hash 后，由既有的 **M7 校验**接管——manifest items 本身是 dataKey 加密认证的（服务器改不了），下载后校验「解密内容 hash == manifest 记录 hash」，信封错位照样被抓住。

### 5.2 去重自愈：孪生笔记回退

即便有协议 v2，A 当下那个坏 blob 的旧 AAD 仍是 `f35f`，A 下载 `a7dd` 双重尝试仍会失败 → 需要「用内容相同的孪生明文」兜底。

- `database_handler.dart` 新增：
  ```dart
  Future<SafeNote?> readNoteByContentHash(String contentHash) async {
    // where: contentHash = ? AND deleted = 0, limit 1
  }
  ```
- `_handleDownloadFailure` 在「无该 uuid 明文」时，增加分支（顺序：同 uuid 明文 → 孪生明文 → 记 corrupt）：
  ```dart
  if (!remoteItem.deleted) {
    final twin = await database.readNoteByContentHash(remoteItem.hash);
    if (twin != null) {
      // 1) 以孪生内容 + 远端元数据，物化该 uuid 的笔记落地本地
      // 2) 用当前协议（AAD=hash）重传 blob，让所有设备都能解开
      actions.add(SyncAction(type: SyncActionType.heal, uuid: uuid, hash: remoteItem.hash,
        message: '共享 blob 旧格式解密失败，已用本机同内容孪生笔记自愈'));
      return remoteItem; // hash 不变（内容相同），保留远端条目即可引用重传后的 blob
    }
  }
  ```

### 5.3 自愈三态在合并 manifest 中的闭环

`_DownloadOutcome`（`_DownloadSuccess` / `_DownloadHealed` / `_DownloadFailed`）让 `_mergeAndTransfer` 在自愈时把合并后的 manifest 指向**修复后的 hash**，避免「好 blob 被当成孤儿 GC 删掉、坏 blob 仍被引用」的结构性缺陷（这是更早一次修复里踩过的坑，此处不复现）。

---

## 6. 验证（全部用本地 6090 WebDAV，未碰 192.168.1.118）

新增测试组「共享 blob」（含 1:1 复现线上故障的用例）：

- **旧格式孪生自愈**：两条内容相同笔记共享 blob、AAD 旧；无该 uuid 明文但有孪生 → 物化 + 重传，失败清零 ✅
- **新格式共享 blob**：AAD=hash，多设备均能以各自 uuid 解开 ✅
- **旧格式兼容下载**：旧 AAD=uuid 的 blob 在新客户端双重尝试下正常下载 ✅
- **端到端**：坏 blob 自愈后，第三台空白设备能正常下载到修复后的笔记 ✅

回归结果：

```
webdav_integration_test + multi_device + change_password   52/52 全过
sync_engine_test + vault_test + crypto_test + local_fs     79/79 全过
flutter analyze：无 error / 无 warning
```

变更日志见 `docs/CHANGES-20260729.md`（顶部）。

---

## 7. 经验总结（给后来人）

1. **「内容寻址去重」与「按身份认证（AAD=uuid）」天然矛盾**。只要 blob 文件名来自内容 hash，AAD 就必须也来自内容（或其派生），否则任何重复内容都会制造「幽灵坏 blob」。这是本次最根本的教训。
2. **先证伪再下结论**：第一直觉「又是密钥问题」，但实测 A 与远端 dataKey 完全一致，立即转向 blob 本身。诊断务必用只读脚本拿数据说话，而不是猜。
3. **「能解但内容不对」≠「密钥错误」**：M7 回归提醒我们，hash 不符必须走独立的 `skip` 分支，不能和自愈/失败混为一谈。
4. **兼容性靠「先新后旧双重尝试」**：改加密格式不必一次性迁移全量数据，下载时回退旧格式即可平滑过渡。
5. **自愈要分层**：同 uuid 明文 → 孪生明文 → 记 corrupt 重试。自愈条件从「同身份」放宽到「同内容」，才能覆盖「本机没这条笔记、但有等价的另一条」的场景。
6. **严守用户约束**：诊断只读远端、副本放 `temp/`，原始 WebDAV 数据零写入。

---

## 8. 相关文档

- `docs/CHANGES-20260729.md` —— 当日变更流水（含 Layer 1/2a/2b 与本次协议修复）
- `docs/sync-protocol-spec.md` —— 同步协议规范（blob AAD、manifest 结构、M7 校验）
- `docs/sync-feature-design.md` / `docs/simplified-sync-design.md` —— 同步总体设计
- `test/sync/webdav_integration_test.dart`（group：共享 blob）—— 可复现用例
- **Layer 3（`blobKeyEpoch` 显式标记）按用户要求暂缓**，待本次自测确认后实施。
