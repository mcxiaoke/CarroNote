/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
*
* 编辑器字体大小设置页。
*
* 交互设计（严格参考主题色子页 theme_color_setting.dart）：
* - 进入页面时本地态初始化为「当前已保存档位」；
* - 选择档位只是本地预览（顶部预览区跟随变化），不立即生效；
* - 底部「Apply」按钮点击后才真正写入 PreferencesStorage；
* - 无取消键，返回即放弃本地改动。
*
* 控件选型：原用 ShadSlider，但真机触摸不灵敏、难拖动、触感生涩；改为
* 单选列表（shadRadioTile，与语言/锁定时长等设置页同构），四档点选、命中
* 区域大、触感明确，且天然适配宽屏窄屏（限宽 720 居中）。
*
* 顶部预览区用 AppName（标题行）+ AppSlogan（正文行），实时跟随选择；
* 两行均用 StrutStyle 按「最大档位字号」预留行高，切换档位时文字字号变化
* 但行高恒定，避免布局高度跳动导致下方内容（含 Apply 栏）上下漂移。
*/

import 'package:flutter/material.dart';

import 'package:easy_localization/easy_localization.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/utils/editor_text.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/widgets/shad_settings_tiles.dart';

/// 编辑器字体大小选择页。
class EditorFontPicker extends StatefulWidget {
  const EditorFontPicker({super.key});

  @override
  State<EditorFontPicker> createState() => _EditorFontPickerState();
}

class _EditorFontPickerState extends State<EditorFontPicker> {
  // 本地暂存态：进入时初始化为当前已保存档位；点选只是改这里（仅预览），
  // Apply 才真正写入 PreferencesStorage。
  late int _pendingIndex;

  @override
  void initState() {
    super.initState();
    _pendingIndex = PreferencesStorage.editorFontSizeIndex;
  }

  /// 是否有「待应用」的改动：本地档位 ≠ 已保存档位时才允许 Apply。
  bool get _hasPendingChange =>
      _pendingIndex != PreferencesStorage.editorFontSizeIndex;

  /// 应用所选档位：写入持久化，然后返回上一级设置页，方便用户立刻去编辑/
  /// 预览页查看效果。若未改动或保存期间页面已销毁则忽略。
  void _apply() {
    if (!_hasPendingChange) return;
    PreferencesStorage.setEditorFontSizeIndex(_pendingIndex).then((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text('Font size'.tr(), style: appBarTitle)),
      // 底部固定操作栏：Apply 按钮始终可见（不随内容滚动）。
      // 与主题色页一致：width 撑满，外层限宽 720 与页面内容区对齐，
      // 桌面/移动都自然；用 Align(heightFactor:1.0) 收缩高度（见 theme_color）。
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Align(
            alignment: Alignment.center,
            heightFactor: 1.0,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Markdown preview does not support font size adjustment'
                        .tr(),
                    style: theme.textTheme.muted,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  ShadButton(
                    width: double.infinity,
                    onPressed: _hasPendingChange ? _apply : null,
                    child: Text('Apply'.tr()),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      body: shadSettingsList([
        _preview(context, theme),
        const SizedBox(height: 12),
        _options(context, theme),
      ]),
    );
  }

  /// 顶部预览：标题行 AppName + 正文行 AppSlogan，实时跟随选择；
  /// 标签区分 Current（=已保存）/ Preview（=选择中）。
  ///
  /// 两行分别用 StrutStyle 按「最大档位字号」预留行高（标题=最大正文+4，
  /// 正文=最大正文），字号随档位变化时行高恒定，避免下方内容上下跳动。
  Widget _preview(BuildContext context, ShadThemeData theme) {
    final isCurrent = _pendingIndex == PreferencesStorage.editorFontSizeIndex;
    final tag = isCurrent
        ? '${'Current'.tr()}: ${EditorText.labelOf(_pendingIndex)}'
        : '${'Preview'.tr()}: ${EditorText.labelOf(_pendingIndex)}';

    // 按最大档位预留行高：标题=最大正文+4，正文=最大正文。
    final titleStrut = StrutStyle(
      fontSize: EditorText.bodySizes.last + EditorText.titleDelta,
      forceStrutHeight: true,
    );
    final bodyStrut = StrutStyle(
      fontSize: EditorText.bodySizes.last,
      forceStrutHeight: true,
    );

    return ShadCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tag,
            style: theme.textTheme.p.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          // 预览标题行：AppName，字号 = 档位标题尺寸。
          Text(
            SafeNotesConfig.appName,
            style: EditorText.titleOf(_pendingIndex),
            strutStyle: titleStrut,
          ),
          const SizedBox(height: 6),
          // 预览正文行：AppSlogan，字号 = 档位正文字尺寸。
          Text(
            SafeNotesConfig.appSlogan,
            style: EditorText.bodyOf(_pendingIndex),
            strutStyle: bodyStrut,
          ),
        ],
      ),
    );
  }

  /// 档位选择区：四档单选（shadRadioTile，与语言/锁定时长设置同构），
  /// 点选即改本地暂存态（仅预览），Apply 才写入；命中区域大、触感明确，
  /// 比滑块在真机上更易用。每行副标题显示该档正文字号数值，便于精确感知。
  Widget _options(BuildContext context, ShadThemeData theme) {
    return ShadCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Font size'.tr(),
            style: theme.textTheme.p.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < EditorText.bodySizes.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            shadRadioTile(
              context,
              title: EditorText.labelOf(i),
              description: EditorText.bodySizeOf(i).toInt().toString(),
              selected: _pendingIndex == i,
              onTap: () => setState(() => _pendingIndex = i),
            ),
          ],
        ],
      ),
    );
  }
}
