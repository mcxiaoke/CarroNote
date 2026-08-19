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

import 'package:flutter/material.dart';

import 'package:core/core.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timeago/timeago.dart' as timeago;

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
  static const _keyIsPinAuthEnabled = 'isPinAuthEnabled';
  static const _keyPinLength = 'pinLength';
  static const _keyPinCharsetIndex = 'pinCharsetIndex';
  static const _keyPinFailedCount = 'pinFailedCount';
  static const _keyPinShuffleEnabled = 'pinShuffleEnabled';
  static const _keyIsCompactPreview = 'isCompactPreview';
  static const _keyIsMarkdownEnabled = 'isMarkdownEnabled';
  static const _keyEditorFontSizeIndex = 'editorFontSizeIndex';
  static const _keyIsRelativeTime = 'isRelativeTime';
  static const _keyIsSortByModified = 'isSortByModified';
  static const _keyIsDimTheme = 'isDimTheme';
  static const _keyDarkThemeEnum = 'isDarkThemeEnum';
  static const _keyIsAutoRotate = 'isAutoRotate';
  static const _keyIsBackupNeeded = 'isBackupNeeded';
  static const _keyBackupDirectory = 'backupDirectory';
  static const _keyIsLocalDarkSwitchEnabled = 'isLocalDarkSwitchEnabled';
  static const _keyIsSystemDarkLightSwitchEnabled =
      'isSystemDarkLightSwitchEnabled';
  static const _keyThemeGroupIndex = 'themeGroupIndex';
  static const _keyThemeColorIndex = 'themeColorIndex';
  static const _keyDevMode = 'devModeEnabled';
  static const _keyIsSidebarCollapsed = 'isSidebarCollapsed';

  static Future init() async {
    _preferences = await SharedPreferences.getInstance();
    // 简化方案:清理旧版 passPhraseHash 残留 key
    // (开发阶段不做数据迁移,但残留 key 会引起歧义,这里清掉)
    await _preferences?.remove(_keyPassPhraseHash);
    // 启动时打印一份配置快照，便于对照用户反馈复现问题
    Log.settings.i('偏好设置已加载, 共 ${_preferences?.getKeys().length ?? 0} 个键');
    Log.settings.d(
      '配置快照: 主题深色=$isThemeDark 系统跟随=$isSystemDarkLightSwitchEnabled '
      '主题色组=$themeGroupIndex 主题色=$themeColorIndex '
      '网格视图=$isGridView 新笔记优先=$isNewFirst 紧凑预览=$isCompactPreview '
      '彩色笔记=$isColorful 自动旋转=$isAutoRotate 防截屏=$isFlagSecure',
    );
    Log.settings.d(
      '安全配置: 生物识别=$isBiometricAuthEnabled '
      'PIN锁定=$isPinAuthEnabled PIN长度=$pinLength '
      '无操作锁定=$isInactivityTimeoutOn 锁定时长=${inactivityTimeout}s',
    );
    Log.settings.d(
      '备份配置: 自动备份=$isBackupOn 待备份=$isBackupNeeded '
      '上次备份=${lastBackupTime.isEmpty ? "从未" : lastBackupTime} '
      '最大重试=$maxBackupRetryAttempts',
    );
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
    await _preferences?.setInt(
      _keyAppVersionCode,
      SafeNotesConfig.appVersionCode,
    );
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

  // 主题色（seed 色库索引）：存 index 不存色值 —— 日后调整 hex 老用户自动生效；
  // 读取方用 clamp 防越界，版本升级改分组结构也不会崩。
  // 默认 0 / 0 = 第一组第一个颜色（「通用」组首色），该组为稳定默认组。
  static int get themeGroupIndex =>
      _preferences?.getInt(_keyThemeGroupIndex) ?? 0;

  static int get themeColorIndex =>
      _preferences?.getInt(_keyThemeColorIndex) ?? 0;

  static Future<void> setThemeGroupIndex(int index) async {
    final old = _preferences?.getInt(_keyThemeGroupIndex);
    await _preferences?.setInt(_keyThemeGroupIndex, index);
    _logPrefChange('主题色组索引', old, index);
  }

  static Future<void> setThemeColorIndex(int index) async {
    final old = _preferences?.getInt(_keyThemeColorIndex);
    await _preferences?.setInt(_keyThemeColorIndex, index);
    _logPrefChange('主题色索引', old, index);
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
    _logPrefChange(
      '列表视图模式',
      old == null ? null : (old ? '网格' : '列表'),
      flag ? '网格' : '列表',
      important: false,
    );
  }

  static bool get isNewFirst => _preferences?.getBool(_keyIsNewFirst) ?? true;

  static Future<void> setIsNewFirst(bool flag) async {
    final old = _preferences?.getBool(_keyIsNewFirst);
    await _preferences?.setBool(_keyIsNewFirst, flag);
    _logPrefChange(
      '笔记排序',
      old == null ? null : (old ? '新→旧' : '旧→新'),
      flag ? '新→旧' : '旧→新',
      important: false,
    );
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

  static bool get isInactivityTimeoutOn =>
      _preferences?.getBool(_keyIsInactivityTimeoutOn) ?? true;

  static Future<void> setIsInactivityTimeoutOn(bool flag) async {
    final old = _preferences?.getBool(_keyIsInactivityTimeoutOn);
    await _preferences?.setBool(_keyIsInactivityTimeoutOn, flag);
    _logPrefChange('无操作自动锁定', old, flag);
  }

  static int get inactivityTimeout {
    // 评审 #18：缺失/越界时回退缺省索引，与 inactivityTimeoutIndex 一致（3 分钟）
    final index = _inactivityTimeoutIndexOr(
      defaultIndex: kDefaultInactivityTimeoutIndex,
    );
    return kInactivityTimeoutChoicesSeconds[index];
  }

  static int get inactivityTimeoutIndex {
    // 评审 #18：缺省统一为 kDefaultInactivityTimeoutIndex（3 分钟 = 180s），
    // 不再与 inactivityTimeout 的越界回退值（原 300s）双默认值打架
    return _inactivityTimeoutIndexOr(
      defaultIndex: kDefaultInactivityTimeoutIndex,
    );
  }

  static Future<void> setInactivityTimeoutIndex({required int index}) async {
    final oldSeconds = inactivityTimeout;
    await _preferences?.setInt(_keyInactivityTimeout, index);
    // 记录实际秒数而非索引，日志才有可读性
    _logPrefChange('无操作锁定时长', '${oldSeconds}s', '${inactivityTimeout}s');
  }

  // 评审 #18：无操作锁定时长选项的唯一事实来源（秒），
  // 设置页与 inactivity_setting 页统一从这里取，消除双份魔法数组硬编码。
  static const List<int> kInactivityTimeoutChoicesSeconds = [
    30, // 30 秒
    60, // 1 分钟
    120, // 2 分钟
    180, // 3 分钟（缺省）
    300, // 5 分钟
    600, // 10 分钟
    900, // 15 分钟
  ];

  /// 缺省索引：3 分钟（=180s），与 UI 中「3 minutes (Default)」一致
  static const int kDefaultInactivityTimeoutIndex = 3;

  /// 读取持久化的索引，越界/缺失时回退 [defaultIndex]，索引始终合法
  static int _inactivityTimeoutIndexOr({required int defaultIndex}) {
    final index = _preferences?.getInt(_keyInactivityTimeout);
    if (index != null &&
        index >= 0 &&
        index < kInactivityTimeoutChoicesSeconds.length) {
      return index;
    }
    return defaultIndex;
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

  // ──────────────────────────────────────────────
  // PIN Lock(与生物识别平行的第二解锁方式)
  // 设计见 docs/pin-lock-design.md
  // ──────────────────────────────────────────────

  /// PIN 长度选项(默认 6 位,可选 4/6/8/10;10 位之上复杂度收益递减,
  /// PIN 是快捷解锁而非替代 master password,故封顶 10 位)
  static const List<int> pinLengthOptions = [4, 6, 8, 10];
  static const int kPinDefaultLength = 6;

  static bool get isPinAuthEnabled =>
      _preferences?.getBool(_keyIsPinAuthEnabled) ?? false;
  static Future<void> setIsPinAuthEnabled(bool flag) async {
    final old = _preferences?.getBool(_keyIsPinAuthEnabled);
    await _preferences?.setBool(_keyIsPinAuthEnabled, flag);
    _logPrefChange('PIN 锁定', old, flag);
  }

  static int get pinLength =>
      _preferences?.getInt(_keyPinLength) ?? kPinDefaultLength;
  static Future<void> setPinLength(int length) async {
    final old = _preferences?.getInt(_keyPinLength);
    await _preferences?.setInt(_keyPinLength, length);
    _logPrefChange('PIN 长度', old, length);
  }

  /// PIN 字符集索引(0=digits,1=alphanumeric 预留,见 PinCharset)
  static int get pinCharsetIndex =>
      _preferences?.getInt(_keyPinCharsetIndex) ?? 0;
  static Future<void> setPinCharsetIndex(int index) async {
    final old = _preferences?.getInt(_keyPinCharsetIndex);
    await _preferences?.setInt(_keyPinCharsetIndex, index);
    _logPrefChange('PIN 字符集', old, index);
  }

  /// PIN 随机键序(防肩窥):每次打开键盘打乱键位顺序;默认关闭。
  /// 仅影响显示层,不影响 PIN 判定(见 PinKeyboard.shuffle)。
  static bool get pinShuffleEnabled =>
      _preferences?.getBool(_keyPinShuffleEnabled) ?? false;
  static Future<void> setPinShuffleEnabled(bool flag) async {
    final old = _preferences?.getBool(_keyPinShuffleEnabled);
    await _preferences?.setBool(_keyPinShuffleEnabled, flag);
    _logPrefChange('PIN 随机键序', old, flag);
  }

  /// PIN 连续失败计数(成功清零;达到 PinAuth.kPinMaxFailedAttempts 后
  /// 自动关闭 PIN 回退密码登录)
  static int get pinFailedCount =>
      _preferences?.getInt(_keyPinFailedCount) ?? 0;
  static Future<void> setPinFailedCount(int count) async {
    final old = _preferences?.getInt(_keyPinFailedCount);
    await _preferences?.setInt(_keyPinFailedCount, count);
    _logPrefChange('PIN 失败计数', old, count, important: false);
  }

  /// 桌面侧栏收起(折叠成仅图标) — 仅桌面端使用,移动端忽略
  static bool get isSidebarCollapsed =>
      _preferences?.getBool(_keyIsSidebarCollapsed) ?? false;
  static Future<void> setIsSidebarCollapsed(bool flag) async {
    final old = _preferences?.getBool(_keyIsSidebarCollapsed);
    await _preferences?.setBool(_keyIsSidebarCollapsed, flag);
    _logPrefChange('桌面侧栏收起', old, flag, important: false);
  }

  static bool get isCompactPreview =>
      _preferences?.getBool(_keyIsCompactPreview) ?? false;
  static Future<void> setIsCompactPreview(bool flag) async {
    final old = _preferences?.getBool(_keyIsCompactPreview);
    await _preferences?.setBool(_keyIsCompactPreview, flag);
    _logPrefChange('紧凑预览', old, flag, important: false);
  }

  /// Markdown 渲染总开关（默认开启）。
  /// 关闭后，笔记预览以纯文本显示，不做 Markdown 解析。
  static bool get isMarkdownEnabled =>
      _preferences?.getBool(_keyIsMarkdownEnabled) ?? true;
  static Future<void> setIsMarkdownEnabled(bool flag) async {
    final old = _preferences?.getBool(_keyIsMarkdownEnabled);
    await _preferences?.setBool(_keyIsMarkdownEnabled, flag);
    _logPrefChange('Markdown 渲染', old, flag);
  }

  /// 编辑器（笔记编辑/预览页）字体大小档位索引。
  ///
  /// 存索引不存像素值：索引 → [EditorText.bodySizes] 映射，老用户升级改档位范围
  /// 也自动生效；默认值 1 = 标准（16px，等于现状）。
  /// 读取方用 [EditorText.index] 的夹紧逻辑防越界。
  static int get editorFontSizeIndex =>
      _preferences?.getInt(_keyEditorFontSizeIndex) ?? 1;

  static Future<void> setEditorFontSizeIndex(int index) async {
    final old = editorFontSizeIndex;
    await _preferences?.setInt(_keyEditorFontSizeIndex, index);
    _logPrefChange('编辑器字体大小', old, index);
  }

  static bool get isRelativeTime =>
      _preferences?.getBool(_keyIsRelativeTime) ?? false;

  static Future<void> setIsRelativeTime(bool flag) async {
    final old = _preferences?.getBool(_keyIsRelativeTime);
    await _preferences?.setBool(_keyIsRelativeTime, flag);
    _logPrefChange('卡片相对时间', old, flag, important: false);
  }

  static bool get isSortByModified =>
      _preferences?.getBool(_keyIsSortByModified) ?? true;

  static Future<void> setIsSortByModified(bool flag) async {
    final old = _preferences?.getBool(_keyIsSortByModified);
    await _preferences?.setBool(_keyIsSortByModified, flag);
    _logPrefChange(
      '排序依据',
      old == null ? null : (old ? '修改时间' : '创建时间'),
      flag ? '修改时间' : '创建时间',
      important: false,
    );
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

  /// dev 模式开关（非 debug 构建通过「设置页版本号连点 5 次」开启）。
  ///
  /// 开启后与 debug build 行为一致：显示调试面板入口、启动日志 Web 服务器、
  /// 日志级别恢复全量 trace。默认关闭。
  static bool get isDevMode => _preferences?.getBool(_keyDevMode) ?? false;
  static Future<void> setDevMode(bool flag) async {
    final old = _preferences?.getBool(_keyDevMode);
    await _preferences?.setBool(_keyDevMode, flag);
    _logPrefChange('开发模式', old, flag);
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

  /// 用户自定义备份目录（选择备份路径功能，移动+桌面通用，持久化记住）
  ///
  /// 空串表示「未设置」，此时备份落盘回退到平台默认目录
  /// （Android=Download/CarroNote，iOS/桌面=应用文档目录）。
  static String get backupDirectory =>
      _preferences?.getString(_keyBackupDirectory) ?? '';
  static Future<void> setBackupDirectory(String path) async {
    final old = backupDirectory;
    await _preferences?.setString(_keyBackupDirectory, path);
    _logPrefChange(
      '备份目录',
      old.isEmpty ? '未设置' : old,
      path.isEmpty ? '未设置' : path,
    );
  }

  /// 导出全部偏好设置（调试面板 / dashboard 下载用）。
  ///
  /// 仅含 UI/功能开关与数值，不含任何密钥类数据。值保持 SharedPreferences
  /// 原始类型（bool/int/String/double/`List<String>`）。
  static Map<String, Object?> dumpAll() {
    final prefs = _preferences;
    if (prefs == null) return const {};
    final out = <String, Object?>{};
    for (final key in prefs.getKeys()) {
      out[key] = prefs.get(key);
    }
    return out;
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
    Log.auth.i(
      '会话密码已注入内存 (len=${pass.length}, '
      '此前${wasSet ? "已有" : "为空"})',
    );
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
  static void setImportPassPhrase(String imPhrase) =>
      importPassPhrase = imPhrase;

  static String? getImportPassPhraseHash() => importPassPhraseHash;
  static void setImportPassPhraseHash(String? imPhraseHash) =>
      importPassPhraseHash = imPhraseHash;
}

class SafeNotesConfig {
  static const String _appVersion = '3.0.0';
  static const int _appVersionCode = 30000;
  // 应用显示名/标语改为跟随翻译资源（AppName / AppSlogan 键），
  static const String _appLogoPath = 'assets/images/icon-round-256.png';
  // 单色主题化图标：圆角方块用 currentColor，纸张为镂空（透出页面底色），
  // 运行期按 Theme 主色着色（见 login/about 页面 SvgPicture + ColorFilter）。
  static const String _appLogoSvgPath =
      'assets/images/icon-round-simple-chip.svg';
  static const String _exportFileNamePrefix = 'safenotes_';
  // 导入允许的扩展名：明文 .json + 加密 .snbak（见 docs/
  // backup-encryption-design-20260810.md §4，双扩展名均需文件选择器可识别）
  static const List<String> _allowedFileExtensionsForImport = ['json', 'snbak'];
  static const String _exportFileNameExtension = '.json';
  static const String _encryptedExportFileNameExtension = '.snbak';
  static const String _backupExtension = '.snbak';
  static const String _backupFileNamePrefix = 'secure_notes_backup';
  static const String _githubUrl = 'https://github.com/mcxiaoke/CarroNote';
  static const String _faqsUrl = 'https://github.com/mcxiaoke/CarroNote';
  static const String _iosBackupDirectoryIndicativePath =
      '/On My iPhone/SecureNotes/';
  static const String _androidDownloadDirectory =
      '/storage/emulated/0/Download/';
  static const String _androidBackupDirectory =
      '/storage/emulated/0/Download/CarroNote/';
  static const String _mailToForFeedback =
      'https://github.com/mcxiaoke/CarroNote/issues';
  static const String _sourceCodeUrl = 'https://github.com/mcxiaoke/CarroNote';
  static const String _bugReportUrl =
      'https://github.com/mcxiaoke/CarroNote/issues';
  static const String _openSourceLicense =
      'https://github.com/mcxiaoke/CarroNote/blob/main/files/LICENSE';
  static const String _playStorUrl = 'https://github.com/mcxiaoke/CarroNote';

  static final Map<String, Locale> _locales = {
    "Čeština": const Locale('cs'),
    "简体中文": const Locale('zh', 'CN'),
    "繁體中文": const Locale('zh', 'TW'),
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
    // 注意: timeago 3.7.1 仅提供 ZhCnMessages, 无 ZhTwMessages,
    // 故 zh_TW 未注册 timeago, 相对时间会回退为英文。如需繁体相对时间需升级 timeago 或自定义 Messages。
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

  /// 应用显示名：跟随系统语言（中文 萝笺 / 其它 CarroNote）；
  static String get appName {
    return 'AppName'.tr();
  }

  static String get appVersion => _appVersion;
  static int get appVersionCode => _appVersionCode;
  static String get bugReportUrl => _bugReportUrl;
  static String get mailToForFeedback => _mailToForFeedback;
  static String get sourceCodeUrl => _sourceCodeUrl;
  static String get openSourceLicense => _openSourceLicense;
  static String get playStoreUrl => _playStorUrl;
  static String get githubUrl => _githubUrl;

  /// 应用标语：跟随翻译（中文用中文文案，其它语言回落英文统一文案）。
  static String get appSlogan => 'AppSlogan'.tr();
  static String get appLogoPath => _appLogoPath;
  static String get appLogoSvgPath => _appLogoSvgPath;
  static String get exportFileExtension => _exportFileNameExtension;

  /// 导入允许的文件扩展名列表：明文 `.json` + 加密 `.snbak`
  static List<String> get importFileExtensions =>
      _allowedFileExtensionsForImport;
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
    String redundancyCounter = PreferencesStorage.backupRedundancyCounter
        .toString();
    if (redundancyCounter == '0') {
      return '$_backupFileNamePrefix$_backupExtension';
    }
    return '$_backupFileNamePrefix$redundancyCounter$_backupExtension';
  }

  /// 手动备份文件名：带时间戳（safenotes_backup_YYYYMMDD_HHMMSS.snbak），
  /// 避免同目录覆盖，用于「立即备份」等手动触发场景。
  static String get manualBackupFileName {
    var now = DateTime.now()
        .toString()
        .replaceAll('-', '')
        .replaceAll(' ', '_')
        .replaceAll(':', '')
        .substring(0, 15);
    return '${_backupFileNamePrefix}_$now$_backupExtension';
  }

  static String get exportFileName => exportFileNameFor(encrypted: false);

  /// 导出文件名：加密导出 `.snbak`，明文导出 `.json`
  ///
  /// 文件名带时间戳（safenotes_YYYYMMDD_HHMMSS），避免同目录覆盖。
  static String exportFileNameFor({required bool encrypted}) {
    var dateNow = DateTime.now()
        .toString()
        .replaceAll("-", "")
        .replaceAll(" ", "_")
        .replaceAll(":", "")
        .substring(0, 15);
    return (_exportFileNamePrefix +
        dateNow +
        (encrypted
            ? _encryptedExportFileNameExtension
            : _exportFileNameExtension));
  }
}

class LanguageItem {
  final String prefix;
  final String? helper;
  const LanguageItem({required this.prefix, this.helper});
}
