# Carro Note（safenotes）代码深度审查报告

| 项目 | 内容 |
|---|---|
| 审查日期 | 2026-09-16 |
| 代码基线 | `pubspec.yaml` version `3.0.0+30000`（Android `versionCode=10`） |
| 审查范围 | `lib/`（App 层）、`packages/core/`（纯 Dart 核心）、`bin/`（CLI）、`server/go` 与 `server/nodejs`（SafeServer 参考实现）、`test/`、`integration_test/`、`scripts/`、构建与 CI 配置 |
| 审查方式 | 静态代码审查；先按模块分区并行通读，再对**每一条高危结论回到源码逐行复核**（不采信转述） |
| 代码规模 | 见 §1.2 |

> **本报告的分级纪律**：所有结论分「确证」与「存疑」两级。**确证** = 有明确 `文件:行号` 与代码片段支撑；**存疑** = 证据不足或需运行环境验证。凡是复核后推翻的初判，一律在 §6 单独列出，避免夸大。

---

## 1. 总体评价

### 1.1 结论摘要

这是一个**工程质量明显高于同类个人项目的 Flutter 加密笔记应用**。加密基元选型正确（Argon2id + AES-256-GCM + 12 字节随机 nonce + 每 vault 独立 salt），核心包强制无 Flutter 依赖（pub workspace 编译器保障），同步引擎对多设备冲突、墓碑、孤儿 blob GC、版本代际等复杂问题有系统性设计，并且配套了规模可观的测试（核心包测试代码量 20,230 行 > 实现 16,795 行）。

**主要风险不在"加密做错了"，而在三类落差：**

1. **承诺与实现的落差**：README/注释宣称的若干安全增强，实际未生效或与实现不符（生物识别包裹层、平台原生加密加速、备份完整性）。
2. **Node 服务端实现明显落后于 Go 实现**：同一份 API 规范的两套实现，Go 版已修复的 4 个并发/安全问题在 Node 版仍然存在（配置回退、XFF 信任、原子写 tmp 名、条件写加锁）。
3. **数据迁移链路存在静默丢失**：备份导出不含 `note_meta` 与 `note_versions`，换机后标签/置顶/锁定/颜色与历史版本全部丢失，而 UI 提示"导入成功"。

**没有发现**密钥明文落日志、SQL 注入可利用点、服务端路径遍历、TLS 校验关闭、CORS 过宽等"教科书级"漏洞。这一点必须讲清楚，避免把工程取舍误报成安全漏洞。

### 1.2 代码规模

| 模块 | 文件数 | 行数 | 说明 |
|---|---:|---:|---|
| `lib/`（App 层） | 123 | 28,094 | UI + 状态装配 + 平台注入 |
| `packages/core/lib`（核心包） | 25 | 16,795 | 加密 / DB / 同步引擎，纯 Dart |
| `packages/core/test` | 36 | 20,230 | **测试/实现比 1.20** |
| `test/` + `integration_test/`（App 层测试） | 45 | 10,245 | 测试/实现比 0.36 |
| `bin/`（CLI） | 3 | 1,801 | 纯 Dart，无需 Flutter SDK |
| `server/go` | 18 | 4,122 | 含 `_test.go` |
| `server/nodejs` | 8 | 1,601 | 无测试 |
| **合计** | **258** | **82,888** | |

核心包测试强度显著高于 App 层——这与"核心逻辑高内聚、App 层依赖 UI 交互"的分层意图一致，属合理投入分布。

### 1.3 严重级别定义

| 级别 | 含义 |
|---|---|
| **高** | 可导致数据丢失、凭据/明文泄露、或安全机制被直接绕过；或与设计承诺严重不符 |
| **中** | 在特定条件下造成可用性/健壮性/隐私降级，或明显偏离最佳实践 |
| **低** | 代码异味、文档滞后、性能损耗、工程一致性问题 |

---

## 2. 架构评估（正面部分）

| 维度 | 评价 | 依据 |
|---|---|---|
| 分层边界 | **优秀**。核心包禁止 Flutter 依赖，由 pub workspace 编译器强制 | 根 `pubspec.yaml:14-15` workspace 声明；`packages/core` 仅依赖 `cryptography`/`http` 等纯 Dart 包 |
| 同步设计深度 | **优秀**。两层密钥（MK/dataKey）、内容寻址、墓碑、孤儿 blob 二阶段观察 GC、版本代际、journal 自愈均有独立设计文档与对应用例 | `docs/simplified-sync-design.md`、`spec-manifest.md`、`spec-journal.md`、`spec-blob.md` + `packages/core/test/sync/` 20 组测试 |
| 事务与崩溃一致性 | **良好**。重加密走单事务 + 失败回滚 + `_dataKey` 还原；降级只记日志不拆表 | `database_handler.dart:2168-2212`、`2226-2229`；`:791-797` `onDowngrade` |
| 密钥/凭据日志纪律 | **良好**。日志只记长度与指纹前 8 位，无口令/密钥明文 | `keyring.dart:53`；全仓 `Log.*` 未见敏感值 |
| Android 端防护 | **良好**。`FLAG_SECURE` 默认开启且 API 33+ 禁用最近任务截图；`allowBackup=false` | `MainActivity.kt:50-71`；`AndroidManifest.xml:13` |
| 资源释放 | **良好**。抽查 15 处页面的 Timer/Controller/FocusNode/Subscription 均有对应释放；全 `lib` 无空 `catch`；`setState` 均有 `mounted` 守卫 | 见 §6 澄清项 |

