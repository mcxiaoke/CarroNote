/*
* Copyright (C) Keshav Priyadarshi and others - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*
* You should have received a copy of the GNU General Public License v3.0 with
* this file. If not, please visit https://www.gnu.org/licenses/gpl-3.0.html
*
* See https://safenotes.dev for support or download.
*/

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timeago/timeago.dart' as timeago;

// Project imports:
import 'package:core/core.dart';

class PreferencesStorage {
  static SharedPreferences? _preferences;

  // 简化方案:passPhraseHash 已移除(以 keyring 解密作为唯一凭证)
  // 保留 _keyPassPhraseHash 常量用于 init() 时清理旧版残留 key(评审 mmm3 B6)
  static const _keyPassPhraseHash = 'passphrasehash';
  static const _keyIsThemeDark = 'isthemedark';
  static const _keyKeyboardIncognito = 'keyboardIcognito';
  static const _keyIsInactivityTimeoutOn = 'isInactivityTimeoutOn';
  static const _keyInactivityTimeout = 'inactivityTimeout';
  static const _keyPreInactivityLogoutCounter = 'preInactivityLogoutCounter';
  static const _keyNoOfLogginAttemptAllowed = 'noOfLogginAttemptAllowed';
  static const _keyBruteforceLockOutTime = 'bruteforceLockOutTime';
  static const _keyIsColorful = 'isColorful';
  static const _keyLastBackupTime = 'lastBackupTime';
  static const _keyIsBackupOn = 'isBackupOn';
  static const _keyColorfulNotesColorIndex = 'colorfulNotesColorIndex';
  static const _keyIsGridView = 'isGridView';
  static const _keyIsNewFirst = 'isNewFirst';
  static const _keyIsFlagSecure = 'isFlagSecure';
  static const _keyBackupRedundancyCounter = 'backupRedundancyCounter';
  static const _keyMaxBackupRetryAttempts = 'maxBackupRetryAttempts';
  static const _keyAppVersionCode = 'appVersionCode';
  static const _keyIsBiometricAuthEnabled = 'isBiometricAuthEnabled';
  static const _keyBiometricAttemptAllTimeCount =
      'biometricAttemptAllTimeCount';
  static const _keyIsCompactPreview = 'isCompactPreview';
  static const _keyIsDimTheme = 'isDimTheme';
  static const _keyDarkThemeEnum = 'isDarkThemeEnum';
  static const _keyIsAutoRotate = 'isAutoRotate';
  static const _keyIsBackupNeeded = 'isBackupNeeded';
  static const _keyIsLocalDarkSwitchEnabled = 'isLocalDarkSwitchEnabled';
  static const _keyIsSystemDarkLightSwitchEnabled =
      'isSystemDarkLightSwitchEnabled';

  static Future init() async {
    _preferences = await SharedPreferences.getInstance();
    // 简化方案:清理旧版 passPhraseHash 残留 key
    // (开发阶段不做数据迁移,但残留 key 会引起歧义,这里清掉)
    await _preferences?.remove(_keyPassPhraseHash);
    // 启动时打印一份配置快照，便于对照用户反馈复现问题
    Log.settings.i('偏好设置已加载, 共 ${_preferences?.getKeys().length ?? 0} 个键');
    Log.settings.d('配置快照: 主题深色=$isThemeDark 系统跟随=$isSystemDarkLightSwitchEnabled '
        '网格视图=$isGridView 新笔记优先=$isNewFirst 紧凑预览=$isCompactPreview '
        '彩色笔记=$isColorful 自动旋转=$isAutoRotate 防截屏=$isFlagSecure');
    Log.settings.d('安全配置: 生物识别=$isBiometricAuthEnabled '
        '无操作锁定=$isInactivityTimeoutOn 锁定时长=${inactivityTimeout}s '
        '允许登录尝试=$noOfLogginAttemptAllowed 锁定时长=${bruteforceLockOutTime}s');
    Log.settings.d('备份配置: 自动备份=$isBackupOn 待备份=$isBackupNeeded '
        '上次备份=${lastBackupTime.isEmpty ? "从未" : lastBackupTime} '
        '最大重试=$maxBackupRetryAttempts');
  }

