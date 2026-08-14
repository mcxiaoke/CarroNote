我已通读项目的 UI/UX 相关代码（主界面、编辑页、登录页、设置页、回收站、改密码、导出对话框、主题模型、设计令牌、各类 widget），下面是一份结构化的审查报告。
SafeNotes Flutter UI/UX 审查报告
一、总体评价
项目整体工程质量中上：已经建立了 AppSpace / AppShape / AppIcon / AppMotion 设计令牌、统一了 ShadToast 提示、引入了空 / 加载 / 错误三态封装、桌面端做了限宽居中、隐私相关设计（enableIMEPersonalizedLearning:false、Markdown 不加载图片、日志不记录笔记内容）做得很到位。
但存在三类系统性问题：
Material 与 shadcn_ui 两套设计系统并存，主题 / 颜色 / 组件混用，维护成本高且视觉不一致。
状态管理碎片化：笔记列表靠 StatefulWidget 手动 refresh，设置页靠空 setState((){}) 刷值，主题用 Provider，同步用 Stream—— 没有单一数据源。
大量 "评审 #N / P0-N / F-Hxx" 注释，说明代码经历过多轮修复但未做重构收敛，遗留 hack（width:0、GlobalKey 重建、endOfFrame 等）较多。
二、跨文件共性问题（按优先级）
P0 — 功能 / 正确性 Bug
1. 搜索框清除按钮与外部 query 不同步（疑似 bug）
widgets/search_widget.dart 内部维护自己的 TextEditingController，但外部通过 widget.text 传入 query。当空状态 CTA 或其他逻辑调用 _searchNote('') 只改外部 query 时，controller 不会清空，导致点击 "Clear Search" 后搜索框文字仍在。建议：让 controller 与外部 text 通过 didUpdateWidget 同步，或完全由外部持有 controller。
2. 笔记卡片颜色随搜索结果变化
views/home.dart 用 NotesColor.getNoteColor(notIndex: index)，index 是过滤后列表的下标。搜索过滤后同一笔记的 index 会变，颜色也跟着跳。应改用 note.id 或 note.uuid 哈希取色，保证颜色稳定。
3. showSnackBarMessage 在 dialog context 中静默失败
utils/snack_message.dart 用 ShadSonner.maybeOf(context)?.show，如果 context 不在 ShadSonner 子树内（如 showDialog 内的 context），maybeOf 返回 null，提示无声消失。建议加 fallback：ScaffoldMessenger.maybeOf(context)?.showSnackBar(...)，或统一用 navigatorKey.currentContext。
4. add_edit_note.dart 保存无 try-catch
onSaveCallback 调用 addOrUpdateNote 可能抛数据库异常，但没有错误处理，失败后页面仍关闭，用户以为保存成功。应包 try-catch，失败时 showErrorToast 并阻止关闭。
P1 — 体验明显问题
5. 两套设计系统并存（最大技术债）
app.dart 用 ShadApp.custom 内嵌 MaterialApp，同时提供 ShadTheme 与 AppThemes。
颜色引用不统一：有的用 Theme.of(context).colorScheme，有的用 ShadTheme.of(context).colorScheme。
home_navigation_rail.dart 用 colorScheme.outlineVariant（Material），drawer.dart 用 ShadTheme.colorScheme.border（shadcn），同是 Divider 颜色却不同源。
组件混用：AppBar/Scaffold/Drawer/IconButton（Material）+ ShadButton/ShadInput/ShadCard/ShadDialog（shadcn）。
建议：制定迁移路线，逐步统一到一套。推荐全量 shadcn_ui（新页面已在用，且设计令牌更完整），或全量 Material 3（Flutter 原生支持最好）。过渡期至少建立一个 AppColors 中间层，屏蔽两套 colorScheme 的差异。
6. 输入框 decoration 大量重复
note_widget.dart（标题 + 正文）、search_widget.dart 都重复写了 7 个 border: ShadBorder.none + backgroundColor: transparent。应抽取为 const kTransparentBorderlessInput = ShadDecoration(...)，或在 ShadThemes.inputTheme 中统一配置。
7. 状态管理不统一
home.dart：List<SafeNote> 普通数组 + 手动 refreshNotes()，同步 / 设置页返回都要手动刷。
settings.dart：每个导航 tile 返回后 setState((){}) 空刷新，模式重复 10+ 次。
主题：Provider；同步：Stream。
建议：统一到 Provider（项目已依赖）或 Riverpod。笔记列表、同步状态、设置偏好都应有单一数据源，UI 只消费不主动刷新。
8. 搜索无 debounce
home.dart 每次输入都全量 where + toList + setState，大笔记库（>1000 条）会卡顿。建议加 200ms debounce（用 Timer 或 rxdart.debounceTime）。
9. 登录页键盘处理导致整页重建
login.dart 第 152 行 MediaQuery.of(context).viewInsets.bottom 在 build 中读取，键盘动画期间每帧触发整页 rebuild。且 scrollToBottomIfOnScreenKeyboard() 在每次 build 都调用，可能导致滚动抖动。
对比：change_passphrase.dart 已用 _lastViewInset 记录上次值，只在键盘从无到有时触发滚动 ——这个模式应反向移植到 login.dart。
建议用 MediaQuery.viewInsetsOf(context) 细分依赖，只让需要的子树重建。
10. 国际化不完整
widgets/states.dart 第 121 行 const Text('Retry') 硬编码英文。
views/settings/settings.dart 第 324-325 行 '$seconds sec' / '${seconds ~/ 60} min' 英文缩写。
建议全局 grep -rn "'[A-Z][a-z]*'" lib/ 排查硬编码字符串，补 .tr()。
11. 无障碍（a11y）缺失
search_widget.dart 清除按钮用 GestureDetector 而非 IconButton，无 Semantics 标签，触控区域仅 24px（移动端建议 48x48）。
home.dart 排序方向切换按钮（arrow_upward/downward）无 tooltip，用户不知道当前升序还是降序。
getFontColorForBackground 对比度未验证，浅色卡片上白字可能不满足 WCAG AA。
建议：所有图标按钮加 tooltip 或 Semantics(label:)，用 flutter analyze + a11y 规则检查。
P2 — 优化建议
12. 魔法数字未收敛到设计令牌
AppSpace/AppShape/AppIcon 已定义，但仍散落：home.dart 的 14 padding、drawer.dart 的 15 圆角、deleted_notes.dart 的 14 padding、change_passphrase.dart 的 25 间距等。建议全局替换为令牌。
13. 加载骨架无闪烁动画
widgets/states.dart 的 loadingState 是静态灰色块，体验一般。可加 Shimmer 动画（shimmer 包或自写 AnimationController + LinearGradient）。且固定 count=3 列表骨架，在网格视图下不匹配，应根据布局参数生成对应形状。
14. 网格 / 列表切换无动画
home.dart 切换视图直接重建，可加 AnimatedSwitcher 或 AnimatedCrossFade 平滑过渡。
15. AppBar actions 在加载时消失导致布局跳动
home.dart isLoading 时 actions: null，整个 actions 区域消失，AppBar 标题位置跳动。应保留占位或只禁用按钮。
16. 桌面端用 BottomSheet 选主题不合适
home_navigation_rail.dart 的 onThemeCallback 直接 showThemeBottomSheet，桌面端底部面板体验差。应改用对话框或侧边面板（showDialog 或 ShadSheet 侧边滑出）。
17. 桌面侧边栏无选中态高亮
home_navigation_rail.dart 点击后导航离开主页，返回后无 "当前页" 记忆，用户不知道自己在哪。建议用 NavigationRail（Material 原生，自带选中态）或手动维护 selectedIndex。
18. shad_dialog.dart 的 width: 0 是 hack
为覆盖 shadcn 主题注入的 double.infinity，用 width: 0 避免 BoxConstraints forces an infinite width 崩溃。依赖内部实现，版本升级可能失效。建议关注 shadcn_ui 升级，或用 IntrinsicWidth 包裹。
19. deleted_notes.dart 文件头注释乱码
第 1-8 行中文注释是 GBK 被误读为 UTF-8 的乱码（鏈€杩戝垹闄よ鍥），应修复为正确 UTF-8。代码本身不受影响，但影响可读性。
20. login.dart 锁定解除时重建 GlobalKey
第 523 行 _formKey = GlobalKey<FormState>()，重建 GlobalKey 是不常见做法。虽然输入框已清空，状态丢失无影响，但应改为 _formKey.currentState?.reset()。
三、具体页面问题
主界面 views/home.dart
_syncStateSub 与 StreamBuilder 双重监听同一 stream，逻辑分散。
GestureDetector 同时 onTap + onVerticalDragStart + onVerticalDragDown 收起键盘，可能与列表滚动冲突（列表滚动时键盘意外收起）。
OpenContainer 的 closedColor 取卡片色，但卡片内部 ShadCard 也有 backgroundColor，可能双重着色。
_RotatingSyncIcon 每次同步都创建 AnimationController，可优化为共用。
dismissKeyboard 条件 if (!currentScope.hasPrimaryFocus && currentScope.hasFocus) 较绕，可简化为 FocusManager.instance.primaryFocus?.unfocus()。
_buildDrawer 中 onLockCallback 没有先 pop drawer，其他项都 pop，唯独 lock 不 pop，可能导致 drawer 留在栈上。
编辑页 views/add_edit_note.dart
编辑 / 预览切换无过渡动画，可加 AnimatedSwitcher。
Markdown 预览 imageBuilder 返回 SizedBox.shrink（隐私保护正确），但用户可能困惑为什么图片不显示，可加占位提示 "图片已禁用"。
_KeyboardAwarePadding 用 AnimatedPadding(duration: AppMotion.normal)，但与系统键盘动画时长可能不一致，导致底部 padding 动画与键盘不同步。建议用 MediaQuery.viewInsetsOf + AnimatedBuilder 跟随系统动画。
_closePage 用 endOfFrame 等待一帧（PopScope canPop 变更需要一帧生效），是 Flutter 已知 workaround 但脆弱，建议加注释说明。
Markdown 样式只覆盖了 p 标签，h1-h6 / blockquote / code 仍用默认，可能与整体风格不一致。
登录页 views/authentication/login.dart
生物识别按钮在不支持时仍显示但 disabled，可考虑隐藏减少视觉噪音。
scrollToBottomIfOnScreenKeyboard 在 build 中调用（见 P1-9）。
_buildForgotPassphrase 字体 isDesktopPlatform ? 14 : 12，应走设计令牌或主题 textTheme。
忘记密码→重置本地数据→pushNamedAndRemoveUntil('/authwall')，但数据库已 close，需确认 AuthWall 能处理重新初始化。
设置页 views/settings/settings.dart
10+ 处 setState((){}) 空刷新（见 P1-7）。
Dark Mode tile 用 shadNavigationTile 而非 shadSwitchTile，点击弹底部面板，与其他 switch tile 交互不一致。
Auto Rotate tile 描述 "Close and open app for change to take effect"，用户体验差，应能实时生效或至少提示原因。
Logout tile 直接执行登出无二次确认，虽然登出不清本地库，但仍应确认避免误触。
_VersionFooter 连点 5 次开启 dev 模式，无视觉反馈（连点几次了），用户可能不知道这个隐藏功能。
回收站 views/deleted_notes.dart
_clearAll 用 for 循环逐条 hardDelete，大量笔记时慢且 N 次 IO，应改为批量 SQL DELETE WHERE id IN (...)。
_DeletedNoteTile 中 Colors.grey / Colors.grey.shade600 / Colors.grey.shade500 硬编码，深色模式下对比度可能不足，应走主题色板。
时间格式 '${deletedTime.month}/${deletedTime.day}' 硬编码美式格式，未国际化，应走 DateFormat。
文件头注释乱码（见 P2-19）。
改密码 views/change_passphrase.dart
_finalSublmitChange 方法名拼写错误（Sublmit → Submit），应修正。
改密码流程 5 步，期间无进度指示（用户不知道卡在哪一步），建议加 ShadToast 或进度条。
_preChangeCheck 中 backend.ping() 可能慢（网络等待），无 loading 状态，按钮可被重复点击。
导出对话框 dialogs/export_backup_dialog.dart
_formatTile 用 GestureDetector 自绘单选圆点，而非 ShadRadio，注释说是为了避免对齐问题 —— 但这意味着 shadcn 组件本身有 bug 或用法不对，应优先修复用法而非自绘。
密码强度无实时提示（只在提交时校验），用户输入弱密码不知道。建议接入 zxcvbnm（项目已依赖）做实时强度条。
四、值得肯定的设计
隐私保护到位：enableIMEPersonalizedLearning:false（incognito keyboard）、Markdown imageBuilder 返回空、日志不记录笔记内容、Secure Display 选项。
设计令牌已建立：AppSpace / AppShape / AppIcon / AppMotion 四套令牌，且有明确注释说明收敛来源。
暴力破解防护：登录失败递减尝试次数 + 锁定倒计时 + Timer 随 widget 生命周期释放（F-H09 修复）。
远端验证三态：verified / wrongPassword / unreachable，网络不可达不扣尝试次数，设计合理。
桌面端适配：登录 / 设置 / 改密码都做了 maxWidth: 420 居中，避免宽窗口拉满。
键盘避让优化：change_passphrase.dart 用 _lastViewInset 只在键盘出现时滚动，模式正确。
三态封装：emptyState / loadingState / errorState 统一替代散落的 Center(Text) 和 CircularProgressIndicator。
改密码前置检查：强制备份 + 同步 + ping，失败有警告对话框让用户选择是否继续，安全意识强。
五、优先级行动清单
表格
优先级 事项  预估工作量
P0  修复搜索框清除按钮同步 bug 0.5h
P0  笔记颜色改用 note.id 取色   0.5h
P0  Toast 加 ScaffoldMessenger fallback  0.5h
P0  编辑页保存加 try-catch    0.5h
P1  制定双设计系统迁移路线，建立 AppColors 中间层    2h
P1  抽取无边框输入框 decoration 常量  0.5h
P1  搜索加 200ms debounce  1h
P1  login.dart 键盘处理反向移植 change_passphrase 模式    1h
P1  补全国际化（Retry /sec/min 等） 1h
P1  无障碍：图标按钮加 tooltip / Semantics   2h
P2  全局魔法数字替换为令牌 3h
P2  加载骨架加 Shimmer 动画    1h
P2  网格 / 列表切换加 AnimatedSwitcher 0.5h
P2  桌面端主题选择改用对话框    1h
P2  回收站批量删除改 SQL    0.5h
P2  修复 deleted_notes.dart 注释乱码  0.1h
六、长期建议
统一状态管理：引入 Riverpod 或规范 Provider 用法，笔记列表、同步状态、设置偏好都走单一数据源，消除手动 refresh 和空 setState。
统一设计系统：选择 shadcn_ui 或 Material 3 之一，逐步迁移。当前两套并存是最大技术债，每次改主题都要改两处。
补充 widget 测试：关键交互（搜索过滤、卡片颜色、PopScope 拦截、登录锁定）应有测试，避免回归。
引入 flutter_lints 更多规则：当前 analysis_options.yaml 只有 avoid_print: true，建议开启 prefer_const_constructors / use_key_in_widget_constructors / avoid_print / sized_box_for_whitespace 等，自动捕获部分问题。
性能监控：大笔记库（>1000 条）下搜索、滚动、同步刷新的帧率，用 Flutter DevTools 实测。