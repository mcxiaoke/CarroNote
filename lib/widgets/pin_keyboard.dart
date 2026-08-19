/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*/

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:safenotes/models/pin_auth.dart';

/// 自定义键盘(PIN Lock 用)
///
/// 为什么不用系统键盘:第三方输入法可能记录输入、系统键盘会弹窗遮挡、占用
/// 大量屏幕空间。App Lock 场景标准做法是应用内自定义键盘(见
/// docs/pin-lock-design.md §7.3)。
///
/// 布局:字符键按 [keys] 依次排入网格,空字符串为占位格,**删除键固定在
/// 网格最后一格(右下角)**。默认按 [PinCharset.digits] 排布:
///
/// ```
/// 1 2 3
/// 4 5 6
/// 7 8 9
/// [ ] 0 [⌫]
/// ```
///
/// 按键大小自适应:未显式传 [buttonSize] 时,按父约束宽度/高度计算,
/// 键盘自动撑满可用空间(设置页与全屏 PIN 覆盖层通用)。
class PinKeyboard extends StatefulWidget {
  const PinKeyboard({
    super.key,
    required this.onKey,
    required this.onBackspace,
    this.keys = const ['1', '2', '3', '4', '5', '6', '7', '8', '9', '', '0'],
    this.columns = 3,
    this.columnsWide,
    this.shuffle = false,
    this.enabled = true,
    this.buttonSize,
    this.spacing = 12,
  });

  /// 数字/字母按键回调
  final ValueChanged<String> onKey;

  /// 删除键回调
  final VoidCallback onBackspace;

  /// 按键字符序列;空字符串表示占位格(不渲染)
  final List<String> keys;

  /// 每行按键数(竖屏)
  final int columns;

  /// 横屏(宽 > 高)时的每行按键数;null 时始终用 [columns]
  final int? columnsWide;

  /// 随机布局(防偷窥):打乱所有非占位按键;预留功能,默认关闭
  final bool shuffle;

  /// 是否可交互(验证中/锁定期间禁用)
  final bool enabled;

  /// 圆形按键直径;null 时按父约束自适应
  final double? buttonSize;

  /// 按键间距
  final double spacing;

  @override
  State<PinKeyboard> createState() => _PinKeyboardState();
}

class _PinKeyboardState extends State<PinKeyboard> {
  late List<String> _keys;

  @override
  void initState() {
    super.initState();
    _keys = _resolveKeys();
  }

  @override
  void didUpdateWidget(PinKeyboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.keys != widget.keys || oldWidget.shuffle != widget.shuffle) {
      _keys = _resolveKeys();
    }
  }

  List<String> _resolveKeys() {
    final keys = List<String>.from(widget.keys);
    if (!widget.shuffle || keys.length < 3) return keys;
    // 打乱所有非占位按键(数字布局下 0 也会参与打乱,防偷窥更彻底)
    final shuf = keys.where((k) => k.isNotEmpty).toList()..shuffle();
    final it = shuf.iterator;
    return [for (final k in keys) k.isEmpty || !it.moveNext() ? k : it.current];
  }

  @override
  Widget build(BuildContext context) {
    final keys = _keys;
    // 网格总格数 = 字符键 + 1(删除键固定在末尾)
    final totalCells = keys.length + 1;

    return LayoutBuilder(
      builder: (context, constraints) {
        // 横屏(宽 > 高)且配置了 columnsWide 时切换列数(如 4×5 → 5×4)
        final columns =
            widget.columnsWide != null &&
                constraints.maxWidth > constraints.maxHeight
            ? widget.columnsWide!
            : widget.columns;
        final rowCount = (totalCells / columns).ceil();
        final gridSize = rowCount * columns;

        final size = _resolveButtonSize(constraints, rowCount, columns);
        final rows = <Widget>[];
        for (var r = 0; r < rowCount; r++) {
          final cells = <Widget>[];
          for (var c = 0; c < columns; c++) {
            final idx = r * columns + c;
            cells.add(_buildCell(idx, gridSize, keys, size));
          }
          rows.add(
            Padding(
              padding: EdgeInsets.only(bottom: widget.spacing),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var c = 0; c < cells.length; c++) ...[
                    if (c > 0) SizedBox(width: widget.spacing),
                    cells[c],
                  ],
                ],
              ),
            ),
          );
        }
        return Column(mainAxisSize: MainAxisSize.min, children: rows);
      },
    );
  }

  /// 计算按键直径:显式传入优先;否则按「宽/高两个方向都放得下」取小者,
  /// 并限制在 40~140 之间,避免小屏溢出或大屏无意义放大。
  double _resolveButtonSize(
    BoxConstraints constraints,
    int rowCount,
    int columns,
  ) {
    if (widget.buttonSize != null) return widget.buttonSize!;
    final byWidth =
        (constraints.maxWidth - widget.spacing * (columns - 1)) / columns;
    final byHeight = constraints.maxHeight.isFinite
        ? (constraints.maxHeight - widget.spacing * (rowCount - 1)) / rowCount
        : double.infinity;
    return math.min(byWidth, byHeight).clamp(40.0, 140.0);
  }

  Widget _buildCell(int idx, int gridSize, List<String> keys, double size) {
    final isBackspace = idx == keys.length;
    // 字符键已排完且非删除键 → 空白占位(保持网格形状)
    if (idx >= keys.length && !isBackspace) {
      return SizedBox(width: size, height: size);
    }
    final label = isBackspace ? '' : keys[idx];
    if (label.isEmpty && !isBackspace) {
      return SizedBox(width: size, height: size);
    }
    final colors = Theme.of(context).colorScheme;
    final VoidCallback? onTap = widget.enabled
        ? () => isBackspace ? widget.onBackspace() : widget.onKey(label)
        : null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: colors.primaryContainer,
          ),
          alignment: Alignment.center,
          child: isBackspace
              ? Icon(
                  Icons.backspace_outlined,
                  size: size * 0.38,
                  color: colors.onPrimaryContainer,
                )
              : Text(
                  label,
                  style: TextStyle(
                    fontSize: size * 0.38,
                    fontWeight: FontWeight.w500,
                    color: colors.onPrimaryContainer,
                  ),
                ),
        ),
      ),
    );
  }
}
