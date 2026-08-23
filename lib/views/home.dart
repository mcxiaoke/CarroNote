/*
* Copyright (C) Keshav Priyadarshi and others - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*
* You should have received a copy of the GNU General Public License v3.0 with
* this file. If not, please visit https://www.gnu.org/licenses/gpl-3.0.html
*
* See https://safenotes.dev for support or download.
*/

import 'dart:async';
import 'dart:math' show max;

import 'package:flutter/material.dart';

import 'package:animations/animations.dart';
import 'package:core/core.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:local_session_timeout/local_session_timeout.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/dialogs/delete_confirmation.dart';
import 'package:safenotes/models/session.dart';
import 'package:safenotes/routes/route_generator.dart';
import 'package:safenotes/src/logger/log_webserver.dart';
import 'package:safenotes/sync/sync_config.dart';
import 'package:safenotes/sync/sync_service.dart';
import 'package:safenotes/utils/dev_mode.dart';
import 'package:safenotes/utils/motion.dart';
import 'package:safenotes/utils/notes_color.dart';
import 'package:safenotes/utils/platform_ui.dart';
import 'package:safenotes/utils/route_observer.dart';
import 'package:safenotes/utils/snack_message.dart';
import 'package:safenotes/utils/spacing.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/views/add_edit_note.dart';
import 'package:safenotes/widgets/drawer.dart';
import 'package:safenotes/widgets/home_navigation_rail.dart';
import 'package:safenotes/widgets/note_card.dart';
import 'package:safenotes/widgets/note_card_compact.dart';
import 'package:safenotes/widgets/note_card_press_feedback.dart';
import 'package:safenotes/widgets/note_color_picker.dart';
import 'package:safenotes/widgets/note_tile.dart';
import 'package:safenotes/widgets/note_tile_compact.dart';
import 'package:safenotes/widgets/search_widget.dart';
import 'package:safenotes/widgets/shad_dialog.dart';
import 'package:safenotes/widgets/states.dart';
import 'package:safenotes/widgets/tag_editor.dart';

/// 排序/显示偏好下拉菜单的固定宽度：足以容纳最长的开关项文字（含换行），
/// 行内 icon 左对齐、文字左对齐、switch 右对齐，且不随内容占满。
const double _kSortMenuWidth = 260;

class HomePage extends StatefulWidget {
  final StreamController<SessionState> sessionStateStream;

  const HomePage({super.key, required this.sessionStateStream});

  @override
  HomePageState createState() => HomePageState();
}

class HomePageState extends State<HomePage> with RouteAware {
  late List<SafeNote> notes;
  late List<SafeNote> allnotes;
  bool isLoading = false;
  String query = '';
  bool isNewFirst = PreferencesStorage.isNewFirst;

  /// 笔记元数据全量快照（key = note uuid），由 [_sortAndStoreNotes] 维护。
  ///
  /// 独立于 `_notesCache`（db 层 _metaCache），置顶排序只叠加 pinned 维度，
  /// 不触碰笔记正文缓存——切换置顶零解密（设计文档 §7.1、红线 5）。
  Map<String, NoteMeta> _noteMeta = const {};
  bool isGridView = PreferencesStorage.isGridView;
  bool _routeSubscribed = false;

  /// 桌面侧栏收起态(持久化,见 PreferencesStorage.isSidebarCollapsed)
  bool _sidebarCollapsed = PreferencesStorage.isSidebarCollapsed;

  /// B4 修复：监听同步状态流，消费 SyncResult.requiresRelogin。
  /// 引擎检测到"他端改密码"（scenario-b：本地 MK 解不开远端包裹）时
  /// 强制弹窗并退出登录（v4 选项 B 定案，替代旧 passwordEpochMismatch 标志），
  /// 覆盖手动同步、autoSync、改密码后推送等所有同步路径。
  StreamSubscription<SyncServiceState>? _syncStateSub;

  /// 最近一次同步状态：由 [_onSyncStateChanged] 维护（合并了原 listen +
  /// StreamBuilder 的双通道监听，见 db 审查"状态管理碎片化"），
  /// AppBar 同步状态按钮直接读本字段驱动图标。
  SyncServiceState? _lastSyncState;

  /// 每个 HomePage 生命周期只弹一次，避免 autoSync 反复触发弹窗轰炸
  bool _passwordChangedDialogShown = false;

  /// 笔记列表/网格的滚动控制器：Scrollbar 与 ScrollView 共享同一 controller，
  /// 不依赖共享的 PrimaryScrollController（多路由共存时后者会被争用导致
  /// Scrollbar 失去 ScrollPosition 抛框架异常）。
  final ScrollController _notesListScroll = ScrollController();
  final ScrollController _notesGridScroll = ScrollController();

  /// 搜索防抖（P1-6）：200ms 内连续输入只触发一次过滤，避免大笔记库卡顿。
  Timer? _debounceTimer;

  /// 排序/显示偏好菜单控制器（AppBar 排序 icon 下拉）。
  final ShadPopoverController _sortMenuController = ShadPopoverController();

  /// 仅显示星标（纯内存开关，不持久化），叠加在排序与搜索之上。
  bool _showStarredOnly = false;

  /// 按标签过滤（纯内存，不持久化）。非空时仅展示含该标签的笔记。
  String? _activeTag;

  /// 多选模式状态。
  bool _isSelectionMode = false;

  /// 多选模式下选中的笔记 uuid 集合。
  Set<String> _selectedUuids = {};

