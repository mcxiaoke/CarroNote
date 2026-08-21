/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*/

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:core/core.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/pin_auth.dart';
import 'package:safenotes/widgets/pin_keyboard.dart';

/// PIN 解锁卡片最大宽度:约屏宽的常宽面板,宽到足以触发 PinKeyboard 的宽屏布局
/// (其宽度阈值 [PinKeyboard.kWideBreakpoint]=560),让 letters 全键盘在桌面用宽屏列数
/// (如 8×5);横屏下也尽量撑宽,减少两侧大片空白。
const double kPinOverlayMaxWidth = 780;

/// 登录页 PIN 解锁覆盖层(与生物识别弹窗平行的快捷解锁方式)
///
/// 由登录页以 `showDialog` 全屏遮罩弹出,呈现为带圆角 + 阴影的对话框卡片,
/// 覆盖在登录界面之上(与生物识别系统弹窗体验一致)。包含:圆点输入指示 +
/// [PinKeyboard] + 满位自动验证 + 「Use passphrase」退出入口。
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
    // 桌面端允许用硬件键盘直接输入 PIN(autofocus 确保能收到物理按键)。
    final charset = PinCharset.fromIndex(PreferencesStorage.pinCharsetIndex);
    // 空间很矮时（移动横屏 / 桌面被拉矮的窗口）隐藏装饰 Icon 与「PIN Lock」标题，
    // 只保留引导文案 + 进度圆点 + 使用密码，把高度让给键盘；桌面窗口可自由 resize，
    // 也会出现矮横屏（如 890x400），因此不再依赖 isCompactLandscape（仅移动平台），
    // 改为高度低于阈值即启用紧凑布局。
    final bool compactHeader = MediaQuery.sizeOf(context).height < 560;
    return Focus(
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: Material(
        type: MaterialType.transparency,
        // 与 home 页一致,不用 SafeArea,浮层直接占满全屏(inset 由 DialogRoute
        // 的 useSafeArea:false 接管,此处不再做任何安全区伸缩)。
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 卡片高度封顶为可用高度减上下边距:卡片永不超出屏幕,顶部/底部圆角
            // 始终完整可见。可滚动部分只在「键盘」区(见键盘的 Flexible),滚动时
            // 不移动卡片本身,因此不会出现之前那种「滚一下圆角变直角/白角」。
            final double cardMaxH = math.max(120.0, constraints.maxHeight - 32);
            return Center(
              child: Container(
                // 卡片带圆角 + 阴影 + 对话框表面色,不再是光板长方形。
                // 移动端横屏下尽量撑满可用空间(宽度铺满,四周统一 16 边距)。
                width: compactHeader ? double.infinity : null,
                margin: const EdgeInsets.all(16),
                constraints: BoxConstraints(
                  maxWidth: kPinOverlayMaxWidth,
                  maxHeight: cardMaxH,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.30),
                      blurRadius: 24,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 28,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!compactHeader) ...[
                        // 图标与「PIN Lock」同一行,省下竖排的空间。
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              LucideIcons.lock,
                              size: 28,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: 10),
                            Text(
                              'PIN Lock'.tr(),
                              style: theme.textTheme.p.copyWith(
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
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
                      ] else
                        // 移动端横屏:空间很矮,把「输入指引 + 进度圆点 + 使用密码登录」
                        // 三要素合并到同一行顶部,下方空间全部留给键盘。
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              flex: 1,
                              child: Text(
                                'Enter your PIN'.tr(),
                                style: TextStyle(
                                  color: theme.colorScheme.mutedForeground,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            _buildDots(theme.colorScheme),
                            Expanded(
                              flex: 1,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  TextButton(
                                    key: const Key('ui-pin-use-passphrase'),
                                    onPressed: widget.onDismiss,
                                    style: TextButton.styleFrom(
                                      minimumSize: Size.zero,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                      ),
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                    ),
                                    child: Text('Use passphrase'.tr()),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      // 固定高度的「状态提示」槽:错误文本出现/消失、验证中切换加载圈
                      // 都不改变总高度,键盘位置稳定不上下跳。错误文本单行省略,防止
                      // 换行撑高再加跳动。
                      SizedBox(
                        height: compactHeader ? 20 : 24,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: _verifying
                              ? const Center(
                                  child: SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                )
                              : _errorText == null
                              ? null
                              : Center(
                                  child: Text(
                                    _errorText!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: theme.colorScheme.destructive,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                        ),
                      ),
                      // 键盘区可伸缩:空间充足时键盘按自然尺寸(按宽屏/窄屏列数自适应),
                      // 空间不足(如横屏+全键盘)时先收缩按键、再在卡片内部单独滚动,
                      // 「Use passphrase」始终固定在下方,绝不压住键盘。
                      // 移动端横屏(compactHeader)走流式布局:字符键顺序铺排、
                      // 按宽度自动换行,不再依赖网格列数。
                      Flexible(
                        child: SingleChildScrollView(
                          child: PinKeyboard(
                            wrap: compactHeader,
                            wrapMinRows: 2,
                            keys: charset.keys,
                            columns: charset.columns,
                            columnsWide: charset.columnsWide,
                            shuffle: PreferencesStorage.pinShuffleEnabled,
                            enabled: !_verifying,
                            onKey: _onDigit,
                            onBackspace: _onBackspace,
                            keyStyle: PinKeyStyle.outline,
                            keyColor: theme.colorScheme.primary,
                          ),
                        ),
                      ),
                      if (!compactHeader) ...[
                        const SizedBox(height: 8),
                        TextButton(
                          key: const Key('ui-pin-use-passphrase'),
                          onPressed: widget.onDismiss,
                          child: Text('Use passphrase'.tr()),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// 桌面端硬件键盘输入处理:委托给共享的 [handlePinKeyEvent]。
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    return handlePinKeyEvent(
      charsetKeys: PinCharset.fromIndex(
        PreferencesStorage.pinCharsetIndex,
      ).keys,
      enabled: !_verifying,
      onDigit: _onDigit,
      onBackspace: _onBackspace,
      event: event,
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
              color: hasError
                  ? (i < _pin.length ? theme.destructive : Colors.transparent)
                  : (i < _pin.length ? theme.primary : Colors.transparent),
              // 空心圆用「按键背景色」accent(= primaryContainer)描边:在卡片表面
              // surfaceContainerHigh 上清晰可见;实心圆边框跟随填充,视觉上是一个点。
              border: Border.all(
                color: hasError
                    ? theme.destructive
                    : (i < _pin.length ? theme.primary : theme.accent),
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
