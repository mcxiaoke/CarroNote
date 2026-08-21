# shadcn_ui 主题色板参考（shadcn_ui 0.56.1）

> 本文档整理自 `temp/shadcn_ui-0.56.1/lib/src/theme/color_scheme/` 下各预设色板的源码，
> 以及 `lib/models/shad_theme.dart`（SafeNotes 对 shadcn_ui 的对接层）。
> 所有 hex 值均为源码中的出厂默认值（已去掉 `0xff` alpha 前缀，转为标准 `#rrggbb`）。
>
> 适用版本：`shadcn_ui 0.56.1`。如升级依赖，请以包内源码为准。

---

## 一、可自定义的语义色 key

shadcn_ui 的所有颜色都挂在 `ShadColorScheme` 上（定义见 `base.dart`）。
它包含 **20 个固定语义色 + 1 个自定义扩展 map**，全部可在 `copyWith(...)` 中单独覆盖。

在组件里通过 `ShadTheme.of(context).colorScheme.<key>` 读取，例如：
`theme.colorScheme.card`（卡片背景）、`theme.colorScheme.primary`（主品牌色）。

| key | 中文含义 | 典型用途 |
|---|---|---|
| `background` | 应用/组件主背景 | 页面与组件的主底色 |
| `foreground` | 主文字色 | 主文本、标题 |
| `card` | 卡片背景 | `ShadCard` / 卡片容器背景 |
| `cardForeground` | 卡片文字 | 卡片上的主文字 |
| `popover` | 弹层背景 | 下拉 / 菜单 / Tooltip / Select 背景 |
| `popoverForeground` | 弹层文字 | 弹层内文字 |
| `primary` | 主品牌色 | 填充按钮、选中态、激活态底色 |
| `primaryForeground` | 主色上的文字 | `primary` 之上的前景文字 |
| `secondary` | 次级表面 | Segmented、次级按钮底色 |
| `secondaryForeground` | 次级表面文字 | 次级表面上的文字 |
| `muted` | 弱化表面 | 禁用 / 非激活态底色 |
| `mutedForeground` | 弱化文字 | 提示语、caption、次要说明 |
| `accent` | 强调表面 | hover、高亮选中项底色 |
| `accentForeground` | 强调表面文字 | 强调表面上的文字 |
| `destructive` | 危险操作色 | 删除按钮底色 |
| `destructiveForeground` | 危险色文字 | 危险操作上的文字 |
| `border` | 边框 | 分割线、卡片描边 |
| `input` | 输入框边框 | 文本输入框边框 |
| `ring` | 焦点环 | 键盘聚焦高亮环 |
| `selection` | 文本选中高亮 | 选中文本的底色 |
| `custom` | 自定义扩展色 | `Map<String, Color>`，用于业务自定义色（`theme.colorScheme.custom['xxx']`） |

### 覆盖方式（copyWith）

在 `lib/models/shad_theme.dart` 的 `ShadThemes.build(...)` 中，SafeNotes 以某个预设为基础，
再用 `.copyWith(...)` 注入品牌色：

```dart
final scheme =
    (brightness == Brightness.light
            ? const ShadSlateColorScheme.light()
            : const ShadSlateColorScheme.dark())
        .copyWith(
          primary: base.primary,                 // 覆盖为 M3 品牌色
          primaryForeground: base.onPrimary,
          secondary: base.secondary,
          secondaryForeground: base.onSecondary,
          accent: base.primaryContainer,
          accentForeground: base.onPrimaryContainer,
          destructive: errorColor,               // 固定红
          destructiveForeground: onErrorColor,
          ring: base.primary,
          selection: base.primary.withValues(alpha: 0.2),
          // 其余 key 不写 = 沿用所选预设的默认值
        );
```

`copyWith` 的完整参数签名见 `base.dart:181`（每个 key 都有对应的可选参数）。
未写出的 key 会**沿用基础预设的默认值**。

### SafeNotes 当前的覆盖状态

由于底层用的是 `ShadSlateColorScheme`，且 `copyWith` 只覆盖了品牌相关色，
所以实际生效情况如下（详情见第三节）：

