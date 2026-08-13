// 集成测试共享 harness
//
// 提供「可复用、隔离、真实」的测试环境，让 widget/集成测试能驱动真实 UI 屏幕：
//   - EasyLocalization（从磁盘读取翻译 JSON，与 export_backup_dialog_test 一致）
//   - 平台 channel 全部用内存/空实现模拟：
//       · flutter_secure_storage → 内存 Map
//       · safenotes/window_title_bar → 直接返回 null（避免 MissingPluginException）
//   - sqflite_ffi 初始化，真实 SQLite 用内存数据库(:memory:)，避开测试沙箱对
//     系统临时目录写入的阻塞（详见 prepareUnlockedVault 注释）
//   - 用真实 Keyring.createNew + NotesDatabase.storeNote 造「带密码的真实库」，
//     密码默认 hello.1111，可 seed 若干笔记，复用 generate_real_db_test 的真实路径。
//   - pumpApp()：挂载真实 App（AuthWall → 登录/设置密码），走完整路由。
//   - wrapScreen()：给单屏注入 ShadTheme + ThemeProvider + NotesColor，便于直接验证。
//
// 用法见 auth_flow_test.dart / settings_flow_test.dart。

// Dart imports:
import 'dart:async';
import 'dart:convert';
import 'dart:math';

// Flutter imports:
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_session_timeout/local_session_timeout.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Package imports:
import 'package:crypto/crypto.dart' show Hmac, sha256;
import 'package:cryptography/cryptography.dart'
    show
        AesGcm,
        Argon2id,
        Cryptography,
        Mac,
        SecretBox,
        SecretBoxAuthenticationError,
        SecretKey;
// DartCryptography 未从公开 API 导出，测试代码可直接引用 src/ 实现。
import 'package:cryptography/src/dart/cryptography.dart' show DartCryptography;
import 'package:core/core.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Project imports:
import 'package:safenotes/app.dart';
import 'package:safenotes/authwall.dart';
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/app_theme.dart';
import 'package:safenotes/models/shad_theme.dart';
import 'package:safenotes/utils/notes_color.dart';
import 'package:safenotes/src/logger/log_webserver.dart';

/// 测试用「无 isolate」加密实现。
///
/// 背景：`cryptography` 的 `DartCryptography.argon2id` 在底层用后台 isolate
/// 跑内存硬化填充；而 `flutter test` 的子进程在本机沙箱里**无法 spawn isolate**
/// （Isolate.run 会永久挂起），导致 Keyring 派生 MK 卡死、90s 超时。
/// 集成测试只关心「登录/设置密码」这条 UI 主流程是否走得通，并不验证 Argon2id
/// 的密码学强度，因此这里把 argon2id 替换成**纯 Dart、同进程、确定性**的
/// PBKDF2-HMAC-SHA256（用 package:crypto）。派生结果与真实 Argon2id 不同，但
/// create 与 unlock 自洽——正确密码能解出 dataKey、错误密码抛异常，足以驱动
/// 整条认证流程。AES-GCM 仍走 DartCryptography 的纯 Dart 实现（无 isolate）。
class _TestArgon2id extends Argon2id {
  _TestArgon2id({
    required this.parallelism,
    required this.memory,
    required this.iterations,
    required this.hashLength,
  }) : super.constructor();

  @override
  final int parallelism;
  @override
  final int memory;
  @override
  final int iterations;
  @override
  final int hashLength;

  @override
  Future<SecretKey> deriveKey({
    required SecretKey secretKey,
    required List<int> nonce,
    List<int> optionalSecret = const <int>[],
    List<int> associatedData = const <int>[],
  }) async {
    // ignore: avoid_print
    print('DBG argon2id deriveKey start');
    final pw = await secretKey.extractBytes();
    // 低迭代次数足矣：测试追求的是「快且确定性」，而非抗暴力破解。
    final out = _pbkdf2HmacSha256(
      password: pw,
      salt: nonce,
      iterations: 4096,
      length: hashLength,
    );
    return SecretKey(out);
  }
}

/// 仅替换 argon2id / aesGcm 的 Cryptography 实现；其余沿用纯 Dart 实现。
class _TestCryptography extends DartCryptography {
  @override
  Argon2id argon2id({
    required int memory,
    required int parallelism,
    required int iterations,
    required int hashLength,
  }) {
    return _TestArgon2id(
      memory: memory,
      parallelism: parallelism,
      iterations: iterations,
      hashLength: hashLength,
    );
  }

