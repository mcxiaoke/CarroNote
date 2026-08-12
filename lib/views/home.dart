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

// Dart imports:
import 'dart:async';
import 'dart:math' show max;

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:animations/animations.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:local_session_timeout/local_session_timeout.dart';
import 'package:provider/provider.dart';

// Project imports:
import 'package:safenotes/utils/platform_ui.dart';
import 'package:core/core.dart';
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/dialogs/backup_import.dart';
import 'package:safenotes/models/session.dart';
import 'package:safenotes/routes/route_generator.dart';
import 'package:safenotes/sync/sync_config.dart';
import 'package:safenotes/sync/sync_service.dart';
import 'package:safenotes/src/logger/log_webserver.dart';
import 'package:safenotes/utils/notes_color.dart';
import 'package:safenotes/utils/route_observer.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:safenotes/widgets/shad_dialog.dart';
import 'package:safenotes/views/settings/theme_setting.dart';
import 'package:safenotes/widgets/drawer.dart';
import 'package:safenotes/widgets/home_navigation_rail.dart';
import 'package:safenotes/widgets/note_card.dart';
import 'package:safenotes/widgets/note_card_compact.dart';
import 'package:safenotes/widgets/note_tile.dart';
import 'package:safenotes/widgets/note_tile_compact.dart';
import 'package:safenotes/widgets/search_widget.dart';
import 'package:safenotes/views/add_edit_note.dart';

class HomePage extends StatefulWidget {
  final StreamController<SessionState> sessionStateStream;

  const HomePage({
    super.key,
    required this.sessionStateStream,
  });

  @override
  HomePageState createState() => HomePageState();
}

class HomePageState extends State<HomePage> with RouteAware {
  late List<SafeNote> notes;
  late List<SafeNote> allnotes;
  bool isLoading = false;
  String query = '';
  bool isNewFirst = PreferencesStorage.isNewFirst;
  bool isGridView = PreferencesStorage.isGridView;
  bool _routeSubscribed = false;

  /// B4 修复：监听同步状态流，消费 SyncResult.requiresRelogin。
  /// 引擎检测到"他端改密码"（scenario-b：本地 MK 解不开远端包裹）时
  /// 强制弹窗并退出登录（v4 选项 B 定案，替代旧 passwordEpochMismatch 标志），
  /// 覆盖手动同步、autoSync、改密码后推送等所有同步路径。
  StreamSubscription<SyncServiceState>? _syncStateSub;

  /// 每个 HomePage 生命周期只弹一次，避免 autoSync 反复触发弹窗轰炸
  bool _passwordChangedDialogShown = false;

  /// 笔记列表/网格的滚动控制器：Scrollbar 与 ScrollView 共享同一 controller，
  /// 不依赖共享的 PrimaryScrollController（多路由共存时后者会被争用导致
  /// Scrollbar 失去 ScrollPosition 抛框架异常）。
  final ScrollController _notesListScroll = ScrollController();
  final ScrollController _notesGridScroll = ScrollController();

