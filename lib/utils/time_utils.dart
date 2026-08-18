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
/// [isRelative] 为 true 时，当天显示相对时间（"x 分钟前"），更早的日期显示绝对日期+时间；
/// 为 false（默认）时始终显示绝对日期+时间（如 Aug 9, 2026 2:30 PM）。
String noteTimeLabel({
  required DateTime time,
  required String localeString,
  required bool isRelative,
}) {
  if (isRelative) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final date = DateTime(time.year, time.month, time.day);
    if (today == date) {
      return humanTime(time: time, localeString: localeString);
    }
  }
  return DateFormat.yMMMd().add_jm().format(time);
}
