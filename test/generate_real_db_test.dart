/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

/*
 * 生成两个「可直接替换客户端数据库」的真实 safenotes_sync.db 文件
 *
 * 用途：构造两份真实客户端数据库，供多端/大笔记/同步联调测试。
 * 复制到客户端数据目录（app support 下的 safenotes_sync.db）即可直接使用，
 * 用下方打印的密码登录即可解锁（keyring 账本已随库生成）。
 *
 * 特性：
 *   - **真实接口**：全程走客户端真实路径——Keyring.createNew（建账本/密钥）、
 *     NotesDatabase.instance.storeNote（字段级 AES-GCM 加密落盘）、
 *     Keyring.unlockLocal（登录解锁）、readAllNotes（解密读取），
 *     不 mock、不直接触碰 SQLite 接口。
 *   - **两个真实数据库**：独立 keyring（各自 vaultId/salt/dataKey/密码）。
 *   - **笔记内容**：默认从 temp/rfc4918.txt（RFC 4918 WebDAV 规范原文，纯
 *     ASCII 无编码污染）随机截取，单条 1KB ~ 100KB（UTF-8 字节，按 Unicode
 *     码点精确累积，绝不拆代理对）；也可用 GEN_DB_CORPUS 指定其他文件。
 *
 * 运行：
 *   flutter test test/generate_real_db_test.dart
 *
 * 可调参数（环境变量，均可选）：
 *   GEN_DB_OUT       输出根目录（默认 temp/generated-db）
 *   GEN_DB_PASSWORD_A 设备 A 密码（默认 safe-a-2026）
 *   GEN_DB_PASSWORD_B 设备 B 密码（默认 safe-b-2026）
 *   GEN_DB_COUNT     每库笔记条数（默认 40）
 *   GEN_DB_SEED      随机种子（默认时间种子，固定值可复现）
 *   GEN_DB_CORPUS    自定义语料文件（绝对路径 .txt）
 */

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:core/core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 单条笔记目标大小范围（字节）
const int kMinBytes = 512; // 512B
const int kMaxBytes = 100 * 1024; // 100KB

/// 数据源（按优先级）：GEN_DB_CORPUS 环境变量 > rfc4918.txt > txt-utf8 > txt
///
/// - rfc4918.txt：RFC 4918 (WebDAV) 规范原文，纯 ASCII，无编码污染（推荐）。
/// - txt-utf8 / txt：小说素材；txt 是 GBK 需先转码，且部分文件含 U+FFFD
///   转码替换符（如 002.txt 有 36 万个），加载时会统一清洗剔除。
const String kCorpusRfc = r'C:\Home\Projects\safenotes\temp\rfc4918.txt';
const String kTxtRoot = r'C:\Home\Projects\temp\txt';
const String kTxtRootUtf8 = r'C:\Home\Projects\temp\txt-utf8';

/// 清洗语料：剔除 U+FFFD（转码替换符乱码）、孤立代理、BOM 等坏字符。
/// rfc4918.txt 本身干净，此步是防御（保证任何数据源都不产出乱码笔记）。
String _sanitize(String corpus) {
  final sb = StringBuffer();
  var i = 0;
  final len = corpus.length;
  while (i < len) {
    final c = corpus.codeUnitAt(i);
    if (c == 0xFFFD) {
      // 转码替换符（乱码）
      i++;
      continue;
    }
    if (c >= 0xD800 && c <= 0xDBFF) {
      // 高代理
      if (i + 1 < len) {
        final lo = corpus.codeUnitAt(i + 1);
        if (lo >= 0xDC00 && lo <= 0xDFFF) {
          sb.writeCharCode(c);
          sb.writeCharCode(lo);
          i += 2;
          continue;
        }
      }
      i++; // 孤立高代理 → 丢弃
      continue;
    }
    if (c >= 0xDC00 && c <= 0xDFFF) {
      // 孤立低代理 → 丢弃
      i++;
      continue;
    }
    sb.writeCharCode(c);
    i++;
  }
  return sb.toString().replaceAll('\uFEFF', '');
}

