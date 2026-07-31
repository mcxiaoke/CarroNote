# Joplin 同步协议 vs SafeNotes 同步协议对比分析

> 调研对象：`F:\Develop\github\joplin-sync-lib`（社区从 `@joplin/lib` 提取的 TypeScript 库，非官方，单人维护，未发 npm）
> 对比基准：SafeNotes 同步协议 v2（`docs/sync-protocol-spec.md`，实现 `lib/sync/`，约 5900 行 Dart，167 个测试含 5 seed 混沌测试全绿）
> 结论先行：**不建议改用 Joplin，继续自研协议；可借鉴 3 个具体机制**（见 §五）。

---

## 一、两个协议的根本设计差异

| 维度 | Joplin | SafeNotes |
|------|--------|-----------|
| **同步协调点** | 无全局索引，每个 item 一个远端文件 `{32位hexID}.md` | 单一 `manifest.json`（整体加密）+ 内容寻址 `blobs/<hash>` |
| **变更检测** | `delta()` API；无原生 delta 的后端用 `basicDelta`：列举全部文件 stat、按 `updated_time` 排序、返回大于上次同步时间戳的项 | manifest ETag 乐观锁：一次 GET 拿到全量状态，本地三方比对（local/base/remote） |
| **并发控制** | 锁文件协议：`locks/{type}_{clientType}_{clientId}.json`，Sync 锁（共享）+ Exclusive 锁（独占），TTL 3 分钟、60s 自动续期 | `If-Match` ETag，412 冲突后重拉重试，无锁文件 |
| **冲突解决** | 官方：note 建 Conflict 副本文件夹、resource 二选一；此库：只返回 `"conflicted"` 状态推给调用方 | LWW（updatedAt 决胜）+ 引擎内建冲突副本保留（E1/R6 路径），已被混沌测试验证 |
| **删除传播** | 远端 id 列表与本地全量 id 做差集推断删除（官方有"90% 删除 fail-safe"，此库中被注释掉） | manifest 内显式墓碑（`deleted: true`），无需推断 |
| **元数据隐私** | **明文泄露**：`id、parent_id、updated_time、type_、share_id` 等字段不加密，远端可见笔记数量、层级结构、修改时间线 | manifest 整体 AES-GCM 加密，远端只见一个密文文件 + 若干 hash 命名的 blob，仅泄露 blob 数量与大小 |
| **时钟依赖** | 强依赖时间戳：`basicDelta` 和冲突判定都基于 `updated_time` 与远端时钟（`remoteDate()` 测偏移来补偿） | 弱依赖：LWW 用 updatedAt 决胜但正确性不依赖时钟（hash 比对兜底），版本协调靠 ETag/keyVersion 而非时间 |

**本质区别**：Joplin 是"**文件级增量同步**"（类似 rsync 思路，适合大量小文件、无索引），SafeNotes 是"**快照式清单同步**"（类似 git 思路，单点真相 + 内容寻址）。前者单条笔记同步流量小、但一致性靠时间戳和锁拼出来；后者每次同步要传整个 manifest、但一致性由乐观锁数学保证，且天然抗时钟漂移。以我们目前的规模（几十~几千条笔记，manifest 10KB 级），快照式明显更简单可靠。

---

## 二、E2EE 加密对比（差距最大的部分）

| 维度 | Joplin | SafeNotes |
|------|--------|-----------|
| 密钥模型 | Master Key 列表（`info.json` 内含 `masterKeys[]`、`activeMasterKeyId`、RSA-2048 ppk），MK 用密码派生密钥加密 | 两层：`MK = PBKDF2-HMAC-SHA256(password, salt, 200k)` → 包裹 32 字节随机 `dataKey`；dataKey 永不因改密码变化 |
| 加密算法 | SJCL 系列（AES-CCM/OCB2 遗留方法，官方近年新增 Custom 方法）；**此库的 EncryptionService 是空壳**（encryptString 直接返回明文，base64 假加密） | AES-256-GCM 全程，AAD 绑定（v2 AAD=hash） |
| 改密码 | 需 Exclusive 锁 + 官方客户端重新加密流程；此库完全不支持 | 仅重包 dataKey（`keyVersion+1`，数据零重写），旧 wrappedDataKey 归档到 dataKeyHistory；混沌测试已验证乱序改密收敛 |
| 密钥纪元 | 仅 item 级 `master_key_id` 指针 | 三级：`keyVersion`（改密）/ `dataKeyEpoch`（dataKey 真轮换）/ `blobKeyEpoch`（per-item 现代化标记）+ repair 通道 |
| 加密粒度 | item 正文加密，但元数据字段白名单明文上传 | 笔记 blob 全密文 + manifest 全密文 + 本地 DB 字段级加密 |

