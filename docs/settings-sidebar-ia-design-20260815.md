# SafeNotes 设置项与侧栏信息架构重构方案

> 日期：2026-08-15
> 范围：客户端 Flutter，`lib/views/settings/settings.dart`、`lib/widgets/drawer.dart`、`lib/widgets/home_navigation_rail.dart` 及其导航回调
> 性质：信息架构（IA）设计文档 —— 回答「设置项如何分组排序」「侧栏该放哪些入口」两个问题，并评估是否牵动导航模式。
> 与既有文档关系：本文聚焦「信息架构」，与 `ui-ux-improvement-report-20260814.md`（视觉/精致度）互补、不重复。

---

## 0. 一句话结论

- **设置项**：从「5 组、名称不准确、Style 臃肿」重构为「4 组，按使用频率 × 重要性排序」，命名对齐主流笔记应用。
- **侧栏**：只保留「位置导航」（回收站、设置、锁定），把「动作」（切换主题）、「Settings 子页」（同步）、「低频信息页」（关于）收敛回设置页。
- **导航模式**：**不需要大改**。移动端抽屉天然适配栈式 push；仅桌面端常驻侧栏有「点二级页侧栏消失」的体验问题，用一次轻量「Shell 化」可解，且不碰路由核心。

---

## 1. 现状梳理

### 1.1 设置页现状（`lib/views/settings/settings.dart`，5 组 17 项）

| 组 | 项 |
|---|---|
| General | Backup · Export Backup · Import Backup · Language |
| Sync | Sync Settings |
| Style | Compact Notes · Relative Time · Sort by Modified Date · Switch Theme · Auto Rotate · Notes Color · Markdown |
| Security | Biometric · Logout on Inactivity · Secure Display · Incognito Keyboard · Change Passphrase · Lock |
| Miscellaneous | Source Code · Open Source License |

### 1.2 侧栏现状（桌面 `home_navigation_rail.dart` = 移动 `drawer.dart`，7 项）

```
Switch Theme / Settings / Recently Deleted / Sync Settings / About
──────────────────────────────────────────────
Lock
```

### 1.3 导航拓扑（`lib/routes/route_generator.dart`）

- 根 `'/'` → `AuthWall`（登录 / 首次设密码）→ 登录成功 `pushNamedAndRemoveUntil('/home')`。
- `HomePage`（全部笔记）是唯一「根」页面，抽屉 / 侧栏长在它身上。
- 「最近删除 / 设置 / 关于 / 同步设置」均为 `pushNamed` 压栈的二级页面，各自独立 Scaffold、**不带侧栏**，返回即 pop 回主页。
- Lock / 登出 → `pushNamedAndRemoveUntil('/login')` 清栈回登录页。

---

## 2. 现状问题诊断

1. **「General」名不副实**：把「备份 / 导出 / 导入 / 语言」四类不相干的东西塞进一个「通用」。
2. **「Style」臃肿且混杂**：7 项里混了三类——主题外观（切换主题、彩色笔记）、笔记显示（紧凑、Markdown、相对时间、排序）、设备行为（自动旋转）。
3. **数据类设置被拆散**：「Sync」组孤零零 1 项，而备份相关的 3 项散在 General。
4. **主题设置分散三处**：Switch Theme（弹层内还藏 Theme Color）、Notes Color、Theme Color 各自为政。
5. **「Miscellaneous」与 About 页功能重叠**：源码 / 开源许可本质属「关于」范畴。
6. **「Lock」两处重复**：设置页 Security 组与侧栏底部各有一处。
7. **Auto Rotate 桌面端无意义**：纯移动端选项，却对所有平台显示。

---

## 3. 设置项重构方案

### 3.1 目标分组（4 组，按「使用频率 × 重要性」降序；2026-08-15 二次修订）

> 修订说明：实施中按用户要求进一步收敛——「更改密码口令」收回安全组（Account 组并入，原「账户类」剥离理由不再适用）；「关于」不再独立成组，作为通用组的最后一个入口（About 页内承载源码 / 开源许可 / 反馈）；版本号 / DEBUG 徽标从设置页底部移到抽屉与侧栏底部。

| # | 组 | 项 | 说明 |
|---|---|---|---|
| 1 | **外观 Appearance** | Dark mode · Theme Color · Notes Color · Compact Notes · Markdown · Relative Time · Sort by Modified | 高频、天天调；主题与界面观感归拢一处；Theme Color 在设置页显性列出（弹层不再重复） |
| 2 | **数据 Data** | Sync Settings · Backup · Export Backup · Import Backup | 换机 / 备份才动；同步与备份/迁移合并 |
| 3 | **安全 Security** | Biometric · Logout on Inactivity · Secure Display · Incognito Keyboard · Change Passphrase | 安全特性开关 + 密码管理（Change Passphrase 由原 Account 组并入） |
| 4 | **通用 General** | Language · Auto Rotate · About | 基础设置；Auto Rotate 仅移动端显示；About 为低频信息页入口（源码 / 许可 / 反馈在 About 页内） |

