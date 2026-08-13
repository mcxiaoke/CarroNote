// 导出面板（ExportBackupDialog）widget 测试
//
// 覆盖：加密/明文二选一、密码确认、空/不一致密码按钮禁用、
//       明文模式隐藏密码框、提交返回 ExportOptions。

// Dart imports:
import 'dart:convert';

// Flutter imports:
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Package imports:
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Project imports:
import 'package:safenotes/dialogs/export_backup_dialog.dart';
import 'package:safenotes/models/shad_theme.dart';
import 'test_helpers.dart';

/// widget 测试的 asset bundle 并不提供项目翻译文件，这里改用 rootBundle.loadString
/// 读取（走 Flutter asset bundle，而非 dart:io 文件 I/O）。本机 flutter test 沙箱里
/// dart:io 的 File.readAsString 会永久挂起（事件循环被冻结），导致
/// EasyLocalization 永远不就绪、App 渲染不出。rootBundle 在 flutter test 下可正常加载。
/// 按 [语言-国家, 语言, en-US] 顺序回退；任一候选加载失败则退化返回空表（.tr() 返回 key）。
class _TestAssetLoader extends AssetLoader {
  @override
  Future<Map<String, dynamic>?> load(String path, Locale locale) async {
    final candidates = <String>[
      if (locale.countryCode != null && locale.countryCode!.isNotEmpty)
        '${locale.languageCode}-${locale.countryCode}',
      locale.languageCode,
      'en-US',
    ];
    for (final code in candidates) {
      try {
        final raw = await rootBundle.loadString('$path/$code.json');
        return jsonDecode(raw) as Map<String, dynamic>;
      } on Object {
        // 该候选不存在，尝试下一个
      }
    }
    return <String, dynamic>{};
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
      // shadcn 迁移后导出面板用 ShadInput / ShadRadio / ShadTheme.of()，
      // 必须包 ShadApp.custom 提供 ShadTheme，否则 ShadTheme.of() 抛异常导致
      // 对话框内容无法渲染（原测试只包了 MaterialApp，对应旧 MD3 版本）。
      child: ShadApp.custom(
        theme: ShadThemes.build(kTestThemeSeed, Brightness.light),
        darkTheme: ShadThemes.build(kTestThemeSeed, Brightness.dark),
        themeMode: ThemeMode.light,
        appBuilder: (c) => MaterialApp(home: home),
      ),
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
    // 默认加密：两个密码输入框（密码 + 确认）+ 一个只读位置展示框，
    // 共 3 个 ShadInput（位置框是 ShadInputFormField，属 ShadInput 子类）。
    expect(find.byType(ShadInput), findsNWidgets(3));
    // 此时密码为空，导出按钮应禁用（点按不弹回）
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
    expect(find.text('Export Backup'), findsOneWidget);
  });

  testWidgets('加密导出：密码不一致时禁用，一致后可提交并返回口令', (tester) async {
    ExportOptions? result;
    await openDialog(tester, (r) => result = r);

    // 输入不一致密码 → 仍禁用
    await tester.enterText(find.byType(ShadInput).at(0), 'pass-1');
    await tester.enterText(find.byType(ShadInput).at(1), 'pass-2');
    await tester.pump();
    expect(find.text('Passwords do not match'), findsOneWidget);
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
    expect(find.text('Export Backup'), findsOneWidget);

    // 改成一致 → 可提交
    await tester.enterText(find.byType(ShadInput).at(1), 'pass-1');
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
    // 明文无密码输入框，但仍有 1 个只读位置展示框（ShadInputFormField）。
    expect(find.byType(ShadInput), findsOneWidget);
    // 明文导出按钮可直接点击
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.encrypted, isFalse);
    expect(result!.password, isNull);
    expect(result!.filePath, endsWith('.json'));
  });
}
