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

// Package imports:
import 'package:media_scanner/media_scanner.dart';
import 'package:path_provider/path_provider.dart';

// Project imports:
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/file_handler.dart';

class ScheduledTask {
  static Future<void> backup() async {
    if (PreferencesStorage.isBackupOn == false ||
        PreferencesStorage.isBackupNeeded == false) {
      return;
    }

    int maxAttempt = PreferencesStorage.maxBackupRetryAttempts;
    for (var attempt = 1; attempt <= maxAttempt; attempt++) {
      if (await unitBackupAttempt() == true) break;
    }
  }

  static Future<bool> unitBackupAttempt() async {
    if (Platform.isAndroid) {
      return androidBackup();
    } else if (Platform.isIOS) {
      return iosBackup();
    }
    return true;
  }

  /// 上一次备份失败时的简要错误信息，供调用方（如改密码前置检查）展示。
  static String? lastBackupError;

  // return true on successful backup
  static Future<bool> androidBackup() async {
    try {
      final String chosenDirectory = SafeNotesConfig.androidBackupDirectory;
      final String jsonOutputContent =
          await FileHandler.encryptedOutputBackupContent();
      final String fileName = SafeNotesConfig.backupFileName;

      lastBackupError = null;
      bool wrote = false;

      // 1) 尝试写入用户设置/默认的备份目录
      //    （Android 分区存储下该目录可能无直接写入权限，会抛 FileSystemException）
      if (chosenDirectory.isNotEmpty) {
        try {
          final jsonFile = File('$chosenDirectory/$fileName');
          jsonFile.writeAsStringSync(jsonOutputContent, mode: FileMode.write);
          MediaScanner.loadMedia(path: jsonFile.path);
          wrote = true;
        } on FileSystemException {
          // 目录不可用（权限不足/不存在）：记录失败原因，随后回退到私有目录
          lastBackupError =
              '默认备份目录不可用（权限不足或目录不存在），已回退到应用私有目录。';
        }
      }

      // 2) 所选目录不可用时，回退到应用私有目录（始终可写，无需外部存储权限）
      if (!wrote) {
        final dir = await getApplicationDocumentsDirectory();
        final jsonFile = File('${dir.path}/$fileName');
        jsonFile.writeAsStringSync(jsonOutputContent, mode: FileMode.write);
        wrote = true;
      }

      await PreferencesStorage.setLastBackupTime();
      await PreferencesStorage.setIsBackupNeeded(false);
      return true;
    } catch (err) {
      lastBackupError = _simplifyBackupError(err);
      return false;
    }
  }

  /// 把备份异常转成一句简明中文提示，便于在 UI 上展示。
  static String _simplifyBackupError(Object err) {
    if (err is FileSystemException) {
      final code = err.osError?.errorCode;
      if (code == 13 || code == 17) {
        return '无法写入备份文件：权限不足或文件被占用。';
      }
      return '无法写入备份文件：${err.message}';
    }
    return '备份失败：${err.toString()}';
  }

  static Future<bool> iosBackup() async {
    final Directory downloadsDir = await getApplicationDocumentsDirectory();

    String? validChosenDirectory = downloadsDir.path;

    if (validChosenDirectory.isNotEmpty) {
      String jsonOutputContent =
          await FileHandler.encryptedOutputBackupContent();
      final String fileName = SafeNotesConfig.backupFileName;
      final jsonFile = File('$validChosenDirectory/$fileName');

      jsonFile.writeAsStringSync(jsonOutputContent);

      await PreferencesStorage.setLastBackupTime();
      await PreferencesStorage.setIsBackupNeeded(false);
    }
    return true;
  }

  /// 强制备份一次（绕过 isBackupOn / isBackupNeeded 开关）
  ///
  /// 用于改密码等关键操作前的数据保护：
  ///   - 无论用户是否开启自动备份，都强制写入一份本地完整备份
  ///   - 失败会重试 maxBackupRetryAttempts 次
  ///
  /// 返回 true 表示备份成功，false 表示失败（调用方可据此决定是否继续操作）。
  static Future<bool> forceBackup() async {
    int maxAttempt = PreferencesStorage.maxBackupRetryAttempts;
    for (var attempt = 1; attempt <= maxAttempt; attempt++) {
      if (await unitBackupAttempt() == true) return true;
    }
    return false;
  }
}
