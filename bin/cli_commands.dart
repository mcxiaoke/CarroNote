// SafeNotes CLI 命令层（纯 Dart）。
//
// 用 package:args 的 CommandRunner/Command 命令树实现（标准解析，不手写 parser）。
// 每个叶子命令的 run() 返回输出字符串（main 统一打印），错误一律抛异常：
//   - CliException             → 用户可预期错误（打印消息，退出码 1）
//   - WrongPasswordException   → 密码错误（退出码 1）
//   - KeyringNotInitializedException → 未初始化 keyring（退出码 1）
//   - 其他异常                 → 崩溃（带堆栈，退出码 2）

// Dart 原生导入
import 'dart:convert';
import 'dart:io';

// Package 导入
import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:core/core.dart';
import 'package:path/path.dart' as p;

// 项目导入
import 'cli_context.dart';

/// 所有命令的公共基类：提供上下文引导与全局参数便捷访问。
///
/// 泛型取 `String?` 而非 `String`：叶子命令的 async run() 返回 `Future<String?>`
/// （可能不输出任何文本），只有 `Command<String?>` 才允许这种返回类型。
abstract class SafeNotesCommand extends Command<String?> {
  /// 当前子命令参数（叶子命令内非空）
  ArgResults get a => argResults!;

  /// 全局参数（--data-dir / --password / --password-file / --device-id）
  ArgResults get g => globalResults!;

  /// 从全局参数解析的解锁密码（可能为 null）
  String? get pw => resolveCliPassword(g);

  /// 引导 CLI 上下文并执行 [body]，finally 统一关闭资源（journal/backend/db）。
  ///
  /// 一条命令 = 一个进程，必须恢复完整状态并在退出前落盘日志与 journal。
  Future<String?> withCtx(Future<String?> Function(CliContext ctx) body) async {
    final ctx = await bootstrapCtx(g);
    try {
      return await body(ctx);
    } finally {
      await ctx.close();
    }
  }

  /// 确保已解锁并返回 keyring（需要密钥的命令统一走这里）
  Future<Keyring> unlocked(CliContext ctx) async {
    await ctx.ensureUnlocked(pw);
    return ctx.requireKeyring();
  }
}

// ──────────────────────────────────────────────
// 输出辅助
// ──────────────────────────────────────────────

String _iso(int ms) =>
    DateTime.fromMillisecondsSinceEpoch(ms).toIso8601String();

String _brief(String s, [int len = 8]) =>
    s.length > len ? s.substring(0, len) : s;

/// 笔记列表的单行格式（制表符分隔，便于脚本解析）
String _noteLine(SafeNote n) {
  final sb = StringBuffer()
    ..write(n.uuid)
    ..write('\t')
    ..write(_iso(n.updatedAt))
    ..write('\t')
    ..write(n.synced ? 'synced' : 'dirty')
    ..write('\t');
  if (n.deleted) sb.write('[已删除] ');
  sb.write(n.title);
  return sb.toString();
}

/// 按 ref 解析笔记：优先 uuid，其次 id。
Future<SafeNote> _resolveNote(CliContext ctx, String ref) async {
  final db = ctx.database;
  final byUuid = await db.readNoteByUuid(ref);
  if (byUuid != null) return byUuid;
  final id = int.tryParse(ref);
  if (id != null) {
    try {
      return await db.readNote(id);
    } on Object {
      // 落到统一的「未找到」错误
    }
  }
  throw CliException('未找到笔记: $ref');
}

// ──────────────────────────────────────────────
// 命令组：db
// ──────────────────────────────────────────────

class DbCommand extends SafeNotesCommand {
  DbCommand() {
    addSubcommand(DbInfoCommand());
    addSubcommand(DbWipeCommand());
  }

  @override
  String get name => 'db';

  @override
  String get description => '数据库信息与销毁';
}

class DbInfoCommand extends SafeNotesCommand {
  @override
  String get name => 'info';

  @override
  String get description => '显示数据库 schema 与统计信息';

  @override
  Future<String?> run() => withCtx((ctx) async {
    await unlocked(ctx);
    final db = await ctx.database.database;
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
    );
    final notes = await ctx.database.readAllNotesIncludingDeleted();
    final deleted = notes.where((n) => n.deleted).length;
    final keyringInit = await ctx.isKeyringInitialized();
    final b = StringBuffer()
      ..writeln('数据目录: ${ctx.dataDir}')
      ..writeln('数据库已打开: ${db.isOpen}')
      ..writeln('设备 ID: ${ctx.deviceId}')
      ..writeln('keyring 已初始化: $keyringInit')
      ..writeln('笔记总数(含回收站): ${notes.length}')
      ..writeln('回收站(墓碑): $deleted')
      ..writeln('表: ${tables.map((r) => r['name']).join(', ')}');
    return b.toString();
  });
}