---

## 3. 高危问题（3 项）

### H1｜备份/导出不含 `note_meta` 与 `note_versions`，换机迁移静默丢失元数据与历史版本 — 高

**位置**：`packages/core/lib/src/db/database_handler.dart:3012-3019`

```dart
Future<String> exportAll() async {
  // T-25 修复：改用含墓碑的全量读取——备份-恢复循环中保留删除状态，...
  final notes = await readAllNotesIncludingDeleted();
  final jsonList = notes.map((note) => note.toJson()).toList();
  return jsonEncode(jsonList).toString();
}
```

**确证**：导出只序列化 `safe_notes` 一张表。`note_meta` 表承载的字段（`note_meta.dart:107-125`：`pinned` / `locked` / `archived` / `color` / `tags`）与 `note_versions` 表的历史快照**均不在备份内**；导入侧也只向 `tableNotes` 插入。

**影响**：用户按 README 承诺的"加密备份导出/导入（无缝迁移到新设备）"换机后，**标签、置顶、锁定、颜色全部归零，每篇笔记最多 50 条历史版本全部丢失**，而 UI 仍提示导入成功，无任何降级提示。

**必要的口径修正**：`docs/backup-scheme-revamp-20260831.md:96` 已明确记载 *"备份只含笔记（沿用现有 exportAll），不含 note\_meta（标签/置顶/锁定）——这是既有行为，本次不改"*。因此 **meta 部分是已记录的工程取舍，不是未被发现的 bug**；但**历史版本（note_versions）的丢失未被任何文档覆盖**，且用户在 UI 侧完全无感知。这是本条仍定为"高"的原因。

**建议**：最低成本是导出时纳入 `note_meta`/`note_versions`，或在导入完成页与导出页明示"备份不含标签/置顶/锁定与历史版本"。后者一行文案即可消除误导。

---

### H2｜Node 服务端配置文件加载失败 → 静默回退公开弱 token — 高

**位置**：`server/nodejs/src/config.js:96-103` + `:32`

```js
function loadConfigFile(cfg, file) {
  let data;
  try { data = JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch (err) {
    process.stderr.write(`warning: load config file failed: ${err.message}\n`);
    return;                       // ← 仅告警，继续沿用默认配置
  }
```
```js
token: 'my-secret-token',         // :32 默认值
```

**确证**：配置文件路径写错或 JSON 语法错误时，服务照常启动，但 token 退化为代码内硬编码的公开可猜值。Go 版同场景为致命退出，且**注释直接点名了这个风险**（`server/go/internal/config/config.go:186-190`）：

```go
if err := loadConfigFile(c, configFile, set); err != nil {
    // 修复 S-1：配置文件加载失败属致命错误，必须非零退出，
    // 严禁静默回退到弱默认 token 导致鉴权被绕过。
    log.Fatalf("fatal: load config file %q failed: %v", configFile, err)
}
```

Go 版另有弱 token 醒目告警（`:204-207`）——Node 版两者皆无。**这不是"作者没想到"，而是 Go 版已识别（编号 S-1）并修复、Node 版未跟进**，见 M13。

**影响**：任何人可读写该 vault 的全部密文（虽为密文，但可任意删除/回滚/投毒，结合 H3 后果进一步放大）。

**适用范围限定**：这是**参考实现**（`docs/server-implementation.md:3`），且 `deploy/install.sh` 会用 `openssl rand -hex 24` 替换占位符生成强 token。风险实际落在"手工修改 `config.json` 后语法写错"的部署者身上——这类静默失败正是最难被察觉的一类。

---

### H3｜Manifest 容器缺少抗回滚绑定，可写远端者能重放旧版本 — 高

**位置**：`packages/core/lib/src/sync/sync_models.dart:987-1021`；AAD 常量 `:921`

```dart
final encryptedItems = await SyncCrypto.seal(dataKey, _itemsAad, itemsBytes); // _itemsAad = 'manifest-items'
...
final prefix = Uint8List.fromList([...fixedHeader, ...headerBytes, ...encryptedItems]);
final pubHash = _sha256(prefix);      // 无密钥 SHA-256
return Uint8List.fromList([...prefix, ...pubHash]);
```

