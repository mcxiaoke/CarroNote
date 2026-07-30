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

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:local_session_timeout/local_session_timeout.dart';
import 'package:provider/provider.dart';

// Project imports:
import 'package:safenotes/data/database_handler.dart';
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/dialogs/backup_import.dart';
import 'package:safenotes/models/safenote.dart';
import 'package:safenotes/models/session.dart';
import 'package:safenotes/routes/route_generator.dart';
import 'package:safenotes/sync/sync_config.dart';
import 'package:safenotes/sync/sync_service.dart';
import 'package:safenotes/utils/notes_color.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/widgets/drawer.dart';
import 'package:safenotes/widgets/note_card.dart';
import 'package:safenotes/widgets/note_card_compact.dart';
import 'package:safenotes/widgets/note_tile.dart';
import 'package:safenotes/widgets/note_tile_compact.dart';
import 'package:safenotes/widgets/search_widget.dart';

class HomePage extends StatefulWidget {
  final StreamController<SessionState> sessionStateStream;

  const HomePage({
    super.key,
    required this.sessionStateStream,
  });

  @override
  HomePageState createState() => HomePageState();
}

class HomePageState extends State<HomePage> {
  late List<SafeNote> notes;
  late List<SafeNote> allnotes;
  bool isLoading = false;
  String query = '';
  bool isHiddenImport = true;
  bool isNewFirst = PreferencesStorage.isNewFirst;
  bool isGridView = PreferencesStorage.isGridView;
  final importPassphraseController = TextEditingController();

  /// B4 修复：监听同步状态流，消费 SyncResult.passwordEpochMismatch。
  /// 引擎检测到"他端改密码"（远端 keyVersion 更高）时弹窗提示用户，
  /// 覆盖手动同步、autoSync、改密码后推送等所有同步路径。
  StreamSubscription<SyncServiceState>? _syncStateSub;

  /// 每个 HomePage 生命周期只弹一次，避免 autoSync 反复触发弹窗轰炸
  bool _passwordChangedDialogShown = false;

  //bool isListner = false;
  @override
  void initState() {
    super.initState();
    refreshNotes();
    _syncStateSub =
        SyncService.instance.stateStream.listen(_onSyncStateChanged);
  }

  @override
  void dispose() {
    _syncStateSub?.cancel();
    importPassphraseController.dispose();
    super.dispose();
  }

