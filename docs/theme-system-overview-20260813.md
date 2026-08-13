# Safenotes 主题体系梳理（2026-08-13）

> 现状：M3 + FlexColorScheme + shadcn_ui 三套体系并存，业务代码混用取色。

## 1. 现在的主题体系全景

```
ThemeProvider（seed 色库 index + themeMode）
   │  seedColor
   ├──► AppThemes.build(seed, brightness)  ──► ThemeData（FCS 包装）──► MaterialApp
   │       └─ ColorScheme.fromSeed()（M3 算法）→ FlexThemeData.light/dark
   │
   └──► ShadThemes.build(seed, brightness) ──► ShadThemeData ──► ShadApp.custom
           └─ ShadSlateColorScheme 基底 + M3 色板映射（copyWith）
```

**三套体系各管什么：**

| 体系 | 角色 | 产出 | 服务对象 |
|---|---|---|---|
| **M3（material_color_utilities）** | 算法层 | `ColorScheme.fromSeed` 生成对比度合规的色板（primary/onPrimary/surfaceContainer…） | 被 FCS 和 Shad 共同调用，**不是独立主题** |
| **FlexColorScheme (FCS)** | Material 主题引擎 | `ThemeData`（按钮/输入框/AppBar 等 Material 组件主题） | `MaterialApp` → 全部 `Scaffold` 页面（home、设置、编辑、认证、对话框） |
| **shadcn_ui (Shad)** | 组件库 + 自己的主题 | `ShadThemeData`（ShadButton/ShadCard/ShadInput/ShadDialog 等） | 业务代码里显式使用的 ShadXxx 组件 |

## 2. 混用现状（代码事实）

- **32 个 lib 文件 import 了 shadcn_ui**；**19 个文件用 Scaffold**（Material 页面壳）。
- `Theme.of(context)` 取色：**22 个文件**（Material 组件 + 自定义取色）。
- `ShadTheme.of(context)` 取色：**12 个文件**（Shad 组件）。
- 主界面 home.dart：Scaffold + AppBar + Material Icon + 笔记卡片（ShadCard 包装）——**页面壳是 Material，卡片/对话框是 Shad**。
- 登录页：Scaffold 壳 + ShadInputFormField + ShadButton + ShadDialog——**壳 Material、控件 Shad**。
- 设置页：Scaffold 壳 + shadSettingsList/shadSettingsCard（Shad）+ ShadSwitch + 自定义 Material tile。
- 编辑页：Scaffold 壳 + ShadInputFormField（透明无边框）。
- 对话框：ShadDialog / 自定义 Material 混用（export_backup_dialog 里两者都有）。

**结论：没有全部迁移到 shadcn，是「Material 壳 + Shad 控件」的渐进式迁移中间态。**

## 3. 混用的问题

### 3.1 视觉不一致（最明显）
- **两套按钮/输入框/对话框并存**：同一屏幕里 ShadButton 与 FilledButton/TextButton、ShadInput 与 TextField 同时出现时，圆角、高度、hover/ripple 反馈、文字风格不同。
- **取色双轨**：`Theme.of(context).colorScheme.primary`（FCS）与 `ShadTheme.of(context).colorScheme.primary`（Shad）虽然都来自同一个 seed，但**映射规则不同**——FCS 走 FlexColorScheme 的 surface 混合/组件微调，Shad 走 M3 直映射 + Slate 基底。同一语义色在两套组件上观感不完全一致（这也是之前"按钮新色、卡片旧色"割裂的根源）。

### 3.2 主题维护成本高（易错）
- 改主题要**同时改两个文件**（`app_theme.dart` + `shad_theme.dart`），各自维护一份色板映射，漏改一处就出现割裂。
- 本次「暗色对比度修复」就是典型：Shad 侧 copyWith 漏了 primaryForeground，FCS 侧却一直是好的——双轨独立演进的必然风险。

### 3.3 组件行为差异
- Material 组件走 `ThemeData`（含 FCS subThemes 的 radius/高度微调），Shad 组件走 `ShadThemeData`（含 Slate 风格）——同一交互控件（开关、单选、文本输入）在两套体系下动效/尺寸/焦点环不一致。
- 例如 ShadSwitch 与 Material Switch、ShadRadio 与 Material Radio，虽然不会同屏出现，但**页面间手感不统一**。

### 3.4 取色脆弱
- 业务代码 `Theme.of(context).colorScheme.*` 在 Material 壳内可用；但如果某天 Shad 组件外包了 MaterialApp（ShadApp.custom 内部其实有 MaterialApp），取色来源会随 context 位置漂移，容易踩坑。
- 现有 22 处 `Theme.of(context)` 取色与 12 处 `ShadTheme.of(context)` 取色并存，语义上都是"品牌色"，但代码里没有统一出口。

## 4. 建议（供决策，未实施）

| 选项 | 做法 | 代价 | 收益 |
|---|---|---|---|
| A. 维持现状 | 双轨共存，规范取色出口 | 零改动 | 无 |
| B. 渐进收敛 | 新页面一律 Shad 组件；Material 壳页面里的裸控件逐步替换为 Shad；统一取色走一个 helper（如 `AppColors.of(context)`） | 中，需逐页替换 + 回归 | 视觉/手感统一，主题维护单一化 |
| C. 全量迁 Shad | 所有 Scaffold/AppBar/Material 组件替换为 Shad 对应物，FCS 仅保留生成基础 ThemeData | 高，几乎重写 UI 层 | 彻底统一，主题只维护 Shad 一套 |

> 业务取色（`Theme.of(context).colorScheme.*` 22 处）无论选哪条路，都建议收敛到统一出口，
> 与 `app_theme.dart` 的"插拔点"设计呼应——换主题引擎时业务层零改动。

## 5. 本次中性风格柔和化改动（已实施）

| 位置 | 改动 | 效果 |
|---|---|---|
| `shad_theme.dart` | ShadSwitch 未选中轨道 `colorScheme.input` → `m3.surfaceContainerHighest` | 暗色 `#1e293b`→`#33353a`，亮色 `#e1e2e9`，off 态不再死黑 |
| `app_theme.dart` | `scaffoldBackgroundColor` → `scheme.surfaceContainerLow` | 亮色 `#f3f3fa`、暗色 `#191c20`，缓解编辑页死白死黑，仍属中性 |

渗透度保持 shadcn 原生中性风格：background/card 仍为 Slate 中性色，品牌色只作用于控件与强调元素。
