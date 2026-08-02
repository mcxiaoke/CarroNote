// GENERATED FILE - DO NOT EDIT MANUALLY.
// 由 scripts/generate_build_info.py 在构建期生成：
// 注入 Git 提交信息与构建时间，供启动日志 / 关于页展示。
//
// 如需更新，请运行 `make gen-build-info` 或 `python scripts/generate_build_info.py`。

/// 构建期注入的版本与构建元数据（Git 提交 + 构建时间）。
///
/// 所有字段均为编译期常量，读取零开销；值为构建那一刻的快照。
class BuildInfo {
  const BuildInfo._();

  /// 应用版本名（来自 pubspec.yaml，例如 "2.3.0"）
  static const String version = '2.3.0';

  /// 构建号 / versionCode（来自 pubspec.yaml 的 +n，例如 10）
  static const int buildNumber = 10;

  /// 版本名 + 构建号的人类可读组合（例如 "2.3.0 (build 10)"）
  static const String versionString = '2.3.0 (build 10)';

  /// Git 完整提交哈希（40 位），非 git 仓库时为 "unknown"
  static const String gitHash = '0a4d888c82a636d3394d6b6c939c61e2adfe4b7d';

  /// Git 短提交哈希（7 位）
  static const String gitHashShort = '0a4d888';

  /// 当前分支名
  static const String gitBranch = 'sync-refact-dev';

  /// git describe 结果（最近标签 + 偏移，无标签时为哈希）
  static const String gitTag = 'v2.3.0-188-g0a4d888';

  /// 自首个提交至今的提交总数（可用于内部版本标识）
  static const String gitCommitCount = '608';

  /// 构建时工作区是否存在未提交改动
  static const bool gitDirty = true;

  /// UTC 构建时间戳（ISO 8601，例如 "2026-08-02T12:20:48Z"）
  static const String buildDate = '2026-08-02T06:44:03Z';

  /// 本地可读构建时间（例如 "2026-08-02 20:20:48"）
  static const String buildDateReadable = '2026-08-02 14:44:03';

  /// 单行版本详情，供启动日志直接打印
  static String get summary => '$versionString '
      '| git $gitHashShort${gitDirty ? " (dirty)" : ""} @ $gitBranch '
      '| built $buildDateReadable';

  /// 多行版本详情，供「关于 / 调试」面板展示
  static String get detail => '''
version      : $versionString
git commit   : $gitHash
git short    : $gitHashShort
branch       : $gitBranch
tag          : ${gitTag.isEmpty ? "(none)" : gitTag}
commit count : $gitCommitCount
working tree : ${gitDirty ? "dirty" : "clean"}
build (UTC)  : $buildDate
build (local): $buildDateReadable
''';
}
