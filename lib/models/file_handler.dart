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

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:core/core.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:media_scanner/media_scanner.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/dialogs/confirm_import.dart';
import 'package:safenotes/utils/cache_manager.dart';
import 'package:safenotes/utils/device_info.dart';
import 'package:safenotes/utils/platform_ui.dart';
import 'package:safenotes/widgets/app_dialogs.dart';

class FileHandler {
  /// 备份导出数据源：笔记 JSON 数组（明文/加密两条路径共用，内容零差异）
  ///
  /// 见 docs/backup-encryption-design-20260810.md §6：明文/加密仅是「是否
  /// 加密」之差，导出内容完全一致。
  static Future<List<Map<String, dynamic>>> loadRecordsForExport() async {
    // exportAll 返回已解密笔记的 JSON 数组字符串（含 uuid/时间戳等全字段，§4.1）
    final String record = await NotesDatabase.instance.exportAll();
    final decoded = jsonDecode(record);
    if (decoded is! List) {
      throw const FormatException('导出数据解析失败：顶层不是数组');
    }
    return decoded.cast<Map<String, dynamic>>();
  }

  /// 明文导出备份内容（plaintext-v1，与旧格式全兼容）
  ///
  /// 数据可携性的一等公民格式：与加密导出只是「是否加密」之差，不引入密码。
  /// UI 将在导出面板上明确提示「该文件不加密，请妥善保管」。
  static Future<String> plainOutputBackupContent() async {
    final records = await loadRecordsForExport();
    final String content = BackupFileCodec.encodePlaintext(records);
    // 备份内容构造完成：记录条数与体积，与后续「写入到哪个路径」的日志配对
    Log.backup.i(
      '已生成明文备份内容: ${records.length} 条笔记, '
      '${content.length} 字节',
    );
    return content;
  }

  /// 加密导出备份内容（snbak v1，真正加密）
  ///
  /// [password] 是「登录口令原文」或用户自定义备份口令（来源由调用方决定：
  /// 自动备份用会话密码 PhraseHandler.getPass，导出面板可让用户自定）。
  /// 文件头不含任何可关联登录 keyring 的敏感字段（无 keyFingerprint/
  /// encryptedDataKey），payload 解密后即为 §4.1 的笔记数组。
  static Future<String> encryptedOutputBackupContent({
    required String password,
  }) async {
    final records = await loadRecordsForExport();
    final String content = await BackupFileCodec.encodeEncrypted(
      password: password,
      records: records,
    );
    // 备份内容构造完成：记录条数与体积（信封 + 头开销），与后续落盘日志配对
    Log.backup.i(
      '已生成加密备份内容: ${records.length} 条笔记, '
      '${content.length} 字节',
    );
    return content;
  }

  Future<String?> selectFileAndImport(BuildContext context) async {
    /*
    导入分流（docs/backup-encryption-design-20260810.md §7）：
      - 加密 snbak（顶层 format=="snbak"）→ 需密码解密后导入
      - 明文 plaintext-v1（顶层 records 根键）→ 直接解析导入（无密码）
    加密导入密码候选：首选「当前会话密码」PhraseHandler.getPass 自动尝试
    （无弹框），失败才弹输入框让用户手输。
    */
    Log.backup.i('开始导入备份：等待用户选择文件');
    String? dataFromFileAsString = await getFileAsString();

    if (dataFromFileAsString == null) {
      Log.backup.i('导入取消：用户未选择文件');
      return "File not picked!".tr();
    } else if (dataFromFileAsString == "unrecognized") {
      Log.backup.w('导入失败：文件无法识别或读取失败');
      return "Unrecognized File!".tr();
    }
    Log.backup.d('已读取备份文件内容 ${dataFromFileAsString.length} 字节，开始解析');

    try {
      final backup = BackupFileCodec.parse(dataFromFileAsString);
      final ImportParser parsedImportData;
      String? plaintextNotice;

      if (backup is BackupFileEncrypted) {
        // ── 加密导入：会话密码自动试解，失败弹输入框 ──
        if (!context.mounted) {
          Log.backup.w('导入中断：上下文已失效');
          return "Import cancelled!".tr();
        }
        final resolved = await _resolveEncryptedRecords(context, backup);
        if (resolved.cancelled) {
          Log.backup.i('导入取消：用户未输入加密备份密码');
          return "Import cancelled!".tr();
        }
        ImportEncryptionControl.setIsImportEncrypted(true);
        parsedImportData = ImportParser.fromDecryptedPlaintext(
          resolved.records,
          expectedTotal: backup.header.total,
        );
      } else if (backup is BackupFilePlaintext) {
        // ── 明文导入：无密码，直接解析（兼容旧备份与用户主动明文导出）──
        ImportEncryptionControl.setIsImportEncrypted(false);
        destroyImportCredentials();
        plaintextNotice = 'This backup is NOT encrypted, imported as plain.'
            .tr();
        parsedImportData = ImportParser.fromDecryptedPlaintext(
          backup.records,
          expectedTotal: backup.total,
        );
      } else {
        Log.backup.w('导入失败：无法识别的备份文件格式');
        return "Unrecognized File!".tr();
      }

      Log.backup.i(
        '备份文件解析成功：共 ${parsedImportData.totalNotes} 条笔记，'
        '等待用户确认导入',
      );

      bool importConfirmed = false;
      // TODO: refactor without using BuildContexts across async gap
      if (context.mounted) {
        importConfirmed = await confirmImportDialog(
          context,
          parsedImportData.totalNotes,
          notice: plaintextNotice,
        );
      }
      if (importConfirmed) {
        final skipped = await insertNotes(parsedImportData.getAllNotes());
        if (skipped > 0) {
          // 幂等去重提示：库中已存在同 uuid 的笔记被跳过，不重复导入
          final imported = parsedImportData.totalNotes - skipped;
          Log.backup.i(
            '导入去重提示: 导入 $imported 条, 跳过已存在 '
            '$skipped 条',
          );
          return '{imported} notes imported, {skipped} skipped (already exist).'
              .tr(namedArgs: {'imported': '$imported', 'skipped': '$skipped'});
        }
      } else {
        Log.backup.i(
          '导入取消：用户在确认对话框中放弃 '
          '(${parsedImportData.totalNotes} 条笔记未导入)',
        );
        return "Import cancelled!".tr();
      }
    } catch (e, st) {
      Log.backup.e('导入失败：解析或写入过程异常', error: e, stackTrace: st);
      return "Failed to import file!".tr();
    }
    return "Notes successfully imported!".tr();
  }

