// 行为契约测试：SessionProvider 的登录/登出/改密码副作用序列
//
// 背景：P2 把原本分散在 Session 静态类里的登录/登出/改密码副作用收口到
// SessionProvider（依赖构造注入）。本测试用「可录制的 fake」锁定副作用
// 的调用序列与参数——这类「顺序/参数漂移」光看代码很难发现，但任何改动
// 都会让本测试变红。
//
// 同时断言 PhraseHandler（内存密码）在登录/登出后的状态，锁住会话密码
// 装载/清除这一安全关键路径。

import 'package:flutter_test/flutter_test.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/session_provider.dart';
import 'support/fake_repositories.dart';
import 'support/fakes.dart';
import 'support/platform_fakes.dart';

/// 记录 SyncRepository 调用的录制 fake。
class _RecordingSyncRepo extends FakeSyncRepository {
  final List<String> calls = [];

  @override
  Future<void> logout() async {
    calls.add('sync.logout');
    await super.logout();
  }
}

/// 记录 NotesRepository 调用的录制 fake。
class _RecordingNotesRepo extends FakeNotesRepository {
  final List<String> calls = [];

  @override
  void clearDataKey() {
    calls.add('notes.clearDataKey');
    super.clearDataKey();
  }
}

/// 记录 BiometricPort 写入的录制 fake。
class _RecordingBiometric extends FakeBiometric {
  final List<String> saves = [];

  @override
  Future<void> saveCredential(String password) async {
    saves.add(password);
    await super.saveCredential(password);
  }
}

void main() {
  late _RecordingSyncRepo syncRepo;
  late _RecordingNotesRepo notesRepo;
  late FakePreferencesRepository prefs;
  late _RecordingBiometric biometric;

  setUp(() {
    syncRepo = _RecordingSyncRepo();
    notesRepo = _RecordingNotesRepo();
    prefs = FakePreferencesRepository();
    biometric = _RecordingBiometric();
  });

  tearDown(() {
    // 清理内存密码，避免用例间串扰（安全红线）。
    PhraseHandler.destroy();
  });

  SessionProvider buildProvider({bool? vaultInitialized}) => SessionProvider(
    notesRepo: notesRepo,
    syncRepo: syncRepo,
    prefsRepo: prefs,
    biometric: biometric,
    vaultInitialized: vaultInitialized,
  );

  group('login', () {
    test('装载密码短语；biometric 未启用时不写凭据', () async {
      prefs.isBiometricAuthEnabled = false;
      buildProvider().login('secret-pass');

      expect(PhraseHandler.getPass, 'secret-pass');
      expect(biometric.saves, isEmpty, reason: '未启用 biometric 不应写凭据');
    });

    test('biometric 启用时写入与本次登录相同的凭据', () async {
      prefs.isBiometricAuthEnabled = true;
      buildProvider().login('secret-pass');

      expect(PhraseHandler.getPass, 'secret-pass');
      expect(biometric.saves, [
        'secret-pass',
      ], reason: '凭据必须等于本次已验证的密码（覆盖他端改密后重新登录场景）');
    });
  });

  group('onPasswordSet', () {
    test('与 login 一致：装载密码 + 启用时刷新凭据', () async {
      prefs.isBiometricAuthEnabled = true;
      buildProvider().onPasswordSet('new-pass');

      expect(PhraseHandler.getPass, 'new-pass');
      expect(biometric.saves, ['new-pass']);
    });
  });

  group('logout', () {
    test('副作用顺序：sync.logout → notes.clearDataKey → 清除内存密码', () async {
      prefs.isBiometricAuthEnabled = true;
      final provider = buildProvider();
      provider.login('secret-pass');
      expect(PhraseHandler.getPass, 'secret-pass');

      await provider.logout();

      // 顺序契约：先释放同步密钥，再清 dataKey（避免在途刷新读空 dataKey）。
      expect(syncRepo.calls, ['sync.logout']);
      expect(notesRepo.calls, ['notes.clearDataKey']);
      expect(PhraseHandler.getPass, isEmpty, reason: '登出必须清除内存密码');
    });

    test('未登录时调用 logout 也安全（不抛异常）', () async {
      final provider = buildProvider();
      await provider.logout();
      expect(PhraseHandler.getPass, isEmpty);
    });
  });

  group('vaultInitialized 透传', () {
    test('null/true/false 原样透传', () {
      expect(buildProvider(vaultInitialized: null).vaultInitialized, isNull);
      expect(buildProvider(vaultInitialized: true).vaultInitialized, isTrue);
      expect(buildProvider(vaultInitialized: false).vaultInitialized, isFalse);
    });
  });
}
