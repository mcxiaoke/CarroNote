/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

// lib/src/platform/database_bootstrap.dart
export 'database_bootstrap_stub.dart'
    if (dart.library.io) 'database_bootstrap_native.dart'
    if (dart.library.js_interop) 'database_bootstrap_web.dart'
    if (dart.library.html) 'database_bootstrap_web.dart';
