/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*/

import 'package:flutter/material.dart';

import 'package:easy_localization/easy_localization.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/pin_auth.dart';
import 'package:safenotes/utils/platform_ui.dart';
import 'package:safenotes/utils/snack_message.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/widgets/app_dialogs.dart';
import 'package:safenotes/widgets/pin_keyboard.dart';
import 'package:safenotes/widgets/shad_settings_tiles.dart';

/// PIN Lock 设置页(与生物识别设置页平行,见 docs/pin-lock-design.md §7.1)
///
/// 未启用:开关 → 打开进入设置流程(选长度 4/6/8 → 输入两次新 PIN)。
/// 已启用:「Change PIN」(验证当前 PIN → 选长度 → 两次新 PIN)、
/// 「Disable PIN Lock」(已登入则无条件直接关闭,无需验证当前 PIN)。
class PinSetting extends StatefulWidget {
  const PinSetting({super.key});

  @override
  State<PinSetting> createState() => _PinSettingState();
}

class _PinSettingState extends State<PinSetting> {
  /// 是否处于设置流程视图(选长度 / 输入 PIN)
  bool _flowActive = false;

  /// 当前流程模式
  _PinFlowMode _flowMode = _PinFlowMode.enable;

  /// 流程中是否出现验证/提交中状态,禁用交互防并发
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('PIN Lock'.tr(), style: appBarTitle)),
      body: _flowActive ? _buildFlow() : _buildSettingsList(),
    );
  }

  // ──────────────────────────────────────────────
  // 设置列表
  // ──────────────────────────────────────────────

  Widget _buildSettingsList() {
    final enabled = PreferencesStorage.isPinAuthEnabled;
    return shadSettingsList([
      shadSettingsCard([
        if (!enabled)
          shadSwitchTile(
            context,
            icon: LucideIcons.key,
            title: 'Enable PIN Lock'.tr(),
            description:
                'Quickly unlock with a PIN instead of your passphrase. '
                        'PIN cannot be recovered if forgotten.'
                    .tr(),
            value: false,
            onChanged: (value) {
              if (!value || _busy) return;
              _startFlow(_PinFlowMode.enable);
            },
          )
        else
          shadInfoTile(
            context,
            icon: LucideIcons.key,
            title: 'PIN Lock'.tr(),
            description: 'Status'.tr(),
            value: 'Enabled · {n} digits'.tr(
              namedArgs: {'n': '${PreferencesStorage.pinLength}'},
            ),
          ),
        if (enabled) ...[
          shadNavigationTile(
            context,
            key: const Key('ui-setting-item-change-pin'),
            icon: LucideIcons.refreshCw,
            title: 'Change PIN'.tr(),
            onTap: _busy ? () {} : () => _startFlow(_PinFlowMode.change),
          ),
          shadNavigationTile(
            context,
            key: const Key('ui-setting-item-disable-pin'),
            icon: LucideIcons.lockOpen,
            title: 'Disable PIN Lock'.tr(),
            destructive: true,
            onTap: _busy ? () {} : () => _confirmDisable(),
          ),
        ],
      ]),
      const SizedBox(height: 12),
    ]);
  }

  /// 无条件关闭 PIN:用户已登入,无需验证当前 PIN 即可直接关闭
  /// (关闭后回退到用主密码解锁,不降低安全性)。仅弹一次确认防误触。
  ///
  /// 确认框走 app 标准 M3 AlertDialog([showAppDestructive]):整卡圆角 + 阴影,
  /// 取消=描边按钮、确认=破坏性红按钮,与删除/登出等危险操作保持一致。
  Future<void> _confirmDisable() async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await showAppDestructive(
      context,
      title: 'Disable PIN Lock'.tr(),
      message:
          'You are signed in. The PIN lock will be removed and you will use '
                  'your passphrase to unlock.'
              .tr(),
      confirmLabel: 'Disable'.tr(),
    );
    if (!mounted) return;
    if (ok == true) {
      await PinAuth.disable();
      if (mounted) {
        showSnackBarMessage(context, 'PIN Lock disabled'.tr());
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  void _startFlow(_PinFlowMode mode) {
    setState(() {
      _flowMode = mode;
      _flowActive = true;
    });
  }

  Widget _buildFlow() {
    return _PinFlow(
      mode: _flowMode,
      onDone: () {
        setState(() {
          _flowActive = false;
          _busy = false;
        });
      },
    );
  }
}

enum _PinFlowMode { enable, change }

/// PIN 设置流程视图
///
/// 步骤按模式组合:
/// - enable:  选长度 → 输入新 PIN → 确认
/// - change:  验证当前 PIN → 选长度 → 输入新 PIN → 确认
/// (disable 为无条件关闭,不走流程,见 [_PinSettingState._confirmDisable])
class _PinFlow extends StatefulWidget {
  const _PinFlow({required this.mode, required this.onDone});

  final _PinFlowMode mode;
  final VoidCallback onDone;

  @override
  State<_PinFlow> createState() => _PinFlowState();
}

enum _PinStep { chooseLength, verifyCurrent, enterNew, confirmNew }

class _PinFlowState extends State<_PinFlow> {
  late _PinStep _step;
  int _length = PreferencesStorage.kPinDefaultLength;
  PinCharset _charset = PinCharset.digits;
  bool _shuffle = false;
  String _firstPin = '';
  String? _errorText;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // 验证当前 PIN 时必须用已存策略;enable 模式可在选择步骤修改
    _length = PreferencesStorage.pinLength;
    _charset = PinCharset.fromIndex(PreferencesStorage.pinCharsetIndex);
    _shuffle = PreferencesStorage.pinShuffleEnabled;
    _step = switch (widget.mode) {
      _PinFlowMode.enable => _PinStep.chooseLength,
      _PinFlowMode.change => _PinStep.verifyCurrent,
    };
  }

  @override
  Widget build(BuildContext context) {
    // PIN 输入步骤(验证/新建/确认)放开宽度上限,让手机横屏能触发 PinKeyboard
    // 的宽屏布局(高度无限时按「宽度≥560」判定);长度/键盘类型选择保持紧凑
    // (kDialogMaxWidthCompact)便于看清全部选项。
    final bool pinEntry = _step != _PinStep.chooseLength;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: pinEntry ? double.infinity : kDialogMaxWidthCompact,
        ),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _buildTitle(),
            const SizedBox(height: 20),
            switch (_step) {
              _PinStep.chooseLength => _buildLengthChooser(),
              _PinStep.verifyCurrent ||
              _PinStep.enterNew ||
              _PinStep.confirmNew => _buildPinEntry(),
            },
          ],
        ),
      ),
    );
  }

  Widget _buildTitle() {
    final theme = ShadTheme.of(context);
    final String title = switch (_step) {
      _PinStep.chooseLength => 'Choose PIN length'.tr(),
      _PinStep.verifyCurrent => 'Enter current PIN'.tr(),
      _PinStep.enterNew => 'Choose PIN'.tr(),
      _PinStep.confirmNew => 'Confirm PIN'.tr(),
    };
    return Column(
      children: [
        Text(
          title,
          textAlign: TextAlign.center,
          style: theme.textTheme.p.copyWith(fontSize: 16),
        ),
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
      ],
    );
  }

  // ── 选长度 + 键盘类型 ─────────────────────────

  Widget _buildLengthChooser() {
    final theme = ShadTheme.of(context);
    return Column(
      children: [
        Text(
          'PIN Length'.tr(),
          style: theme.textTheme.muted.copyWith(fontSize: 13),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (final len in PreferencesStorage.pinLengthOptions) ...[
              if (len != PreferencesStorage.pinLengthOptions.first)
                const SizedBox(width: 12),
              _LengthOption(
                length: len,
                selected: _length == len,
                onTap: () => setState(() => _length = len),
              ),
            ],
          ],
        ),
        const SizedBox(height: 20),
        Text(
          'Keyboard Type'.tr(),
          style: theme.textTheme.muted.copyWith(fontSize: 13),
        ),
        const SizedBox(height: 8),
        // 键盘类型竖排(窄屏不溢出,宽屏由外层 ConstrainedBox 限宽居中)
        ShadCard(
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < PinCharset.values.length; i++) ...[
                if (i > 0)
                  const Divider(
                    height: 1,
                    thickness: 1,
                    indent: 14,
                    endIndent: 14,
                  ),
                shadRadioTile(
                  context,
                  title: _charsetTitle(PinCharset.values[i]),
                  description: _charsetSubtitle(PinCharset.values[i]),
                  selected: _charset == PinCharset.values[i],
                  onTap: () => setState(() => _charset = PinCharset.values[i]),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 24),
        // 随机键序(防肩窥):每次打开键盘打乱键位顺序,默认关闭
        KeyedSubtree(
          key: const Key('ui-pin-setting-shuffle'),
          child: shadSwitchTile(
            context,
            icon: LucideIcons.shuffle,
            title: 'Random keypad order'.tr(),
            description:
                'Shuffle the keys each time to protect against '
                        'shoulder-surfing.'
                    .tr(),
            value: _shuffle,
            onChanged: (value) => setState(() => _shuffle = value),
          ),
        ),
        const SizedBox(height: 24),
        ShadButton(
          width: double.infinity,
          onPressed: _busy
              ? null
              : () => setState(() => _step = _PinStep.enterNew),
          child: Text('Next'.tr()),
        ),
        const SizedBox(height: 8),
        Center(
          child: TextButton(
            onPressed: widget.onDone,
            child: Text('Cancel'.tr()),
          ),
        ),
      ],
    );
  }

  String _charsetTitle(PinCharset charset) => switch (charset) {
    PinCharset.digits => 'Digits'.tr(),
    PinCharset.alphanumeric => 'Digits & Letters'.tr(),
    PinCharset.letters => 'Full keyboard'.tr(),
  };

  String _charsetSubtitle(PinCharset charset) => switch (charset) {
    PinCharset.digits => '3×4 · 10 keys',
    PinCharset.alphanumeric => '4×6 · 10 digits + 13 letters',
    PinCharset.letters => '5×8 · 10 digits + 26 letters + 3 symbols',
  };

  // ── PIN 输入(验证当前 / 输入新 / 确认新)──

  Widget _buildPinEntry() {
    final theme = ShadTheme.of(context);
    return Column(
      children: [
        // 圆点指示:与设置中的长度一致(验证当前 PIN 时读取已存长度)
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < _length; i++) ...[
              if (i > 0) const SizedBox(width: 14),
              AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i < _currentInput.length
                      ? _errorText != null
                            ? theme.colorScheme.destructive
                            : theme.colorScheme.primary
                      : Colors.transparent,
                  border: Border.all(
                    color: _errorText != null
                        ? theme.colorScheme.destructive
                        : theme.colorScheme.border,
                    width: 1.5,
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 20),
        Focus(
          autofocus: true,
          onKeyEvent: _onHardwareKey,
          child: PinKeyboard(
            keys: _charset.keys,
            columns: _charset.columns,
            columnsWide: _charset.columnsWide,
            // 移动端横屏改用流式布局(与解锁覆盖层一致),最少两行避免数字键盘挤成一行。
            wrap: isCompactLandscape(context),
            wrapMinRows: 2,
            shuffle: _shuffle,
            enabled: !_busy,
            onKey: _onDigit,
            onBackspace: _onBackspace,
            keyStyle: PinKeyStyle.outline,
            keyColor: theme.colorScheme.primary,
          ),
        ),
        const SizedBox(height: 12),
        Center(
          child: TextButton(
            onPressed: widget.onDone,
            child: Text('Cancel'.tr()),
          ),
        ),
      ],
    );
  }

  String _currentInput = '';

  /// 桌面端硬件键盘输入:委托给共享的 [handlePinKeyEvent]。
  KeyEventResult _onHardwareKey(FocusNode node, KeyEvent event) {
    return handlePinKeyEvent(
      charsetKeys: _charset.keys,
      enabled: !_busy,
      onDigit: _onDigit,
      onBackspace: _onBackspace,
      event: event,
    );
  }

  void _onDigit(String digit) {
    if (_currentInput.length >= _length || _busy) return;
    setState(() {
      _currentInput += digit;
      _errorText = null;
    });
    if (_currentInput.length == _length) {
      _onEntryCompleted();
    }
  }

  void _onBackspace() {
    if (_currentInput.isEmpty || _busy) return;
    setState(() {
      _currentInput = _currentInput.substring(0, _currentInput.length - 1);
      _errorText = null;
    });
  }

  Future<void> _onEntryCompleted() async {
    setState(() => _busy = true);
    final pin = _currentInput;
    _currentInput = '';
    switch (_step) {
      case _PinStep.verifyCurrent:
        await _handleVerifyCurrent(pin);
      case _PinStep.enterNew:
        setState(() {
          _firstPin = pin;
          _step = _PinStep.confirmNew;
          _busy = false;
        });
      case _PinStep.confirmNew:
        await _handleConfirmNew(pin);
      case _PinStep.chooseLength:
        break;
    }
  }

  Future<void> _handleVerifyCurrent(String pin) async {
    final passphrase = await PinAuth.verifyPin(pin);
    if (!mounted) return;
    if (passphrase.isEmpty) {
      setState(() {
        _errorText = 'Wrong PIN.'.tr();
        _busy = false;
      });
      return;
    }
    setState(() {
      _step = _PinStep.chooseLength;
      _busy = false;
    });
  }

  Future<void> _handleConfirmNew(String pin) async {
    if (pin != _firstPin) {
      if (!mounted) return;
      setState(() {
        _errorText = 'PINs do not match. Try again.'.tr();
        _firstPin = '';
        _step = _PinStep.enterNew;
        _busy = false;
      });
      return;
    }
    await PinAuth.setPin(
      pin,
      policy: PinPolicy(length: _length, charset: _charset, shuffle: _shuffle),
    );
    if (!mounted) return;
    showSnackBarMessage(context, 'PIN Lock enabled'.tr());
    widget.onDone();
  }
}

/// 长度选项卡片(4 / 6 / 8)
class _LengthOption extends StatelessWidget {
  const _LengthOption({
    required this.length,
    required this.selected,
    required this.onTap,
  });

  final int length;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          width: 72,
          height: 56,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: selected
                ? theme.colorScheme.primary.withValues(alpha: 0.12)
                : Colors.transparent,
            border: Border.all(
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.border,
              width: selected ? 1.5 : 1,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            '$length',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w500,
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.foreground,
            ),
          ),
        ),
      ),
    );
  }
}