- **已被品牌色覆盖（不取 slate 默认值）**：`primary`、`primaryForeground`、`secondary`、
  `secondaryForeground`、`accent`、`accentForeground`、`destructive`、`destructiveForeground`、
  `ring`、`selection`。
- **沿用 slate 默认值**：`background`、`foreground`、`card`、`cardForeground`、
  `popover`、`popoverForeground`、`muted`、`mutedForeground`、`border`、`input`。

> 注意：SafeNotes 的**页面底层背景**（`scaffoldBackgroundColor`）来自 M3 的
> `ColorScheme.surfaceContainerLow`（见 `lib/models/app_theme.dart`），**不**是这里的
> `ShadColorScheme.background`。两者是并存的独立体系。

---

## 二、预定义主题（Color Scheme）默认值

共 12 个预设，分两组：

- **中性灰阶组（5 个）**：`slate` / `gray` / `neutral` / `zinc` / `stone`
  —— 背景、卡片、边框都用灰，区别只在灰的**色温**（冷蓝 / 纯灰 / 暖米等）。
- **彩色主色组（7 个）**：`blue` / `green` / `red` / `rose` / `orange` / `violet` / `yellow`
  —— 中性基底不变，把 `primary` / `ring` 设成对应彩色，作为 UI 主色。

下表每个预设都给出 **Light / Dark** 两套值。

### 2.1 中性灰阶组

#### slate —— 偏冷蓝灰（清冷、科技感；SafeNotes 当前使用）

| Color Key | Light | Dark |
|---|---|---|
| background | `#ffffff` | `#020817` |
| foreground | `#020817` | `#f8fafc` |
| card | `#ffffff` | `#020817` |
| cardForeground | `#020817` | `#f8fafc` |
| popover | `#ffffff` | `#020817` |
| popoverForeground | `#020817` | `#f8fafc` |
| primary | `#0f172a` | `#f8fafc` |
| primaryForeground | `#f8fafc` | `#0f172a` |
| secondary | `#f1f5f9` | `#1e293b` |
| secondaryForeground | `#0f172a` | `#f8fafc` |
| muted | `#f1f5f9` | `#1e293b` |
| mutedForeground | `#64748b` | `#94a3b8` |
| accent | `#f1f5f9` | `#1e293b` |
| accentForeground | `#0f172a` | `#f8fafc` |
| destructive | `#ef4444` | `#ef4444` |
| destructiveForeground | `#f8fafc` | `#f8fafc` |
| border | `#e2e8f0` | `#1e293b` |
| input | `#e2e8f0` | `#1e293b` |
| ring | `#020817` | `#cbd5e1` |
| selection | `#b4d7ff` | `#355172` |

#### gray —— 标准中性灰（略冷，最"标准"）

| Color Key | Light | Dark |
|---|---|---|
| background | `#ffffff` | `#030712` |
| foreground | `#030712` | `#f9fafb` |
| card | `#ffffff` | `#030712` |
| cardForeground | `#030712` | `#f9fafb` |
| popover | `#ffffff` | `#030712` |
| popoverForeground | `#030712` | `#f9fafb` |
| primary | `#111827` | `#f9fafb` |
| primaryForeground | `#f9fafb` | `#111827` |
| secondary | `#f3f4f6` | `#1f2937` |
| secondaryForeground | `#111827` | `#f9fafb` |
| muted | `#f3f4f6` | `#1f2937` |
| mutedForeground | `#6b7280` | `#9ca3af` |
| accent | `#f3f4f6` | `#1f2937` |
| accentForeground | `#111827` | `#f9fafb` |
| destructive | `#ef4444` | `#ef4444` |
| destructiveForeground | `#f9fafb` | `#f9fafb` |
| border | `#e5e7eb` | `#1f2937` |
| input | `#e5e7eb` | `#1f2937` |
| ring | `#030712` | `#d1d5db` |
| selection | `#b4d7ff` | `#355172` |

#### neutral —— 最纯、几乎无色相的灰（最干净不挑）

