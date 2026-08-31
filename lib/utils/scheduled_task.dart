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

import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:core/core.dart';
import 'package:media_scanner/media_scanner.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/file_handler.dart';
import 'package:safenotes/src/platform/platform_io.dart';
import 'package:safenotes/utils/platform_ui.dart';

class ScheduledTask {
  static Future<void> backup() async {
    if (kIsWeb) return;
    // 发布评审 R1：不再依赖 isBackupNeeded 标记。旧实现「备份成功后置 false、
    // 无任何路径置回 true」，导致自动备份一生只执行一次（Last Backup 停在首次）。
    // 自动备份触发点本来就少（切后台/登出/升级后），每次触发都全量落盘即可；
    // 手动路径 forceBackup 本就绕过该标记，语义现在与自动路径一致。
    if (PreferencesStorage.isBackupOn == false) {
      Log.backup.d(
        '跳过自动备份: 开关 isBackupOn='
        '${PreferencesStorage.isBackupOn}',
      );
      return;
    }

    // 去重（v2 设计）：笔记数据无变化则不重复写盘。
    // 指纹只对明文 records，不受 AES-GCM 随机 nonce 影响（见 docs/
    // backup-scheme-revamp-20260831.md）。强制备份不走本入口，不去重。
    final fingerprint = await FileHandler.recordsFingerprint();
    if (fingerprint.isNotEmpty &&
        fingerprint == PreferencesStorage.lastBackupFingerprint) {
      Log.backup.d('自动备份跳过：笔记数据无变化（指纹一致），不上传新文件');
      return;
    }

    int maxAttempt = PreferencesStorage.maxBackupRetryAttempts;
    Log.backup.i(
      '开始自动备份 平台=${Platform.operatingSystem} '
      '最大重试=$maxAttempt 上次备份=${PreferencesStorage.lastBackupTime}',
    );
    final startedAt = DateTime.now();

    for (var attempt = 1; attempt <= maxAttempt; attempt++) {
      // 评审 #11：防止备份失败把重试循环拖成无界阻塞（Session.logout 会 await
      // 本方法）。超过总超时预算立即中断，保证退出/改密码不被卡死。
      if (DateTime.now().difference(startedAt) >= _backupTotalTimeout) {
        Log.backup.w(
          '自动备份：达到总超时 ${_backupTotalTimeout.inSeconds}s，'
          '中断重试 (attempt=$attempt/$maxAttempt)',
        );
        lastBackupError ??= '备份重试达到总超时上限';
        break;
      }
      if (await unitBackupAttempt(scene: BackupScene.auto) == true) {
        final ms = DateTime.now().difference(startedAt).inMilliseconds;
        Log.backup.i('自动备份成功 第 $attempt/$maxAttempt 次尝试, 耗时 ${ms}ms');
        // 仅在成功落盘后更新指纹，避免"失败但指纹已更新导致下次跳过"。
        await PreferencesStorage.setLastBackupFingerprint(fingerprint);
        return;
      }
      Log.backup.w(
        '自动备份第 $attempt/$maxAttempt 次尝试失败: '
        '${lastBackupError ?? "未知原因"}',
      );
      // 评审 #11：指数退避（200ms 起，翻倍，封顶 5s），避免失败后打爆网络/磁盘
      await _waitBackoff(attempt, startedAt);
    }

    final ms = DateTime.now().difference(startedAt).inMilliseconds;
    // 备份是数据安全的最后防线，全部重试耗尽必须以 ERROR 留痕
    Log.backup.e(
      '自动备份失败：$maxAttempt 次尝试全部失败, 耗时 ${ms}ms, '
      '最后错误=${lastBackupError ?? "未知原因"}',
    );
  }

  /// 解析最终备份落盘目录（选择备份路径功能的核心）
  ///
  /// 优先返回用户自定义目录 [PreferencesStorage.backupDirectory]（已持久化记住）；
  /// 未设置时回退平台默认目录（[FileHandler.defaultBackupDirectory]，即
  /// Android=Download/CarroNote，iOS/桌面=应用文档目录）。所有备份通道
  /// （androidBackup/iosBackup/desktopBackup）与 UI 指示路径统一从此取，避免
  /// 「UI 显示的路径」与「真实落盘路径」再次错位。
  static Future<String> resolveBackupDirectory() async {
    final custom = PreferencesStorage.backupDirectory;
    if (custom.isNotEmpty) return custom;
    return FileHandler.defaultBackupDirectory();
  }

