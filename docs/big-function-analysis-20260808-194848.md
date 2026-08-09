# 巨型函数统计分析报告

> 生成时间：2026-08-08 19:48 (GMT+8)
> 统计范围：`lib/` + `packages/*/lib/` 下全部 Dart 源文件（排除 `*_test.dart`）
> 扫描文件：78 个 ｜ 识别函数/方法：**561 个**（含 UI build 方法）
> 配套脚本：`temp/analyze_bigfuncs.py`（可复跑）

---

## 一、重要更正（必须先读）

**本次重写了函数边界解析器，修正了一个会导致行数"虚高"的严重 bug。**

旧脚本（之前错误分析里引用的 `_resolveConflict` 597 行、`keyring.load` 486/572 行、`_buildLocalManifest` 342 行等）只统计**函数帧自身**的花括号，不统计 `class` / `if` / `while` 等花括号。结果是：一个函数打开后，其内部的类、`}` 不会让它闭合，于是它把后面所有代码（直到文件结束或某个巧合的 `{`）全部"吞"进自己的函数体，行数被严重夸大。

**经逐行核对源码确认的真实行数（与修正后解析器一致）：**

| 函数 | 旧脚本误报 | 真实行数 | 核实方式 |
|---|---|---|---|
| `_resolveConflict` (sync_engine.dart) | 597 | **6** | 读源码 1905–1910，`}` 在第 1910 行 |
| `keyring.load` (keyring.dart) | 486/572 | **24** | 读源码 209–232，`}` 在第 232 行 |
| `_buildLocalManifest` (sync_engine.dart) | 342 | **48** | 读源码 1352–1399，`}` 在第 1399 行 |
| `_uploadJournal` (sync_engine.dart) | 65 | **7** | 读源码 162–168，try/catch 小函数 |

**修正后的解析器已通过 5 处独立抽查（行数、函数边界与源码逐行吻合），本报告所有数字均以此为准。** 下文所有数据均为真实值。

---

## 二、统计口径与方法

1. **"函数"定义**：带显式返回类型 / `get`·`set` / `factory` 修饰符 / `Type.` 点号前缀（工厂构造）的方法。已排除 `Text(...)`、`setState(...)`、`await x(...)`、`obj.method(...)`、`Type.staticMethod(...)` 等**调用误判**。
2. **行数（LOC）**：函数体（含签名行与结尾 `}`）的物理行数。
3. **if/else 分支数**：统计函数体内
   - 每个 `if (...)` 计 **1**；
   - 每个 `else`（含 `else if` 的 `else`）计 **1**；
   - `else if` 内层的 `if` **不重复计**（避免双计）。
   - ⚠️ **`switch` / `case` 不计入**（Dart 的 `switch` 是独立分支结构）。因此"分支数=0"的函数未必无逻辑，可能用了 `switch`/顺序 `return`。
4. **类型归类**：同步/数据逻辑（sync_engine / sync_service / sync_models / webdav 等）、UI/构建（`build` 及 `_build*`/路由/设置页）、日志/调试。

---

## 三、总体分布

| 指标 | 数值 |
|---|---|
| 扫描文件数 | 78 |
| 识别函数/方法总数 | 561 |
| 函数行数中位数 | 13 |
| 函数行数均值 | 21.0 |
| 最大单函数行数 | **393**（`_syncOnce`） |
| **LOC ≥ 200 的巨型函数** | **4 个** |
| **LOC ≥ 100 的函数** | **12 个** |
| **LOC ≥ 60 的函数（本报告重点）** | **29 个** |
| 29 个巨型函数的 if/else 分支合计 | 141 |
| 分支数为 0 的巨型函数 | 6 个（均为 `build`/投影类，见下文） |

**按类型分布（29 个 LOC≥60）：**

| 类型 | 数量 | 说明 |
|---|---|---|
| UI / 构建（`build` 及页面拼装） | 17 | 声明式 Widget 树，行数大但分支少 |
| 同步 / 数据逻辑 | 9 | 真正的复杂度热点 |
| 日志 / 调试 | 1 | `_buildHtmlPage` 拼 HTML |
| 其他 / UI | 2 | 路由、启动引导 |

---

## 四、巨型函数完整清单（LOC ≥ 60，共 29 个）

> 类型标注：`[逻]`=逻辑密集　`[UI]`=声明式 UI/构建　`[日志]`=调试页面

