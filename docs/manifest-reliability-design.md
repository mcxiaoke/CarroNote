# Manifest 与 item/blob 可靠性增强设计（v5 容器 + pubHash 损坏检测 + 统一恢复编排）

> 调研时间：2026-08-03（初稿）
> 修订时间：2026-08-03 12:35（v5 容器重构）
> 修订时间：2026-08-03 13:20（并入 item/blob 格式评审，修正写侧原子性事实）
> 修订时间：2026-08-03 13:40（并入 HLC 升级方案备忘 §6.4）
> 修订时间：2026-08-03 14:00（§6.4 重构：网络时钟校准为首选方案，HLC 降级为备忘）
> 修订时间：2026-08-03 14:20（§6.4.1 时间源候选按用户实测更新：bytedance.com 主源）
> 修订时间：2026-08-03 14:35（§6.4.1 移除测速明细，去掉腾讯系，仅留候选域名列表）
> 修订时间：2026-08-03 14:56（按评审修订：删除 HMAC / MACkey 防篡改链路，仅保留无密钥
>   pubHash 损坏检测；前提收敛为「个人笔记只检测损坏、不做防篡改」+「开发中未发布，
>   不兼容旧代码与旧数据、不做迁移代码」）
> 修订时间：2026-08-03 15:23（外部 review 八项：HLC 编码改为 43+20 bit 塞入有符号 int64；
>   §5.4 净增 +8B 与"仅 headerLen 是长度前缀"；§6.4.1 统一"按序尝试、首个成功"、GC 措辞改
>   "网络真实时间"、补隐私/地域权衡与单调时钟平台缺口；magic 去数字改为 'SMNT'；§2.3 开销注明净增 40B）
> 修订时间：2026-08-03 16:40（按收益/成本评审重构：**移除 §6.4 网络时钟校准 + HLC 整块**
>   （LWW 维持墙钟）；**移除 §6.3 修订 1 注入式内容哈希**（改动牵连面广、收益不足，保留现状
>   仅在注释留笔）；journal 全保真化与文件改名标注为"暂不做"；新增 §11 实施约束清单
>   （异常调用点 / bak 循环语义 / PUT 成功判定），闭合此前识别的实现回归风险）
> 范围：评估当前 `manifest.json` 二进制格式与抗损坏能力，并同步评审 `ManifestItem` / blob
>   存储格式，给出 v5 整体可靠性增强方案。
> 结论先行：**不上 WinRAR 式前向纠错（FEC）**；重做 v5 容器格式（magic + 文件级版本 +
> 无密钥公开 SHA-256 `pubHash` 损坏校验），配合「统一恢复编排（re-GET → 验 pubHash 挑 bak →
> 本地重建）」+「写侧原子化」+「heal 路径补自描述字段」+「blob payload 加版本字段」。
> 威胁模型：个人笔记应用，**只检测损坏、不做防篡改**——不引入 keyed HMAC / MACkey；
> 开发中未发布，**不兼容旧代码与旧数据、不做迁移代码**。

---

## 0. 实施优先级总览

按"收益 ÷（成本 + 风险）"排序，实施时按此顺序推进。详见 §10 分阶段计划。

| 优先级 | 修改项 | 收益 | 成本 | 风险 | 依赖 |
|---|---|---|---|---|---|
| **P0** | §9 `writeRingBackup` 原子化 | 高（消除备份半写） | 极小 | 零 | 无，可独立先行 |
| **P0** | §5 v5 容器 + pubHash | 高（根治损坏误判 P0） | 中 | 需配套 §11.1 调用点改造 | — |
| **P1** | §6.3 修订 3 heal 路径补自描述字段 | 中（让 §5.3 密钥判据在 heal 路径生效） | 小 | 零 | 配套 §5 |
| **P1** | §7 统一恢复编排 | 中（损坏后自动恢复） | 低 | 需明确 §11.2 bak 循环语义 | 依赖 §5 |
| **P2** | §6.3 修订 4 blob payload 加 `v` 字段 | 低（未来保险） | 小 | 零 | 搭车 §5 |
| **P2** | §6.3 修订 2 内容寻址语义注释 | 低（可读性） | 极小 | 零 | 搭车 §5 |
| 暂不做 | §8.3 journal 全保真化 | 中（终极自愈） | 高 | 中 | — |
| 暂不做 | §10 阶段 7 文件改名 / 去 `.json` | 低 | 小 | 破坏存量布局 | — |
| 已移除 | ~~网络时钟校准（原 §6.4.1）~~ | — | — | 见下 | — |
| 已移除 | ~~注入式内容哈希（原 §6.3 修订 1）~~ | — | — | 见下 | — |

**已移除项说明**：

