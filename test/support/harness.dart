// 测试支撑层：widget 测试的共享 harness
//
// 提供 withProviders() 函数，作为「单屏测试」的标准包裹器，替代 test_helpers 中
// 的 wrapScreen 和 pumpApp 的部分功能。
//
// 特性：
//   - EasyLocalization + TestAssetLoader（翻译加载）
//   - ShadApp.custom 包装（ShadTheme + Material 双主题）
//   - MediaQuery(viewInsets: EdgeInsets.zero) 消除键盘动画导致的 pumpAndSettle 卡死
//   - 可选的 Provider 列表注入（通过 overrides 参数）
//
// 用法：
//   await tester.pumpWidget(withProviders(
//     const MyWidget(),
//     overrides: [
//       Provider<MyService>.value(FakeMyService()),
//     ],
//   ));
//   await tester.pumpAndSettle();  // 不再因键盘动画卡死

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:easy_localization/easy_localization.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

// Project imports:
import 'package:safenotes/models/app_theme.dart';
import 'package:safenotes/models/shad_theme.dart';
import 'package:safenotes/utils/notes_color.dart';

import 'asset_loader.dart';

/// 单屏测试使用的固定主题 seed（与 App 默认一致：独立默认色·深海蓝）。
const Color kHarnessThemeSeed = Color(0xFF0F3460);

/// 把 [child] 包裹进测试所需的 Provider 树与主题。
///
/// 默认提供：
///   - EasyLocalization + TestAssetLoader
///   - ShadApp.custom + ShadThemes 双主题
///   - MediaQuery(viewInsets: EdgeInsets.zero) 消除键盘滚动动画
///   - ChangeNotifierProvider<ThemeProvider>
///   - ChangeNotifierProvider<NotesColor>
///
/// [overrides] 可覆盖或追加 Provider，替换默认的 Provider 或新增依赖。
/// 注意：传入的 overrides 元素应为 Provider&lt;T&gt; 等 SingleChildWidget 实例。
///
/// 注意：此函数不包含数据库/同步/安全存储等测试替身，调用方需通过 overrides
/// 自行注入所需依赖（各 Phase 逐步添加）。
Widget withProviders(
  Widget child, {
  List<dynamic> overrides = const [],
  Color themeSeed = kHarnessThemeSeed,
  ThemeMode themeMode = ThemeMode.light,
}) {
  return EasyLocalization(
    path: 'assets/translations',
    supportedLocales: const [Locale('en', 'US'), Locale('zh', 'CN')],
    fallbackLocale: const Locale('en', 'US'),
    startLocale: const Locale('en', 'US'),
    assetLoader: TestAssetLoader(),
    child: MediaQuery(
      data: const MediaQueryData(viewInsets: EdgeInsets.zero),
      child: ShadApp.custom(
        themeMode: themeMode,
        theme: ShadThemes.build(themeSeed, Brightness.light),
        darkTheme: ShadThemes.build(themeSeed, Brightness.dark),
        appBuilder: (context) => MultiProvider(
          providers: [
            ChangeNotifierProvider<ThemeProvider>(
              create: (_) => ThemeProvider(),
            ),
            ChangeNotifierProvider<NotesColor>(
              create: (_) => NotesColor(),
            ),
            ...overrides,
          ],
          child: child,
        ),
      ),
    ),
  );
}