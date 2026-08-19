/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

// 测试环境初始化（轻 / 重两档）。
//
// 轻量 [initLightEnv]：普通 widget 测试（单屏封装 wrapScreen / 弹窗测试）只需
//   `pumpWidget` 一个屏幕，不碰数据库与加密。只做几件事：
//   - SharedPreferences 内存 mock；
//   - EasyLocalization 就绪 + 关闭翻译缺失 warning 日志；
//   - 关闭光标闪烁（EditableText.debugDeterministicCursor）→ pumpAndSettle 收敛，
//     消除「聚焦输入框 → 光标 blink 周期调度帧 → 永不 settle」一类死循环；
//   - mock Windows 标题栏通道：`ThemeProvider` 构造时会调 `syncWindowsTitleBar`
//     （lib/utils/window_title_bar.dart），测试下该通道未注册会抛
//     MissingPluginException（只 catch 了 PlatformException），需返回 null；
//   - 日志 HTTP 服务器默认关闭（其周期性 idle-timeout Timer 会在 FakeAsync 下挂起）。
//
// 全量 [initFullEnv]：集成型 widget 测试（驱动真实 App / 真实 DB + Keyring，
//   如 auth_flow_test）在轻量之上追加：
//   - flutter_secure_storage → 内存 Map（避免 MissingPluginException）；
//   - sqflite_ffi 初始化，用「无后台 isolate」变体（databaseFactoryFfiNoIsolate）：
//     默认变体把 SQLite 操作放到后台 isolate，与测试事件循环死锁，NoIsolate 让
//     SQLite 跑在主 isolate（操作同步且短促），彻底规避死锁；
//   - 用「无 isolate / 无 yield」的 **真实**加密替代 cryptography 默认实例
//     （见 support/crypto.dart）：Argon2id 默认 spawn isolate + Future.delayed
//     让出，在 flutter test 子进程的 FakeAsync zone 里都会永久挂起。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:cryptography/cryptography.dart' show Cryptography;
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:safenotes/src/logger/log_webserver.dart';

import 'crypto.dart';

/// 测试用「实时报告安全存储」通道与内存后端，避免 MissingPluginException。
const _secureChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);
final Map<String, String> _secureStore = {};

void _setupSecureStorageMock() {
  _secureStore.clear();
  TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_secureChannel, (call) async {
        final args = call.arguments as Map<Object?, Object?>;
        switch (call.method) {
          case 'read':
            return _secureStore[args['key'] as String];
          case 'write':
            _secureStore[args['key'] as String] =
                (args['value'] as String?) ?? '';
            return true;
          case 'delete':
            _secureStore.remove(args['key'] as String);
            return true;
          case 'containsKey':
            return _secureStore.containsKey(args['key'] as String);
          case 'readAll':
            return Map<String, String>.from(_secureStore);
          case 'deleteAll':
            _secureStore.clear();
            return true;
          default:
            return null;
        }
      });
}

/// 标题栏主题通道（Windows 专用）；测试里直接返回 null，避免未注册通道报错。
const _titleBarChannel = MethodChannel('safenotes/window_title_bar');

/// 轻量环境：普通 widget 测试（不碰数据库 / 加密 / 平台通道）。
Future<void> initLightEnv() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 必须在首次 getInstance() 之前注入，否则会去初始化真实平台存储。
  SharedPreferences.setMockInitialValues({});
  // 关闭聚焦输入框的光标闪烁（定时 setState → 持续调度帧 → pumpAndSettle 永不收敛）。
  EditableText.debugDeterministicCursor = true;
  // 标题栏主题通道（Windows 专用）：ThemeProvider 构造即调用，测试下返回 null，
  // 避免未注册通道抛 MissingPluginException。
  TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_titleBarChannel, (call) async => null);
  // 集成测试关闭日志 HTTP 服务器：其 HttpServer idle timeout 会在 FakeAsync 下
  // 留下永远 pending 的周期性 Timer（见 log_webserver.dart 的 enableWebServer 注释）。
  LogWebServer.enableWebServer = false;
  // 屏蔽 easy_localization 在 flutter test 下的翻译缺失等 warning 日志。
  // 注意：flutter test 不执行 main()，必须在测试初始化阶段、ensureInitialized()
  // 之前设置静态 logger（构造 EasyLocalization 不会重置该静态实例）。
  EasyLocalization.logger.enableBuildModes = [];
  await EasyLocalization.ensureInitialized();
}

/// 全量环境：集成型 widget 测试（真实 DB + Keyring，如认证主流程）。
Future<void> initFullEnv() async {
  await initLightEnv();
  _setupSecureStorageMock();
  // 桌面端用 sqflite_ffi（与 main._bootstrap 一致的真实 SQLite 路径），
  // 内存数据库(:memory:) 避开对系统临时目录的写入；用「无后台 isolate」变体，
  // 避免默认变体在 flutter test 完整初始化下与测试事件循环死锁。
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  // 用「无 isolate / 无 yield」的真实加密替换 cryptography 默认实例（见 crypto.dart）。
  Cryptography.instance = NoIsolateDartCryptography();
}