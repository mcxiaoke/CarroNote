// PreferencesRepository 接口：抽象化偏好存储层
//
// 设计目标：用 ChangeNotifier 接口替换 PreferencesStorage 的全部静态 getter/setter，
// 使测试可以通过 FakePreferencesRepository 注入任意偏好值，无需依赖 SharedPreferences。
//
// 用法：
//   生产：Provider<PreferencesRepository>.value(value: ...)
//   测试：Provider<PreferencesRepository>.value(value: FakePreferencesRepository())
//
// 静态桥：PreferencesStorage 的静态方法转发到 PreferencesRepository.instance，
// 若未主动注入（instance == null）则保持原有 SharedPreferences 行为，保证迁移期间
// 所有现有调用方无感。
//
// §4.1 交付物：
//   - PreferencesRepository（抽象类，extends ChangeNotifier）
//   - SharedPreferencesPreferencesRepository（真实实现）
//   - PreferencesStorage 静态桥（转发到 _inst）
//   - FakePreferencesRepository in test/support/fakes.dart

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:shared_preferences/shared_preferences.dart';

// Project imports:
import 'package:safenotes/data/preference_and_config.dart';

/// 偏好存储抽象接口。
///
/// 所有 getter/setter 与现有 PreferencesStorage 静态方法一一对应。
/// 继承 ChangeNotifier 以便 Provider 监听变化。
abstract class PreferencesRepository extends ChangeNotifier {
  // ── 全局 ──

  int get appVersionCode;
  Future<void> setAppVersionCodeToCurrent();

  // ── 主题 ──

  bool get isThemeDark;
  Future<void> setIsThemeDark(bool flag);

  int get themeGroupIndex;
  int get themeColorIndex;
  Future<void> setThemeGroupIndex(int index);
  Future<void> setThemeColorIndex(int index);

  bool get isDimTheme;
  Future<void> setIsDimTheme(bool flag);

  int get darkThemeEnum;
  Future<void> setDarkThemeEnum({required int index});

  bool get isLocalDarkSwitchEnabled;
  Future<void> setLocalDarkSwitchEnabled(bool flag);

  bool get isSystemDarkLightSwitchEnabled;
  Future<void> setSystemDarkLightSwitchEnabled(bool flag);

  // ── 笔记视图 ──

  bool get isGridView;
  Future<void> setIsGridView(bool flag);

  bool get isNewFirst;
  Future<void> setIsNewFirst(bool flag);

  bool get isCompactPreview;
  Future<void> setIsCompactPreview(bool flag);

  bool get isMarkdownEnabled;
  Future<void> setIsMarkdownEnabled(bool flag);

  bool get isRelativeTime;
  Future<void> setIsRelativeTime(bool flag);

  bool get isSortByModified;
  Future<void> setIsSortByModified(bool flag);

  bool get isColorful;
  Future<void> setIsColorful(bool flag);

  int get colorfulNotesColorIndex;
  Future<void> setColorfulNotesColorIndex(int index);

  // ── 安全 ──

  bool get isFlagSecure;
  Future<void> setIsFlagSecure(bool flag);

  bool get isBiometricAuthEnabled;
  Future<void> setIsBiometricAuthEnabled(bool flag);

  int get biometricAttemptAllTimeCount;
  Future<void> incrementBiometricAttemptAllTimeCount();

  bool get keyboardIncognito;
  Future<void> setKeyboardIncognito(bool flag);

  // ── 会话超时 ──

  bool get isInactivityTimeoutOn;
  Future<void> setIsInactivityTimeoutOn(bool flag);

  int get inactivityTimeoutIndex;
  int get inactivityTimeout;
  Future<void> setInactivityTimeoutIndex({required int index});

  int get focusTimeout;
  int get preInactivityLogoutCounter;

  // ── 暴力破解防护 ──

  int get noOfLogginAttemptAllowed;
  int get bruteforceLockOutTime;

  // ── 备份 ──

  bool get isBackupOn;
  Future<void> setIsBackupOn(bool flag);