### 3.2 排序逻辑

- 组间：外观 → 数据 → 安全 → 通用，即「高频 → 低频」「观感 → 数据 → 安全 → 低频信息」。
- 组内：视觉（主题/配色）在前，排版（紧凑/Markdown）居中，时间与排序（信息呈现方式）靠后。

### 3.3 关键取舍

1. **Theme Color 与 Dark mode 弹层去重**：弹层原本内置主题色入口，设置页显性列出 Theme Color 后，弹层内的主题色项已移除，二者不再重复；主题入口统一为设置页的「Dark mode（开弹层）+ Theme Color（进色库）」，强化发现性。
2. **Lock 移出设置页**：只保留侧栏底部的 Lock，桌面 / 移动一致，消除两处重复。
3. **Auto Rotate 平台判断**：复用 `utils/platform_ui.dart` 的 `isDesktopPlatform` / `isIOS`，桌面端隐藏该行。
4. **版本号 / DEBUG 徽标移到抽屉与侧栏底部**：设置页底部不再显示版本信息；抽屉与侧栏底部以分多行小字展示（复用 `widgets/footer.dart` 的 `footer()`）。
5. **开发者模式入口移到 About 页大 LOGO**：由设置页底部连点版本号改为在 About 页连点大图标 5 次开启。

---

## 4. 侧栏重构方案

核心原则：**侧栏只放「去哪」（位置导航），不放「做什么」（动作开关）；低频、属于 Settings 子页的入口统一收敛进 Settings。**

### 4.1 目标结构

- **移动端 Drawer（抽屉）**：

  ```
  Notes（全部笔记）      ← 新增：返回主页
  Recently Deleted
  Settings
  ──────────────────────
  Lock
  ```

- **桌面端 Sidebar（常驻）**：

  ```
  Recently Deleted
  Settings
  ──────────────────────
  Lock
  ```

  （桌面侧栏本身常驻主页，故无需「Notes」项。）

### 4.2 移出项去向

| 移出项 | 去向 |
|---|---|
| Switch Theme | Settings → 外观组 |
| Sync Settings | AppBar 同步状态按钮（`_syncStatusButton`）+ Settings → 数据组 |
| About | 随 Source Code / License 并入 About 页，由 Settings → 关于组进入 |

### 4.3 注意点

- **Sync Settings 移出侧栏的前提**：未配置同步时 AppBar 按钮不显示，用户只能靠 Settings → 数据组入口，链路仍通，需确认无死角。

---

## 5. 导航模式评估：是否要大改

**结论：不需要大改，且只有桌面端半程涉及「平行」诉求。**

| 方案 | 做法 | 改动范围 | 判断 |
|---|---|---|---|
| **A. 只精简侧栏 + 重排设置**（本轮） | 保持 push 栈式，仅改侧栏 item 与设置分组 | 0 路由改动，只改 `drawer.dart` / `home_navigation_rail.dart` / `settings.dart` | 移动端完美；桌面端点二级页时侧栏暂时消失（现状即如此，非新引入） |
| **B. 桌面端 Shell 化**（可选二期） | 桌面端新建「常驻侧栏 + 内容区 IndexedStack」外壳，把 Notes / 回收站 / 设置装进去；移动端仍 drawer + push | 新建 1 个 Shell，改造 3 个页面为「内容化」，**不动 RouteGenerator / 登录 / session** | 桌面侧栏不消失、状态可保留，体验最优 |
| **C. 彻底平级化**（暂缓） | 引入 go_router ShellRoute 或嵌套 Navigator，三页真正平级 + 深链 | 重写 RouteGenerator、`app.dart` 换 `MaterialApp.router`、登录 / authwall / session 全部重构 | 对「移动优先 + 桌面补充」定位收益不明显，成本高，不建议现在做 |

**推荐路径**：本轮先做方案 A；方案 B 单独排一个迭代（等「桌面点二级页侧栏消失」被确认为真实痛点）；方案 C 不做。

---

## 6. 落地改动清单（方案 A）

| 文件 | 改动 |
|---|---|
| `lib/views/settings/settings.dart` | 重排为 4 组；Change Passphrase 并入安全组；Dark mode 替换 Switch Theme；About 并入通用组末尾；Auto Rotate 加平台判断；Lock 移除；Source Code / License 移除（迁 About）；底部版本号 / DEBUG 徽标移除 |
| `lib/widgets/drawer.dart` | 移动抽屉 item 收敛为 Notes / Recently Deleted / Settings / Lock；移除 Switch Theme / Sync Settings / About；底部补版本号小字 |
| `lib/widgets/home_navigation_rail.dart` | 桌面侧栏 item 收敛为 Recently Deleted / Settings / Lock；底部补版本号小字 |
| `lib/views/home.dart` | 导航回调：移除 `onSyncSettingsCallback` / `onAboutCallback`，抽屉补 `onNotesCallback`（pop 回主页） |
| `lib/views/settings/theme_setting.dart` | Dark mode 弹层移除重复的 Theme Color 项（设置页已有显式入口） |
| `lib/views/settings/about_page.dart` | 补充源码 / 开源许可 / 反馈链接（承接原 Miscellaneous）；大 LOGO 连点开启 dev 模式 |

