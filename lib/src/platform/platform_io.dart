/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

// lib/src/platform/platform_io.dart
export 'io_real.dart'
    if (dart.library.js_interop) 'io_stub.dart'
    if (dart.library.html) 'io_stub.dart';