  bool get isBackupNeeded;
  Future<void> setIsBackupNeeded(bool flag);

  String get lastBackupTime;
  Future<void> setLastBackupTime();

  int get maxBackupRetryAttempts;
  int get backupRedundancyCounter;
  Future<void> incrementBackupRedundancyCounter();

  String get backupDirectory;
  Future<void> setBackupDirectory(String path);

  // ── 开发模式 ──

  bool get isDevMode;
  Future<void> setDevMode(bool flag);

  // ── 其他 ──

  bool get isAutoRotate;
  Future<void> setIsAutoRotate(bool flag);

  int get noOfLoginsBeforeNextPassphraseRememberChallenge;

  // ── 工具 ──

  Map<String, Object?> dumpAll();
  Future<void> reload();

  /// 清除 keyring 相关的 SharedPreferences key（忘记密码逃生通道使用）
  Future<void> clearVaultRelatedKeys();
}

/// SharedPreferences 实现的 PreferencesRepository。
class SharedPreferencesPreferencesRepository extends PreferencesRepository {
  SharedPreferences? _prefs;

  /// [prefs] 由装配点注入已加载的实例（避免构造期异步 getInstance 竞态，
  /// 导致首次读取落到默认值）。未传入时退回自行异步加载。
  SharedPreferencesPreferencesRepository({SharedPreferences? prefs}) {
    if (prefs != null) {
      _prefs = prefs;
    } else {
      _init();
    }
  }

  Future<void> _init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  bool _getBool(String key, bool defaultValue) =>
      _prefs?.getBool(key) ?? defaultValue;

  int _getInt(String key, int defaultValue) =>
      _prefs?.getInt(key) ?? defaultValue;

  String _getString(String key, String defaultValue) =>
      _prefs?.getString(key) ?? defaultValue;

  Future<void> _setBool(String key, bool value) =>
      _prefs?.setBool(key, value) ?? Future.value();

  Future<void> _setInt(String key, int value) =>
      _prefs?.setInt(key, value) ?? Future.value();

  Future<void> _setString(String key, String value) =>
      _prefs?.setString(key, value) ?? Future.value();

  // ── 全局 ──

  @override
  int get appVersionCode => _getInt('appVersionCode', 1);

  @override
  Future<void> setAppVersionCodeToCurrent() async {
    // 与 PreferencesStorage.setAppVersionCodeToCurrent 一致：写入当前版本号，
    // 不硬编码，避免版本升级后此处漂移导致 onAppUpdate 每次启动重复执行。
    await _setInt('appVersionCode', SafeNotesConfig.appVersionCode);
  }

  // ── 主题 ──

  @override
  bool get isThemeDark {
    // 与 PreferencesStorage.isThemeDark 语义一致：
    // 1) 若开启「跟随系统深浅色」，直接返回系统亮度；
    // 2) 否则优先返回显式设置的值（可能为 false）；
    // 3) 未显式设置时回退到系统亮度（getBool 返回 null，不能简单用默认 false 兜底）。
    final prefs = _prefs;
    final isSystemDark =
        WidgetsBinding.instance.platformDispatcher.platformBrightness ==
        Brightness.dark;
    if (isSystemDarkLightSwitchEnabled) {
      return isSystemDark;
    }
    final isDark = prefs?.getBool('isthemedark');
    if (isDark != null) return isDark;
    return isSystemDark;
  }

  @override
  Future<void> setIsThemeDark(bool flag) async {
    await _setBool('isthemedark', flag);
    notifyListeners();
  }

  @override
  int get themeGroupIndex => _getInt('themeGroupIndex', 0);

  @override
  int get themeColorIndex => _getInt('themeColorIndex', 0);

  @override
  Future<void> setThemeGroupIndex(int index) async {
    await _setInt('themeGroupIndex', index);
    notifyListeners();
  }

  @override
  Future<void> setThemeColorIndex(int index) async {
    await _setInt('themeColorIndex', index);
    notifyListeners();
  }

  @override
  bool get isDimTheme => _getBool('isDimTheme', true);

