/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*
*/

// lib/src/platform/http_client_factory.dart
export 'http_client_factory_native.dart'
    if (dart.library.js_interop) 'http_client_factory_web.dart'
    if (dart.library.html) 'http_client_factory_web.dart';
