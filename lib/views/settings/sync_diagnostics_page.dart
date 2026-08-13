/*
 * 同步调试面板（E1）
 *
 * 五个 Tab 面板：
 *   1. 状态：同步子系统诊断快照（含后端/Keyring/设备信息，可复制）
 *   2. 同步结果：最近一次同步的详细统计和失败笔记
 *   3. 操作记录：SyncAction 列表（含结构化错误详情）
 *   4. 日志：实时日志查看器（logcat 风格，可过滤/复制/导出/清空）
 *   5. Web 服务器：启动/停止 HTTP 日志服务器（移动端远程查看用）
 *   6. 测试：PBKDF2 vs Argon2id 性能对比基准
 *
 * 所有面板的信息均可复制，日志支持导出为文本文件。
 */

// Dart 导入

// Dart imports:
import 'dart:async';
import 'dart:io';

// Flutter imports:
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Package imports:
import 'package:core/core.dart';
import 'package:easy_localization/easy_localization.dart';

// Project imports:
import 'package:safenotes/src/logger/log_webserver.dart';
import 'package:safenotes/sync/sync_service.dart';
import 'package:safenotes/utils/styles.dart';

// Flutter 导入

// Package 导入

// Project 导入

class SyncDiagnosticsPage extends StatefulWidget {
  const SyncDiagnosticsPage({super.key});

  @override
  State<SyncDiagnosticsPage> createState() => _SyncDiagnosticsPageState();
}

class _SyncDiagnosticsPageState extends State<SyncDiagnosticsPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    // 注意：Web 服务器为全局单例，离开页面不停止
    // 只有用户手动停止或应用退出（SyncService.dispose）才关闭
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Debug Panel'.tr(), style: appBarTitle),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabs: [
            Tab(text: 'Status'.tr()),
            Tab(text: 'Sync Results'.tr()),
            Tab(text: 'Actions'.tr()),
            Tab(text: 'Logs'.tr()),
            Tab(text: 'Web Server'.tr()),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh'.tr(),
            onPressed: () => setState(() {}),
          ),
        ],
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _StatusTab(),
          _SyncResultTab(),
          _ActionsTab(),
          _LogsTab(),
          _WebServerTab(onUpdate: () => setState(() {})),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────
// Tab 1: 状态
// ──────────────────────────────────────────────

