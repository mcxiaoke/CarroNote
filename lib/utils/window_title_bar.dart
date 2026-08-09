// Dart imports:
import 'dart:io';

// Flutter imports:
import 'package:flutter/services.dart';

/// 将应用主题同步到 Windows 原生标题栏（仅 Windows 平台生效）。
///
/// 背景：Flutter 的 Windows runner 默认按【系统】主题（注册表
/// `AppsUseLightTheme`）设置标题栏明暗，但应用内自带暗/亮模式开关，
/// 二者并不联动。要让「应用内暗黑模式」也把 Windows 标题栏切成暗色，
/// 需要由 Dart 侧通过 method channel 把当前主题推送到原生层，由原生层
/// 调用 DWM `DWMWA_USE_IMMERSIVE_DARK_MODE`。
///
/// 其它平台（Linux/macOS/Android/iOS）没有该通道，直接提前返回，不调用。
const MethodChannel _titleBarChannel = MethodChannel(
  'safenotes/window_title_bar',
);

/// 通知 Windows 原生层将标题栏切换为暗色([isDark])或亮色。
/// 仅 Windows 平台生效；非 Windows 平台直接跳过（无该通道）。
Future<void> syncWindowsTitleBar(bool isDark) async {
  if (!Platform.isWindows) return;
  try {
    await _titleBarChannel.invokeMethod<void>('setDarkMode', isDark);
  } on PlatformException {
    // 理论上 Windows 已注册该通道，保留健壮性。
  }
}