**确证**：① `header`（含 `version`、`lastModifiedBy`、`schemaVersion`）为**明文**；② items 的 GCM AAD 是常量字符串 `'manifest-items'`，既不绑定 header 字节、也不绑定 version；③ `pubHash` 是无密钥 SHA-256，任何人可重算。反序列化（`deserialize:1035-1055`）的三阶段校验因此全部可被绕过的字节重排通过。

**影响**：在 E2EE 威胁模型中服务端通常视为不可信。能写远端存储的攻击者（恶意自建服务端、WebDAV 被入侵、对象存储凭据泄露）可把 `version` 回滚到旧代际，或将「旧 header + 新 items」交叉拼装并重算 pubHash，客户端无法察觉。GET→PUT 之间仅有 ETag 乐观锁，无新鲜性证明。

**客观边界**：攻击者**无法解密** items 明文，只能回滚/重放/投毒；且必须先具备远端写权限。因此这是"完整性/新鲜性缺口"，不是"机密性缺口"。

---

## 4. 中危问题（13 项）

### M1｜生物识别"包裹密钥"与密文同库明文存放，包裹层形同虚设 — 中

`lib/models/biometric_auth.dart:109-112` 与 `:72-75`：

```dart
// 包裹密钥：明文写入同一个 secure storage
await storage.write(key: _secureBiometricWrapKey, value: base64Encode(fresh));
// 主密码密文：写入同一个 secure storage
await storage.write(key: _secureBiometricAuthKey, value: '$_wrappedPrefix${base64Encode(envelope)}');
```

**确证**：`_biometricWrapKey`（明文）与 `_secureBiometricAuthKey`（密文）位于**同一个 `FlutterSecureStorage` 实例**（`:40` `static const storage = FlutterSecureStorage()`，未传任何 options、未绑定生物识别认证）。两者同时可读 ⇒ 包裹层不带来任何额外门槛。

**与注释不符**：`:29-31` 声称 *"即使 secure storage 被部分导出/泄露，直接泄漏的也只是密文而非明文密码"* —— 在同库场景下该论断不成立。实际安全性**等价于明文存储主密码**（不低于、也不劣于旧实现；旧版明文回退分支仍在 `:54-56`）。

**为何定为"中"而非"高"**：包裹密钥与密文都在 Keystore/EncryptedSharedPreferences 保护之下，攻击者须先攻破该存储；且 `allowBackup=false` 已封堵 ADB 备份路径。这是"增强承诺未兑现"，不是"新增暴露面"。

---

### M2｜PIN 包裹密钥同样明文存放，PIN 成为唯一防线（默认 6 位）— 中

`lib/models/pin_auth.dart:216-217`：

```dart
final wrapKey = SyncCrypto.generateDataKey();
await storage.write(key: _securePinWrapKey, value: base64Encode(wrapKey)); // 明文
```

**确证**：结构同 M1。真正的强度来自 PIN → Argon2id 派生的那一层（`:231` `KdfParams.create` + `:235-240`）。默认 PIN 长度为 **6 位**（`lib/data/preference_and_config.dart:424` `kPinDefaultLength = 6`，可选 4/6/8/10）。

**爆破成本（按代码实测数据推算，纠正夸大）**：`crypto.dart:108` 记录 Windows 实测 Argon2id(32MiB, t=3, p=2) 约 **200–330ms/次**。6 位纯数字共 10⁶ 组合：单核约 **2.3–3.8 天**；8 核并行约 **7–12 小时**；专用多核/GPU 集群可进一步压缩。这个量级**对离线爆破是真实可行的**，但绝非"分钟级"——本报告不采用该夸大说法。

**前提**：攻击者须已取得设备存储访问权（root/已解锁备份）。配合 `pinFailedCount` 存于**未加密** SharedPreferences（`preference_and_config.dart:463-467`）⇒ root 后可直接清零重试额度。

**附带缺陷（低）**：改 PIN 时的"验证当前 PIN"路径（`views/settings/pin_setting.dart:476-490`）未调用 `PinAuth.onPinFailed()`，无计数与节流；而解锁路径（`pin_unlock_panel.dart:365`）有。需已登录会话才可达，故影响有限。

---

### M3｜会话监听开关为死代码，且计时器只认指针事件（键盘输入不重置）— 中

**位置**：`lib/main.dart:401-407`；第三方包 `local_session_timeout-3.2.0/lib/src/session_timeout_manager.dart:64-76`、`:113-121`

```dart
return SessionTimeoutManager(
  sessionConfig: _cachedSessionConfig!,
  child: App(sessionStateStream: sessionStateStream, navigatorKey: navigatorKey),
);                                   // ← stream 传给了 App，没传给 Manager
```
```dart
if (widget._sessionStateStream == null) { _isListensing = true; }   // 未传 ⇒ 恒为监听态
widget._sessionStateStream?.listen((SessionState sessionState) { ... }); // 本 App 永不订阅
```

