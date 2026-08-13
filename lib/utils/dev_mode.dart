/*
 * dev 模式全局状态
 *
 * 需求：非 debug 构建（release/profile）默认不开启任何调试能力：
 *   - 不显示调试面板入口（主界面 AppBar 的 bug 图标）
 *   - 日志级别默认 warn（而非 info/trace）
 *   - 不自动启动日志 Web 服务器
 *
 * 在设置页底部「版本号 · 构建时间」区域连续点击 5 次可开启 dev 模式，
 * 开启后与 debug build 行为完全一致（上述能力全部恢复）。
 *
 * debug 构建恒为 dev 模式（[DevMode.isActive] 直接返回 true），
 * 因此本文件不影响任何 debug 构建的既有行为。
 */

// Package imports:
import 'package:core/core.dart';

// Project imports:
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/src/logger/log_webserver.dart';

class DevMode {
  DevMode._();

  /// 设置页底部连点次数阈值
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
  static Future<bool> enable() async {
    final alreadyActive = isActive;
    if (!alreadyActive) {
      await PreferencesStorage.setDevMode(true);
    }
    // 日志级别恢复全量 trace（与 debug build 一致）
    AppLog.refreshLevel();
    // 启动日志 Web 服务器（幂等，失败不影响主流程）
    try {
      await LogWebServer.instance.start();
    } on Object catch (e, st) {
      Log.web.w('dev 模式开启日志 Web 服务器失败', error: e, stackTrace: st);
    }
    return !alreadyActive;
  }
}
