/*
* Copyright (C) Keshav Priyadarshi and others - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*
* See https://safenotes.dev for support or download.
*/

import 'dart:io';

import 'package:flutter/material.dart';

import 'package:core/core.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/dialogs/backup_import.dart';
import 'package:safenotes/dialogs/export_backup_dialog.dart';
import 'package:safenotes/models/file_handler.dart';
import 'package:safenotes/utils/platform_ui.dart';
import 'package:safenotes/utils/scheduled_task.dart';
import 'package:safenotes/utils/snack_message.dart';
import 'package:safenotes/utils/storage_permission.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/utils/text_styles.dart';
import 'package:safenotes/utils/time_utils.dart';
import 'package:safenotes/widgets/shad_settings_tiles.dart';

class BackupSetting extends StatefulWidget {
  const BackupSetting({super.key});

  @override
  State<BackupSetting> createState() => BackupSettingState();
}

class BackupSettingState extends State<BackupSetting> {
  String validWorkingBackupFullyQualifiedPath = '';
  String validWorkingBackupDirectory = '';
  String lastUpdateTime = '';
  bool isBackupOn = false;

  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _refresh();
  }

  Future<void> _refresh() async {
    PreferencesStorage.reload();

    String path = await getBackupIndicativePath();
    final dir = path.isEmpty ? '' : File(path).parent.path;

    setState(() {
      validWorkingBackupFullyQualifiedPath = path;
      validWorkingBackupDirectory = dir;
      isBackupOn = PreferencesStorage.isBackupOn;
      refreshUpdateTime();
    });
  }

  /// 备份「指示路径」：始终返回该平台备份文件的最终落盘位置（可能与命名一致）
  ///
  /// 统一从 [ScheduledTask.resolveBackupDirectory] 取目录（用户自定义路径优先，
  /// 否则回退平台默认目录），与 androidBackup/iosBackup/desktopBackup 落盘位置
  /// 完全一致，避免「UI 显示路径」与「真实落盘路径」再次错位。
  /// 不再要求「必须有历史备份」才显示路径（否则出现先备份才能点「立即备份」的
  /// 死锁，原本桌面端从未返回路径，按钮永远灰置、位置空白）。
  Future<String> getBackupIndicativePath() async {
    final dir = await ScheduledTask.resolveBackupDirectory();
    if (dir.isEmpty) return '';
    return p.join(dir, SafeNotesConfig.backupFileName);
  }

  void refreshUpdateTime() {
    Locale currentLocale = Localizations.localeOf(context);
    String lastBackupTime = PreferencesStorage.lastBackupTime;

    lastBackupTime = lastBackupTime.isEmpty
        ? 'Never'.tr()
        : humanTime(
            time: DateTime.parse(lastBackupTime),
            localeString: currentLocale.toString(),
          );

    lastUpdateTime = lastBackupTime;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Backup'.tr(), style: appBarTitle)),
      body: _bodyBackup(context),
    );
  }

  Widget _bodyBackup(BuildContext context) {
    final String dir = validWorkingBackupDirectory;
    final bool canOpen = dir.isNotEmpty;

    return shadSettingsList([
      shadSettingsCard([
        shadSwitchTile(
          context,
          icon: LucideIcons.cloud,
          title: 'Auto Backup'.tr(),
          description: 'AppBackupDescription'.tr(),
          value: isBackupOn,
          onChanged: (value) async {
            await PreferencesStorage.setIsBackupOn(value);
            if (value == true) {
              await onBackupNow();
            }
            setState(() => isBackupOn = value);
          },
        ),
      ]),
      shadSectionTitle(context, 'Backup'.tr()),
      shadSettingsCard([
        shadInfoTile(
          context,
          icon: LucideIcons.history,
          title: 'Last Backup'.tr(),
          value: lastUpdateTime.isEmpty ? 'Never synced'.tr() : lastUpdateTime,
        ),
        shadNavigationTile(
          context,
          icon: LucideIcons.folderOpen,
          title: 'Location'.tr(),
          subtitle: dir.isEmpty ? '—' : dir,
          onTap: canOpen ? () => _openBackupDirectory() : () {},
        ),
        shadNavigationTile(
          context,
          icon: LucideIcons.folderInput,
          title: 'Change location'.tr(),
          onTap: () => _pickBackupLocation(),
        ),
        shadNavigationTile(
          context,
          icon: LucideIcons.cloudUpload,
          title: 'Backup Now'.tr(),
          onTap: () => onBackupNow(),
        ),
        _encryptedBadge(),
      ]),
      shadSectionTitle(context, 'Transfer'.tr()),
      shadSettingsCard([
        shadNavigationTile(
          context,
          key: const Key('ui-setting-item-exportbackup'),
          icon: LucideIcons.fileOutput,
          title: 'Export Backup'.tr(),
          onTap: () => startExportNotes(context),
        ),
        shadNavigationTile(
          context,
          key: const Key('ui-setting-item-importbackup'),
          icon: LucideIcons.download,
          title: 'Import Backup'.tr(),
          onTap: () async {
            await showImportDialog(context);
          },
        ),
      ]),
      const SizedBox(height: 12),
    ]);
  }

  Widget _encryptedBadge() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      child: Row(
        children: [
          const Icon(LucideIcons.lock, size: 15, color: Colors.green),
          const SizedBox(width: 6),
          Text(
            'Backup encrypted'.tr(),
            style: const TextStyle(fontSize: AppTextSize.s12),
          ),
        ],
      ),
    );
  }

  Future<void> _openBackupDirectory() async {
    final dir = validWorkingBackupDirectory;
    if (dir.isEmpty) return;
    await openBackupDirectory(dir, context);
  }

  /// 选择备份路径（目录选择器），结果持久化记住（SharedPreferences）
  ///
  /// - 桌面 / Android：FilePicker.getDirectoryPath 原生目录选择
  /// - iOS：系统无目录选择器，备份位置固定在应用 Documents，仅提示
  Future<void> _pickBackupLocation() async {
    if (isIOS) {
      showSnackBarMessage(context, 'iOS backup location is fixed'.tr());
      return;
    }
    try {
      final dir = await FilePicker.getDirectoryPath(
        dialogTitle: 'Select backup folder'.tr(),
        initialDirectory: validWorkingBackupDirectory.isNotEmpty
            ? validWorkingBackupDirectory
            : null,
      );
      if (dir != null && dir.isNotEmpty) {
        await PreferencesStorage.setBackupDirectory(dir);
        Log.backup.i('用户选择备份目录: $dir');
        if (!mounted) return;
        showSnackBarMessage(context, 'Backup location updated'.tr());
        await _refresh();
      }
    } catch (e, st) {
      Log.backup.e('选择备份目录失败', error: e, stackTrace: st);
      if (!mounted) return;
      showErrorToast(context, 'Failed to select folder'.tr());
    }
  }

  Future<void> onBackupNow() async {
    // 用户主动点击「立即备份」，是数据安全的关键人工动作，需明确留痕
    Log.backup.i('用户触发手动备份 (isBackupOn=$isBackupOn)');
    if (isAndroid) {
      final granted = await handleBackupPermissionAndLocation();
      if (!granted) {
        if (!mounted) return;
        showErrorToast(context, 'Storage permission required!'.tr());
        return;
      }
    }
    // 手动备份必须真正落盘，绕过 isBackupOn/isBackupNeeded 开关：
    // 否则首次成功后备 isBackupNeeded 置 false，「再次点击立即备份」会静默跳过。
    final manualFileName = SafeNotesConfig.manualBackupFileName;
    final success = await ScheduledTask.forceBackup(fileName: manualFileName);
    if (!mounted) return;
    if (success) {
      final dir = await ScheduledTask.resolveBackupDirectory();
      if (!mounted) return;
      final actualPath = dir.isEmpty ? '' : p.join(dir, manualFileName);
      showSnackBarMessage(
        context,
        'Backup written to: {path}'.tr(namedArgs: {'path': actualPath}),
      );
      Log.backup.i('手动备份成功: $actualPath');
    } else {
      final err = ScheduledTask.lastBackupError ?? 'Unknown error';
      showErrorToast(
        context,
        'Backup failed: {err}'.tr(namedArgs: {'err': err}),
      );
      Log.backup.e('手动备份失败: $err');
    }
    await _refresh();
  }
}