  static Future<void> reload() async {
    await _preferences?.reload();
    Log.settings.d('偏好设置已重新加载');
  }

  /// 统一的配置变更日志出口
  ///
  /// 只记录「非敏感」的开关与数值型偏好；密码 / 密钥类数据绝不进日志。
  /// [label] 中文可读名，[oldValue] 旧值（null 表示此前未设置），[newValue] 新值。
  /// 值未变化时降为 trace，避免重复渲染 UI 时刷屏。
  static void _logPrefChange(
    String label,
    Object? oldValue,
    Object? newValue, {
    bool important = true,
  }) {
    final from = oldValue?.toString() ?? '未设置';
    final to = newValue?.toString() ?? 'null';
    if (from == to) {
      Log.settings.t('设置未变化: $label = $to');
      return;
    }
    final msg = '设置变更: $label: $from → $to';
    important ? Log.settings.i(msg) : Log.settings.d(msg);
  }

  /// 清除 keyring 相关的 SharedPreferences key(忘记密码逃生通道使用)
  ///
  /// 与 NotesDatabase.deleteDbFile 配合使用:
  ///   - db 文件包含 sync_meta 表(vaultId/encryptedDataKey/salt 等)
  ///   - SharedPreferences 中 biometric 开关保留(用户偏好不变)
  ///   - passPhraseHash 已在 init() 清理,这里再清一次保险
  static Future<void> clearVaultRelatedKeys() async {
    // 逃生通道的一部分：清除保险库相关 key（不可逆），必须留痕
    Log.settings.w('清除保险库相关偏好键（忘记密码逃生通道）');
    await _preferences?.remove(_keyPassPhraseHash);
    // biometric 开关保留:用户偏好不变,只是 keyring 数据被清空
    // 其他 UI 偏好(gridView/sortOrder 等)也保留
  }

// appVersionCode controls the one time code execution on version change
  static int get appVersionCode =>
      _preferences?.getInt(_keyAppVersionCode) ?? 1;

  static Future<void> setAppVersionCodeToCurrent() async {
    final old = _preferences?.getInt(_keyAppVersionCode);
    await _preferences
        ?.setInt(_keyAppVersionCode, SafeNotesConfig.appVersionCode);
    _logPrefChange('已记录版本号', old, SafeNotesConfig.appVersionCode);
  }

  static int get colorfulNotesColorIndex =>
      _preferences?.getInt(_keyColorfulNotesColorIndex) ?? 0;

  static Future<void> setColorfulNotesColorIndex(int index) async {
    final old = _preferences?.getInt(_keyColorfulNotesColorIndex);
    await _preferences?.setInt(_keyColorfulNotesColorIndex, index);
    _logPrefChange('笔记配色索引', old, index);
  }

  static bool get isThemeDark {
    bool? isDark = _preferences?.getBool(_keyIsThemeDark);
    bool isSystemDark =
        WidgetsBinding.instance.platformDispatcher.platformBrightness ==
            Brightness.dark;

    if (isSystemDarkLightSwitchEnabled) {
      return isSystemDark;
    }
    if (isDark != null) return isDark;
    return WidgetsBinding.instance.platformDispatcher.platformBrightness ==
        Brightness.dark;
  }

  static Future<void> setIsThemeDark(bool flag) async {
    final old = _preferences?.getBool(_keyIsThemeDark);
    await _preferences?.setBool(_keyIsThemeDark, flag);
    _logPrefChange('深色主题', old, flag);
  }

  static int get backupRedundancyCounter =>
      _preferences?.getInt(_keyBackupRedundancyCounter) ?? 0;

  static Future<void> incrementBackupRedundancyCounter() async {
    final old = PreferencesStorage.backupRedundancyCounter;
    await _preferences?.setInt(_keyBackupRedundancyCounter, old + 1);
    // 备份文件名后缀计数，属内部细节，降为 debug
    _logPrefChange('备份冗余计数', old, old + 1, important: false);
  }