  //bool isListner = false;
  @override
  void initState() {
    super.initState();
    Log.ui.i('进入主界面');
    refreshNotes();
    _syncStateSub =
        SyncService.instance.stateStream.listen(_onSyncStateChanged);
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
  Future<void> _startLogWebServer() async {
    if (LogWebServer.instance.isRunning) return;
    try {
      await LogWebServer.instance.start();
    } on Object catch (e, st) {
      Log.web.w('日志 Web 服务器启动失败（不影响应用使用）',
          error: e, stackTrace: st);
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '{count} notes failed to sync due to key mismatch and will be retried on the next sync'
                  .tr(namedArgs: {'count': '${failed.length}'}),
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }

    // B4 修复：他端改密码提示（v4 起用 requiresRelogin 标志接管）
    if (_passwordChangedDialogShown) return;
    if (state.lastResult?.requiresRelogin != true) return;

    _passwordChangedDialogShown = true;
    showDialog(
      context: context,
      // 强制：不可点击遮罩关闭，用户必须处理"重新登录"
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        // 强制：不可用系统返回键关闭
        canPop: false,
        child: ShadDialog(
          title: Text('Password Changed on Another Device'.tr()),
          actions: [
            shadDialogActionBar(actions: [
              ShadDialogAction(
                label: 'Logout and Login Again'.tr(),
                primary: true,
                onPressed: () async {
                  Navigator.of(dialogContext).pop();
                  await _logoutToLogin();
                },
              ),
            ]),
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load notes: {error}'
              .tr(namedArgs: {'error': '$e'}))),
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
    List<SafeNote> tmpNotes;
    if (isNewFirst) {
      tmpNotes = await NotesDatabase.instance.readAllNotes()
        ..sort((a, b) => keyOf(b).compareTo(keyOf(a)));
    } else {
      tmpNotes = await NotesDatabase.instance.readAllNotes()
        ..sort((a, b) => keyOf(a).compareTo(keyOf(b)));
    }
    setState(() {
      allnotes = notes = tmpNotes;
    });
    // 界面数据装载结果：条数 + 排序方式（用户排障最常需要的两项）
    Log.ui.i('主界面笔记列表已装载: ${tmpNotes.length} 条, '
        '${sortByModified ? "修改时间" : "创建时间"}/'
        '${isNewFirst ? "新→旧" : "旧→新"}');
  }

  @override
  Widget build(BuildContext context) {
    Provider.of<NotesColor>(context);

    // 桌面/大屏适配（P2 NavigationRail）：按整个应用窗口宽度做断点判断。
    // 用 MediaQuery.sizeOf 取「窗口」尺寸（而非某个局部 widget 的约束），
    // 因为导航形态是顶层布局决策，应与窗口整体尺寸绑定。
    // - Compact (< 600px)：保留移动端 Drawer（汉堡菜单）
    // - Medium/Expanded (≥ 600px)：左侧常驻 NavigationRail + 内容区
    final double windowWidth = MediaQuery.sizeOf(context).width;
    final bool isCompact = windowWidth < 600;

    return GestureDetector(
      onTap: dismissKeyboard,
      onVerticalDragStart: dismissKeyboard,
      onVerticalDragDown: dismissKeyboard,
      child: Scaffold(
        drawer: isCompact ? _buildDrawer(context) : null,
        appBar: AppBar(
          title: Text(
            'Safe Notes'.tr(),
            style: appBarTitle,
          ),
          actions: isLoading
              ? null
              : [
                  //_DevSessionListner(),
                  _syncStatusButton(),
                  _diagnosticsButton(),
                  _gridListView(),
                  _shortNotes(),
                ],
        ),
        // 桌面/大屏适配（P0-2）：原本 body 铺满整个窗口宽度。
        // 用 Center + ConstrainedBox 将内容宽度收束到最大 1300 并居中，
        // 避免大屏上文字行过宽、卡片被拉散；手机宽度 < 1300 时约束不生效，
        // 行为与改动前一致。crossAxisAlignment.stretch 让内容填满受限宽度。
        body: isCompact
            ? _homeBody()
              : Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  HomeSidebar(
                    onImportCallback: _navImport,
                    onChangePassCallback: _navChangePass,
                    onThemeCallback: _navTheme,
                    onBiometricsCallback: _navBiometrics,
                    onSettingsCallback: _navSettings,
                    onDeletedNotesCallback: _navDeletedNotes,
                    onLogoutCallback: _navLogout,
                  ),
                  Expanded(child: _homeBody()),
                ],
              ),
        floatingActionButton: _addANewNoteButton(context),
      ),
    );
  }

