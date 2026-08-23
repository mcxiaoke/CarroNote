/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

/*
 * 同步调试面板（E1）
 *
 * 四个 Tab 面板：
 *   1. 状态：同步子系统诊断快照（含后端/Keyring/设备信息，可复制），
 *      底部以纯文本展示最近一次同步结果
 *   2. 日志：实时日志查看器（logcat 风格，可过滤/复制/导出/清空）
 *   3. Web 服务器：启动/停止 HTTP 日志服务器（移动端远程查看用）
 *   4. 测试：危险调试操作（清空日志 / journal / 数据库）
 *
 * 所有面板的信息均可复制，日志支持导出到系统下载目录。
 */

// Dart 导入

import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitType;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:core/core.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/src/logger/log_webserver.dart';
import 'package:safenotes/authwall.dart' show AppBootState;
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/biometric_auth.dart';
import 'package:safenotes/models/pin_auth.dart';
import 'package:safenotes/sync/sync_service.dart';
import 'package:safenotes/utils/snack_message.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/utils/text_styles.dart';

// Flutter 导入

// Package 导入

// Project 导入

class SyncDiagnosticsPage extends StatefulWidget {
  const SyncDiagnosticsPage({super.key});

  @override
  State<SyncDiagnosticsPage> createState() => _SyncDiagnosticsPageState();
}

class _SyncDiagnosticsPageState extends State<SyncDiagnosticsPage> {
  String _selectedTab = 'status';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Debug Panel'.tr(), style: appBarTitle),
        actions: [
          IconButton(
            icon: const Icon(LucideIcons.rotateCw),
            tooltip: 'Refresh'.tr(),
            onPressed: () => setState(() {}),
          ),
        ],
      ),
      body: ShadTabs<String>(
        value: _selectedTab,
        onChanged: (value) => setState(() => _selectedTab = value),
        scrollable: true,
        gap: 8,
        // 与原 TabBarView 一致：非激活 tab 不常驻构建（避免日志 tab 在
        // Offstage 未布局时提前 initState 触发未就绪的滚动，导致崩溃）。
        maintainState: false,
        tabs: [
          ShadTab<String>(
            value: 'status',
            expandContent: true,
            content: _StatusTab(),
            child: Text('Status'.tr()),
          ),
          ShadTab<String>(
            value: 'logs',
            expandContent: true,
            content: _LogsTab(),
            child: Text('Logs'.tr()),
          ),
          ShadTab<String>(
            value: 'web',
            expandContent: true,
            content: _WebServerTab(onUpdate: () => setState(() {})),
            child: Text('Web Server'.tr()),
          ),
          ShadTab<String>(
            value: 'test',
            expandContent: true,
            content: const _TestTab(),
            child: Text('Test'.tr()),
          ),
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
                  icon: const Icon(LucideIcons.copy, size: 20),
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
              color: _semDanger(context),
            ),
        ]),
        _buildSection(context, 'Backend Config'.tr(), [
          _KV(
            'Sync Master Switch'.tr(),
            snapshot.syncEnabled ? 'On'.tr() : 'Off'.tr(),
            color: snapshot.syncEnabled ? null : _semWarning(context),
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
        // 最近一次同步结果（纯文本，原"同步结果"tab 数据并入此处）
        Text(
          'Latest Sync Result'.tr(),
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(4),
          ),
          child: SelectableText(
            _lastResultPlainText(snapshot),
            style: TextStyle(
              fontSize: AppTextSize.s12,
              fontFamily: 'monospace',
              height: 1.4,
              color: snapshot.lastResultSuccess == true
                  ? _semSuccess(context)
                  : snapshot.lastResultSuccess == false
                  ? _semDanger(context)
                  : _semNeutral(context),
            ),
          ),
        ),
        const SizedBox(height: 16),
        ShadButton.raw(
          variant: ShadButtonVariant.outline,
          leading: const Icon(LucideIcons.download),
          child: Text('Export Diagnostics + Logs'.tr()),
          onPressed: () async {
            try {
              final path = await SyncService.instance.exportAllLogsToFile();
              if (context.mounted) {
                showSnackBarMessage(
                  context,
                  'Exported to {path}'.tr(namedArgs: {'path': path}),
                );
              }
            } on Object catch (e) {
              if (context.mounted) {
                showSnackBarMessage(
                  context,
                  'Export failed: {error}'.tr(namedArgs: {'error': '$e'}),
                );
              }
            }
          },
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
              style: TextStyle(
                color: _semNeutral(context),
                fontSize: AppTextSize.s12,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              kv.value,
              style: TextStyle(fontSize: AppTextSize.s12, color: kv.color),
            ),
          ),
        ],
      ),
    );
  }

  /// 最近一次同步结果 → 纯文本块（原"同步结果"tab 数据）
  String _lastResultPlainText(SyncDiagnosticsSnapshot s) {
    if (s.lastResultSuccess == null) return 'No sync results yet'.tr();
    final failed = s.lastResultFailedNoteUuids;
    final actionCount = s.lastResultActions?.length ?? 0;
    return [
      'Success: ${s.lastResultSuccess}',
      'Attempts: ${s.lastResultAttempts ?? "N/A"}',
      'RequiresRelogin: ${s.lastResultRequiresRelogin ?? false}',
      'Uploaded/Downloaded/Deleted: '
          '${s.lastResultUploaded ?? 0}/${s.lastResultDownloaded ?? 0}/'
          '${s.lastResultDeleted ?? 0}',
      'Conflicts/Migrated/Skipped: '
          '${s.lastResultConflicts ?? 0}/${s.lastResultMigrated ?? 0}/'
          '${s.lastResultSkipped ?? 0}',
      'Actions: $actionCount',
      'Error: ${s.lastResultErrorMessage ?? "-"}',
      'FailedNotes(${failed?.length ?? 0}): '
          '${(failed == null || failed.isEmpty) ? "-" : failed.join(", ")}',
    ].join('\n');
  }
}

