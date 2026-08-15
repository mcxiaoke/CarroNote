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
import 'dart:math' as math;

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart';

// Project imports:
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/file_handler.dart';
import 'package:safenotes/utils/platform_ui.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/widgets/shad_dialog.dart';

/// 导出面板返回的选项（docs/backup-encryption-design-20260810.md §6）
class ExportOptions {
  /// true=加密导出（snbak，需密码）；false=明文导出（json）
  final bool encrypted;

  /// 加密导出时用于派生 B-KEY 的口令（登录口令原文或用户自定义）
  final String? password;

  /// 目标落盘完整路径（含文件名）
  final String filePath;

  const ExportOptions({
    required this.encrypted,
    required this.filePath,
    this.password,
  });
}

/// 导出备份面板：明文/加密二选一 + 密码确认 + 路径选择
///
/// 支持平台：
///   - 桌面（Windows/Linux/macOS）：原生「另存为」对话框（saveFile）
///   - Android：系统目录选择器（getDirectoryPath），文件名自动生成
///   - iOS：落应用文档目录（系统无目录选择器）
/// 返回 [ExportOptions]；用户取消返回 null。
class ExportBackupDialog extends StatefulWidget {
  const ExportBackupDialog({super.key});

  /// 打开导出面板；返回值见 [ExportOptions]
  ///
  /// 与同步配置一致：桌面端居中弹框，移动端全屏对话框（fullscreenDialog）。
  static Future<ExportOptions?> show(BuildContext context) {
    if (isDesktopPlatform) {
      return showDialog<ExportOptions>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const ExportBackupDialog(),
      );
    }
    return Navigator.of(context).push<ExportOptions>(
      MaterialPageRoute<ExportOptions>(
        fullscreenDialog: true,
        builder: (_) => const ExportBackupDialog(),
      ),
    );
  }

  @override
  ExportBackupDialogState createState() => ExportBackupDialogState();
}

class ExportBackupDialogState extends State<ExportBackupDialog> {
  bool _encrypted = true;
  bool _hidden = true;
  final TextEditingController _passwordCtrl = TextEditingController();
  final TextEditingController _confirmCtrl = TextEditingController();

  /// 格式单选的控制器：手动提供 [ShadProvider]，用 Column 布局让每个
  /// [ShadRadio] 撑满卡片宽度（原生 ShadRadioGroup 的 Wrap 不撑满）。
  late final ShadRadioController<bool> _formatCtrl;

  /// 平台默认备份目录（异步加载后展示「默认位置」）
  String? _defaultDir;

  /// 桌面端 saveFile 选择的完整路径（null = 未选择）
  String? _desktopPath;

  /// Android 目录选择器选择的目录（null = 未选择）
  String? _androidDir;

  @override
  void initState() {
    super.initState();
    // 导出是低频操作：密码必须由用户主动输入，不预填内存中的 app 会话密码
    // （此前把 PhraseHandler.getPass 静默填进密码框，导出的加密备份实际
    // 用了 app 登录密码，属于隐私隐患）。密码框留空，用户输入后才可导出。
    _loadDefaultDir();
    _formatCtrl = ShadRadioController<bool>(value: _encrypted)
      ..addListener(_onFormatChanged);
  }

  void _onFormatChanged() {
    setState(() => _encrypted = _formatCtrl.value ?? true);
  }