class DbWipeCommand extends SafeNotesCommand {
  DbWipeCommand() {
    argParser.addFlag('yes', abbr: 'y', help: '跳过确认（危险操作必须携带）');
  }

  @override
  String get name => 'wipe';

  @override
  String get description => '删除数据库文件与 journal（不可恢复）';

  @override
  Future<String?> run() => withCtx((ctx) async {
    if (!(a['yes'] as bool)) {
      throw CliException('危险操作，需确认：db wipe --yes');
    }
    await ctx.database.close();
    await ctx.database.deleteDbFile();
    final journalDir = Directory(p.join(ctx.dataDir, 'journal'));
    if (journalDir.existsSync()) await journalDir.delete(recursive: true);
    return '已删除数据库文件与 journal（数据目录内容清空）';
  });
}

// ──────────────────────────────────────────────
// 命令组：keyring
// ──────────────────────────────────────────────

class KeyringCommand extends SafeNotesCommand {
  KeyringCommand() {
    addSubcommand(KeyringInitCommand());
    addSubcommand(KeyringUnlockCommand());
    addSubcommand(KeyringStatusCommand());
    addSubcommand(KeyringVerifyCommand());
    addSubcommand(KeyringChangePasswordCommand());
  }

  @override
  String get name => 'keyring';

  @override
  String get description => '密钥管理（初始化 / 解锁 / 改密码）';
}

class KeyringInitCommand extends SafeNotesCommand {
  KeyringInitCommand() {
    argParser.addFlag('json', help: '机器可读输出');
  }

  @override
  String get name => 'init';

  @override
  String get description => '首次设置密码并创建 keyring';

  @override
  Future<String?> run() => withCtx((ctx) async {
    final k = await ctx.keyringInit(pw ?? '');
    if (a['json'] as bool) {
      return jsonEncode({
        'vaultId': k.vaultId,
        'keyVersion': k.keyVersion,
        'dataKeyEpoch': k.dataKeyEpoch,
        'keyFingerprint': k.keyFingerprint,
        'initialized': true,
      });
    }
    return 'keyring 已初始化: vaultId=${k.vaultId} '
        'keyVersion=${k.keyVersion} epoch=${k.dataKeyEpoch} '
        'fp=${_brief(k.keyFingerprint)}';
  });
}

class KeyringUnlockCommand extends SafeNotesCommand {
  KeyringUnlockCommand() {
    argParser.addFlag('json', help: '机器可读输出');
  }

  @override
  String get name => 'unlock';

  @override
  String get description => '用密码解锁本地 keyring（解锁后可读写笔记）';

  @override
  Future<String?> run() => withCtx((ctx) async {
    final k = await ctx.unlock(pw ?? '');
    if (a['json'] as bool) {
      return jsonEncode({
        'vaultId': k.vaultId,
        'keyVersion': k.keyVersion,
        'dataKeyEpoch': k.dataKeyEpoch,
        'unlocked': true,
      });
    }
    return '解锁成功: vaultId=${k.vaultId} '
        'keyVersion=${k.keyVersion} epoch=${k.dataKeyEpoch} '
        'fp=${_brief(k.keyFingerprint)}';
  });
}

class KeyringStatusCommand extends SafeNotesCommand {
  @override
  String get name => 'status';

  @override
  String get description => '显示 keyring 状态（不需要密码）';

  @override
  Future<String?> run() => withCtx((ctx) async {
    final init = await ctx.isKeyringInitialized();
    final b = StringBuffer()..writeln('已初始化: $init');
    if (init) {
      final ledger = await KeyringLedger.load(ctx.database);
      if (ledger != null) {
        final e = ledger.current;
        b
          ..writeln('vaultId: ${ledger.vaultId}')
          ..writeln('keyVersion: ${e.keyVersion}')
          ..writeln('dataKeyEpoch: ${e.dataKeyEpoch}')
          ..writeln('keyFingerprint: ${e.keyFingerprint}')
          ..writeln('reason: ${e.reason}')
          ..writeln('createdAt: ${_iso(ledger.createdAt)}')
          ..writeln('当前已解锁: ${ctx.keyring != null}');
      } else {
        b.writeln('账本损坏（将视为未初始化）');
      }
    }
    return b.toString().trimRight();
  });
}

class KeyringVerifyCommand extends SafeNotesCommand {
  @override
  String get name => 'verify';

  @override
  String get description => '校验密码是否正确（不改任何状态）';

