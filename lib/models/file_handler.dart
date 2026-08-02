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
import 'dart:convert';
import 'dart:io';

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';

// Project imports:
import 'package:core/core.dart';
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/dialogs/confirm_import.dart';
import 'package:safenotes/utils/cache_manager.dart';
import 'package:safenotes/utils/device_info.dart';

class FileHandler {
  /// 导出备份内容(明文 JSON)
  ///
  /// 简化方案:移除 passPhraseHash 后,backup 文件不再写密码指纹。
  /// 当前 backup 实际是明文导出(exportAll 已解密),
  /// recordHandlerHash 原本只是 owner 身份指纹,不用作加密密钥。
  /// 本次最小化:写固定标记 "plaintext-v1",完整加密改造见 docs/登录验证简化方案-20260729.md 5.2 TODO。
  static Future<String> encryptedOutputBackupContent() async {
    String record = await NotesDatabase.instance.exportAll();
    int totalCountOfNotes = '{'.allMatches(record).length;

    String content =
        '{ "records" : $record, "recordHandlerHash" : "plaintext-v1", "total" : ${totalCountOfNotes.toString()} }';
    // 备份内容构造完成：记录条数与体积，与后续「写入到哪个路径」的日志配对
    Log.backup.i('已生成备份内容: $totalCountOfNotes 条笔记, '
        '${content.length} 字节');
    return content;
  }

  Future<String?> selectFileAndImport(BuildContext context) async {
    /*
    简化方案:移除 passPhraseHash 后,import 不再校验密码。
    当前 backup 实际是明文导出,密码校验只是形式门禁,不影响数据可读性。
    本次最小化:直接解析并插入笔记,完整加密改造见
    docs/登录验证简化方案-20260729.md 5.2 TODO。
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
      var jsonDecodedData = jsonDecode(dataFromFileAsString);
      // 明文 backup:不校验密码,直接解析
      ImportEncryptionControl.setIsImportEncrypted(false);
      destroyImportCredentials();

      final parsedImportData = ImportParser.fromJson(jsonDecodedData);
      Log.backup.i('备份文件解析成功：共 ${parsedImportData.totalNotes} 条笔记，'
          '等待用户确认导入');

      bool importConfirmed = false;
      // TODO: refactor without using BuildContexts across async gap
      if (context.mounted) {
        importConfirmed =
            await confirmImportDialog(context, parsedImportData.totalNotes);
      }
      if (importConfirmed) {
        await insertNotes(parsedImportData.getAllNotes());
      } else {
        Log.backup.i('导入取消：用户在确认对话框中放弃 '
            '(${parsedImportData.totalNotes} 条笔记未导入)');
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

  Future<bool> confirmImportDialog(BuildContext context, int totalNotes) async {
    return await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => ImportConfirm(importCount: totalNotes),
        ) ??
        false;
  }

  Future<String?> getFileAsString() async {
    try {
      if (Platform.isAndroid) {
        // emptyCache to prevent filepicker from picking old cached version
        // starting Android 11 all files are provided through cache mechanism and not directly
        await CacheManager.emptyCache();
        FilePickerResult? result;

        if (await isAndroidSdkVersionAbove(29)) {
          result = await FilePicker.pickFiles(
            type: FileType.custom,
            allowedExtensions: [SafeNotesConfig.importFileExtension],
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
          var jsonFile = File(file.path!);

          String content = jsonFile.readAsStringSync();
          return content;
        }
      } else if (Platform.isIOS) {
        FilePickerResult? result = await FilePicker.pickFiles(
          type: FileType.custom,
          allowedExtensions: [SafeNotesConfig.importFileExtension],
          allowMultiple: false,
        );
        if (result != null) {
          File jsonFile = File(result.files.single.path!);
          String content = jsonFile.readAsStringSync();
          return content;
        }
      }
    } catch (e) {
      return "unrecognized";
    }
    return null;
  }

  Future<void> insertNotes(List<SafeNote> imported) async {
    Log.backup.i('开始写入导入的笔记: 共 ${imported.length} 条');
    final startedAt = DateTime.now();
    var ok = 0;
    for (final note in imported) {
      await NotesDatabase.instance.storeNote(note);
      ok++;
    }
    final ms = DateTime.now().difference(startedAt).inMilliseconds;
    Log.backup.i('导入完成: 成功写入 $ok/${imported.length} 条笔记, 耗时 ${ms}ms');
  }
}
