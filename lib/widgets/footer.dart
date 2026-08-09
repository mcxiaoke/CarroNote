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

// Flutter imports:
import 'package:flutter/material.dart';

// Project imports:
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/utils/build_info.dart';

Widget footer() {
  const double fontSize = 12;
  final Color color = PreferencesStorage.isThemeDark
      ? const Color(0xFFafb8ba)
      : const Color(0xFF8e989c);
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
        Text(headerText, style: style),
        Text(buildInfoText, style: style),
      ],
    ),
  );
}
