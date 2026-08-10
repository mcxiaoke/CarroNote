// 同步配置（SyncConfig / SyncBackendDraft / SyncService.testBackendConfig）
// 单元测试。
//
// 覆盖三层逻辑：
//   1. SyncBackendDraft 值对象：isComplete / connectionSignature / buildBackend，
//      以及「切换类型不丢配置」字段保留。
//   2. 同步总开关语义：isSyncEnabled / hasBackendConfig / isSyncReady，
//      以及旧版本（无 sync_enabled 键）的迁移默认值。
//   3. SyncService.testBackendConfig：用真实临时目录对 localFs 后端做连通性测试。
//
// 测试环境没有原生实现，因此：
//   - SharedPreferences 用 setMockInitialValues 注入内存 mock；
//   - flutter_secure_storage 的 MethodChannel 用内存 Map 模拟，
//     避免 MissingPluginException（注意它是 Error 而非 Exception，测不到会被抛出）。

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:safenotes/sync/sync_config.dart';
import 'package:safenotes/sync/sync_service.dart';

const _secureChannel =
    MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
final Map<String, String> _secureStore = {};

void _setupTestBindings() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _secureStore.clear();
  TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_secureChannel, (call) async {
    final args = call.arguments as Map<Object?, Object?>;
    switch (call.method) {
      case 'read':
        return _secureStore[args['key'] as String];
      case 'write':
        _secureStore[args['key'] as String] = (args['value'] as String?) ?? '';
        return true;
      case 'delete':
        _secureStore.remove(args['key'] as String);
        return true;
      case 'containsKey':
        return _secureStore.containsKey(args['key'] as String);
      case 'readAll':
        return Map<String, String>.from(_secureStore);
      case 'deleteAll':
        _secureStore.clear();
        return true;
      default:
        return null;
    }
  });
}

/// 把 SharedPreferences 复位到空状态，保证用例间隔离。
Future<void> _resetPrefs() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.clear();
}

