/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*/

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:safenotes/models/pin_auth.dart';

/// 桌面端硬件键盘输入 PIN 的共享处理函数(解锁覆盖层 / 设置 & 修改 PIN 界面共用)。
///
/// 物理键盘按下当前字符集([charsetKeys],即 `PinCharset.keys`)内的可见字符时调用
/// [onDigit] 追加,Backspace 调用 [onBackspace];非字符集键、验证/忙态、无可见
/// 字符的修饰键忽略。返回 [KeyEventResult.handled] 表示按键已被本处理器消费。
KeyEventResult handlePinKeyEvent({
  required List<String> charsetKeys,
  required bool enabled,
  required ValueChanged<String> onDigit,
  required VoidCallback onBackspace,
  required KeyEvent event,
}) {
  if (event is! KeyDownEvent) return KeyEventResult.ignored;
  if (event.logicalKey == LogicalKeyboardKey.backspace) {
    onBackspace();
    return KeyEventResult.handled;
  }
  final char = event.character;
  if (char == null || char.isEmpty) return KeyEventResult.ignored;
  if (!enabled) return KeyEventResult.ignored;
  if (!charsetKeys.contains(char)) return KeyEventResult.ignored;
  onDigit(char);
  return KeyEventResult.handled;
}

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
///
/// 按键直径硬限制 [kMinButtonSize]~[kMaxButtonSize]:小屏不溢出、
/// 大屏(桌面)不无限放大。
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
    this.wrap = false,
    this.wrapMinRows = 1,
  });

  /// 自动布局时按键直径下限(触控可用,参见 [kMinButtonSize])
  static const double kMinButtonSize = 48;

  /// 自动布局时按键直径上限(桌面大屏不喧宾夺主,参见 [kMaxButtonSize])
  static const double kMaxButtonSize = 72;

  /// 高度不受约束(如 ListView / 设置页)时,宽度达到该值即视为宽屏
  static const double kWideBreakpoint = 560;

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

  /// 流式布局(横向 Flex / 自动换行):忽略 [columns]/[columnsWide],把字符键
  /// 按顺序铺排、宽度不足时自动折行,删除键跟在末尾。适用于空间很矮的横屏
  /// (键盘文字顺序摆放、自动换行),无需算网格列数。
  final bool wrap;

  /// 流式布局([wrap] 为 true)时的最少行数,防止窄高空间(如横屏)把键盘压成
  /// 单行——例如纯数字键盘(10 数字 + 删除)在宽横屏下若不受限会排成一行,
  /// 设 [wrapMinRows]=2 即强制折成至少两行(6+5)。行数本就更多的键盘(letters)
  /// 不受影响。
  final int wrapMinRows;

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
        // 流式布局:字符键顺序铺排 + 自动换行,省去网格/列数计算。
        if (widget.wrap) {
          final size = widget.buttonSize ?? PinKeyboard.kMinButtonSize;
          return _buildWrap(keys, size, constraints.maxWidth);
        }
        // 宽屏(横屏 / 桌面宽窗)时切到更多列更少行(如 4×5 → 5×4)。
        // 高度不受约束(设置页 ListView 中)时退化为按宽度阈值判断。
        final isWide =
            widget.columnsWide != null && _isWideConstraints(constraints);
        final columns = isWide ? widget.columnsWide! : widget.columns;
        final rowCount = (totalCells / columns).ceil();

        final size = _resolveButtonSize(constraints, rowCount, columns);
        final rows = <Widget>[];
        for (var r = 0; r < rowCount; r++) {
          final cells = <Widget>[];
          for (var c = 0; c < columns; c++) {
            final idx = r * columns + c;
            cells.add(_buildCell(idx, keys, size));
          }
          rows.add(
            Padding(
              // 行间留白;最后一行不再吞掉底部 spacing,避免窄高容器按公式算好
              // (rowCount*size + (rowCount-1)*spacing) 后仍被额外 padding 顶出溢出
              padding: EdgeInsets.only(
                bottom: r < rowCount - 1 ? widget.spacing : 0,
              ),
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

  /// 宽屏判定:高度有限时按宽 > 高(横屏 / 桌面宽窗);
  /// 高度无限(ListView 内)时按宽度是否达到 [PinKeyboard.kWideBreakpoint]。
  bool _isWideConstraints(BoxConstraints constraints) {
    final maxH = constraints.maxHeight;
    if (maxH.isFinite) return constraints.maxWidth > maxH;
    return constraints.maxWidth >= PinKeyboard.kWideBreakpoint;
  }

  /// 计算按键直径:显式传入优先;否则按「宽/高两个方向都放得下」取小者,
  /// 并限制在 [PinKeyboard.kMinButtonSize]~[PinKeyboard.kMaxButtonSize]
  /// 之间,避免小屏溢出或大屏(桌面)无意义放大。
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
    return math
        .min(byWidth, byHeight)
        .clamp(PinKeyboard.kMinButtonSize, PinKeyboard.kMaxButtonSize);
  }

  Widget _buildCell(int idx, List<String> keys, double size) {
    final isBackspace = idx == keys.length;
    // 字符键已排完且非删除键 → 空白占位(保持网格形状)
    if (!isBackspace && idx >= keys.length) {
      return SizedBox(width: size, height: size);
    }
    final label = isBackspace ? '' : keys[idx];
    if (!isBackspace && label.isEmpty) {
      return SizedBox(width: size, height: size);
    }
    return _buildKeyButton(label: label, isBackspace: isBackspace, size: size);
  }

  /// 流式布局:字符键按顺序铺排,宽度不足自动折行,删除键跟在末尾。
  ///
  /// [wrapMinRows]<=1 或按键很少时走原生 [Wrap](所有行统一居中,含末行半行);
  /// [wrapMinRows]>1 且按键较多时按「每行最多 [maxPerRow] 个」显式分行列排,
  /// 满行居中、末行左对齐(像实体键盘那样,而不是把半行也居中)。
  ///
  /// [maxWidthAvail] 为父约束宽度(可能是无限),用于限制每行最多按键数,
  /// 避免大键盘(letters 40 键)被 [wrapMinRows] 压成 2 行并横向溢出——
  /// 每行上限取「按行数算」与「按可用宽度算」的较小者。
  Widget _buildWrap(List<String> keys, double size, double maxWidthAvail) {
    final children = <Widget>[
      for (final k in keys)
        if (k.isNotEmpty)
          _buildKeyButton(label: k, isBackspace: false, size: size),
      _buildKeyButton(label: '', isBackspace: true, size: size),
    ];
    if (widget.wrapMinRows <= 1 || children.length <= widget.wrapMinRows) {
      return Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: widget.spacing,
        runSpacing: widget.spacing,
        children: children,
      );
    }
    // 每行最多按键数:既能保证至少 [wrapMinRows] 行(防数字键盘挤成 1 行),
    // 又不超出可用宽度(防 letters 被挤成 2 行溢出)。
    final byRows = (children.length / widget.wrapMinRows).ceil();
    final byWidth = maxWidthAvail.isFinite && maxWidthAvail > 0
        ? (maxWidthAvail / (size + widget.spacing)).floor()
        : byRows;
    final maxPerRow = math.min(byRows, math.max(1, byWidth));
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += maxPerRow) {
      final isLast = i + maxPerRow >= children.length;
      final rowItems = children.sublist(
        i,
        math.min(i + maxPerRow, children.length),
      );
      rows.add(
        Row(
          mainAxisAlignment:
              isLast ? MainAxisAlignment.start : MainAxisAlignment.center,
          children: [
            for (var c = 0; c < rowItems.length; c++) ...[
              if (c > 0) SizedBox(width: widget.spacing),
              rowItems[c],
            ],
          ],
        ),
      );
    }
    final maxWidth = maxPerRow * size + (maxPerRow - 1) * widget.spacing;
    return Center(
      child: SizedBox(
        width: maxWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var r = 0; r < rows.length; r++) ...[
              if (r > 0) SizedBox(height: widget.spacing),
              rows[r],
            ],
          ],
        ),
      ),
    );
  }

  /// 单个圆形按键(字符键或删除键)。
  Widget _buildKeyButton({
    required String label,
    required bool isBackspace,
    required double size,
  }) {
    final colors = Theme.of(context).colorScheme;
    final VoidCallback? onTap = widget.enabled
        ? () {
            // 按键触感反馈:与系统键盘一致的轻触确认
            HapticFeedback.lightImpact();
            if (isBackspace) {
              widget.onBackspace();
            } else {
              widget.onKey(label);
            }
          }
        : null;
    return Material(
      // 把有色的圆形背景直接作为 Material(shape: circle):InkWell 的点击高亮/波纹
      // 才会画在有色表面之上(此前透明 Material + Container 圆底,点击无可见反馈)。
      color: colors.primaryContainer,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        customBorder: const CircleBorder(),
        // 点击变色:按下高亮 + 波纹用文字色轻微点缀
        splashColor: colors.onPrimaryContainer.withValues(alpha: 0.16),
        highlightColor: colors.onPrimaryContainer.withValues(alpha: 0.10),
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Center(
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
      ),
    );
  }
}
