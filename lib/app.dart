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
import 'dart:async';

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:easy_localization/easy_localization.dart';
import 'package:local_session_timeout/local_session_timeout.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

// Project imports:
import 'package:safenotes/authwall.dart';
import 'package:safenotes/data/db_admin_port.dart';
import 'package:safenotes/data/note_repository.dart';
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/data/preference_repository.dart';
import 'package:safenotes/models/app_theme.dart';
import 'package:safenotes/models/session_provider.dart';
import 'package:safenotes/models/shad_theme.dart';
import 'package:safenotes/platform/ports.dart';
import 'package:safenotes/routes/route_generator.dart';
import 'package:safenotes/sync/sync_repository.dart';
import 'package:safenotes/utils/app_scroll_behavior.dart';
import 'package:safenotes/utils/notes_color.dart';
import 'package:safenotes/utils/route_observer.dart';

class App extends StatelessWidget {
  final StreamController<SessionState> sessionStateStream;
  final GlobalKey<NavigatorState> navigatorKey;

  const App({
    super.key,
    required this.sessionStateStream,
    required this.navigatorKey,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<NotesColor>(create: (_) => NotesColor()),
        // P4: 注入 Repository 接口（向下兼容，现有代码仍直接访问 NotesDatabase.instance 等）
        ChangeNotifierProvider<PreferencesRepository>(
          create: (_) => SharedPreferencesPreferencesRepository(),
        ),
        // ThemeProvider 依赖 PreferencesRepository，需在其后创建。
        ChangeNotifierProvider<ThemeProvider>(
          create: (context) =>
              ThemeProvider(prefs: context.read<PreferencesRepository>()),
        ),
        ChangeNotifierProvider<NotesRepository>.value(
          value: NotesDatabaseRepository(),
        ),
        ChangeNotifierProvider<SyncRepository>.value(
          value: SyncServiceRepository(),
        ),
        Provider<NotesDbAdminPort>.value(value: NotesDbAdminAdapter()),
        // §4.6 平台 port 注入（真实 adapter）
        Provider<SecureStoragePort>(
          create: (_) => const FlutterSecureStorageAdapter(),
        ),
        Provider<BiometricPort>(create: (_) => const PlatformBiometricPort()),
        Provider<DeviceInfoPort>(
          create: (_) => const DeviceIdProviderAdapter(),
        ),
        Provider<PermissionPort>(
          create: (_) => const PermissionHandlerAdapter(),
        ),
        Provider<AppDirsPort>(create: (_) => const PathProviderAdapter()),
        Provider<FilePickerPort>(create: (_) => const FilePickerAdapter()),
        Provider<UrlLauncherPort>(create: (_) => const UrlLauncherAdapter()),
        Provider<MediaScannerPort>(create: (_) => const MediaScannerAdapter()),
        // SessionProvider 依赖上述 repository/port，需在其后创建。
        ChangeNotifierProvider<SessionProvider>(
          create: (context) => SessionProvider(
            notesRepo: context.read<NotesRepository>(),
            syncRepo: context.read<SyncRepository>(),
            prefsRepo: context.read<PreferencesRepository>(),
            biometric: context.read<BiometricPort>(),
            vaultInitialized: AppBootState.vaultInitialized,
          ),
        ),
      ],
      builder: (context, _) {
        final themeProvider = Provider.of<ThemeProvider>(context);
        // 动态品牌色：seed 来自 ThemeProvider，换色时 notifyListeners 触发全局重建。
        final seed = themeProvider.seedColor;

        // 改用 ShadApp 默认构造（替代 ShadApp.custom + 内嵌 MaterialApp）：
        // 由 ShadApp 直接提供 ShadTheme 与内部 WidgetsApp，Material 主题
        // 通过 materialThemeBuilder 保持 AppThemes（M3 ColorScheme.fromSeed）配置。
        return ShadApp(
          themeMode: themeProvider.themeMode,
          theme: ShadThemes.build(seed, Brightness.light),
          darkTheme: ShadThemes.build(seed, Brightness.dark),
          // Material 主题仍走 AppThemes（M3 ColorScheme.fromSeed 色板），brightness 由 ShadApp 传入
          materialThemeBuilder: (context, mTheme) =>
              AppThemes.build(seed, mTheme.brightness),
          navigatorKey: navigatorKey,
          navigatorObservers: [routeObserver],
          initialRoute: '/',
          onGenerateRoute: RouteGenerator.generateRoute,
          title: SafeNotesConfig.appName,
          scrollBehavior: const AppScrollBehavior(),
          localizationsDelegates: context.localizationDelegates,
          supportedLocales: context.supportedLocales,
          locale: context.locale,
          // ShadSonner 放到 Navigator 之上（同原 MaterialApp.builder 的用途）
          builder: (context, child) => ShadSonner(child: child!),
          home: AuthWall(sessionStateStream: sessionStateStream),
        );
      },
    );
  }
}