/// 统一的导出入口：打开导出面板、写文件并提示结果。
/// 供备份设置页与设置主页「导出备份」共用。
Future<void> startExportNotes(BuildContext context) async {
  Log.backup.i('用户触发手动导出（打开导出面板）');
  final options = await ExportBackupDialog.show(context);
  if (!context.mounted) return;
  if (options == null) {
    Log.backup.i('导出取消：用户在导出面板放弃');
    return;
  }
  try {
    final String content;
    if (options.encrypted) {
      final password = options.password;
      if (password == null || password.isEmpty) {
        showErrorToast(context, 'Export requires a password!'.tr());
        return;
      }
      content = await FileHandler.encryptedOutputBackupContent(
        password: password,
      );
    } else {
      content = await FileHandler.plainOutputBackupContent();
    }
    await FileHandler.writeBackupFile(
      content: content,
      filePath: options.filePath,
    );
    if (!context.mounted) return;
    Log.backup.i('导出完成: ${options.filePath}');
    showSnackBarMessage(
      context,
      'Backup exported to: {path}'.tr(namedArgs: {'path': options.filePath}),
    );
  } catch (e, st) {
    if (!context.mounted) return;
    Log.backup.e('导出失败', error: e, stackTrace: st);
    showErrorToast(context, "Failed to export file!".tr());
  }
}

