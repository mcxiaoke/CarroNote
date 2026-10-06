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
//   5. 系统托盘（tray_manager）：「最小化到托盘」「关闭到托盘」开启时隐藏
//      窗口保活，托盘左键 / 右键菜单 / 第二实例（桌面快捷方式、任务栏 PIN）
//      三条路径唤醒。
//
// 仅桌面平台（Windows/macOS/Linux）调用；Web/移动端自动跳过。

import 'dart:async';
import 'dart:ui' show Offset, Size;

import 'package:flutter/painting.dart';

import 'package:core/core.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/utils/desktop_window_callback.dart';
import 'package:safenotes/utils/platform_ui.dart';

// 托盘：仅桌面端启用，提供「隐藏到托盘」后的唤醒入口。
// Windows 右键自动弹出上下文菜单，左键点击恢复主窗口。

/// 主窗口最小尺寸（桌面布局可用的下限，含侧栏 + 内容区 + 键盘输入域）。
const Size kAppWindowMinSize = Size(380, 380);

/// 主窗口初始尺寸（与 windows/runner/main.cpp 保持一致的观感）。
const Size kAppWindowInitialSize = Size(1280, 800);

/// 关闭前清理的兜底超时：清理逻辑挂死时仍保证窗口能关掉。
const Duration _closeHandlerTimeout = Duration(seconds: 10);

/// 防止连点 X 重复触发保存/销毁流程。
bool _isClosing = false;

/// 托盘「退出」时置为 true，跳过「关闭到托盘」隐藏逻辑、走完整退出清理。
bool _forceQuit = false;

/// 是否启用「关闭按钮（X）隐藏到托盘」。
bool get closeToTrayEnabled => PreferencesStorage.closeToTray;

/// 是否启用「最小化时隐藏到托盘」。
bool get minimizeToTrayEnabled => PreferencesStorage.minimizeToTray;

final _AppWindowListener _appWindowListener = _AppWindowListener();
final _TrayEventHandler _trayEventHandler = _TrayEventHandler();

class _AppWindowListener with WindowListener {
  @override
  void onWindowClose() async {
    if (_isClosing) return;
    // 设置开启「关闭到托盘」且非托盘「退出」请求时：隐藏窗口而不是退出。
    if (closeToTrayEnabled && !_forceQuit) {
      await windowManager.hide();
      await windowManager.setSkipTaskbar(true);
      return;
    }
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
      // 退出前销毁托盘图标，避免托盘残留「幽灵」图标。
      // 必须在 close() 之前：close() 只是异步 PostMessage，窗口随即销毁、
      // 消息循环退出，之后再调销毁托盘的 method channel 可能来不及执行。
      try {
        await trayManager.destroy();
      } on Object catch (_) {}
      await windowManager.setPreventClose(false);
      await windowManager.close();
    }
  }

  @override
  void onWindowMinimize() async {
    // 设置开启时：最小化即隐藏到托盘（任务栏窗口按钮消失）。
    if (minimizeToTrayEnabled) {
      await windowManager.hide();
      await windowManager.setSkipTaskbar(true);
    }
  }

  @override
  void onWindowFocus() async {
    // 第二实例唤醒（main.cpp 的 SetForegroundWindow）会触发本事件。
    // 此前隐藏到托盘时任务栏 tab 已被 DeleteTab，SW_SHOW 不会自动恢复，
    // 这里补 AddTab（setSkipTaskbar(false)），否则唤醒后的窗口没有任务栏按钮。
    if (await windowManager.isVisible() &&
        await windowManager.isSkipTaskbar()) {
      await windowManager.setSkipTaskbar(false);
    }
  }
}

/// 托盘事件：左键恢复主窗口；右键弹出上下文菜单。
class _TrayEventHandler with TrayListener {
  @override
  void onTrayIconMouseDown() {
    showMainWindowFromTray();
  }

  @override
  void onTrayIconRightMouseDown() async {
    // tray_manager 0.5.3 Windows 不会自动弹菜单，需手动调用。
    // 每次弹出前重建菜单：启动时（runApp 之前）easy_localization 尚未加载，
    // 标签只有在应用跑起来后才拿得到当前语言的翻译。
    await applyTrayContextMenu();
    await trayManager.popUpContextMenu();
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
    await initDesktopTray();
  });
}

/// 初始化系统托盘图标与右键菜单（显示主窗口 / 退出）。
Future<void> initDesktopTray() async {
  if (!isDesktopPlatform) return;
  try {
    trayManager.addListener(_trayEventHandler);
    // tray_manager Windows 用 LoadImage(IMAGE_ICON) 加载图标，仅支持 .ico，
    // 传 .png 会静默失败（托盘图标为空）。必须用 .ico（放进 assets 才能打包）。
    await trayManager.setIcon('assets/images/app_icon.ico');
    await trayManager.setToolTip('SafeNotes');
    // 初始菜单标签此时是英文 key（翻译未加载），实际弹出的菜单
    // 会在每次右键时经 applyTrayContextMenu 重建为当前语言。
    await applyTrayContextMenu();
  } on Object catch (e, st) {
    Log.app.w('托盘初始化失败（忽略，桌面窗口仍可用）', error: e, stackTrace: st);
  }
}

/// 设置托盘右键菜单：显示主窗口 / 退出。
Future<void> applyTrayContextMenu() async {
  final showItem = MenuItem(
    key: 'show_window',
    label: 'Show Main Window'.tr(),
    onClick: (menuItem) => showMainWindowFromTray(),
  );
  final exitItem = MenuItem(
    key: 'exit_app',
    label: 'Exit'.tr(),
    onClick: (menuItem) => _exitFromTray(),
  );
  await trayManager.setContextMenu(
    Menu(items: [showItem, MenuItem.separator(), exitItem]),
  );
}

/// 从托盘恢复主窗口：先恢复任务栏图标，再显示并聚焦。
/// window_manager 0.5.1 的 show() 只做 SW_SHOW，不会恢复最小化窗口；
/// 最小化状态由后面 focus() 内部的 IsMinimized→Restore 处理。
Future<void> showMainWindowFromTray() async {
  if (!isDesktopPlatform) return;
  await windowManager.setSkipTaskbar(false);
  await windowManager.show();
  await windowManager.focus();
}

/// 托盘「退出」：走完整清理链路后再退出（跳过「关闭到托盘」隐藏）。
Future<void> _exitFromTray() async {
  _forceQuit = true;
  await windowManager.close();
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
