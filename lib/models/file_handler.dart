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
import 'package:safenotes/data/database_handler.dart';
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/dialogs/confirm_import.dart';
import 'package:safenotes/models/parse_import.dart';
import 'package:safenotes/models/safenote.dart';
import 'package:safenotes/utils/cache_manager.dart';
import 'package:safenotes/utils/device_info.dart';

class FileHandler {
  /// 导出备份内容(明文 JSON)
  ///
  /// 简化方案:移除 passPhraseHash 后,backup 文件不再写密码指纹。
  /// 当前 backup 实际是明文导出(exportAllEncrypted => exportAll 已解密),
  /// recordHandlerHash 原本只是 owner 身份指纹,不用作加密密钥。
  /// 本次最小化:写固定标记 "plaintext-v1",完整加密改造见 docs/登录验证简化方案-20260729.md 5.2 TODO。
  static Future<String> encryptedOutputBackupContent() async {
    String record = await NotesDatabase.instance.exportAllEncrypted();
    int totalCountOfNotes = '{'.allMatches(record).length;

    String content =
        '{ "records" : $record, "recordHandlerHash" : "plaintext-v1", "total" : ${totalCountOfNotes.toString()} }';
    return content;
  }

  Future<String?> selectFileAndImport(BuildContext context) async {
    /*
    简化方案:移除 passPhraseHash 后,import 不再校验密码。
    当前 backup 实际是明文导出,密码校验只是形式门禁,不影响数据可读性。
    本次最小化:直接解析并插入笔记,完整加密改造见
    docs/登录验证简化方案-20260729.md 5.2 TODO。
    */
    String? dataFromFileAsString = await getFileAsString();

    if (dataFromFileAsString == null) {
      return "File not picked!".tr();
    } else if (dataFromFileAsString == "unrecognized") {
      return "Unrecognized File!".tr();
    }

    try {
      var jsonDecodedData = jsonDecode(dataFromFileAsString);
      // 明文 backup:不校验密码,直接解析
      ImportEncryptionControl.setIsImportEncrypted(false);
      destroyImportCredentials();

      final parsedImportData = ImportParser.fromJson(jsonDecodedData);

      bool importConfirmed = false;
      // TODO: refactor without using BuildContexts across async gap
      if (context.mounted) {
        importConfirmed =
            await confirmImportDialog(context, parsedImportData.totalNotes);
      }
      if (importConfirmed) {
        await insertNotes(parsedImportData.getAllNotes());
      } else {
        return "Import cancelled!".tr();
      }
    } catch (e) {
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
    for (final note in imported) {
      await NotesDatabase.instance.encryptAndStore(note);
    }
  }
}