**确证**：`sessionStateStream` 未作为 `sessionStateStream` 参数传给 `SessionTimeoutManager`，故包内 `_sessionStateStream == null` ⇒ `_isListensing = true`（恒监听），`listen(...)` 永不注册。

**准确的影响描述（此处纠正一个常见误判）**：
- ❌ **不是**"自动锁定整条链路失效、计时器停摆"——恰恰相反，`_isListensing` 恒为 true，**计时器一直在工作，无操作锁定与失焦锁定功能本身是生效的**（`main.dart` 的 `sessionHandler` 由包的回调驱动）。
- ✅ 真正的问题是：① 全仓所有 `sessionStateStream.add(SessionState.start/stopListening)`（`main.dart:427`、`login.dart:527`、`home.dart:293` 等）**均无消费者**，是死代码；② `main.dart:350-361` 的 H6「键盘活动重置计时器」修复**因此完全无效**——包只在 `onPointerDown` 重置计时器（`:115-119`），**桌面端连续键盘输入（无鼠标）超过无操作阈值仍会被强制登出**，正是该修复想解决的问题。

---

### M4｜墓碑 GC 用本机墙钟比对远端作者时间戳，时钟显著前移会提前抹除墓碑 — 中

**位置**：`packages/core/lib/src/sync/sync_engine.dart:1712-1715`

```dart
final now = DateTime.now().millisecondsSinceEpoch;
...
if (note.deleted && (now - note.updatedAt) > kTombstoneGcThresholdMs) {
  await database.hardDeleteByUuid(note.uuid);   // 发生在 putManifest 之前，无事务回滚
  continue;                                     // 该 uuid 不进入本次 manifest
}
```

**确证**：墓碑的 `updatedAt` 在下载时被回填为**远端作者时间戳**（`_downloadNote` 的 `copyWith(updatedAt: item.updatedAt)`），而 GC 判据用的是**本机墙钟**，二者时钟不同源。

**影响**：任一设备时钟比真实时间快 30 天以上（`kTombstoneGcThresholdMs`），它会在下一次同步时把刚收到的墓碑从本地硬删、并从自己 PUT 的 manifest 中整体抹除；此时**尚未取到该墓碑的离线设备**上线后，会把该笔记判为"仅本地有"而重新上传 ⇒ **删除被复活**。硬删除先于网络写入且无回滚。

**必要澄清（推翻一条初判）**：有初判认为"GC 路径未写入 `purgedUuids`，导致 M1 防复活机制不覆盖它"。经复核**该说法不成立**——`hardDeleteByUuid` 内部在同一事务中调用了 `_addPurgedUuidInTxn`（`database_handler.dart:1751-1764`），`sync_engine.dart:1697/1709` 的注释**属实**。但 `purgedUuids` 只保护**本机**不复活，无法阻止**其他尚未同步的设备**重新上传，故风险依然成立。

**边界**：需要时钟漂移 > 30 天（较极端），且复活的是数据（对隐私是"删除未生效"，对完整性不是丢失）。测试 `chaos_multi_client_test.dart:1768` 只覆盖了"两端时钟一致"的场景。

---

### M5｜Node 版原子写使用固定临时文件名，并发写互相截断 — 中

`server/nodejs/src/storage/fs.js:405-419`：

```js
const tmpPath = filePath + '.tmp';        // 无随机后缀
const fd = fs.openSync(tmpPath, 'w');     // O_TRUNC
fs.writeSync(fd, data); fs.fsyncSync(fd); fs.closeSync(fd);
await fs.promises.rename(tmpPath, filePath);
```

**确证**：同一资源（典型场景：多设备并发 PUT 同一 manifest）共享同一个 `.tmp` 路径，`O_TRUNC` 互相截断，可能 rename 出半写文件。Go 版已修复为随机后缀（`internal/storage/fs.go:519-525` `fmt.Sprintf("%s.%s.tmp", path, hex...)`）。

**影响**：manifest 损坏或多设备更新丢失——这正是同步服务端最不能出错的地方。属"Go 版已有正确范本、Node 版未同步"的典型。

---

### M6｜Node 版无条件信任 `X-Forwarded-For` 最左一跳 — 中

`server/nodejs/src/auth.js:125-130`：

```js
const xff = req.headers['x-forwarded-for'];
if (xff) { const first = xff.split(',')[0].trim(); if (first) return first; }
```

**确证**：Go 版仅在 `trustProxy` 开启时信任且取**最右**一跳（`internal/auth/auth.go:172-179`）。`docs/server-api-spec.md:753` 自己也记录了该差异。

**影响**：伪造 XFF 即可绕过 10 次/分的失败限流（无限爆破 token）、把 429 打到受害者 IP、污染审计日志。Go 版不受影响。

---

### M7｜服务端单 vault 单静态 token，无配额、无按设备吊销 — 中