  /// B4 修复：他端改密码提示
  ///
  /// 触发条件：最近一次同步结果 passwordEpochMismatch=true
  /// （即远端 keyVersion 高于本端会话，本端还在用旧密码）。
  /// 数据安全性说明：
  ///   - 本地笔记由 dataKey 加密，dataKey 在改密码时不变，笔记不受影响；
  ///   - 纪元不匹配的那次同步本身已正常完成（本地未同步笔记已推送）；
  ///   - 退出登录只清内存密钥与会话，不删除本地数据库，
  ///     用新密码重新登录后所有笔记完好且继续同步。
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
              '${failed.length} 条笔记因密钥不匹配未能同步，将在下次同步重试',
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }

    // B4 修复：他端改密码提示（保持不变）
    if (_passwordChangedDialogShown) return;
    if (state.lastResult?.passwordEpochMismatch != true) return;

    _passwordChangedDialogShown = true;
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('密码已在其他设备修改'.tr()),
        content: Text(
          '检测到同步密码已在其他设备上变更。\n\n'
                  '本地笔记不会丢失，未同步的更改也已正常同步。'
                  '请退出登录并使用新密码重新登录，'
                  '否则旧密码将无法继续使用。'
              .tr(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text('稍后'.tr()),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              await _logoutToLogin();
            },
            child: Text('退出并重新登录'.tr()),
          ),
        ],
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
      // 防御层：避免任何异常（如 dataKey 不匹配、db 损坏、迁移进行中）
      // 导致 isLoading 永远为 true，UI 一直转圈。
      // 典型场景：本地 vault 与 db 不一致，readAllNotes 解密失败抛
      // DataKeyNotSetException；reEncryptAllNotes 期间抛
      // MigrationInProgressException。
      // 清空笔记列表并提示用户，至少让 UI 可交互（用户可登出或进入设置）。
      if (mounted) {
        setState(() {
          allnotes = notes = <SafeNote>[];
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载笔记失败：$e')),
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
    // show recently created notes first
    List<SafeNote> tmpNotes;
    if (isNewFirst) {
      tmpNotes = await NotesDatabase.instance.readAllNotes()
        ..sort((a, b) => b.createdTime.compareTo(a.createdTime));
    } else {
      tmpNotes = await NotesDatabase.instance.readAllNotes()
        ..sort((a, b) => a.createdTime.compareTo(b.createdTime));
    }
    setState(() {
      allnotes = notes = tmpNotes;
    });
  }

  @override
  Widget build(BuildContext context) {
    Provider.of<NotesColor>(context);

    return GestureDetector(
      onTap: dismissKeyboard,
      onVerticalDragStart: dismissKeyboard,
      onVerticalDragDown: dismissKeyboard,
      child: Scaffold(
        drawer: _buildDrawer(context),
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
                  _gridListView(),
                  _shortNotes(),
                ],
        ),
        body: Column(
          children: [
            _buildSearch(),
            _handleAndBuildNotes(),
          ],
        ),
        floatingActionButton: _addANewNoteButton(context),
      ),
    );
  }

  /// AppBar 同步状态按钮
  ///
  /// 仅在启用同步时显示，点击跳转同步设置页。
  /// 图标根据同步状态变化：
  ///   - 未初始化/空闲：cloud_outlined
  ///   - 同步中：sync（旋转动画）
  ///   - 成功：cloud_done_outlined
  ///   - 失败：cloud_off_outlined（红色）
  Widget _syncStatusButton() {
    if (!SyncConfig.isSyncEnabled) return const SizedBox.shrink();

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
        return '同步未初始化';
      case SyncStatus.idle:
        return '同步就绪';
      case SyncStatus.syncing:
        return '同步中…';
      case SyncStatus.success:
        return '同步成功';
      case SyncStatus.error:
        return '同步失败';
    }
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
              ? Text(noNotes, style: const TextStyle(fontSize: fontSize))
              : (isGridView ? _buildNotes() : _buildNotesTile())
          : const Center(child: CircularProgressIndicator()),
    );
  }

  Widget _addANewNoteButton(BuildContext context) {
    return FloatingActionButton(
      child: const Icon(Icons.add),
      onPressed: () async {
        await Navigator.pushNamed(
          context,
          '/addnote',
          arguments: widget.sessionStateStream,
        );
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

  Widget _buildDrawer(BuildContext context) {
    return HomeDrawer(
      onImportCallback: () async {
        Navigator.of(context).pop();
        widget.sessionStateStream.add(SessionState.stopListening);
        await showImportDialog(context, homeRefresh: refreshNotes);
        widget.sessionStateStream.add(SessionState.startListening);
      },
      onChangePassCallback: () async {
        // 先关抽屉再跳转：不要 await 返回后再 pop。若目标页触发了
        // pushNamedAndRemoveUntil 清栈（如退出登录），残留的 pop() 会把
        // 栈中唯一剩余的路由弹掉，触发 Navigator _history.isNotEmpty 断言崩溃。
        Navigator.of(context).pop();
        await Navigator.pushNamed(context, '/changepassphrase');
      },
      onLogoutCallback: () async {
        // F3 修复：顺序与 settings.dart / main.dart 超时退出保持一致，
        // 具体顺序说明见 _logoutToLogin 注释。
        await _logoutToLogin();
      },
      onSettingsCallback: () async {
        // 先关抽屉再跳转，理由见 onChangePassCallback 注释。
        Navigator.of(context).pop();
        await Navigator.pushNamed(
          context,
          '/settings',
          arguments: widget.sessionStateStream,
        );
        // 设置页内退出登录时，'/settings' 是被 removeUntil 移除的（而非正常
        // pop 返回），此 continuation 仍会被唤醒。此时 dataKey 已清、页面
        // 即将销毁，必须跳过 refresh，否则 readAllNotes 抛
        // DataKeyNotSetException。
        if (mounted && NotesDatabase.instance.isEncryptionEnabled) {
          refreshNotes();
        }
      },
      onBiometricsCallback: () async {
        // 先关抽屉再跳转，理由见 onChangePassCallback 注释。
        Navigator.of(context).pop();
        await Navigator.pushNamed(
          context,
          '/biometricSetting',
        );
      },
      onDeletedNotesCallback: () async {
        // 先关抽屉再跳转，理由见 onChangePassCallback 注释。
        Navigator.of(context).pop();
        await Navigator.pushNamed(context, '/deletedNotes');
        // 同 onSettingsCallback：路由若被清栈移除（如无操作超时登出），
        // 需跳过 refresh。
        if (mounted && NotesDatabase.instance.isEncryptionEnabled) {
          refreshNotes();
        }
      },
    );
  }

  Widget _buildNotesTile() {
    return ListView.separated(
      padding: const EdgeInsets.all(15),
      itemCount: notes.length,
      itemBuilder: ((context, index) {
        final note = notes[index];
        return GestureDetector(
          onTap: () async {
            await Navigator.pushNamed(
              context,
              '/viewnote',
              arguments: NoteDetailPageArguments(
                note: note,
                sessionStream: widget.sessionStateStream,
              ),
            );
            refreshNotes();
          },
          child: PreferencesStorage.isCompactPreview
              ? NoteTileWidgetCompact(note: note, index: index)
              : NoteTileWidget(note: note, index: index),
        );
      }),
      separatorBuilder: (BuildContext context, int index) {
        return Container(
          height: 7,
          color: Colors.transparent,
        );
      },
    );
  }

  Widget _buildNotes() {
    return AlignedGridView.count(
      itemCount: notes.length,
      padding: const EdgeInsets.all(12),
      crossAxisCount: 2,
      mainAxisSpacing: 4,
      crossAxisSpacing: 4,
      itemBuilder: (context, index) {
        final note = notes[index];
        return GestureDetector(
          onTap: () async {
            await Navigator.pushNamed(
              context,
              '/viewnote',
              arguments: NoteDetailPageArguments(
                note: note,
                sessionStream: widget.sessionStateStream,
              ),
            );
            refreshNotes();
          },
          child: PreferencesStorage.isCompactPreview
              ? NoteCardWidgetCompact(note: note, index: index)
              : NoteCardWidget(note: note, index: index),
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
