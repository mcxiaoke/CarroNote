// 导航菜单项（Drawer / 桌面 Sidebar 共用），风格与设置页 shadcn 设置项一致：
// 品牌色圆角图标容器 + 文字 + 可选尾部 + 整行点击反馈（Material + InkWell）。

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:shadcn_ui/shadcn_ui.dart';

/// 单个导航菜单项。
///
/// - [icon] 显示在品牌色（Nord 蓝 / 危险红）圆角容器内；
/// - [label] 用 shadcn 文本主题，与设置页分区标题/设置项保持一致；
/// - [destructive] 为 true 时图标与文字转为危险色（如登出）；
/// - [trailing] 可选尾部控件（如开关）；
/// - 整行可点击，hover/highlight 由 Material + InkWell 提供（叠加在 ShadApp 之上）。
Widget shadNavMenuItem(
  BuildContext context, {
  required IconData icon,
  required String label,
  bool destructive = false,
  Widget? trailing,
  required VoidCallback onTap,
}) {
  final theme = ShadTheme.of(context);
  final color = destructive
      ? theme.colorScheme.destructive
      : theme.colorScheme.primary;

  return Material(
    color: Colors.transparent,
    borderRadius: BorderRadius.circular(10),
    child: InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, size: 18, color: color),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.p.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            trailing ?? const SizedBox.shrink(),
          ],
        ),
      ),
    ),
  );
}
