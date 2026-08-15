// 平台插件 Ports（§4.6）
//
// 为每个在 widget 测试里会造成 MissingPluginException 的平台插件定义窄接口，
// 并包一层真实 adapter。测试方提供独立的 Fake 实现（见 test/support/）。
//
// 设计目标：消灭测试里对 MethodChannel 的 mock（_setupSecureStorageMock、
// 标题栏通道 mock），改为注入内存/固定值的测试替身。
//
// 各 port 接口签名与真实插件 API 对齐（无臆造方法）。

// Dart imports:
import 'dart:io';

// Package imports:
import 'package:file_picker/file_picker.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:media_scanner/media_scanner.dart';
import 'package:path_provider/path_provider.dart' as path_provider;
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

// Project imports:
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/biometric_auth.dart';
import 'package:safenotes/utils/device_id.dart';

// ─────────────────────────────────────────────────────────────
// 1. SecureStoragePort
// ─────────────────────────────────────────────────────────────

/// 安全存储窄接口（flutter_secure_storage 的抽象）。
abstract class SecureStoragePort {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
  Future<bool> containsKey(String key);
  Future<Map<String, String>> readAll();
  Future<void> deleteAll();
}

/// 真实实现：包 flutter_secure_storage。
class FlutterSecureStorageAdapter implements SecureStoragePort {
  const FlutterSecureStorageAdapter();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<bool> containsKey(String key) => _storage.containsKey(key: key);

  @override
  Future<Map<String, String>> readAll() => _storage.readAll();

  @override
  Future<void> deleteAll() => _storage.deleteAll();
}

// ─────────────────────────────────────────────────────────────
// 2. BiometricPort
// ─────────────────────────────────────────────────────────────

/// 生物识别能力窄接口（local_auth 的抽象）。
///
/// 只暴露 UI/认证流程真正用到的能力：判断可用性、触发认证、读取/写入
/// 生物识别凭据（走 SecureStoragePort，避免直接依赖插件）。
abstract class BiometricPort {
  /// 设备是否支持生物识别。
  Future<bool> isAvailable();

  /// 触发系统生物识别认证。
  Future<bool> authenticate();

  /// 读取生物识别凭据（解密后的 vault 密码；未设置返回空串）。
  Future<String> readCredential();

  /// 写入生物识别凭据（解密后的 vault 密码）。
  Future<void> saveCredential(String password);

  /// 清除生物识别凭据。
  Future<void> clearCredential();
}

/// 真实实现：包 local_auth + [BiometricAuth]。
///
/// authenticate/isAvailable 走 local_auth 系统生物识别；凭据读写走
/// [BiometricAuth]（F-C01 包裹态，存于 secure storage）。
class PlatformBiometricPort implements BiometricPort {
  const PlatformBiometricPort();

  @override
  Future<bool> isAvailable() async {
    final la = LocalAuthentication();
    return await la.isDeviceSupported() && await la.canCheckBiometrics;
  }

  @override
  Future<bool> authenticate() async {
    final la = LocalAuthentication();
    return la.authenticate(
      localizedReason: 'Login using your biometric credential',
    );
  }

  @override
  Future<String> readCredential() => BiometricAuth.authKey;

  @override
  Future<void> saveCredential(String password) async {
    await BiometricAuth.savePassword(password);
    await PreferencesStorage.setIsBiometricAuthEnabled(true);
  }

  @override
  Future<void> clearCredential() => BiometricAuth.disable();
}

// ─────────────────────────────────────────────────────────────
// 3. DeviceInfoPort
// ─────────────────────────────────────────────────────────────

/// 设备信息窄接口（device_info_plus / DeviceIdProvider 的抽象）。
abstract class DeviceInfoPort {
  /// 获取设备 ID（格式 `<platform>-<id>`）。
  Future<String> getDeviceId();

  /// 已缓存的设备 ID（未缓存返回 null）。
  String? get cachedDeviceId;
}

/// 真实实现：包 [DeviceIdProvider]（其本身经 device_info_plus 查询）。
class DeviceIdProviderAdapter implements DeviceInfoPort {
  const DeviceIdProviderAdapter();

  @override
  Future<String> getDeviceId() => DeviceIdProvider.instance.getDeviceId();

  @override
  String? get cachedDeviceId => DeviceIdProvider.instance.cachedDeviceId;
}

// ─────────────────────────────────────────────────────────────
// 4. PermissionPort
// ─────────────────────────────────────────────────────────────

/// 权限窄接口（permission_handler 的抽象）。
abstract class PermissionPort {
  /// 请求存储权限，返回是否授予。
  Future<bool> requestStoragePermission();

  /// 请求指定权限，返回是否授予。
  Future<bool> request(String permission);
}

