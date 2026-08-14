/*
* Copyright (C) Keshav Priyadarshi and others - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*
* You should have received a copy of the GNU General Public License v3.0 with
* this file. If not, please visit https://www.gnu.org/licenses/gpl-3.0.html
*
* See https://safenotes.dev for support or download.
*/

// Dart imports:
import 'dart:async';

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:easy_localization/easy_localization.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

// Project imports:
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/widgets/shad_dialog.dart';

class PreInactivityLogOff extends StatefulWidget {
  const PreInactivityLogOff({super.key});

  @override
  State<PreInactivityLogOff> createState() => _PreInactivityLogOffState();
}

/// 闲置倒计时登出。P2-2：已迁移至 ShadDialog，去除 BackdropFilter。
class _PreInactivityLogOffState extends State<PreInactivityLogOff> {
  // F-H10/F-H11 修复:倒计时计时器与 StreamController 从文件顶层移入 State,
  // 由 State 的生命周期管理,避免先前的全局 Timer 在对话框关闭后仍触发 pop
  final StreamController<String> _controller =
      StreamController<String>.broadcast();
  final int _timeoutSeconds = PreferencesStorage.preInactivityLogoutCounter;
  int _counter = 0;
  Timer? _timer;
  // 缓存 NavigatorState：倒计时回调异步触发，若此时对话框已被登出导航移除
  // （deactivated），再 Navigator.of(context) 会因查找已停用元素的祖先而崩溃。
  // 这里在 didChangeDependencies 里保存引用，回调只用该引用。
  NavigatorState? _navigator;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigator = Navigator.of(context);
  }

  @override
  void deactivate() {
    // 对话框从路由树移除（如登出导航到登录页）时立即停止倒计时，
    // 避免在 deactivated 状态下定时器仍触发 pop。
    _timer?.cancel();
    super.deactivate();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.close();
    super.dispose();
  }

  void _startTimer() {
    _counter = _timeoutSeconds;
    _timer?.cancel();

    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      (_counter > 0) ? _counter-- : timer.cancel();
      if (!_controller.isClosed) {
        _controller.add(_counter.toString().padLeft(2, '0'));
      }
      if (_counter == 0 && mounted) {
        // 倒计时结束,自动触发登出
        _navigator?.pop();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final initialCounterValue = _timeoutSeconds.toString().padLeft(2, '0');

    return ShadDialog(
      constraints: kAppDialogConstraints,
      title: Text('Logging Off'.tr()),
      actions: [
        shadDialogActionBar(
          actions: [
            ShadDialogAction(
              label: 'Cancel'.tr(),
              onPressed: () => Navigator.of(context).pop(true),
            ),
            ShadDialogAction(
              label: 'Logout'.tr(),
              destructive: true,
              onPressed: () => Navigator.of(context).pop(false),
            ),
          ],
        ),
      ],
      child: Align(
        alignment: Alignment.centerLeft,
        child: StreamBuilder(
          stream: _controller.stream,
          builder: (BuildContext context, AsyncSnapshot<String> snapshot) {
            var countDownTime = snapshot.hasData
                ? '00:${snapshot.data}'
                : ' 00:$initialCounterValue';

            return Text(
              'There was no user activity for quite a while. You will be logged off unless you cancel within {countDownTime} seconds.'
                  .tr(namedArgs: {'countDownTime': countDownTime}),
              style: dialogBodyTextStyle,
            );
          },
        ),
      ),
    );
  }
}

Future<bool?> preInactivityLogOffAlert(BuildContext context) {
  return showAppDialog(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext context) {
      // 倒计时由 _PreInactivityLogOffState.initState 启动,
      // 对话框关闭时 timer 与 stream 由 State.dispose 统一清理
      return const PreInactivityLogOff();
    },
  );
}