/// 打开备份目录（移动 / 桌面通用）
///
/// - 桌面（Windows/Linux/macOS）：launchUrl(file://) 用系统文件管理器打开目录
/// - iOS：shareddocuments:// 跳转到应用 Documents
/// - Android：先尝试 file:// URI，再试 SAF content:// URI，失败则显示路径
Future<void> openBackupDirectory(String directory, BuildContext context) async {
  try {
    if (isIOS) {
      await launchUrl(Uri.parse('shareddocuments://$directory'));
      return;
    }
    // Android / 桌面：优先尝试 file:// URI
    final uri = Uri.directory(directory);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return;
    }
    // Android：尝试 SAF DocumentsProvider URI
    if (isAndroid) {
      try {
        final encoded = directory.replaceAll('/', '%2F');
        final safUri = Uri.parse(
          'content://com.android.externalstorage.documents/tree/primary%3A$encoded',
        );
        if (await canLaunchUrl(safUri)) {
          await launchUrl(safUri, mode: LaunchMode.externalApplication);
          return;
        }
      } catch (_) {
        // SAF URI 失败，静默降级
      }
    }
    // 全失败：显示路径让用户手动导航
    if (context.mounted) {
      showSnackBarMessage(
        context,
        'Backup folder: {path}'.tr(namedArgs: {'path': directory}),
      );
    }
  } catch (e, st) {
    Log.backup.e('打开备份目录失败: $directory', error: e, stackTrace: st);
    if (context.mounted) {
      showErrorToast(context, 'Could not open folder'.tr());
    }
  }
}

Future<bool> handleBackupPermissionAndLocation() async {
  if (!await handleStoragePermission()) return false;

  // If the download directory doesn't exists return false
  if (!await Directory(SafeNotesConfig.androidDownloadDirectory).exists()) {
    return false;
  }
  await Directory(
    SafeNotesConfig.androidBackupDirectory,
  ).create(recursive: false);

  return true;
}
