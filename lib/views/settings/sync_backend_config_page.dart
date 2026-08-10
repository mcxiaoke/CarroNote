/*
 * 同步后端配置面板
 *
 * 把原先散落在设置页的 6 个「点一下弹个输入框」收敛成一个完整表单：
 *   - 顶部选后端类型，中部填该类型的地址/账号/密码/Token/目录
 *   - 底部「测试连接」→ 通过后「保存」才可用
 *
 * 两个关键约束：
 *   1. **测试通过才能保存**：保存按钮只在「当前输入的连通性指纹 == 上次
 *      测试通过的指纹」时可用。改动任何一个影响连通性的字段都会作废上次
 *      测试结果，必须重测——避免"测的是 A，存的是 B"。
 *   2. **切换类型不丢配置**：每种后端类型的输入框各自常驻，切走再切回来
 *      内容还在（与持久层"每种类型独立 key"的行为一致）。
 *
 * 本页只负责收集与校验，不写 SharedPreferences、不碰 SyncService：
 * 保存时通过 Navigator.pop 把草稿交回调用方（同步设置页）统一落盘并生效。
 */

// Flutter 导入
import 'package:flutter/material.dart';

// Package 导入
import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';

// Project 导入
import 'package:safenotes/sync/sync_config.dart';
import 'package:safenotes/sync/sync_service.dart';
import 'package:safenotes/utils/platform_ui.dart';

