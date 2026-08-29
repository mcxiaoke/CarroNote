/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

// lib/src/platform/io_stub.dart
// 仅用于让 Web 编译通过；Web 上这些符号不会被真实调用，或返回安全默认值。
// ignore_for_file: constant_identifier_names, annotate_overrides
import 'dart:async';
import 'dart:typed_data';

void exit(int code) {}

class Platform {
  static const bool isAndroid = false;
  static const bool isIOS = false;
  static const bool isWindows = false;
  static const bool isMacOS = false;
  static const bool isLinux = false;
  static const bool isFuchsia = false;
  static String get operatingSystem => 'web';
  static String get operatingSystemVersion => 'web';
  static String get version => 'web';
  static String get localeName => 'en_US';
  static String get resolvedExecutable => '';
  static String get executable => '';
  static String get pathSeparator => '/';
  static const Map<String, String> environment = <String, String>{};
}

class FileStat {
  DateTime get changed => DateTime.fromMillisecondsSinceEpoch(0);
  DateTime get modified => DateTime.fromMillisecondsSinceEpoch(0);
  DateTime get accessed => DateTime.fromMillisecondsSinceEpoch(0);
  int get type => 0;
  int get mode => 0;
  int get size => 0;
}

abstract class FileSystemEntity {
  String get path => '';
  Uri get uri => Uri.parse(path);
  Directory get parent => Directory('');
  Future<bool> exists() async => false;
  bool existsSync() => false;
  Future<FileSystemEntity> delete({bool recursive = false}) async => this;
  void deleteSync({bool recursive = false}) {}
  static Future<bool> isDirectory(String path) async => false;
  static bool isDirectorySync(String path) => false;
  static Future<bool> isFile(String path) async => false;
  static bool isFileSync(String path) => false;
  Future<FileStat> stat() async => FileStat();
  FileStat statSync() => FileStat();
}

class File extends FileSystemEntity {
  File(this.path);
  @override
  final String path;
  @override
  Directory get parent => Directory('');
  @override
  Future<bool> exists() async => false;
  @override
  bool existsSync() => false;
  Future<File> create({bool recursive = false, bool exclusive = false}) async =>
      this;
  void createSync({bool recursive = false, bool exclusive = false}) {}
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async => this;
  @override
  void deleteSync({bool recursive = false}) {}
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    dynamic encoding,
    bool flush = false,
  }) async => this;
  void writeAsStringSync(
    String contents, {
    FileMode mode = FileMode.write,
    dynamic encoding,
    bool flush = false,
  }) {}
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) async => this;
  void writeAsBytesSync(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) {}
  Future<String> readAsString({dynamic encoding}) async => '';
  String readAsStringSync({dynamic encoding}) => '';
  Future<Uint8List> readAsBytes() async => Uint8List(0);
  Uint8List readAsBytesSync() => Uint8List(0);
  Future<File> rename(String newPath) async => File(newPath);
  File renameSync(String newPath) => File(newPath);
  Future<File> copy(String newPath) async => File(newPath);
  File copySync(String newPath) => File(newPath);
  Future<int> length() async => 0;
  int lengthSync() => 0;
  Stream<List<int>> openRead([int? start, int? end]) => const Stream.empty();
  IOSink openWrite({FileMode mode = FileMode.write, dynamic encoding}) =>
      throw UnsupportedError('Web does not support openWrite');
}

class Directory extends FileSystemEntity {
  Directory(this.path);
  @override
  final String path;
  Future<Directory> create({bool recursive = false}) async => this;
  void createSync({bool recursive = false}) {}
  @override
  Future<bool> exists() async => false;
  @override
  bool existsSync() => false;
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async => this;
  @override
  void deleteSync({bool recursive = false}) {}
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) => const Stream.empty();
  List<FileSystemEntity> listSync({
    bool recursive = false,
    bool followLinks = true,
  }) => const [];
  Future<Directory> rename(String newPath) async => Directory(newPath);
  Directory renameSync(String newPath) => Directory(newPath);
}

class FileMode {
  const FileMode._();
  static const write = FileMode._();
  static const writeOnly = FileMode._();
  static const writeOnlyAppend = FileMode._();
  static const append = FileMode._();
  static const read = FileMode._();
}

class FileSystemException implements Exception {
  FileSystemException([this.message, this.path, this.osError]);
  final String? message;
  final String? path;
  final dynamic osError;
  @override
  String toString() => 'FileSystemException: $message ($path)';
}

abstract class IOSink implements Sink<List<int>> {
  Future<void> flush() async {}
  @override
  Future<void> close() async {}
  void write(Object? obj) {}
  void writeln([Object? obj = '']) {}
  @override
  void add(List<int> data) {}
}

class InternetAddressType {
  static const IPv4 = InternetAddressType._();
  static const IPv6 = InternetAddressType._();
  static const any = InternetAddressType._();
  const InternetAddressType._();
}

class InternetAddress {
  final String address;
  InternetAddress(this.address);
  bool get isLoopback => false;
}

class NetworkInterface {
  String get name => '';
  List<InternetAddress> get addresses => const [];
  static Future<List<NetworkInterface>> list({
    bool includeLoopback = false,
    bool includeLinkLocal = false,
    InternetAddressType type = InternetAddressType.any,
  }) async => const [];
}

class SocketException implements Exception {
  SocketException([this.message, this.osError, this.address, this.port]);
  final String? message;
  final dynamic osError;
  final dynamic address;
  final int? port;
  @override
  String toString() => 'SocketException: $message';
}

class HttpException implements Exception {
  HttpException(this.message, {this.uri});
  final String message;
  final Uri? uri;
  @override
  String toString() => 'HttpException: $message';
}