**确证**：`server/go/internal/server/server.go:67` `store.NewVault(storage.DefaultVaultID)`——vaultID 硬编码，HTTP 层无任何身份维度；配额方面全仓仅单请求上限（`server.go:218` `MaxBytesReader` 默认 64MB），无总容量/租户配额。

**影响**：所有设备共用一把静态 token，任一设备泄露即全量暴露且无法单独吊销；持 token 者可无限次 PUT 写满磁盘（配合 Docker 无 `read_only` 可拖垮宿主）。

**口径**：`docs/server-implementation.md:696` 已说明"多 vault 接口已预留但未在 HTTP 层暴露"，属**已知设计边界**。风险在于用户按"多用户服务器"部署时会完全越权——文档已提示"同一 vault 多用户共享不是预期场景"，但部署文档未同步该限制到醒目位置。

---

### M8｜明文 HTTP 面偏大 — 中

**确证链**：
- `android/app/src/main/AndroidManifest.xml:15` `android:usesCleartextTraffic="true"`（Android 9+ 默认为 false，此处显式放开）
- `server/go/internal/server/server.go:180-186`：未配置 `CertFile/KeyFile` 时打印 WARNING 后以纯 HTTP 启动；`deploy/config.json`、`docker/config.json`、`dist/.wsns-bundle/config.json` 均未配置证书
- `server/docker/docker-compose.yml:28-32` 端口映射 `"4080:4080"` 绑定所有网卡，默认 token `${WSNS_TOKEN:-change-me-to-a-strong-random-token}`

**影响**：Bearer token 与密文在链路上明文传输。密文本身已有 GCM 保护，**机密性影响有限**；真实风险是**可被中间人重放/回滚**（与 H3 叠加）以及 token 可被嗅探后重放（服务端无时间戳/nonce 机制）。

**公正说明**：`docs/server-api-spec.md:712` 明确要求"生产环境必须使用 HTTPS"；`install.sh` 本身质量不错（`set -euo pipefail`、专用 `safenotes` 用户、目录 0700、配置 0640、自动生成 192bit token、**无 `curl | sh`、无 `chmod 777`**）。

---

### M9｜数据目录可被环境变量整体重定向 — 中

`lib/src/platform/data_dir_override_native.dart:53-72`：

```dart
final env = Platform.environment['SN_DATA_DIR'];
if (env != null && env.isNotEmpty) { dataDirOverride = env; }
...
SharedPreferencesStorePlatform.instance = FilePreferencesStore(File(p.join(dir,'preferences.json')));
```

**影响**：数据库（含 `sync_meta.keyring` 密钥材料）、prefs、日志可被同机任意能设置环境变量的进程整体重定向；portable 模式会把含 keyring 的库写到 exe 同级 `app_data/`，若安装在 OneDrive/网盘同步目录会被上传并多实例互覆盖。属"便利性换安全性"的取舍，需文档显著提示。

---

### M10｜数据库层性能：缺关键索引 + 串行全表解密 + N+1 — 中

- **索引缺失**：`database_handler.dart:958-969` 只建 `uuid`/`deleted`/`synced` 三个索引；而 `readNoteByContentHash`（`:1221-1235`）与 `existsContentHash`（`:1242-1252`）按 `content_hash` 查询 ⇒ **每次调用全表扫描**；`readDeletedNotes` 按 `updated_at` 排序同样无索引。
- **串行解密**：`:1338-1351` `for (final row in rows) healthy.add(await _fromEncryptedRow(row));` 逐条 await；而同文件 `_readAllNotesStrict:1363` 用了 `Future.wait`，两处不一致。
- **N+1**：`:1812-1817` `hardDeleteAllDeleted` 每条 uuid 两次读+写；`:2817-2843` `mergeRemoteNoteMetas` 每条远端一次 SELECT + 一次 INSERT；`:1469/1492/1501` 单次保存触发 4 条 SQL。

**影响**：在千条级笔记规模下即可感知（回收站每次进入全量重解密）。**未发现**正确性问题，纯性能债务。

---

### M11｜日志 Web 服务器：release 默认关闭，但一旦开启暴露面过大 — 中

**判定结论：不是"生产默认开启的漏洞"。**

确证闸门：`lib/utils/dev_mode.dart:42-45` —— `kDebugMode` 恒 true，release 读 `PreferencesStorage.isDevMode`，而 `preference_and_config.dart:624` 默认 `?? false`；`lib/views/home.dart:199-201` 自动启动前有 `if (!DevMode.isActive) return;`。Web 侧 stub 恒关。⇒ **release 首次安装不会开启**，仅在 debug 构建或用户主动"关于页连点 5 次"开启。