  @override
  AesGcm aesGcm({int secretKeyLength = 32, int nonceLength = 12}) {
    return _TestAesGcm(
      secretKeyLength: secretKeyLength,
      nonceLength: nonceLength,
    );
  }
}

/// 测试用「无 isolate」AES-GCM 替身。
///
/// 不实现真正的 AES/GCM，而是用 HMAC-SHA256 派生密钥流做 XOR 流加密
/// （package:crypto 的 Hmac，纯 Dart、同进程）。只要 encrypt/decrypt 互为逆运算、
/// 且 wrap/unwrapDataKey 用同一把 MK，密钥环就能正确落盘与还原。集成测试只验证
/// 认证主流程是否走得通，不验证密码学强度。
class _TestAesGcm extends AesGcm {
  _TestAesGcm({this.secretKeyLength = 32, this.nonceLength = 12})
      : super.constructor();

  @override
  final int secretKeyLength;
  @override
  final int nonceLength;

  @override
  Future<SecretBox> encrypt(
    List<int> clearText, {
    required SecretKey secretKey,
    List<int>? nonce,
    List<int> aad = const <int>[],
    Uint8List? possibleBuffer,
  }) async {
    // ignore: avoid_print
    print('DBG aes encrypt start');
    final key = await secretKey.extractBytes();
    final usedNonce = nonce ?? _randomBytes(nonceLength);
    final cipherText = _xorKeystream(key: key, nonce: usedNonce, data: clearText);
    // mac 长度需与 macAlgorithm.macLength 一致（GCM 为 16），这里填 16 字节。
    final mac = _hmac(key, cipherText).sublist(0, 16);
    return SecretBox(cipherText, nonce: usedNonce, mac: Mac(mac));
  }

  @override
  Future<List<int>> decrypt(
    SecretBox secretBox, {
    required SecretKey secretKey,
    List<int>? nonce,
    List<int> aad = const <int>[],
    Uint8List? possibleBuffer,
  }) async {
    final key = await secretKey.extractBytes();
    // 认证：复算 encrypt 时写入的 MAC（HMAC-SHA256(key, cipherText) 前 16 字节），
    // 并与 SecretBox 携带的 mac 做常数时间比较。主密钥（由密码派生）错误时，
    // 错误 key 复算出的 MAC 与落盘 MAC 不匹配 → 抛 SecretBoxAuthenticationError，
    // 被 SyncCrypto._aesGcmDecrypt 的 on Object 捕获并包装为 SyncDecryptionException，
    // 最终由 keyring._unwrapOrThrow 转成 WrongPasswordException——与真实 AES-GCM
    // 的 tag 校验失败行为一致，使「错误密码」路径能被正确识别（否则 XOR 对称可
    // 逆，任何密码都会「解密成功」从而登录成功，错误密码分支永远触发不了）。
    final expectedMac = _hmac(key, secretBox.cipherText).sublist(0, 16);
    final storedMac = secretBox.mac.bytes;
    if (!_constantTimeEqual(expectedMac, storedMac)) {
      throw SecretBoxAuthenticationError();
    }
    final usedNonce = nonce ?? secretBox.nonce;
    final out = _xorKeystream(
      key: key,
      nonce: usedNonce,
      data: secretBox.cipherText,
    );
    return out;
  }
}

/// 纯 Dart PBKDF2-HMAC-SHA256（package:crypto 的 Hmac），同步、无 isolate。
Uint8List _pbkdf2HmacSha256({
  required List<int> password,
  required List<int> salt,
  required int iterations,
  required int   length,
}) {
  const hlen = 32; // SHA-256 输出长度
  final hmac = Hmac(sha256, password);
  final blocks = (length + hlen - 1) ~/ hlen;
  final out = Uint8List(blocks * hlen);
  for (var block = 1; block <= blocks; block++) {
    final inner = Uint8List(salt.length + 4);
    inner.setRange(0, salt.length, salt);
    inner[salt.length] = (block >> 24) & 0xff;
    inner[salt.length + 1] = (block >> 16) & 0xff;
    inner[salt.length + 2] = (block >> 8) & 0xff;
    inner[salt.length + 3] = block & 0xff;
    var u = hmac.convert(inner).bytes;
    final t = Uint8List.fromList(u);
    for (var i = 2; i <= iterations; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < t.length; j++) {
        t[j] ^= u[j];
      }
    }
    out.setRange((block - 1) * hlen, (block - 1) * hlen + hlen, t);
  }
  return out.sublist(0, length);
}

