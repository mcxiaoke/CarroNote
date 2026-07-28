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
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
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
    Key? key,
    required this.sessionStateStream,
  }) : super(key: key);

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
  //bool isListner = false;
  @override
  void initState() {
    super.initState();
    refreshNotes();
  }

  Future<void> refreshNotes() async {
    setState(() => isLoading = true);
    await _sortAndStoreNotes();
    setState(() => isLoading = false);
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
          ? Icon(MdiIcons.sortCalendarAscending)
          : Icon(MdiIcons.sortCalendarDescending),
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
        await Session.logout();
        widget.sessionStateStream.add(SessionState.stopListening);

        if (context.mounted) {
          await Navigator.pushNamedAndRemoveUntil(
            context,
            '/login',
            (Route<dynamic> route) => false,
            arguments: SessionArguments(
              sessionStream: widget.sessionStateStream,
              isKeyboardFocused: false,
            ),
          );
        }
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

  void dismissKeyboard([var _]) {
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