| Color Key | Light | Dark |
|---|---|---|
| background | `#ffffff` | `#0a0a0a` |
| foreground | `#0a0a0a` | `#fafafa` |
| card | `#ffffff` | `#0a0a0a` |
| cardForeground | `#0a0a0a` | `#fafafa` |
| popover | `#ffffff` | `#0a0a0a` |
| popoverForeground | `#0a0a0a` | `#fafafa` |
| primary | `#171717` | `#fafafa` |
| primaryForeground | `#fafafa` | `#171717` |
| secondary | `#f5f5f5` | `#262626` |
| secondaryForeground | `#171717` | `#fafafa` |
| muted | `#f5f5f5` | `#262626` |
| mutedForeground | `#737373` | `#a3a3a3` |
| accent | `#f5f5f5` | `#262626` |
| accentForeground | `#171717` | `#fafafa` |
| destructive | `#ef4444` | `#ef4444` |
| destructiveForeground | `#fafafa` | `#fafafa` |
| border | `#e5e5e5` | `#262626` |
| input | `#e5e5e5` | `#262626` |
| ring | `#0a0a0a` | `#d4d4d4` |
| selection | `#b4d7ff` | `#355172` |

#### zinc —— 偏冷、带一点紫调的灰（冷而非蓝）

| Color Key | Light | Dark |
|---|---|---|
| background | `#ffffff` | `#09090b` |
| foreground | `#09090b` | `#fafafa` |
| card | `#ffffff` | `#09090b` |
| cardForeground | `#09090b` | `#fafafa` |
| popover | `#ffffff` | `#09090b` |
| popoverForeground | `#09090b` | `#fafafa` |
| primary | `#18181b` | `#fafafa` |
| primaryForeground | `#fafafa` | `#18181b` |
| secondary | `#f4f4f5` | `#27272a` |
| secondaryForeground | `#18181b` | `#fafafa` |
| muted | `#f4f4f5` | `#27272a` |
| mutedForeground | `#71717a` | `#a1a1aa` |
| accent | `#f4f4f5` | `#27272a` |
| accentForeground | `#18181b` | `#fafafa` |
| destructive | `#ef4444` | `#ef4444` |
| destructiveForeground | `#fafafa` | `#fafafa` |
| border | `#e4e4e7` | `#27272a` |
| input | `#e4e4e7` | `#27272a` |
| ring | `#18181b` | `#d4d4d8` |
| selection | `#b4d7ff` | `#355172` |

#### stone —— 最暖，带米黄/棕调（柔和自然）

| Color Key | Light | Dark |
|---|---|---|
| background | `#ffffff` | `#0c0a09` |
| foreground | `#0c0a09` | `#fafaf9` |
| card | `#ffffff` | `#0c0a09` |
| cardForeground | `#0c0a09` | `#fafaf9` |
| popover | `#ffffff` | `#0c0a09` |
| popoverForeground | `#0c0a09` | `#fafaf9` |
| primary | `#1c1917` | `#fafaf9` |
| primaryForeground | `#fafaf9` | `#1c1917` |
| secondary | `#f5f5f4` | `#292524` |
| secondaryForeground | `#1c1917` | `#fafaf9` |
| muted | `#f5f5f4` | `#292524` |
| mutedForeground | `#78716c` | `#a8a29e` |
| accent | `#f5f5f4` | `#292524` |
| accentForeground | `#1c1917` | `#fafaf9` |
| destructive | `#ef4444` | `#ef4444` |
| destructiveForeground | `#fafaf9` | `#fafaf9` |
| border | `#e7e5e4` | `#292524` |
| input | `#e7e5e4` | `#292524` |
| ring | `#0c0a09` | `#d6d3d1` |
| selection | `#b4d7ff` | `#355172` |

**中性组色温速记**：`slate`→蓝灰冷，`zinc`→紫灰冷，`gray`→标准灰，
`neutral`→纯灰，`stone`→暖米灰。

### 2.2 彩色主色组

> 彩色预设的 `background` / `card` / `border` 等中性表面仍用灰（多为 slate 系灰），
> 仅 `primary` / `ring` 与对应彩色一致。下表只列出与中性组不同的关键值，
> 中性表面（background/foreground/card/cardForeground/popover/popoverForeground/
> secondary/secondaryForeground/muted/mutedForeground/accent/accentForeground/
> border/input）规律同中性组，列全以便查阅。

