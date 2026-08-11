// 共享的 shadcn_ui 风格设置项组件，供 Settings / Backup / Sync 等设置类页面复用。
//
// 设计原则：每个分区用一张 [ShadCard] 装若干 tile，tile 之间用细分隔线；
// 图标统一是品牌色圆角容器；点击反馈用 [Material]+[InkWell] 包裹（叠加在
// ShadApp 内部的 MaterialApp 之上，行为与原生一致）。

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:shadcn_ui/shadcn_ui.dart';

/// 分区小标题（shadcn section 风格：小写、柔和色）。
Widget shadSectionTitle(BuildContext context, String label) {
  final theme = ShadTheme.of(context);
  return Padding(
    padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
    child: Text(
      label,
      style: theme.textTheme.small.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: 0.4,
        color: theme.colorScheme.mutedForeground,
      ),
    ),
  );
}

/// 设置项卡片：去掉默认 padding，tile 撑满，行间插入细分隔线。
Widget shadSettingsCard(List<Widget> tiles) {
  return ShadCard(
    padding: EdgeInsets.zero,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: _withDividers(tiles),
    ),
  );
}

List<Widget> _withDividers(List<Widget> tiles) {
  final out = <Widget>[];
  for (var i = 0; i < tiles.length; i++) {
    if (i > 0) out.add(const _TileDivider());
    out.add(tiles[i]);
  }
  return out;
}

/// 导航型设置项（点击进入子页 / 弹窗 / 外链）。
Widget shadNavigationTile(
  BuildContext context, {
  required IconData icon,
  required String title,
  String? subtitle,
  String? value,
  bool destructive = false,
  required void Function() onTap,
}) {
  return _TileSurface(
    onTap: onTap,
    child: Row(
      children: [
        _TileIcon(icon: icon, destructive: destructive),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: ShadTheme.of(context).textTheme.p.copyWith(
                      color: destructive
                          ? ShadTheme.of(context).colorScheme.destructive
                          : null,
                    ),
              ),
              if (subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    subtitle,
                    style: ShadTheme.of(context)
                        .textTheme
                        .muted
                        .copyWith(fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
        if (value != null)
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Text(
              value,
              style: ShadTheme.of(context).textTheme.muted.copyWith(fontSize: 13),
            ),
          ),
        const SizedBox(width: 4),
        Icon(
          LucideIcons.chevronRight,
          size: 18,
          color: ShadTheme.of(context).colorScheme.mutedForeground,
        ),
      ],
    ),
  );
}

/// 开关型设置项（整行可点击切换，右侧 [ShadSwitch]）。
Widget shadSwitchTile(
  BuildContext context, {
  required IconData icon,
  required String title,
  String? description,
  required bool value,
  required ValueChanged<bool> onChanged,
}) {
  return _TileSurface(
    onTap: () => onChanged(!value),
    child: Row(
      children: [
        _TileIcon(icon: icon),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: ShadTheme.of(context).textTheme.p),
              if (description != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    description,
                    style: ShadTheme.of(context)
                        .textTheme
                        .muted
                        .copyWith(fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
        ShadSwitch(value: value, onChanged: onChanged),
      ],
    ),
  );
}

/// 只读信息行（图标 + 标题 + 右侧值），不可点击。
Widget shadInfoTile(
  BuildContext context, {
  required IconData icon,
  required String title,
  String? description,
  required String value,
}) {
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
    child: Row(
      children: [
        _TileIcon(icon: icon),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: ShadTheme.of(context).textTheme.p),
              if (description != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    description,
                    style: ShadTheme.of(context)
                        .textTheme
                        .muted
                        .copyWith(fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
        Text(
          value,
          style: ShadTheme.of(context).textTheme.muted.copyWith(fontSize: 13),
        ),
      ],
    ),
  );
}

/// 单个设置项的点击表面：圆角 hover/highlight 反馈。
class _TileSurface extends StatelessWidget {
  final VoidCallback onTap;
  final Widget child;

  const _TileSurface({required this.onTap, required this.child});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          child: child,
        ),
      ),
    );
  }
}

/// 圆形品牌色图标容器（Nord 蓝）。
class _TileIcon extends StatelessWidget {
  final IconData icon;
  final bool destructive;

  const _TileIcon({required this.icon, this.destructive = false});

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final color = destructive
        ? theme.colorScheme.destructive
        : theme.colorScheme.primary;
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, size: 18, color: color),
    );
  }
}

/// tile 之间的细分隔线。
class _TileDivider extends StatelessWidget {
  const _TileDivider();

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Divider(
      height: 1,
      thickness: 1,
      indent: 14,
      endIndent: 14,
      color: theme.colorScheme.border,
    );
  }
}
