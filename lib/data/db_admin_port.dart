// NotesDbAdminPort 窄端口接口：数据库管理操作
//
// 设计目标：将数据库管理操作（检查器、备份、逃生通道）从 NotesRepository
// 中分离出来，形成窄接口，仅被 DB 检查器、备份、忘记密码三个屏使用。
//
// §4.2 交付物：
//   - NotesDbAdminPort（抽象接口）
//   - NotesDbAdminAdapter（真实实现，委托给 NotesDatabase.instance）
//   - FakeNotesDbAdminPort（内存实现，用于测试）

// Package imports:
import 'package:core/core.dart';
import 'package:sqflite_common/sqlite_api.dart';

/// 数据库管理窄端口接口。
///
/// 仅被 DB 检查器、备份、忘记密码三个屏使用。
/// 不继承 ChangeNotifier——管理操作不需要响应式更新。
abstract class NotesDbAdminPort {
  /// 获取原始数据库句柄。
  Future<Database> get database;

  /// 查询指定表的前 [limit] 行数据（DB Inspector 展示用）。
  Future<List<Map<String, dynamic>>> queryTableRows(
    String table, {
    int limit = 100,
  });

  /// 返回本地库结构元数据（表清单、行数、列 schema、文件信息）。
  Future<Map<String, dynamic>> inspectMetadata();

  /// 导出所有笔记为 JSON 字符串（明文，已解密）。
  Future<String> exportAll();

  /// 关闭数据库连接。
  Future<void> close();

  /// 返回当前数据库文件的绝对路径。
  Future<String> dbFilePath();

  /// 删除数据库文件（忘记密码逃生通道使用）。
  Future<void> deleteDbFile();
}

/// 真实实现：委托给 [NotesDatabase.instance]。
class NotesDbAdminAdapter extends NotesDbAdminPort {
  @override
  Future<Database> get database => NotesDatabase.instance.database;

  @override
  Future<List<Map<String, dynamic>>> queryTableRows(
    String table, {
    int limit = 100,
  }) => NotesDatabase.instance.queryTableRows(table, limit: limit);

  @override
  Future<Map<String, dynamic>> inspectMetadata() =>
      NotesDatabase.instance.inspectMetadata();

  @override
  Future<String> exportAll() => NotesDatabase.instance.exportAll();

  @override
  Future<void> close() => NotesDatabase.instance.close();

  @override
  Future<String> dbFilePath() => NotesDatabase.instance.dbFilePath();

  @override
  Future<void> deleteDbFile() => NotesDatabase.instance.deleteDbFile();
}