  static bool get isFlagSecure =>
      _preferences?.getBool(_keyIsFlagSecure) ?? true;

  static Future<void> setIsFlagSecure(bool flag) async {
    final old = _preferences?.getBool(_keyIsFlagSecure);
    await _preferences?.setBool(_keyIsFlagSecure, flag);
    _logPrefChange('安全显示（防截屏）', old, flag);
  }

  static bool get isGridView => _preferences?.getBool(_keyIsGridView) ?? true;

  static Future<void> setIsGridView(bool flag) async {
    final old = _preferences?.getBool(_keyIsGridView);
    await _preferences?.setBool(_keyIsGridView, flag);
    _logPrefChange('列表视图模式', old == null ? null : (old ? '网格' : '列表'),
        flag ? '网格' : '列表',
        important: false);
  }

  static bool get isNewFirst => _preferences?.getBool(_keyIsNewFirst) ?? true;

  static Future<void> setIsNewFirst(bool flag) async {
    final old = _preferences?.getBool(_keyIsNewFirst);
    await _preferences?.setBool(_keyIsNewFirst, flag);
    _logPrefChange('笔记排序', old == null ? null : (old ? '新→旧' : '旧→新'),
        flag ? '新→旧' : '旧→新',
        important: false);
  }

  static String get lastBackupTime =>
      _preferences?.getString(_keyLastBackupTime) ?? '';

  static Future<void> setLastBackupTime() async {
    final old = _preferences?.getString(_keyLastBackupTime);
    final now = DateTime.now().toIso8601String();
    await _preferences?.setString(_keyLastBackupTime, now);
    _logPrefChange('上次备份时间', old, now, important: false);
  }

  static bool get isBackupOn =>
      _preferences?.getBool(_keyIsBackupOn) ?? false; //true;

  static Future<void> setIsBackupOn(bool flag) async {
    final old = _preferences?.getBool(_keyIsBackupOn);
    await _preferences?.setBool(_keyIsBackupOn, flag);
    _logPrefChange('自动备份开关', old, flag);
  }

  static bool get isColorful => _preferences?.getBool(_keyIsColorful) ?? true;

  static Future<void> setIsColorful(bool flag) async {
    final old = _preferences?.getBool(_keyIsColorful);
    await _preferences?.setBool(_keyIsColorful, flag);
    _logPrefChange('彩色笔记', old, flag);
  }

  static Future<void> setKeyboardIncognito(bool flag) async {
    final old = _preferences?.getBool(_keyKeyboardIncognito);
    await _preferences?.setBool(_keyKeyboardIncognito, flag);
    _logPrefChange('键盘无痕模式', old, flag);
  }

  static bool get keyboardIncognito =>
      _preferences?.getBool(_keyKeyboardIncognito) ?? true;

  static int get noOfLogginAttemptAllowed {
    //default: 3 unsuccessful
    return _preferences?.getInt(_keyNoOfLogginAttemptAllowed) ?? 4;
  }

  static int get bruteforceLockOutTime {
    //default: 30 seconds
    return _preferences?.getInt(_keyBruteforceLockOutTime) ?? 30;
  }

  static bool get isInactivityTimeoutOn =>
      _preferences?.getBool(_keyIsInactivityTimeoutOn) ?? true;

  static Future<void> setIsInactivityTimeoutOn(bool flag) async {
    final old = _preferences?.getBool(_keyIsInactivityTimeoutOn);
    await _preferences?.setBool(_keyIsInactivityTimeoutOn, flag);
    _logPrefChange('无操作自动锁定', old, flag);
  }

  static int get inactivityTimeout {
    //default: 4 minutes

    List<int> choices = [30, 60, 120, 180, 300, 600, 900];
    var index = _preferences?.getInt(_keyInactivityTimeout);
    if (!(index != null && index >= 0 && index < choices.length)) {
      index = 4; // default
    }

    return choices[index];
  }

  static int get inactivityTimeoutIndex =>
      _preferences?.getInt(_keyInactivityTimeout) ?? 3;