> 注：若后续推进方案 B，则在此基础上升级桌面端为 Shell，改动集中在 `home.dart` 与新建的 Shell widget，路由表不动。

---

## 7. 验收标准

- [x] 设置页为 4 组，组名与主流产品对齐（Appearance / Data / Security / General，About 为 General 末尾入口）。
- [x] Change Passphrase 位于安全组。
- [x] Auto Rotate 仅移动端可见。
- [x] Lock 只出现在侧栏底部，设置页不再有。
- [x] 侧栏（桌面）仅含 Recently Deleted / Settings / Lock；抽屉（移动）含 Notes / Recently Deleted / Settings / Lock。
- [x] 设置页底部不再显示版本号 / DEBUG 徽标；二者移到抽屉与侧栏底部（分多行小字）。
- [x] 源码 / 开源许可可从 About 页访问。
- [x] 未配置同步时，用户仍能通过 Settings → 数据组进入同步设置。
- [x] 开发者模式由 About 页大 LOGO 连点开启。
- [x] Dark mode 弹层内不再重复展示 Theme Color 项。

---

## 附录 A：主流笔记应用对标参考

> 检索于 2026-08-15。SafeNotes 的直接对标是 **Standard Notes**（端到端加密笔记），最值得参考。

### A.1 五款代表产品横向对照

| 产品 | 侧栏放什么 | 设置入口 | 设置页组织 | 回收站位置 |
|---|---|---|---|---|
| Standard Notes | 全部笔记 · 标签树 · 归档 | 侧栏底部齿轮 | 分栏：General / Security / Backup / Appearance | 侧栏一级 Trash |
| Obsidian | 文件树 · 搜索 · 书签 · 标签 | 左下角齿轮（固定） | 分 Tab：Editor / Appearance / Hotkeys / About / 插件 | 文件树 .trash |
| Notion | Teamspaces · Shared · Private · Favorites · Inbox | 侧栏底部 Settings | 分栏 modal：Account / Language / Appearance | 侧栏底部 Trash |
| Bear | 笔记列表 · 标签树（#tag） | 齿轮图标 | 分 Tab：General / Editor / Themes / Sync / Import | 侧栏 Trash |
| Keep / Apple Notes | 笔记 · 标签 · 归档 | 顶栏菜单 | 极简，几乎无独立设置页 | 侧栏 回收站 / 最近删除 |

### A.2 四条共识（对本方案的支撑）

1. **侧栏 100% 是「内容导航」**，从不放设置动作；设置只是侧栏底部一个固定入口。→ 否定「Switch Theme 放侧栏」。
2. **回收站在每家都是侧栏一级入口**。→ 「回收站保留在侧栏」必须留。
3. **设置页分组命名高度统一**，与本方案一一对应：Appearance / Editor(Display) / Sync·Backup / Security / Account / About。唯一分歧是 Language（Obsidian 放 About、Notion 放 Language&Region、Bear 放 General），放「通用」合理。
4. **桌面端设置页普遍「分栏 / Tab」**，而非一张长滚动列表 —— SafeNotes 未来可演进方向；移动端单页分组列表本身已是主流（iOS 设置同款）。

---

## 附录 B：备选方案（未采纳，留档参考）

### B.1 设置页采用「分栏 / Tab」式（Obsidian / Bear 式）

- 做法：设置页内左侧竖排分组 Tab（Appearance / Data / Security / Account / General / About），右侧内容。
- 未采纳理由：适合桌面端，但移动端仍是单页滚动更自然；当前先做单页分组即可，分栏可作为「桌面 Shell 化」同期的进阶项。

### B.2 Export / Import 收进 Backup 子页

- 做法：设置主页「数据」组只保留「Sync Settings」「Backup」，把 Export / Import 移入 `backup_setting.dart` 子页。
- 未采纳理由：导出 / 导入是独立高频动作（换机、迁移时常用），保留在设置主页一屏可达更直接；但若追求设置主页极简，此选项可后续再议。

### B.3 侧栏保留「Sync Settings」为一级入口

- 做法：维持同步在侧栏可见。
- 未采纳理由：与 AppBar 同步状态按钮重复；且同步属于「Settings 子页」，按「侧栏只放位置导航」原则应收敛。若后续发现用户对同步入口依赖度高，可让侧栏「设置」项旁显示同步状态角标替代。

### B.4 彻底平级化导航（go_router ShellRoute）

- 做法：见正文 §5 方案 C。
- 未采纳理由：成本高、收益不明显，见 §5 判断。
