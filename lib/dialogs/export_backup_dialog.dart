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
import 'dart:io';
import 'dart:ui' show ImageFilter;

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

// Project imports:
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/file_handler.dart';
import 'package:safenotes/utils/platform_ui.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
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
  static Future<ExportOptions?> show(BuildContext context) {
    return showDialog<ExportOptions>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const ExportBackupDialog(),
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
  }

  @override
  void dispose() {
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
    } else if (Platform.isAndroid) {
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
    const double radius = 10.0;

    return BackdropFilter(
      filter: ImageFilter.blur(),
      child: Dialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
        ),
        child: SizedBox(
          width: 420,
          child: Padding(
            padding: const EdgeInsets.all(20),
            // 内容加滚动：避免小窗口/低分辨率下 Column 底部溢出
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Export Backup'.tr(), style: dialogHeadTextStyle),
                  const SizedBox(height: 16),
                  _buildFormatSelector(),
                  const SizedBox(height: 12),
                  if (_encrypted) _buildPasswordFields(),
                  if (!_encrypted) _buildPlaintextNotice(),
                  const SizedBox(height: 12),
                  _buildLocationRow(),
                  const SizedBox(height: 16),
                  shadDialogActionBar(
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
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFormatSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Format'.tr(), style: dialogBodyTextStyle),
        const SizedBox(height: 6),
        ShadRadioGroup<String>(
          initialValue: _encrypted ? 'encrypted' : 'plaintext',
          onChanged: (value) {
            if (value == null) return;
            setState(() => _encrypted = value == 'encrypted');
          },
          items: [
            ShadRadio<String>(
              value: 'encrypted',
              label: Text('Encrypted (.snbak) (Recommended)'.tr()),
              sublabel: Text(
                'Encrypted with a password, safe to store or share.'.tr(),
                style: const TextStyle(fontSize: 12),
              ),
            ),
            ShadRadio<String>(
              value: 'plaintext',
              label: Text('Plain text (.json)'.tr()),
              sublabel: Text(
                'Not encrypted; anyone with the file can read it.'.tr(),
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      ],
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
          leading: const Icon(Icons.lock),
          trailing: IconButton(
            icon: Icon(
              _hidden ? Icons.visibility : Icons.visibility_off,
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
          leading: const Icon(Icons.lock_outline),
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
      'safe place.'.tr(),
      style: TextStyle(
        fontSize: 13,
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
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).dividerColor),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  _locationPath,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: _pickLocation,
              icon: const Icon(Icons.folder_open, size: 18),
              label: Text('Browse'.tr()),
            ),
          ],
        ),
      ],
    );
  }
}