  @override
  Future<String?> run() => withCtx((ctx) async {
    await ctx.verifyPassword(pw ?? '');
    return '密码正确';
  });
}

class KeyringChangePasswordCommand extends SafeNotesCommand {
  KeyringChangePasswordCommand() {
    argParser
      ..addOption('old', help: '旧密码', hide: false)
      ..addOption('new', help: '新密码', hide: false)
      ..addFlag('json', help: '机器可读输出');
  }

  @override
  String get name => 'change-password';

  @override
  String get description => '修改同步密码（dataKey 不变，O(1) 不重加密笔记）';

  @override
  Future<String?> run() => withCtx((ctx) async {
    final oldPw = a['old'] as String?;
    final newPw = a['new'] as String?;
    if (oldPw == null || oldPw.isEmpty || newPw == null || newPw.isEmpty) {
      throw CliException('需要 --old 与 --new 两个密码参数');
    }
    if (oldPw == newPw) {
      throw CliException('新密码不能与旧密码相同');
    }
    final k = await ctx.changePassword(oldPassword: oldPw, newPassword: newPw);
    if (a['json'] as bool) {
      return jsonEncode({
        'vaultId': k.vaultId,
        'keyVersion': k.keyVersion,
        'dataKeyEpoch': k.dataKeyEpoch,
        'changed': true,
      });
    }
    return '改密码完成: keyVersion=${k.keyVersion} '
        'epoch=${k.dataKeyEpoch} fp=${_brief(k.keyFingerprint)}';
  });
}

// ──────────────────────────────────────────────
// 命令组：note
// ──────────────────────────────────────────────

class NoteCommand extends SafeNotesCommand {
  NoteCommand() {
    addSubcommand(NoteAddCommand());
    addSubcommand(NoteListCommand());
    addSubcommand(NoteGetCommand());
    addSubcommand(NoteUpdateCommand());
    addSubcommand(NoteDeleteCommand());
    addSubcommand(NoteRestoreCommand());
    addSubcommand(NoteHardDeleteCommand());
    addSubcommand(NotePurgeDeletedCommand());
  }

  @override
  String get name => 'note';

  @override
  String get description => '笔记增删改查';
}

class NoteAddCommand extends SafeNotesCommand {
  NoteAddCommand() {
    argParser
      ..addOption('title', help: '标题')
      ..addOption('body', help: '正文')
      ..addOption('file', help: '从文件读取正文')
      ..addFlag('json', help: '机器可读输出');
  }

  @override
  String get name => 'add';

  @override
  String get description => '新建笔记（需要解锁）';

  @override
  Future<String?> run() => withCtx((ctx) async {
    await unlocked(ctx);
    final title = a['title'] as String? ?? '';
    var body = a['body'] as String? ?? '';
    final file = a['file'] as String?;
    if (file != null && file.isNotEmpty) {
      body = await File(file).readAsString();
    }
    if (title.isEmpty && body.isEmpty) {
      throw CliException('需要 --title 或 --body');
    }
    final note = SafeNote.create(title: title, description: body);
    final stored = await ctx.database.storeNote(note);
    if (a['json'] as bool) {
      return jsonEncode({'uuid': stored.uuid, 'id': stored.id});
    }
    return '已创建笔记: uuid=${stored.uuid} id=${stored.id} '
        'hash=${_brief(stored.contentHash)}';
  });
}

class NoteListCommand extends SafeNotesCommand {
  NoteListCommand() {
    argParser
      ..addOption('limit', help: '最多输出条数')
      ..addOption('query', help: '按标题/正文子串过滤（忽略大小写）')
      ..addFlag('deleted', help: '包含回收站笔记')
      ..addFlag('json', help: '机器可读输出');
  }

  @override
  String get name => 'list';

  @override
  String get description => '列出笔记（按更新时间倒序）';

  @override
  Future<String?> run() => withCtx((ctx) async {
    await unlocked(ctx);
    final db = ctx.database;
    var notes = (a['deleted'] as bool)
        ? await db.readAllNotesIncludingDeleted()
        : await db.readAllNotes();
    notes = notes.toList()..sort((x, y) => y.updatedAt.compareTo(x.updatedAt));
    final query = (a['query'] as String?)?.toLowerCase();
    if (query != null && query.isNotEmpty) {
      notes = notes
          .where(
            (n) =>
                n.title.toLowerCase().contains(query) ||
                n.description.toLowerCase().contains(query),
          )
          .toList();
    }
    final limit = int.tryParse(a['limit'] as String? ?? '');
    if (limit != null && limit > 0 && notes.length > limit) {
      notes = notes.sublist(0, limit);
    }
    if (a['json'] as bool) {
      return jsonEncode(notes.map((n) => n.toJson()).toList());
    }
    final b = StringBuffer()..writeln('共 ${notes.length} 条:');
    for (final n in notes) {
      b.writeln(_noteLine(n));
    }
    return b.toString().trimRight();
  });
}