  //bool isListner = false;
  @override
  void initState() {
    super.initState();
    Log.ui.i('进入主界面');
    refreshNotes();
    // 订阅前先取当前状态，保证 AppBar 按钮在首个事件到来前就有正确图标。
    _lastSyncState = SyncService.instance.state;
    _syncStateSub = SyncService.instance.stateStream.listen(
      _onSyncStateChanged,
    );
    // 需求：日志 Web 服务器随主界面启动（全平台：移动端 + 桌面端），
    // 应用退出（detached）时由 main.dart 的 _shutdown 统一停止。
    // 放在主界面而非 SyncService，是为了让未配置同步的用户也能远程看日志。
    _startLogWebServer();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null && !_routeSubscribed) {
      routeObserver.subscribe(this, route);
      _routeSubscribed = true;
    }
  }

  @override
  void dispose() {
    if (_routeSubscribed) {
      routeObserver.unsubscribe(this);
    }
    _syncStateSub?.cancel();
    _debounceTimer?.cancel();
    _sortMenuController.dispose();
    _notesListScroll.dispose();
    _notesGridScroll.dispose();
    // 注意：此处不停止日志 Web 服务器。
    // HomePage 会因登出 / 页面跳转等原因反复销毁重建，
    // 而日志服务器的生命周期是"应用级"的，只在应用退出时结束。
    super.dispose();
  }

  /// 从设置等子页面返回时，按最新排序偏好重新排序。
  ///
  /// 排序字段（修改日期/创建日期）由设置页切换，不会经过主页顶栏的方向按钮，
  /// 故需在返回时主动重排，否则要等下次进入主页才生效。
  @override
  void didPopNext() {
    if (!mounted) return;
    _sortAndStoreNotes();
  }

  /// 启动日志 Web 服务器（幂等，失败不影响主流程）
  ///
  /// 仅 dev 模式（含 debug 构建）自动启动；非 dev 模式默认不启动，
  /// 需要时可在调试面板的 Web Server Tab 手动启停。
  Future<void> _startLogWebServer() async {
    if (!DevMode.isActive) return;
    if (LogWebServer.instance.isRunning) return;
    try {
      await LogWebServer.instance.start();
    } on Object catch (e, st) {
      Log.web.w('日志 Web 服务器启动失败（不影响应用使用）', error: e, stackTrace: st);
    }
  }

  /// B4 修复：他端改密码提示
  ///
  /// 触发条件：最近一次同步结果 requiresRelogin=true
  /// （v4 scenario-b：他端改了密码，本地 MK 解不开远端包裹，同步被中止）。
  /// 数据安全性说明：
  ///   - 本地笔记由 dataKey 加密，dataKey 在改密码时不变，笔记不受影响；
  ///   - 同步已被引擎中止（零写入），本地新建/修改的笔记保留在本地数据库；
  ///   - 退出登录只清内存密钥与会话，不删除本地数据库，
  ///     用新密码重新登录后所有笔记完好且继续同步。
  ///
  /// v4（epoch 消除）起引擎不再设置 passwordEpochMismatch 标志，
  /// 改为 requiresRelogin=true；弹窗为**强制**（不可点击遮罩/返回键跳过，
  /// 仅提供"重新登录"），符合设计定案「选项 B：失败 + 强制重登录」。
  void _onSyncStateChanged(SyncServiceState state) {
    if (!mounted) return;
    // 更新 AppBar 同步状态图标（合并 StreamBuilder 职责）。
    setState(() => _lastSyncState = state);

    // Bug B 修复：同步完成（成功或失败且已有结果）后刷新主页列表，
    // 让后台/手动同步拉取到的远端笔记立即显示，无需重启或返回设置页。
    // 主页笔记列表是 StatefulWidget 维护的普通数组（非 MVVM/Provider 驱动），
    // 引擎下载笔记只写本地数据库、不会通知 UI，故需在此主动重查。
    // 仅对"完成态"刷新（syncing/idle 等中间态不刷新，避免无谓读库）。
    if ((state.status == SyncStatus.success ||
            state.status == SyncStatus.error) &&
        state.lastResult != null) {
      refreshNotes();

      // Layer 1 提示：存在因密钥不匹配/数据损坏而未能同步（且无本机明文可自愈）
      // 的笔记时，非致命提示用户，这些笔记会在后续同步中重试。
      final failed = state.lastResult!.failedNoteUuids;
      if (failed.isNotEmpty && mounted) {
        // P2-3：错误提示走 ShadToast（destructive + 6s）。
        showErrorToast(
          context,
          '{count} notes failed to sync due to key mismatch and will be retried on the next sync'
              .tr(namedArgs: {'count': '${failed.length}'}),
        );
      }
    }

    // B4 修复：他端改密码提示（v4 起用 requiresRelogin 标志接管）
    if (_passwordChangedDialogShown) return;
    if (state.lastResult?.requiresRelogin != true) return;

    _passwordChangedDialogShown = true;
    showAppDialog(
      context: context,
      // 强制：不可点击遮罩关闭，用户必须处理"重新登录"
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        // 强制：不可用系统返回键关闭
        canPop: false,
        child: ShadDialog(
          constraints: kAppDialogConstraints,
          title: Text('Password Changed on Another Device'.tr()),
          actions: [
            shadDialogActionBar(
              actions: [
                ShadDialogAction(
                  label: 'Logout and Login Again'.tr(),
                  primary: true,
                  onPressed: () async {
                    Navigator.of(dialogContext).pop();
                    await _logoutToLogin();
                  },
                ),
              ],
            ),
          ],
          child: Text(
            'The sync passphrase was changed on another device; the current passphrase is no longer valid.\n\nLocal notes are not lost; unsynced changes are kept locally. Please log in again with the new passphrase.'
                .tr(),
          ),
        ),
      ),
    );
  }

  /// 安全登出并跳转登录页（与 drawer 的 onLogoutCallback 顺序一致）：
  /// 1. 先停会话监听；2. 导航清栈到 /login（不 await）；
  /// 3. 页面卸载后再清敏感状态。只清内存密钥，不动本地数据库。
  Future<void> _logoutToLogin() async {
    widget.sessionStateStream.add(SessionState.stopListening);

    if (mounted) {
      Navigator.pushNamedAndRemoveUntil(
        context,
        '/login',
        (Route<dynamic> route) => false,
        arguments: SessionArguments(
          sessionStream: widget.sessionStateStream,
          isKeyboardFocused: false,
        ),
      );
    }

    await Session.logout();
  }

  Future<void> refreshNotes() async {
    setState(() => isLoading = true);
    try {
      await _sortAndStoreNotes();
    } on Exception catch (e) {
      Log.ui.e('刷新笔记列表失败, 已清空列表以保持界面可交互', error: e);
      // 防御层：避免任何异常（如 dataKey 不匹配、db 损坏、迁移进行中）
      // 导致 isLoading 永远为 true，UI 一直转圈。
      // 典型场景：本地 keyring 与 db 不一致，readAllNotes 解密失败抛
      // DataKeyNotSetException；reEncryptAllNotes 期间抛
      // MigrationInProgressException。
      // 清空笔记列表并提示用户，至少让 UI 可交互（用户可登出或进入设置）。
      if (mounted) {
        setState(() {
          allnotes = notes = <SafeNote>[];
        });
        // P2-3：错误提示走 ShadToast（destructive + 6s）。
        showErrorToast(
          context,
          'Failed to load notes: {error}'.tr(namedArgs: {'error': '$e'}),
        );
      }
    } finally {
      if (mounted) {
        setState(() => isLoading = false);
      }
    }
  }

  Future<void> _sortAndStoreNotes() async {
    // storing copy of notes in allnotes so that it does not change while doing search
    // 默认按修改时间排序（新→旧），可在设置中改为创建时间
    final sortByModified = PreferencesStorage.isSortByModified;
    DateTime keyOf(SafeNote n) =>
        sortByModified ? n.modifiedTime : n.createdTime;
    // 读取元数据快照（pinned 维度），用于置顶排序与卡片角标。
    // 命中 _metaCache 时零解密；与 _notesCache 完全隔离（红线 5）。
    final metaMap = await NotesDatabase.instance.readAllNoteMeta();
    final tmpNotes = await NotesDatabase.instance.readAllNotes();
    // 两级排序：置顶(starr)恒在最前；同级内部再按原时间键排序。
    // 保持 PreferencesStorage.isSortByModified / isNewFirst 语义不变。
    tmpNotes.sort((a, b) {
      final int pa = (metaMap[a.uuid]?.pinned ?? false) ? 1 : 0;
      final int pb = (metaMap[b.uuid]?.pinned ?? false) ? 1 : 0;
      if (pa != pb) return pb.compareTo(pa); // pinned 优先
      return isNewFirst
          ? keyOf(b).compareTo(keyOf(a))
          : keyOf(a).compareTo(keyOf(b));
    });
    setState(() {
      allnotes = tmpNotes;
      _noteMeta = metaMap; // 供 2.2 卡片角标同步读取
      // 刷新时保留「仅星标/按标签」内存筛选（搜索关键词在刷新时按旧行为清空）。
      notes = _applyMetaFilters(tmpNotes);
    });
    // 界面数据装载结果：条数 + 排序方式（用户排障最常需要的两项）
    Log.ui.i(
      '主界面笔记列表已装载: ${tmpNotes.length} 条, '
      '${sortByModified ? "修改时间" : "创建时间"}/'
      '${isNewFirst ? "新→旧" : "旧→新"}',
    );
  }

  @override
  Widget build(BuildContext context) {
    Provider.of<NotesColor>(context);

    // 桌面/大屏适配（P2 NavigationRail）：用 LayoutBuilder 读实际可用宽度做断点
    // 判断，而非 MediaQuery.sizeOf（窗口尺寸）。响应式布局建议避免直接读
    // MediaQuery.size，改用约束宽度更稳健——此处 Scaffold 拿到的约束宽度即为
    // 窗口宽度，等价且重建范围更小。
    // - Compact (< 600px)：保留移动端 Drawer（汉堡菜单）
    // - Medium/Expanded (≥ 600px)：左侧常驻 NavigationRail + 内容区
    return LayoutBuilder(
      builder: (context, constraints) {
        final bool isCompact = constraints.maxWidth < kCompactBreakpoint;

        return GestureDetector(
          onTap: dismissKeyboard,
          onVerticalDragStart: dismissKeyboard,
          onVerticalDragDown: dismissKeyboard,
          child: PopScope(
            canPop: !_isSelectionMode,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop && _isSelectionMode) {
                _exitSelectionMode();
              }
            },
            child: Scaffold(
              key: const Key('ui-home-screen'),
              drawer: isCompact ? _buildDrawer(context) : null,
              appBar: _isSelectionMode
                  ? _buildSelectionAppBar()
                  : AppBar(
                      actions: isLoading
                          ? null
                          : [
                              if (_showStarredOnly || _activeTag != null)
                                _filterIndicator(),
                              _syncStatusButton(),
                              _diagnosticsButton(),
                              _shortNotes(),
                            ],
                    ),
              body: isCompact
                  ? _homeBody()
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        HomeSidebar(
                          isCollapsed: _sidebarCollapsed,
                          onToggleCollapsed: _toggleSidebarCollapsed,
                          onAllNotesCallback: _clearFilters,
                          onSettingsCallback: _navSettings,
                          onDeletedNotesCallback: _navDeletedNotes,
                          onStarredCallback: _enableStarredFilter,
                          tags: PreferencesStorage.managedTags,
                          activeTag: _activeTag,
                          onTagSelected: _enableTagFilter,
                          onManageTags: _manageTags,
                          onLockCallback: _navLock,
                        ),
                        Expanded(child: _homeBody()),
                      ],
                    ),
              floatingActionButton: _isSelectionMode
                  ? null
                  : _addANewNoteButton(context),
            ),
          ),
        );
      },
    );
  }

  /// 桌面侧栏收起/展开切换：持久化跨会话保留。
  void _toggleSidebarCollapsed() {
    setState(() => _sidebarCollapsed = !_sidebarCollapsed);
    PreferencesStorage.setIsSidebarCollapsed(_sidebarCollapsed);
  }

  /// 主页主体内容（搜索框 + 笔记列表/网格），Compact 与桌面 Rail 模式共用。
  Widget _homeBody() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1300),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [_buildSearch(), _handleAndBuildNotes()],
        ),
      ),
    );
  }

  /// AppBar 同步状态按钮
  ///
  /// 仅在同步总开关已开且后端配置完整时显示，点击跳转同步设置页。
  /// 图标根据同步状态变化：
  ///   - 未初始化/空闲：cloud_outlined
  ///   - 同步中：sync（旋转动画）
  ///   - 成功：cloud_done_outlined
  ///   - 失败：cloud_off_outlined（红色）
  Widget _syncStatusButton() {
    if (!SyncConfig.isSyncEnabled) return const SizedBox.shrink();

    final state = _lastSyncState ?? SyncService.instance.state;
    final isSyncing = state.isSyncing;
    return IconButton(
      icon: isSyncing
          ? const _RotatingSyncIcon()
          : Icon(
              _syncIconData(state.status),
              // P1-22：错误色统一走 shad destructive。
              color: state.status == SyncStatus.error
                  ? ShadTheme.of(context).colorScheme.destructive
                  : null,
            ),
      tooltip: _syncTooltip(state.status),
      onPressed: () async {
        Log.ui.i(
          '界面切换: 主界面 → 同步设置(/syncSettings), '
          '当前同步状态=${state.status.name}',
        );
        await Navigator.pushNamed(context, '/syncSettings');
        if (mounted) refreshNotes();
      },
    );
  }

  IconData _syncIconData(SyncStatus status) {
    switch (status) {
      case SyncStatus.uninitialized:
        return LucideIcons.cloudOff;
      case SyncStatus.idle:
        return LucideIcons.cloud;
      case SyncStatus.syncing:
        return LucideIcons.refreshCw;
      case SyncStatus.success:
        return LucideIcons.cloudCheck;
      case SyncStatus.error:
        return LucideIcons.cloudOff;
    }
  }

  String _syncTooltip(SyncStatus status) {
    switch (status) {
      case SyncStatus.uninitialized:
        return 'Sync not initialized'.tr();
      case SyncStatus.idle:
        return 'Sync ready'.tr();
      case SyncStatus.syncing:
        return 'Syncing…'.tr();
      case SyncStatus.success:
        return 'Sync successful'.tr();
      case SyncStatus.error:
        return 'Sync failed'.tr();
    }
  }

  /// AppBar 调试面板入口按钮
  ///
  /// 仅 dev 模式（含 debug 构建）显示；非 dev 模式隐藏入口（release 默认）。
  /// 点击跳转 /diagnostics 调试面板。
  Widget _diagnosticsButton() {
    if (!DevMode.isActive) return const SizedBox.shrink();
    return IconButton(
      icon: const Icon(LucideIcons.bug),
      tooltip: 'Debug Panel'.tr(),
      onPressed: () async {
        Log.ui.i('界面切换: 主界面 → 调试面板(/diagnostics)');
        await Navigator.pushNamed(context, '/diagnostics');
        Log.ui.d('界面返回: 调试面板 → 主界面');
      },
    );
  }

  // Widget _DevSessionListner() {
  //   return IconButton(
  //     icon: isListner ? Icon(LucideIcons.toggleRight) : Icon(LucideIcons.toggleLeft),
  //     onPressed: () {
  //       if (isListner == true)
  //         widget.sessionStateStream.add(SessionState.stopListening);
  //       else
  //         widget.sessionStateStream.add(SessionState.startListening);

  //       setState(() {
  //         this.isListner = !this.isListner;
  //       });
  //     },
  //   );
  // }

  Widget _shortNotes() {
    return ShadPopover(
      controller: _sortMenuController,
      child: IconButton(
        key: const Key('ui-home-toolbar-sort'),
        icon: const Icon(LucideIcons.funnelPlus),
        tooltip: 'Notes Preferences'.tr(),
        onPressed: () => _sortMenuController.toggle(),
      ),
      popover: (context) =>
          SizedBox(width: _kSortMenuWidth, child: _buildSortMenu(context)),
    );
  }

  /// 排序/显示偏好下拉菜单：复用排序 icon（↑/↓ 表示新→旧方向），
  /// 点击弹出开关列表，各项与设置页共用同一持久化偏好。
  Widget _buildSortMenu(BuildContext context) {
    final theme = ShadTheme.of(context);
    Widget row({
      Key? key,
      required IconData icon,
      required String title,
      required bool value,
      required ValueChanged<bool> onChanged,
    }) {
      return KeyedSubtree(
        key: key,
        child: InkWell(
          onTap: () => onChanged(!value),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.max,
              children: [
                Icon(icon, size: 18, color: theme.colorScheme.foreground),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    // ShadPopover 会给内容包一层 DefaultTextStyle(textAlign: center)，
                    // 必须显式左对齐，否则文字居中/换行时参差不齐。
                    textAlign: TextAlign.start,
                    style: theme.textTheme.p,
                  ),
                ),
                const SizedBox(width: 12),
                ShadSwitch(value: value, onChanged: onChanged),
              ],
            ),
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        row(
          key: const Key('ui-home-menu-gridview'),
          icon: LucideIcons.layoutGrid,
          title: 'Grid view'.tr(),
          value: isGridView,
          onChanged: (v) {
            setState(() {
              isGridView = v;
              PreferencesStorage.setIsGridView(v);
            });
          },
        ),
        row(
          key: const Key('ui-home-menu-newfirst'),
          icon: LucideIcons.arrowDown,
          title: 'Newest first'.tr(),
          value: isNewFirst,
          onChanged: (v) {
            setState(() => isNewFirst = v);
            PreferencesStorage.setIsNewFirst(isNewFirst);
            _sortAndStoreNotes();
          },
        ),
        row(
          key: const Key('ui-home-menu-sortmodified'),
          icon: LucideIcons.arrowUpDown,
          title: 'Sort by Modified Date'.tr(),
          value: PreferencesStorage.isSortByModified,
          onChanged: (v) {
            // 排序字段切换走同一套排序入口（内部 setState 刷新列表）。
            PreferencesStorage.setIsSortByModified(v);
            _sortAndStoreNotes();
          },
        ),
        row(
          key: const Key('ui-home-menu-relativetime'),
          icon: LucideIcons.clock,
          title: 'Relative Time'.tr(),
          value: PreferencesStorage.isRelativeTime,
          onChanged: (v) {
            PreferencesStorage.setIsRelativeTime(v);
            setState(() {}); // 时间标签（相对/绝对）随偏好即时刷新
          },
        ),
        row(
          key: const Key('ui-home-menu-compact'),
          icon: LucideIcons.shrink,
          title: 'Compact Notes'.tr(),
          value: PreferencesStorage.isCompactPreview,
          onChanged: (v) {
            PreferencesStorage.setIsCompactPreview(v);
            setState(() {}); // 卡片/紧凑瓦片样式即时切换
          },
        ),
        row(
          key: const Key('ui-home-menu-colorful'),
          icon: LucideIcons.brush,
          title: 'Notes Color'.tr(),
          value: PreferencesStorage.isColorful,
          onChanged: (v) {
            PreferencesStorage.setIsColorful(v);
            setState(() {}); // 卡片底色即时切换
          },
        ),
      ],
    );
  }

  Widget _handleAndBuildNotes() {
    final String noNotes = 'No Notes'.tr();

    return Expanded(
      child: !isLoading
          ? notes.isEmpty
                // P3-15：搜索无结果与空库区分，避免用户以为笔记被删。
                ? query.isNotEmpty
                      ? emptyState(
                          icon: LucideIcons.searchX,
                          text: 'No notes match "{query}"'.tr(
                            namedArgs: {'query': query},
                          ),
                          cta: 'Clear Search'.tr(),
                          onCta: () => _searchNote(''),
                        )
                      : emptyState(
                          icon: LucideIcons.stickyNote,
                          text: noNotes,
                          cta: 'New Note'.tr(),
                          onCta: _openAddNote,
                        )
                : (isGridView ? _buildNotes() : _buildNotesTile())
          : loadingState(),
    );
  }

  /// 新建笔记：FAB 与空状态 CTA 共用入口。
  Future<void> _openAddNote() async {
    Log.ui.i('界面切换: 主界面 → 新建笔记(/addnote)');
    await Navigator.pushNamed(
      context,
      '/addnote',
      arguments: widget.sessionStateStream,
    );
    Log.ui.d('界面返回: 新建笔记 → 主界面, 触发列表刷新');
    refreshNotes();
  }

  Widget _addANewNoteButton(BuildContext context) {
    // 原 FloatingActionButton 替换为 ShadButton：56×56 圆形悬浮，保持新建入口外观。
    return ShadButton(
      key: const Key('ui-home-fab-newnote'),
      width: 56,
      height: 56,
      padding: EdgeInsets.zero,
      decoration: ShadDecoration(
        border: ShadBorder.all(
          radius: const BorderRadius.all(Radius.circular(28)),
        ),
      ),
      onPressed: _openAddNote,
      child: const Icon(LucideIcons.plus),
    );
  }

  Widget _buildSearch() {
    final String searchBoxHint = 'Search...'.tr();

    return SearchWidget(
      text: query,
      hintText: searchBoxHint,
      onChanged: _searchNote,
    );
  }

  /// 移动端 Drawer：复用统一的导航回调（_nav*），并在每个会离开主页的入口前
  /// 先 pop 抽屉（与改动前行为一致）。桌面 Rail 模式不需要 pop，直接调 _nav*。
  ///
  /// Notes 项：抽屉本身常驻主页，点击即关闭抽屉回到全部笔记（等价「返回主页」）。
  Widget _buildDrawer(BuildContext context) {
    return HomeDrawer(
      onNotesCallback: () {
        Navigator.of(context).pop();
        // 抽屉点「笔记」回到全部笔记：清除星标/标签过滤。
        _clearFilters();
      },
      onSettingsCallback: () {
        Navigator.of(context).pop();
        _navSettings();
      },
      onDeletedNotesCallback: () {
        Navigator.of(context).pop();
        _navDeletedNotes();
      },
      onStarredCallback: () {
        Navigator.of(context).pop();
        _enableStarredFilter();
      },
      tags: PreferencesStorage.managedTags,
      activeTag: _activeTag,
      onTagSelected: (tag) {
        Navigator.of(context).pop();
        _enableTagFilter(tag);
      },
      onManageTags: () {
        Navigator.of(context).pop();
        _manageTags();
      },
      onLockCallback: () {
        _navLock();
      },
    );
  }

  /// 打开标签管理页（抽屉/侧栏标签组 header 编辑入口），保存后刷新抽屉列表。
  Future<void> _manageTags() async {
    final result = await pushTagEditor(
      context,
      title: 'Manage Tags'.tr(),
      pool: PreferencesStorage.managedTags,
      selected: const [],
      selectionMode: false,
    );
    if (result == null || !mounted) return;
    await PreferencesStorage.setManagedTags(result.pool);
    // 若当前正按某被删标签过滤，则清除过滤回到全部。
    if (_activeTag != null && !result.pool.contains(_activeTag)) {
      _clearFilters();
    } else {
      if (mounted) setState(() {});
    }
  }

  // ---- 桌面 Rail 与移动 Drawer 共用的导航动作（不带 pop，pop 由 Drawer 负责） ----

  Future<void> _navSettings() async {
    Log.ui.i('界面切换: 主界面 → 设置(/settings)');
    await Navigator.pushNamed(
      context,
      '/settings',
      arguments: widget.sessionStateStream,
    );
    // 设置页内退出登录时 '/settings' 被 removeUntil 移除，dataKey 已清，
    // 必须跳过 refresh，否则 readAllNotes 抛 DataKeyNotSetException。
    if (mounted && NotesDatabase.instance.isEncryptionEnabled) {
      refreshNotes();
    }
  }

  Future<void> _navDeletedNotes() async {
    Log.ui.i('界面切换: 主界面 → 回收站(/deletedNotes)');
    await Navigator.pushNamed(context, '/deletedNotes');
    if (mounted && NotesDatabase.instance.isEncryptionEnabled) {
      refreshNotes();
    }
  }

  /// 锁定：清空内存中的密钥与会话、跳回登录页（本地数据原样保留）。
  /// 与抽屉/侧栏的"锁定"入口一致；行为即原「退出登录」（本应用登出不清本地库）。
  Future<void> _navLock() async {
    Log.auth.i('用户主动锁定');
    await _logoutToLogin();
  }

  /// 笔记卡片的"容器放大"转场（animations OpenContainer，Material
  /// container transform 模式）：点击卡片时容器从卡片矩形放大到全屏进入
  /// 编辑页，返回时缩回原位。替代原 pushNamed('/editnote')（保留日志埋点
  /// 与返回后刷新；OpenContainer 的 route opaque:true，无黑屏问题）。
  Widget _openNoteEditorContainer({
    required SafeNote note,
    required int index,
    required bool grid,
  }) {
    // 卡片背景色：用 allnotes 中的稳定索引取色，避免搜索过滤后同一笔记颜色跳变。
    // allnotes 是排序固定的全量列表，搜索后 notes 是过滤子集，index 会变。
    // indexOf 返回其在全量列表中的位置，颜色始终与排序顺序挂钩。
    final int stableIndex = allnotes.indexOf(note);
    final int colorIndex = stableIndex >= 0 ? stableIndex : index; // 兜底
    final int? noteColor = _noteMeta[note.uuid]?.color;
    final Color cardColor = NotesColor.getNoteColorWithMeta(
      notIndex: colorIndex,
      metaColor: noteColor,
      context: context,
    );
    // 编辑页背景色：有颜色时与编辑页 Scaffold 一致，过渡更自然。
    final Color openColor =
        NotesColor.editorBackgroundColor(
          metaColor: noteColor,
          context: context,
        ) ??
        Theme.of(context).scaffoldBackgroundColor;
    final bool isSelected = _selectedUuids.contains(note.uuid);
    return OpenContainer(
      tappable: false,
      // P1-11：时长走 AppMotion.pageTransition（保持 250ms：动画期间编辑页
      // 会被 FittedBox 缩放渲染，时长过长易掉帧，故不上调到 slow）。
      transitionDuration: AppMotion.pageTransition,
      transitionType: ContainerTransitionType.fade,
      closedColor: cardColor,
      openColor: openColor,
      closedShape: RoundedRectangleBorder(
        // P1-14：与卡片圆角（AppShape.cardRadius）保持一致。
        borderRadius: BorderRadius.circular(AppShape.cardRadius),
      ),
      openShape: const RoundedRectangleBorder(),
      closedElevation: 0,
      openElevation: 0,
      routeSettings: RouteSettings(
        name: '/editnote',
        arguments: AddEditNoteArguments(
          sessionStream: widget.sessionStateStream,
          note: note,
        ),
      ),
      onClosed: (_) {
        if (mounted) refreshNotes();
      },
      closedBuilder: (context, action) => NoteCardPressFeedback(
        onTap: () {
          if (_isSelectionMode) {
            _toggleSelection(note.uuid);
            return;
          }
          // 只记录 uuid 与序号，不记录标题正文（隐私红线）
          Log.ui.i(
            '界面切换: 主界面(${grid ? "网格" : "列表"}) → 编辑笔记'
            '(/editnote) uuid=${note.uuid} index=$index',
          );
          action();
        },
        onLongPress: () => _enterSelectionMode(note.uuid),
        // ui 前缀 key：集成测试按序号定位第 N 条笔记（如 ui-home-note-1 = 第 2 条）
        child: KeyedSubtree(
          key: Key('ui-home-note-$index'),
          child: PreferencesStorage.isCompactPreview
              ? (grid
                    ? NoteCardWidgetCompact(
                        note: note,
                        index: colorIndex,
                        pinned: _noteMeta[note.uuid]?.pinned ?? false,
                        noteColor: noteColor,
                        isSelectionMode: _isSelectionMode,
                        isSelected: isSelected,
                      )
                    : NoteTileWidgetCompact(
                        note: note,
                        index: colorIndex,
                        pinned: _noteMeta[note.uuid]?.pinned ?? false,
                        noteColor: noteColor,
                        isSelectionMode: _isSelectionMode,
                        isSelected: isSelected,
                      ))
              : (grid
                    ? NoteCardWidget(
                        note: note,
                        index: colorIndex,
                        pinned: _noteMeta[note.uuid]?.pinned ?? false,
                        noteColor: noteColor,
                        isSelectionMode: _isSelectionMode,
                        isSelected: isSelected,
                      )
                    : NoteTileWidget(
                        note: note,
                        index: colorIndex,
                        pinned: _noteMeta[note.uuid]?.pinned ?? false,
                        noteColor: noteColor,
                        isSelectionMode: _isSelectionMode,
                        isSelected: isSelected,
                      )),
        ),
      ),
      openBuilder: (context, closeAction) => AddEditNotePage(
        sessionStateStream: widget.sessionStateStream,
        note: note,
      ),
    );
  }

  Widget _buildNotesTile() {
    // 桌面/大屏适配（P1-4）：桌面端原生滚动条默认隐藏，长列表难以定位。
    // 外包 Scrollbar，桌面常驻可见（thumbVisibility），移动端保持默认覆盖式。
    return Scrollbar(
      controller: _notesListScroll,
      thumbVisibility: isDesktopPlatform,
      child: ListView.separated(
        controller: _notesListScroll,
        padding: const EdgeInsets.all(14),
        itemCount: notes.length,
        itemBuilder: ((context, index) {
          final note = notes[index];
          return _openNoteEditorContainer(
            note: note,
            index: index,
            grid: false,
          );
        }),
        separatorBuilder: (BuildContext context, int index) {
          // 与网格视图 12px 间距保持一致（原 7px 偏挤）。
          return const SizedBox(height: 12);
        },
      ),
    );
  }

  Widget _buildNotes() {
    // 桌面/大屏适配（P0-1 + P1-4）：
    // 1) 原本写死 crossAxisCount:2，宽屏上只是把 2 列拉宽。改为按网格真实
    //    可用宽度计算列数（目标列宽 ~300，最小 2 列）：手机仍 2 列，桌面随
    //    窗口变宽自动增列。用 LayoutBuilder 读受限宽度（body 已限宽 1300），
    //    避免直接用 MediaQuery 取到整屏宽度导致超宽屏列数过多。
    // 2) 外包 Scrollbar，桌面常驻可见（thumbVisibility），移动端保持默认。
    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = max(2, (constraints.maxWidth / 300).floor());
        return Scrollbar(
          controller: _notesGridScroll,
          thumbVisibility: isDesktopPlatform,
          child: AlignedGridView.count(
            controller: _notesGridScroll,
            itemCount: notes.length,
            // 卡片间距：原 4px 过挤，网格里相邻卡片几乎黏在一起。
            // 12px 让每张卡片成为独立视觉单元，外边距同步放到 14px。
            padding: const EdgeInsets.all(14),
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            itemBuilder: (context, index) {
              final note = notes[index];
              return _openNoteEditorContainer(
                note: note,
                index: index,
                grid: true,
              );
            },
          ),
        );
      },
    );
  }

  /// 应用「仅星标 + 按标签」两个元数据内存筛选，返回过滤后的列表。
  ///
  /// 用于刷新/排序后重算列表；搜索时则走 [_applyViewFilter] 把关键词叠加进来。
  List<SafeNote> _applyMetaFilters(List<SafeNote> source) {
    Iterable<SafeNote> result = source;
    if (_showStarredOnly) {
      result = result.where((n) => _noteMeta[n.uuid]?.pinned ?? false);
    }
    if (_activeTag != null && _activeTag!.isNotEmpty) {
      result = result.where(
        (n) => (_noteMeta[n.uuid]?.tags ?? const []).contains(_activeTag),
      );
    }
    return result.toList();
  }

  /// 将「搜索关键词 + 仅星标/按标签」内存筛选合并应用到当前列表。
  ///
  /// 排序保持 [allnotes] 已有顺序（排序发生在 _sortAndStoreNotes），
  /// 这里只负责过滤；[query] 在调用前由 [_searchNote] 写好。
  void _applyViewFilter() {
    final ql = query.trim().toLowerCase();
    var result = allnotes;
    if (ql.isNotEmpty) {
      result = result.where((note) {
        final titleLower = note.title.toLowerCase();
        final descriptionLower = note.description.toLowerCase();
        return titleLower.contains(ql) || descriptionLower.contains(ql);
      }).toList();
    }
    setState(() => notes = _applyMetaFilters(result));
  }

  // ---- 星标 / 标签过滤动作（抽屉、侧栏入口调用） ----

  /// 进入「仅看星标」过滤：清除标签过滤，只保留星标。
  void _enableStarredFilter() {
    setState(() {
      _showStarredOnly = true;
      _activeTag = null;
    });
    _applyViewFilter();
  }

  /// 进入指定标签过滤：清除星标过滤，只保留含该标签的笔记。
  void _enableTagFilter(String tag) {
    setState(() {
      _activeTag = tag;
      _showStarredOnly = false;
    });
    _applyViewFilter();
  }

  /// 清除当前过滤（星标与标签都不限）。
  void _clearFilters() {
    if (!_showStarredOnly && _activeTag == null) return;
    setState(() {
      _showStarredOnly = false;
      _activeTag = null;
    });
    _applyViewFilter();
  }

  /// AppBar 过滤态指示：显示当前过滤条件（「星标」或标签名）为**纯文本**（title 样式）。
  ///
  /// 不支持点击清除——清除过滤须在侧栏/抽屉点「笔记」回到全部笔记
  /// （对应 [_clearFilters] 由 onAllNotesCallback 触发）。
  Widget _filterIndicator() {
    final String label = _activeTag ?? 'Starred only'.tr();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Center(
        child: Text(
          label,
          key: const Key('ui-home-filter-indicator'),
          style: Theme.of(context).textTheme.titleMedium,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  // ---- 多选模式 ----

  /// 进入多选模式并选中指定笔记。
  void _enterSelectionMode(String uuid) {
    setState(() {
      _isSelectionMode = true;
      _selectedUuids.add(uuid);
    });
  }

  /// 切换指定笔记的选中状态；最后一个取消时自动退出多选模式。
  void _toggleSelection(String uuid) {
    setState(() {
      if (_selectedUuids.contains(uuid)) {
        _selectedUuids.remove(uuid);
        if (_selectedUuids.isEmpty) {
          _isSelectionMode = false;
        }
      } else {
        _selectedUuids.add(uuid);
      }
    });
  }

  /// 退出多选模式，清空所有选中。
  void _exitSelectionMode() {
    setState(() {
      _isSelectionMode = false;
      _selectedUuids.clear();
    });
  }

  /// 全选/取消全选当前 notes 列表。
  void _toggleSelectAll() {
    setState(() {
      final allUuids = notes.map((n) => n.uuid).toSet();
      if (_selectedUuids.containsAll(allUuids)) {
        _selectedUuids.clear();
        _isSelectionMode = false;
      } else {
        _selectedUuids = allUuids;
      }
    });
  }

  /// 多选模式操作栏：✕关闭 + 计数 + 星标/颜色/标签 + 溢出菜单(锁定/全选/删除)
  PreferredSizeWidget _buildSelectionAppBar() {
    return AppBar(
      leading: IconButton(
        key: const Key('ui-home-selection-close'),
        icon: const Icon(LucideIcons.x),
        onPressed: _exitSelectionMode,
      ),
      title: Text('${_selectedUuids.length}'),
      actions: [
        IconButton(
          key: const Key('ui-home-selection-star'),
          tooltip: 'Starred'.tr(),
          icon: const Icon(LucideIcons.pin),
          onPressed: _batchToggleStar,
        ),
        IconButton(
          key: const Key('ui-home-selection-color'),
          tooltip: 'Note Color'.tr(),
          icon: const Icon(LucideIcons.palette),
          onPressed: _showColorPicker,
        ),
        IconButton(
          key: const Key('ui-home-selection-tags'),
          tooltip: 'Edit Tags'.tr(),
          icon: const Icon(LucideIcons.tags),
          onPressed: _batchEditTags,
        ),
        PopupMenuButton<String>(
          key: const Key('ui-home-selection-overflow'),
          icon: const Icon(LucideIcons.moreVertical),
          onSelected: (value) {
            switch (value) {
              case 'lock':
                _batchToggleLock();
              case 'select_all':
                _toggleSelectAll();
              case 'delete':
                _batchDelete();
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              key: const Key('ui-home-selection-lock'),
              value: 'lock',
              child: Row(
                children: [
                  const Icon(LucideIcons.lock, size: 18),
                  const SizedBox(width: 8),
                  Text('Lock'.tr()),
                ],
              ),
            ),
            const PopupMenuDivider(),
            PopupMenuItem(
              key: const Key('ui-home-selection-selectall'),
              value: 'select_all',
              child: Row(
                children: [
                  const Icon(LucideIcons.checkCheck, size: 18),
                  const SizedBox(width: 8),
                  Text('Select All'.tr()),
                ],
              ),
            ),
            PopupMenuItem(
              key: const Key('ui-home-selection-delete'),
              value: 'delete',
              child: Row(
                children: [
                  const Icon(LucideIcons.trash2, size: 18),
                  const SizedBox(width: 8),
                  Text('Delete'.tr()),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ---- 批量操作 ----

  /// 批量切换星标：全部已星标→取消，否则→全部星标。
  Future<void> _batchToggleStar() async {
    final allPinned = _selectedUuids.every(
      (uuid) => _noteMeta[uuid]?.pinned ?? false,
    );
    final target = !allPinned;
    await Future.wait(
      _selectedUuids.map(
        (uuid) => NotesDatabase.instance.setNotePinned(uuid, target),
      ),
    );
    Log.note.i('批量星标: count=${_selectedUuids.length} pinned=$target');
    SyncService.instance.autoSync();
    _exitSelectionMode();
    refreshNotes();
  }

  /// 批量切换锁定：全部已锁定→解锁，否则→全部锁定。
  Future<void> _batchToggleLock() async {
    final allLocked = _selectedUuids.every(
      (uuid) => _noteMeta[uuid]?.locked ?? false,
    );
    final target = !allLocked;
    await Future.wait(
      _selectedUuids.map(
        (uuid) => NotesDatabase.instance.setNoteLocked(uuid, target),
      ),
    );
    Log.note.i('批量锁定: count=${_selectedUuids.length} locked=$target');
    SyncService.instance.autoSync();
    _exitSelectionMode();
    refreshNotes();
  }

  /// 批量删除：弹确认对话框后软删除选中笔记。
  Future<void> _batchDelete() async {
    final count = _selectedUuids.length;
    await showDeleteConfirmation(
      context: context,
      onConfirm: () async {
        final ids = _selectedUuids.map((uuid) {
          return allnotes.firstWhere((n) => n.uuid == uuid).id!;
        }).toList();
        await Future.wait(
          ids.map((id) => NotesDatabase.instance.softDelete(id)),
        );
        Log.note.i('批量删除(移入回收站): count=$count');
        SyncService.instance.autoSync();
        _exitSelectionMode();
        refreshNotes();
      },
    );
  }

  /// 批量设置标签：打开标签编辑器，选中的标签集合覆盖到所有选中笔记。
  Future<void> _batchEditTags() async {
    final TagEditorResult? result = await pushTagEditor(
      context,
      title: 'Edit Tags'.tr(),
      pool: PreferencesStorage.managedTags,
      selected: const [],
      selectionMode: true,
    );
    if (result == null) return;
    final tags = NoteMeta.normalizeTags(result.selected);
    await Future.wait(
      _selectedUuids.map(
        (uuid) => NotesDatabase.instance.setNoteTags(uuid, tags),
      ),
    );
    await PreferencesStorage.setManagedTags(result.pool);
    Log.note.i('批量设置标签: count=${_selectedUuids.length} tags=${tags.length}');
    SyncService.instance.autoSync();
    _exitSelectionMode();
    refreshNotes();
  }

  /// 批量设置颜色：弹出颜色选择 Sheet 后批量写入 NoteMeta.color。
  ///
  /// 如果所有选中笔记颜色一致，高亮当前色；选择「默认」会清除颜色。
  Future<void> _showColorPicker() async {
    // 从缓存读取选中笔记的当前颜色，用于高亮。
    final selectedColors = _selectedUuids
        .map((uuid) => _noteMeta[uuid]?.color)
        .toSet();
    // 所有选中笔记颜色一致时传 currentColor，否则不高亮（混色场景）。
    final int? currentColor = selectedColors.length == 1
        ? selectedColors.first
        : null;

    final result = await showNoteColorPicker(
      context,
      currentColor: currentColor,
    );
    // null = 用户关闭了 sheet，不做任何操作。
    if (result == null) return;
    final int? color = result.color; // null = 清除颜色
    await Future.wait(
      _selectedUuids.map(
        (uuid) => NotesDatabase.instance.setNoteColor(uuid, color),
      ),
    );
    Log.note.i('批量设置颜色: count=${_selectedUuids.length} color=$color');
    SyncService.instance.autoSync();
    _exitSelectionMode();
    refreshNotes();
  }

  void _searchNote(String query) {
    // 搜索防抖：200ms 内连续输入只执行最后一次过滤。
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 200), () {
      setState(() => this.query = query);
      _applyViewFilter();
      // 只记录关键词长度与命中数，绝不记录关键词内容（可能含敏感信息）
      Log.ui.d(
        '笔记搜索: 关键词长度=${query.trim().length}, '
        '命中 ${notes.length}/${allnotes.length} 条',
      );
    });
  }

  void dismissKeyboard([Object? _]) {
    final FocusScopeNode currentScope = FocusScope.of(context);
    if (!currentScope.hasPrimaryFocus && currentScope.hasFocus) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
  }
}

/// 同步中旋转图标（AppBar 用）
class _RotatingSyncIcon extends StatefulWidget {
  const _RotatingSyncIcon();

  @override
  State<_RotatingSyncIcon> createState() => _RotatingSyncIconState();
}

class _RotatingSyncIconState extends State<_RotatingSyncIcon>
    with TickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _controller,
      child: const Icon(LucideIcons.refreshCw),
    );
  }
}
