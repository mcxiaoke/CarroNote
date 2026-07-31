/*
 * 同步调试面板（E1）
 *
 * 五个 Tab 面板：
 *   1. 状态：同步子系统诊断快照（含后端/Vault/设备信息，可复制）
 *   2. 同步结果：最近一次同步的详细统计和失败笔记
 *   3. 操作记录：SyncAction 列表（含结构化错误详情）
 *   4. 日志：实时日志查看器（logcat 风格，可过滤/复制/导出/清空）
 *   5. Web 服务器：启动/停止 HTTP 日志服务器（移动端远程查看用）
 *
 * 所有面板的信息均可复制，日志支持导出为文本文件。
 */

// Dart 导入
import 'dart:async';
import 'dart:io';

// Flutter 导入
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Package 导入
import 'package:easy_localization/easy_localization.dart';

// Project 导入
import 'package:safenotes/utils/log_webserver.dart';
import 'package:safenotes/utils/app_logger.dart';
import 'package:safenotes/sync/sync_models.dart';
import 'package:safenotes/sync/sync_service.dart';
import 'package:safenotes/utils/styles.dart';

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
        title: Text('调试面板'.tr(), style: appBarTitle),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabs: const [
            Tab(text: '状态'),
            Tab(text: '同步结果'),
            Tab(text: '操作记录'),
            Tab(text: '日志'),
            Tab(text: 'Web 服务器'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
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
            Text('诊断快照', style: Theme.of(context).textTheme.titleMedium),
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.copy, size: 20),
                  tooltip: '复制全部',
                  onPressed: () => _copyToClipboard(
                    context,
                    snapshot.toReadableText(),
                    '诊断快照已复制',
                  ),
                ),
              ],
            ),
          ],
        ),
        const Divider(),
        _buildSection(context, '同步状态', [
          _KV('状态', snapshot.status),
          _KV('正在同步', snapshot.isSyncing.toString()),
          _KV('后端就绪', snapshot.backendReady.toString()),
          _KV('上次同步', snapshot.lastSyncTime?.toString() ?? 'N/A'),
          if (snapshot.errorMessage != null)
            _KV('错误信息', snapshot.errorMessage!, color: Colors.red),
        ]),
        _buildSection(context, '后端配置', [
          _KV('类型', snapshot.backendDisplayName),
          _KV('运行时类型', snapshot.backendRuntimeType ?? 'N/A'),
          _KV('providerKey', snapshot.providerKey ?? 'N/A'),
          if (snapshot.localFsPath.isNotEmpty)
            _KV('LocalFs 路径', snapshot.localFsPath),
          if (snapshot.webdavUrl.isNotEmpty) ...[
            _KV('WebDAV URL', snapshot.webdavUrl),
            _KV('WebDAV 用户', snapshot.webdavUsername),
          ],
          if (snapshot.safeServerUrl.isNotEmpty)
            _KV('SafeServer URL', snapshot.safeServerUrl),
          _KV('自动同步', snapshot.autoSyncEnabled.toString()),
        ]),
        _buildSection(context, 'Vault 元数据', [
          _KV('Vault ID', snapshot.vaultId ?? 'N/A'),
          _KV('keyVersion', snapshot.keyVersion?.toString() ?? 'N/A'),
          _KV('dataKeyEpoch', snapshot.dataKeyEpoch?.toString() ?? 'N/A'),
          _KV('keyFingerprint',
              snapshot.keyFingerprint?.substring(0, 16) ?? 'N/A'),
          _KV('KDF',
              '${snapshot.kdfAlgorithm ?? "N/A"} (${snapshot.kdfIterations ?? "N/A"} iterations)'),
        ]),
        _buildSection(context, '设备', [
          _KV('设备 ID', snapshot.deviceId ?? 'N/A'),
        ]),
        _buildSection(context, '日志', [
          _KV('日志目录', snapshot.logDirPath ?? 'N/A'),
          _KV('内存缓冲条目数', snapshot.logBufferCount.toString()),
        ]),
        const SizedBox(height: 16),
        ElevatedButton.icon(
          icon: const Icon(Icons.download),
          label: const Text('导出诊断+日志'),
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
        Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            )),
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
            child: Text(kv.key,
                style: TextStyle(color: Colors.grey[600], fontSize: 13)),
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
      _copyToClipboard(context, text, '诊断+日志已复制到剪贴板');
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
      return const Center(child: Text('尚无同步结果'));
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('最近同步结果', style: Theme.of(context).textTheme.titleMedium),
        const Divider(),
        _buildKVRow(context, '成功',
            snapshot.lastResultSuccess!.toString(),
            color: snapshot.lastResultSuccess! ? Colors.green : Colors.red),
        _buildKVRow(context, '重试次数', snapshot.lastResultAttempts?.toString() ?? 'N/A'),
        const SizedBox(height: 12),
        Text('统计', style: Theme.of(context).textTheme.titleSmall),
        _buildStatGrid(context, snapshot),
        const SizedBox(height: 12),
        _buildKVRow(context, '密钥纪元不匹配',
            snapshot.lastResultPasswordEpochMismatch?.toString() ?? 'N/A'),
        if (snapshot.lastResultErrorMessage != null) ...[
          const SizedBox(height: 12),
          Text('错误信息', style: Theme.of(context).textTheme.titleSmall),
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
          Text('失败笔记 (${snapshot.lastResultFailedNoteUuids!.length})',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          ...snapshot.lastResultFailedNoteUuids!.map(
            (uuid) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: SelectableText(uuid,
                  style: TextStyle(fontSize: 12, color: Colors.orange[700])),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildStatGrid(
      BuildContext context, SyncDiagnosticsSnapshot snapshot) {
    final stats = [
      ('上传', snapshot.lastResultUploaded ?? 0, Icons.upload, Colors.blue),
      ('下载', snapshot.lastResultDownloaded ?? 0, Icons.download, Colors.green),
      ('删除', snapshot.lastResultDeleted ?? 0, Icons.delete, Colors.red),
      ('冲突', snapshot.lastResultConflicts ?? 0, Icons.warning, Colors.orange),
      ('迁移', snapshot.lastResultMigrated ?? 0, Icons.swap_horiz, Colors.purple),
      ('跳过', snapshot.lastResultSkipped ?? 0, Icons.skip_next, Colors.grey),
    ];
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 2.5,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: stats.length,
      itemBuilder: (context, index) {
        final (label, count, icon, color) = stats[index];
        return Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withValues(alpha: 0.3)),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 16, color: color),
                  const SizedBox(width: 4),
                  Text(label, style: TextStyle(fontSize: 12, color: color)),
                ],
              ),
              Text('$count',
                  style: TextStyle(
                      fontSize: 20, fontWeight: FontWeight.bold, color: color)),
            ],
          ),
        );
      },
    );
  }

  Widget _buildKVRow(BuildContext context, String key, String value,
      {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(key,
                style: TextStyle(color: Colors.grey[600], fontSize: 13)),
          ),
          Expanded(
            child: SelectableText(value,
                style: TextStyle(fontSize: 13, color: color)),
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
      return const Center(child: Text('尚无操作记录'));
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
        title: Text(action.type,
            style: TextStyle(fontWeight: FontWeight.bold, color: color)),
        subtitle: Text(
          action.uuid.isNotEmpty ? 'uuid: ${action.uuid}' : action.message ?? '',
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
                if (action.uuid.isNotEmpty)
                  _buildDetail('UUID', action.uuid),
                if (action.hash != null)
                  _buildDetail('Hash', action.hash!),
                if (action.message != null)
                  _buildDetail('消息', action.message!),
                if (action.errorLabel != null)
                  _buildDetail('错误类型', action.errorLabel!, color: Colors.red),
                if (action.errorDisplay != null)
                  _buildDetail('错误详情', action.errorDisplay!, color: Colors.red),
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
            child: Text(key,
                style: TextStyle(color: Colors.grey[600], fontSize: 12)),
          ),
          Expanded(
            child: SelectableText(value,
                style: TextStyle(fontSize: 12, color: color)),
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
                  _scrollController.position.maxScrollExtent);
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
                bottom: BorderSide(color: Colors.grey.withValues(alpha: 0.3))),
          ),
          child: Row(
            children: [
              // 级别过滤按钮
              PopupMenuButton<AppLogLevel>(
                icon: const Icon(Icons.filter_list, size: 20),
                tooltip: '级别过滤',
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
                        Icon(enabled ? Icons.check_box : Icons.check_box_outline_blank,
                            size: 18),
                        const SizedBox(width: 8),
                        Text(_levelName(level)),
                      ],
                    ),
                  );
                }).toList(),
              ),
              // 自动滚动
              IconButton(
                icon: Icon(_autoScroll ? Icons.vertical_align_bottom : Icons.vertical_align_top,
                    size: 20),
                tooltip: _autoScroll ? '自动滚动：开' : '自动滚动：关',
                onPressed: () => setState(() => _autoScroll = !_autoScroll),
              ),
              const Spacer(),
              // 复制
              IconButton(
                icon: const Icon(Icons.copy, size: 20),
                tooltip: '复制全部日志',
                onPressed: () {
                  final text = entries.map((e) => e.formattedLine).join('\n');
                  _copyToClipboard(context, text, '已复制 ${entries.length} 条日志');
                },
              ),
              // 导出（复制诊断+日志）
              IconButton(
                icon: const Icon(Icons.download, size: 20),
                tooltip: '导出诊断+日志',
                onPressed: () async {
                  final text = await SyncService.instance.exportAllLogsAsText();
                  if (context.mounted) {
                    _copyToClipboard(context, text, '诊断+日志已复制');
                  }
                },
              ),
              // 清空（仅清空内存缓冲，不影响文件）
              IconButton(
                icon: const Icon(Icons.delete_sweep, size: 20),
                tooltip: '清空内存日志',
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
            '${entries.length} 条日志（共 ${_entries.length} 条）',
            style: TextStyle(fontSize: 11, color: Colors.grey[600]),
          ),
        ),
        // 日志列表
        Expanded(
          child: entries.isEmpty
              ? const Center(child: Text('暂无日志'))
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
  String _statusText = '未启动';
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
      setState(() => _statusText = '未启动');
      return;
    }
    final ip = await _getLocalIp();
    final port = LogWebServer.instance.port;
    setState(() {
      _statusText = '运行中\n'
          '局域网访问: http://$ip:$port\n'
          '本机访问: http://localhost:$port';
    });
  }

  Future<void> _toggleServer() async {
    if (LogWebServer.instance.isRunning) {
      await LogWebServer.instance.stop();
      setState(() => _statusText = '已停止');
    } else {
      setState(() => _isStarting = true);
      try {
        final port = await LogWebServer.instance.start();
        // 获取本机 IP
        final ip = await _getLocalIp();
        setState(() {
          _statusText = '运行中\n'
              '局域网访问: http://$ip:$port\n'
              '本机访问: http://localhost:$port';
        });
      } on Object catch (e) {
        setState(() => _statusText = '启动失败: $e');
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
        Text('日志 Web 服务器', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          '启动后可在 PC 浏览器中实时查看本机日志，无需导出文件。\n'
          '适用于移动端（SD 卡导出受限的场景）。\n\n'
          '服务器为全局单例，离开此页面不会停止，'
          '只有手动停止或应用退出才关闭。\n\n'
          '端点：\n'
          '  /            → 实时日志查看器（WebSocket）\n'
          '  /logs        → 全量日志文本（可 curl 下载）\n'
          '  /diagnostics → 诊断快照文本',
          style: TextStyle(fontSize: 13, color: Colors.grey[600]),
        ),
        const SizedBox(height: 24),
        // 状态指示
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: (isRunning ? Colors.green : Colors.grey)
                .withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: (isRunning ? Colors.green : Colors.grey)
                    .withValues(alpha: 0.3)),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(isRunning ? Icons.wifi : Icons.wifi_off,
                      color: isRunning ? Colors.green : Colors.grey),
                  const SizedBox(width: 8),
                  Text(
                    isRunning
                        ? '运行中 (端口 ${LogWebServer.instance.port})'
                        : '已停止',
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
          label: Text(isRunning ? '停止' : '启动'),
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
                  '安全提示：服务器绑定 0.0.0.0，同一局域网内的设备均可访问。'
                  '日志不含密码/Token 等敏感信息。'
                  '当前为 debug 阶段，服务器会随同步服务自动启动；'
                  '发布版本会改为默认关闭。',
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
    SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 2),
    ),
  );
}
