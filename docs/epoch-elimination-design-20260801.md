# 密钥纪元消除设计（epoch 自愈 → item 自描述 + 只读解密）

日期：2026-08-01
状态：设计评审（未实现）
关联事故：`docs/CHANGES-20260801.md`（真实数据：8 条 manifest 声称 epoch2、blob 实为 epoch1 的脏数据）

## 1. 问题回顾

### 1.1 事故根因（真实数据还原）

- 两端用同一密码初始化，但 **dataKey 随机生成 → 各自不同**（这是设计使然）。
- Android 首次同步触发 scenario-d 迁移（旧 journal seq=1/2），采用远端 dataKey、epoch 1→2、keyVersion 采用远端值。
- 迁移后 **epoch 分裂**：Android=2（已迁移）、Windows=1（未迁移，改密码不碰 epoch）。
- 分裂期间 Windows 下载到 Android 的 epoch-2 blob，`_downloadNote` 的 heal 分支用 `!=`（L1783）判断方向，**2≠1 即触发** → 用本地低纪元 1 重传覆盖服务器高纪元 blob → 翻转开始。
- 双方反复互相覆盖，最终 8 条 manifest 声称 epoch2、blob 实为 epoch1。

### 1.2 结构性根因

epoch 被当成**全局状态机**（两端必须收敛到同一数值），由此衍生「谁对谁错」判定 → 自动重写 → 方向错即翻转。但 epoch 本质只是**加密参数的版本标签**，不该驱动任何「纠正」行为。

## 2. 根本方案：item 自描述 + 只读解密

采纳业界（Joplin 多 master key / Standard Notes immutable itemsKey）模型：

1. **`blobKeyEpoch` 是 item 写死的自描述属性**：谁加密谁定，解密端不推断、不比较、不纠正。
2. **解密端是纯函数**：用 item 声明的 epoch 解密 → 能解就物化显示 → 解不开就报「缺 key / 密钥不符」。
3. **解不开时提示用户**（输旧密码 / 手动 `repairRemote()`），**不做任何自动重传**。

## 3. 复杂度评估（改前 vs 改后）

判据：**改后代码量（含新机制）> 改前 → 方案不合格，弃用**。

### 3.1 改前：与 epoch 自动重写相关的代码（以 `lib/sync/sync_engine.dart` 为准）

| 函数 / 机制 | 位置 | 行数 | 命运 |
|---|---|---|---|
| `repairRemote`（全量修复） | L631-880 | ~250 | **保留**（用户主动路径） |
| `_buildLocalManifest`（乐观声明 epoch + override 三元组） | L1013-1077 | ~65 | 瘦身 |
| `_mergeAndTransfer`（含 pendingReupload 重传分支） | L1091-1313 | ~223 | 瘦身 |
| `_probeBlobEpoch`（探测实际纪元） | L1634-1670 | ~37 | **删除** |
| `_downloadNote`（含 Layer3 heal「纪元不符→当前纪元重传」） | L1671-1913 | ~243 | 瘦身（删 heal） |
| `_handleDownloadFailure`（本机明文/孪生自愈重传） | L1914-2010 | ~97 | 瘦身 |
| `adoptRemoteEpoch` 调用 + `epochMismatch` 状态机 + override 三元组 + `markAllForBlobReupload` | 全文件散落 | ~100（估） | **删除** |
| **改前小计** | | **~1015 行** | |

### 3.2 改后：保留的 + 新增的

| 项 | 行数 | 说明 |
|---|---|---|
| `repairRemote` | ~250 | 保留不变 |
| `_buildLocalManifest` | ~50 | 删 override/乐观声明，`blobKeyEpoch` 直接取 item 本地记录值 |
| `_mergeAndTransfer` | ~180 | 删 pendingReupload 分支 |
| `_downloadNote` | ~160 | 删 heal 重传分支；解密失败直接报 `corrupt` |
| `_handleDownloadFailure` | ~30 | 仅剩「记录失败 + 提示 repair」，删两层自动自愈重传 |
| 新增：`_blobMissingKeyError`（解密失败提示） | ~15 | 明确报「缺 key」而非猜测 |
| **改后小计** | | **~685 行** |

