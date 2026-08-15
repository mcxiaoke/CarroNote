// 测试支撑层：widget 测试的共享 harness
//
// 提供 withProviders() 函数，作为「单屏测试」的标准包裹器，替代 test_helpers 中
// 的 wrapScreen 和 pumpApp 的部分功能。
//
// 特性：
//   - EasyLocalization + TestAssetLoader（翻译加载）
//   - ShadApp.custom 包装（ShadTheme + Material 双主题）
//   - MediaQuery(viewInsets: EdgeInsets.zero) 消除键盘动画导致的 pumpAndSettle 卡死
//   - 默认 SessionProvider + FakeNotesRepository + FakeSyncRepository
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
import 'package:safenotes/data/db_admin_port.dart';
import 'package:safenotes/data/note_repository.dart';
import 'package:safenotes/data/preference_repository.dart';
import 'package:safenotes/models/app_theme.dart';
import 'package:safenotes/models/session_provider.dart';
import 'package:safenotes/models/shad_theme.dart';
import 'package:safenotes/platform/ports.dart';
import 'package:safenotes/sync/sync_repository.dart';
import 'package:safenotes/utils/notes_color.dart';

import 'asset_loader.dart';
import 'fake_repositories.dart';
import 'fakes.dart';
import 'platform_fakes.dart';

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
///   - ChangeNotifierProvider<SessionProvider> (vaultInitialized: null)
///   - ChangeNotifierProvider<NotesRepository> (FakeNotesRepository)
///   - ChangeNotifierProvider<SyncRepository> (FakeSyncRepository)
///   - Provider<NotesDbAdminPort> (FakeNotesDbAdminPort)
///
/// [overrides] 可覆盖或追加 Provider，替换默认的 Provider 或新增依赖。
/// 注意：传入的 overrides 元素应为 Provider&lt;T&gt; 等 SingleChildWidget 实例。
///
/// 注意：FakeNotesRepository 和 FakeSyncRepository 是内存实现，不依赖数据库或网络。
/// 如需真实数据库，请在 overrides 中注入 NotesDatabaseRepository 等实现。
Widget withProviders(
  Widget child, {
  List<dynamic> overrides = const [],
  PreferencesRepository? preferences,
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
        appBuilder: (context) => MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<NotesColor>(create: (_) => NotesColor()),
              ChangeNotifierProvider<PreferencesRepository>(
                create: (_) => preferences ?? FakePreferencesRepository(),
              ),
              ChangeNotifierProvider<ThemeProvider>(
                create: (context) => ThemeProvider(
                  prefs: context.read<PreferencesRepository>(),
                ),
              ),
              ChangeNotifierProvider<NotesRepository>(
                create: (_) => FakeNotesRepository(),
              ),
              ChangeNotifierProvider<SyncRepository>(
                create: (_) => FakeSyncRepository(),
              ),
              Provider<NotesDbAdminPort>(
                create: (_) => FakeNotesDbAdminPort(),
              ),
              // §4.6 平台 port 测试替身
              Provider<SecureStoragePort>(create: (_) => FakeSecureStorage()),
              Provider<BiometricPort>(create: (_) => FakeBiometric()),
              Provider<DeviceInfoPort>(create: (_) => FakeDeviceInfo()),
              Provider<PermissionPort>(create: (_) => FakePermission()),
              Provider<AppDirsPort>(create: (_) => FakeAppDirs()),
              Provider<FilePickerPort>(create: (_) => FakeFilePicker()),
              Provider<UrlLauncherPort>(create: (_) => FakeUrlLauncher()),
              Provider<MediaScannerPort>(create: (_) => FakeMediaScanner()),
              ChangeNotifierProvider<SessionProvider>(
                create: (context) => SessionProvider(
                  notesRepo: context.read<NotesRepository>(),
                  syncRepo: context.read<SyncRepository>(),
                  prefsRepo: context.read<PreferencesRepository>(),
                  biometric: context.read<BiometricPort>(),
                ),
              ),
              ...overrides,
            ],
            child: child,
          ),
        ),
      ),
    ),
  );
}
