// lib/utils/desktop_window_stub.dart
// Web / 非桌面环境下的窗口管理桩实现
import 'dart:ui' show Offset, Size;

const Size kAppWindowMinSize = Size(380, 380);
const Size kAppWindowInitialSize = Size(1280, 800);

Future<void> initDesktopWindowManager() async {}
Future<void> setWindowSize(Size size) async {}
Future<Size?> getWindowSize() async => null;
Future<void> setWindowPosition(Offset position) async {}
