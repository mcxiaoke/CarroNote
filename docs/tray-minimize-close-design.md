# 托盘化方案：最小化/关闭到系统托盘（Windows 优先）

日期：2026-10-06
状态：已实现（本文档为 2026-10-06 晚间工作区丢失后依据会话记录重建）

## 需求

- 设置项："最小化时隐藏到托盘"、"关闭按钮（X）隐藏到托盘"（桌面端可见，`GeneralSettingsPage`，存 `PreferencesStorage`，仅桌面平台显示）。
- 隐藏到托盘后：进程继续运行，窗口隐藏、任务栏窗口按钮消失。
- 唤醒路径：
  - 托盘图标左键 / 托盘菜单「显示主窗口」
  - 双击桌面快捷方式（exe）
  - 点击 PIN 到任务栏的 exe 图标
  - 托盘菜单「退出」才真正退出（走现有 `desktopWindowCloseHandler` 清理链路）。

说明：PIN 任务栏的图标、桌面快捷方式都指向同一个 exe，点击后启动第二实例，
由 `windows/runner/main.cpp` 的单实例守卫拦截，转而唤醒已有窗口。因此
最小化/隐藏到托盘后，上述两条入口都依赖 main.cpp 的唤醒链路。

## 技术选型

- 窗口管理：已有 `window_manager: 0.5.1`，继续沿用。
- 托盘：`tray_manager`（Windows/macOS/Linux 通用，API 干净）。备选 `system_tray`。
- 设置页：沿用 `PreferencesStorage` + `shadSettingsList`/`shadSwitchTile` 模式。

## 实现要点

1. `PreferencesStorage` 增加两个 bool：`minimizeToTray`、`closeToTray`（默认都 false，保守）。
2. `GeneralSettingsPage`：`isDesktopPlatform` 时显示两个 `shadSwitchTile`。
3. 托盘初始化（`desktop_window_native.dart`）：
   - `TrayManager.instance.setIcon(app_icon.ico)`（Windows 的 `LoadImage` 仅支持 .ico，
     传 .png 会静默失败），设置菜单：显示主窗口 / 退出。
   - 左键点击托盘图标 = 显示主窗口。
   - 菜单标签走 `.tr()`；因托盘初始化在 `runApp` 之前、翻译未加载，
     每次右键弹出前重建菜单。
4. 行为拦截：
   - X 关窗：`onWindowClose` 中先查 `closeToTray`。若开启且不是"真退出"请求，
     `windowManager.hide()` + `windowManager.setSkipTaskbar(true)`，直接返回，不走销毁。
   - 最小化：监听 `onWindowMinimize`，若 `minimizeToTray` 开启，
     `hide` + `setSkipTaskbar(true)`。
   - 托盘「退出」：设标志位（`_forceQuit = true`）后走原有清理 + 真正关闭路径，
     且在 `close()` 之前 `trayManager.destroy()`（close 是异步 PostMessage，
     之后销毁托盘的 method channel 可能来不及执行，会残留幽灵图标）。
5. 唤醒：`setSkipTaskbar(false)` → `show()` → `focus()`。
   注意 window_manager 0.5.1 的 `show()` 只做 `SW_SHOW` 不做 restore，
   最小化状态由 `focus()` 内部 `IsMinimized→Restore` 处理。
6. **必须改 `windows/runner/main.cpp`**：当前第二实例唤醒只做
   `IsIconic ? SW_RESTORE : SetForegroundWindow`，对隐藏窗口（`SW_HIDE`）无效。
   改为：
   ```cpp
   if (!::IsWindowVisible(existing)) {
     ::ShowWindow(existing, SW_SHOW);
   }
   if (::IsIconic(existing)) {
     ::ShowWindow(existing, SW_RESTORE);
   }
   ::SetForegroundWindow(existing);
   ```
   这样桌面快捷方式 / 任务栏 PIN 图标唤醒时能正确显示被隐藏的窗口。
   注意：窗口隐藏时 PID 仍在，`FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW")` 仍能找到。
7. **第二实例唤醒后任务栏按钮恢复**：`setSkipTaskbar(true)` 的原生实现是
   `ITaskbarList::DeleteTab`，main.cpp 的 `SW_SHOW` 不会重新 AddTab。Dart 侧在
   `onWindowFocus`（`SetForegroundWindow` 经 `WM_NCACTIVATE` 触发）里检测
   「窗口可见且 skipTaskbar」时调 `setSkipTaskbar(false)` 恢复任务栏按钮。

## 需要注意的边界

- 真退出 vs 隐藏到托盘要用标志位区分，托盘「退出」必须绕过拦截并走完整清理。
- 托盘态下后台任务（同步、session timeout、自动锁定）继续按现有逻辑评估。
- macOS/Linux：同样逻辑，但托盘图标要求不同（macOS 走 rootBundle base64 加载，
  NSImage 可读 .ico；Linux appindicator 对 .ico 文件路径可能失败，会走 catch 分支
  放弃托盘初始化，不影响窗口功能）。
- closeToTray 开启时，任务管理器「关闭窗口」（WM_CLOSE）也会被吞掉转隐藏，
  只能托盘退出或结束进程——与常见托盘应用一致。
- 首次实现后要用两个设置开关分别手工验证三条唤醒路径。

## 文件影响

- `pubspec.yaml`（加 tray_manager）
- `lib/data/preference_and_config.dart`（两个开关）
- `lib/views/settings/general_settings_page.dart`（两个开关 UI）
- `lib/utils/desktop_window_native.dart`（拦截 X / minimize、托盘、唤醒、forceQuit）
- `assets/images/app_icon.ico`（托盘图标，与 exe 图标同源）
- `assets/translations/{en-US,zh-CN}.json`（6 个 key）
- `windows/runner/main.cpp`（隐藏窗口唤醒）
