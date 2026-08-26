// 桌面端窗口关闭拦截回调的共享声明。
//
// 独立成文件是为了让 native / stub 两个平台实现与调用方（main.dart）
// 共享同一符号，避免循环导出（发布评审 R2）。

/// 窗口关闭前的清理回调：保存未提交草稿、停同步、flush 日志等。
typedef DesktopWindowCloseHandler = Future<void> Function();

/// 由 main.dart 在启动时注入；null 表示未配置（直接放行关闭）。
DesktopWindowCloseHandler? desktopWindowCloseHandler;