class _StatusTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final snapshot = SyncService.instance.getDiagnosticsSnapshot();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Diagnostics Snapshot'.tr(),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.copy, size: 20),
                  tooltip: 'Copy All'.tr(),
                  onPressed: () => _copyToClipboard(
                    context,
                    snapshot.toReadableText(),
                    'Snapshot copied'.tr(),
                  ),
                ),
              ],
            ),
          ],
        ),
        const Divider(),
        _buildSection(context, 'Sync Status'.tr(), [
          _KV('Status'.tr(), snapshot.status),
          _KV('Syncing'.tr(), snapshot.isSyncing.toString()),
          _KV('Backend Ready'.tr(), snapshot.backendReady.toString()),
          _KV('Last Sync'.tr(), snapshot.lastSyncTime?.toString() ?? 'N/A'),
          if (snapshot.errorMessage != null)
            _KV(
              'Error Message'.tr(),
              snapshot.errorMessage!,
              color: Colors.red,
            ),
        ]),
        _buildSection(context, 'Backend Config'.tr(), [
          _KV(
            'Sync Master Switch'.tr(),
            snapshot.syncEnabled ? 'On'.tr() : 'Off'.tr(),
            color: snapshot.syncEnabled ? null : Colors.orange,
          ),
          _KV('Type'.tr(), snapshot.backendDisplayName),
          _KV('Runtime Type'.tr(), snapshot.backendRuntimeType ?? 'N/A'),
          _KV('providerKey', snapshot.providerKey ?? 'N/A'),
          if (snapshot.localFsPath.isNotEmpty)
            _KV('LocalFs Path', snapshot.localFsPath),
          if (snapshot.webdavUrl.isNotEmpty) ...[
            _KV('WebDAV URL', snapshot.webdavUrl),
            _KV('WebDAV User', snapshot.webdavUsername),
          ],
          if (snapshot.safeServerUrl.isNotEmpty)
            _KV('SafeServer URL', snapshot.safeServerUrl),
          _KV('Auto Sync'.tr(), snapshot.autoSyncEnabled.toString()),
        ]),
        _buildSection(context, 'Keyring Metadata'.tr(), [
          _KV('Keyring ID', snapshot.vaultId ?? 'N/A'),
          _KV('keyVersion', snapshot.keyVersion?.toString() ?? 'N/A'),
          _KV('dataKeyEpoch', snapshot.dataKeyEpoch?.toString() ?? 'N/A'),
          _KV(
            'keyFingerprint',
            snapshot.keyFingerprint?.substring(0, 16) ?? 'N/A',
          ),
          _KV(
            'KDF',
            '${snapshot.kdfAlgorithm ?? "N/A"} (${snapshot.kdfIterations ?? "N/A"} iterations)',
          ),
        ]),
        _buildSection(context, 'Device'.tr(), [
          _KV('Device ID'.tr(), snapshot.deviceId ?? 'N/A'),
        ]),
        _buildSection(context, 'Logs'.tr(), [
          _KV('Log Directory'.tr(), snapshot.logDirPath ?? 'N/A'),
          _KV('Memory Buffer Entries'.tr(), snapshot.logBufferCount.toString()),
        ]),
        const SizedBox(height: 16),
        ElevatedButton.icon(
          icon: const Icon(Icons.download),
          label: Text('Export Diagnostics + Logs'.tr()),
          onPressed: () => _exportLogs(context),
        ),
      ],
    );
  }

  Widget _buildSection(BuildContext context, String title, List<_KV> items) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Text(
          title,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(height: 8),
        ...items.map((kv) => _buildKVRow(context, kv)),
      ],
    );
  }

  Widget _buildKVRow(BuildContext context, _KV kv) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              kv.key,
              style: TextStyle(color: Colors.grey[600], fontSize: 13),
            ),
          ),
          Expanded(
            child: SelectableText(
              kv.value,
              style: TextStyle(fontSize: 13, color: kv.color),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _exportLogs(BuildContext context) async {
    final text = await SyncService.instance.exportAllLogsAsText();
    if (context.mounted) {
      _copyToClipboard(context, text, 'Diagnostics + logs copied'.tr());
    }
  }
}

class _KV {
  final String key;
  final String value;
  final Color? color;
  const _KV(this.key, this.value, {this.color});
}

// ──────────────────────────────────────────────
// Tab 2: 同步结果
// ──────────────────────────────────────────────

class _SyncResultTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final snapshot = SyncService.instance.getDiagnosticsSnapshot();
    final hasResult = snapshot.lastResultSuccess != null;

    if (!hasResult) {
      return Center(child: Text('No sync results yet'.tr()));
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Latest Sync Result'.tr(),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const Divider(),
        _buildKVRow(
          context,
          'Success'.tr(),
          snapshot.lastResultSuccess!.toString(),
          color: snapshot.lastResultSuccess! ? Colors.green : Colors.red,
        ),
        _buildKVRow(
          context,
          'Retry Count'.tr(),
          snapshot.lastResultAttempts?.toString() ?? 'N/A',
        ),
        const SizedBox(height: 12),
        Text('Statistics'.tr(), style: Theme.of(context).textTheme.titleSmall),
        _buildStatGrid(context, snapshot),
        const SizedBox(height: 12),
        _buildKVRow(
          context,
          'Requires Relogin'.tr(),
          snapshot.lastResultRequiresRelogin?.toString() ?? 'N/A',
          color: (snapshot.lastResultRequiresRelogin ?? false)
              ? Colors.red
              : null,
        ),
        if (snapshot.lastResultErrorMessage != null) ...[
          const SizedBox(height: 12),
          Text(
            'Error Message'.tr(),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.red.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: SelectableText(
              snapshot.lastResultErrorMessage!,
              style: const TextStyle(fontSize: 13, color: Colors.red),
            ),
          ),
        ],
        if (snapshot.lastResultFailedNoteUuids != null &&
            snapshot.lastResultFailedNoteUuids!.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            'Failed Notes ({count})'.tr(
              namedArgs: {
                'count': '${snapshot.lastResultFailedNoteUuids!.length}',
              },
            ),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          ...snapshot.lastResultFailedNoteUuids!.map(
            (uuid) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: SelectableText(
                uuid,
                style: TextStyle(fontSize: 12, color: Colors.orange[700]),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildStatGrid(
    BuildContext context,
    SyncDiagnosticsSnapshot snapshot,
  ) {
    final stats = [
      (
        'Upload'.tr(),
        snapshot.lastResultUploaded ?? 0,
        Icons.upload,
        Colors.blue,
      ),
      (
        'Download'.tr(),
        snapshot.lastResultDownloaded ?? 0,
        Icons.download,
        Colors.green,
      ),
      (
        'Delete'.tr(),
        snapshot.lastResultDeleted ?? 0,
        Icons.delete,
        Colors.red,
      ),
      (
        'Conflicts'.tr(),
        snapshot.lastResultConflicts ?? 0,
        Icons.warning,
        Colors.orange,
      ),
      (
        'Migrated'.tr(),
        snapshot.lastResultMigrated ?? 0,
        Icons.swap_horiz,
        Colors.purple,
      ),
      (
        'Skipped'.tr(),
        snapshot.lastResultSkipped ?? 0,
        Icons.skip_next,
        Colors.grey,
      ),
    ];
    // 用 LayoutBuilder + Wrap 取代固定 childAspectRatio 的 GridView：
    // 窄屏下固定宽高比会让单元格高度不足以容纳内容，导致 RenderFlex 底部溢出。
    // 这里按可用宽度计算每列宽度，单元格高度由内容自适应，杜绝溢出。
    return LayoutBuilder(
      builder: (context, constraints) {
        const crossAxisCount = 3;
        const spacing = 8.0;
        final chipWidth =
            (constraints.maxWidth - spacing * (crossAxisCount - 1)) /
            crossAxisCount;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: stats.map((s) {
            final (label, count, icon, color) = s;
            return SizedBox(
              width: chipWidth,
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: color.withValues(alpha: 0.3)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(icon, size: 16, color: color),
                        const SizedBox(width: 4),
                        Text(
                          label,
                          style: TextStyle(fontSize: 12, color: color),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$count',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: color,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }

  Widget _buildKVRow(
    BuildContext context,
    String key,
    String value, {
    Color? color,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              key,
              style: TextStyle(color: Colors.grey[600], fontSize: 13),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(fontSize: 13, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────
// Tab 3: 操作记录
// ──────────────────────────────────────────────

class _ActionsTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final snapshot = SyncService.instance.getDiagnosticsSnapshot();
    // 过滤掉 skip 类型：skip 量大且无实际信息价值，
    // 只显示有意义的操作（上传/下载/删除/冲突/修复/失败/迁移）
    final allActions = snapshot.lastResultActions ?? [];
    final actions = allActions.where((a) => a.type != 'skip').toList();

    if (actions.isEmpty) {
      return Center(child: Text('No actions yet'.tr()));
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: actions.length,
      itemBuilder: (context, index) {
        final action = actions[index];
        return _buildActionCard(context, action);
      },
    );
  }

  Widget _buildActionCard(BuildContext context, SyncActionInfo action) {
    final isError = action.type == 'uploadFailed' || action.type == 'corrupt';
    final isHeal = action.type == 'heal';
    final isConflict = action.type == 'conflict';

    Color? color;
    IconData icon;
    if (isError) {
      color = Colors.red;
      icon = Icons.error_outline;
    } else if (isHeal) {
      color = Colors.green;
      icon = Icons.healing;
    } else if (isConflict) {
      color = Colors.orange;
      icon = Icons.warning;
    } else if (action.type == 'upload') {
      color = Colors.blue;
      icon = Icons.upload;
    } else if (action.type == 'download') {
      color = Colors.teal;
      icon = Icons.download;
    } else if (action.type == 'delete') {
      color = Colors.red[300];
      icon = Icons.delete;
    } else if (action.type == 'migrate') {
      color = Colors.purple;
      icon = Icons.swap_horiz;
    } else {
      color = Colors.grey;
      icon = Icons.info;
    }

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ExpansionTile(
        leading: Icon(icon, color: color),
        title: Text(
          action.type,
          style: TextStyle(fontWeight: FontWeight.bold, color: color),
        ),
        subtitle: Text(
          action.uuid.isNotEmpty
              ? 'uuid: ${action.uuid}'
              : action.message ?? '',
          style: const TextStyle(fontSize: 12),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (action.uuid.isNotEmpty) _buildDetail('UUID', action.uuid),
                if (action.hash != null) _buildDetail('Hash', action.hash!),
                if (action.message != null)
                  _buildDetail('Message'.tr(), action.message!),
                if (action.errorLabel != null)
                  _buildDetail(
                    'Error Type'.tr(),
                    action.errorLabel!,
                    color: Colors.red,
                  ),
                if (action.errorDisplay != null)
                  _buildDetail(
                    'Error Details'.tr(),
                    action.errorDisplay!,
                    color: Colors.red,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetail(String key, String value, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              key,
              style: TextStyle(color: Colors.grey[600], fontSize: 12),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(fontSize: 12, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────
// Tab 4: 日志（实时 logcat 风格）
// ──────────────────────────────────────────────

class _LogsTab extends StatefulWidget {
  @override
  State<_LogsTab> createState() => _LogsTabState();
}

class _LogsTabState extends State<_LogsTab> {
  final List<AppLogEntry> _entries = [];
  StreamSubscription<AppLogEntry>? _sub;
  final ScrollController _scrollController = ScrollController();
  bool _autoScroll = true;

  // 级别过滤
  final Map<AppLogLevel, bool> _levelFilter = {
    AppLogLevel.trace: false,
    AppLogLevel.debug: false,
    AppLogLevel.info: true,
    AppLogLevel.warning: true,
    AppLogLevel.error: true,
    AppLogLevel.fatal: true,
  };

  @override
  void initState() {
    super.initState();
    // 加载历史日志
    _entries.addAll(SyncService.instance.getLogEntries());
    // 订阅实时日志
    _sub = SyncService.instance.logStream.listen((entry) {
      if (mounted) {
        setState(() {
          _entries.add(entry);
          // 限制内存中的条目数
          if (_entries.length > 2000) {
            _entries.removeRange(0, _entries.length - 2000);
          }
        });
        if (_autoScroll) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scrollController.hasClients) {
              _scrollController.jumpTo(
                _scrollController.position.maxScrollExtent,
              );
            }
          });
        }
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  List<AppLogEntry> get _filteredEntries {
    return _entries.where((e) => _levelFilter[e.level] ?? true).toList();
  }

  @override
  Widget build(BuildContext context) {
    final entries = _filteredEntries;
    return Column(
      children: [
        // 工具栏
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            border: Border(
              bottom: BorderSide(color: Colors.grey.withValues(alpha: 0.3)),
            ),
          ),
          child: Row(
            children: [
              // 级别过滤按钮
              PopupMenuButton<AppLogLevel>(
                icon: const Icon(Icons.filter_list, size: 20),
                tooltip: 'Level Filter'.tr(),
                onSelected: (level) {
                  setState(() {
                    _levelFilter[level] = !(_levelFilter[level] ?? true);
                  });
                },
                itemBuilder: (context) => AppLogLevel.values.map((level) {
                  final enabled = _levelFilter[level] ?? true;
                  return PopupMenuItem(
                    value: level,
                    child: Row(
                      children: [
                        Icon(
                          enabled
                              ? Icons.check_box
                              : Icons.check_box_outline_blank,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Text(_levelName(level)),
                      ],
                    ),
                  );
                }).toList(),
              ),
              // 自动滚动
              IconButton(
                icon: Icon(
                  _autoScroll
                      ? Icons.vertical_align_bottom
                      : Icons.vertical_align_top,
                  size: 20,
                ),
                tooltip: _autoScroll
                    ? 'Auto-scroll: On'.tr()
                    : 'Auto-scroll: Off'.tr(),
                onPressed: () => setState(() => _autoScroll = !_autoScroll),
              ),
              const Spacer(),
              // 复制
              IconButton(
                icon: const Icon(Icons.copy, size: 20),
                tooltip: 'Copy All Logs'.tr(),
                onPressed: () {
                  final text = entries.map((e) => e.formattedLine).join('\n');
                  _copyToClipboard(
                    context,
                    text,
                    'Copied {count} log entries'.tr(
                      namedArgs: {'count': '${entries.length}'},
                    ),
                  );
                },
              ),
              // 导出（复制诊断+日志）
              IconButton(
                icon: const Icon(Icons.download, size: 20),
                tooltip: 'Export Diagnostics + Logs'.tr(),
                onPressed: () async {
                  final text = await SyncService.instance.exportAllLogsAsText();
                  if (context.mounted) {
                    _copyToClipboard(
                      context,
                      text,
                      'Diagnostics + logs copied'.tr(),
                    );
                  }
                },
              ),
              // 清空（仅清空内存缓冲，不影响文件）
              IconButton(
                icon: const Icon(Icons.delete_sweep, size: 20),
                tooltip: 'Clear In-memory Logs'.tr(),
                onPressed: () {
                  SyncService.instance.clearLogBuffer();
                  setState(() {
                    _entries.clear();
                  });
                },
              ),
            ],
          ),
        ),
        // 日志计数
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Text(
            '{count} log entries (total {total})'.tr(
              namedArgs: {
                'count': '${entries.length}',
                'total': '${_entries.length}',
              },
            ),
            style: TextStyle(fontSize: 11, color: Colors.grey[600]),
          ),
        ),
        // 日志列表
        Expanded(
          child: entries.isEmpty
              ? Center(child: Text('No logs yet'.tr()))
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    return _buildLogLine(entry);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildLogLine(AppLogEntry entry) {
    final color = _levelColor(entry.level);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 1, horizontal: 4),
      child: SelectableText(
        entry.formattedLine,
        style: TextStyle(
          fontSize: 11,
          fontFamily: 'Consolas',
          color: color,
          height: 1.4,
        ),
      ),
    );
  }

  Color _levelColor(AppLogLevel level) {
    switch (level) {
      case AppLogLevel.trace:
        return Colors.grey[600]!;
      case AppLogLevel.debug:
        return Colors.grey[500]!;
      case AppLogLevel.info:
        return Colors.blue[300]!;
      case AppLogLevel.warning:
        return Colors.orange[400]!;
      case AppLogLevel.error:
        return Colors.red[400]!;
      case AppLogLevel.fatal:
        return Colors.red[700]!;
    }
  }

  String _levelName(AppLogLevel level) {
    switch (level) {
      case AppLogLevel.trace:
        return 'TRACE';
      case AppLogLevel.debug:
        return 'DEBUG';
      case AppLogLevel.info:
        return 'INFO';
      case AppLogLevel.warning:
        return 'WARN';
      case AppLogLevel.error:
        return 'ERROR';
      case AppLogLevel.fatal:
        return 'FATAL';
    }
  }
}

// ──────────────────────────────────────────────
// Tab 5: Web 服务器
// ──────────────────────────────────────────────

class _WebServerTab extends StatefulWidget {
  final VoidCallback onUpdate;

  const _WebServerTab({required this.onUpdate});

  @override
  State<_WebServerTab> createState() => _WebServerTabState();
}

class _WebServerTabState extends State<_WebServerTab> {
  String _statusText = 'Not started'.tr();
  bool _isStarting = false;

  @override
  void initState() {
    super.initState();
    // 页面打开时如果服务器已在运行，刷新状态显示
    if (LogWebServer.instance.isRunning) {
      _refreshStatus();
    }
  }

  /// 刷新状态文本（显示 IP 和端口）
  Future<void> _refreshStatus() async {
    if (!LogWebServer.instance.isRunning) {
      setState(() => _statusText = 'Not started'.tr());
      return;
    }
    final ip = await _getLocalIp();
    final port = LogWebServer.instance.port;
    setState(() {
      _statusText =
          'Running\nLAN access: http://{ip}:{port}\nLocal access: http://localhost:{port}'
              .tr(namedArgs: {'ip': ip, 'port': '$port'});
    });
  }

  Future<void> _toggleServer() async {
    if (LogWebServer.instance.isRunning) {
      await LogWebServer.instance.stop();
      setState(() => _statusText = 'Stopped'.tr());
    } else {
      setState(() => _isStarting = true);
      try {
        final port = await LogWebServer.instance.start();
        // 获取本机 IP
        final ip = await _getLocalIp();
        setState(() {
          _statusText =
              'Running\nLAN access: http://{ip}:{port}\nLocal access: http://localhost:{port}'
                  .tr(namedArgs: {'ip': ip, 'port': '$port'});
        });
      } on Object catch (e) {
        setState(
          () => _statusText = 'Startup failed: {error}'.tr(
            namedArgs: {'error': '$e'},
          ),
        );
      } finally {
        setState(() => _isStarting = false);
      }
    }
    widget.onUpdate();
  }

  /// 获取本机局域网 IP
  Future<String> _getLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) {
            return addr.address;
          }
        }
      }
    } on Object {
      // 忽略
    }
    return '127.0.0.1';
  }

  @override
  Widget build(BuildContext context) {
    final isRunning = LogWebServer.instance.isRunning;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Log Web Server'.tr(),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'Start to view local logs in a PC browser in real time, no export needed.\nSuitable for mobile (where SD card export is limited).\n\nThe server is a global singleton; leaving this page does not stop it, only manual stop or app exit does.\n\nEndpoints:\n  /            → Real-time log viewer (WebSocket)\n  /logs        → Full log text (downloadable via curl)\n  /diagnostics → Diagnostics snapshot text'
              .tr(),
          style: TextStyle(fontSize: 13, color: Colors.grey[600]),
        ),
        const SizedBox(height: 24),
        // 状态指示
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: (isRunning ? Colors.green : Colors.grey).withValues(
              alpha: 0.1,
            ),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: (isRunning ? Colors.green : Colors.grey).withValues(
                alpha: 0.3,
              ),
            ),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    isRunning ? Icons.wifi : Icons.wifi_off,
                    color: isRunning ? Colors.green : Colors.grey,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    isRunning
                        ? 'Running (port {port})'.tr(
                            namedArgs: {
                              'port': '${LogWebServer.instance.port}',
                            },
                          )
                        : 'Stopped'.tr(),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: isRunning ? Colors.green : Colors.grey,
                    ),
                  ),
                ],
              ),
              if (isRunning) ...[
                const SizedBox(height: 12),
                SelectableText(
                  _statusText,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        // 启动/停止按钮
        FilledButton.icon(
          onPressed: _isStarting ? null : _toggleServer,
          icon: _isStarting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(isRunning ? Icons.stop : Icons.play_arrow),
          label: Text(isRunning ? 'Stop'.tr() : 'Start'.tr()),
        ),
        const SizedBox(height: 16),
        // 安全提示
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.orange.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
          ),
          child: Row(
            children: [
              const Icon(Icons.warning, color: Colors.orange, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Security note: the server binds 0.0.0.0, so any device on the same LAN can access it. Logs do not contain sensitive information such as passwords/tokens. Currently in debug stage, the server starts automatically with the sync service; release builds will default to off.'
                      .tr(),
                  style: TextStyle(fontSize: 12, color: Colors.orange[800]),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ──────────────────────────────────────────────
// 辅助：复制到剪贴板
// ──────────────────────────────────────────────

void _copyToClipboard(BuildContext context, String text, String message) {
  Clipboard.setData(ClipboardData(text: text));
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
  );
}
