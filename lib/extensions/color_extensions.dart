/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*/

import 'dart:ui' show Color;

extension HexColor on Color {
  /// Converts a hexadecimal string to a [Color] object.
  ///
  /// The [hexString] should be in the format "aabbcc" or "ffaabbcc" with an
  /// optional leading "#". Returns `null` if the input is `null` or invalid.
  static Color? fromHex(String? hexString) {
    if (hexString == null) {
      return null;
    }
    try {
      final buffer = StringBuffer();
      if (hexString.length == 6 || hexString.length == 7) {
        buffer.write('ff');
      }
      buffer.write(hexString.replaceFirst('#', ''));
      return Color(int.parse(buffer.toString(), radix: 16));
    } catch (e) {
      return null;
    }
  }

  /// Converts this [Color] object to a hexadecimal string representation.
  ///
  /// The returned string is in the format "#aarrggbb" if [leadingHashSign] is
  /// `true`, otherwise "aarrggbb".
  String toHex({bool leadingHashSign = true}) {
    final hexA = (a * 255).round().toRadixString(16).padLeft(2, '0');
    final hexR = (r * 255).round().toRadixString(16).padLeft(2, '0');
    final hexG = (g * 255).round().toRadixString(16).padLeft(2, '0');
    final hexB = (b * 255).round().toRadixString(16).padLeft(2, '0');

    return '${leadingHashSign ? '#' : ''}$hexA$hexR$hexG$hexB';
  }
}