class _KV {
  final String key;
  final String value;
  final Color? color;
  const _KV(this.key, this.value, {this.color});
}

// ──────────────────────────────────────────────
// Tab 2: 日志（实时 logcat 风格）
// ──────────────────────────────────────────────

class _LogsTab extends StatefulWidget {
  @override
  State<_LogsTab> createState() => _LogsTabState();
}

class _LogsTabState extends State<_LogsTab> {
  final List<AppLogEntry> _entries = [];
  StreamSubscription<AppLogEntry>? _sub;
  final ScrollController _scrollController = ScrollController();
  final ShadPopoverController _levelFilterController = ShadPopoverController();
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
            // hasContentDimensions：滚动视图完成首次布局后才有内容尺寸；
            // 未布局（如 Offstage）时 maxScrollExtent 为 null，直接跳过。
            if (_scrollController.hasClients &&
                _scrollController.position.hasContentDimensions) {
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
    _levelFilterController.dispose();
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
              bottom: BorderSide(
                color: _semNeutral(context).withValues(alpha: 0.3),
              ),
            ),
          ),
          child: Row(
            children: [
              // 级别过滤按钮
              ShadPopover(
                controller: _levelFilterController,
                child: Tooltip(
                  message: 'Level Filter'.tr(),
                  child: ShadIconButton.raw(
                    variant: ShadButtonVariant.ghost,
                    icon: const Icon(LucideIcons.listFilter, size: 20),
                    onPressed: () => _levelFilterController.toggle(),
                  ),
                ),
                popover: (context) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final level in AppLogLevel.values)
                      InkWell(
                        onTap: () => setState(() {
                          _levelFilter[level] = !(_levelFilter[level] ?? true);
                        }),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                (_levelFilter[level] ?? true)
                                    ? LucideIcons.squareCheck
                                    : LucideIcons.square,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Text(_levelName(level)),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              // 自动滚动
              IconButton(
                icon: Icon(
                  _autoScroll
                      ? LucideIcons.alignEndVertical
                      : LucideIcons.alignStartVertical,
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
                icon: const Icon(LucideIcons.copy, size: 20),
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
              // 导出（写入系统下载目录）
              IconButton(
                icon: const Icon(LucideIcons.download, size: 20),
                tooltip: 'Export Diagnostics + Logs'.tr(),
                onPressed: () async {
                  try {
                    final path = await SyncService.instance
                        .exportAllLogsToFile();
                    if (context.mounted) {
                      showSnackBarMessage(
                        context,
                        'Exported to {path}'.tr(namedArgs: {'path': path}),
                      );
                    }
                  } on Object catch (e) {
                    if (context.mounted) {
                      showSnackBarMessage(
                        context,
                        'Export failed: {error}'.tr(namedArgs: {'error': '$e'}),
                      );
                    }
                  }
                },
              ),
              // 清空（仅清空内存缓冲，不影响文件）
              IconButton(
                icon: const Icon(LucideIcons.trash2, size: 20),
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
            style: TextStyle(
              fontSize: AppTextSize.s12,
              color: _semNeutral(context),
            ),
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
    final color = _levelColor(context, entry.level);
    // 窄屏（手机）裁掉日期前缀只留时间：实时日志基本都在同一天，
    // 日期无意义却占掉小半行宽度
    var line = entry.formattedLine;
    if (MediaQuery.sizeOf(context).width < 600) {
      line = line.replaceFirst(RegExp(r'^\d{4}-\d{2}-\d{2} '), '');
    }
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
      child: SelectableText(
        line,
        style: TextStyle(
          fontSize: AppTextSize.s12,
          fontFamily: 'monospace',
          color: color,
          height: 1.4,
        ),
      ),
    );
  }

  Color _levelColor(BuildContext context, AppLogLevel level) {
    switch (level) {
      case AppLogLevel.trace:
        return _semNeutral(context);
      case AppLogLevel.debug:
        return _semNeutral(context);
      case AppLogLevel.info:
        return _semInfo(context);
      case AppLogLevel.warning:
        return _semWarning(context);
      case AppLogLevel.error:
        return _semDanger(context);
      case AppLogLevel.fatal:
        return _semDanger(context);
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
// Tab 3: Web 服务器
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
    final token = LogWebServer.instance.token ?? '';
    setState(() {
      _statusText =
          'Running\nLAN: http://{ip}:{port}/?token={token}\nLocal: http://localhost:{port}/?token={token}'
              .tr(namedArgs: {'ip': ip, 'port': '$port', 'token': token});
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
        final token = LogWebServer.instance.token ?? '';
        setState(() {
          _statusText =
              'Running\nLAN: http://{ip}:{port}/?token={token}\nLocal: http://localhost:{port}/?token={token}'
                  .tr(namedArgs: {'ip': ip, 'port': '$port', 'token': token});
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
          style: TextStyle(
            fontSize: AppTextSize.s12,
            color: _semNeutral(context),
          ),
        ),
        const SizedBox(height: 24),
        // 状态指示
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: (isRunning ? _semSuccess(context) : _semNeutral(context))
                .withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: (isRunning ? _semSuccess(context) : _semNeutral(context))
                  .withValues(alpha: 0.3),
            ),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    isRunning ? LucideIcons.wifi : LucideIcons.wifiOff,
                    color: isRunning
                        ? _semSuccess(context)
                        : _semNeutral(context),
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
                      color: isRunning
                          ? _semSuccess(context)
                          : _semNeutral(context),
                    ),
                  ),
                ],
              ),
              if (isRunning) ...[
                const SizedBox(height: 12),
                SelectableText(
                  _statusText,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: AppTextSize.s12),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        // 启动/停止按钮
        ShadButton(
          onPressed: _isStarting ? null : _toggleServer,
          leading: _isStarting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(isRunning ? LucideIcons.square : LucideIcons.play),
          child: Text(isRunning ? 'Stop'.tr() : 'Start'.tr()),
        ),
        const SizedBox(height: 16),
        // 安全提示
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _semWarning(context).withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _semWarning(context).withValues(alpha: 0.3),
            ),
          ),
          child: Row(
            children: [
              Icon(
                LucideIcons.triangleAlert,
                color: _semWarning(context),
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Security note: the server binds 0.0.0.0. A random 6-digit token is generated on each start; all requests must include ?token=xxx. Logs do not contain sensitive information. Currently in debug stage, the server starts automatically; release builds will default to off.'
                      .tr(),
                  style: TextStyle(
                    fontSize: AppTextSize.s12,
                    color: _semWarning(context),
                  ),
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
// Tab 4: 测试（危险调试操作，仅 dev 面板可达）
// ──────────────────────────────────────────────

class _TestTab extends StatelessWidget {
  const _TestTab();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Test'.tr(), style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          'These operations are destructive and take effect immediately, only for debugging and testing.'
              .tr(),
          style: TextStyle(
            fontSize: AppTextSize.s12,
            color: _semWarning(context),
          ),
        ),
        const SizedBox(height: 16),
        _TestButton(
          icon: LucideIcons.trash2,
          label: 'Clear Logs'.tr(),
          confirmMessage: 'Clear all log files and in-memory buffer?'.tr(),
          onConfirm: () async {
            final deleted = await SyncService.instance.clearAllLogs();
            return 'Logs cleared ({count} files)'.tr(
              namedArgs: {'count': '$deleted'},
            );
          },
        ),
        _TestButton(
          icon: LucideIcons.fileX,
          label: 'Clear Journal'.tr(),
          confirmMessage:
              'Clear the local journal? Recovery history will be lost.'.tr(),
          onConfirm: () async {
            await SyncService.instance.clearJournal();
            return 'Journal cleared'.tr();
          },
        ),
        _TestButton(
          icon: LucideIcons.database,
          label: 'Clear Database'.tr(),
          confirmMessage:
              'Delete ALL local data (notes, keys, database)? The app will exit.'
                  .tr(),
          onConfirm: () async {
            // 与登录页「重置本地数据」(_performLocalDataReset) 同款流程，
            // 但不做备份、完成后直接结束进程，用户手动重开进入首次设置：
            // 1. 停同步并释放内存密钥态（防止退出前 autoSync 把远端数据拉回空库）
            await SyncService.instance.logout();
            // 2. 关连接后删除整个 db 文件（含 sync_meta 的 keyring 账本）
            await NotesDatabase.instance.close();
            await NotesDatabase.instance.deleteDbFile();
            // 3. 清除生物识别/PIN 凭据与保险库相关偏好键
            await BiometricAuth.disable();
            await PinAuth.disable();
            await PreferencesStorage.clearVaultRelatedKeys();
            AppBootState.vaultInitialized = false;
            // 4. 结束进程（required：跳过优雅退出询问，各平台直接终止）
            await ServicesBinding.instance.exitApplication(
              AppExitType.required,
            );
            exit(0);
            // return 'Local data reset'.tr();
          },
        ),
      ],
    );
  }
}

/// 危险操作按钮：点击后弹确认框，确认执行并展示结果
class _TestButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final String confirmMessage;
  final Future<String> Function() onConfirm;

  const _TestButton({
    required this.icon,
    required this.label,
    required this.confirmMessage,
    required this.onConfirm,
  });

  @override
  State<_TestButton> createState() => _TestButtonState();
}

class _TestButtonState extends State<_TestButton> {
  bool _running = false;

  Future<void> _run() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.label),
        content: Text(widget.confirmMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel'.tr()),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              'Confirm'.tr(),
              style: TextStyle(color: _semDanger(context)),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _running = true);
    try {
      final message = await widget.onConfirm();
      if (mounted) showSnackBarMessage(context, message);
    } on Object catch (e) {
      if (mounted) {
        showSnackBarMessage(
          context,
          'Failed: {error}'.tr(namedArgs: {'error': '$e'}),
        );
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ShadButton.raw(
        variant: ShadButtonVariant.outline,
        onPressed: _running ? null : _run,
        leading: _running
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(widget.icon, color: _semDanger(context)),
        child: Text(widget.label),
      ),
    );
  }
}