/// HMAC-SHA256（返回 32 字节）。
Uint8List _hmac(List<int> key, List<int> data) =>
    Uint8List.fromList(Hmac(sha256, key).convert(data).bytes);

/// 常数时间比较两个字节序列（防止时序侧信道；此处用于测试替身的 MAC 校验）。
bool _constantTimeEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// 用 HMAC-SHA256(key, nonce ‖ blockIndex) 派生密钥流，与 data 做 XOR。
/// blockIndex 为 4 字节大端，按 32 字节分块；加密解密同运算（对称）。
Uint8List _xorKeystream({
  required List<int> key,
  required List<int> nonce,
  required List<int> data,
}) {
  const blockSize = 32;
  final out = Uint8List(data.length);
  final counter = Uint8List(4);
  final input = Uint8List(nonce.length + 4);
  input.setRange(0, nonce.length, nonce);
  for (var i = 0; i < data.length; i += blockSize) {
    final blockIndex = i ~/ blockSize;
    counter[0] = (blockIndex >> 24) & 0xff;
    counter[1] = (blockIndex >> 16) & 0xff;
    counter[2] = (blockIndex >> 8) & 0xff;
    counter[3] = blockIndex & 0xff;
    input.setRange(nonce.length, nonce.length + 4, counter);
    final ks = _hmac(key, input);
    final end = data.length - i < blockSize ? data.length - i : blockSize;
    for (var j = 0; j < end; j++) {
      out[i + j] = data[i + j] ^ ks[j];
    }
  }
  return out;
}

/// 安全随机字节（nonce 用）。
Uint8List _randomBytes(int length) {
  final r = Random.secure();
  return Uint8List.fromList(List<int>.generate(length, (_) => r.nextInt(256)));
}

/// 测试用翻译加载器。
///
/// 背景：flutter test 的资源 bundle 不含项目翻译文件，需要自行加载。
/// 原先直接用 `dart:io` 的 `File.readAsString` 从磁盘读取，但在本机测试沙箱里
/// 该调用会**永久挂起**（文件 I/O 被阻断，且会冻结事件循环，连超时定时器都无法触发），
/// 导致 EasyLocalization 的 LocalizationsResolver 永远不就绪 → 整个 App 被渲染成
/// `SizedBox.shrink()` → AuthWall 从未构建 → 所有 `find.text` 断言失败。
///
/// 改用 `rootBundle.loadString`：它走 Flutter 的 asset bundle（pubspec 已声明
/// `assets/translations/`），在 flutter test 下可正常加载，且不会触发被阻断的
/// dart:io 文件 I/O。en-US.json 的键与英文值一致（如 "Login"→"Login"），缺失的键
/// `.tr()` 会回退到键本身，因此测试断言的英文文本与加载真实翻译后渲染的文本一致。
/// 若加载仍失败，退化为空表（.tr() 返回 key），保证 UI 仍能渲染、可被驱动。
///
/// 记忆化（按 locale 缓存 Future）：首个 EasyLocalization 实例卸载后，本机沙箱里
/// 第二次调用 `rootBundle.loadString` 会再次挂起（事件循环被冻结），表现为后续
/// `pumpApp` 永远渲染不出 App。同一进程内翻译不会变化，故每个 locale 只加载一次，
/// 既规避二次挂起，又提升确定性、减少重复 I/O。
class _TestAssetLoader extends AssetLoader {
  static final Map<String, Future<Map<String, dynamic>?>> _cache = {};

  @override
  Future<Map<String, dynamic>?> load(String path, Locale locale) async {
    final code = locale.countryCode == null
        ? locale.languageCode
        : '${locale.languageCode}-${locale.countryCode}';
    final cacheKey = '$path/$code';
    return _cache.putIfAbsent(cacheKey, () async {
      try {
        final raw = await rootBundle.loadString('$cacheKey.json');
        return jsonDecode(raw) as Map<String, dynamic>;
      } on Object {
        // 退化：返回空表，.tr() 直接返回 key（英文），不影响 UI 渲染与驱动。
        return <String, dynamic>{};
      }
    });
  }
}

