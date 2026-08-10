/*
 * 同步设置页面
 *
 * 功能：
 *   - 同步总开关（独立于后端配置：出错时关掉即可止血，配置原样保留）
 *   - 打开后端配置面板（地址/账号/密码/Token 一次填完，测试通过才能保存）
 *   - 开关自动同步
 *   - 手动触发同步
 *   - 显示同步状态和上次结果
 */

// Flutter 导入
import 'package:flutter/material.dart';

// Package 导入
import 'package:easy_localization/easy_localization.dart';
import 'package:settings_ui/settings_ui.dart';
import 'package:safenotes/utils/settings_platform.dart';

// Project 导入
import 'package:core/core.dart';
import 'package:safenotes/sync/sync_config.dart';
import 'package:safenotes/sync/sync_service.dart';
import 'package:safenotes/views/settings/sync_backend_config_page.dart';

class SyncSettingsPage extends StatefulWidget {
  const SyncSettingsPage({super.key});

  @override
  State<SyncSettingsPage> createState() => _SyncSettingsPageState();
}

class _SyncSettingsPageState extends State<SyncSettingsPage> {
  @override
  void initState() {
    super.initState();
    _initSyncConfig();
  }

  Future<void> _initSyncConfig() async {
    await SyncConfig.init();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Sync Settings'.tr()),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    return SettingsList(
      platform: currentDevicePlatform,
      sections: [
        // ── 同步总开关 ──
        SettingsSection(
          title: Text('Sync Switch'.tr()),
          tiles: [
            SettingsTile.switchTile(
              leading: const Icon(Icons.cloud_sync_outlined),
              title: Text('Enable Sync'.tr()),
              description: Text('Disables all communication with remote; backend config is kept.'.tr()),
              initialValue: SyncConfig.isSyncEnabled,
              onToggle: _toggleSyncEnabled,
            ),
          ],
        ),

        // ── 同步状态 ──
        SettingsSection(
          title: Text('Sync Status'.tr()),
          tiles: [
            SettingsTile.navigation(
              leading: const Icon(Icons.sync),
              title: Text('Sync Now'.tr()),
              value: Text(_syncStatusText()),
              onPressed: (_) => _triggerSync(),
            ),
            SettingsTile.navigation(
              leading: const Icon(Icons.build_outlined),
              title: Text('Repair Sync Data'.tr()),
              description: Text('Scans and repairs blobs that the remote cannot decrypt.'.tr()),
              onPressed: (_) => _triggerRepair(),
            ),
            SettingsTile.navigation(
              leading: const Icon(Icons.info_outline),
              title: Text('Last Sync'.tr()),
              value: Text(_lastSyncText()),
            ),
          ],
        ),

        // ── 后端配置 ──
        SettingsSection(
          title: Text('Backend Config'.tr()),
          tiles: [
            SettingsTile.navigation(
              leading: const Icon(Icons.settings_ethernet),
              title: Text('Sync Configuration'.tr()),
              description: Text(_backendSummaryText()),
              value: Text(SyncConfig.backendDisplayName),
              onPressed: (_) => _openBackendConfigPanel(),
            ),
          ],
        ),

        // ── 自动同步 ──
        SettingsSection(
          title: Text('Auto Sync'.tr()),
          tiles: [
            SettingsTile.switchTile(
              leading: const Icon(Icons.autorenew),
              title: Text('Auto sync after note changes'.tr()),
              initialValue: SyncConfig.isAutoSyncEnabled,
              onToggle: (value) async {
                await SyncConfig.setAutoSyncEnabled(value);
                setState(() {});
              },
            ),
          ],
        ),

        // ── Keyring 管理 ──
        SettingsSection(
          title: Text('Encrypted Keyring'.tr()),
          tiles: [
            SettingsTile.navigation(
              leading: const Icon(Icons.vpn_key_outlined),
              title: Text('Keyring Status'.tr()),
              value: Text(_vaultStatusText()),
            ),
          ],
        ),
      ],
    );
  }

  // ──────────────────────────────────────────────
  // 状态显示
  // ──────────────────────────────────────────────

  String _syncStatusText() {
    if (!SyncConfig.isSyncEnabled) return 'Disabled'.tr();
    if (!SyncConfig.hasBackendConfig) return 'No backend configured'.tr();
    final state = SyncService.instance.state;
    switch (state.status) {
      case SyncStatus.uninitialized:
        return 'Not initialized'.tr();
      case SyncStatus.idle:
        return 'Ready'.tr();
      case SyncStatus.syncing:
        return 'Syncing…'.tr();
      case SyncStatus.success:
        return 'Sync successful'.tr();
      case SyncStatus.error:
        return 'Sync failed'.tr();
    }
  }

  /// 后端配置摘要（一眼看出当前连的是哪里，不泄漏密码/Token）
  String _backendSummaryText() {
    switch (SyncConfig.backendType) {
      case SyncBackendType.none:
        return 'No backend selected yet. Tap to configure.'.tr();
      case SyncBackendType.localFs:
        final path = SyncConfig.localFsPath;
        return path.isEmpty ? 'Sync folder not set'.tr() : path;
      case SyncBackendType.webdav:
        final url = SyncConfig.webdavUrl;
        if (url.isEmpty) return 'Server address not set'.tr();
        return '$url (${SyncConfig.webdavUsername})';
      case SyncBackendType.safeServer:
        final url = SyncConfig.safeServerUrl;
        return url.isEmpty ? 'Server address not set'.tr() : url;
    }
  }

  String _lastSyncText() {
    final state = SyncService.instance.state;
    if (state.lastSyncTime == null) {
      return 'Never synced'.tr();
    }
    final time = state.lastSyncTime!;
    String result = '${time.month}/${time.day} ${time.hour}:${time.minute.toString().padLeft(2, '0')}';
    if (state.lastResult != null) {
      final r = state.lastResult!;
      if (r.success) {
        result += ' (↑${r.uploaded} ↓${r.downloaded}';
        if (r.deleted > 0) result += ' ✗${r.deleted}';
        result += ')';
      } else {
        result += ' (failed)'.tr();
      }
    }
    return result;
  }

  String _vaultStatusText() {
    return SyncService.instance.keyring != null
        ? 'Unlocked'.tr()
        : 'Not initialized'.tr();
  }

  // ──────────────────────────────────────────────
  // 后端配置交互
  // ──────────────────────────────────────────────

  /// 同步总开关
  ///
  /// 与后端配置解耦：关掉只是停用同步服务，地址/凭据一个字都不动，
  /// 排查完问题打开开关即可原样恢复。
  Future<void> _toggleSyncEnabled(bool enabled) async {
    await SyncConfig.setSyncEnabled(enabled);
    // 需求 3：开关打开且配置有效时自动把同步服务拉起来；
    // 关闭时停掉引擎与后端连接。两个方向都由 applyConfigToService 承担。
    final result = await _applyConfigToService();
    if (!mounted) return;
    setState(() {});

    if (enabled && !SyncConfig.hasBackendConfig) {
      _showMessage('Sync enabled, but no backend configured. Please complete the sync configuration.'.tr());
    } else if (enabled && !result.success) {
      _showMessage('Sync enabled, but initialization failed: {error}'.tr(
          namedArgs: {'error': result.error ?? 'Unknown error'.tr()}));
    } else if (enabled && SyncService.instance.state.isInitialized) {
      // 刚启用就拉一次远端，行为与登录后一致
      SyncService.instance.autoSync();
    }
  }

  /// 打开后端配置面板（地址/账号/密码/Token 一次填完，测试通过才能保存）
  Future<void> _openBackendConfigPanel() async {
    final saved = await showSyncBackendConfigPanel(
      context,
      initialDraft: SyncBackendDraft.fromConfig(),
    );
    if (saved == null) return; // 用户取消

    await saved.save();
    // F-H06：配置变更立即应用到运行中的 SyncService（停止旧引擎或切换后端），
    // 否则内存中旧 backend 继续被 autoSync 使用，改配置形同虚设
    final result = await _applyConfigToService();
    if (!mounted) return;
    setState(() {});

    if (!result.success) {
      _showMessage('Config saved, but failed to apply: {error}'.tr(
          namedArgs: {'error': result.error ?? 'Unknown error'.tr()}));
    } else if (!SyncConfig.isSyncEnabled &&
        saved.type != SyncBackendType.none) {
      _showMessage('Config saved. Sync is currently off; it will take effect when enabled.'.tr());
    } else {
      _showMessage('Sync configuration saved'.tr());
    }
  }

  /// F-H06：把当前 SyncConfig 应用到运行中的 SyncService
  Future<({bool success, String? error})> _applyConfigToService() async {
    return SyncService.instance.applyConfigToService(
      database: NotesDatabase.instance,
    );
  }

  // ──────────────────────────────────────────────
  // 同步触发
  // ──────────────────────────────────────────────

  Future<void> _triggerSync() async {
    // 用户从设置页主动触发同步，是重要人工动作，需明确留痕
    Log.sync.i('用户触发手动同步（同步设置页）');
    if (!_ensureSyncUsable()) return;
    // 如果同步服务未初始化，尝试用内存中 keyring 初始化后端
    // （登录时 keyring 已缓存，配置完后端即可直接初始化）
    if (!SyncService.instance.state.isInitialized) {
      if (SyncService.instance.keyring == null) {
        _showMessage('Keyring not initialized. Please log in again.'.tr());
        return;
      }
      final result = await SyncService.instance.initBackend(
        database: NotesDatabase.instance,
      );
      if (!result.success) {
        _showMessage(result.error ?? 'Backend initialization failed'.tr());
        return;
      }
    }

    final result = await SyncService.instance.sync();
    if (mounted) {
      setState(() {});
      if (result != null && !result.success) {
        _showMessage('Sync failed: {error}'.tr(
            namedArgs: {'error': '${result.errorMessage}'}));
      } else if (result != null && result.hasChanges) {
        _showMessage('Sync complete: ↑{uploaded} ↓{downloaded}'.tr(
            namedArgs: {
              'uploaded': '${result.uploaded}',
              'downloaded': '${result.downloaded}',
            }));
      }
    }
  }

  /// 「修复同步数据」按钮：扫描远端 blob 并尝试修复坏条目。
  ///
  /// 可选输入旧密码（用于恢复 scenario-d 合并产生的旧密钥 blob）；
  /// 留空则仅用当前 dataKey + 本机明文尝试修复。
  Future<void> _triggerRepair() async {
    // 用户主动触发「修复同步数据」，重要人工动作
    Log.sync.i('用户触发修复同步数据（同步设置页）');
    if (!_ensureSyncUsable()) return;
    if (!SyncService.instance.state.isInitialized) {
      if (SyncService.instance.keyring == null) {
        _showMessage('Keyring not initialized. Please log in again.'.tr());
        return;
      }
      final result = await SyncService.instance.initBackend(
        database: NotesDatabase.instance,
      );
      if (!result.success) {
        _showMessage(result.error ?? 'Backend initialization failed'.tr());
        return;
      }
    }

    _showMessage('Verifying and repairing remote data…'.tr());
    final result = await SyncService.instance.repairRemote();

    if (mounted) {
      setState(() {});
      if (result == null) {
        _showMessage('Repair skipped: syncing in progress or no permission'.tr());
      } else if (!result.success) {
        _showMessage('Repair failed: {error}'.tr(
            namedArgs: {'error': '${result.errorMessage}'}));
      } else if (result.failedNoteUuids.isNotEmpty) {
        _showMessage(
            'Repair complete: fixed {fixed} entries, {failed} still unreadable (no key/plaintext).'
                .tr(namedArgs: {
              'fixed': '${result.uploaded}',
              'failed': '${result.failedNoteUuids.length}',
            }));
      } else {
        _showMessage('Repair complete: fixed {fixed} entries, no remaining corruption.'
            .tr(namedArgs: {'fixed': '${result.uploaded}'}));
      }
    }
  }

  /// 手动同步 / 修复前的前置检查：总开关 + 后端配置
  ///
  /// 返回 false 表示已给出提示、调用方应直接返回。
  bool _ensureSyncUsable() {
    if (!SyncConfig.isSyncEnabled) {
      _showMessage('Sync is disabled. Enable "Enable Sync" first.'.tr());
      return false;
    }
    if (!SyncConfig.hasBackendConfig) {
      _showMessage('No sync backend configured. Please complete the sync configuration first.'.tr());
      return false;
    }
    return true;
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}
