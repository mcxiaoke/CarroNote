/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

/*
 * dev 模式全局状态
 *
 * 需求：非 debug 构建（release/profile）默认不开启任何调试能力：
 *   - 不显示调试面板入口（主界面 AppBar 的 bug 图标）
 *   - 日志级别默认 warn（而非 info/trace）
 *   - 不自动启动日志 Web 服务器
 *
 * 开启与关闭（简化方案）：
 *   - 开启：只能在关于页连点应用图标 [DevMode.tapThreshold] 次（5 次）调用
 *     [enable]，开启 dev 模式（持久化 + 刷新日志级别 + 启动日志 Web 服务器）。
 *   - 关闭：在设置页的开发者模式开关上关闭（[setActive(false)] / [disable]）。
 *   - 关闭后开关即置灰，想再次开启必须回到关于页连点图标，不能在设置页直接打开。
 *
 * debug 构建恒为 dev 模式（[DevMode.isActive] 直接返回 true），
 * 因此本文件不影响任何 debug 构建的既有行为。
 */

import 'package:core/core.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/src/logger/log_webserver.dart';

class DevMode {
  DevMode._();

  /// 关于页连点次数阈值
  static const int tapThreshold = 5;

  /// 当前是否处于 dev 模式：
  /// - debug 构建恒为 true（不读偏好，避免启动早期 Preferences 未初始化的问题）；
  /// - 非 debug 构建读取持久化开关 [PreferencesStorage.isDevMode]。
  static bool get isActive {
    if (kDebugMode) return true;
    return PreferencesStorage.isDevMode;
  }

  /// 开启 dev 模式（幂等）：持久化开关 + 立即刷新日志级别 + 启动日志 Web 服务器。
  ///
  /// 返回是否发生了状态变化（false 表示此前已处于 dev 模式）。
  static Future<bool> enable() async => _apply(true);

  /// 关闭 dev 模式（幂等）：清除持久化开关 + 恢复日志级别 + 停止日志 Web 服务器。
  static Future<bool> disable() async => _apply(false);

  /// 由设置页开关调用：按 [active] 设置 dev 模式并同步日志级别 / 日志 Web 服务器。
  ///
  /// debug 构建恒为 dev 模式，本方法为空操作（开关不可改变状态）。
  static Future<void> setActive(bool active) async {
    await _apply(active);
  }

  /// 统一应用 dev 模式开关状态：持久化 + 刷新日志级别 + 启停日志 Web 服务器。
  ///
  /// 返回是否发生了状态变化。debug 构建恒为 true 目标态、无需任何副作用，直接返回 false。
  static Future<bool> _apply(bool active) async {
    if (kDebugMode) return false;
    final already = PreferencesStorage.isDevMode;
    if (already == active) return false;
    await PreferencesStorage.setDevMode(active);
    // 日志级别恢复/降回（dev: trace，非 dev: warn）
    AppLog.refreshLevel();
    if (active) {
      // 启动日志 Web 服务器（幂等，失败不影响主流程）
      try {
        await LogWebServer.instance.start();
      } on Object catch (e, st) {
        Log.web.w('dev 模式开启日志 Web 服务器失败', error: e, stackTrace: st);
      }
    } else {
      // 关闭时停止日志 Web 服务器
      try {
        await LogWebServer.instance.stop();
      } on Object catch (e, st) {
        Log.web.w('dev 模式停止日志 Web 服务器失败', error: e, stackTrace: st);
      }
    }
    return true;
  }
}