/// 打开同步后端配置面板
///
/// 返回用户保存的草稿；用户取消返回 null。
///
/// **桌面端以弹框（Dialog）呈现**，不占满整个窗口；移动端保持整页
/// （fullscreenDialog），交互范式与原来一致。两种形态共用同一份表单状态
/// （[SyncBackendConfigPage]），仅外壳不同。
Future<SyncBackendDraft?> showSyncBackendConfigPanel(
  BuildContext context, {
  required SyncBackendDraft initialDraft,
}) {
  if (isDesktopPlatform) {
    return showDialog<SyncBackendDraft>(
      context: context,
      // 点遮罩 = 取消（返回 null），与移动端返回键语义一致
      barrierDismissible: true,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          // 限宽限高：弹框而非整窗，桌面端居中显示
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 760),
          child: Column(
            children: [
              _DialogHeader(
                onClose: () => Navigator.of(dialogContext).pop(),
              ),
              Expanded(
                child: SyncBackendConfigPage(initialDraft: initialDraft),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 移动端：整页（全屏对话框样式）
  return Navigator.of(context).push<SyncBackendDraft>(
    MaterialPageRoute<SyncBackendDraft>(
      fullscreenDialog: true,
      builder: (_) => Scaffold(
        appBar: AppBar(
          title: Text('Sync Configuration'.tr()),
        ),
        body: SafeArea(
          bottom: false,
          child: SyncBackendConfigPage(initialDraft: initialDraft),
        ),
      ),
    ),
  );
}

/// 桌面弹框顶部标题栏（含关闭/取消按钮）
class _DialogHeader extends StatelessWidget {
  final VoidCallback onClose;

  const _DialogHeader({required this.onClose});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 8, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Sync Configuration'.tr(),
              style: theme.textTheme.titleMedium,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Cancel'.tr(),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

class SyncBackendConfigPage extends StatefulWidget {
  final SyncBackendDraft initialDraft;

  const SyncBackendConfigPage({super.key, required this.initialDraft});

  @override
  State<SyncBackendConfigPage> createState() => _SyncBackendConfigPageState();
}

class _SyncBackendConfigPageState extends State<SyncBackendConfigPage> {
  late SyncBackendType _type;

  late final TextEditingController _localFsPathCtrl;
  late final TextEditingController _webdavUrlCtrl;
  late final TextEditingController _webdavUsernameCtrl;
  late final TextEditingController _webdavPasswordCtrl;
  late final TextEditingController _safeServerUrlCtrl;
  late final TextEditingController _safeServerTokenCtrl;

  bool _obscureWebdavPassword = true;
  bool _obscureSafeServerToken = true;

  /// 正在测试连接（期间禁用所有按钮，避免重复发起）
  bool _testing = false;

  /// 上一次「测试通过」时的连通性指纹；null 表示还没测过
  String? _passedSignature;

  /// 上一次测试的指纹与结果（用于展示成功/失败提示）
  String? _resultSignature;
  String? _resultError;

  @override
  void initState() {
    super.initState();
    final d = widget.initialDraft;
    _type = d.type;
    _localFsPathCtrl = TextEditingController(text: d.localFsPath);
    _webdavUrlCtrl = TextEditingController(text: d.webdavUrl);
    _webdavUsernameCtrl = TextEditingController(text: d.webdavUsername);
    _webdavPasswordCtrl = TextEditingController(text: d.webdavPassword);
    _safeServerUrlCtrl = TextEditingController(text: d.safeServerUrl);
    _safeServerTokenCtrl = TextEditingController(text: d.safeServerToken);
  }

  @override
  void dispose() {
    _localFsPathCtrl.dispose();
    _webdavUrlCtrl.dispose();
    _webdavUsernameCtrl.dispose();
    _webdavPasswordCtrl.dispose();
    _safeServerUrlCtrl.dispose();
    _safeServerTokenCtrl.dispose();
    super.dispose();
  }

  /// 由当前界面输入组装草稿（含所有类型的字段，切换类型不丢内容）
  SyncBackendDraft get _draft => SyncBackendDraft(
        type: _type,
        localFsPath: _localFsPathCtrl.text,
        webdavUrl: _webdavUrlCtrl.text,
        webdavUsername: _webdavUsernameCtrl.text,
        webdavPassword: _webdavPasswordCtrl.text,
        safeServerUrl: _safeServerUrlCtrl.text,
        safeServerToken: _safeServerTokenCtrl.text,
      );

  /// 「不同步」不需要测试，其余类型必须字段齐全且已测试通过
  bool get _canSave {
    if (_type == SyncBackendType.none) return true;
    final draft = _draft;
    if (!draft.isComplete) return false;
    return draft.connectionSignature == _passedSignature;
  }

  bool get _canTest => _type != SyncBackendType.none && _draft.isComplete;

  /// 当前输入是否就是最近一次测试的那份配置
  bool get _hasFreshResult =>
      _resultSignature != null &&
      _resultSignature == _draft.connectionSignature;

  @override
  Widget build(BuildContext context) {
    // 与形态无关的表单内容：可滚动表单 + 底部操作栏。
    // 桌面端放进 Dialog、移动端放进 Scaffold，均由调用方包裹。
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            children: [
              _buildTypeSelector(),
              const SizedBox(height: 8),
              ..._buildTypeFields(),
            ],
          ),
        ),
        _buildBottomBar(),
      ],
    );
  }

  // ──────────────────────────────────────────────
  // 后端类型
  // ──────────────────────────────────────────────

  Widget _buildTypeSelector() {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          for (final type in SyncBackendType.values)
            ListTile(
              dense: true,
              enabled: !_testing,
              leading: Icon(
                _type == type
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: _type == type ? theme.colorScheme.primary : null,
              ),
              title: Text(_typeTitle(type)),
              subtitle: Text(
                _typeSubtitle(type),
                style: theme.textTheme.bodySmall,
              ),
              // 切换类型只改 _type，各类型输入框内容原样保留
              onTap: _testing ? null : () => setState(() => _type = type),
            ),
        ],
      ),
    );
  }

  String _typeTitle(SyncBackendType type) {
    switch (type) {
      case SyncBackendType.none:
        return 'No Sync'.tr();
      case SyncBackendType.localFs:
        return 'Local Folder'.tr();
      case SyncBackendType.webdav:
        return 'WebDAV';
      case SyncBackendType.safeServer:
        return 'SafeServer';
    }
  }

  String _typeSubtitle(SyncBackendType type) {
    switch (type) {
      case SyncBackendType.none:
        return 'Clears the backend selection; no sync with any remote.'.tr();
      case SyncBackendType.localFs:
        return 'Syncs to a local directory (testing / single device).'.tr();
      case SyncBackendType.webdav:
        return 'Nutstore / NextCloud / self-hosted'.tr();
      case SyncBackendType.safeServer:
        return 'Self-hosted lightweight sync service (HTTP API).'.tr();
    }
  }

  // ──────────────────────────────────────────────
  // 各类型的配置字段
  // ──────────────────────────────────────────────

  List<Widget> _buildTypeFields() {
    switch (_type) {
      case SyncBackendType.none:
        return [
          Padding(
            padding: EdgeInsets.only(top: 16),
            child: Text('Selected "No Sync"; saving will clear the backend selection.'.tr()),
          ),
        ];
      case SyncBackendType.localFs:
        return [
          _sectionTitle('Local Folder'.tr()),
          _textField(
            controller: _localFsPathCtrl,
            label: 'Sync Directory'.tr(),
            hint: 'e.g. D:\\SafeNotesSync',
            icon: Icons.folder_outlined,
            suffix: IconButton(
              icon: const Icon(Icons.folder_open),
              tooltip: 'Choose Directory'.tr(),
              onPressed: _testing ? null : _pickLocalFsPath,
            ),
          ),
        ];
      case SyncBackendType.webdav:
        return [
          _sectionTitle('WebDAV'),
          _textField(
            controller: _webdavUrlCtrl,
            label: 'Server Address'.tr(),
            hint: 'https://dav.jianguoyun.com/dav/',
            icon: Icons.link,
            keyboardType: TextInputType.url,
          ),
          _textField(
            controller: _webdavUsernameCtrl,
            label: 'Username'.tr(),
            hint: 'user@example.com',
            icon: Icons.person_outline,
          ),
          _textField(
            controller: _webdavPasswordCtrl,
            label: 'Password'.tr(),
            hint: 'App Password (not login password)'.tr(),
            icon: Icons.lock_outline,
            obscure: _obscureWebdavPassword,
            suffix: _obscureToggle(
              obscured: _obscureWebdavPassword,
              onPressed: () => setState(
                () => _obscureWebdavPassword = !_obscureWebdavPassword,
              ),
            ),
          ),
          _hint('The client automatically creates a safenotes-vault subdirectory under this address for sync data.'.tr()),
        ];
      case SyncBackendType.safeServer:
        return [
          _sectionTitle('SafeServer'),
          _textField(
            controller: _safeServerUrlCtrl,
            label: 'Server Address'.tr(),
            hint: 'http://192.168.1.118:2025',
            icon: Icons.dns_outlined,
            keyboardType: TextInputType.url,
          ),
          _textField(
            controller: _safeServerTokenCtrl,
            label: 'Token',
            hint: 'Fixed Bearer Token configured at deployment'.tr(),
            icon: Icons.key,
            obscure: _obscureSafeServerToken,
            suffix: _obscureToggle(
              obscured: _obscureSafeServerToken,
              onPressed: () => setState(
                () => _obscureSafeServerToken = !_obscureSafeServerToken,
              ),
            ),
          ),
        ];
    }
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 4),
        child: Text(
          text,
          style: Theme.of(context).textTheme.titleSmall,
        ),
      );

  Widget _hint(String text) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          text,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );

  Widget _obscureToggle({
    required bool obscured,
    required VoidCallback onPressed,
  }) =>
      IconButton(
        icon: Icon(obscured ? Icons.visibility_off : Icons.visibility),
        tooltip: obscured ? 'Show'.tr() : 'Hide'.tr(),
        onPressed: _testing ? null : onPressed,
      );

  Widget _textField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    bool obscure = false,
    Widget? suffix,
    TextInputType? keyboardType,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: TextField(
        controller: controller,
        enabled: !_testing,
        obscureText: obscure,
        keyboardType: keyboardType,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          prefixIcon: Icon(icon),
          suffixIcon: suffix,
          border: const OutlineInputBorder(),
        ),
        // 任何输入变化都要重算「能否保存」：指纹一变，上次测试结果即作废
        onChanged: (_) => setState(() {}),
      ),
    );
  }

  Future<void> _pickLocalFsPath() async {
    final path = await FilePicker.getDirectoryPath();
    if (path != null && mounted) {
      setState(() => _localFsPathCtrl.text = path);
    }
  }

  // ──────────────────────────────────────────────
  // 底部：测试结果 + 操作按钮
  // ──────────────────────────────────────────────

  Widget _buildBottomBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildResultBanner(),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: _testing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.network_check),
                    label: Text(_testing ? 'Testing...'.tr() : 'Test Connection'.tr()),
                    onPressed: (_testing || !_canTest) ? null : _runTest,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.save_outlined),
                    label: Text('Save'.tr()),
                    onPressed: (_testing || !_canSave) ? null : _save,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultBanner() {
    final theme = Theme.of(context);
    final String message;
    final Color color;
    final IconData icon;

    if (_testing) {
      message = 'Connecting to backend…'.tr();
      color = theme.colorScheme.onSurfaceVariant;
      icon = Icons.hourglass_empty;
    } else if (_type == SyncBackendType.none) {
      message = '"No Sync" does not require testing; you can save directly.'.tr();
      color = theme.colorScheme.onSurfaceVariant;
      icon = Icons.info_outline;
    } else if (!_draft.isComplete) {
      message = 'Please fill in all required fields.'.tr();
      color = theme.colorScheme.onSurfaceVariant;
      icon = Icons.edit_outlined;
    } else if (!_hasFreshResult) {
      message = 'Configuration has changed; test the connection before saving.'.tr();
      color = theme.colorScheme.onSurfaceVariant;
      icon = Icons.info_outline;
    } else if (_resultError == null) {
      message = 'Connection test passed; you can save.'.tr();
      color = Colors.green;
      icon = Icons.check_circle_outline;
    } else {
      message = 'Connection failed: {error}'.tr(
          namedArgs: {'error': _resultError ?? ''});
      color = theme.colorScheme.error;
      icon = Icons.error_outline;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _runTest() async {
    final draft = _draft;
    final signature = draft.connectionSignature;
    setState(() {
      _testing = true;
      _resultSignature = null;
      _resultError = null;
    });

    final result = await SyncService.instance.testBackendConfig(draft);

    if (!mounted) return;
    setState(() {
      _testing = false;
      _resultSignature = signature;
      _resultError = result.success ? null : (result.error ?? 'Unknown error'.tr());
      // 只有成功才记录「已通过」的指纹，保存按钮据此解锁
      if (result.success) _passedSignature = signature;
    });
  }

  void _save() {
    if (!_canSave) return;
    Navigator.of(context).pop(_draft.normalized());
  }
}