  @override
  void dispose() {
    _formatCtrl.removeListener(_onFormatChanged);
    _formatCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadDefaultDir() async {
    try {
      final dir = await FileHandler.defaultBackupDirectory();
      if (mounted && dir.isNotEmpty) {
        setState(() => _defaultDir = dir);
      }
    } catch (_) {
      // 目录获取失败不阻断导出面板：用户可直接「浏览」选路径，或走默认命名
    }
  }

  String get _fileName =>
      SafeNotesConfig.exportFileNameFor(encrypted: _encrypted);

  String get _locationPath {
    if (isDesktopPlatform && _desktopPath != null) return _desktopPath!;
    final dir = _androidDir ?? _defaultDir ?? '';
    return dir.isEmpty ? _fileName : p.join(dir, _fileName);
  }

  bool get _passwordValid {
    final p = _passwordCtrl.text;
    return p.isNotEmpty && p == _confirmCtrl.text;
  }

  Future<void> _pickLocation() async {
    if (isDesktopPlatform) {
      // 桌面端：原生「另存为」，用户决定文件名与位置
      final path = await FilePicker.saveFile(
        dialogTitle: 'Save backup'.tr(),
        fileName: _fileName,
        initialDirectory: _defaultDir,
        type: FileType.any,
      );
      if (path != null && path.isNotEmpty && mounted) {
        setState(() => _desktopPath = path);
      }
    } else if (isAndroid) {
      // Android：选目录，文件名由应用生成
      final dir = await FilePicker.getDirectoryPath(
        dialogTitle: 'Select backup folder'.tr(),
        initialDirectory: _androidDir ?? _defaultDir,
      );
      if (dir != null && dir.isNotEmpty && mounted) {
        setState(() => _androidDir = dir);
      }
    }
    // iOS：无目录选择器，落应用文档目录（默认路径展示即可）
  }

  void _onSubmit() {
    final String filePath;
    if (isDesktopPlatform && _desktopPath != null) {
      filePath = _desktopPath!;
    } else {
      final dir = _androidDir ?? _defaultDir ?? '';
      filePath = dir.isEmpty ? _fileName : p.join(dir, _fileName);
    }
    Navigator.of(context).pop(
      ExportOptions(
        encrypted: _encrypted,
        password: _encrypted ? _passwordCtrl.text : null,
        filePath: filePath,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget content = SizedBox(
      // 宽度自适应：桌面固定、移动占满屏宽；统一按屏宽收窄，
      // 桌面窗口 resize 到更窄时同样收窄，避免横向溢出
      width: math.min(
        kDialogMaxWidthWide,
        MediaQuery.of(context).size.width - 32,
      ),
      // 内容加滚动：避免小窗口/低分辨率下 Column 底部溢出
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildFormatSelector(),
            const SizedBox(height: 12),
            // 用固定最小高度占位（而非 Visibility），切换明文/加密时对话框
            // 高度恒定、不上下跳动；同时避免 Visibility(maintainSize) 在
            // 隐藏测量时把子项以无限宽布局导致的崩溃。
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 122),
              child: _encrypted
                  ? _buildPasswordFields()
                  : _buildPlaintextNotice(),
            ),
            const SizedBox(height: 12),
            _buildLocationRow(),
          ],
        ),
      ),
    );

    final Widget actionBar = shadDialogActionBar(
      actions: [
        ShadDialogAction(
          label: 'Cancel'.tr(),
          onPressed: () => Navigator.of(context).pop(),
        ),
        ShadDialogAction(
          label: 'Export'.tr(),
          primary: true,
          enabled: !(_encrypted && !_passwordValid),
          onPressed: _onSubmit,
        ),
      ],
    );

    // 移动端：全屏对话框，与同步配置一致
    if (!isDesktopPlatform) {
      return Scaffold(
        backgroundColor: ShadTheme.of(context).colorScheme.background,
        appBar: AppBar(title: Text('Export Backup'.tr(), style: appBarTitle)),
        body: SafeArea(
          bottom: false,
          child: Padding(
            // 全屏页无 ShadDialog 自带内边距，需手动留边距，
            // 避免文字/输入框贴屏幕边缘。
            padding: const EdgeInsets.all(16),
            child: content,
          ),
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: actionBar,
          ),
        ),
      );
    }

    // 桌面端：居中弹框（宽面板，与同步配置同 560 限宽）
    return ShadDialog(
      constraints: const BoxConstraints(maxWidth: kDialogMaxWidthWide),
      title: Text('Export Backup'.tr()),
      // 关闭小屏断点下的按钮全宽覆盖（width: double.infinity），避免按钮
      // minWidth: Infinity 在内在测量时崩溃（BoxConstraints forces an
      // infinite width）。
      expandActionsWhenTiny: false,
      actions: [actionBar],
      child: content,
    );
  }

  Widget _buildFormatSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Format'.tr(), style: dialogBodyTextStyle),
        const SizedBox(height: 6),
        ShadCard(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: ShadProvider(
            data: _formatCtrl as ShadRadioController<dynamic>,
            child: Column(
              children: [
                _formatRadio(
                  value: true,
                  title: 'Encrypted (.snbak) (Recommended)'.tr(),
                  subtitle: 'Encrypted with a password, safe to store or share.'
                      .tr(),
                ),
                _formatRadio(
                  value: false,
                  title: 'Plain text (.json)'.tr(),
                  subtitle: 'Not encrypted; anyone with the file can read it.'
                      .tr(),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 单个格式选项：原生 [ShadRadio]（圆点 + 两行文字垂直居中）。
  ///
  /// ShadRadio 默认 `radioPadding` 顶部 +1，视觉上圆点略高，显式归零让
  /// 圆点与文字严格垂直居中（替代旧的自绘圆点方案）。
  ///
  /// 外层 [SizedBox] 撑满卡片宽度：这里用的是 [Column] 而非 ShadRadioGroup
  /// 的 Wrap，因此 `double.infinity` 可安全使用。
  Widget _formatRadio({
    required bool value,
    required String title,
    required String subtitle,
  }) {
    final theme = ShadTheme.of(context);
    return SizedBox(
      width: double.infinity,
      child: ShadRadio<bool>(
        value: value,
        radioPadding: EdgeInsets.zero,
        label: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.p),
            Text(subtitle, style: theme.textTheme.muted.copyWith(fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _buildPasswordFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Password'.tr(), style: dialogBodyTextStyle),
        const SizedBox(height: 6),
        ShadInput(
          controller: _passwordCtrl,
          obscureText: _hidden,
          enableIMEPersonalizedLearning: false,
          onChanged: (_) => setState(() {}),
          placeholder: Text('Encryption Phrase'.tr()),
          padding: kInputPadding,
          leading: const Icon(Icons.lock, size: kInputIconSize),
          trailing: kInputIconButton(
            icon: Icon(
              _hidden ? Icons.visibility : Icons.visibility_off,
              size: kInputIconSize,
            ),
            onPressed: () => setState(() => _hidden = !_hidden),
          ),
        ),
        const SizedBox(height: 8),
        ShadInput(
          controller: _confirmCtrl,
          obscureText: _hidden,
          enableIMEPersonalizedLearning: false,
          onChanged: (_) => setState(() {}),
          placeholder: Text('Confirm password'.tr()),
          padding: kInputPadding,
          leading: const Icon(Icons.lock_outline, size: kInputIconSize),
        ),
        if (_passwordCtrl.text.isNotEmpty &&
            _passwordCtrl.text != _confirmCtrl.text)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Passwords do not match'.tr(),
              style: TextStyle(
                color: ShadTheme.of(context).colorScheme.destructive,
                fontSize: 12,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildPlaintextNotice() {
    return Text(
      'Plain-export warning: the file is NOT encrypted. Keep it in a '
              'safe place.'
          .tr(),
      style: TextStyle(
        fontSize: 12,
        color: ShadTheme.of(context).colorScheme.destructive,
      ),
    );
  }

  Widget _buildLocationRow() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Location'.tr(), style: dialogBodyTextStyle),
        const SizedBox(height: 6),
        Row(
          children: [
            Flexible(
              // 用 maxWidth 夹住宽度：Row 在做内在宽度测量时会对 Flexible 子项
              // 传 width=Infinity，而 ShadInput 内部 ConstrainedBox 拿到无限宽会
              // 崩溃（Android 上尤为明显）。这里限定最大宽度，避免无限宽透传。
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: kInputMaxWidthInRow,
                ),
                child: ShadInputFormField(
                  key: ValueKey(_locationPath),
                  initialValue: _locationPath,
                  readOnly: true,
                  padding: kInputPadding,
                  leading: const Icon(LucideIcons.folder, size: kInputIconSize),
                ),
              ),
            ),
            const SizedBox(width: 8),
            ShadButton.outline(
              onPressed: _pickLocation,
              leading: const Icon(LucideIcons.folderOpen, size: kInputIconSize),
              child: Text('Browse'.tr()),
            ),
          ],
        ),
      ],
    );
  }
}