class NoteGetCommand extends SafeNotesCommand {
  NoteGetCommand() {
    argParser.addFlag('json', help: '机器可读输出');
  }

  @override
  String get name => 'get';

  @override
  String get description => '查看单条笔记内容';

  @override
  Future<String?> run() => withCtx((ctx) async {
    await unlocked(ctx);
    final note = await _resolveNote(ctx, a.rest.join(' ').trim());
    if (a['json'] as bool) return jsonEncode(note.toJson());
    final b = StringBuffer()
      ..writeln('标题: ${note.title}')
      ..writeln('---')
      ..writeln(note.description)
      ..writeln('---')
      ..writeln(
        'uuid=${note.uuid} id=${note.id} '
        'hash=${_brief(note.contentHash, 12)}',
      )
      ..writeln(
        'created=${_iso(note.createdTime.millisecondsSinceEpoch)} '
        'updated=${_iso(note.updatedAt)} '
        'synced=${note.synced ? "是" : "否"} '
        'deleted=${note.deleted ? "是" : "否"}',
      );
    return b.toString();
  });
}

class NoteUpdateCommand extends SafeNotesCommand {
  NoteUpdateCommand() {
    argParser
      ..addOption('title', help: '新标题')
      ..addOption('body', help: '新正文')
      ..addOption('file', help: '从文件读取新正文')
      ..addFlag('json', help: '机器可读输出');
  }

  @override
  String get name => 'update';

  @override
  String get description => '编辑笔记（修改后标记未同步，可被 LWW 正常合并）';

  @override
  Future<String?> run() => withCtx((ctx) async {
    await unlocked(ctx);
    final ref = a.rest.join(' ').trim();
    if (ref.isEmpty) throw CliException('需要笔记 ref（uuid 或 id）');
    final original = await _resolveNote(ctx, ref);

    final newTitle = a['title'] as String?;
    var newBody = a['body'] as String?;
    final file = a['file'] as String?;
    if (file != null && file.isNotEmpty) {
      newBody = await File(file).readAsString();
    }
    if (newTitle == null && newBody == null) {
      throw CliException('需要 --title 或 --body');
    }
    // 与 App editor_state.updateNote 完全一致的语义：
    // 重算 hash、时间戳置现在、synced=false，保留 syncedHash/syncedDeleted 基线
    final now = DateTime.now();
    final updated = original.copyWith(
      title: newTitle ?? original.title,
      description: newBody ?? original.description,
      contentHash: SafeNote.computeHash(
        newTitle ?? original.title,
        newBody ?? original.description,
      ),
      updatedAt: now.millisecondsSinceEpoch,
      synced: false,
    );
    await ctx.database.updateNoteByUuid(updated);
    if (a['json'] as bool) return jsonEncode(updated.toJson());
    return '已更新笔记: uuid=${updated.uuid} '
        'hash=${_brief(updated.contentHash, 12)}';
  });
}

class NoteDeleteCommand extends SafeNotesCommand {
  @override
  String get name => 'delete';

  @override
  String get description => '软删除（移入回收站，可恢复，可同步）';

  @override
  Future<String?> run() => withCtx((ctx) async {
    await unlocked(ctx);
    final note = await _resolveNote(ctx, a.rest.join(' ').trim());
    await ctx.database.softDelete(note.id!);
    return '已软删除笔记: uuid=${note.uuid}';
  });
}

class NoteRestoreCommand extends SafeNotesCommand {
  @override
  String get name => 'restore';

  @override
  String get description => '从回收站恢复笔记';

  @override
  Future<String?> run() => withCtx((ctx) async {
    await unlocked(ctx);
    final note = await _resolveNote(ctx, a.rest.join(' ').trim());
    await ctx.database.restoreNote(note.id!);
    return '已恢复笔记: uuid=${note.uuid}';
  });
}

class NoteHardDeleteCommand extends SafeNotesCommand {
  NoteHardDeleteCommand() {
    argParser.addFlag('yes', abbr: 'y', help: '跳过确认（不可恢复）');
  }

  @override
  String get name => 'hard-delete';

  @override
  String get description => '永久删除（不可恢复）';

  @override
  Future<String?> run() => withCtx((ctx) async {
    await unlocked(ctx);
    if (!(a['yes'] as bool)) {
      throw CliException('危险操作，需确认：note hard-delete <ref> --yes');
    }
    final note = await _resolveNote(ctx, a.rest.join(' ').trim());
    await ctx.database.hardDelete(note.id!);
    return '已永久删除笔记: uuid=${note.uuid}';
  });
}

