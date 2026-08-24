// lib/src/platform/database_bootstrap_web.dart
import 'package:sqflite_common/sqflite.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

Future<void> initDatabaseForPlatform({String? dataDirOverride}) async {
  // 使用 NoWebWorker 模式：直接在主线程加载 sqlite3.wasm 并挂载 IndexedDB 文件系统，
  // 零通信开销，100% 兼容所有现代浏览器环境（包括各类 Debug 服务器与无头模式）。
  databaseFactory = databaseFactoryFfiWebNoWebWorker;
}