/// 从 [corpus] 的 codeUnit 起点截取一段文本，使其 UTF-8 字节数接近 [targetBytes]。
///
/// **按 Unicode 码点（rune）安全截取**：代理对（emoji/非 BMP 字符）成对取入，
/// 绝不拆散——按 code unit 逐个截取会把代理对拆成孤立代理，正是乱码的来源之一。
String _sliceToBytes(String corpus, int start, int targetBytes) {
  // 起点若落在低代理（代理对后半），回退到对首的高代理
  if (start > 0) {
    final c0 = corpus.codeUnitAt(start);
    if (c0 >= 0xDC00 && c0 <= 0xDFFF) {
      final prev = corpus.codeUnitAt(start - 1);
      if (prev >= 0xD800 && prev <= 0xDBFF) start -= 1;
    }
  }
  final sb = StringBuffer();
  var bytes = 0;
  var i = start;
  while (i < corpus.length && bytes < targetBytes) {
    final code = corpus.codeUnitAt(i);
    if (code >= 0xD800 && code <= 0xDBFF && i + 1 < corpus.length) {
      final lo = corpus.codeUnitAt(i + 1);
      if (lo >= 0xDC00 && lo <= 0xDFFF) {
        // 完整代理对：成对写入
        sb.writeCharCode(code);
        sb.writeCharCode(lo);
        bytes += utf8.encode(String.fromCharCodes([code, lo])).length;
        i += 2;
        continue;
      }
    }
    sb.writeCharCode(code);
    bytes += utf8.encode(String.fromCharCode(code)).length;
    i += 1;
  }
  return sb.toString();
}

/// 从语料随机截取一条笔记（title 取片段开头，description 为片段剩余）
///
/// 截取片段若不足 [kMinBytes]（随机起点太靠近语料末尾），换起点重试
/// （最多 [kSampleRetries] 次），保证单条满足 1KB~100KB 要求。
({String title, String description}) _sampleNote(
  String corpus,
  Random rng,
  int targetBytes,
) {
  const kSampleRetries = 8;
  for (var attempt = 0; attempt < kSampleRetries; attempt++) {
    final start = rng.nextInt(corpus.length > 10 ? corpus.length - 1 : 1);
    final slice = _sliceToBytes(corpus, start, targetBytes);
    if (utf8.encode(slice).length < kMinBytes) continue; // 片段过短，重试

    // title：片段第一个换行前的内容（或前 60 码点），清洗控制字符
    final nl = slice.indexOf('\n');
    var firstLine = (nl >= 0 ? slice.substring(0, nl) : slice).trim();
    if (firstLine.runes.length > 60) {
      firstLine = String.fromCharCodes(firstLine.runes.take(60));
    }
    if (firstLine.isEmpty) firstLine = 'Notes from corpus';
    firstLine = firstLine.replaceAll(RegExp(r'[\x00-\x1F]'), '');

    // description：片段去掉 title 部分后的剩余（去重开头空白）
    var rest = slice.substring(firstLine.length).trim();
    if (rest.isEmpty) rest = slice;
    return (title: firstLine, description: rest);
  }
  // 语料极小等极端情况：直接返回语料开头（不再保证 1KB）
  final head = _sliceToBytes(corpus, 0, kMinBytes);
  return (title: 'Notes from corpus', description: head);
}