class NotePurgeDeletedCommand extends SafeNotesCommand {
  NotePurgeDeletedCommand() {
    argParser.addFlag('yes', abbr: 'y', help: '跳过确认（不可恢复）');
  }

  @override
  String get name => 'purge-deleted';

  @override
  String get description => '清空回收站（永久删除全部墓碑）';

  @override
  Future<String?> run() => withCtx((ctx) async {
    await unlocked(ctx);
    if (!(a['yes'] as bool)) {
      throw CliException('危险操作，需确认：note purge-deleted --yes');
    }
    final deleted = await ctx.database.readDeletedNotes();
    for (final n in deleted) {
      await ctx.database.hardDelete(n.id!);
    }
    return '已清空回收站: 永久删除 ${deleted.length} 条';
  });
}

// ──────────────────────────────────────────────
// 命令：export / import
// ──────────────────────────────────────────────

class ExportCommand extends SafeNotesCommand {
  ExportCommand() {
    argParser.addOption('out', help: '输出文件路径（默认 <data-dir>/backup.json）');
  }

  @override
  String get name => 'export';

  @override
  String get description => '导出明文备份（records/plaintext-v1 格式，与 App 兼容）';

  @override
  Future<String?> run() => withCtx((ctx) async {
    await unlocked(ctx);
    final notes = await ctx.database.readAllNotes();
    final out = a['out'] as String? ?? p.join(ctx.dataDir, 'backup.json');
    final record = jsonEncode(notes.map((n) => n.toJson()).toList());
    final content =
        '{ "records" : $record, '
        '"recordHandlerHash" : "plaintext-v1", '
        '"total" : ${notes.length} }';
    await File(out).writeAsString(content, flush: true);
    return '已导出 ${notes.length} 条笔记 → $out';
  });
}

class ImportCommand extends SafeNotesCommand {
  ImportCommand() {
    argParser
      ..addOption('in', help: '导入文件路径（必须）')
      ..addFlag('json', help: '机器可读输出');
  }

  @override
  String get name => 'import';

  @override
  String get description => '从备份文件导入笔记（与 App FileHandler 同解析逻辑）';

  @override
  Future<String?> run() => withCtx((ctx) async {
    await unlocked(ctx);
    final path = a['in'] as String?;
    if (path == null || path.isEmpty) throw CliException('需要 --in <文件>');
    final file = File(path);
    if (!file.existsSync()) throw CliException('文件不存在: $path');
        final parsed = ImportParser.fromJson(
          jsonDecode(await file.readAsString()) as Map<String, dynamic>,
        );
        // 幂等导入：已存在同 uuid 的笔记跳过（App 直接 storeNote 会 UNIQUE 冲突，
        // CLI 作为测试工具改为跳过，便于重复导入 / 恢复流程验证）。
        var imported = 0;
        var skipped = 0;
        for (final note in parsed.getAllNotes()) {
          final exists = await ctx.database.readNoteByUuid(note.uuid);
          if (exists != null) {
            skipped++;
            continue;
          }
          await ctx.database.storeNote(note);
          imported++;
        }
        if (a['json'] as bool) {
          return jsonEncode({
            'imported': imported,
            'skipped': skipped,
            'countMismatch': parsed.isNoteCountMissmatched,
          });
        }
        return '已导入 $imported 条笔记（跳过已存在 $skipped 条）'
            '${parsed.isNoteCountMissmatched ? '（数量与备份不一致，请核对）' : ''}';
  });
}

// ──────────────────────────────────────────────
// 命令组：sync
// ──────────────────────────────────────────────

class SyncCommand extends SafeNotesCommand {
  SyncCommand() {
    addSubcommand(SyncSetupCommand());
    addSubcommand(SyncRunCommand());
    addSubcommand(SyncRepairCommand());
    addSubcommand(SyncStatusCommand());
  }

  @override
  String get name => 'sync';

  @override
  String get description => '同步配置与执行';
}

class SyncSetupCommand extends SafeNotesCommand {
  SyncSetupCommand() {
    argParser
      ..addOption('type', help: 'localfs | webdav | safeserver | none')
      ..addOption('path', help: 'localfs 后端根目录')
      ..addOption('url', help: 'webdav / safeserver 服务地址')
      ..addOption('username', help: 'webdav 用户名')
      ..addOption('backend-password', help: 'webdav 密码（写 credentials 文件）')
      ..addOption('backend-token', help: 'safeserver Token（写 credentials 文件）');
  }