/// flutter_secure_storage 的内存实现，避免 MissingPluginException。
const _secureChannel =
    MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
final Map<String, String> _secureStore = {};

void _setupSecureStorageMock() {
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

/// 标题栏主题通道（Windows 专用）；测试里直接返回 null，避免未注册通道报错。
const _titleBarChannel = MethodChannel('safenotes/window_title_bar');

/// 全局测试环境初始化（setUpAll 调用一次）。
Future<void> initTestEnv() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 必须在首次 getInstance() 之前注入，否则去初始化真实平台存储。
  SharedPreferences.setMockInitialValues({});
  _setupSecureStorageMock();
  TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_titleBarChannel, (call) async => null);
  // 桌面端用 sqflite_ffi（与 main._bootstrap 一致的真实 SQLite 路径），
  // 内存数据库(:memory:) 避开对系统临时目录的写入。
  // 用「无后台 isolate」变体：databaseFactoryFfi 默认把 SQLite 操作放到后台
  // isolate，在本机 flutter test 的完整初始化（EasyLocalization 等）下会与
  // 测试事件循环死锁，表现为 openDatabase 永久挂起（dart:isolate
  // _RawReceivePort._handleMessage）。NoIsolate 让 SQLite 跑在主 isolate，
  // 操作同步且短促，彻底规避该死锁。
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  // 用「无 isolate」加密实现替换 cryptography 默认实例：cryptography 的
  // Argon2id 在 flutter test 子进程里会 spawn 后台 isolate 并永久挂起，
  // 导致 Keyring 派生 MK 卡死。测试只关心认证主流程能否走通，不验证密码学强度，
  // 故用纯 Dart、同进程的 PBKDF2-HMAC-SHA256 取代（详见 _TestArgon2id 注释）。
  // AES-GCM 仍走 DartCryptography 的纯 Dart 实现（无 isolate）。
  Cryptography.instance = _TestCryptography();
  // ignore: avoid_print
  print('DBG instance=${Cryptography.instance.runtimeType}');
  // 集成测试关闭日志 HTTP 服务器：其 HttpServer idle timeout 会在 FakeAsync 下
  // 留下永远 pending 的周期性 Timer（见 log_webserver.dart 的 enableWebServer 注释）。
  LogWebServer.enableWebServer = false;
  await EasyLocalization.ensureInitialized();
}

/// 造一个「已初始化保险库、已解锁」的真实测试库。
///
/// 注意：必须使用「内存数据库」(:memory:) 而非落盘文件。flutter test 的子进程
/// 在沙箱里对系统临时目录（AppData\Local\Temp）的文件写入会被阻塞/挂起，
/// 导致 Directory.systemTemp.createTemp 永久 await，进而 90s 超时。
/// 内存库与 core 包自身测试一致，且完全避开文件系统，稳定可重复。
///
/// [password] 默认 hello.1111（与手测一致）；[seeds] 可选预置笔记。
/// 设置 AppBootState.vaultInitialized=true，使 AuthWall 走登录页。
Future<void> prepareUnlockedVault({
  String password = 'hello.1111',
  List<({String title, String description})> seeds = const [],
}) async {
  final db = await openDatabase(
    ':memory:',
    version: 4,
    onCreate: NotesDatabase.createDBForTesting,
  );
  NotesDatabase.setDatabaseForTesting(db);

  // 真实初始化密钥环（生产首次设置密码走的接口）
  final keyring = await Keyring.createNew(
    password: password,
    database: NotesDatabase.instance,
  );
  NotesDatabase.instance.setDataKey(keyring.dataKey);

  for (final s in seeds) {
    await NotesDatabase.instance.storeNote(
      SafeNote.create(title: s.title, description: s.description),
    );
  }

  await PreferencesStorage.init();
  AppBootState.vaultInitialized = true;
}