// ──────────────────────────────────────────────
// P2-7 语义色映射（替代硬编码 Material Colors.*，随主题明暗/seed 变化）
// ──────────────────────────────────────────────

/// 成功（原 green）→ 品牌主色
Color _semSuccess(BuildContext context) =>
    Theme.of(context).colorScheme.primary;

/// 危险/失败（原 red）→ shad destructive
Color _semDanger(BuildContext context) =>
    ShadTheme.of(context).colorScheme.destructive;

/// 警告（原 orange）→ M3 tertiary（随 seed 变化的中性强调色）
Color _semWarning(BuildContext context) =>
    Theme.of(context).colorScheme.tertiary;

/// 信息/上传/下载/迁移（原 blue/teal/purple）→ secondary
Color _semInfo(BuildContext context) => Theme.of(context).colorScheme.secondary;

/// 中性/跳过（原 grey）→ onSurfaceVariant
Color _semNeutral(BuildContext context) =>
    Theme.of(context).colorScheme.onSurfaceVariant;

// ──────────────────────────────────────────────
// 辅助：复制到剪贴板
// ──────────────────────────────────────────────

void _copyToClipboard(BuildContext context, String text, String message) {
  Clipboard.setData(ClipboardData(text: text));
  showSnackBarMessage(context, message);
}
