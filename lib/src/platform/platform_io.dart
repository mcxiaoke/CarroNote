// lib/src/platform/platform_io.dart
export 'io_real.dart'
    if (dart.library.js_interop) 'io_stub.dart'
    if (dart.library.html) 'io_stub.dart';
