/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

// lib/src/platform/data_dir_override.dart
export 'data_dir_override_native.dart'
    if (dart.library.js_interop) 'data_dir_override_web.dart'
    if (dart.library.html) 'data_dir_override_web.dart';