| # | 函数名 | 位置 | 行数 | if/else | 类型 | 功能简述 |
|---|---|---|---|---|---|---|
| 1 | `_syncOnce` | sync_engine.dart:500 | **393** | 24 | [逻] | **一次同步尝试的核心编排**：拉远端 manifest→解密→与本地比较→计算上传/下载/删除/冲突 action→乐观锁与 keyVersion 守卫→scenario 分支。全项目最复杂的单函数。 |
| 2 | `_repairRemoteOnce` | sync_engine.dart:931 | **257** | 10 | [逻] | 单次远端修复尝试：拉取远端 manifest、用 keyring 解密 items、对比本地、修复不一致（孤儿/损坏 blob 等）。 |
| 3 | `_settings` | settings.dart:62 | 255 | 2 | [UI] | 设置页整页 Widget 树拼装（声明式 UI）。 |
| 4 | `generateRoute` | route_generator.dart:49 | 200 | 8 | [UI] | 路由工厂：按 `RouteSettings.name` 映射到各页面 Widget，集中路由表。 |
| 5 | `_buildHtmlPage` | log_webserver.dart:346 | 181 | 12 | [日志] | 构造调试 Web 页面 HTML（内嵌 CSS+JS），按诊断数据拼装前端页面字符串。 |
| 6 | `build` | theme_setting.dart:51 | 170 | 0 | [UI] | 主题设置页 Widget 构建。 |
| 7 | `build` | drawer.dart:54 | 144 | 2 | [UI] | 应用侧边栏 Drawer 构建。 |
| 8 | `_buildBody` | sync_settings.dart:53 | 136 | 3 | [UI] | 同步设置页主体内容构建。 |
| 9 | `_finalSublmitChange` | change_passphrase.dart:314 | 117 | 9 | [逻] | 改密码最终提交：校验、重新包装 dataKey、写回 keyring、触发同步/迁移。 |
| 10 | `_gcOrphanBlobs` | sync_engine.dart:2501 | 110 | 7 | [逻] | 孤儿 blob 两阶段垃圾回收（候选观察制），manifest PUT 后调用。 |
| 11 | `build` | sync_diagnostics_page.dart:542 | 107 | 1 | [UI] | 同步诊断页某区块构建。 |
| 12 | `build` | sync_diagnostics_page.dart:786 | 102 | 1 | [UI] | 同步诊断页另一区块构建。 |
| 13 | `sync` | sync_service.dart:397 | 89 | 4 | [逻] | 手动触发同步（互斥、状态更新、通知监听者）。 |
| 14 | `sync` | sync_engine.dart:226 | 83 | 2 | [逻] | 执行一次完整同步（编排 `_syncOnce`、统计、重试判定）。 |
| 15 | `_bootstrap` | main.dart:111 | 77 | 3 | [UI] | 应用启动初始化：加载偏好、初始化 keyring/日志/同步引擎。 |
| 16 | `build` | deleted_notes.dart:215 | 72 | 0 | [UI] | 最近删除页 Widget 构建。 |
| 17 | `build` | sync_diagnostics_page.dart:99 | 72 | 4 | [UI] | 同步诊断页头部/概览构建。 |
| 18 | `build` | note_card.dart:40 | 71 | 0 | [UI] | 笔记卡片 Widget 构建。 |
| 19 | `_buildDrawer` | home.dart:467 | 69 | 2 | [UI] | 主页抽屉菜单构建。 |
| 20 | `build` | note_tile.dart:39 | 69 | 0 | [UI] | 笔记列表项 Widget 构建。 |
| 21 | `_journalAction` | sync_engine.dart:2641 | 69 | 0 | [逻] | 把笔记级 action 投影为 journal 条目（统一在 `_addAction` 漏斗记录）。 |
| 22 | `_buildActionCard` | sync_diagnostics_page.dart:388 | 68 | 13 | [UI] | 诊断页单条同步操作卡片构建（按类型分 13 个分支渲染）。 |
| 23 | `_parseAndVerifyContainer` | sync_models.dart:1002 | 66 | 6 | [逻] | v5 容器解析 + pubHash 校验，反序列化 header + 加密 items。 |
| 24 | `repairRemote` | sync_service.dart:491 | 65 | 4 | [逻] | 全面校验修复远端数据（委托 `SyncEngine.repairRemote`）。 |
| 25 | `_loginController` | set_passphrase.dart:311 | 63 | 6 | [逻] | 设置密码流程的登录/校验控制。 |
| 26 | `build` | search_widget.dart:48 | 62 | 0 | [UI] | 搜索控件 Widget 构建。 |
| 27 | `_onSyncStateChanged` | home.dart:127 | 61 | 5 | [逻] | 同步状态变化回调（如他端改密码强制重登提示）。 |
| 28 | `_initKeyring` | set_passphrase.dart:387 | 60 | 9 | [逻] | 初始化 Keyring：生成 dataKey + encryptedDataKey，注入密钥。 |
| 29 | `listManifestBackups` | webdav_backend.dart:766 | 60 | 4 | [逻] | WebDAV 后端列出 manifest 备份（从新到旧）。 |

