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

class Style {
  static TextStyle buttonTextStyle(BuildContext context) {
    return TextStyle(color: Theme.of(context).colorScheme.onPrimary);
  }
}

TextStyle dialogBodyTextStyle = const TextStyle(fontSize: 14);

TextStyle dialogHeadTextStyle = const TextStyle(
  fontFamily: 'MerriweatherBlack',
  fontWeight: FontWeight.bold,
  letterSpacing: 0,
  fontSize: 20,
);

TextStyle appBarTitle = const TextStyle(
  fontFamily: 'MerriweatherBlack',
  fontWeight: FontWeight.bold,
  letterSpacing: -0.4,
  fontSize: 20,
);