  @override
  Future<void> setIsDimTheme(bool flag) async {
    await _setBool('isDimTheme', flag);
    notifyListeners();
  }

  @override
  int get darkThemeEnum => _getInt('isDarkThemeEnum', 0);

  @override
  Future<void> setDarkThemeEnum({required int index}) async {
    await _setInt('isDarkThemeEnum', index);
  }

  @override
  bool get isLocalDarkSwitchEnabled =>
      _getBool('isLocalDarkSwitchEnabled', false);

  @override
  Future<void> setLocalDarkSwitchEnabled(bool flag) async {
    await _setBool('isLocalDarkSwitchEnabled', flag);
    notifyListeners();
  }

  @override
  bool get isSystemDarkLightSwitchEnabled =>
      _getBool('isSystemDarkLightSwitchEnabled', true);

  @override
  Future<void> setSystemDarkLightSwitchEnabled(bool flag) async {
    await _setBool('isSystemDarkLightSwitchEnabled', flag);
    notifyListeners();
  }

  // ── 笔记视图 ──

  @override
  bool get isGridView => _getBool('isGridView', true);

  @override
  Future<void> setIsGridView(bool flag) async {
    await _setBool('isGridView', flag);
    notifyListeners();
  }

  @override
  bool get isNewFirst => _getBool('isNewFirst', true);

  @override
  Future<void> setIsNewFirst(bool flag) async {
    await _setBool('isNewFirst', flag);
    notifyListeners();
  }

  @override
  bool get isCompactPreview => _getBool('isCompactPreview', false);

  @override
  Future<void> setIsCompactPreview(bool flag) async {
    await _setBool('isCompactPreview', flag);
    notifyListeners();
  }

  @override
  bool get isMarkdownEnabled => _getBool('isMarkdownEnabled', true);

  @override
  Future<void> setIsMarkdownEnabled(bool flag) async {
    await _setBool('isMarkdownEnabled', flag);
    notifyListeners();
  }

  @override
  bool get isRelativeTime => _getBool('isRelativeTime', false);

  @override
  Future<void> setIsRelativeTime(bool flag) async {
    await _setBool('isRelativeTime', flag);
    notifyListeners();
  }

  @override
  bool get isSortByModified => _getBool('isSortByModified', true);

  @override
  Future<void> setIsSortByModified(bool flag) async {
    await _setBool('isSortByModified', flag);
    notifyListeners();
  }

  @override
  bool get isColorful => _getBool('isColorful', true);

  @override
  Future<void> setIsColorful(bool flag) async {
    await _setBool('isColorful', flag);
    notifyListeners();
  }

  @override
  int get colorfulNotesColorIndex => _getInt('colorfulNotesColorIndex', 0);

  @override
  Future<void> setColorfulNotesColorIndex(int index) async {
    await _setInt('colorfulNotesColorIndex', index);
  }

  // ── 安全 ──

  @override
  bool get isFlagSecure => _getBool('isFlagSecure', true);

  @override
  Future<void> setIsFlagSecure(bool flag) async {
    await _setBool('isFlagSecure', flag);
    notifyListeners();
  }

  @override
  bool get isBiometricAuthEnabled => _getBool('isBiometricAuthEnabled', false);

  @override
  Future<void> setIsBiometricAuthEnabled(bool flag) async {
    await _setBool('isBiometricAuthEnabled', flag);
    notifyListeners();
  }

  @override
  int get biometricAttemptAllTimeCount =>
      _getInt('biometricAttemptAllTimeCount', 0);

  @override
  Future<void> incrementBiometricAttemptAllTimeCount() async {
    final current = biometricAttemptAllTimeCount;
    await _setInt('biometricAttemptAllTimeCount', current + 1);
  }

  @override
  bool get keyboardIncognito => _getBool('keyboardIcognito', true);

  @override
  Future<void> setKeyboardIncognito(bool flag) async {
    await _setBool('keyboardIcognito', flag);
    notifyListeners();
  }

  // ── 会话超时 ──