  void destroyImportCredentials() {
    ImportPassPhraseHandler.setImportPassPhrase("null");
    ImportPassPhraseHandler.setImportPassPhraseHash(null);
  }

  /// 解析加密备份的候选密码（docs/backup-encryption-design-20260810.md §7）
  ///
  /// 首选「当前会话密码」[PhraseHandler.getPass] 自动尝试（无弹框）；失败或
  /// 无会话密码时弹输入框让用户手输，解密失败带错误提示重开直到成功/取消。
  Future<({List<dynamic> records, bool cancelled})> _resolveEncryptedRecords(
    BuildContext context,
    BackupFileEncrypted backup,
  ) async {
    // 1) 会话密码自动试解
    final sessionPass = PhraseHandler.getPass;
    if (sessionPass.isNotEmpty) {
      try {
        return (
          records: await BackupFileCodec.decryptEncrypted(backup, sessionPass),
          cancelled: false,
        );
      } on SyncDecryptionException {
        Log.backup.w('会话密码无法解密该备份，改用用户输入');
      }
    }

    // 2) 弹输入框，解密失败带错误提示重开
    //    通用密码输入模板（showAppPassword，与全 app 密码输入同一入口）
    String? errorText;
    while (true) {
      if (!context.mounted) {
        return (records: const [], cancelled: true);
      }
      final String? entered = await showAppPassword(
        context,
        title: 'Import Data is Encrypted'.tr(),
        message: 'Enter the passphrase of the device that generated this file.'
            .tr(),
        confirmLabel: 'Submit'.tr(),
        cancelLabel: 'Cancel'.tr(),
        placeholder: 'Encryption Phrase'.tr(),
        errorText: errorText,
      );
      if (entered == null) {
        return (records: const [], cancelled: true);
      }
      try {
        return (
          records: await BackupFileCodec.decryptEncrypted(backup, entered),
          cancelled: false,
        );
      } on SyncDecryptionException {
        Log.backup.w('导入失败：加密备份密码错误');
        errorText = 'Incorrect password or backup file corrupted!'.tr();
      }
    }
  }

  Future<bool> confirmImportDialog(
    BuildContext context,
    int totalNotes, {
    String? notice,
  }) async {
    final result = await showImportConfirmDialog(
      context: context,
      importCount: totalNotes,
      notice: notice,
    );
    return result ?? false;
  }

  /// 平台默认备份目录（导出面板未选路径时的回退落盘位置）
  ///
  /// 桌面端此前无备份通道（scheduled_task 直接返回 false），补全为写入应用
  /// 文档目录（Windows=Documents、Linux=~/Documents、macOS=Documents）。
  static Future<String> defaultBackupDirectory() async {
    if (isAndroid) {
      // 首选 Download/Carro Note（有权限时）；不可用回退应用私有目录
      if (await Directory(SafeNotesConfig.androidDownloadDirectory).exists()) {
        try {
          await Directory(
            SafeNotesConfig.androidBackupDirectory,
          ).create(recursive: false);
          return SafeNotesConfig.androidBackupDirectory;
        } on FileSystemException {
          // 目录创建失败回退应用文档目录（始终可写）
        }
      }
      return (await getApplicationDocumentsDirectory()).path;
    }
    // iOS / 桌面统一用应用文档目录
    return (await getApplicationDocumentsDirectory()).path;
  }

