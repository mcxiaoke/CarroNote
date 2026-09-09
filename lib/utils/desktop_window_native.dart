/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*/

// 桌面端窗口管理（window_manager 封装）。
//
// Flutter 桌面 runner 创建的窗口默认就可自由缩放（WS_OVERLAPPEDWINDOW），
// 这里通过 window_manager 补充应用内可控能力：
//   1. 设最小尺寸：防止窗口被拖到布局崩坏（侧栏/输入框挤出屏幕）；
//   2. 启动居中并设置初始尺寸；
//   3. 提供 WindowManager 实例供后续功能（如记住上次大小、全屏等）扩展；
//   4. 拦截点 X 关窗（R2）：先执行 [desktopWindowCloseHandler]（保存编辑器
//      草稿 + 停同步/日志等清理），再销毁窗口——否则异步保存与进程退出
//      竞态，未保存内容必丢。
//
// 仅桌面平台（Windows/macOS/Linux）调用；Web/移动端自动跳过。

import 'dart:async';
import 'dart:ui' show Offset, Size;

import 'package:flutter/painting.dart';

import 'package:core/core.dart';
import 'package:window_manager/window_manager.dart';

import 'package:safenotes/utils/desktop_window_callback.dart';
import 'package:safenotes/utils/platform_ui.dart';

/// 主窗口最小尺寸（桌面布局可用的下限，含侧栏 + 内容区 + 键盘输入域）。
const Size kAppWindowMinSize = Size(380, 380);

/// 主窗口初始尺寸（与 windows/runner/main.cpp 保持一致的观感）。
const Size kAppWindowInitialSize = Size(1280, 800);

/// 关闭前清理的兜底超时：清理逻辑挂死时仍保证窗口能关掉。
const Duration _closeHandlerTimeout = Duration(seconds: 10);

/// 防止连点 X 重复触发保存/销毁流程。
bool _isClosing = false;

final _AppWindowListener _appWindowListener = _AppWindowListener();

class _AppWindowListener with WindowListener {
  @override
  void onWindowClose() async {
    if (_isClosing) return;
    _isClosing = true;
    // 先立即隐藏窗口给用户「秒关」的视觉反馈，清理在不可见状态下进行，
    // 最后再 destroy。否则关窗前的清理（保存草稿/停同步等，最长 10s）
    // 会让窗口停在原地，表现为点 X 后卡顿。
    await windowManager.hide();
    final sw = Stopwatch()..start();
    try {
      final handler = desktopWindowCloseHandler;
      if (handler != null) {
        await handler().timeout(_closeHandlerTimeout);
      }
    } on Object catch (e, st) {
      Log.app.w('窗口关闭前清理失败（忽略，继续退出）', error: e, stackTrace: st);
    } finally {
      final elapsed = sw.elapsed;
      // 正常清理应在百毫秒级；超 1s 说明关窗链路有慢步骤（如在途同步），
      // 用 warn 级别保证 release（默认 warn）下也能看到。
      if (elapsed > const Duration(seconds: 1)) {
        Log.app.w('窗口关闭前清理耗时较长: ${elapsed.inMilliseconds}ms');
      }
      // 防止点X关闭窗口后鼠标显示沙漏繁忙
      // await windowManager.destroy();
      await windowManager.setPreventClose(false);
      await windowManager.close();
    }
  }
}

/// 初始化桌面窗口管理器并在窗口就绪后应用尺寸/位置设置。
///
/// 必须在 `WidgetsFlutterBinding.ensureInitialized()` 之后调用
/// （main.dart 的 runZonedGuarded 里已满足）。
Future<void> initDesktopWindowManager() async {
  if (!isDesktopPlatform) return;

  await windowManager.ensureInitialized();

  final options = WindowOptions(
    size: kAppWindowInitialSize,
    center: true,
    minimumSize: kAppWindowMinSize,
    title: 'SafeNotes',
  );

  // waitUntilReadyToShow：等原生窗口就绪后一次性写入尺寸/位置/最小尺寸，
  // 避免在 Dart 侧启动期反复读写窗口属性造成闪烁。
  windowManager.waitUntilReadyToShow(options, () async {
    // R2：拦截系统关闭（点 X / Alt+F4），转由 onWindowClose 先保存草稿再退出
    await windowManager.setPreventClose(true);
    windowManager.addListener(_appWindowListener);
    await windowManager.show();
    await windowManager.focus();
  });
}

/// 程序化设置主窗口尺寸（桌面真机窗口）。
///
/// 供集成测试使用：真实缩放窗口后，MediaQuery.sizeOf 与布局约束会随平台
/// 尺寸变化更新——相比 `setSurfaceSize`（只改 `View.physicalSize`、MediaQuery
/// 不随之更新，见 drawer.dart），能暴露真实桌面布局在各窗口尺寸下的问题。
/// 非桌面平台为空操作。
Future<void> setWindowSize(Size size) async {
  if (!isDesktopPlatform) return;
  await windowManager.setSize(size);
}

/// 读取当前主窗口尺寸（逻辑坐标，桌面真机窗口）。
/// 供集成测试在 `setWindowSize` 后核验实际生效尺寸；非桌面平台返回 null。
Future<Size?> getWindowSize() async {
  if (!isDesktopPlatform) return null;
  return windowManager.getSize();
}

/// 程序化设置主窗口在屏幕上的位置（左上角逻辑坐标，桌面真机窗口）。
/// 供集成测试使用；非桌面平台为空操作。
Future<void> setWindowPosition(Offset position) async {
  if (!isDesktopPlatform) return;
  await windowManager.setPosition(position);
}