- **网络时钟校准 / HLC（原 §6.4）**：LWW 维持墙钟 + hash 字典序兜底（[sync_engine.dart:1596](file:///c:/Home/Projects/safenotes/packages/core/lib/src/sync/sync_engine.dart#L1596)）。移除理由：①设备间 offset 各自校准、不一致，反而让 LWW 比纯墙钟更差；②需在 `ports.dart` 新增 `monotonicNowMs()` 注入点（违反核心包纯 Dart 约束的前置依赖）；③GC 时间降级链未定义（网络故障时行为不确定）。单用户多端偶然时钟漂移可接受，不值得引入此复杂度。
- **注入式内容哈希（原 §6.3 修订 1）**：保留 `SHA-256('$title\n$description')`（[safenote.dart:234](file:///c:/Home/Projects/safenotes/packages/core/lib/src/models/safenote.dart#L234)）。移除理由：改动牵连 5 处（computeHash / DB 列 / 孪生笔记查询 / blob 寻址 / M7 校验），收益仅消除"概率极低的编码歧义碰撞"，成本与收益不匹配。**在 `SafeNote.computeHash` 代码注释中留一笔"已知非单射、概率极低"以备未来排查**。

---

## 1. 当前 Manifest 格式（基于代码事实）

定义位置：`packages/core/lib/src/sync/sync_models.dart`（`ManifestCrypto`，812–926 行）。

### 1.1 二进制容器结构

```
[ 4 字节大端 uint32 = header 长度 ][ header 明文 JSON 字节 ][ items 密文（AES-256-GCM） ]
```

- 前 4 字节是 `header` 的字节长度（裸二进制，大端）。
- 接着是 `header` 明文 JSON。
- 其后是 `items` 密文：`AES-256-GCM(dataKey, AAD='manifest-items', plaintext=items JSON)`，
  信封为 `nonce(12) ‖ ciphertext ‖ tag(16)`（`crypto.dart:290-299`）。

### 1.2 Header 明文字段（`ManifestHeader`）

| 字段 | 含义 |
|---|---|
| `schemaVersion` | 协议版本，当前 `5`（`kManifestSchemaVersion`，见 `sync_models.dart:79`） |
| `version` | 每次成功 PUT +1 |
| `vaultId` | 同步组 UUID |
| `createdAt` / `updatedAt` | 毫秒时间戳 |
| `keyFingerprint` | H(MK)，检测他端改密码 |
| `keyVersion` | 密码版本（改一次 +1） |
| `encryptedDataKey` | MK 加密的 dataKey（base64） |
| `kdf.{algorithm,salt,iterations,memoryKiB?,parallelism?}` | 新 vault 默认 `ARGON2ID`（m=32MiB,t=3,p=2）；存量 `PBKDF2-HMAC-SHA256`/per-vault salt/200000，按 `algorithm` 字段分派，互操作 |
| `dataKeyWrap` | `AES-256-GCM` |
| `dataKeyEpoch` | v5 后仅审计元数据 |
| `dataKeyFingerprint` / `dataKeyCreatedAt` / `dataKeyCreatedBy` | v5 新增自描述审计字段 |
| `lastModifiedBy` | 最后修改设备 |

### 1.3 真实文件验证

`temp/safenotes-vault/manifest.json`（30631 字节）解析结果：

- header 长度字段 = 729，明文 header 解析正常；加密 items 体 = 29898 字节（需 dataKey 才能解）。
- header 实测值：`schemaVersion=5`、`version=51`、`keyVersion=3`、`dataKeyFingerprint=4d42b5f6...`、`lastModifiedBy=windows-{A6BD8CBA-...}`，字段与 `ManifestHeader` 完全吻合。

---

## 2. 格式设计的工程评价

### 2.1 "明文 + 密文混合"是必要的，不是缺陷

`header` 必须明文（新设备无 dataKey，要先读 `encryptedDataKey` + KDF 参数才能派生 MK）；`items` 必须密文（笔记元数据也需保密）。JWE / OpenPGP / Signal 信封加密都是此思路。所以"混合"本身不该被批评。

### 2.2 当前格式的三个真实瑕疵

1. **文件名骗人**：叫 `manifest.json` 却不是 JSON（含裸二进制），`file` 命令报 `data`，编辑器/工具打不开。格式声明错误。
2. **裸二进制长度前缀，无 magic / 文件级版本**：文件既非文本也非标准容器，磁盘损坏、误传、MIME 嗅探都难识别。
3. **半明文半乱码**：排障/审计时 humans 困惑，易误判"没加密干净"。

### 2.3 改进选项对比

| 方案 | 改动 | 收益 | 代价 |
|---|---|---|---|
| 改扩展名 / 去 `.json` + 文档声明二进制 | 极小 | 消除 json 欺骗（治标） | 仍非纯文本 |
| 拆两文件：`manifest.json`（明文 header）+ `manifest-items.bin`（密文） | 中 | header 可被任意 JSON 工具 diff/审计（近 Joplin 做法） | 多一次 IO、双文件原子性更难 |
| 纯 JSON 包裹：`{header:{...}, items:"<base64密文>"}` | 中 | 整个文件合法 JSON、可调试、可文本 diff | base64 +33% 体积、密文不能零拷贝 |
| 现状 + 开头加 magic + 文件级版本 | 小 | 防误传/损坏识别 | 仍非文本 |
| **v5 容器（magic + pubHash 损坏检测，本文档方案）** | 中 | 区分"损坏 / 密钥不匹配"两种失败 + 新设备可预验 | 固定头 12B + pubHash 32B（相对旧 4B 前缀**净增约 40B**） |

---

## 3. 现有抗损坏机制（事实核查）

### 3.1 GCM 自带认证（强于 CRC，但不纠错）

`items` 用 AES-256-**GCM**（AEAD），任何字节翻转在解密时 tag 校验失败直接抛异常——能**检测**损坏。但 GCM 设计哲学是"**检测到就拒，不纠错**"。这是"不抗损坏"感知的根源。

### 3.2 关键缺陷：损坏 vs 密钥不匹配 不可区分

当前代码对 `items` GCM 解密失败的处置是**按密钥问题处理**，而不是按损坏处理：

- scenario-b 分支：`本地 MK 解不开远端包裹 + 远端 keyVersion >= 本地` → **强制重登**（`sync_engine.dart:458-471`）；
- `MK 未缓存 + dataKey 解不开` → 报"密钥验证信息不足"失败（`sync_engine.dart:438-445`）。

**后果**：一个字节翻转（磁盘坏扇区、网络截断、半写）会让用户被错误判定为"他端改了密码，请重新登录"，甚至触发 keyring 迁移流程。这是当前格式最严重的可靠性缺口，也是本方案 v5 容器要根治的核心问题。

### 3.3 环形备份（已存在）

- `kManifestBackupRingCount = 5`（`sync_backend.dart:238`）。
- 写入时机：`sync_engine.dart:619-623`，每次走到 Step 4「加密 + PUT manifest」**之前**，先 `backupManifest(remoteResponse.ciphertext)`。
- 触发条件：① 本次 sync 有实际变更；② 远端已存在旧 manifest（`ciphertext.isNotEmpty`，首次创建不备份）。
- 备份内容：**即将被覆盖的旧版本**，不是刚生成的新版。当前线上 `manifest.json` 不在 bak 里。
- 轮转：`slot = (slot+1) % 5`，覆盖最老的一份；`.manifest-bak-index` 记录当前槽。
- 真实目录验证：`temp/safenotes-vault/manifest-backup/` 含 `manifest.bak-0..4` + `.manifest-bak-index`。

### 3.4 已存在的损坏恢复路径（需集成复用，而非另起炉灶）

`sync_engine.dart:311-354` 已有：`deserializeHeaderOnly` 抛 `FormatException`（header 长度错位 / JSON 解析失败）→ `backupCorruptManifest` + journal 留痕 + 用本地数据重建 manifest 并 PUT 覆盖。**局限**：只覆盖 header 的结构性损坏，且无法捕获"能解析成合法 JSON 但字段被翻转"与"items 密文损坏"这两类静默损坏（后者还被误判为密钥问题）。

### 3.5 其它自愈

- `blobs-orphan/`：软删除隔离区，超期才真删。
- `repairRemote`：远端 blob 缺失时，若本机持有明文则重传自愈。
- **journal（现成的"第二数据源"）**：`_addAction` 漏斗统一投影笔记级事件（`noteUpsert` / `noteDelete` / `noteConflict`，含 uuid + hash），且已在多个落地点上传远端（`_uploadJournal`，`sync_engine.dart:361,662`）。本文档此前版本完全遗漏了它——它是终极重建最有力的数据源（详见 §8）。

### 3.6 真正缺口（按优先级）

1. **损坏 / 密钥不匹配 不可区分**（§3.2）——最严重。
2. **整体无 magic / 无文件级完整性**——下载后无法区分"真损坏 vs 旧文件 vs 错误文件"。
3. **header 明文 JSON 无校验**——长度字段或 JSON 字符翻转，部分静默损坏逃过 §3.4 的 FormatException 路径。
4. **bak 自身无校验**——5 份 bak 同样无完整性校验，回退只能逐个盲试解密。
5. **备份写入非原子**——`putManifest` / `putBlob` 已 tmp+rename 原子写（`local_fs_backend.dart:115-123`、156-164），仅环形备份 `writeRingBackup`（`sync_backend.dart:271`）直接 `File.writeAsBytes`，半写备份本身是恢复路径的隐患。

> 原第 6 项"item/blob 内容哈希编码不单射"已随 §6.3 修订 1 一并移除（保留现状）。

---

## 4. 抗损坏方案对比与结论

### 4.1 WinRAR 式 FEC（Reed-Solomon 恢复记录）能实现吗？

**技术上能，但对 manifest 是错配。**

- 若做 FEC，必须作用在**密文**上（不是明文）：对 AES-GCM 密文做 RS 分块编码是安全的（冗余符号 = 密文字节的有限域线性组合，仍随机，不泄露明文；Tahoe-LAFS 等即如此）。
- 但 manifest 是「可派生的索引」：blob（笔记内容）才是唯一不可再生数据，manifest 可由"本地 DB + journal + blobs 目录"重建（局限见 §8.2）。FEC 价值在**大文件 + 不可靠信道 + 无法回退**（如视频），而 manifest 才 30KB、后端（WebDAV / 对象存储）本身多副本 + ETag 校验、本地还有 5 份环形备份 + 现成 journal。上 FEC 要分块/编解码/定位 erasure，复杂度高收益低。

### 4.2 推荐方案一句话

**v5 容器（§5）解决"能否正确判断坏没坏、坏在哪"，统一恢复编排（§7）解决"坏了我怎么办"，
写侧原子化（§9）减少坏的概率，journal（§8）兜住"全都坏了"；item/blob 修订（§6）消除自愈
元数据丢失。**

| 方案 | 作用 | 复杂度 | 推荐度 |
|---|---|---|---|
| v5 容器：magic + 文件级版本 + pubHash | 区分损坏 / 密钥不匹配，新设备可预验 | 中 | ⭐ 必做（P0） |
| item/blob 格式修订（payload 版本 + 自愈字段补齐 + 语义注释） | 元数据自描述一致 | 小 | ⭐ 必做（P1/P2） |
| 统一恢复编排：re-GET → 验 pubHash 挑 bak → 本地重建 | 损坏后自动挑好版本恢复 | 低（备份已存在 + §3.4 路径复用） | ⭐ 必做（P1） |
| 备份写入原子化（temp + rename + fsync） | 源头减少半写损坏（manifest/blob 已原子） | 极小 | ⭐ 必做（P0） |
| journal 升级全保真事件源，manifest 纯派生 | 终极自愈从"修"变"重放" | 高 | 暂不做（见 §8.3） |
| WinRAR 式 RS 恢复记录 | 字节级纠错 | 高 | ❌ 不推荐 |

> 说明：原「迁移后旧备份验签（保留上一代 MACkey）」条目已删除——删除 HMAC 后旧备份判定
> 天然成立（§7.3），无需保留任何历史密钥。

---

## 5. v5 容器设计（全新格式）

> 前提：本文档明确**不考虑与旧 v4 二进制的兼容性**，可从零设计。旧格式文件与旧格式 bak 在升级后按"无法解析"走统一恢复编排即可。

### 5.1 布局

```
0         4        6        8        12
┌─────────┬────────┬────────┬────────┬──────────────┬──────────────┬──────────────┐
│  magic   │fileVer│schemaV │headerLen│    header    │     items    │    pubHash   │
│  4 字节   │ 2 字节 │ 2 字节 │ 4 字节  │   明文 JSON   │  AES-GCM 密文 │   SHA-256 32B │
└─────────┴────────┴────────┴────────┴──────────────┴──────────────┴──────────────┘
```

- `magic`：4 字节固定标识 `'SMNT'`（SafeNotes ManifesT）——**容器家族标识，不带版本数字**；实际
  版本由 `fileVer`（容器布局）与 `schemaVersion`（协议语义）分别承载，避免"系列 v2 / 协议 v5"混淆。
- `fileVer`（**2 字节**）：**文件级容器布局版本**，首个布局为 `1`。2 字节的理由见 §5.4。
- `schemaVersion`（2 字节）：**协议语义版本**（当前 `kManifestSchemaVersion=5`），与 fileVer 职责分离：容器布局变更只动 fileVer，字段语义变更只动 schemaVersion，二者解耦便于各自演进。
- `headerLen`：4 字节大端，header 字节数（沿用现编码）。
- `header`：明文 JSON（同现格式）。
- `items`：`AES-256-GCM(dataKey, AAD='manifest-items', items JSON)`，信封格式不变。
- `pubHash`：32 字节 `SHA-256(容器 [0, pubHash 起始处) 全部字节)` —— 即除 `pubHash` 外的整个容器。**无密钥**，任何人在派生 dataKey 之前都能算。

> **防篡改边界**：`pubHash` 无密钥、可被任意重算，因此本设计**不防云端恶意篡改**（攻击者可篡改内容后重算 pubHash 通过校验）。只保证「非恶意损坏」（磁盘坏扇区、网络截断、半写）可检测——个人自建后端场景可接受。若未来需要防篡改，可在文件尾部追加 keyed HMAC（覆盖范围含 pubHash，`fileVer` 演进兼容），不影响当前布局决策。

### 5.2 密钥使用（无第二把 MACkey）

- **dataKey 只用于 AES-GCM**（items 加密与 blob 加密）。**不引入 MACkey / keyed HMAC**——本设计只检测损坏、不做防篡改（§5.1 边界）。
- 无 MACkey 的连带收益：
  - **改密码（keyVersion+1）不换 dataKey**（`keyring.dart:792` 明确"O(1) 不触碰笔记"）→ 数据与 key 关系不变，无需任何额外处理。
  - **dataKey 迁移（scenario-d / epoch 切换）后旧备份判定天然成立**：`pubHash` 无密钥、新旧 dataKey 都能验；旧 bak 用当前 dataKey 解 GCM 失败即「旧密钥数据」（§7.3），无需保留任何历史密钥。

### 5.3 验证矩阵（一次性区分损坏 / 密钥不匹配）

| 检查（按序） | 通过说明 | 失败判据 |
|---|---|---|
| `magic` / `fileVer` | 文件是本格式、容器布局可读 | 非本格式 / 布局版本过低 → 错误文件 / 需升级 |
| `headerLen` 范围 | header 偏移合法 | 结构损坏 |
| `pubHash`（**无需 key**） | 数据字节未被改动（损坏检测） | 位翻转 / 截断 / 半写 → **损坏** |
| `GCM items`（需 dataKey） | 内容可解、密钥正确 | pubHash 通过但 GCM 失败 → **密钥不匹配**，走密码/迁移流程 |

关键含义：

- **pubHash 失败 = 数据坏了**（不管 GCM 是否恰好能解）；**pubHash 通过但 GCM 失败 = 密钥不对**（不是数据问题）。二者正交，彻底消除 §3.2 的"损坏被误判为改密码强制重登"。
- 推理：非恶意损坏必然破坏 pubHash（SHA-256 对随机位翻转敏感），故"pubHash 通过 + GCM 失败"只可能是 key 问题（含 dataKey 迁移后的旧密钥数据）。**检测损坏与区分密钥不匹配都不需要 keyed HMAC。**
- **防篡改边界**：恶意攻击者会重算 pubHash，故"损坏 vs 篡改"不做区分、不防篡改（§5.1）。个人自建后端场景可接受。
- **新设备 onboarding（无 dataKey）两段式**：派生前只能验 `magic`/`fileVer`/`headerLen`/`pubHash`（结构 + 损坏检测）；派生 dataKey 后直接 GCM 解密 items（无需补验）。onboarding 本身就要读 `encryptedDataKey` + KDF 参数派生 dataKey，窗口极短，`pubHash` 已保证该窗口内"数据确实没坏"。

### 5.4 为什么 fileVer 用 2 字节

- **对齐**：4+2+2+4 = 12 字节固定头，`magic`/`fileVer`/`schemaV`/`headerLen` 四个字段对齐整洁
  （其中仅 `headerLen` 是长度前缀，其余是固定宽度标识/版本字段），解析偏移都是固定常数。
- **演进余量**：1 字节只有 256 个容器布局版本；文件级格式的生命周期远超 256 次布局变更（历史上 v1→v4 已改过 4 版）。2 字节（65536）配合 schemaVersion 独立 2B，基本杜绝"布局版本打满"的再迁移。
- **成本可忽略**：相对旧格式仅 4 字节长度前缀，新固定头**净增 +8 字节**（其中 `fileVer` 选 2B 而非 1B 只多 1B），相对 30KB 文件占比为零。

### 5.5 序列化 / 反序列化流程

```
serialize:
  headerBytes = UTF-8(JSON(header))
  itemsBytes  = AES-GCM(dataKey, 'manifest-items', JSON(items))
  pubHash     = SHA-256(magic ‖ fileVer ‖ schemaV ‖ headerLen ‖ headerBytes ‖ itemsBytes)
  return 拼接（[magic][fileVer][schemaV][headerLen][headerBytes][itemsBytes][pubHash]）

deserialize:
  1. 长度 < 44 → FormatException
  2. magic/fileVer/schemaVersion 检查
  3. headerLen 范围检查 + 解析 header（明文）
  4. 验 pubHash；失败 → 抛 ManifestAuthException（损坏，区别于密钥问题）
  5. GCM 解 items；失败 → 抛 ManifestKeyMismatchException（密钥不匹配）
```

异常分类（新增两个具名异常，替代"全靠 GCM 抛错再猜"）：

- `ManifestAuthException`：结构 / pubHash 失败 → 数据问题 → 统一恢复编排。
- `ManifestKeyMismatchException`：pubHash 过、GCM 败 → 密钥问题 → 密码 / 迁移流程（现有分支逻辑）。

> **实施约束**：新异常必须在所有 deserialize 调用点被正确分流，否则会被现有 `on Object catch` 兜底吞掉，导致 §3.2 问题不仅没修反而被掩盖。完整调用点改造清单见 §11.1。

---

## 6. Item 与 Blob 格式（随 v5 一起修订）

> 本节字段 / 寻址 / 信封修订与 §5 v5 容器同批生效（同一新协议版本），不兼容旧数据。

### 6.1 现状（基于代码事实）

- `ManifestItem`（`sync_models.dart:77-231`）：`hash` / `deleted` / `updatedAt` / `updatedBy` /
  `createdAt` / `deletedAt?` / `contentSize` / `blobKeyEpoch` / `dataKeyFingerprint` /
  `createdBy` / `dataKeyCreatedAt?` / `dataKeyCreatedBy?`。
- blob 信封（`crypto.dart:290-342`）：`AES-256-GCM(dataKey, AAD=hash)`，信封
  `nonce(12) ‖ ciphertext ‖ tag(16)`；明文 JSON `{"title":"...","description":"..."}`
  （`safenote.dart:243-249`）。
- 内容寻址：`hash = SHA-256('$title\n$description')`（`safenote.dart:234-237`）；blob 键名 = hash，
  天然去重、多 uuid 共享同一 blob。
- 校验链：GCM tag（抗错位/篡改）→ 下载解密后重算 hash 比对 M7（`sync_engine.dart:1816-1817`）。

### 6.2 值得保留的设计

1. **AAD = 内容 hash 而非 uuid**：去重共享的前提；若 AAD 绑 uuid，共享 blob 在其他设备永远
   解不开（`sync_engine.dart:1634-1640` 的注释推理正确）。
2. **密钥演进友好**：dataKey 迁移重加密后 AAD 仍为 hash，寻址稳定、跨密钥可续用。
3. **item 自描述 `dataKeyFingerprint`**（v4）：精确区分"旧 key 数据 vs 真损坏"，比 epoch 强。
4. **putBlob 已原子写**（`local_fs_backend.dart:156-164`，tmp + rename）。

### 6.3 修订项（随 v5 落地）

> **已移除修订 1（注入式内容哈希）**：保留 `SHA-256('$title\n$description')` 现状。已知该编码非单射
> （`"A\nB" + "C"` 与 `"A" + "B\nC"` 哈希相同），但概率极低且改动牵连面广（computeHash / DB 列 /
> 孪生笔记查询 / blob 寻址 / M7 校验共 5 处），收益不足。**实施时在 `SafeNote.computeHash`
> 注释中留笔"已知非单射、概率极低"以备未来排查**。

**修订 2 — 内容寻址名不副实（键名 ≠ blob 字节哈希）。**

`item.hash` 是逻辑内容哈希，blob 明文是 JSON，二者域不同：无法对解密字节直接重算验证，
且 `contentSize`（`toContentBytes().length`，JSON 字节长，`sync_engine.dart:1093`）与 hash 域
不一致。修订：明确"逻辑内容哈希 = 身份、payload = 存储表示"两域语义并在代码注释写明；
`contentSize` 定义为 payload（JSON）字节长，与身份域解耦。

**修订 3 — 自愈/重建路径丢弃自描述字段。**

`_handleDownloadFailure` 重建的 item（`sync_engine.dart:1917-1924`）不写
`dataKeyFingerprint` / `createdBy` / `dataKeyCreatedAt`，而 `_buildLocalManifest` 全写
（`sync_engine.dart:1099-1102`）——heal 后的条目失去"用哪把 key 加密"的自我描述，后续解密
失败无法归因。修订：heal 路径补全同一组自描述字段。

> **此项是 §5.3 验证矩阵"密钥不匹配"判据的配套**——没有自描述字段，heal 后的条目永远无法
> 参与密钥归因，§5.3 的区分能力在 heal 路径上失效。

**修订 4 — blob payload 无版本字段。**

`{"title","description"}` 裸 JSON，将来加字段无法判别新老格式。修订：payload 增加 `"v"` 字段：
`{"v":2,"title":"...","description":"..."}`。身份与 payload 解耦后，加字段不影响已寻址的 blob。

> **LWW 时钟策略（原修订 5）：维持墙钟现状，不引入网络校准或 HLC。**
> 跨设备时钟偏斜会静默选错 LWW 胜者；同 ms 并发靠 hash 字典序兜底（`sync_models.dart:94`）。
> 本设计**不改动 LWW 时钟结构**——网络校准与 HLC 的成本/风险高于收益（详见 §0 已移除项说明），
> 单用户多端偶然时钟漂移可接受。

---

## 7. 统一恢复编排

### 7.1 流程（替换 §3.4 现路径，并在其基础上扩展）

```
manifest 加载失败（ManifestAuthException / FormatException）
  ├─ 1. 若远端可 GET → 重新 GET 一次并完整校验（结构 + pubHash）
  │     └─ 通过 → 用远端（防瞬时坏 / 半写；远端 PUT 已成功时不回退 bak）
  ├─ 2. 校验失败 → 从 bak 按槽位从新到旧试（先验 pubHash、后解密，见 §7.2）
  │     ├─ 找到好版本 → 恢复为当前 manifest
  │     │     └─ 立即触发一次普通 sync（本地 DB merge 回远端，§7.4）
  │     └─ 全坏 → 3
  └─ 3. 终极自愈：本地 DB + journal + blobs 重建（§8）
        └─ 重建后 PUT（乐观锁 + journal 留痕），并入现有重建日志语义
```

要点：

- **复用而非重写**：`sync_engine.dart:311-354` 的"FormatException → backupCorruptManifest → 重建 → PUT → journal"路径直接并入本流程；新增的 `ManifestAuthException` 与 `FormatException` 同走该入口，只是触发面从"仅 header 结构"扩到"整文件校验"。
- **PUT 已成功时优先 re-GET**：`V_n` 已成功 PUT（远端完好，仅本地视图读到坏）时，正确做法是重新 GET 远端；回退 bak 反而把刚成功的 `V_n` 覆盖成 `V_n-1`，凭空丢数据。回退 bak 仅作为"远端 manifest 文件本身损坏/丢失"的兜底。
- **PUT 成功判定**（实施约束）：客户端崩溃重启后无法直接区分"上次 PUT 已成功"还是"未发起/未完成"。**通过 journal 最近一条 `syncManifestPut`（`sync_engine.dart:631-638`）的存在性 + 本地 `manifestVersion` 与远端 ETag 的对比来判定**——若 journal 显示上次 PUT 已完成且远端 ETag 与本地状态吻合，则视为"PUT 已成功"，走 re-GET 而非回退 bak。

### 7.2 bak 选择策略：先验 pubHash、后解密

有了 pubHash，回退**不再需要逐个 GCM 盲试**：

1. 按槽位从新到旧，对每个 `manifest.bak-*` 先验 `pubHash`（**无 key、免费**，粗损检测）；
2. 验过才做 GCM 解密；
3. 验失败直接跳过——无需昂贵的 GCM 也能判断"这份坏了"。

> **实施约束（关键）**：bak 选择循环中，**任何异常都跳过当前 bak 试下一份**——包括
> `ManifestKeyMismatchException`（pubHash 过 + GCM 败 = 旧 dataKey 数据）。**全部 bak 试完仍无可用
> 版本，才走 scenario-b 密钥不匹配判定**。若实现者按字面理解"解密失败即密钥问题"，会让回退 bak
> 时误触发强制重登，引入回归。完整语义见 §11.2。

> 过渡期注意：旧 v4 裸格式 bak 没有 `pubHash` 字段，只能沿用现有"逐个 GCM 盲试"逻辑；
> 全部写入 v5 格式后才享受预验。（开发中未发布，实际过渡场景极窄，实现时先 v5 化即可。）

### 7.3 dataKey 迁移后旧备份判定（无 MACkey 后自动成立）

scenario-d 迁移（`sync_engine.dart:488`，dataKey 真变）或 epoch 切换后，旧 bak 由旧 dataKey
加密。无 MACkey 后判据**天然成立**，无需保留历史密钥、无需重签备份环：

- `pubHash` 无密钥，**新旧 dataKey 都能验** → 备份是否损坏永远可判；
- 旧 bak：`pubHash` 通过 + 当前 dataKey GCM 解密失败 = **旧密钥数据**（不是损坏）→ 可提示
  "用旧 key 解密"或走迁移流程，与 §5.3 验证矩阵的「密钥不匹配」判据一致。

### 7.4 回退后补改动 = 触发普通 sync（非新 rebuild）

回退到 `V_n-1` 后，只需再跑一次普通 sync：sync 的 LWW merge 发现「本地 DB 的 `updatedAt` 比 `V_n-1` 新」→ 本地胜 → 把缺的条目补回新 manifest 并 PUT。这是 sync 本职，幂等安全，无需额外重建模块。

注意：若 `V_n` 包含其他设备刚 PUT 的 merge，回退会丢之；但其他设备本地 DB 也有自己的变更，下次 sync 会 re-converge（最终一致性窗口，日志留一笔）。环形 5 份在高频同步（3s debounce）下回退窗口可能过短，可考虑提高 `kManifestBackupRingCount` 或改为"版本号跳变时才备份"（待实测后定）。

---

## 8. 终极自愈：从"可重建"修正为"可部分重建"

本文档初稿称"manifest 完全由本地 DB + blobs 决定、丢了能重建"，**此说言过其实**，修正如下。

### 8.1 数据源优先级

| 数据源 | 能还原什么 | 局限 |
|---|---|---|
| **journal（第一优先，现成）** | 笔记事件序：uuid → hash 映射、上传/下载/删除记录（`_journalAction`，`sync_engine.dart:2255-2320`，已上传远端） | 事件型，缺 createdAt/updatedAt/contentSize；不保证 100% 覆盖历史 |
| 本地 DB | uuid ↔ blob 归属、时间戳、删除状态 | DB 本身也可能损坏 / 被清理 |
| blobs（内容寻址） | 笔记明文（可重加密重建 hash → 内容） | 无 uuid 归属、无删除墓碑 |

### 8.2 明确局限

- **删除墓碑不可还原**：`deleted` 状态（tombstone）在本地 DB 清理后无法从 blobs 恢复——重建会"复活"用户在其他设备已删除的笔记。
- **uuid ↔ blob 归属依赖 DB/journal**：纯 blobs 目录只有内容寻址 hash，不知道哪个 hash 属于哪条笔记。
- 因此终极重建的**正确表述**是：`本地 DB + journal` 先还原 items（uuid/hash/时间戳/墓碑），blobs 只用于**校验与兜底**（hash 不匹配的条目 → `repairRemote` 重传）。

### 8.3 方向二（暂不做，备注）：journal 全保真化，manifest 纯派生

> **暂不做**：Tier 1+2 落地后，损坏场景已被 pubHash + bak + 重建三重覆盖，journal 全保真化的
> 边际收益不足以支撑其成本（journal 格式重构 + 截断/压缩策略 + 重放正确性需大量测试）。留作
> 未来"离线鲁棒性"方向的备选。

把 journal 升级为**全保真 append-only 事件源**（每条含完整 item 元数据：uuid / hash / createdAt / updatedAt / contentSize / deleted / keyEpoch），每条自带**无密钥 SHA-256 内容哈希**（整体已 AES-GCM 加密，GCM tag 自带损坏检测；不用 keyed MAC 是因为本设计不做防篡改，§5.1），随每次 PUT 一并上传。则 manifest 退化为纯派生物，"manifest 坏了"从"怎么修"变成"怎么重放"——用 journal 重放即可**确定性重建** manifest，回退 / 重建逻辑全部简化。代价：journal 体积增长、需要截断/压缩策略。

---

## 9. 写侧原子性（防胜于救）

- **现状（事实修正）**：LocalFS 的 `putManifest`（`local_fs_backend.dart:115-123`）与
  `putBlob`（`local_fs_backend.dart:156-164`）**已经**是 temp + rename 原子写；非原子的只有
  环形备份 `writeRingBackup`（`sync_backend.dart:271` 直接 `File.writeAsBytes`）。
- **修订**：`writeRingBackup` 的备份写入改为 temp + flush + rename（同盘原子），避免"备份本身
  是坏的"。
- **远端**：WebDAV / SafeServer 走服务端 PUT 覆盖 + ETag 乐观锁，客户端侧只保证"先备份、后 PUT"
  （现已如此，§3.3）。

> **此项独立于其它改动，可第一个落地**（P0，零依赖、零风险）。

---

## 10. 实施建议（分阶段）

按 §0 优先级推进，依赖关系如下：

- **阶段 1（P0，独立先行）写侧原子化**：`writeRingBackup` 改 temp + rename + fsync（manifest/blob 已原子，不改）。零依赖、零风险，可立即落地。
- **阶段 2（P0，核心）v5 容器 + pubHash 损坏校验**：实现 §5 布局 / 验证矩阵 / 具名异常，替换 `ManifestCrypto.serialize/deserialize`；升级 `kManifestSchemaVersion` → 5。**必须配套 §11.1 调用点改造清单**，否则新异常被 `on Object` 吞掉，问题不仅没修反而被掩盖。
- **阶段 3（P1，配套）item/blob 修订**：§6.3 三项修订——payload 加 `v` 字段、自愈路径补自描述字段、`contentSize` 域语义明确（注释级）。修订 3（heal 补字段）是 §5.3 验证矩阵的配套，必须与阶段 2 同批或紧随其后。
- **阶段 4（P1，下游）统一恢复编排**：§7 流程落地，并入现有 `FormatException → 重建` 路径（`sync_engine.dart:311-354`）；bak 按"先验 pubHash 后解密"选择。**必须明确 §11.2 bak 循环语义**，否则回退时会误触发 scenario-b 强制重登。
- **阶段 5（已删除）**：原"迁移后旧备份验签（保留上一代 MACkey）"已删除——无 MACkey 后旧备份判定天然成立（§7.3），无需任何历史密钥处理。
- **阶段 6（暂不做）journal 全保真化**：§8.3 方向二，manifest 纯派生。待 Tier 1+2 落地后评估边际收益。
- **阶段 7（暂不做）格式呈现优化**：文件改名 / 去 `.json` 后缀（magic 已消除"误传"问题，改名仅为了让人类与工具不被骗，但破坏存量布局，收益不足）。

> 兼容性声明：**开发中未发布——不兼容旧代码与旧数据，不做迁移代码**。v5 布局与 §6.3 修订均与
> 旧实现不兼容；旧 manifest / bak / 本地 DB 一律按"废弃重建"处理（全新安装 / 开发重置即重来，
> 无需任何迁移逻辑）。
>
> 代码落地时请在 `docs/CHANGES-{YYYYMMDD}.md` 追加变更概要。

---

## 11. 已识别风险与实施约束（必读）

本节汇总实施时必须遵守的约束，违反任一条都会引入回归。

### 11.1 异常调用点改造清单（对应风险 1）

新增 `ManifestAuthException`（损坏）/ `ManifestKeyMismatchException`（密钥不匹配）后，
`sync_engine.dart` 中**所有** `ManifestCrypto.deserialize` 调用点必须同步更新 catch 逻辑。
当前共 9 处（行号会随代码演进，实施时以 grep 为准）：

| 调用点 | 当前 catch | 改造要求 |
|---|---|---|
| 行 396（正常同步分支） | `on Object` 兜底 | 拆分：`ManifestAuthException` → 走 §7 恢复编排；`ManifestKeyMismatchException` → 走 scenario-b |
| 行 420 / 431 / 434（MK 未缓存分支） | `on Object` 兜底 | 同上，且 `ManifestAuthException` 不应触发"密钥验证信息不足" |
| 行 453 / 482 / 490 / 538（迁移分支） | `on Object` 兜底 | 同上，迁移路径中损坏应走 §7 而非迁移失败 |
| 行 731（repair 路径） | 需核实 | 同上 |

**核心原则**：`ManifestAuthException` 永远不走 scenario-b 强制重登；`ManifestKeyMismatchException`
才走密钥/迁移流程。若某调用点用 `on Object` 兜底，新异常会被吞掉，§3.2 问题不仅没修反而被掩盖。

### 11.2 bak 循环语义（对应风险 2）

§7.2 bak 选择循环必须遵守：

```
for bak in baks (从新到旧):
  try:
    if not verifyPubHash(bak): continue      # 损坏，跳过
    manifest = GCM_decrypt(bak)               # 可能抛 ManifestKeyMismatchException
    return manifest                            # 成功
  on ManifestAuthException: continue          # 结构损坏，跳过
  on ManifestKeyMismatchException: continue   # 旧密钥数据，跳过（不是损坏，但这份不能用）
  on Object: continue                          # 未知异常，保守跳过

# 全部 bak 试完仍无可用版本
→ 走 scenario-b 密钥不匹配判定（此时才合理：当前 dataKey 解不开任何 bak）
```

**关键**：`ManifestKeyMismatchException` 在 bak 循环中**跳过当前 bak 试下一份**，而非触发强制重登。
只有"所有 bak 都解不开"才意味着密钥真的不匹配。若实现者按"解密失败即密钥问题"字面理解，
回退 bak 时会误触发 `requiresRelogin: true`，引入回归。

### 11.3 PUT 成功判定（对应风险 6）

§7.1 "PUT 已成功时优先 re-GET"需要判定上次 PUT 是否成功。客户端崩溃重启后无法直接区分，
**通过以下信号组合判定**：

1. journal 最近一条 `syncManifestPut`（`sync_engine.dart:631-638`）存在 → 上次 PUT 已发起并完成 journal 写入；
2. 本地 `manifestVersion`（`database.getManifestVersion`）与重新 GET 的远端 manifest `version` 一致 → 远端确实收到了那次 PUT；
3. 两者都满足 → 视为"PUT 已成功"，走 re-GET 用远端版本；否则走 bak 回退。

若实现时省略此判定，可能把刚成功的 `V_n` 覆盖成 `V_n-1`，凭空丢数据。