  static Future<void> setInactivityTimeoutIndex({required int index}) async {
    final oldSeconds = inactivityTimeout;
    await _preferences?.setInt(_keyInactivityTimeout, index);
    // 记录实际秒数而非索引，日志才有可读性
    _logPrefChange('无操作锁定时长', '${oldSeconds}s', '${inactivityTimeout}s');
  }

//default: Same as inactivityTimeout
  static int get focusTimeout => PreferencesStorage.inactivityTimeout;
  // static int get focusTimeout => _preferences?.getInt(_keyFocusTimeout) ?? 60;

  //default: 50
  static int get maxBackupRetryAttempts =>
      _preferences?.getInt(_keyMaxBackupRetryAttempts) ?? 50;

  //for logout popup alert. default: 15 seconds
  static int get preInactivityLogoutCounter =>
      _preferences?.getInt(_keyPreInactivityLogoutCounter) ?? 15;

  static bool get isBiometricAuthEnabled =>
      _preferences?.getBool(_keyIsBiometricAuthEnabled) ?? false;
  static Future<void> setIsBiometricAuthEnabled(bool flag) async {
    final old = _preferences?.getBool(_keyIsBiometricAuthEnabled);
    await _preferences?.setBool(_keyIsBiometricAuthEnabled, flag);
    // 认证方式变更属安全敏感设置，固定 info 级
    _logPrefChange('生物识别登录', old, flag);
  }

  static int get biometricAttemptAllTimeCount =>
      _preferences?.getInt(_keyBiometricAttemptAllTimeCount) ?? 0;

  static Future<void> incrementBiometricAttemptAllTimeCount() async {
    final old = PreferencesStorage.biometricAttemptAllTimeCount;
    await _preferences?.setInt(_keyBiometricAttemptAllTimeCount, old + 1);
    _logPrefChange('生物识别累计次数', old, old + 1, important: false);
  }

  static bool get isCompactPreview =>
      _preferences?.getBool(_keyIsCompactPreview) ?? false;
  static Future<void> setIsCompactPreview(bool flag) async {
    final old = _preferences?.getBool(_keyIsCompactPreview);
    await _preferences?.setBool(_keyIsCompactPreview, flag);
    _logPrefChange('紧凑预览', old, flag, important: false);
  }

  static bool get isDimTheme => _preferences?.getBool(_keyIsDimTheme) ?? true;
  static Future<void> setIsDimTheme(bool flag) async {
    final old = _preferences?.getBool(_keyIsDimTheme);
    await _preferences?.setBool(_keyIsDimTheme, flag);
    _logPrefChange('暗淡主题', old, flag);
  }

  static bool get isLocalDarkSwitchEnabled =>
      _preferences?.getBool(_keyIsLocalDarkSwitchEnabled) ?? false;

  static Future<void> setLocalDarkSwitchEnabled(bool flag) async {
    final old = _preferences?.getBool(_keyIsLocalDarkSwitchEnabled);
    await _preferences?.setBool(_keyIsLocalDarkSwitchEnabled, flag);
    _logPrefChange('应用内深色开关', old, flag);
  }

  static bool get isSystemDarkLightSwitchEnabled =>
      _preferences?.getBool(_keyIsSystemDarkLightSwitchEnabled) ?? true;

  static Future<void> setSystemDarkLightSwitchEnabled(bool flag) async {
    final old = _preferences?.getBool(_keyIsSystemDarkLightSwitchEnabled);
    await _preferences?.setBool(_keyIsSystemDarkLightSwitchEnabled, flag);
    _logPrefChange('跟随系统深浅色', old, flag);
  }

  //Default is Dim. i.e enumIndex = 0
  static int get darkThemeEnum => _preferences?.getInt(_keyDarkThemeEnum) ?? 0;
  static Future<void> setDarkThemeEnum({required int index}) async {
    final old = _preferences?.getInt(_keyDarkThemeEnum);
    await _preferences?.setInt(_keyDarkThemeEnum, index);
    _logPrefChange('深色主题风格索引', old, index);
  }

  static bool get isAutoRotate =>
      _preferences?.getBool(_keyIsAutoRotate) ?? false;

