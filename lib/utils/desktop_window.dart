/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

// lib/utils/desktop_window.dart
export 'desktop_window_callback.dart';
export 'desktop_window_stub.dart'
    if (dart.library.io) 'desktop_window_native.dart';