/// 读取语料：文件或目录均可（目录读取全部 .txt 拼接）；按优先级候选
Future<String> _loadCorpus() async {
  final envFile = Platform.environment['GEN_DB_CORPUS'];
  final candidates = <String>[
    if (envFile != null && envFile.isNotEmpty) envFile,
    kCorpusRfc,
    kTxtRootUtf8,
    kTxtRoot,
  ];
  for (final root in candidates) {
    try {
      final f = File(root);
      if (f.existsSync() && f.path.toLowerCase().endsWith('.txt')) {
        final raw = await f.readAsString(encoding: utf8);
        final corpus = _sanitize(raw);
        if (corpus.length < kMinBytes) continue;
        // ignore: avoid_print
        print('[GEN] 素材: $root（${corpus.length} 字符，清洗后）');
        return corpus;
      }
      final dir = Directory(root);
      if (dir.existsSync()) {
        final files =
            dir
                .listSync()
                .whereType<File>()
                .where((f) => f.path.toLowerCase().endsWith('.txt'))
                .toList()
              ..sort((a, b) => a.path.compareTo(b.path));
        if (files.isEmpty) continue;
        final buf = StringBuffer();
        for (final f in files) {
          buf.writeln(await f.readAsString(encoding: utf8));
        }
        final corpus = _sanitize(buf.toString());
        if (corpus.length < kMinBytes) continue;
        // ignore: avoid_print
        print('[GEN] 素材: $root（${corpus.length} 字符，清洗后）');
        return corpus;
      }
    } on FileSystemException catch (e) {
      // ignore: avoid_print
      print('[GEN] 候选 $root 读取失败（可能是 GBK 编码），尝试下一候选: $e');
      continue;
    }
  }
  throw StateError(
    '语料不可用：请提供可读取的 .txt（GEN_DB_CORPUS，'
    '或使用默认 $kCorpusRfc / $kTxtRootUtf8 / $kTxtRoot）。',
  );
}