  static Future<void> setIsAutoRotate(bool flag) async {
    final old = _preferences?.getBool(_keyIsAutoRotate);
    await _preferences?.setBool(_keyIsAutoRotate, flag);
    _logPrefChange('屏幕自动旋转', old, flag);
  }

  static int get noOfLoginsBeforeNextPassphraseRememberChallenge => 5;

  static bool get isBackupNeeded =>
      _preferences?.getBool(_keyIsBackupNeeded) ?? true;
  static Future<void> setIsBackupNeeded(bool flag) async {
    final old = _preferences?.getBool(_keyIsBackupNeeded);
    await _preferences?.setBool(_keyIsBackupNeeded, flag);
    _logPrefChange('待备份标记', old, flag, important: false);
  }
}

class PhraseHandler {
  static String _passphrase = '';

  /// 注入会话密码（内存态）
  ///
  /// 隐私红线：**只记录状态与长度，绝不记录密码本身**。
  static void initPass(String pass) {
    final wasSet = _passphrase.isNotEmpty;
    _passphrase = pass;
    Log.auth.i('会话密码已注入内存 (len=${pass.length}, '
        '此前${wasSet ? "已有" : "为空"})');
  }

  static void destroy() {
    final wasSet = _passphrase.isNotEmpty;
    _passphrase = '';
    if (wasSet) Log.auth.i('会话密码已从内存清除');
  }

  static String get getPass => _passphrase;
}

class ImportEncryptionControl {
  static bool isImportEncrypted = true;
  static bool getIsImportEncrypted() => isImportEncrypted;
  static void setIsImportEncrypted(bool flag) {
    if (isImportEncrypted != flag) {
      Log.backup.d('导入加密标记: $isImportEncrypted → $flag');
    }
    isImportEncrypted = flag;
  }
}

class ImportPassPhraseHandler {
  static String? importPassPhrase;
  static String? importPassPhraseHash;
  static String? getImportPassPhrase() => importPassPhrase;
  static void setImportPassPhrase(String imPhrase) => importPassPhrase = imPhrase;

  static String? getImportPassPhraseHash() => importPassPhraseHash;
  static void setImportPassPhraseHash(String? imPhraseHash) =>
      importPassPhraseHash = imPhraseHash;
}

class SafeNotesConfig {
  static const String _appVersion = '2.3.0';
  static const int _appVersionCode = 10;
  static const String _appName = 'Safe Notes';
  static const String _appSlogan = 'Encrypted note manager!';
  static const String _appLogoPath = 'assets/images/splash_500.png';
  static const String _appLogoAsProfilePath = 'assets/images/splash.png';
  static const String _exportFileNamePrefix = 'safenotes_';
  static const String _allowedFileExtensionsForImport = 'json';
  static const String _exportFileNameExtension = '.json';
  static const String _backupExtension = '.json';
  static const String _backupFileNamePrefix = 'safenotes_backup';
  static const String _githubUrl = 'https://github.com/keshav-space/safenotes';
  static const String _faqsUrl = 'https://safenotes.dev/faqs.html';
  static const String _iosBackupDirectoryIndicativePath =
      '/On My iPhone/Safe Notes/';
  static const String _androidDownloadDirectory =
      '/storage/emulated/0/Download/';
  static const String _androidBackupDirectory =
      '/storage/emulated/0/Download/Safe Notes/';
  static const String _mailToForFeedback =
      'mailto:contact@safenotes.dev?subject=Help and Feedback';
  static const String _sourceCodeUrl =
      'https://github.com/keshav-space/safenotes';
  static const String _bugReportUrl =
      'mailto:contact@safenotes.dev?subject=Bug Report';
  static const String _openSourceLicense =
      'https://github.com/keshav-space/safenotes/blob/main/LICENSE';
  static const String _playStorUrl =
      'https://play.google.com/store/apps/details?id=com.trisven.safenotes';