#### blue —— 蓝主色

| Color Key | Light | Dark |
|---|---|---|
| background | `#ffffff` | `#020817` |
| foreground | `#020817` | `#f8fafc` |
| card | `#ffffff` | `#020817` |
| cardForeground | `#020817` | `#f8fafc` |
| popover | `#ffffff` | `#020817` |
| popoverForeground | `#020817` | `#f8fafc` |
| primary | `#2563eb` | `#3b82f6` |
| primaryForeground | `#f8fafc` | `#0f172a` |
| secondary | `#f1f5f9` | `#1e293b` |
| secondaryForeground | `#0f172a` | `#f8fafc` |
| muted | `#f1f5f9` | `#1e293b` |
| mutedForeground | `#64748b` | `#94a3b8` |
| accent | `#f1f5f9` | `#1e293b` |
| accentForeground | `#0f172a` | `#f8fafc` |
| destructive | `#ef4444` | `#ef4444` |
| destructiveForeground | `#f8fafc` | `#f8fafc` |
| border | `#e2e8f0` | `#1e293b` |
| input | `#e2e8f0` | `#1e293b` |
| ring | `#2563eb` | `#1d4ed8` |
| selection | `#b4d7ff` | `#355172` |

#### green —— 绿主色

| Color Key | Light | Dark |
|---|---|---|
| background | `#ffffff` | `#0c0a09` |
| foreground | `#09090b` | `#f2f2f2` |
| card | `#ffffff` | `#1c1917` |
| cardForeground | `#09090b` | `#f2f2f2` |
| popover | `#ffffff` | `#171717` |
| popoverForeground | `#09090b` | `#f2f2f2` |
| primary | `#16a34a` | `#22c55e` |
| primaryForeground | `#fff1f2` | `#052e16` |
| secondary | `#f4f4f5` | `#27272a` |
| secondaryForeground | `#18181b` | `#fafafa` |
| muted | `#f4f4f5` | `#262626` |
| mutedForeground | `#71717a` | `#a1a1aa` |
| accent | `#f4f4f5` | `#292524` |
| accentForeground | `#18181b` | `#fafafa` |
| destructive | `#ef4444` | `#ef4444` |
| destructiveForeground | `#fafafa` | `#fef2f2` |
| border | `#e4e4e7` | `#27272a` |
| input | `#e4e4e7` | `#27272a` |
| ring | `#16a34a` | `#15803d` |
| selection | `#b4d7ff` | `#355172` |

#### red —— 红主色

| Color Key | Light | Dark |
|---|---|---|
| background | `#ffffff` | `#0a0a0a` |
| foreground | `#0a0a0a` | `#fafafa` |
| card | `#ffffff` | `#0a0a0a` |
| cardForeground | `#0a0a0a` | `#fafafa` |
| popover | `#ffffff` | `#0a0a0a` |
| popoverForeground | `#0a0a0a` | `#fafafa` |
| primary | `#dc2626` | `#dc2626` |
| primaryForeground | `#fef2f2` | `#fef2f2` |
| secondary | `#f5f5f5` | `#262626` |
| secondaryForeground | `#171717` | `#fafafa` |
| muted | `#f5f5f5` | `#262626` |
| mutedForeground | `#737373` | `#a3a3a3` |
| accent | `#f5f5f5` | `#262626` |
| accentForeground | `#171717` | `#fafafa` |
| destructive | `#ef4444` | `#ef4444` |
| destructiveForeground | `#fafafa` | `#fafafa` |
| border | `#e5e5e5` | `#262626` |
| input | `#e5e5e5` | `#262626` |
| ring | `#dc2626` | `#dc2626` |
| selection | `#b4d7ff` | `#355172` |

#### rose —— 玫红/粉红主色

