/*
* Copyright (C) Keshav Priyadarshi and others - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*
* You should have received a copy of the GNU General Public License v3.0 with
* this file. If not, please visit https://www.gnu.org/licenses/gpl-3.0.html
*
* See https://safenotes.dev for support or download.
*/

// Dart imports:
import 'dart:async';

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:easy_localization/easy_localization.dart';
import 'package:local_session_timeout/local_session_timeout.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

// Project imports:
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/utils/platform_ui.dart';
import 'package:safenotes/utils/text_direction_util.dart';
import 'package:safenotes/utils/text_styles.dart';

class NoteFormWidget extends StatelessWidget {
  final StreamController<SessionState> sessionStateStream;

  final String? title;
  final String? description;
  final ValueChanged<String> onChangedTitle;
  final ValueChanged<String> onChangedDescription;

  const NoteFormWidget({
    super.key,
    this.title = '',
    this.description = '',
    required this.onChangedTitle,
    required this.onChangedDescription,
    required this.sessionStateStream,
  });

  @override
  Widget build(BuildContext context) {
    const double allSidePadding = 16.0;

    return SingleChildScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      child: Padding(
        padding: const EdgeInsets.all(allSidePadding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildTitle(),
            const SizedBox(height: 8),
            const Divider(height: 1, thickness: 1),
            const SizedBox(height: 8),
            buildDescription(context),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildTitle() {
    final String titleHint = 'Title'.tr();
    //Disable IMEPL if keyboard incognito mode is true
    final bool enableIMEPLFlag = !PreferencesStorage.keyboardIncognito;

    return ShadInputFormField(
      key: const Key('ui-note-field-title'),
      autofocus: true,
      enableIMEPersonalizedLearning: enableIMEPLFlag,
      maxLines: null,
      textDirection: getTextDirecton(title!),
      initialValue: title,
      enableInteractiveSelection: true,
      // P1-19：编辑器标题走 AppText.title（20 bold），保留平台字体族。
      style: AppText.title.copyWith(
        fontFamily: uiFontFamily,
        fontFamilyFallback: uiFontFamilyFallback,
      ),
      placeholder: Text(titleHint),
      // 防御主题层 minHeight:48 抬高：编辑器标题/正文保持按内容（行高）紧凑布局
      constraints: const BoxConstraints(minHeight: 0),
      padding: EdgeInsets.zero,
      inputPadding: EdgeInsets.zero,
      // 全 border 显式置 none + 透明背景，维持 borderless 编辑器的紧凑外观，
      // 防御 shadcn 输入框默认描边/填充（与搜索框同源，避免被主题副作用改出黑框）。
      decoration: const ShadDecoration(
        border: ShadBorder.none,
        focusedBorder: ShadBorder.none,
        errorBorder: ShadBorder.none,
        secondaryBorder: ShadBorder.none,
        secondaryFocusedBorder: ShadBorder.none,
        secondaryErrorBorder: ShadBorder.none,
        color: Colors.transparent,
      ),
      onChanged: onChangedTitle,
    );
  }

  Widget buildDescription(BuildContext context) {
    // maxLine is used in resizing description field on keyboard activation or dismissal
    final String hintDescription = 'Type something...'.tr();
    final bool enableIMEPLFlag = !PreferencesStorage.keyboardIncognito;

    return ShadInputFormField(
      key: const Key('ui-note-field-body'),
      enableIMEPersonalizedLearning: enableIMEPLFlag,
      //maxLines: maxLinesToShowAtTimeDescription,
      maxLines: null,
      minLines: 1,
      initialValue: description,
      textDirection: getTextDirecton(description!),
      enableInteractiveSelection: true,
      alignment: Alignment.topLeft,
      // 编辑器正文保持 16（AppText.body），编辑态为纯文本、不套 Markdown 排版。
      style: AppText.body.copyWith(
        fontFamily: uiFontFamily,
        fontFamilyFallback: uiFontFamilyFallback,
      ),
      placeholder: Text(hintDescription),
      // 防御主题层 minHeight:48 抬高（同标题框）
      constraints: const BoxConstraints(minHeight: 0),
      padding: EdgeInsets.zero,
      inputPadding: EdgeInsets.zero,
      decoration: const ShadDecoration(
        border: ShadBorder.none,
        focusedBorder: ShadBorder.none,
        errorBorder: ShadBorder.none,
        secondaryBorder: ShadBorder.none,
        secondaryFocusedBorder: ShadBorder.none,
        secondaryErrorBorder: ShadBorder.none,
        color: Colors.transparent,
      ),
      onChanged: onChangedDescription,
    );
  }

  // int computeMaxLine(
  //     {required BuildContext context, required double fontHeight}) {
  //   final double totalHeight = MediaQuery.of(context).size.height;
  //   final EdgeInsets paddingInsets = MediaQuery.of(context).padding;
  //   final double keyboard = MediaQuery.of(context).viewInsets.bottom;
  //   final double padding = paddingInsets.top + paddingInsets.bottom;

  //   double totalHeightRatio = (totalHeight - padding) / 100;
  //   double fontHeightRatio = fontHeight / 100;
  //   double theXfactor = totalHeightRatio / 3.2;
  //   /*
  //   When Keyboard is on screen:-
  //   Theoretical Ratios for top:description:keyboard
  //   theoreticalTitleNTopHeightRatio = x*(3.2-1.6);
  //   theoreticalDescriptinHeightRatio = x*1.6;
  //   theoreticalKeyboardHeightRatio = x;
  //   x + x*1.2 + x = totalHeightRatio (i.e total height of screen)

  //   From above:
  //   if keyboard is on-screen:
  //     theoreticalDescriptinHeightRatio = x*1.6
  //   if keyboard not on screen:
  //     theoreticalDescriptinHeightRatio = x*2.6 (keyboard space is taken by description)
  //   */
  //   double descriptionRatio = theXfactor * 2.6;
  //   if (keyboard > 0) descriptionRatio = theXfactor * 1.4;
  //   return (descriptionRatio / fontHeightRatio).round();
  // }
}
