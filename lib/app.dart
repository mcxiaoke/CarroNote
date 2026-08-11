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
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/app_theme.dart';
import 'package:safenotes/models/shad_theme.dart';
import 'package:safenotes/routes/route_generator.dart';
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
        ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
        ChangeNotifierProvider<NotesColor>(create: (_) => NotesColor()),
      ],
      builder: (context, _) {
        final themeProvider = Provider.of<ThemeProvider>(context);

        // ShadApp.custom 同时提供 ShadTheme(给 ShadXxx 组件) 与内部 MaterialApp
        // (给现有 Material 页面，沿用 FlexColorScheme 主题)。两套设计系统并存，
        // 旧页面零改动即可继续工作，新页面逐步采用 Shad 组件。
        return ShadApp.custom(
          themeMode: themeProvider.themeMode,
          theme: ShadThemes.light,
          darkTheme: ShadThemes.dark,
          appBuilder: (context) {
            return MaterialApp(
              debugShowCheckedModeBanner: false,
              navigatorKey: navigatorKey,
              navigatorObservers: [routeObserver],
              initialRoute: '/',
              onGenerateRoute: RouteGenerator.generateRoute,
              title: SafeNotesConfig.appName,
              themeMode: themeProvider.themeMode,
              theme: AppThemes.lightTheme,
              darkTheme: AppThemes.darkTheme,
              scrollBehavior: const AppScrollBehavior(),
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              home: AuthWall(sessionStateStream: sessionStateStream),
            );
          },
        );
      },
    );
  }
}