结论：我们的加密设计**全面优于** Joplin（尤其零知识程度和改密码成本）。joplin-sync-lib 的 E2EE 更是 stub，若要真密文互通必须回官方仓库抠 SJCL 实现——毫无必要。

---

## 三、"直接用 Joplin" 的可行性评估

**不可行，三个硬伤：**

1. **语言不通**：joplin-sync-lib 是 TypeScript/Node.js（依赖 fs-extra、Node crypto/Buffer），无法在 Flutter/Dart 运行。嵌入 JS 引擎（flutter_js 等）来跑同步核心是灾难性架构。
2. **它不是完整同步引擎**：定位是"远端存储客户端"（Storage API），本地状态跟踪（sync_time 表）、冲突副本、E2EE 全要调用方自建；官方 Conflict folder 机制在此库只剩注释。
3. **数据模型硬耦合**：`.md` 序列化格式、`type_` 枚举、字段白名单全绑死 Joplin schema，我们的 SafeNote（title/description/uuid/contentHash）套不进去。

**改用官方 Joplin 协议（自己用 Dart 重写）也不划算**：需要实现锁协议、basicDelta、`.md` 序列化、SJCL 兼容加密，工作量远超现有协议，换来的却是更弱的元数据隐私和更强的时钟依赖。我们的协议已有 167 个测试（含 3 客户端 × 120 步 × 随机改密混沌测试）背书。

---

## 四、Joplin 做得比我们好的地方（客观承认）

1. **单条笔记同步流量**：改一条笔记只传一个小文件；我们要重传整个 manifest（当前 10KB 级无所谓，十万条笔记时 manifest 会到 MB 级）。
2. **后端生态**：OneDrive/GoogleDrive/Dropbox/S3/Joplin Server 都有 Driver；我们只有 localFs/WebDAV/SafeServer。
3. **附件（resource）体系**：`.resource/` 目录 + blob 分离下载策略成熟；我们尚无附件同步。
4. **exclusive 锁保护关键迁移**：sync target 版本升级、开启 E2EE 时用独占锁挡住其他客户端，比"事后发现纪元不匹配再协调"更主动。
5. **远端时钟偏移探测**：`remoteDate()` 上传临时文件测偏移，值得留意（虽然我们对时钟依赖弱）。

---

## 五、可借鉴清单（按优先级）

| # | 借鉴点 | 说明 | 建议 |
|---|--------|------|------|
| 1 | **删除 fail-safe** | Joplin 官方：一次同步若要删除超过 90% 的本地笔记则中止并报警（防止远端被清空/换库导致本地数据全灭） | **值得立刻加**：在 SyncEngine 应用远端墓碑/缺失前加阈值检查（如单次删除 > 50% 且 > 10 条则要求用户确认）。成本低、救命价值高 |
| 2 | **Exclusive 锁用于 dataKey 轮换** | 未来若实现 `dataKeyEpoch+1` 的真密钥轮换（全量重加密），迁移窗口期用锁文件（带 TTL）挡住其他客户端，避免半迁移状态被并发写入 | 记入设计储备，实现真轮换时采用；日常同步继续走 ETag 无锁 |
| 3 | **manifest 分片预案** | Joplin 的 per-item 文件布局提示了扩展路径：若 manifest 过大，可按 uuid 前缀分片（`manifest-00.json`…）+ 一个小根索引，保留 ETag 语义 | 仅当用户量级达到万条笔记再考虑，现在不动 |
| 4 | 附件同步的 `.resource/` 分离模式 | 附件 blob 与笔记 blob 分目录、支持"按需下载" | 未来做附件功能时参考 |

---

## 六、最终建议

- **继续自研协议**。SafeNotes 协议在零知识、改密码成本、时钟无关性、可测试性上全面占优，且刚通过重型混沌测试验证。
- **不引入 joplin-sync-lib**（语言不通 + E2EE 空壳 + 非官方低成熟度），也不迁移到 Joplin 官方协议（隐私倒退 + 重写成本）。
- **短期落地一项**：删除 fail-safe（§五 #1），这是 Joplin 十年实战沉淀出的防灾机制，我们的协议目前没有等价保护。