但开启后的确证风险值得记入：
- `log_webserver_io.dart:156` 绑定 `InternetAddress.anyIPv4`（= 0.0.0.0 所有网卡），而文件头注释 `:49` 将其描述为"仅绑定 0.0.0.0（局域网可访问），不做公网暴露"——**把 0.0.0.0 当作"不暴露"是认知错误**
- `:317-321` `Access-Control-Allow-Origin: *` ⇒ 任意网站可跨域请求本地调试端口
- 敏感端点：`/api/download/db`（下载整库）、`/api/download/all`（日志+db+prefs+journal 打包 ZIP）、`/api/prefs`、`/api/db?table=&limit=`
- Token 强度足够（`Random.secure()` 16 字节，`:170-172`），且 `:237-244/310-314` 对除 OPTIONS 外全部强制校验；但 token 经 **URL query** 传递（会进浏览器历史与日志）
- 已做防护：`/logfile?name=` 过滤了 `.. / \`（`:443`），无目录穿越

**建议**：至少改为默认绑定 `127.0.0.1` 并移除 `ACAO: *`。

---

### M12｜i18n 缺译 + 一处插值 key 永不命中 — 中

**确证（抽样验证）**：`'Failed to restore note'`（`lib/views/deleted_notes.dart:178`）与 `'Authentication'`（`lib/views/settings/security_settings_page.dart:67`）均以 `.tr()` 调用，但在 `assets/translations/` 下**检索不到对应 key** ⇒ 中文界面直接显示英文硬编码。

`scripts/i18n_audit.py` 实测报告 MISSING 13 条（含 `sync_diagnostics_page.dart`、`pin_setting.dart:518`、`backup_setting.dart:157`、`login.dart:871` 等）+ BROKEN 1 条（`version_history_page.dart:170` `'Failed to compute diff: $e'.tr()` —— 插值字符串作 key，翻译表永远匹配不上）。

**工程根因**：该脚本质量不错（支持隐式字符串拼接检测、插值 key 检测、`--fill`），但**未接入任何任务运行器与 CI**（见 L13）。

---

### M13｜Go / Node 双实现的安全修复不对称（系统性）— 中

这是本次审查中**最具解释力的一条观察**，它把 H2、M5、M6、L8、L9 统一为同一根因。

**确证**：Go 实现内部存在一套**编号化的安全修复记录**，每条都带注释说明修复了什么：

| 编号 | 修复内容 | Go 侧证据 | Node 侧现状 |
|---|---|---|---|
| **S-1** | 配置文件加载失败必须致命退出 | `config.go:187` 注释"修复 S-1" | ❌ `config.js:96-103` 仅告警后回退默认值 |
| **C-2** | 「正确凭证即白名单」：先校验 token 再判限流 | `server.go:228` 注释"修复 C-2" | ❌ `server.js:102-117` 限流在认证**之前** |
| **C-3** | 原子写临时文件加随机后缀 | `fs.go:519` 注释"修复 C-3" | ❌ `fs.js:407` `filePath + '.tmp'` 固定名 |
| — | XFF 仅在 `trustProxy` 时信任且取最右一跳 | `auth.go:165-179`（注释明写"攻击者在公网可直接伪造 XFF…"） | ❌ `auth.js:123-130` 无条件信任且取最左一跳 |
| L-3 / L-4 | 环境变量优先级 / 弱 token 告警 | `config.go:193-207` | ❌ 均无 |

**佐证**：`server/go` 含 `auth_test.go`、`config_test.go`、`fs_test.go` 三个测试文件；`server/nodejs`（8 文件 / 1,601 行）**无任何测试**，且 `server/nodejs/server.js:201` 无法绑定回环地址（只有 `port` 无 `addr`，Go 版支持 `-addr 127.0.0.1:4080`）。

**结论**：Node 实现的定位应被明确为**早期原型**，其安全姿态显著落后于同仓 Go 实现。要么补齐上述 4–5 项（均有 Go 版可直接照搬的正确范本），要么在文档中显著标注"仅供本地开发、勿用于生产"。当前 `docs/server-implementation.md:3` 仅称其为"参考实现"，力度不足。

---

## 5. 低危问题与工程债务（13 项）

| # | 问题 | 位置 |
|---|---|---|
| L1 | `FlutterCryptography.enable()` **从未被调用**（全仓仅注释提及），宣称的"Android/iOS 平台原生 AES-GCM、快 50 倍"未生效，实际为纯 Dart | `packages/core/lib/src/crypto/crypto.dart:34/173/489` |
| L2 | 会话密钥/口令内存不清零：`clearDataKey()` 仅置 null 未 `fillRange`；`_passphrase = ''` 对不可变 String 无效。Dart 语言的结构性限制，非本仓独有 | `database_handler.dart:437-440`；`preference_and_config.dart:704-708` |
| L3 | 文档滞后：`docs/db-schema.md:12` 写"Schema 版本 4"、只列 2 表 3 索引；代码为 **v7**，另有 `note_meta`/`note_versions` 两表 | `database_handler.dart:726` |
| L4 | README 引用的 `SECURITY.md`、`AUTHORS.md` **在仓库中不存在** | 根目录已核实缺失 |
| L5 | `analysis_options.yaml` 仅 `include: package:flutter_lints/flutter.yaml`，无 `errors:` 加固、无 `strict-casts`；exclude 项重复（`temp/**` 两次、`**/*.g.dart` 两次） | 根目录 |
| L6 | 依赖卫生：`rename`（换包名 CLI 工具）被放在 `dependencies` 而非 `dev_dependencies`；`tuple`/`logger`/`modal_bottom_sheet`/`awesome_extensions`/`flutter_svg`/`meta` 疑似零引用 | `pubspec.yaml:48` 等（静态推断，建议实跑 `dependency_validator` 复核） |
| L7 | Node 版日志泄露 Authorization 前 12 字符（`"Bearer " + token 前 5 位`）且记录含 query 的完整 URL；Go 版输出 `sha256:` 前 8 位且 info 级只记 Path | `server/nodejs/src/middleware.js:39-44,88` vs `server/go/internal/server/middleware.go:122-128` |
| L8 | Node 版限流在认证**之前**，NAT 后多设备/他人扫端口会连坐，合法用户窗口内无法用正确 token 自愈（Go 版先校验再 Reset） | `server/nodejs/server.js:102-117` vs `server/go/internal/server/server.go:231-244` |
| L9 | Node 版条件写（`ifMatch`/`ifNoneMatch`）读 ETag 后直接写，全程无锁 ⇒ TOCTOU；Go 版持 `v.mu` | `server/nodejs/src/storage/fs.js:208-224` vs `server/go/internal/storage/fs.go:253-277` |
| L10 | 备份文件非原子写（直接 `writeAsStringSync` 到目标路径，无 tmp+rename）。而改密码前强制备份依赖该文件作为唯一回滚手段 | `lib/utils/scheduled_task.dart:173/196/244/276`、`lib/models/file_handler.dart:316` |
| L11 | CLI `db wipe` 不需解锁（只需 `--yes`）。破坏性操作无口令二次校验，且会连带删除 journal | `bin/cli_commands.dart:166-175`（注：`db info` 走 `unlocked()`，:134） |
| L12 | Android 仍申请 `READ/WRITE_EXTERNAL_STORAGE` + `requestLegacyExternalStorage="true"`；对隐私类应用偏宽 | `AndroidManifest.xml:4-5,11` |
| L13 | 工程一致性：`justfile`/`Makefile`/`Taskfile.yml` 三套运行器任务重复；`Makefile:33` 注释仍指向已不存在的 `lib/utils/build_info.dart`（实际为 `scripts/generate_build_info.dart`）；CI 未执行 `integration_test/`、`i18n_audit.py`、`dependency_validator` | 根目录 + `.github/workflows/` |

---

## 6. 澄清：不是问题的问题（避免误报）

以下条目在初轮审查中被提出，**经回到源码复核后判定为不成立或属有意设计**，特此记录以防后续重复"修复"：

| 初判 | 复核结论 |
|---|---|
| "墓碑 GC 未写入 `purgedUuids`，防复活机制不覆盖" | **不成立**。`hardDeleteByUuid` 内部在同一事务调用 `_addPurgedUuidInTxn`（`database_handler.dart:1751-1764`），引擎注释属实。剩余风险见 M4（跨设备复活），与 purgedUuids 无关 |
| "会话监听整条链路失效、计时器停摆" | **不成立**。`sessionStateStream` 未传 ⇒ 包内 `_isListensing` 恒为 true，**计时器一直在跑**，锁定功能正常。真实缺陷是"开关事件成死代码 + 键盘活动不重置"（M3） |
| "CLI 绕过锁定直接读写数据库" | **不成立**。`db info` 等需 `await unlocked(ctx)`（`bin/cli_commands.dart:134`）。仅 `db wipe` 免密（L11），且 wipe 本身即删除全部数据 |
| "备份不含 note_meta 是未发现的严重 bug" | **部分不成立**。设计文档已记载为既有取舍（`docs/backup-scheme-revamp-20260831.md:96`）。真正未被记录的是 `note_versions` 丢失（H1） |
| "6 位 PIN 可分钟级离线爆破" | **夸大**。按 `crypto.dart:108` 实测 200–330ms/次推算，10⁶ 组合单核约 2.3–3.8 天（M2） |
| "KDF 参数过低 / nonce 复用 / 密钥落日志" | **均有反证**。新 vault 为 Argon2id 32MiB/t=3/p=2 + 16B 随机 salt（`crypto.dart:109-118`）；nonce 12B 全部 `Random.secure()` 且无外部传入固定值；日志只记长度与指纹前 8 位 |
| "改密码 O(1) 是宣传话术" | **不成立**。`keyring.dart:908-1002` 只重包裹 32 字节 + `keyVersion+1` + 单键 `setMeta`，`dataKey` 不变、不重加密笔记；`keyring_test.dart` 锁定该行为。（UI 层改密流程含备份与同步，端到端耗时并非 O(1)，但密钥轮转确为 O(1)） |
| "服务端存在路径遍历 / CORS 过宽 / 非恒定时间比较" | **均不成立**。两套实现均有 `filepath.Clean`/`path.posix.normalize` + 段级 `..` 拒绝 + 落盘前缀包含校验；全仓无 `Access-Control-Allow-Origin`；Go 用 `subtle.ConstantTimeCompare`、Node 用 `crypto.timingSafeEqual` |
| "TLS 校验被客户端关闭" | **不成立**。`packages/core/lib` 全仓无 `badCertificateCallback` / `allowInsecure` |
| "编辑-删除冲突丢失数据" | **属有意取舍**。`sync_engine.dart:1986-1988` 注释明确：一端删除一端存活时交给 LWW、不另存副本，以避免副本增殖。代价是并发编辑内容无留存——应作为"已知风险接受项"，非 bug |
| "资源泄漏 / 空 catch / setState-after-dispose" | **抽查未发现**。15 处页面的 Timer/Controller/FocusNode/Subscription 均有释放；全 `lib` 正则扫描无空 `catch`；关键 `setState` 均有 `mounted` 守卫 |

---

## 7. 修复优先级建议（按 ROI 排序）

| 优先级 | 事项 | 理由 | 成本 |
|---|---|---|---|
| **P0** | **M13 整体**：Node 版补齐 S-1/C-2/C-3 + XFF 四项（H2 + M5 + M6 + L8 + L9） | 同一根因、同一批修复；Go 版已有可直接照搬的正确范本，且 Go 注释已写明修复理由 | 低 |
| **P0** | H2 单独立项：配置加载失败改 `process.exit(1)` | 静默回退弱 token 是最难被察觉的一类失败 | 极低 |
| **P1** | H1 备份纳入 meta+versions，或至少在 UI 明示"备份不含标签与历史版本" | 直接的静默数据丢失；后者一行文案 | 低 |
| **P1** | M1/M2 去掉"包裹层提升安全性"的表述，或将包裹密钥移出同库；M2 补 `onPinFailed()` 计数 | 消除承诺与实现的落差 | 中 |
| **P1** | M3 把 `sessionStateStream` 正确传给 `SessionTimeoutManager`，或移除死代码并为键盘事件补监听 | 桌面端打字被登出是真实体验缺陷 | 低 |
| **P2** | H3 manifest 抗回滚（把 header/version 绑定进 items 的 AAD，或改用带密钥 MAC） | 需协议版本升级与兼容处理 | 中高 |
| **P2** | M10 补 `content_hash`/`updated_at` 索引、改 `Future.wait` | 迁移需 bump schema 版本（当前 v7） | 低 |
| **P2** | M11 日志服务器改绑 127.0.0.1、移除 `ACAO: *` | 三行改动 | 极低 |
| **P3** | L13 CI 接入 `integration_test`、`i18n_audit.py`、`dependency_validator`；L3/L4 文档补齐 | 防止同类问题复发 | 低 |
| **P3** | L1 `FlutterCryptography.enable()` 或删掉性能宣称 | 二选一即可 | 低 |

---

## 8. 审查局限（诚实声明）

以下内容**未覆盖**，报告中相关结论请勿视为已验证：

1. **未执行任何测试套件**。本机未定位到可用的 `dart`/`flutter` 可执行文件（`C:/Home/Develop/flutter/bin/dart` 不存在），`dart test packages/core/test` 与 `flutter test` 均未能运行。测试覆盖度的判断来自**静态阅读测试文件**，而非运行结果的绿色证明。
2. **`sync_engine.dart` 第 850–1300 行**未逐行复核（占该文件约 14%），该区间包含 Step 1 分支 2（他端改密码中止）、`_MigrationRequiredException` 抛出点等；相关结论依赖行号级检索与调用序列推断。
3. **Go 版 `internal/backup/` 模块**未细读（快照/归档路径拼接与磁盘占用）。
4. **未做动态验证**：无渗透测试、无并发压测、无真机时钟漂移实验。M4（时钟）、M5（并发写）、M6（限流绕过）均为静态推演。
5. **依赖漏洞扫描未执行**（无 `dart pub outdated` / `npm audit` / `govulncheck` 结果）。
6. **iOS 平台**未审查（`ios/` 目录与 `Info.plist` 的 `NSURLIsExcludedFromBackupKey` 设置未核实，明文导出文件是否会被 iCloud 同步属未验证项）。
7. 部分行号为本次工作区快照，若文件在审查后发生变更需重新核对。

---

*本报告基于 2026-09-16 工作区代码快照静态审查产出。所有"确证"结论均可通过报告中的 `文件:行号` 复核；所有"存疑"与"未覆盖"项已在 §8 声明。*
