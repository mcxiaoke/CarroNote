/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

// 集成型 widget 测试共享 harness
//
// 提供「可复用、隔离、真实」的测试环境，让集成型 widget 测试能驱动真实 UI 屏幕：
//   - 环境初始化统一在 `test/support/harness.dart`：`initFullEnv()` 装配真实
//     加密、sqflite_ffi NoIsolate、平台通道 mock 与 EasyLocalization；
//     普通 widget 测试（不碰 DB/加密）用 `initLightEnv()`。
//   - 用真实 Keyring.createNew + NotesDatabase.storeNote 造「带密码的真实库」，
//     密码默认 hello.1111，可 seed 若干笔记，测试跑在**真实加密**之上。
//   - pumpApp()：挂载真实 App（AuthWall → 登录/设置密码），走完整路由。
//   - wrapScreen()：给单屏注入 ShadTheme + ThemeProvider + NotesColor，便于直接验证。
//
// 用法见 auth_flow_test.dart / theme_color_setting_test.dart。

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:core/core.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_session_timeout/local_session_timeout.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:safenotes/app.dart';
import 'package:safenotes/authwall.dart';
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/app_theme.dart';
import 'package:safenotes/models/shad_theme.dart';
import 'package:safenotes/utils/notes_color.dart';

import 'support/asset_loader.dart';

export 'support/harness.dart' show initFullEnv, initLightEnv;

/// 造一个「已初始化保险库、已解锁」的真实测试库。
///
/// 注意：必须使用「内存数据库」(:memory:) 而非落盘文件。flutter test 的子进程
/// 在沙箱里对系统临时目录（AppData\Local\Temp）的文件写入会被阻塞/挂起，
/// 导致 Directory.systemTemp.createTemp 永久 await，进而 90s 超时。
/// 内存库与 core 包自身测试一致，且完全避开文件系统，稳定可重复。
///
/// 密码派生/解密走真实算法（NoIsolateDartCryptography，见 support/crypto.dart）：
/// 正确密码能解出 dataKey、错误密码走真实 GCM tag 校验抛异常，
/// 足以驱动整条认证流程。
///
/// [password] 默认 hello.1111（与手测一致）；[seeds] 可选预置笔记。
/// 设置 AppBootState.vaultInitialized=true，使 AuthWall 走登录页。
Future<void> prepareUnlockedVault({
  String password = 'hello.1111',
  List<({String title, String description})> seeds = const [],
}) async {
  final db = await openDatabase(
    ':memory:',
    version: 4,
    onCreate: NotesDatabase.createDBForTesting,
  );
  NotesDatabase.setDatabaseForTesting(db);

  // 真实初始化密钥环（生产首次设置密码走的接口）
  final keyring = await Keyring.createNew(
    password: password,
    database: NotesDatabase.instance,
  );
  NotesDatabase.instance.setDataKey(keyring.dataKey);

  for (final s in seeds) {
    await NotesDatabase.instance.storeNote(
      SafeNote.create(title: s.title, description: s.description),
    );
  }

  await PreferencesStorage.init();
  AppBootState.vaultInitialized = true;
}

/// 造一个「空保险库」的内存测试库（无 keyring），用于首次运行设置密码流程。
Future<void> prepareEmptyVault() async {
  final db = await openDatabase(
    ':memory:',
    version: 4,
    onCreate: NotesDatabase.createDBForTesting,
  );
  NotesDatabase.setDatabaseForTesting(db);
  await PreferencesStorage.init();
  AppBootState.vaultInitialized = false;
}

/// 关闭内存库，保证用例间隔离。
Future<void> disposeVault() async {
  try {
    await NotesDatabase.instance.close();
  } on Object {
    // 忽略关闭异常
  }
}

/// 挂载真实 App（AuthWall 按 AppBootState.vaultInitialized 选择登录/设置密码页）。
///
/// 每次调用创建独立的 session stream 与 navigator key。测试通过 UI 交互驱动路由。
Future<void> pumpApp(WidgetTester tester) async {
  await tester.pumpWidget(
    EasyLocalization(
      path: 'assets/translations',
      supportedLocales: const [Locale('en', 'US'), Locale('zh', 'CN')],
      fallbackLocale: const Locale('en', 'US'),
      startLocale: const Locale('en', 'US'),
      assetLoader: TestAssetLoader(),
      child: App(
        sessionStateStream: StreamController<SessionState>(),
        navigatorKey: GlobalKey<NavigatorState>(),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

// ──────────────────────────────────────────────
// 单屏封装（直接验证 SettingsScreen / ColorPallet / ThemeBottomSheet 等）
// ──────────────────────────────────────────────

/// 单屏测试使用的固定主题 seed（与 App 默认一致：独立默认色·深海蓝，
/// 即 ThemeProvider.defaultSeedColor，不依赖 seed 色库数据）。
const Color kTestThemeSeed = Color(0xFF0F3460);

/// 单屏测试共用的 Provider 实例（测试可读取以断言状态变化）。
late ThemeProvider testThemeProvider;
late NotesColor testNotesColor;

/// 在 setUp 调用：创建供单屏测试使用的 Provider 实例。
void prepareProviders() {
  testThemeProvider = ThemeProvider();
  testNotesColor = NotesColor();
}

/// 把单个屏幕包进 ShadTheme + MaterialApp + 双 Provider，
/// 与 App 的提供者结构一致，可真实渲染 ShadButton / ShadTheme.of(context)。
Widget wrapScreen(Widget screen) {
  return EasyLocalization(
    path: 'assets/translations',
    supportedLocales: const [Locale('en', 'US'), Locale('zh', 'CN')],
    fallbackLocale: const Locale('en', 'US'),
    startLocale: const Locale('en', 'US'),
    assetLoader: TestAssetLoader(),
    child: MultiProvider(
      providers: [
        ChangeNotifierProvider<ThemeProvider>.value(value: testThemeProvider),
        ChangeNotifierProvider<NotesColor>.value(value: testNotesColor),
      ],
      builder: (context, _) => Builder(
        builder: (ctx) {
          // 订阅 ThemeProvider，使 themeMode 变化时重建 ShadApp.custom
          final tp = Provider.of<ThemeProvider>(ctx);
          return ShadApp.custom(
            themeMode: tp.themeMode,
            theme: ShadThemes.build(kTestThemeSeed, Brightness.light),
            darkTheme: ShadThemes.build(kTestThemeSeed, Brightness.dark),
            appBuilder: (c) => MaterialApp(home: screen),
          );
        },
      ),
    ),
  );
}