  @override
  String get name => 'setup';

  @override
  String get description => '配置同步后端（敏感凭据不入 SQLite）';

  @override
  Future<String?> run() => withCtx((ctx) async {
    final type = a['type'] as String? ?? '';
    switch (type) {
      case CliBackendType.none:
        await ctx.clearBackendConfig();
        return '已清除同步后端配置';
      case CliBackendType.localFs:
        final path = a['path'] as String?;
        if (path == null || path.isEmpty) {
          throw CliException('localfs 需要 --path <根目录>');
        }
        await ctx.saveBackendConfig(type: type, localFsPath: path);
        return '已配置 localfs 后端: $path';
      case CliBackendType.webdav:
        final url = a['url'] as String?;
        final user = a['username'] as String?;
        if (url == null || url.isEmpty || user == null || user.isEmpty) {
          throw CliException('webdav 需要 --url 与 --username');
        }
        await ctx.saveBackendConfig(
          type: type,
          webdavUrl: url,
          webdavUsername: user,
        );
        await ctx.writeCredentials(
          webdavPassword: a['backend-password'] as String?,
        );
        return '已配置 webdav 后端: $user@$url';
      case CliBackendType.safeServer:
        final url = a['url'] as String?;
        if (url == null || url.isEmpty) {
          throw CliException('safeserver 需要 --url');
        }
        await ctx.saveBackendConfig(type: type, safeServerUrl: url);
        await ctx.writeCredentials(
          safeServerToken: a['backend-token'] as String?,
        );
        return '已配置 safeserver 后端: $url';
      default:
        throw CliException('未知后端类型: $type（localfs/webdav/safeserver/none）');
    }
  });
}

class SyncRunCommand extends SafeNotesCommand {
  SyncRunCommand() {
    argParser
      ..addOption('backend-password', help: 'webdav 密码（覆盖凭据文件/环境变量）')
      ..addOption('backend-token', help: 'safeserver Token（覆盖凭据文件/环境变量）')
      ..addFlag('json', help: '机器可读输出');
  }

  @override
  String get name => 'run';

  @override
  String get description => '执行一次同步（需要解锁 + 已配置后端）';

  @override
  Future<String?> run() => withCtx((ctx) async {
    await unlocked(ctx);
    final result = await ctx.sync(
      webdavPassword: a['backend-password'] as String?,
      safeServerToken: a['backend-token'] as String?,
    );
    return _formatSyncResult(result, json: a['json'] as bool);
  });
}

class SyncRepairCommand extends SafeNotesCommand {
  SyncRepairCommand() {
    argParser
      ..addOption('backend-password', help: 'webdav 密码（覆盖凭据文件/环境变量）')
      ..addOption('backend-token', help: 'safeserver Token（覆盖凭据文件/环境变量）')
      ..addFlag('json', help: '机器可读输出');
  }

  @override
  String get name => 'repair';

  @override
  String get description => '全面校验并修复远端数据（对齐 App「修复同步数据」）';

  @override
  Future<String?> run() => withCtx((ctx) async {
    await unlocked(ctx);
    final result = await ctx.repairRemote(
      webdavPassword: a['backend-password'] as String?,
      safeServerToken: a['backend-token'] as String?,
    );
    return _formatSyncResult(result, json: a['json'] as bool);
  });
}

class SyncStatusCommand extends SafeNotesCommand {
  @override
  String get name => 'status';

  @override
  String get description => '显示同步配置与远端状态（不需要密码）';

  @override
  Future<String?> run() => withCtx((ctx) async {
    final db = ctx.database;
    final type = await db.getMeta(CliConfigKeys.backendType);
    final providerKey = await ctx.backendProviderKey();
    final manifestVersion = providerKey == null
        ? null
        : await db.getManifestVersion(providerKey);
    final b = StringBuffer()
      ..writeln('设备 ID: ${ctx.deviceId}')
      ..writeln('后端类型: ${type ?? "(未配置)"}');
    if (providerKey != null) b.writeln('providerKey: $providerKey');
    if (manifestVersion != null) {
      b.writeln('manifest version: $manifestVersion');
    }
    switch (type) {
      case CliBackendType.localFs:
        b.writeln('后端路径: ${await db.getMeta(CliConfigKeys.localFsPath)}');
      case CliBackendType.webdav:
        b.writeln('URL: ${await db.getMeta(CliConfigKeys.webdavUrl)}');
        b.writeln('用户名: ${await db.getMeta(CliConfigKeys.webdavUsername)}');
      case CliBackendType.safeServer:
        b.writeln('URL: ${await db.getMeta(CliConfigKeys.safeServerUrl)}');
    }
    return b.toString().trimRight();
  });
}

