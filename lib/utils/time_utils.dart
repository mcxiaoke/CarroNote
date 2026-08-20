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

import 'package:intl/intl.dart';
import 'package:timeago/timeago.dart' as timeago;

import 'package:safenotes/data/preference_and_config.dart';

String humanTime({required DateTime time, required String localeString}) {
  // set local for all supported language
  SafeNotesConfig.setTimeagoLocale();

  if (localeString == 'en_US') return timeago.format(time, locale: 'en');
  if (localeString == 'fr') return timeago.format(time, locale: 'fr_short');
  return timeago.format(time, locale: localeString);
}

/// 卡片时间戳展示：绝对或相对。
///
/// [isRelative] 为 true 时一律显示相对时间（"5 分钟前"、"3 天前"），
/// 与设置项描述一致（Show note timestamps as relative, e.g. 5 minutes ago）；
/// 为 false（默认）时始终显示绝对日期+时间（如 Aug 9, 2026 2:30 PM）。
String noteTimeLabel({
  required DateTime time,
  required String localeString,
  required bool isRelative,
}) {
  // isRelative 为 true 时，若时间在7天内则显示相对时间，否则显示绝对时间。
  if (isRelative &&
      time.isAfter(DateTime.now().subtract(const Duration(days: 7)))) {
    return humanTime(time: time, localeString: localeString);
  }
  return DateFormat.yMMMd().add_jm().format(time);
}
