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

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:settings_ui/settings_ui.dart';
import 'package:safenotes/utils/settings_platform.dart';
import 'package:url_launcher/url_launcher.dart';

// Project imports:
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/dialogs/export_backup_dialog.dart';
import 'package:safenotes/models/file_handler.dart';
import 'package:core/core.dart';
import 'package:safenotes/utils/scheduled_task.dart';
import 'package:safenotes/utils/snack_message.dart';
import 'package:safenotes/utils/storage_permission.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/utils/time_utils.dart';

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
    final String path = validWorkingBackupFullyQualifiedPath;
    final bool canOpen = validWorkingBackupDirectory.isNotEmpty;

    return SettingsList(
      platform: currentDevicePlatform,
      lightTheme: appSettingsTheme(context),
      darkTheme: appSettingsTheme(context),
      sections: [
        SettingsSection(
          tiles: [
            SettingsTile.switchTile(
              initialValue: PreferencesStorage.isBackupOn,
              title: Text('Auto Backup'.tr()),
              description: Text(
                'This will create an encrypted local backup, which gets automatically updated every day. Moreover, the backup is designed such that it can be used in tandem with other open-source tools like SyncThing to keep the multiple redundant backups across different devices on the local network.\nTo switch to a new device, you would simply need to copy this backup file to the new device and import that in your new Safe Notes app.\nFor more, see FAQ.'
                    .tr(),
              ),
              onToggle: (value) async {
                await PreferencesStorage.setIsBackupOn(value);
                if (value == true) {
                  await onBackupNow();
                }
                setState(() => isBackupOn = value);
              },
            ),
          ],
        ),
        SettingsSection(
          title: Text('Backup'.tr()),
          tiles: [
            SettingsTile(
              leading: const Icon(Icons.history),
              title: Text('Last Backup'.tr()),
              value: Text(
                lastUpdateTime.isEmpty ? 'Never synced'.tr() : lastUpdateTime,
              ),
              description: _encrypted(),
            ),
            SettingsTile.navigation(
              leading: const Icon(Icons.folder_outlined),
              title: Text('Location'.tr()),
              value: Text(
                path.isEmpty ? '—' : path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onPressed: canOpen ? (_) => _openBackupDirectory() : null,
            ),
            SettingsTile.navigation(
              leading: const Icon(Icons.edit_location_alt_outlined),
              title: Text('Change location'.tr()),
              onPressed: (_) => _pickBackupLocation(),
            ),
            SettingsTile.navigation(
              leading: const Icon(Icons.backup_outlined),
              title: Text('Backup Now'.tr()),
              onPressed: path.isNotEmpty ? (_) => onBackupNow() : null,
            ),
          ],
        ),
        SettingsSection(
          title: Text('Export'.tr()),
          tiles: [
            SettingsTile.navigation(
              leading: const Icon(Icons.ios_share),
              title: Text('Export Backup'.tr()),
              description: Text(
                'Choose to export encrypted (.snbak) or plain text (.json). Encrypted export protects notes with a password; plain export is NOT encrypted, keep it safe.'
                    .tr(),
              ),
              onPressed: (_) => _onExportNotes(),
            ),
          ],
        ),
      ],
    );
  }

  Widget _encrypted() {
    return Row(
      children: [
        const Icon(Icons.lock, size: 15, color: Colors.green),
        const SizedBox(width: 1),
        Text('Backup encrypted'.tr(), style: const TextStyle(fontSize: 10)),
      ],
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
    if (Platform.isIOS) {
      showSnackBarMessage(context, 'iOS backup location is fixed'.tr());
      return;
    }
    try {
      final dir = await FilePicker.getDirectoryPath(
        dialogTitle: 'Select backup folder'.tr(),
        initialDirectory:
            validWorkingBackupDirectory.isNotEmpty ? validWorkingBackupDirectory : null,
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
      showSnackBarMessage(context, 'Failed to select folder'.tr());
    }
  }

  Future<void> _onExportNotes() async {
    Log.backup.i('用户触发手动导出（打开导出面板）');
    final options = await ExportBackupDialog.show(context);
    if (!mounted) return;
    if (options == null) {
      Log.backup.i('导出取消：用户在导出面板放弃');
      return;
    }
    try {
      final String content;
      if (options.encrypted) {
        final password = options.password;
        if (password == null || password.isEmpty) {
          showSnackBarMessage(context, 'Export requires a password!'.tr());
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
      if (!mounted) return;
      Log.backup.i('导出完成: ${options.filePath}');
      showSnackBarMessage(
        context,
        'Backup exported to: {path}'.tr(namedArgs: {'path': options.filePath}),
      );
    } catch (e, st) {
      if (!mounted) return;
      Log.backup.e('导出失败', error: e, stackTrace: st);
      showSnackBarMessage(context, "Failed to export file!".tr());
    }
  }

  Future<void> onBackupNow() async {
    // 用户主动点击「立即备份」，是数据安全的关键人工动作，需明确留痕
    Log.backup.i('用户触发手动备份 (isBackupOn=$isBackupOn)');
    if (Platform.isAndroid) {
      final granted = await handleBackupPermissionAndLocation();
      if (!granted) {
        if (!mounted) return;
        showSnackBarMessage(context, 'Storage permission required!'.tr());
        return;
      }
    }
    // 手动备份必须真正落盘，绕过 isBackupOn/isBackupNeeded 开关：
    // 否则首次成功后备 isBackupNeeded 置 false，「再次点击立即备份」会静默跳过。
    final success = await ScheduledTask.forceBackup();
    if (!mounted) return;
    if (success) {
      showSnackBarMessage(
        context,
        'Backup written to: {path}'.tr(
          namedArgs: {'path': validWorkingBackupFullyQualifiedPath},
        ),
      );
      Log.backup.i('手动备份成功: $validWorkingBackupFullyQualifiedPath');
    } else {
      final err = ScheduledTask.lastBackupError ?? 'Unknown error';
      showSnackBarMessage(
        context,
        'Backup failed: {err}'.tr(namedArgs: {'err': err}),
      );
      Log.backup.e('手动备份失败: $err');
    }
    await _refresh();
  }
}

/// 打开备份目录（移动 / 桌面通用）
///
/// - 桌面（Windows/Linux/macOS）：launchUrl(file://) 用系统文件管理器打开目录
/// - iOS：shareddocuments:// 跳转到应用 Documents
/// - Android：尽力而为（file:// 受限于系统安全策略，失败仅提示路径）
Future<void> openBackupDirectory(String directory, BuildContext context) async {
  try {
    if (Platform.isIOS) {
      await launchUrl(Uri.parse('shareddocuments://$directory'));
      return;
    }
    final uri = Uri.directory(directory);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (context.mounted) {
      showSnackBarMessage(context, 'Could not open folder'.tr());
    }
  } catch (e, st) {
    Log.backup.e('打开备份目录失败: $directory', error: e, stackTrace: st);
    if (context.mounted) {
      showSnackBarMessage(context, 'Could not open folder'.tr());
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