| Color Key | Light | Dark |
|---|---|---|
| background | `#ffffff` | `#0c0a09` |
| foreground | `#09090b` | `#f2f2f2` |
| card | `#ffffff` | `#1c1917` |
| cardForeground | `#09090b` | `#f2f2f2` |
| popover | `#ffffff` | `#171717` |
| popoverForeground | `#09090b` | `#f2f2f2` |
| primary | `#e11d48` | `#e11d48` |
| primaryForeground | `#fff1f2` | `#fff1f2` |
| secondary | `#f4f4f5` | `#27272a` |
| secondaryForeground | `#18181b` | `#fafafa` |
| muted | `#f4f4f5` | `#262626` |
| mutedForeground | `#71717a` | `#a1a1aa` |
| accent | `#f4f4f5` | `#292524` |
| accentForeground | `#18181b` | `#fafafa` |
| destructive | `#ef4444` | `#ef4444` |
| destructiveForeground | `#fafafa` | `#fef2f2` |
| border | `#e4e4e7` | `#27272a` |
| input | `#e4e4e7` | `#27272a` |
| ring | `#e11d48` | `#e11d48` |
| selection | `#b4d7ff` | `#355172` |

#### orange —— 橙主色

| Color Key | Light | Dark |
|---|---|---|
| background | `#ffffff` | `#0c0a09` |
| foreground | `#0c0a09` | `#fafaf9` |
| card | `#ffffff` | `#0c0a09` |
| cardForeground | `#0c0a09` | `#fafaf9` |
| popover | `#ffffff` | `#0c0a09` |
| popoverForeground | `#0c0a09` | `#fafaf9` |
| primary | `#f97316` | `#ea580c` |
| primaryForeground | `#fafaf9` | `#fafaf9` |
| secondary | `#f5f5f4` | `#292524` |
| secondaryForeground | `#1c1917` | `#fafaf9` |
| muted | `#f5f5f4` | `#292524` |
| mutedForeground | `#78716c` | `#a8a29e` |
| accent | `#f5f5f4` | `#292524` |
| accentForeground | `#1c1917` | `#fafaf9` |
| destructive | `#ef4444` | `#ef4444` |
| destructiveForeground | `#fafaf9` | `#fafaf9` |
| border | `#e7e5e4` | `#292524` |
| input | `#e7e5e4` | `#292524` |
| ring | `#f97316` | `#ea580c` |
| selection | `#b4d7ff` | `#355172` |

#### violet —— 紫主色

| Color Key | Light | Dark |
|---|---|---|
| background | `#ffffff` | `#030712` |
| foreground | `#030712` | `#f9fafb` |
| card | `#ffffff` | `#030712` |
| cardForeground | `#030712` | `#f9fafb` |
| popover | `#ffffff` | `#030712` |
| popoverForeground | `#030712` | `#f9fafb` |
| primary | `#7c3aed` | `#6d28d9` |
| primaryForeground | `#f9fafb` | `#f9fafb` |
| secondary | `#f3f4f6` | `#1f2937` |
| secondaryForeground | `#111827` | `#f9fafb` |
| muted | `#f3f4f6` | `#1f2937` |
| mutedForeground | `#6b7280` | `#9ca3af` |
| accent | `#f3f4f6` | `#1f2937` |
| accentForeground | `#111827` | `#f9fafb` |
| destructive | `#ef4444` | `#ef4444` |
| destructiveForeground | `#f9fafb` | `#f9fafb` |
| border | `#e5e7eb` | `#1f2937` |
| input | `#e5e7eb` | `#1f2937` |
| ring | `#7c3aed` | `#6d28d9` |
| selection | `#b4d7ff` | `#355172` |

#### yellow —— 黄主色

| Color Key | Light | Dark |
|---|---|---|
| background | `#ffffff` | `#0c0a09` |
| foreground | `#0c0a09` | `#fafaf9` |
| card | `#ffffff` | `#0c0a09` |
| cardForeground | `#0c0a09` | `#fafaf9` |
| popover | `#ffffff` | `#0c0a09` |
| popoverForeground | `#0c0a09` | `#fafaf9` |
| primary | `#facc15` | `#facc15` |
| primaryForeground | `#422006` | `#422006` |
| secondary | `#f5f5f4` | `#292524` |
| secondaryForeground | `#1c1917` | `#fafaf9` |
| muted | `#f5f5f4` | `#292524` |
| mutedForeground | `#78716c` | `#a8a29e` |
| accent | `#f5f5f4` | `#292524` |
| accentForeground | `#1c1917` | `#fafaf9` |
| destructive | `#ef4444` | `#ef4444` |
| destructiveForeground | `#fafaf9` | `#fafaf9` |
| border | `#e7e5e4` | `#292524` |
| input | `#e7e5e4` | `#292524` |
| ring | `#0c0a09` | `#a16207` |
| selection | `#b4d7ff` | `#355172` |

