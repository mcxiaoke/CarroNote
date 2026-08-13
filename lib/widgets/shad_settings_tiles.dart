// 共享的 shadcn_ui 风格设置项组件，供 Settings / Backup / Sync 等设置类页面复用。
//
// 设计原则：每个分区用一张 [ShadCard] 装若干 tile，tile 之间用细分隔线；
// 图标统一是品牌色圆角容器；点击反馈用 [Material]+[InkWell] 包裹（叠加在
// ShadApp 内部的 MaterialApp 之上，行为与原生一致）。

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:shadcn_ui/shadcn_ui.dart';

/// 设置类页面的标准内容容器：统一内边距 + 桌面端限宽居中。
///
/// 桌面窗口可以拉得很宽，设置项撑满整行会让开关跑到视线之外、阅读动线断裂，
/// 因此这里统一把内容限制在 [maxWidth] 内并水平居中；移动端不受影响
/// （屏幕本来就窄于该阈值）。所有设置页共用这一处逻辑。
Widget shadSettingsList(List<Widget> children, {double maxWidth = 720}) {
  return Center(
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: children,
      ),
    ),
  );
}

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
                    style: ShadTheme.of(
                      context,
                    ).textTheme.muted.copyWith(fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
        if (value != null)
          Flexible(
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              // Align 让 value 真正靠右到行末：Flexible 内 Text 只按内容宽度排布，
              // 仅靠 textAlign 无法推到末尾（文字会停在标题右侧即行中间）。
              child: Align(
                alignment: Alignment.centerRight,
                child: Text(
                  value,
                  textAlign: TextAlign.end,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ShadTheme.of(
                    context,
                  ).textTheme.muted.copyWith(fontSize: 13),
                ),
              ),
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
                    style: ShadTheme.of(
                      context,
                    ).textTheme.muted.copyWith(fontSize: 12),
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

/// 单选型设置项（一组里选一个，选中项右侧显示勾）。
///
/// [leading] 优先于 [icon]，用于色板等自定义前置图形。
Widget shadRadioTile(
  BuildContext context, {
  required String title,
  String? description,
  required bool selected,
  required void Function() onTap,
  IconData? icon,
  Widget? leading,
}) {
  final theme = ShadTheme.of(context);
  return _TileSurface(
    onTap: onTap,
    child: Row(
      children: [
        if (leading != null) ...[
          leading,
          const SizedBox(width: 14),
        ] else if (icon != null) ...[
          _TileIcon(icon: icon),
          const SizedBox(width: 14),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.p.copyWith(
                  fontWeight: selected ? FontWeight.w600 : null,
                  color: selected ? theme.colorScheme.primary : null,
                ),
              ),
              if (description != null && description.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    description,
                    style: theme.textTheme.muted.copyWith(fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
        if (selected)
          Icon(LucideIcons.check, size: 18, color: theme.colorScheme.primary),
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
                    style: ShadTheme.of(
                      context,
                    ).textTheme.muted.copyWith(fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
        Flexible(
          child: Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Text(
              value,
              textAlign: TextAlign.end,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ShadTheme.of(
                context,
              ).textTheme.muted.copyWith(fontSize: 13),
            ),
          ),
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
