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
import 'package:core/core.dart';

class ScheduledTask {
  static Future<void> backup() async {
    // 记录触发条件：便于排查「为什么这次没有产生备份文件」
    if (PreferencesStorage.isBackupOn == false ||
        PreferencesStorage.isBackupNeeded == false) {
      Log.backup.d('跳过自动备份: 开关 isBackupOn='
          '${PreferencesStorage.isBackupOn}, '
          '待备份 isBackupNeeded=${PreferencesStorage.isBackupNeeded}');
      return;
    }

    int maxAttempt = PreferencesStorage.maxBackupRetryAttempts;
    Log.backup.i('开始自动备份 平台=${Platform.operatingSystem} '
        '最大重试=$maxAttempt 上次备份=${PreferencesStorage.lastBackupTime}');
    final startedAt = DateTime.now();

    for (var attempt = 1; attempt <= maxAttempt; attempt++) {
      // 评审 #11：防止备份失败把重试循环拖成无界阻塞（Session.logout 会 await
      // 本方法）。超过总超时预算立即中断，保证退出/改密码不被卡死。
      if (DateTime.now().difference(startedAt) >= _backupTotalTimeout) {
        Log.backup.w('自动备份：达到总超时 ${_backupTotalTimeout.inSeconds}s，'
            '中断重试 (attempt=$attempt/$maxAttempt)');
        lastBackupError ??= '备份重试达到总超时上限';
        break;
      }
      if (await unitBackupAttempt() == true) {
        final ms = DateTime.now().difference(startedAt).inMilliseconds;
        Log.backup.i('自动备份成功 第 $attempt/$maxAttempt 次尝试, 耗时 ${ms}ms');
        return;
      }
      Log.backup.w('自动备份第 $attempt/$maxAttempt 次尝试失败: '
          '${lastBackupError ?? "未知原因"}');
      // 评审 #11：指数退避（200ms 起，翻倍，封顶 5s），避免失败后打爆网络/磁盘
      await _waitBackoff(attempt, startedAt);
    }

    final ms = DateTime.now().difference(startedAt).inMilliseconds;
    // 备份是数据安全的最后防线，全部重试耗尽必须以 ERROR 留痕
    Log.backup.e('自动备份失败：$maxAttempt 次尝试全部失败, 耗时 ${ms}ms, '
        '最后错误=${lastBackupError ?? "未知原因"}');
  }

  static Future<bool> unitBackupAttempt() async {
    if (Platform.isAndroid) {
      return androidBackup();
    } else if (Platform.isIOS) {
      return iosBackup();
    }
    // 评审 #2 修复：桌面端此前直接 return true 造成"假备份"（改密码前置
    // forceBackup 报告成功但实际未写文件）。桌面端尚未实现真实备份通道，
    // 这里如实返回 false，让上层（backup 重试循环 / forceBackup）正确感知失败：
    //   - 自动备份：重试耗尽后以 ERROR 留痕，不再误报成功
    //   - 改密码前置 forceBackup：弹"备份失败"警告并让用户决定是否继续
    Log.backup.w('当前平台 ${Platform.operatingSystem} 无自动备份实现，'
        '视为备份失败（返回 false）');
    lastBackupError ??= '当前平台（${Platform.operatingSystem}）暂不支持本地备份';
    return false;
  }

  /// 上一次备份失败时的简要错误信息，供调用方（如改密码前置检查）展示。
  static String? lastBackupError;

  // 评审 #11：重试退避参数
  /// 指数退避基础延迟（第 1 次失败后等 200ms，翻倍，封顶 [_backoffMaxDelay]）
  static const Duration _backoffBaseDelay = Duration(milliseconds: 200);
  /// 指数退避封顶延迟
  static const Duration _backoffMaxDelay = Duration(seconds: 5);
  /// 整轮重试的总超时预算：超过即中断（防止 Session.logout / 改密码前置被卡死）
  static const Duration _backupTotalTimeout = Duration(seconds: 30);

