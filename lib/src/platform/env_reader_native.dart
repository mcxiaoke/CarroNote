// lib/src/platform/env_reader_native.dart
import 'dart:io';

String? getPlatformEnv(String name) => Platform.environment[name];