  @override
  bool get isInactivityTimeoutOn => _getBool('isInactivityTimeoutOn', true);

  @override
  Future<void> setIsInactivityTimeoutOn(bool flag) async {
    await _setBool('isInactivityTimeoutOn', flag);
    notifyListeners();
  }

  @override
  int get inactivityTimeoutIndex {
    final index = _getInt('inactivityTimeout', 3);
    if (index >= 0 && index < kInactivityTimeoutChoicesSeconds.length) {
      return index;
    }
    return 3; // default: 3 minutes
  }

  @override
  int get inactivityTimeout {
    final idx = inactivityTimeoutIndex;
    return kInactivityTimeoutChoicesSeconds[idx];
  }

  @override
  Future<void> setInactivityTimeoutIndex({required int index}) async {
    await _setInt('inactivityTimeout', index);
    notifyListeners();
  }

  @override
  int get focusTimeout => inactivityTimeout;

  @override
  int get preInactivityLogoutCounter =>
      _getInt('preInactivityLogoutCounter', 15);

  // ── 暴力破解防护 ──

  @override
  int get noOfLogginAttemptAllowed => _getInt('noOfLogginAttemptAllowed', 4);

  @override
  int get bruteforceLockOutTime => _getInt('bruteforceLockOutTime', 30);

  // ── 备份 ──

  @override
  bool get isBackupOn => _getBool('isBackupOn', false);

  @override
  Future<void> setIsBackupOn(bool flag) async {
    await _setBool('isBackupOn', flag);
    notifyListeners();
  }

  @override
  bool get isBackupNeeded => _getBool('isBackupNeeded', true);

  @override
  Future<void> setIsBackupNeeded(bool flag) async {
    await _setBool('isBackupNeeded', flag);
  }

  @override
  String get lastBackupTime => _getString('lastBackupTime', '');

  @override
  Future<void> setLastBackupTime() async {
    await _setString('lastBackupTime', DateTime.now().toIso8601String());
  }

  @override
  int get maxBackupRetryAttempts => _getInt('maxBackupRetryAttempts', 50);

  @override
  int get backupRedundancyCounter => _getInt('backupRedundancyCounter', 0);

  @override
  Future<void> incrementBackupRedundancyCounter() async {
    final current = backupRedundancyCounter;
    await _setInt('backupRedundancyCounter', current + 1);
  }

  @override
  String get backupDirectory => _getString('backupDirectory', '');

  @override
  Future<void> setBackupDirectory(String path) async {
    await _setString('backupDirectory', path);
  }

  // ── 开发模式 ──

  @override
  bool get isDevMode => _getBool('devModeEnabled', false);

  @override
  Future<void> setDevMode(bool flag) async {
    await _setBool('devModeEnabled', flag);
    notifyListeners();
  }

  // ── 其他 ──

  @override
  bool get isAutoRotate => _getBool('isAutoRotate', false);

  @override
  Future<void> setIsAutoRotate(bool flag) async {
    await _setBool('isAutoRotate', flag);
    notifyListeners();
  }

  @override
  int get noOfLoginsBeforeNextPassphraseRememberChallenge => 5;

  // ── 工具 ──

  @override
  Map<String, Object?> dumpAll() {
    final prefs = _prefs;
    if (prefs == null) return const {};
    final out = <String, Object?>{};
    for (final key in prefs.getKeys()) {
      out[key] = prefs.get(key);
    }
    return out;
  }

  @override
  Future<void> reload() async {
    await _prefs?.reload();
  }

  @override
  Future<void> clearVaultRelatedKeys() async {
    await _prefs?.remove('passphrasehash');
  }
}

const List<int> kInactivityTimeoutChoicesSeconds = [
  30, // 30 秒
  60, // 1 分钟
  120, // 2 分钟
  180, // 3 分钟（缺省）
  300, // 5 分钟
  600, // 10 分钟
  900, // 15 分钟
];

/// 缺省索引：3 分钟（=180s），与 UI 中「3 minutes (Default)」一致。
const int kDefaultInactivityTimeoutIndex = 3;