/// 为一个设备生成完整数据库（真实 keyring + 真实 storeNote 加密落盘）
Future<void> _generateOneDevice({
  required String outputDir,
  required String deviceName,
  required String password,
  required int noteCount,
  required String corpus,
  required Random rng,
}) async {
  // 0. 输出目录与文件路径（safenotes_sync.db 即客户端数据库文件名）
  //    注意：dbPath 必须是**绝对路径**——sqflite ffi 对相对路径会解析到
  //    getDatabasesPath() 默认目录，导致删目录清不掉旧文件、多次运行在同一
  //    文件累积旧 keyring 密文（新 keyring 解不开 → 验证解密失败）。
  final dir = Directory(outputDir);
  if (dir.existsSync()) {
    await dir.delete(recursive: true); // 覆盖旧生成
  }
  await dir.create(recursive: true);
  final dbPath = p.join(outputDir, 'safenotes_sync.db');

  // 1. 打开真实 SQLite 文件（schema v3，与生产一致；仅新建时执行 createDB）
  final db = await openDatabase(
    dbPath,
    version: 3,
    onCreate: NotesDatabase.createDBForTesting,
  );
  NotesDatabase.setDatabaseForTesting(db);

  // 2. 真实登录/初始化路径：Keyring.createNew 生成账本并写入 sync_meta
  //    （客户端首次设置密码时走的就是这个接口）
  final keyring = await Keyring.createNew(
    password: password,
    database: NotesDatabase.instance,
  );
  // 3. 注入 dataKey（客户端登录后 setDataKey 的真实行为）
  NotesDatabase.instance.setDataKey(keyring.dataKey);

  // 4. 用真实 storeNote 接口写入笔记（title/description 字段级加密）
  for (var i = 0; i < noteCount; i++) {
    final targetBytes = kMinBytes + rng.nextInt(kMaxBytes - kMinBytes + 1);
    final sample = _sampleNote(corpus, rng, targetBytes);
    final note = SafeNote.create(
      title: sample.title,
      description: sample.description,
    );
    await NotesDatabase.instance.storeNote(note);
  }

  // 5. 关闭落盘（真实 close）
  await NotesDatabase.instance.close();

  // 6. 验证：用真实登录路径重新打开（unlockLocal 解 keyring → setDataKey → 读），
  //    确认生成的库文件可被客户端直接解锁读取
  final reopened = await openDatabase(dbPath, version: 3);
  NotesDatabase.setDatabaseForTesting(reopened);
  final unlocked = await Keyring.unlockLocal(
    password: password,
    database: NotesDatabase.instance,
  );
  NotesDatabase.instance.setDataKey(unlocked.dataKey);
  final all = await NotesDatabase.instance.readAllNotes();
  await NotesDatabase.instance.close();

  final fileSize = File(dbPath).lengthSync();
  final sizes = all.map((n) => utf8.encode(n.title + n.description).length);
  // ignore: avoid_print
  print(
    '[GEN] $deviceName: 写入 ${all.length} 条 / 文件 ${(fileSize / 1024).toStringAsFixed(1)}KB'
    ' / 大小范围 ${sizes.reduce(min)}B~${sizes.reduce(max)}B'
    ' / 密码 "$password" / 路径 $dbPath',
  );
  if (all.length != noteCount) {
    fail('$deviceName 验证失败：期望 $noteCount 条，实际 ${all.length} 条');
  }
  // 乱码断言：任何笔记不得含 U+FFFD（转码替换符）或孤立代理
  final bad = all.where((n) {
    final text = n.title + n.description;
    if (text.contains('\uFFFD')) return true;
    for (final cu in text.codeUnits) {
      if (cu >= 0xD800 && cu <= 0xDFFF) return true; // 孤立代理（代理对已配对则不会被单独编码）
    }
    return false;
  }).toList();
  if (bad.isNotEmpty) {
    fail(
      '$deviceName 含乱码 ${bad.length} 条（U+FFFD/孤立代理），'
      '首条 title="${bad.first.title.substring(0, bad.first.title.length > 30 ? 30 : bad.first.title.length)}"',
    );
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit(); // 桌面端真实 sqlite3 ffi
    databaseFactory = databaseFactoryFfi;
  });

  test(
    '生成两个真实数据库（可复制替换客户端 safenotes_sync.db）',
    () async {
      // ── 参数（环境变量可覆盖）──
      final outRel = Platform.environment['GEN_DB_OUT'] ?? 'temp/generated-db';
      // 绝对化输出根目录（避免 ffi 相对路径解析到默认数据库目录）
      final outRoot = p.isAbsolute(outRel)
          ? outRel
          : p.join(Directory.current.path, outRel);
      final pwA = Platform.environment['GEN_DB_PASSWORD_A'] ?? 'safe-a-2026';
      final pwB = Platform.environment['GEN_DB_PASSWORD_B'] ?? 'safe-b-2026';
      final count =
          int.tryParse(Platform.environment['GEN_DB_COUNT'] ?? '') ?? 40;
      final seed =
          int.tryParse(Platform.environment['GEN_DB_SEED'] ?? '') ??
          DateTime.now().millisecondsSinceEpoch;
      // ignore: avoid_print
      print('[GEN] 参数: out=$outRoot count=$count seed=$seed');
      final rng = Random(seed);

      // ── 素材 ──
      final corpus = await _loadCorpus();

      // ── 设备 A / B（各自独立 keyring，vaultId/salt/dataKey/密码均不同）──
      await _generateOneDevice(
        outputDir: p.join(outRoot, 'deviceA'),
        deviceName: 'deviceA',
        password: pwA,
        noteCount: count,
        corpus: corpus,
        rng: rng,
      );
      await _generateOneDevice(
        outputDir: p.join(outRoot, 'deviceB'),
        deviceName: 'deviceB',
        password: pwB,
        noteCount: count,
        corpus: corpus,
        rng: rng,
      );

      // ignore: avoid_print
      print(
        '[GEN] 完成。将 deviceA/safenotes_sync.db、deviceB/safenotes_sync.db'
        ' 复制到客户端数据目录替换同名文件即可，'
        '分别用密码 "$pwA" / "$pwB" 登录。',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
