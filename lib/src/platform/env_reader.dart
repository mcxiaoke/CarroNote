// lib/src/platform/env_reader.dart
export 'env_reader_native.dart'
    if (dart.library.js_interop) 'env_reader_web.dart'
    if (dart.library.html) 'env_reader_web.dart';
