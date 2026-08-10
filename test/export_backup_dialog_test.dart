// 导出面板（ExportBackupDialog）widget 测试
//
// 覆盖：加密/明文二选一、密码确认、空/不一致密码按钮禁用、
//       明文模式隐藏密码框、提交返回 ExportOptions。

// Dart imports:
import 'dart:convert';
import 'dart:io';

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Project imports:
import 'package:safenotes/dialogs/export_backup_dialog.dart';

/// widget 测试的 asset bundle 并不提供项目翻译文件，这里直接从磁盘
/// 读取 JSON 供 EasyLocalization 加载（flutter test 的 CWD 是包根目录）。
class _TestAssetLoader extends AssetLoader {
  @override
  Future<Map<String, dynamic>?> load(String path, Locale locale) async {
    final code = locale.countryCode == null
        ? locale.languageCode
        : '${locale.languageCode}-${locale.countryCode}';
    final map = jsonDecode(await File('$path/$code.json').readAsString());
    return map as Map<String, dynamic>;
  }
}

void main() {
  setUpAll(() async {
    // 与 App main() 一致：先初始化 EasyLocalization，否则其内部
    // `_deviceLocale` 晚初始化字段未就绪，widget 测试直接崩溃。
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  Widget wrapForTest(Widget home) {
    return EasyLocalization(
      path: 'assets/translations',
      supportedLocales: const [Locale('en', 'US'), Locale('zh', 'CN')],
      fallbackLocale: const Locale('en', 'US'),
      startLocale: const Locale('en', 'US'),
      assetLoader: _TestAssetLoader(),
      child: MaterialApp(home: home),
    );
  }

  Future<void> openDialog(
    WidgetTester tester,
    void Function(ExportOptions?) onResult,
  ) async {
    await tester.pumpWidget(
      wrapForTest(
        Scaffold(
          body: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () async {
                onResult(await ExportBackupDialog.show(ctx));
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('默认加密模式：展示格式选择与两个密码输入框', (tester) async {
    await openDialog(tester, (_) {});

    expect(find.text('Export Backup'), findsOneWidget);
    expect(find.text('Encrypted (.snbak) (Recommended)'), findsOneWidget);
    expect(find.text('Plain text (.json)'), findsOneWidget);
    // 默认加密：两个密码输入框（密码 + 确认）
    expect(find.byType(TextField), findsNWidgets(2));
    // 此时密码为空，导出按钮应禁用（点按不弹回）
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
    expect(find.text('Export Backup'), findsOneWidget);
  });

  testWidgets('加密导出：密码不一致时禁用，一致后可提交并返回口令', (tester) async {
    ExportOptions? result;
    await openDialog(tester, (r) => result = r);

    // 输入不一致密码 → 仍禁用
    await tester.enterText(find.byType(TextField).at(0), 'pass-1');
    await tester.enterText(find.byType(TextField).at(1), 'pass-2');
    await tester.pump();
    expect(find.text('Passwords do not match'), findsOneWidget);
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
    expect(find.text('Export Backup'), findsOneWidget);

    // 改成一致 → 可提交
    await tester.enterText(find.byType(TextField).at(1), 'pass-1');
    await tester.pump();
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.encrypted, isTrue);
    expect(result!.password, 'pass-1');
    expect(result!.filePath, endsWith('.snbak'));
  });

  testWidgets('明文模式：隐藏密码框，可直接导出', (tester) async {
    ExportOptions? result;
    await openDialog(tester, (r) => result = r);

    await tester.tap(find.text('Plain text (.json)'));
    await tester.pumpAndSettle();
    // 明文无密码输入框
    expect(find.byType(TextField), findsNothing);
    // 明文导出按钮可直接点击
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.encrypted, isFalse);
    expect(result!.password, isNull);
    expect(result!.filePath, endsWith('.json'));
  });
}