/// 真实实现：包 permission_handler。
class PermissionHandlerAdapter implements PermissionPort {
  const PermissionHandlerAdapter();

  @override
  Future<bool> requestStoragePermission() async {
    final granted = await Permission.storage.isGranted;
    if (granted) return true;
    final status = await Permission.storage.request();
    return status.isGranted;
  }

  @override
  Future<bool> request(String permission) async {
    final p = _parsePermission(permission);
    final granted = await p.isGranted;
    if (granted) return true;
    final status = await p.request();
    return status.isGranted;
  }

  Permission _parsePermission(String name) {
    switch (name) {
      case 'storage':
        return Permission.storage;
      case 'notification':
        return Permission.notification;
      case 'location':
        return Permission.location;
      default:
        return Permission.storage;
    }
  }
}

// ─────────────────────────────────────────────────────────────
// 5. AppDirsPort
// ─────────────────────────────────────────────────────────────

/// 应用目录窄接口（path_provider 的抽象）。
abstract class AppDirsPort {
  /// 应用支持目录（持久化、非用户可见）。
  Future<Directory> getSupportDirectory();

  /// 应用文档目录（用户可见）。
  Future<Directory> getDocumentsDirectory();

  /// 临时目录。
  Future<Directory> getTemporaryDirectory();
}

/// 真实实现：包 path_provider。
class PathProviderAdapter implements AppDirsPort {
  const PathProviderAdapter();

  @override
  Future<Directory> getSupportDirectory() =>
      path_provider.getApplicationSupportDirectory();

  @override
  Future<Directory> getDocumentsDirectory() =>
      path_provider.getApplicationDocumentsDirectory();

  @override
  Future<Directory> getTemporaryDirectory() =>
      path_provider.getTemporaryDirectory();
}

// ─────────────────────────────────────────────────────────────
// 6. FilePickerPort
// ─────────────────────────────────────────────────────────────

/// 文件选择窄接口（file_picker 的抽象）。
abstract class FilePickerPort {
  /// 选择单个文件，返回路径（取消返回 null）。
  Future<String?> pickFile({List<String>? allowedExtensions});

  /// 选择目录，返回路径（取消返回 null）。
  Future<String?> pickDirectory();

  /// 保存文件，返回路径（取消返回 null）。
  Future<String?> saveFile({String? fileName, List<String>? allowedExtensions});
}

/// 真实实现：包 file_picker。
class FilePickerAdapter implements FilePickerPort {
  const FilePickerAdapter();

  @override
  Future<String?> pickFile({List<String>? allowedExtensions}) async {
    final result = await FilePicker.pickFiles(
      type: allowedExtensions == null ? FileType.any : FileType.custom,
      allowedExtensions: allowedExtensions,
      allowMultiple: false,
    );
    return result?.files.single.path;
  }

  @override
  Future<String?> pickDirectory() async {
    final path = await FilePicker.getDirectoryPath();
    return path;
  }

  @override
  Future<String?> saveFile({
    String? fileName,
    List<String>? allowedExtensions,
  }) async {
    final path = await FilePicker.saveFile(
      fileName: fileName,
      type: allowedExtensions == null ? FileType.any : FileType.custom,
      allowedExtensions: allowedExtensions,
    );
    return path;
  }
}

// ─────────────────────────────────────────────────────────────
// 7. UrlLauncherPort
// ─────────────────────────────────────────────────────────────

/// 链接打开窄接口（url_launcher 的抽象）。
abstract class UrlLauncherPort {
  /// 用外部应用打开 URL。
  Future<bool> launchExternal(Uri url);

  /// 用应用内 WebView 打开 URL。
  Future<bool> launchInApp(Uri url);
}

/// 真实实现：包 url_launcher。
class UrlLauncherAdapter implements UrlLauncherPort {
  const UrlLauncherAdapter();

  @override
  Future<bool> launchExternal(Uri url) =>
      launchUrl(url, mode: LaunchMode.externalApplication);

  @override
  Future<bool> launchInApp(Uri url) =>
      launchUrl(url, mode: LaunchMode.inAppWebView);
}

// ─────────────────────────────────────────────────────────────
// 8. MediaScannerPort
// ─────────────────────────────────────────────────────────────

/// 媒体扫描窄接口（media_scanner 的抽象）。
abstract class MediaScannerPort {
  /// 通知系统媒体库收录指定文件。
  Future<void> loadMedia(String path);
}

/// 真实实现：包 media_scanner。
class MediaScannerAdapter implements MediaScannerPort {
  const MediaScannerAdapter();

  @override
  Future<void> loadMedia(String path) async {
    await MediaScanner.loadMedia(path: path);
  }
}
