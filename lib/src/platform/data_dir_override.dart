// lib/src/platform/data_dir_override.dart
export 'data_dir_override_native.dart'
    if (dart.library.js_interop) 'data_dir_override_web.dart'
    if (dart.library.html) 'data_dir_override_web.dart';