---

## 五、关键解读

### 5.1 真正的复杂度热点（逻辑密集，应优先重构）
只有 **2 个函数**真正称得上"巨型且复杂"：
- **`_syncOnce`（393 行 / 24 分支）**——同步核心编排，混合了拉取、解密、比较、action 计算、乐观锁守卫、scenario 分支。这是 `sync_engine` god-file 里最该拆的地方。
- **`_repairRemoteOnce`（257 行 / 10 分支）**——远端修复单轮逻辑，同样混合多职责。

其余同步逻辑函数（`_gcOrphanBlobs` 110、`_parseAndVerifyContainer` 66、`_onSyncStateChanged` 61、`_initKeyring` 60 等）行数适中、边界清晰，风险可控。

### 5.2 "行数大但分支少"的 `build` 方法（17 个，风险低）
`build` / `_settings` / `_buildBody` / `_buildDrawer` 等共 17 个，行数 60–255，但 if/else 分支普遍 0–4。**这些是 Flutter 声明式 Widget 树**——行数来自嵌套的 UI 组件拼装，不是控制流复杂度。除非出现"build 里做副作用/网络请求"（本项目的 `lib/main.dart` 曾有过，已在之前审查中标记），否则不应作为重构重点。

### 5.3 分支数为 0 的 6 个函数
`theme_setting.build`、`deleted_notes.build`、`note_card.build`、`note_tile.build`、`search_widget.build`、`_journalAction`——前 5 个是纯声明式 UI（无 `if`/`else`，可能用三元或 `?` 运算符）；`_journalAction` 是投影/记录逻辑（用 `switch` 或顺序 `return`，按口径不计入 if/else）。**均无控制流风险**。

### 5.4 与"错误密度"审查的关系
此前错误密度审查里提到的 `sync_engine.dart` 是 god-file（32 个 catch、多职责），结论依然成立——**它的"大"在于职责集中与函数数量多，而非单个函数体超长**。本次修正后可见：sync_engine 内真正超长的仅 `_syncOnce` 与 `_repairRemoteOnce`，其余方法（如 `_resolveConflict` 仅 6 行、`_buildLocalManifest` 48 行、`_uploadJournal` 7 行）都很精小。因此 god-file 的治理方向应是**按职责拆分类/抽取策略对象**，而非误以为要把 600 行函数切开。

---

## 六、建议（按性价比）

1. **优先拆分 `_syncOnce`（393 行）**：将其 scenario 分支（本地优先 / 远端优先 / 冲突 / 迁移 / 他端改密码中止）抽成独立的私有方法或策略对象，目标每段 ≤ 60 行。这是全项目唯一的高复杂度单体函数。
2. **拆分 `_repairRemoteOnce`（257 行）**：把"拉取→解密→逐项修复"拆为可单测的步骤。
3. **`build` 方法暂不重构**：保持声明式风格；仅排查是否有 `build` 内执行副作用（网络/文件/状态写入）。
4. **`switch`/`case` 未被计入分支**：若要看清 `generateRoute`(200)、`_buildHtmlPage`(181)、各 `toString` 的真实分支复杂度，需另行按 `switch`/`case` 统计（可扩展脚本）。

---

## 七、复跑方式

```bash
cd C:/Home/Projects/safenotes
python temp/analyze_bigfuncs.py        # 打印统计 + 写入 temp/bigfuncs.txt / temp/bigfuncs.json
```

脚本已修复的解析陷阱（供后续复用）：
- 排除 `Text(...)` / `setState(...)` 等构造调用（要求函数名前有返回类型/`get`·`set`/修饰符/`Type.` 前缀，且返回类型须大写开头或少量小写类型关键字）。
- 排除 `await x(...)` / `return x(...)` 等调用（`=>` 不再被误当返回类型）。
- 排除 `obj.method(...)` / `Type.staticMethod(...)` 调用（`Type.name` 形态仅当带 `factory`/`const` 修饰符才认作定义）。
- 字符串内 `${...}` 插值嵌套的同型引号不再提前终止字符串（避免括号泄漏）。
- **用真实括号深度（含 class/if/while 的花括号）判定函数开合**，而非仅统计函数帧括号。
