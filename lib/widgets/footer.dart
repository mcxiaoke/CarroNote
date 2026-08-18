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

import 'package:flutter/material.dart';

import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/generated/build_info.g.dart';
import 'package:safenotes/utils/dev_mode.dart';
import 'package:safenotes/utils/text_styles.dart';

/// dev 模式的醒目徽标（非 dev 模式不渲染）。
///
/// [DevMode.isActive] 在 debug 构建恒为 true（release/profile 下仅当用户通过
/// 设置页连点版本号开启 dev 模式后才显示）。与 debug 版独立 applicationId
/// （.dev 后缀）配套，避免把调试版误当正式版。
Widget debugBadge(BuildContext context) {
  if (!DevMode.isActive) return const SizedBox.shrink();
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      // P1-22：错误/危险色统一走 shad destructive（替代硬编码 0xFFD32F2F）。
      color: ShadTheme.of(context).colorScheme.destructive,
      borderRadius: BorderRadius.circular(10),
    ),
    child: const Text(
      'DEBUG',
      style: TextStyle(
        color: Colors.white,
        fontSize: AppTextSize.s12,
        fontWeight: FontWeight.bold,
        letterSpacing: 1,
      ),
    ),
  );
}

Widget footer(BuildContext context) {
  const double fontSize = AppTextSize.s12;
  // 统一用主题 onSurfaceVariant，亮暗自动适配（不再硬编码 #afb8ba/#8e989c）。
  final Color color = Theme.of(context).colorScheme.onSurfaceVariant;
  final TextStyle style = TextStyle(color: color, fontSize: fontSize);
  final versionText = SafeNotesConfig.appVersion;
  // 第一行：版本号
  final headerText = 'v$versionText';
  // 第二行：构建时间 + git short hash
  final buildInfoText =
      '${BuildInfo.buildDateReadable} · ${BuildInfo.gitHashShort}';

  return Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Column(
      children: [
        debugBadge(context),
        if (DevMode.isActive) const SizedBox(height: 6),
        Text(headerText, style: style),
        Text(buildInfoText, style: style),
      ],
    ),
  );
}
