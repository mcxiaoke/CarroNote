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
import 'dart:ui';

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:easy_localization/easy_localization.dart';

// Project imports:
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/widgets/shad_dialog.dart';

class PreInactivityLogOff extends StatefulWidget {
  const PreInactivityLogOff({super.key});

  @override
  State<PreInactivityLogOff> createState() => _PreInactivityLogOffState();
}

class _PreInactivityLogOffState extends State<PreInactivityLogOff> {
  // F-H10/F-H11 修复:倒计时计时器与 StreamController 从文件顶层移入 State,
  // 由 State 的生命周期管理,避免先前的全局 Timer 在对话框关闭后仍触发 pop
  final StreamController<String> _controller =
      StreamController<String>.broadcast();
  final int _timeoutSeconds = PreferencesStorage.preInactivityLogoutCounter;
  int _counter = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _startTimer();
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
        Navigator.of(context).pop();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    const double paddingAllAround = 20.0;
    // P1-14：圆角 10→12，与 ShadDialog（AppShape.cardRadius）一致。
    const double dialogRadius = 12.0;

    return BackdropFilter(
      filter: ImageFilter.blur(),
      child: Dialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(dialogRadius),
        ),
        child: Padding(
          padding: const EdgeInsets.all(paddingAllAround),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _title(),
              _body(paddingAllAround),
              _buildButtons(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _title() {
    final String title = 'Logging Off'.tr();
    const double topSpacing = 10.0;

    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(top: topSpacing), //, right: 100),
        child: Text(title, style: dialogHeadTextStyle),
      ),
    );
  }

  Widget _body(double padding) {
    final initialCounterValue = _timeoutSeconds.toString().padLeft(2, '0');
    const double topSpacing = 15.0;

    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: EdgeInsets.only(top: topSpacing, bottom: padding),
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

  Widget _buildButtons(BuildContext context) {
    return shadDialogActionBar(
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
    );
  }
}

Future<bool?> preInactivityLogOffAlert(BuildContext context) {
  return showDialog(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext context) {
      // 倒计时由 _PreInactivityLogOffState.initState 启动,
      // 对话框关闭时 timer 与 stream 由 State.dispose 统一清理
      return const PreInactivityLogOff();
    },
  );
}