  static Future<bool> unitBackupAttempt({
    String? fileName,
    BackupScene scene = BackupScene.auto,
  }) async {
    // 所有备份统一走「加密导出」（docs/backup-encryption-design-20260810.md
    // §6 密码来源落地 1）：用会话内存密码 PhraseHandler.getPass 派生 B-KEY。
    // 密码为空说明会话态异常，如实失败（不能写明文备份）。
    if (PhraseHandler.getPass.isEmpty) {
      Log.backup.w('自动备份：会话密码为空，无法加密备份（返回 false）');
      lastBackupError ??= '会话密码不可用，无法加密备份';
      return false;
    }
    // 默认文件名按场景生成（carronote_<scene>_<ts>.snbak），保留显式 fileName 覆盖。
    final effectiveName =
        fileName ?? SafeNotesConfig.backupFileNameForScene(scene);
    if (isAndroid) {
      return androidBackup(customFileName: effectiveName);
    } else if (isIOS) {
      return iosBackup(customFileName: effectiveName);
    }
    return desktopBackup(customFileName: effectiveName);
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
  static Future<bool> androidBackup({String? customFileName}) async {
    try {
      // 选择备份路径：优先用户自定义目录，否则回退平台默认目录
      final String chosenDirectory = await resolveBackupDirectory();
      final String jsonOutputContent =
          await FileHandler.encryptedOutputBackupContent(
            password: PhraseHandler.getPass,
          );
      final String fileName = customFileName ?? SafeNotesConfig.backupFileName;
      final int bytes = jsonOutputContent.length;

      lastBackupError = null;
      bool wrote = false;

      // 1) 尝试写入用户设置/默认的备份目录
      //    （Android 分区存储下该目录可能无直接写入权限，会抛 FileSystemException）
      if (chosenDirectory.isNotEmpty) {
        try {
          final jsonFile = File(p.join(chosenDirectory, fileName));
          jsonFile.writeAsStringSync(jsonOutputContent, mode: FileMode.write);
          MediaScanner.loadMedia(path: jsonFile.path);
          wrote = true;
          // 备份落盘的关键信息：写到哪、多大，便于用户核对备份文件
          Log.backup.i(
            'Android 备份已写入首选目录: ${jsonFile.path} '
            '($bytes 字节)',
          );
        } on FileSystemException catch (e) {
          // 目录不可用（权限不足/不存在）：记录失败原因，随后回退到私有目录
          lastBackupError = '默认备份目录不可用（权限不足或目录不存在），已回退到应用私有目录。';
          Log.backup.w(
            '首选备份目录不可写，回退到应用私有目录: '
            '${p.join(chosenDirectory, fileName)}',
            error: e,
          );
        }
      }

      // 2) 所选目录不可用时，回退到应用私有目录（始终可写，无需外部存储权限）
      if (!wrote) {
        final dir = await getApplicationDocumentsDirectory();
        final jsonFile = File(p.join(dir.path, fileName));
        jsonFile.writeAsStringSync(jsonOutputContent, mode: FileMode.write);
        wrote = true;
        Log.backup.i(
          'Android 备份已写入应用私有目录: ${jsonFile.path} '
          '($bytes 字节)',
        );
      }

      await PreferencesStorage.setLastBackupTime();
      return true;
    } catch (err, st) {
      lastBackupError = _simplifyBackupError(err);
      Log.backup.e(
        'Android 备份写入失败: $lastBackupError',
        error: err,
        stackTrace: st,
      );
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

  static Future<bool> iosBackup({String? customFileName}) async {
    try {
      final String dir = await resolveBackupDirectory();

      if (dir.isEmpty) {
        Log.backup.w('iOS 备份跳过：应用文档目录路径为空');
        return false;
      }

      String jsonOutputContent = await FileHandler.encryptedOutputBackupContent(
        password: PhraseHandler.getPass,
      );
      final String fileName = customFileName ?? SafeNotesConfig.backupFileName;
      final jsonFile = File(p.join(dir, fileName));

      jsonFile.writeAsStringSync(jsonOutputContent);
      Log.backup.i(
        'iOS 备份已写入: ${jsonFile.path} '
        '(${jsonOutputContent.length} 字节)',
      );

      await PreferencesStorage.setLastBackupTime();
      return true;
    } catch (err, st) {
      lastBackupError = _simplifyBackupError(err);
      Log.backup.e('iOS 备份写入失败: $lastBackupError', error: err, stackTrace: st);
      return false;
    }
  }

  /// 桌面端（Windows/Linux/macOS）本地备份
  ///
  /// 本设计补全：此前桌面端在 [unitBackupAttempt] 直接返回 false（无真实备份
  /// 通道）。现在把加密备份写入应用文档目录（path_provider 在桌面返回
  /// Documents 目录），与 iOS 行为对齐。
  static Future<bool> desktopBackup({String? customFileName}) async {
    try {
      // 选择备份路径：优先用户自定义目录，否则回退应用文档目录
      final dir = Directory(await resolveBackupDirectory());
      final String content = await FileHandler.encryptedOutputBackupContent(
        password: PhraseHandler.getPass,
      );
      final String fileName = customFileName ?? SafeNotesConfig.backupFileName;
      final jsonFile = File(p.join(dir.path, fileName));

      // 目录可能尚未创建（首次），确保父目录存在
      await jsonFile.parent.create(recursive: true);
      jsonFile.writeAsStringSync(content, mode: FileMode.write);
      Log.backup.i(
        '桌面端备份已写入: ${jsonFile.path} '
        '(${content.length} 字节)',
      );

      await PreferencesStorage.setLastBackupTime();
      return true;
    } catch (err, st) {
      lastBackupError = _simplifyBackupError(err);
      Log.backup.e('桌面端备份写入失败: $lastBackupError', error: err, stackTrace: st);
      return false;
    }
  }

  /// 强制备份一次（绕过 isBackupOn 开关，且不去重）
  ///
  /// 用于关键操作前的数据保护：
  ///   - 无论用户是否开启自动备份，都强制写入一份本地完整备份
  ///   - 失败会重试 maxBackupRetryAttempts 次
  ///
  /// [scene] 决定文件名后缀（changepw / migrate / manual），便于识别备份来源。
  ///
  /// 返回 true 表示备份成功，false 表示失败（调用方可据此决定是否继续操作）。
  static Future<bool> forceBackup({
    BackupScene scene = BackupScene.manual,
  }) async {
    if (kIsWeb) return true;
    int maxAttempt = PreferencesStorage.maxBackupRetryAttempts;
    // 强制备份通常发生在改密码等高风险操作前，起止必须留痕
    Log.backup.i(
      '开始强制备份（绕过开关）平台=${Platform.operatingSystem} '
      '最大重试=$maxAttempt',
    );
    final startedAt = DateTime.now();

    for (var attempt = 1; attempt <= maxAttempt; attempt++) {
      // 评审 #11：与自动备份一致，加总超时保护（改密码前置检查不能被卡死）
      if (DateTime.now().difference(startedAt) >= _backupTotalTimeout) {
        Log.backup.w(
          '强制备份：达到总超时 ${_backupTotalTimeout.inSeconds}s，'
          '中断重试 (attempt=$attempt/$maxAttempt)',
        );
        lastBackupError ??= '备份重试达到总超时上限';
        break;
      }
      if (await unitBackupAttempt(scene: scene) == true) {
        final ms = DateTime.now().difference(startedAt).inMilliseconds;
        Log.backup.i('强制备份成功 第 $attempt/$maxAttempt 次尝试, 耗时 ${ms}ms');
        return true;
      }
      Log.backup.w(
        '强制备份第 $attempt/$maxAttempt 次尝试失败: '
        '${lastBackupError ?? "未知原因"}',
      );
      await _waitBackoff(attempt, startedAt);
    }

    final ms = DateTime.now().difference(startedAt).inMilliseconds;
    Log.backup.e(
      '强制备份失败：$maxAttempt 次尝试全部失败, 耗时 ${ms}ms, '
      '最后错误=${lastBackupError ?? "未知原因"}',
    );
    return false;
  }
}