/// 把 SyncResult 格式化为文本 / JSON；失败抛 CliException。
String _formatSyncResult(SyncResult r, {required bool json}) {
  if (!r.success) {
    final msg =
        '同步失败: ${r.errorMessage}'
        '${r.requiresRelogin ? '（需要重新登录）' : ''}';
    throw CliException(msg);
  }
  if (json) {
    return jsonEncode({
      'success': true,
      'uploaded': r.uploaded,
      'downloaded': r.downloaded,
      'deleted': r.deleted,
      'conflicts': r.conflicts,
      'skipped': r.skipped,
      'migrated': r.migrated,
      'requiresRelogin': r.requiresRelogin,
      'actions': [
        for (final act in r.actions)
          {
            'type': act.type.name,
            'uuid': act.uuid,
            'message': act.displayMessage,
          },
      ],
      'failedNoteUuids': r.failedNoteUuids,
    });
  }
  final b = StringBuffer()
    ..writeln(
      '同步完成: 上传=${r.uploaded} 下载=${r.downloaded} '
      '删除=${r.deleted} 冲突=${r.conflicts} 跳过=${r.skipped} '
      '迁移=${r.migrated} (attempt=${r.attempts})',
    );
  for (final act in r.actions) {
    b.writeln(
      '  [${act.type.name}] ${_brief(act.uuid)}'
      '${act.displayMessage.isEmpty ? '' : '  ${act.displayMessage}'}',
    );
  }
  if (r.failedNoteUuids.isNotEmpty) {
    b.writeln(
      '注意: ${r.failedNoteUuids.length} 条笔记未能同步'
      '${r.requiresRelogin ? '，需要重新登录' : ''}',
    );
  }
  return b.toString().trimRight();
}

// ──────────────────────────────────────────────
// 命令组：log / journal
// ──────────────────────────────────────────────

class LogCommand extends SafeNotesCommand {
  LogCommand() {
    addSubcommand(LogCatCommand());
    addSubcommand(LogPathCommand());
  }

  @override
  String get name => 'log';

  @override
  String get description => '运行日志查看';
}

class LogPathCommand extends SafeNotesCommand {
  @override
  String get name => 'path';

  @override
  String get description => '显示日志目录路径';

  @override
  Future<String?> run() => withCtx((ctx) async {
    final path = await AppLogFile.currentPath();
    return '日志目录: ${AppLogFile.dirPath}\n当前日志: ${path ?? "(无)"}';
  });
}

class LogCatCommand extends SafeNotesCommand {
  LogCatCommand() {
    argParser.addOption('tail', help: '只显示最后 N 行（默认 200）');
  }

  @override
  String get name => 'cat';

  @override
  String get description => '输出日志文件内容（尾部）';

  @override
  Future<String?> run() => withCtx((ctx) async {
    final path = await AppLogFile.currentPath();
    if (path == null || !File(path).existsSync()) {
      return '(日志文件尚未生成)';
    }
    final lines = await File(path).readAsLines();
    final tail = int.tryParse(a['tail'] as String? ?? '') ?? 200;
    final start = tail > 0 && lines.length > tail ? lines.length - tail : 0;
    return lines.sublist(start).join('\n');
  });
}

class JournalCommand extends SafeNotesCommand {
  JournalCommand() {
    addSubcommand(JournalCatCommand());
    addSubcommand(JournalStatusCommand());
  }

  @override
  String get name => 'journal';

  @override
  String get description => '同步操作日志查看';
}

class JournalStatusCommand extends SafeNotesCommand {
  @override
  String get name => 'status';

  @override
  String get description => '显示 journal 统计';

  @override
  Future<String?> run() => withCtx((ctx) async {
    final vaultId = await Keyring.getVaultId(ctx.database);
    if (vaultId == null) return 'keyring 未初始化，无 journal';
    final j = await Journal.open(
      baseDir: ctx.dataDir,
      vaultId: vaultId,
      deviceId: ctx.deviceId,
    );
    try {
      final entries = await j.readAll();
      return 'journal 目录: ${j.dirPath}\n'
          '总条目: ${entries.length}\n'
          'nextSeq: ${j.nextSeq}\n'
          'pending: ${j.pendingCount}';
    } finally {
      await j.close();
    }
  });
}

class JournalCatCommand extends SafeNotesCommand {
  JournalCatCommand() {
    argParser
      ..addOption('tail', help: '只显示最后 N 条（默认全部）')
      ..addFlag('json', help: '机器可读输出');
  }

  @override
  String get name => 'cat';

