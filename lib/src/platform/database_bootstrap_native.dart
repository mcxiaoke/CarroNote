// lib/src/platform/database_bootstrap_native.dart
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:safenotes/utils/platform_ui.dart';

Future<void> initDatabaseForPlatform({String? dataDirOverride}) async {
  if (isDesktopPlatform) {
    sqfliteFfiInit();
    databaseFactoryOrNull = databaseFactoryFfi;
    final dbDir =
        dataDirOverride ?? (await getApplicationSupportDirectory()).path;
    await databaseFactory.setDatabasesPath(dbDir);
  }
}
