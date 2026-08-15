// 测试用 fake 实现集合
//
// 各 Phase 逐步将测试替身集中到此文件，取代分散在各测试文件中的私有 fake。
//
// 用法：
//   Provider<PreferencesRepository>.value(
//     value: FakePreferencesRepository(isThemeDark: true),
//   )

// Project imports:
import 'package:safenotes/data/preference_repository.dart';

/// 测试用偏好存储 fake。
///
/// 所有 getter 返回可配置的默认值（通过构造函数参数），setter 仅更新内存状态。
/// 不依赖 SharedPreferences，不触发通知。
class FakePreferencesRepository extends PreferencesRepository {
  FakePreferencesRepository({
    this.appVersionCode = 1,
    this.isThemeDark = false,
    this.themeGroupIndex = 0,
    this.themeColorIndex = 0,
    this.isDimTheme = true,
    this.darkThemeEnum = 0,
    this.isLocalDarkSwitchEnabled = false,
    this.isSystemDarkLightSwitchEnabled = true,
    this.isGridView = true,
    this.isNewFirst = true,
    this.isCompactPreview = false,
    this.isMarkdownEnabled = true,
    this.isRelativeTime = false,
    this.isSortByModified = true,
    this.isColorful = true,
    this.colorfulNotesColorIndex = 0,
    this.isFlagSecure = true,
    this.isBiometricAuthEnabled = false,
    this.biometricAttemptAllTimeCount = 0,
    this.keyboardIncognito = true,
    this.isInactivityTimeoutOn = true,
    this.inactivityTimeoutIndex = 3,
    this.focusTimeout = 180,
    this.preInactivityLogoutCounter = 15,
    this.noOfLogginAttemptAllowed = 4,
    this.bruteforceLockOutTime = 30,
    this.isBackupOn = false,
    this.isBackupNeeded = true,
    this.lastBackupTime = '',
    this.maxBackupRetryAttempts = 50,
    this.backupRedundancyCounter = 0,
    this.backupDirectory = '',
    this.isDevMode = false,
    this.isAutoRotate = false,
    this._dumpData = const {},
  });

  // ── 全局 ──
  @override
  int appVersionCode;

  @override
  Future<void> setAppVersionCodeToCurrent() async {
    appVersionCode = 30000;
  }

  // ── 主题 ──
  @override
  bool isThemeDark;

  @override
  Future<void> setIsThemeDark(bool flag) async {
    isThemeDark = flag;
  }

  @override
  int themeGroupIndex;

  @override
  int themeColorIndex;

  @override
  Future<void> setThemeGroupIndex(int index) async {
    themeGroupIndex = index;
  }

  @override
  Future<void> setThemeColorIndex(int index) async {
    themeColorIndex = index;
  }

  @override
  bool isDimTheme;

  @override
  Future<void> setIsDimTheme(bool flag) async {
    isDimTheme = flag;
  }

  @override
  int darkThemeEnum;

  @override
  Future<void> setDarkThemeEnum({required int index}) async {
    darkThemeEnum = index;
  }

  @override
  bool isLocalDarkSwitchEnabled;

  @override
  Future<void> setLocalDarkSwitchEnabled(bool flag) async {
    isLocalDarkSwitchEnabled = flag;
  }

  @override
  bool isSystemDarkLightSwitchEnabled;

  @override
  Future<void> setSystemDarkLightSwitchEnabled(bool flag) async {
    isSystemDarkLightSwitchEnabled = flag;
  }

  // ── 笔记视图 ──
  @override
  bool isGridView;

  @override
  Future<void> setIsGridView(bool flag) async {
    isGridView = flag;
  }

  @override
  bool isNewFirst;

  @override
  Future<void> setIsNewFirst(bool flag) async {
    isNewFirst = flag;
  }

  @override
  bool isCompactPreview;

  @override
  Future<void> setIsCompactPreview(bool flag) async {
    isCompactPreview = flag;
  }

  @override
  bool isMarkdownEnabled;

  @override
  Future<void> setIsMarkdownEnabled(bool flag) async {
    isMarkdownEnabled = flag;
  }

  @override
  bool isRelativeTime;

  @override
  Future<void> setIsRelativeTime(bool flag) async {
    isRelativeTime = flag;
  }

  @override
  bool isSortByModified;

  @override
  Future<void> setIsSortByModified(bool flag) async {
    isSortByModified = flag;
  }

  @override
  bool isColorful;

  @override
  Future<void> setIsColorful(bool flag) async {
    isColorful = flag;
  }

  @override
  int colorfulNotesColorIndex;

  @override
  Future<void> setColorfulNotesColorIndex(int index) async {
    colorfulNotesColorIndex = index;
  }

  // ── 安全 ──
  @override
  bool isFlagSecure;

  @override
  Future<void> setIsFlagSecure(bool flag) async {
    isFlagSecure = flag;
  }

  @override
  bool isBiometricAuthEnabled;

  @override
  Future<void> setIsBiometricAuthEnabled(bool flag) async {
    isBiometricAuthEnabled = flag;
  }

  @override
  int biometricAttemptAllTimeCount;

  @override
  Future<void> incrementBiometricAttemptAllTimeCount() async {
    biometricAttemptAllTimeCount++;
  }

  @override
  bool keyboardIncognito;

  @override
  Future<void> setKeyboardIncognito(bool flag) async {
    keyboardIncognito = flag;
  }

  // ── 会话超时 ──
  @override
  bool isInactivityTimeoutOn;

  @override
  Future<void> setIsInactivityTimeoutOn(bool flag) async {
    isInactivityTimeoutOn = flag;
  }

  @override
  int inactivityTimeoutIndex;

  @override
  int get inactivityTimeout => kInactivityTimeoutChoicesSeconds[inactivityTimeoutIndex];

  @override
  Future<void> setInactivityTimeoutIndex({required int index}) async {
    inactivityTimeoutIndex = index;
  }

  @override
  int focusTimeout;

  @override
  int preInactivityLogoutCounter;

  // ── 暴力破解 ──
  @override
  int noOfLogginAttemptAllowed;

  @override
  int bruteforceLockOutTime;

  // ── 备份 ──
  @override
  bool isBackupOn;

  @override
  Future<void> setIsBackupOn(bool flag) async {
    isBackupOn = flag;
  }

  @override
  bool isBackupNeeded;

  @override
  Future<void> setIsBackupNeeded(bool flag) async {
    isBackupNeeded = flag;
  }

  @override
  String lastBackupTime;

  @override
  Future<void> setLastBackupTime() async {
    lastBackupTime = DateTime.now().toIso8601String();
  }

  @override
  int maxBackupRetryAttempts;

  @override
  int backupRedundancyCounter;

  @override
  Future<void> incrementBackupRedundancyCounter() async {
    backupRedundancyCounter++;
  }

  @override
  String backupDirectory;

  @override
  Future<void> setBackupDirectory(String path) async {
    backupDirectory = path;
  }

  // ── 开发模式 ──
  @override
  bool isDevMode;

  @override
  Future<void> setDevMode(bool flag) async {
    isDevMode = flag;
  }

  // ── 其他 ──
  @override
  bool isAutoRotate;

  @override
  Future<void> setIsAutoRotate(bool flag) async {
    isAutoRotate = flag;
  }

  @override
  int get noOfLoginsBeforeNextPassphraseRememberChallenge => 5;

  // ── 工具 ──
  final Map<String, Object?> _dumpData;

  @override
  Map<String, Object?> dumpAll() => Map.from(_dumpData);

  @override
  Future<void> reload() async {}
}