void main() {
  setUpAll(() {
    _setupTestBindings();
    // 必须在首次 getInstance() 之前注入，否则会去初始化真实平台存储。
    SharedPreferences.setMockInitialValues({});
  });

  setUp(() async {
    // 每个用例前初始化并清空持久层，保证隔离。
    // 真实 App 在 main._bootstrap 里已 init，save() 依赖 _prefs 非 null。
    await SyncConfig.init();
    await _resetPrefs();
  });

  group('SyncBackendDraft 值对象', () {
    test('none 类型永远视为不完整', () {
      final draft = SyncBackendDraft(
        type: SyncBackendType.none,
        webdavUrl: 'x',
        webdavUsername: 'y',
      );
      expect(draft.isComplete, isFalse);
      expect(draft.buildBackend(), isNull);
      expect(draft.connectionSignature, equals('none'));
    });

    test('localFs：路径缺失即不完整，有路径即完整且能构造后端', () {
      final empty = SyncBackendDraft(type: SyncBackendType.localFs);
      expect(empty.isComplete, isFalse);
      expect(empty.buildBackend(), isNull);

      final ok = SyncBackendDraft(
        type: SyncBackendType.localFs,
        localFsPath: '/tmp/vault',
      );
      expect(ok.isComplete, isTrue);
      final backend = ok.buildBackend();
      expect(backend, isNotNull);
      expect(backend!.providerKey, isNotEmpty);
      expect(backend.runtimeType.toString(), contains('LocalFsBackend'));
    });

    test('webdav：URL 与用户名齐全才完整（密码可空）', () {
      final missingUser = SyncBackendDraft(
        type: SyncBackendType.webdav,
        webdavUrl: 'https://dav.example.com/dav/',
      );
      expect(missingUser.isComplete, isFalse);

      final ok = SyncBackendDraft(
        type: SyncBackendType.webdav,
        webdavUrl: 'https://dav.example.com/dav/',
        webdavUsername: 'alice',
        webdavPassword: 'secret',
      );
      expect(ok.isComplete, isTrue);
      final backend = ok.buildBackend();
      expect(backend, isNotNull);
      expect(backend!.providerKey, isNotEmpty);
      expect(backend.runtimeType.toString(), contains('WebDavBackend'));
    });

    test('safeServer：URL 与 Token 齐全才完整', () {
      final missingToken = SyncBackendDraft(
        type: SyncBackendType.safeServer,
        safeServerUrl: 'http://192.168.1.1:2025',
      );
      expect(missingToken.isComplete, isFalse);

      final ok = SyncBackendDraft(
        type: SyncBackendType.safeServer,
        safeServerUrl: 'http://192.168.1.1:2025',
        safeServerToken: 'tok-123',
      );
      expect(ok.isComplete, isTrue);
      final backend = ok.buildBackend();
      expect(backend, isNotNull);
      expect(backend!.providerKey, isNotEmpty);
      expect(backend.runtimeType.toString(), contains('SafeServerBackend'));
    });

    test('normalized 仅裁剪 URL/用户名/路径，不裁剪密码与 Token', () {
      final draft = SyncBackendDraft(
        type: SyncBackendType.webdav,
        webdavUrl: '  https://dav.example.com/dav/  ',
        webdavUsername: '  alice  ',
        webdavPassword: '  p@ss ',
      );
      final n = draft.normalized();
      expect(n.webdavUrl, equals('https://dav.example.com/dav/'));
      expect(n.webdavUsername, equals('alice'));
      // 密码保留首尾空格，避免"看起来对但认证失败"
      expect(n.webdavPassword, equals('  p@ss '));
    });

    test('connectionSignature 随当前类型字段变化，且只覆盖当前类型', () {
      const pwd = 'pw';
      final webdav = SyncBackendDraft(
        type: SyncBackendType.webdav,
        webdavUrl: 'https://dav.example.com/',
        webdavUsername: 'alice',
        webdavPassword: pwd,
        // 故意填了别的类型字段，不应影响 webdav 指纹
        safeServerUrl: 'http://1.2.3.4:2025',
        safeServerToken: 'other',
      );
      expect(webdav.connectionSignature,
          equals('webdav|https://dav.example.com/|alice|${pwd.hashCode}'));

      // 改 URL → 指纹变化
      final changed = webdav.copyWith(
          webdavUrl: 'https://dav2.example.com/');
      expect(changed.connectionSignature, isNot(equals(webdav.connectionSignature)));

      // 改 safeServer 字段不应影响 webdav 指纹
      final sameSig = webdav.copyWith(safeServerToken: 'changed');
      expect(sameSig.connectionSignature, equals(webdav.connectionSignature));
    });

    test('切换类型不丢配置：save 写回全部类型字段', () async {
      // 先以 webdav 配置保存
      const webdavDraft = SyncBackendDraft(
        type: SyncBackendType.webdav,
        webdavUrl: 'https://dav.example.com/dav/',
        webdavUsername: 'alice',
        webdavPassword: 'secret',
      );
      await webdavDraft.save();

      // 切到 safeServer 并保存
      const safeDraft = SyncBackendDraft(
        type: SyncBackendType.safeServer,
        safeServerUrl: 'http://192.168.1.1:2025',
        safeServerToken: 'tok-123',
        // 同时保留着 webdav 字段（面板里用户在切换时不会清空）
        webdavUrl: 'https://dav.example.com/dav/',
        webdavUsername: 'alice',
        webdavPassword: 'secret',
      );
      await safeDraft.save();

      // 从持久化读回草稿，webdav 配置应原样保留
      final restored = SyncBackendDraft.fromConfig();
      expect(restored.type, equals(SyncBackendType.safeServer));
      expect(restored.webdavUrl, equals('https://dav.example.com/dav/'));
      expect(restored.webdavUsername, equals('alice'));
      expect(restored.webdavPassword, equals('secret'));
      // 再切回 webdav 时，原配置仍在
      expect(restored.copyWith(type: SyncBackendType.webdav).isComplete,
          isTrue);
    });
  });

  group('同步总开关语义', () {
    test('无 sync_enabled 键 + 后端为 none → 默认关闭', () async {
      await _resetPrefs();
      await SyncConfig.init();
      expect(SyncConfig.isSyncEnabled, isFalse);
      expect(SyncConfig.hasBackendConfig, isFalse);
      expect(SyncConfig.isSyncReady, isFalse);
    });

    test('无 sync_enabled 键 + 已配置后端 → 迁移默认开启', () async {
      await _resetPrefs();
      await SyncConfig.init();
      // 旧版本用 backendType != none 表达"同步已开"
      await SyncConfig.setBackendType(SyncBackendType.webdav);
      await SyncConfig.setWebdavUrl('https://dav.example.com/dav/');
      await SyncConfig.setWebdavUsername('alice');
      // 注意：未写入 sync_enabled 键
      expect(SyncConfig.isSyncEnabled, isTrue,
          reason: '旧版本升级：后端已配置应推断为同步开启');
      expect(SyncConfig.hasBackendConfig, isTrue);
      expect(SyncConfig.isSyncReady, isTrue);
    });

    test('显式关闭 sync_enabled → 即便后端完整也整体不就绪', () async {
      await _resetPrefs();
      await SyncConfig.init();
      await SyncConfig.setBackendType(SyncBackendType.webdav);
      await SyncConfig.setWebdavUrl('https://dav.example.com/dav/');
      await SyncConfig.setWebdavUsername('alice');
      await SyncConfig.setSyncEnabled(false);
      expect(SyncConfig.isSyncEnabled, isFalse);
      expect(SyncConfig.hasBackendConfig, isTrue);
      expect(SyncConfig.isSyncReady, isFalse,
          reason: '总开关关闭后无论后端多完整都不应就绪');
    });

    test('displayNameOf 覆盖全部类型', () {
      expect(SyncConfig.displayNameOf(SyncBackendType.none),
          equals('Not configured'));
      expect(SyncConfig.displayNameOf(SyncBackendType.localFs),
          equals('Local folder'));
      expect(SyncConfig.displayNameOf(SyncBackendType.webdav), equals('WebDAV'));
      expect(SyncConfig.displayNameOf(SyncBackendType.safeServer),
          equals('SafeServer'));
    });
  });

  group('SyncService.testBackendConfig', () {
    test('localFs：真实临时目录可连通（init + getManifest + close）', () async {
      final dir = await Directory.systemTemp.createTemp('safenotes_test_');
      try {
        final draft = SyncBackendDraft(
          type: SyncBackendType.localFs,
          localFsPath: dir.path,
        );
        final result =
            await SyncService.instance.testBackendConfig(draft);
        expect(result.success, isTrue, reason: result.error ?? '未知错误');
        // 临时目录应已被 init 创建
        expect(await dir.exists(), isTrue);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('none 类型直接报错，不构造后端', () async {
      final draft = SyncBackendDraft(type: SyncBackendType.none);
      final result = await SyncService.instance.testBackendConfig(draft);
      expect(result.success, isFalse);
      expect(result.error, contains('No sync backend type selected'));
    });

    test('字段不完整的草稿直接报错', () async {
      final draft = SyncBackendDraft(
        type: SyncBackendType.webdav,
        webdavUrl: 'https://dav.example.com/dav/',
        // 缺用户名
      );
      final result = await SyncService.instance.testBackendConfig(draft);
      expect(result.success, isFalse);
      expect(result.error, contains('Configuration incomplete'));
    });
  });
}
