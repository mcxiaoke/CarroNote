// 闲置倒计时登出对话框。
//
// 按钮事件语义与 showAppConfirm 相反（这里 cancel→true 留页，confirm→false 登出），
// 因此不直接复用 showAppConfirm，自己包一个 ShadDialog。

// Dart imports:
import 'dart:async';

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:easy_localization/easy_localization.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

// Project imports:
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/widgets/shad_dialog.dart';

/// 闲置倒计时登出对话框：
///   - 返回 true = 用户取消倒计时（留在当前页）
///   - 返回 false = 倒计时结束自动登出 / 用户主动登出
///   - 返回 null = 对话框被异常关闭
Future<bool?> preInactivityLogOffAlert(BuildContext context) {
  return showAppDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _LogOffDialog(),
  );
}

class _LogOffDialog extends StatefulWidget {
  const _LogOffDialog();

  @override
  State<_LogOffDialog> createState() => _LogOffDialogState();
}

class _LogOffDialogState extends State<_LogOffDialog> {
  late int _counter = PreferencesStorage.preInactivityLogoutCounter;
  Timer? _timer;
  NavigatorState? _navigator;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigator = Navigator.of(context);
  }

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_counter <= 0) {
        _timer?.cancel();
        if (mounted) _navigator?.pop(false); // 倒计时结束 → 自动登出
        return;
      }
      setState(() => _counter--);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cd = _counter.toString().padLeft(2, '0');
    return ShadDialog.alert(
      scrollable: false,
      padding: EdgeInsets.zero,
      title: Text('Logging Off'.tr()),
      description: Text(
        'There was no user activity for quite a while. '
                'You will be logged off unless you cancel within {countDownTime} seconds.'
            .tr(namedArgs: {'countDownTime': ' 00:$cd'}),
      ),
      actions: [
        // 取消 → 留页（返回 true）
        ShadButton.outline(
          onPressed: () => _navigator?.pop(true),
          child: Text('Cancel'.tr()),
        ),
        // 退出 → 登出（返回 false）
        ShadButton.destructive(
          onPressed: () => _navigator?.pop(false),
          child: Text('Logout'.tr()),
        ),
      ],
    );
  }
}