  /// 指数退避等待：从 200ms 起翻倍，封顶 5s。
  /// 若已接近总超时则不再等待，让上层循环立即退出。
  static Future<void> _waitBackoff(int attempt, DateTime startedAt) async {
    final elapsed = DateTime.now().difference(startedAt);
    if (elapsed + _backoffMaxDelay >= _backupTotalTimeout) return;
    var delayMs = _backoffBaseDelay.inMilliseconds * (1 << (attempt - 1));
    if (delayMs > _backoffMaxDelay.inMilliseconds) {
      delayMs = _backoffMaxDelay.inMilliseconds;
    }
    await Future<void>.delayed(Duration(milliseconds: delayMs));
  }

  // return true on successful backup
  static Future<bool> androidBackup() async {
    try {
      final String chosenDirectory = SafeNotesConfig.androidBackupDirectory;
      final String jsonOutputContent =
          await FileHandler.encryptedOutputBackupContent();
      final String fileName = SafeNotesConfig.backupFileName;
      final int bytes = jsonOutputContent.length;

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
          // 备份落盘的关键信息：写到哪、多大，便于用户核对备份文件
          Log.backup.i('Android 备份已写入首选目录: ${jsonFile.path} '
              '($bytes 字节)');
        } on FileSystemException catch (e) {
          // 目录不可用（权限不足/不存在）：记录失败原因，随后回退到私有目录
          lastBackupError =
              '默认备份目录不可用（权限不足或目录不存在），已回退到应用私有目录。';
          Log.backup.w('首选备份目录不可写，回退到应用私有目录: '
              '$chosenDirectory/$fileName', error: e);
        }
      }

      // 2) 所选目录不可用时，回退到应用私有目录（始终可写，无需外部存储权限）
      if (!wrote) {
        final dir = await getApplicationDocumentsDirectory();
        final jsonFile = File('${dir.path}/$fileName');
        jsonFile.writeAsStringSync(jsonOutputContent, mode: FileMode.write);
        wrote = true;
        Log.backup.i('Android 备份已写入应用私有目录: ${jsonFile.path} '
            '($bytes 字节)');
      }

      await PreferencesStorage.setLastBackupTime();
      await PreferencesStorage.setIsBackupNeeded(false);
      return true;
    } catch (err, st) {
      lastBackupError = _simplifyBackupError(err);
      Log.backup.e('Android 备份写入失败: $lastBackupError',
          error: err, stackTrace: st);
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
      Log.backup.i('iOS 备份已写入: ${jsonFile.path} '
          '(${jsonOutputContent.length} 字节)');

      await PreferencesStorage.setLastBackupTime();
      await PreferencesStorage.setIsBackupNeeded(false);
    } else {
      Log.backup.w('iOS 备份跳过：应用文档目录路径为空');
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
    // 强制备份通常发生在改密码等高风险操作前，起止必须留痕
    Log.backup.i('开始强制备份（绕过开关）平台=${Platform.operatingSystem} '
        '最大重试=$maxAttempt');
    final startedAt = DateTime.now();

    for (var attempt = 1; attempt <= maxAttempt; attempt++) {
      // 评审 #11：与自动备份一致，加总超时保护（改密码前置检查不能被卡死）
      if (DateTime.now().difference(startedAt) >= _backupTotalTimeout) {
        Log.backup.w('强制备份：达到总超时 ${_backupTotalTimeout.inSeconds}s，'
            '中断重试 (attempt=$attempt/$maxAttempt)');
        lastBackupError ??= '备份重试达到总超时上限';
        break;
      }
      if (await unitBackupAttempt() == true) {
        final ms = DateTime.now().difference(startedAt).inMilliseconds;
        Log.backup.i('强制备份成功 第 $attempt/$maxAttempt 次尝试, 耗时 ${ms}ms');
        return true;
      }
      Log.backup.w('强制备份第 $attempt/$maxAttempt 次尝试失败: '
          '${lastBackupError ?? "未知原因"}');
      await _waitBackoff(attempt, startedAt);
    }

    final ms = DateTime.now().difference(startedAt).inMilliseconds;
    Log.backup.e('强制备份失败：$maxAttempt 次尝试全部失败, 耗时 ${ms}ms, '
        '最后错误=${lastBackupError ?? "未知原因"}');
    return false;
  }
}