  /// 把备份内容写到目标路径并返回落盘文件
  ///
  /// [directory] 目录；[fileName] 文件名。目录不存在时递归创建
  /// （Android 下载目录/桌面端文档目录可能尚未创建）。
  static Future<File> writeBackupToPath({
    required String content,
    required String directory,
    required String fileName,
  }) async {
    return writeBackupFile(
      content: content,
      filePath: p.join(directory, fileName),
    );
  }

  /// 把备份内容写到完整路径（导出面板最终落盘入口）
  ///
  /// 自动创建父目录、同步写盘；Android 通知媒体库收录。
  static Future<File> writeBackupFile({
    required String content,
    required String filePath,
  }) async {
    final jsonFile = File(filePath);
    final dir = jsonFile.parent;
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    jsonFile.writeAsStringSync(content, mode: FileMode.write);
    Log.backup.i('备份已写入: ${jsonFile.path} (${content.length} 字节)');

    // Android 上通知媒体库收录，让用户在系统文件管理器可见
    if (isAndroid) {
      MediaScanner.loadMedia(path: jsonFile.path);
    }
    return jsonFile;
  }

  Future<String?> getFileAsString() async {
    try {
      // 评审 #10：导入文件体积上限，防止误选超大文件把内存打爆。
      // 基线：单条笔记 ≤ 1MB，正常备份 ≤ 1 万条；上限取 256MB 已远超需要，
      // 同时阻止普通误操作读到数 GB 的任意文件。
      const int maxImportBytes = 256 * 1024 * 1024;
      final String? path;
      if (isAndroid) {
        // emptyCache to prevent filepicker from picking old cached version
        // starting Android 11 all files are provided through cache mechanism and not directly
        await CacheManager.emptyCache();
        FilePickerResult? result;

        if (await isAndroidSdkVersionAbove(29)) {
          result = await FilePicker.pickFiles(
            type: FileType.custom,
            allowedExtensions: SafeNotesConfig.importFileExtensions,
            allowMultiple: false,
          );
        } else {
          result = await FilePicker.pickFiles(
            type: FileType.any,
            allowMultiple: false,
          );
        }
        if (result != null) {
          PlatformFile file = result.files.first;
          if (file.size == 0) return null;
          if (file.size > maxImportBytes) {
            Log.backup.w(
              '导入失败：备份文件过大 ${file.size} '
              '>(上限 $maxImportBytes 字节)',
            );
            return "unrecognized";
          }
          path = file.path;
        } else {
          return null;
        }
      } else if (isIOS) {
        FilePickerResult? result = await FilePicker.pickFiles(
          type: FileType.custom,
          allowedExtensions: SafeNotesConfig.importFileExtensions,
          allowMultiple: false,
        );
        if (result != null) {
          final file = result.files.single;
          if (file.size > maxImportBytes) {
            Log.backup.w(
              '导入失败：备份文件过大 ${file.size} '
              '>(上限 $maxImportBytes 字节)',
            );
            return "unrecognized";
          }
          path = file.path;
        } else {
          return null;
        }
      } else {
        // 桌面端补全：此前直接返回 null 导致「桌面端无导入通道」，现在与移动端
        // 一致用文件选择器（json/snbak 双扩展名）。
        FilePickerResult? result = await FilePicker.pickFiles(
          type: FileType.custom,
          allowedExtensions: SafeNotesConfig.importFileExtensions,
          allowMultiple: false,
        );
        if (result != null) {
          final file = result.files.single;
          if (file.size == 0) return null;
          if (file.size > maxImportBytes) {
            Log.backup.w(
              '导入失败：备份文件过大 ${file.size} '
              '>(上限 $maxImportBytes 字节)',
            );
            return "unrecognized";
          }
          path = file.path;
        } else {
          return null;
        }
      }
      // 评审 #10：主线程同步读任意大文件会卡 UI（甚至整机冻结几十秒），
      // 改为后台 isolate 异步读取。
      return await File(path!).readAsString();
    } catch (e) {
      return "unrecognized";
    }
  }

  /// 写入导入的笔记（返回被跳过的条数，即库中已存在同 uuid 的笔记数）
  ///
  /// 底层 `storeNotesInTransaction` 做 uuid 幂等去重：同 uuid 已存在的
  /// 笔记（含墓碑）跳过，仅新增本地没有的，避免撞 UNIQUE 约束整体回滚。
  Future<int> insertNotes(List<SafeNote> imported) async {
    Log.backup.i('开始写入导入的笔记: 共 ${imported.length} 条');
    final startedAt = DateTime.now();
    // 评审 #10：整个导入放入单个事务，任一条失败整体回滚，
    // 不再出现「中途崩/错一条 → 半库数据」的脏状态。
    final inserted = await NotesDatabase.instance.storeNotesInTransaction(
      imported,
    );
    final skipped = imported.length - inserted;
    final ms = DateTime.now().difference(startedAt).inMilliseconds;
    Log.backup.i(
      '导入完成: 成功写入 $inserted/${imported.length} 条笔记'
      '（跳过已存在 $skipped 条）, 耗时 ${ms}ms',
    );
    return skipped;
  }
}