> 彩色预设普遍规律：`ring` 在亮色模式多数取对应彩色（yellow 因黄色过亮、亮色 `ring` 取近黑 `#0c0a09` 以保证可见）；
> `destructive` 全为 `#ef4444`，`selection` 亮色 `#b4d7ff` / 暗色 `#355172`，与中性组一致。

---

## 三、SafeNotes 中的实际生效情况

SafeNotes 的 shadcn_ui 主题对接层只有一处：`lib/models/shad_theme.dart` 的 `ShadThemes.build(...)`。

### 当前策略

1. **基础色板**：固定使用 `ShadSlateColorScheme`（中性蓝灰）。
2. **品牌色注入**：通过 `.copyWith(...)` 把 `primary` 系列与 `destructive`、`ring`、`selection`
   覆盖为 M3 `ColorScheme.fromSeed(seed)` 生成的品牌色（来自用户选的主题 seed 色）。
3. **两套体系并存**：shadcn_ui 的 `ShadColorScheme` 只作用于 `ShadXxx` 组件；
   普通 Material 页面由 `lib/models/app_theme.dart` 的 M3 `ThemeData` 主题化，
   页面底层背景 `scaffoldBackgroundColor` 取自 M3 的 `surfaceContainerLow`，**不**走这里的
   `ShadColorScheme.background`。

### 各 key 实际来源

| key | 实际来源 |
|---|---|
| background / foreground / card / cardForeground / popover / popoverForeground / muted / mutedForeground / border / input | `ShadSlateColorScheme` 默认值（即本文档 slate 行） |
| primary / primaryForeground / secondary / secondaryForeground / accent / accentForeground / ring / selection | `copyWith` 注入的 M3 品牌色（随主题 seed 与明暗变化） |
| destructive / destructiveForeground | `copyWith` 注入的固定红（`light.error` / `light.onError`） |

因此：**切换主题 seed 色时，只有被 `copyWith` 覆盖的品牌相关色会变色；
`card` / `border` / `muted` 等中性表面永远保持 slate 的蓝灰色，不随主题色变化。**

### 如何切换底层预设

- **换灰阶底色/边框色温**（如觉得 slate 太蓝，想用更暖的 stone 或更纯的 neutral）：
  改 `shad_theme.dart` 中基础两行的 `ShadSlateColorScheme` →
  `ShadStoneColorScheme` / `ShadNeutralColorScheme` 等（其余 `copyWith` 不动，
  品牌色注入不受影响）。

- **直接用某个彩色当主色**（而非跟随用户 theme seed）：
  把基础换成 `ShadBlueColorScheme` 等，并**删除 `copyWith` 里的 `primary: base.primary` 等品牌色覆盖行**，
  否则会被品牌色覆盖回去。

- **按名字取任意预设**（包内也提供工厂方法，便于动态切换）：
  `ShadColorScheme.fromName('slate', brightness: Brightness.light)`。

---

## 四、源码位置速查

| 内容 | 文件 |
|---|---|
| 语义色字段定义 + `copyWith` / `merge` 签名 | `temp/shadcn_ui-0.56.1/lib/src/theme/color_scheme/base.dart` |
| 各预设默认值 | `temp/shadcn_ui-0.56.1/lib/src/theme/color_scheme/{slate,gray,neutral,zinc,stone,blue,green,red,rose,orange,violet,yellow}.dart` |
| `fromName` 工厂 | `base.dart`（`ShadColorScheme.fromName`） |
| SafeNotes 对接层 | `lib/models/shad_theme.dart`（`ShadThemes.build`） |
| SafeNotes 页面背景（M3，独立体系） | `lib/models/app_theme.dart`（`scaffoldBackgroundColor: base.surfaceContainerLow`） |
