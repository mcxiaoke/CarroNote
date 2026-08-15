// 平台插件测试替身（§4.6）
//
// 为每个平台 port 提供内存/固定值的 fake 实现，widget 测试注入后即可
// 避免 MissingPluginException，无需 mock MethodChannel。
//
// 用法：
//   Provider<SecureStoragePort>.value(value: FakeSecureStorage()),
//   Provider<BiometricPort>.value(value: FakeBiometric()),

// Dart imports:
import 'dart:io';

// Project imports:
import 'package:safenotes/platform/ports.dart';

/// 内存 Map 实现的安全存储 fake。
class FakeSecureStorage implements SecureStoragePort {
  final Map<String, String> _store = {};

  @override
  Future<String?> read(String key) async => _store[key];

  @override
  Future<void> write(String key, String value) async {
    _store[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _store.remove(key);
  }

  @override
  Future<bool> containsKey(String key) async => _store.containsKey(key);

  @override
  Future<Map<String, String>> readAll() async => Map.of(_store);

  @override
  Future<void> deleteAll() async {
    _store.clear();
  }
}

/// 可配置的生物识别 fake。
///
/// 默认可用、认证成功。可注入预置凭据（[credential]）。
class FakeBiometric implements BiometricPort {
  FakeBiometric({
    this.available = true,
    this.authResult = true,
    this.credential = '',
  });

  /// 设备是否支持生物识别。
  bool available;

  /// authenticate() 的返回值。
  bool authResult;

  /// 预置的生物识别凭据。
  String credential;

  /// 记录了 authenticate() 被调用的次数。
  int authenticateCalls = 0;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<bool> authenticate() async {
    authenticateCalls++;
    return authResult;
  }

  @override
  Future<String> readCredential() async => credential;

  @override
  Future<void> saveCredential(String password) async {
    credential = password;
  }

  @override
  Future<void> clearCredential() async {
    credential = '';
  }
}

/// 固定设备 ID 的 device info fake。
class FakeDeviceInfo implements DeviceInfoPort {
  FakeDeviceInfo({this.deviceId = 'test-device-1'});

  final String deviceId;

  @override
  Future<String> getDeviceId() async => deviceId;

  @override
  String? get cachedDeviceId => deviceId;
}

/// 永远授予的权限 fake。
class FakePermission implements PermissionPort {
  FakePermission({this.granted = true});

  final bool granted;
  final List<String> requested = [];

  @override
  Future<bool> requestStoragePermission() async {
    requested.add('storage');
    return granted;
  }

  @override
  Future<bool> request(String permission) async {
    requested.add(permission);
    return granted;
  }
}

/// 内存/临时目录的应用目录 fake。
class FakeAppDirs implements AppDirsPort {
  FakeAppDirs({String? supportPath, String? documentsPath})
    : support = Directory(supportPath ?? '/tmp/safenotes-support'),
      documents = Directory(documentsPath ?? '/tmp/safenotes-documents');

  final Directory support;
  final Directory documents;

  @override
  Future<Directory> getSupportDirectory() async => support;

  @override
  Future<Directory> getDocumentsDirectory() async => documents;

  @override
  Future<Directory> getTemporaryDirectory() async =>
      Directory('/tmp/safenotes-temp');
}

/// 返回固定路径的文件选择 fake。
class FakeFilePicker implements FilePickerPort {
  FakeFilePicker({this.pickPath, this.directoryPath, this.savePath});

  /// pickFile 返回的路径（null 表示取消）。
  String? pickPath;

  /// pickDirectory 返回的路径（null 表示取消）。
  String? directoryPath;

  /// saveFile 返回的路径（null 表示取消）。
  String? savePath;

  final List<String> calls = [];

  @override
  Future<String?> pickFile({List<String>? allowedExtensions}) async {
    calls.add('pickFile');
    return pickPath;
  }

  @override
  Future<String?> pickDirectory() async {
    calls.add('pickDirectory');
    return directoryPath;
  }

  @override
  Future<String?> saveFile({
    String? fileName,
    List<String>? allowedExtensions,
  }) async {
    calls.add('saveFile');
    return savePath;
  }
}

/// 记录调用、返回 true 的 url launcher fake。
class FakeUrlLauncher implements UrlLauncherPort {
  final List<Uri> externalLaunches = [];
  final List<Uri> inAppLaunches = [];
  bool result = true;

  @override
  Future<bool> launchExternal(Uri url) async {
    externalLaunches.add(url);
    return result;
  }

  @override
  Future<bool> launchInApp(Uri url) async {
    inAppLaunches.add(url);
    return result;
  }
}

/// no-op 的媒体扫描 fake。
class FakeMediaScanner implements MediaScannerPort {
  final List<String> scannedPaths = [];

  @override
  Future<void> loadMedia(String path) async {
    scannedPaths.add(path);
  }
}