  static final Map<String, Locale> _locales = {
    "Čeština": const Locale('cs'),
    "简体中文": const Locale('zh', 'CN'),
    "Deutsch": const Locale('de'),
    "English": const Locale('en', 'US'),
    "Español": const Locale('es'),
    "Français": const Locale('fr'),
    "Indonesia": const Locale('id'),
    "Norsk": const Locale('nb', 'NO'),
    "Polski": const Locale('pl'),
    "Português do Brasil": const Locale('pt', 'BR'),
    "Português": const Locale('pt'),
    "Русский": const Locale('ru'),
    "Türk": const Locale('tr'),
    "Yкраїнська": const Locale('uk'),
  };

  // set timeago local for all supported language
  static void setTimeagoLocale() {
    timeago.setLocaleMessages('zh_CN', timeago.ZhCnMessages());
    timeago.setLocaleMessages('cs', timeago.CsMessages());
    timeago.setLocaleMessages('en', timeago.EnMessages());
    timeago.setLocaleMessages('fr_short', timeago.FrMessages());
    timeago.setLocaleMessages('de', timeago.DeMessages());
    timeago.setLocaleMessages('id', timeago.IdMessages());
    timeago.setLocaleMessages('nb_NO', timeago.NbNoMessages());
    timeago.setLocaleMessages('pl', timeago.PlMessages());
    timeago.setLocaleMessages('pt', timeago.PtBrMessages());
    timeago.setLocaleMessages('pt_BR', timeago.PtBrMessages());
    timeago.setLocaleMessages('ru', timeago.RuMessages());
    timeago.setLocaleMessages('es', timeago.EsMessages());
    timeago.setLocaleMessages('tr', timeago.TrMessages());
    timeago.setLocaleMessages('uk', timeago.UkMessages());
  }

  static String get appName => _appName;
  static String get appVersion => _appVersion;
  static int get appVersionCode => _appVersionCode;
  static String get logoAsProfile => _appLogoAsProfilePath;
  static String get bugReportUrl => _bugReportUrl;
  static String get mailToForFeedback => _mailToForFeedback;
  static String get sourceCodeUrl => _sourceCodeUrl;
  static String get openSourceLicense => _openSourceLicense;
  static String get playStoreUrl => _playStorUrl;
  static String get githubUrl => _githubUrl;
  static String get appSlogan => _appSlogan;
  static String get appLogoPath => _appLogoPath;
  static String get exportFileExtension => _exportFileNameExtension;
  static String get importFileExtension => _allowedFileExtensionsForImport;
  static String get faqsUrl => _faqsUrl;
  static String get androidDownloadDirectory => _androidDownloadDirectory;
  static String get androidBackupDirectory => _androidBackupDirectory;
  static String get iosBackupDirectoryIndicativePath =>
      _iosBackupDirectoryIndicativePath;
  static Map<String, Locale> get allLocale => _locales;
  static List<Locale> get localesValues => _locales.values.toList();
  static List<String> get localesKeys => _locales.keys.toList();
  static List<LanguageItem> get languageItems {
    List<LanguageItem> items = [];
    for (var element in localesKeys) {
      items.add(LanguageItem(prefix: element, helper: null));
    }
    return items;
  }

  static Map<String, String> get mapLocaleName {
    //{'en_US':'English'}
    Map<String, String> mapLocaleName = {};
    _locales.forEach((key, value) {
      mapLocaleName[value.toString()] = key;
    });
    return mapLocaleName;
  }

  static String get backupFileName {
    String redundancyCounter =
        PreferencesStorage.backupRedundancyCounter.toString();
    if (redundancyCounter == '0') {
      return '$_backupFileNamePrefix$_backupExtension';
    }
    return '$_backupFileNamePrefix$redundancyCounter$_backupExtension';
  }

  static String get exportFileName {
    var dateNow = DateTime.now()
        .toString()
        .replaceAll("-", "")
        .replaceAll(" ", "_")
        .replaceAll(":", "")
        .substring(0, 15);
    return (_exportFileNamePrefix + dateNow + _exportFileNameExtension);
  }
}

class LanguageItem {
  final String prefix;
  final String? helper;
  const LanguageItem({required this.prefix, this.helper});
}