  @override
  String get description => '输出 journal 条目（审计 + 排障）';

  @override
  Future<String?> run() => withCtx((ctx) async {
    final vaultId = await Keyring.getVaultId(ctx.database);
    if (vaultId == null) return 'keyring 未初始化，无 journal';
    final j = await Journal.open(
      baseDir: ctx.dataDir,
      vaultId: vaultId,
      deviceId: ctx.deviceId,
    );
    try {
      var entries = await j.readAll();
      final tail = int.tryParse(a['tail'] as String? ?? '');
      if (tail != null && tail > 0 && entries.length > tail) {
        entries = entries.sublist(entries.length - tail);
      }
      if (a['json'] as bool) {
        return jsonEncode(entries.map((e) => e.toJson()).toList());
      }
      final b = StringBuffer();
      for (final e in entries) {
        b.writeln(
          '#${e.seq} ${_iso(e.ts)} ${e.type.wire}'
          '${e.phase.wire == "none" ? '' : '/${e.phase.wire}'}'
          '${e.uuid == null ? '' : ' uuid=${_brief(e.uuid!)}'}'
          '${e.hash == null ? '' : ' hash=${_brief(e.hash!)}'}'
          '${e.dataKeyEpoch == null ? '' : ' epoch=${e.dataKeyEpoch}'}'
          ' by=${_brief(e.by)}'
          '${e.note == null ? '' : ' ${e.note}'}',
        );
      }
      return b.toString().trimRight();
    } finally {
      await j.close();
    }
  });
}

// ──────────────────────────────────────────────
// 命令组：meta
// ──────────────────────────────────────────────

class MetaCommand extends SafeNotesCommand {
  MetaCommand() {
    addSubcommand(MetaListCommand());
    addSubcommand(MetaGetCommand());
    addSubcommand(MetaSetCommand());
  }

  @override
  String get name => 'meta';

  @override
  String get description => 'sync_meta 键值操作（调试用）';
}

class MetaListCommand extends SafeNotesCommand {
  @override
  String get name => 'list';

  @override
  String get description => '列出 meta 键';

  @override
  Future<String?> run() => withCtx((ctx) async {
    final db = await ctx.database.database;
    final rows = await db.query('sync_meta', columns: ['key', 'value']);
    final b = StringBuffer();
    for (final r in rows) {
      final value = (r['value'] as String?) ?? '';
      b.writeln('${r['key']}\t${value.length} 字节\t$value');
    }
    b.writeln('共 ${rows.length} 个键');
    return b.toString().trimRight();
  });
}

class MetaGetCommand extends SafeNotesCommand {
  @override
  String get name => 'get';

  @override
  String get description => '读取单个 meta 键';

  @override
  Future<String?> run() => withCtx((ctx) async {
    final key = a.rest.join(' ').trim();
    if (key.isEmpty) throw CliException('需要 meta 键名');
    final value = await ctx.database.getMeta(key);
    return value ?? '(不存在)';
  });
}

class MetaSetCommand extends SafeNotesCommand {
  @override
  String get name => 'set';

  @override
  String get description => '写入单个 meta 键（谨慎，可能破坏状态）';

  @override
  Future<String?> run() => withCtx((ctx) async {
    final args = a.rest;
    if (args.length < 2) throw CliException('用法: meta set <key> <value>');
    await ctx.database.setMeta(args[0], args.sublist(1).join(' '));
    return '已写入 meta: ${args[0]}';
  });
}

// ──────────────────────────────────────────────
// 命令装配入口
// ──────────────────────────────────────────────

/// 构造完整的 CommandRunner 命令树。
CommandRunner<String?> buildCliRunner() {
  final runner = CommandRunner<String?>(
    'safenotes-cli',
    'SafeNotes 核心逻辑 CLI —— 纯 Dart 驱动的真实流程测试 / 互操作验证入口。',
  );
  runner.argParser
    ..addOption(
      'data-dir',
      defaultsTo: 'temp/cli-data',
      help: '数据目录（一个目录 = 一台设备实例）',
    )
    ..addOption('password', help: '解锁密码（交互式终端用）')
    ..addOption('password-file', help: '从文件首行读取解锁密码（自动化推荐）')
    ..addOption('device-id', help: '设备 ID 覆盖（默认自动生成并持久化）');
  runner
    ..addCommand(DbCommand())
    ..addCommand(KeyringCommand())
    ..addCommand(NoteCommand())
    ..addCommand(ExportCommand())
    ..addCommand(ImportCommand())
    ..addCommand(SyncCommand())
    ..addCommand(LogCommand())
    ..addCommand(JournalCommand())
    ..addCommand(MetaCommand());
  return runner;
}