  /// 主页主体内容（搜索框 + 笔记列表/网格），Compact 与桌面 Rail 模式共用。
  Widget _homeBody() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1300),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildSearch(),
            _handleAndBuildNotes(),
          ],
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
    if (!SyncConfig.isSyncReady) return const SizedBox.shrink();

    return StreamBuilder<SyncServiceState>(
      stream: SyncService.instance.stateStream,
      initialData: SyncService.instance.state,
      builder: (context, snapshot) {
        final state = snapshot.data ?? SyncService.instance.state;
        final isSyncing = state.isSyncing;
        return IconButton(
          icon: isSyncing
              ? const _RotatingSyncIcon()
              : Icon(_syncIconData(state.status),
                  color: state.status == SyncStatus.error
                      ? Colors.red
                      : null),
          tooltip: _syncTooltip(state.status),
          onPressed: () async {
            Log.ui.i('界面切换: 主界面 → 同步设置(/syncSettings), '
                '当前同步状态=${state.status.name}');
            await Navigator.pushNamed(context, '/syncSettings');
            if (mounted) refreshNotes();
          },
        );
      },
    );
  }

  IconData _syncIconData(SyncStatus status) {
    switch (status) {
      case SyncStatus.uninitialized:
        return Icons.cloud_off_outlined;
      case SyncStatus.idle:
        return Icons.cloud_outlined;
      case SyncStatus.syncing:
        return Icons.sync;
      case SyncStatus.success:
        return Icons.cloud_done_outlined;
      case SyncStatus.error:
        return Icons.cloud_off_outlined;
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
  /// 始终显示（即使未启用同步），便于用户随时查看日志和诊断信息。
  /// 点击跳转 /diagnostics 调试面板。
  Widget _diagnosticsButton() {
    return IconButton(
      icon: const Icon(Icons.bug_report_outlined),
      tooltip: 'Debug Panel'.tr(),
      onPressed: () async {
        Log.ui.i('界面切换: 主界面 → 调试面板(/diagnostics)');
        await Navigator.pushNamed(context, '/diagnostics');
        Log.ui.d('界面返回: 调试面板 → 主界面');
      },
    );
  }

  Widget _gridListView() {
    return IconButton(
      icon: !isGridView
          ? const Icon(Icons.grid_view_outlined)
          : const Icon(Icons.splitscreen_outlined),
      onPressed: () {
        setState(() {
          PreferencesStorage.setIsGridView(!isGridView);
          isGridView = !isGridView;
        });
      },
    );
  }

  // Widget _DevSessionListner() {
  //   return IconButton(
  //     icon: isListner ? Icon(Icons.toggle_on) : Icon(Icons.toggle_off),
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
    return IconButton(
      icon: !isNewFirst
          ? Icon(Icons.arrow_upward)
          : Icon(Icons.arrow_downward),
      onPressed: () {
        setState(() {
          isNewFirst = !isNewFirst;
          _sortAndStoreNotes();
        });
      },
    );
  }

  Widget _handleAndBuildNotes() {
    final String noNotes = 'No Notes'.tr();
    const double fontSize = 24.0;

    return Expanded(
      child: !isLoading
          ? notes.isEmpty
              ? Center(
                  child: Text(noNotes, style: const TextStyle(fontSize: fontSize)))
              : (isGridView ? _buildNotes() : _buildNotesTile())
          : const Center(child: CircularProgressIndicator()),
    );
  }

  Widget _addANewNoteButton(BuildContext context) {
    return FloatingActionButton(
      child: const Icon(Icons.add),
      onPressed: () async {
        Log.ui.i('界面切换: 主界面 → 新建笔记(/addnote)');
        await Navigator.pushNamed(
          context,
          '/addnote',
          arguments: widget.sessionStateStream,
        );
        Log.ui.d('界面返回: 新建笔记 → 主界面, 触发列表刷新');
        refreshNotes();
      },
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
  Widget _buildDrawer(BuildContext context) {
    return HomeDrawer(
      onImportCallback: () {
        Navigator.of(context).pop();
        _navImport();
      },
      onChangePassCallback: () {
        Navigator.of(context).pop();
        _navChangePass();
      },
      onBiometricsCallback: () {
        Navigator.of(context).pop();
        _navBiometrics();
      },
      onSettingsCallback: () {
        Navigator.of(context).pop();
        _navSettings();
      },
      onDeletedNotesCallback: () {
        Navigator.of(context).pop();
        _navDeletedNotes();
      },
      onLogoutCallback: () {
        _navLogout();
      },
    );
  }

  // ---- 桌面 Rail 与移动 Drawer 共用的导航动作（不带 pop，pop 由 Drawer 负责） ----

  Future<void> _navImport() async {
    Log.ui.i('用户发起导入笔记流程');
    widget.sessionStateStream.add(SessionState.stopListening);
    await showImportDialog(context, homeRefresh: refreshNotes);
    widget.sessionStateStream.add(SessionState.startListening);
    Log.ui.d('导入流程结束, 已恢复会话超时监听');
  }

  Future<void> _navChangePass() async {
    Log.ui.i('界面切换: 主界面 → 修改密码(/changepassphrase)');
    await Navigator.pushNamed(context, '/changepassphrase');
  }

  void _navTheme() {
    showThemeBottomSheet(context);
  }

  Future<void> _navBiometrics() async {
    Log.ui.i('界面切换: 主界面 → 生物识别设置(/biometricSetting)');
    await Navigator.pushNamed(context, '/biometricSetting');
  }

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

  Future<void> _navLogout() async {
    Log.auth.i('用户主动登出');
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
    // 卡片背景色：与 NoteTileWidget/NoteCardWidget 内部取色保持一致
    final Color cardColor = NotesColor.getNoteColor(notIndex: index);
    return OpenContainer(
      tappable: false,
      transitionDuration: const Duration(milliseconds: 350),
      transitionType: ContainerTransitionType.fade,
      closedColor: cardColor,
      openColor: Theme.of(context).scaffoldBackgroundColor,
      closedShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
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
      closedBuilder: (context, action) => GestureDetector(
        onTap: () {
          // 只记录 uuid 与序号，不记录标题正文（隐私红线）
          Log.ui.i('界面切换: 主界面(${grid ? "网格" : "列表"}) → 编辑笔记'
              '(/editnote) uuid=${note.uuid} index=$index');
          action();
        },
        child: PreferencesStorage.isCompactPreview
            ? (grid
                ? NoteCardWidgetCompact(note: note, index: index)
                : NoteTileWidgetCompact(note: note, index: index))
            : (grid
                ? NoteCardWidget(note: note, index: index)
                : NoteTileWidget(note: note, index: index)),
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
        return _openNoteEditorContainer(note: note, index: index, grid: false);
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
              return _openNoteEditorContainer(note: note, index: index, grid: true);
            },
          ),
        );
      },
    );
  }

  void _searchNote(String query) {
    final notes = allnotes.where((note) {
      final titleLower = note.title.toLowerCase();
      final descriptionLower = note.description.toLowerCase();
      final queryLower = query.toLowerCase().trim();

      return titleLower.contains(queryLower) ||
          descriptionLower.contains(queryLower);
    }).toList();

    setState(
      () {
        this.query = query;
        this.notes = notes;
      },
    );
    // 只记录关键词长度与命中数，绝不记录关键词内容（可能含敏感信息）
    Log.ui.d('笔记搜索: 关键词长度=${query.trim().length}, '
        '命中 ${notes.length}/${allnotes.length} 条');
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
      child: const Icon(Icons.sync),
    );
  }
}
