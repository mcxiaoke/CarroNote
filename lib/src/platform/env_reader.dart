/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

// lib/src/platform/env_reader.dart
export 'env_reader_native.dart'
    if (dart.library.js_interop) 'env_reader_web.dart'
    if (dart.library.html) 'env_reader_web.dart';
