/*
 * 同步设置页面
 *
 * 功能：
 *   - 选择同步后端（无 / 本地文件夹 / WebDAV）
 *   - 配置 LocalFs 路径或 WebDAV 凭据
 *   - 开关自动同步
 *   - 手动触发同步
 *   - 显示同步状态和上次结果
 */

// Flutter 导入
import 'package:flutter/material.dart';

// Package 导入
import 'package:file_picker/file_picker.dart';
import 'package:settings_ui/settings_ui.dart';

// Project 导入
import 'package:core/core.dart';
import 'package:safenotes/sync/sync_config.dart';
import 'package:safenotes/sync/sync_service.dart';

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
        title: const Text('同步设置'),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    return SettingsList(
      platform: DevicePlatform.iOS,
      sections: [
        // ── 同步状态 ──
        SettingsSection(
          title: const Text('同步状态'),
          tiles: [
            SettingsTile.navigation(
              leading: const Icon(Icons.sync),
              title: const Text('立即同步'),
              value: Text(_syncStatusText()),
              onPressed: (_) => _triggerSync(),
            ),
            SettingsTile.navigation(
              leading: const Icon(Icons.build_outlined),
              title: const Text('修复同步数据'),
              description: const Text('扫描并修复远端无法解密的 blob'),
              onPressed: (_) => _triggerRepair(),
            ),
            SettingsTile.navigation(
              leading: const Icon(Icons.info_outline),
              title: const Text('上次同步'),
              value: Text(_lastSyncText()),
            ),
          ],
        ),

        // ── 后端配置 ──
        SettingsSection(
          title: const Text('后端配置'),
          tiles: [
            SettingsTile.navigation(
              leading: const Icon(Icons.cloud_outlined),
              title: const Text('后端类型'),
              value: Text(SyncConfig.backendDisplayName),
              onPressed: (_) => _showBackendTypePicker(),
            ),
            if (SyncConfig.backendType == SyncBackendType.localFs)
              SettingsTile.navigation(
                leading: const Icon(Icons.folder_outlined),
                title: const Text('同步文件夹'),
                value: Text(
                  SyncConfig.localFsPath.isEmpty
                      ? '未设置'
                      : SyncConfig.localFsPath,
                ),
                onPressed: (_) => _pickLocalFsPath(),
              ),
            if (SyncConfig.backendType == SyncBackendType.webdav) ...[
              SettingsTile.navigation(
                leading: const Icon(Icons.link),
                title: const Text('WebDAV 地址'),
                value: Text(
                  SyncConfig.webdavUrl.isEmpty
                      ? '未设置'
                      : SyncConfig.webdavUrl,
                ),
                onPressed: (_) => _editWebdavUrl(),
              ),
              SettingsTile.navigation(
                leading: const Icon(Icons.person_outline),
                title: const Text('用户名'),
                value: Text(
                  SyncConfig.webdavUsername.isEmpty
                      ? '未设置'
                      : SyncConfig.webdavUsername,
                ),
                onPressed: (_) => _editWebdavUsername(),
              ),
              SettingsTile.navigation(
                leading: const Icon(Icons.lock_outline),
                title: const Text('密码'),
                value: Text(
                  SyncConfig.webdavPassword.isEmpty
                      ? '未设置'
                      : '已设置',
                ),
                onPressed: (_) => _editWebdavPassword(),
              ),
            ],
            if (SyncConfig.backendType == SyncBackendType.safeServer) ...[
              SettingsTile.navigation(
                leading: const Icon(Icons.dns_outlined),
                title: const Text('SafeServer 地址'),
                value: Text(
                  SyncConfig.safeServerUrl.isEmpty
                      ? '未设置'
                      : SyncConfig.safeServerUrl,
                ),
                onPressed: (_) => _editSafeServerUrl(),
              ),
              SettingsTile.navigation(
                leading: const Icon(Icons.key),
                title: const Text('Token'),
                value: Text(
                  SyncConfig.safeServerToken.isEmpty
                      ? '未设置'
                      : '已设置',
                ),
                onPressed: (_) => _editSafeServerToken(),
              ),
            ],
          ],
        ),

        // ── 自动同步 ──
        SettingsSection(
          title: const Text('自动同步'),
          tiles: [
            SettingsTile.switchTile(
              leading: const Icon(Icons.autorenew),
              title: const Text('笔记变更后自动同步'),
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
          title: const Text('加密 Keyring'),
          tiles: [
            SettingsTile.navigation(
              leading: const Icon(Icons.vpn_key_outlined),
              title: const Text('Keyring 状态'),
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
    final state = SyncService.instance.state;
    switch (state.status) {
      case SyncStatus.uninitialized:
        return '未初始化';
      case SyncStatus.idle:
        return SyncConfig.isSyncEnabled ? '就绪' : '未配置后端';
      case SyncStatus.syncing:
        return '同步中...';
      case SyncStatus.success:
        return '同步成功';
      case SyncStatus.error:
        return '同步失败';
    }
  }

  String _lastSyncText() {
    final state = SyncService.instance.state;
    if (state.lastSyncTime == null) {
      return '从未同步';
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
        result += ' (失败)';
      }
    }
    return result;
  }

  String _vaultStatusText() {
    return SyncService.instance.keyring != null ? '已解锁' : '未初始化';
  }

  // ──────────────────────────────────────────────
  // 后端配置交互
  // ──────────────────────────────────────────────

  void _showBackendTypePicker() {
    showDialog(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('选择同步后端'),
        children: [
          SimpleDialogOption(
            onPressed: () => _selectBackendType(SyncBackendType.none),
            child: const ListTile(
              leading: Icon(Icons.close),
              title: Text('不同步'),
              subtitle: Text('禁用同步功能'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => _selectBackendType(SyncBackendType.localFs),
            child: const ListTile(
              leading: Icon(Icons.folder),
              title: Text('本地文件夹'),
              subtitle: Text('同步到本地目录（测试/单设备）'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => _selectBackendType(SyncBackendType.webdav),
            child: const ListTile(
              leading: Icon(Icons.cloud),
              title: Text('WebDAV'),
              subtitle: Text('坚果云 / NextCloud / 自建'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => _selectBackendType(SyncBackendType.safeServer),
            child: const ListTile(
              leading: Icon(Icons.dns),
              title: Text('SafeServer'),
              subtitle: Text('自建轻量同步服务（HTTP API）'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _selectBackendType(SyncBackendType type) async {
    await SyncConfig.setBackendType(type);
    // F-H06：配置变更立即应用到运行中的 SyncService（停止旧引擎或切换后端），
    // 否则内存中旧 backend 继续被 autoSync 使用，改配置形同虚设
    await _applyConfigToService();
    if (mounted) {
      Navigator.pop(context);
      setState(() {});
    }
  }

  Future<void> _pickLocalFsPath() async {
    final result = await FilePicker.getDirectoryPath();
    if (result != null) {
      await SyncConfig.setLocalFsPath(result);
      await _applyConfigToService();
      if (mounted) setState(() {});
    }
  }

  Future<void> _editWebdavUrl() async {
    await _showTextEditor(
      title: 'WebDAV 地址',
      initialValue: SyncConfig.webdavUrl,
      hintText: 'https://dav.jianguoyun.com/dav/',
      onSave: (value) async {
        await SyncConfig.setWebdavUrl(value);
        await _applyConfigToService();
        if (mounted) setState(() {});
      },
    );
  }

  Future<void> _editWebdavUsername() async {
    await _showTextEditor(
      title: 'WebDAV 用户名',
      initialValue: SyncConfig.webdavUsername,
      hintText: 'user@example.com',
      onSave: (value) async {
        await SyncConfig.setWebdavUsername(value);
        await _applyConfigToService();
        if (mounted) setState(() {});
      },
    );
  }

  Future<void> _editWebdavPassword() async {
    await _showTextEditor(
      title: 'WebDAV 密码',
      initialValue: SyncConfig.webdavPassword,
      hintText: '应用专用密码（非登录密码）',
      obscure: true,
      onSave: (value) async {
        await SyncConfig.setWebdavPassword(value);
        await _applyConfigToService();
        if (mounted) setState(() {});
      },
    );
  }

  Future<void> _editSafeServerUrl() async {
    await _showTextEditor(
      title: 'SafeServer 地址',
      initialValue: SyncConfig.safeServerUrl,
      hintText: 'http://192.168.1.118:2025',
      onSave: (value) async {
        await SyncConfig.setSafeServerUrl(value);
        await _applyConfigToService();
        if (mounted) setState(() {});
      },
    );
  }

  Future<void> _editSafeServerToken() async {
    await _showTextEditor(
      title: 'SafeServer Token',
      initialValue: SyncConfig.safeServerToken,
      hintText: '部署时配置的固定 Bearer Token',
      obscure: true,
      onSave: (value) async {
        await SyncConfig.setSafeServerToken(value);
        await _applyConfigToService();
        if (mounted) setState(() {});
      },
    );
  }

  /// F-H06：把当前 SyncConfig 应用到运行中的 SyncService
  Future<void> _applyConfigToService() async {
    await SyncService.instance.applyConfigToService(
      database: NotesDatabase.instance,
    );
  }

  Future<void> _showTextEditor({
    required String title,
    required String initialValue,
    required String hintText,
    required Function(String) onSave,
    bool obscure = false,
  }) async {
    final controller = TextEditingController(text: initialValue);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(hintText: hintText),
          obscureText: obscure,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result != null) {
      await onSave(result);
    }
  }

  // ──────────────────────────────────────────────
  // 同步触发
  // ──────────────────────────────────────────────

  Future<void> _triggerSync() async {
    // 用户从设置页主动触发同步，是重要人工动作，需明确留痕
    Log.sync.i('用户触发手动同步（同步设置页）');
    // 如果同步服务未初始化，尝试用内存中 keyring 初始化后端
    // （登录时 keyring 已缓存，配置完后端即可直接初始化）
    if (!SyncService.instance.state.isInitialized) {
      if (SyncService.instance.keyring == null) {
        _showMessage('Keyring 未初始化，请重新登录');
        return;
      }
      final result = await SyncService.instance.initBackend(
        database: NotesDatabase.instance,
      );
      if (!result.success) {
        _showMessage(result.error ?? '后端初始化失败');
        return;
      }
    }

    final result = await SyncService.instance.sync();
    if (mounted) {
      setState(() {});
      if (result != null && !result.success) {
        _showMessage('同步失败：${result.errorMessage}');
      } else if (result != null && result.hasChanges) {
        _showMessage('同步完成：↑${result.uploaded} ↓${result.downloaded}');
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
    if (!SyncService.instance.state.isInitialized) {
      if (SyncService.instance.keyring == null) {
        _showMessage('Keyring 未初始化，请重新登录');
        return;
      }
      final result = await SyncService.instance.initBackend(
        database: NotesDatabase.instance,
      );
      if (!result.success) {
        _showMessage(result.error ?? '后端初始化失败');
        return;
      }
    }

    _showMessage('正在校验并修复远端数据…');
    final result = await SyncService.instance.repairRemote();

    if (mounted) {
      setState(() {});
      if (result == null) {
        _showMessage('修复未执行：正在同步中或无权限');
      } else if (!result.success) {
        _showMessage('修复失败：${result.errorMessage}');
      } else if (result.failedNoteUuids.isNotEmpty) {
        _showMessage('修复完成：治愈 ${result.uploaded} 条，'
            '${result.failedNoteUuids.length} 条仍无法解密（无密钥/明文）');
      } else {
        _showMessage('修复完成：治愈 ${result.uploaded} 条，无残留损坏');
      }
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}