### 3.3 结论

- **净减约 -330 行（约 -33%）**，且删掉的是最危险、最难测的分支（自动重写、探测、双向翻转），保留的是一次性显式迁移与用户主动修复。
- 删掉 4 个状态变量（`epochMismatch`/`overrideXxx`/`pendingReupload`/`markAllForBlobReupload`），**分支复杂度显著下降**。
- `keyring.dart` 侧：`adoptRemoteEpoch`、`markAllForBlobReupload` 删除（约 -50 行），`migrateToRemoteVault`（显式迁移）保留。
- 满足判据：改后代码量下降，方案合格。

### 3.4 代价（接受项）

- 解密失败从「自动修复」变为「提示 + 手动 repair」——UX 略降。
- 迁移（scenario-d / scenario-c）仍是显式一次性动作，代码保留，不属本次删减范围。

## 4. 关键 Q&A（epoch 语义澄清）

### Q1：怎么检测「dataKey 不同」？

不直接比较 dataKey（它只在本地），而是通过「能否解开远端 encryptedDataKey」间接判断
（`keyring.dart checkMigrationNeeded` L531-560）：

```
比较本地/远端 encryptedDataKey
  ├─ 完全相同 → 无需迁移（同 vault）
  └─ 不同 → 用本地 MK（密码派生）解远端 encryptedDataKey
           ├─ 解开 → 密码相同，直接采用远端 dataKey（迁移）
           └─ 解不开 → 密码不同(scenario-c) 或 salt 不同(scenario-d)
```

dataKey 从不在线比较；比较的是「密码派生的 MK 能否解开对方的包裹」。

### Q2：迁移后 dataKey 已一致，blobKeyEpoch 还有意义吗？

有意义，但只剩一个：**加密格式版本标签（AAD 绑定）**。
AAD = `'$epoch|$hash'`，epoch 参与解密校验，防止密文错位被误收（内容 hash 校验外的
额外保险）。迁移完成后它退化为「与具体 blob 绑定的自描述标签」，**不再承担密钥区分、
不参与收敛、不驱动同步行为**——这正是本方案要的语义。

### Q3：第三个设备加入，epoch 1/2/3 到底是什么？

epoch 递增的唯一时机 = **dataKey 值真正变化**（`migrateToRemote` L584-587
`keyChanged → nextEpoch = dataKeyEpoch + 1`）。

```
epoch=1 → 初始 dataKey
epoch=2 → 某次迁移生成了新 dataKey（旧 dataKey 退役）
epoch=3 → 又一次迁移（如忘记密码→重置→全库重加密）
```

**新设备加入 = 采用当前全局 dataKey + 跟随其 epoch，不产生新 epoch**（C 用密码解开
A/B 的包裹即采用同一 dataKey，epoch 继承自远端 header 不 +1）。所有正常设备汇聚在
同一 epoch；混编（部分 item=1、部分=2）只出现在「一代旧 dataKey 的 blob 尚未被重
加密」的过渡期——改后方案中完全无害，解密端按各自标签解，不强求统一。

## 5. 协议影响

- **`ManifestItem.blobKeyEpoch` 保留**（item 自描述），但语义从「待现代化」变为「加密版本标签」。
- `ManifestHeader.dataKeyEpoch` 保留，仅作元数据，不再驱动同步行为。
- 需同步更新 `docs/sync-protocol-spec.md`（§blobKeyEpoch 语义）与相关测试。

## 6. 风险

- 老设备（升级前）可能用旧 heal 逻辑覆盖新设备的数据 → 需**所有客户端同步升级**后才生效。
- 删除 `_probeBlobEpoch` 后，旧格式 blob（epoch=0 / v1 uuid-AAD）解密路径需保留只读兼容。
- 测试：删减的 heal/翻转分支对应测试改为「解密失败→corrupt+提示」断言。

## 7. 实施顺序建议

1. 先落地本设计（epoch 自愈消除）。
2. 全量测试 + `make valid`。
3. 更新协议文档与 CHANGES。
4. 观察一轮真实多端同步确认无翻转回归。