/// 造一个「空保险库」的内存测试库（无 keyring），用于首次运行设置密码流程。
Future<void> prepareEmptyVault() async {
  // ignore: avoid_print
  print('DBG prepareEmptyVault start');
  final db = await openDatabase(
    ':memory:',
    version: 4,
    onCreate: NotesDatabase.createDBForTesting,
  );
  NotesDatabase.setDatabaseForTesting(db);
  await PreferencesStorage.init();
  AppBootState.vaultInitialized = false;
  // ignore: avoid_print
  print('DBG prepareEmptyVault end');
}

/// 关闭内存库，保证用例间隔离。
Future<void> disposeVault() async {
  try {
    await NotesDatabase.instance.close();
  } on Object {
    // 忽略关闭异常
  }
}

/// 挂载真实 App（AuthWall 按 AppBootState.vaultInitialized 选择登录/设置密码页）。
///
/// 每次调用创建独立的 session stream 与 navigator key。测试通过 UI 交互驱动路由。
///
/// 注意：登录/设置密码页在 build() 里会按软键盘显隐调用 scrollToBottomIfOnScreenKeyboard()，
/// 在 flutter_test 里 autofocus 会唤起模拟软键盘（viewInsets.bottom>0），从而每帧
/// animateTo 形成「永不收敛」的滚动动画，使 pumpAndSettle 卡死超时。
/// 故此处改用有限时长 pump（与 _settle 一致），不依赖动画收敛。
Future<void> pumpApp(WidgetTester tester) async {
  // ignore: avoid_print
  print('DBG pumpApp start');
  await tester.pumpWidget(
    EasyLocalization(
      path: 'assets/translations',
      supportedLocales: const [Locale('en', 'US'), Locale('zh', 'CN')],
      fallbackLocale: const Locale('en', 'US'),
      startLocale: const Locale('en', 'US'),
      assetLoader: _TestAssetLoader(),
      child: App(
        sessionStateStream: StreamController<SessionState>(),
        navigatorKey: GlobalKey<NavigatorState>(),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
  // ignore: avoid_print
  print('DBG pumpApp end');
}

/// 有限时长泵入：用于含永动动画/过渡的页面（如登录页软键盘滚动动画、HomePage 的
/// 重复动画），代替 pumpAndSettle 以避免测试卡死。覆盖 keyring 派生(~1-2s)+转场。
Future<void> settle(WidgetTester tester, {int steps = 14}) async {
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

// ──────────────────────────────────────────────
// 单屏封装（直接验证 SettingsScreen / ColorPallet / ThemeBottomSheet 等）
// ──────────────────────────────────────────────

/// 单屏测试使用的固定主题 seed（与 App 默认一致：独立默认色·深海蓝，
/// 即 ThemeProvider.defaultSeedColor，不依赖 seed 色库数据）。
const Color kTestThemeSeed = Color(0xFF0F3460);

/// 单屏测试共用的 Provider 实例（测试可读取以断言状态变化）。
late ThemeProvider testThemeProvider;
late NotesColor testNotesColor;

/// 在 setUp 调用：创建供单屏测试使用的 Provider 实例。
void prepareProviders() {
  testThemeProvider = ThemeProvider();
  testNotesColor = NotesColor();
}

/// 把单个屏幕包进 ShadTheme + MaterialApp + 双 Provider，
/// 与 App 的提供者结构一致，可真实渲染 ShadButton / ShadTheme.of(context)。
Widget wrapScreen(Widget screen) {
  return EasyLocalization(
    path: 'assets/translations',
    supportedLocales: const [Locale('en', 'US'), Locale('zh', 'CN')],
    fallbackLocale: const Locale('en', 'US'),
    startLocale: const Locale('en', 'US'),
    assetLoader: _TestAssetLoader(),
    child: MultiProvider(
      providers: [
        ChangeNotifierProvider<ThemeProvider>.value(value: testThemeProvider),
        ChangeNotifierProvider<NotesColor>.value(value: testNotesColor),
      ],
      builder: (context, _) => Builder(
        builder: (ctx) {
          // 订阅 ThemeProvider，使 themeMode 变化时重建 ShadApp.custom
          final tp = Provider.of<ThemeProvider>(ctx);
          return ShadApp.custom(
            themeMode: tp.themeMode,
            theme: ShadThemes.build(kTestThemeSeed, Brightness.light),
            darkTheme: ShadThemes.build(kTestThemeSeed, Brightness.dark),
            appBuilder: (c) => MaterialApp(home: screen),
          );
        },
      ),
    ),
  );
}
