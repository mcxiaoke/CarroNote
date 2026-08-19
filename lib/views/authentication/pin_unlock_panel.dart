/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*/

import 'package:flutter/material.dart';

import 'package:core/core.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/pin_auth.dart';
import 'package:safenotes/widgets/pin_keyboard.dart';

/// 登录页 PIN 解锁覆盖层(与生物识别弹窗平行的快捷解锁方式)
///
/// 由登录页以 `showDialog + Dialog.fullscreen` 全屏覆盖在登录界面之上,
/// 与生物识别系统弹窗体验一致。包含:圆点输入指示 + [PinKeyboard] +
/// 满位自动验证 + 「Use passphrase」退出入口。
///
/// 连续失败达到阈值后自动关闭 PIN 并提示改用密码登录
/// (见 docs/pin-lock-design.md §6)。
class PinUnlockPanel extends StatefulWidget {
  const PinUnlockPanel({
    super.key,
    required this.onAuthenticated,
    this.onDismiss,
  });

  /// PIN 验证通过后回调,参数为解出的 vault 密码(父级复用现有登录流程)
  final Future<void> Function(String passphrase) onAuthenticated;

  /// 用户选择「Use passphrase」或 PIN 已被关闭时触发(父级关闭覆盖层)
  final VoidCallback? onDismiss;

  @override
  State<PinUnlockPanel> createState() => _PinUnlockPanelState();
}

class _PinUnlockPanelState extends State<PinUnlockPanel> {
  String _pin = '';
  String? _errorText;
  bool _verifying = false;

  /// PIN 因连续失败被自动关闭(回退密码登录)
  bool _disabled = false;

  int get _length => PreferencesStorage.pinLength;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    if (_disabled) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                LucideIcons.lock,
                size: 40,
                color: theme.colorScheme.destructive,
              ),
              const SizedBox(height: 16),
              Text(
                'PIN lock was disabled after multiple failed attempts. '
                        'Please sign in with your passphrase.'
                    .tr(),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: theme.colorScheme.destructive,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 16),
              ShadButton(
                onPressed: widget.onDismiss,
                child: Text('Use passphrase'.tr()),
              ),
            ],
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // 内容占可用空间 80%(键盘在下方自适应撑满剩余空间)
        final maxW = constraints.maxWidth * 0.8;
        final maxH = constraints.maxHeight * 0.8;
        final charset = PinCharset.fromIndex(
          PreferencesStorage.pinCharsetIndex,
        );
        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxW, maxHeight: maxH),
            child: Column(
              children: [
                Icon(
                  LucideIcons.lock,
                  size: 40,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 12),
                Text(
                  'PIN Lock'.tr(),
                  style: theme.textTheme.p.copyWith(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Enter your PIN'.tr(),
                  style: TextStyle(
                    color: theme.colorScheme.mutedForeground,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 20),
                _buildDots(theme.colorScheme),
                if (_errorText != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _errorText!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: theme.colorScheme.destructive,
                        fontSize: 13,
                      ),
                    ),
                  ),
                // 键盘自适应撑满剩余空间(按键大小随窗口缩放)
                Expanded(
                  child: Center(
                    child: PinKeyboard(
                      keys: charset.keys,
                      columns: charset.columns,
                      columnsWide: charset.columnsWide,
                      enabled: !_verifying,
                      onKey: _onDigit,
                      onBackspace: _onBackspace,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                TextButton(
                  onPressed: widget.onDismiss,
                  child: Text('Use passphrase'.tr()),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 圆点输入指示:已输入实心,未输入空心;错误态红色
  Widget _buildDots(ShadColorScheme theme) {
    final bool hasError = _errorText != null;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < _length; i++) ...[
          if (i > 0) const SizedBox(width: 14),
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: i < _pin.length
                  ? hasError
                        ? theme.destructive
                        : theme.primary
                  : Colors.transparent,
              border: Border.all(
                color: hasError ? theme.destructive : theme.border,
                width: 1.5,
              ),
            ),
          ),
        ],
      ],
    );
  }

  void _onDigit(String digit) {
    if (_pin.length >= _length || _verifying) return;
    setState(() {
      _pin += digit;
      _errorText = null;
    });
    if (_pin.length == _length) {
      _onCompleted();
    }
  }

  void _onBackspace() {
    if (_pin.isEmpty || _verifying) return;
    setState(() {
      _pin = _pin.substring(0, _pin.length - 1);
      _errorText = null;
    });
  }

  Future<void> _onCompleted() async {
    setState(() => _verifying = true);
    final passphrase = await PinAuth.verifyPin(_pin);
    if (passphrase.isNotEmpty) {
      // 验证通过:父级复用现有 _login(passphrase) 并导航离开;
      // 若父级未导航(异常路径),恢复键盘可交互,避免卡死
      await widget.onAuthenticated(passphrase);
      if (mounted) setState(() => _verifying = false);
      return;
    }
    // 验证失败:计数 +1,达到阈值自动关闭
    final closed = await PinAuth.onPinFailed();
    if (!mounted) return;
    if (closed) {
      Log.auth.w('PIN 解锁覆盖层: 已因多次失败自动关闭');
      setState(() {
        _disabled = true;
        _pin = '';
        _errorText = null;
        _verifying = false;
      });
      return;
    }
    final remaining =
        PinAuth.kPinMaxFailedAttempts - PreferencesStorage.pinFailedCount;
    setState(() {
      _errorText = 'Wrong PIN. {n} attempts remaining.'.tr(
        namedArgs: {'n': '$remaining'},
      );
      _pin = '';
      _verifying = false;
    });
  }
}
