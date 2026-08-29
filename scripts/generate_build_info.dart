/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

// 生成 lib/generated/build_info.g.dart —— 在构建期把 Git 提交信息与构建时间注入到应用。
//
// 产出内容包含：
//   - 版本号与构建号（解析自 pubspec.yaml 的 version: x.y.z+n）
//   - Git 完整/短提交哈希、分支名、describe 标签、提交总数、工作区是否脏
//   - UTC 构建时间戳（ISO 8601）与本地可读时间
//
// 设计要点：
//   - 仅使用 Dart 标准库（dart:io），跨平台无需额外依赖；
//     运行方式：dart run scripts/generate_build_info.dart
//   - 内容未变化时不写文件，避免无谓的重新编译。
//   - git 不可用时（如非仓库 / CI 未拉取历史）优雅降级为 "unknown"，不阻断构建。
//   - build_info 每次构建都会变化（时间戳），不需入库，因此输出到 lib/generated/
//     （该目录被 .gitignore 忽略，不入库）。
import 'dart:io';

// 脚本位于 <root>/scripts/，项目根目录 = 脚本所在目录的父目录
// （不依赖运行时的当前目录，任何 cwd 下执行都能正确定位）。
final Directory root = File(Platform.script.toFilePath()).parent.parent;
final File pubspec = File('${root.path}/pubspec.yaml');
final File out = File('${root.path}/lib/generated/build_info.g.dart');

final RegExp versionRe = RegExp(
  r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+(\d+)',
  multiLine: true,
);
final RegExp versionNoBuildRe = RegExp(
  r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)',
  multiLine: true,
);

/// 执行 git 子命令，成功返回 strip 后的 stdout，失败返回 null（不抛异常）。
String? runGit(List<String> args) {
  try {
    final proc = Process.runSync('git', args, workingDirectory: root.path);
    if (proc.exitCode == 0) {
      return (proc.stdout as String).trim();
    }
  } catch (_) {
    // git 不存在 / 非仓库等：返回 null 走降级路径。
  }
  return null;
}

/// 从 pubspec.yaml 解析 version: x.y.z+n，返回 (版本名, 构建号)。
(String, int) parseVersion() {
  final text = pubspec.readAsStringSync();
  final m = versionRe.firstMatch(text);
  if (m != null) {
    return (m.group(1)!, int.parse(m.group(2)!));
  }
  // 兜底：只有版本名没有构建号
  final m2 = versionNoBuildRe.firstMatch(text);
  if (m2 != null) {
    return (m2.group(1)!, 0);
  }
  return ('0.0.0', 0);
}

/// 收集 Git 仓库信息，不可用时给出安全的降级值。
Map<String, String> collectGitInfo() {
  final gitHash = runGit(['rev-parse', 'HEAD']) ?? 'unknown';
  var gitShort = runGit(['rev-parse', '--short', 'HEAD']);
  gitShort ??= gitHash != 'unknown' && gitHash.length >= 7
      ? gitHash.substring(0, 7)
      : 'unknown';
  final branch = runGit(['rev-parse', '--abbrev-ref', 'HEAD']) ?? 'unknown';
  // --always 保证在无 tag 时也返回 commit 哈希；不含 --dirty，脏标记单独计算
  final tag = runGit(['describe', '--tags', '--always']) ?? '';
  final count = runGit(['rev-list', '--count', 'HEAD']) ?? '0';
  // 工作区是否有未提交改动（脏）
  final status = runGit(['status', '--porcelain']);
  final dirty = (status != null && status.isNotEmpty) ? 'true' : 'false';
  return {
    'git_hash': gitHash,
    'git_short': gitShort,
    'branch': branch,
    'tag': tag,
    'count': count,
    'dirty': dirty,
  };
}

String buildDartSource(
  String version,
  int buildNumber,
  Map<String, String> git,
  String buildDateUtc,
  String buildDateReadable,
) {
  final versionString = '$version (build $buildNumber)';
  return '''
// GENERATED FILE - DO NOT EDIT MANUALLY.
// 由 scripts/generate_build_info.dart 在构建期生成：
// 注入 Git 提交信息与构建时间，供启动日志 / 关于页展示。
//
// 如需更新，请运行 `dart run scripts/generate_build_info.dart`（或 just gen-build-info）。

/// 构建期注入的版本与构建元数据（Git 提交 + 构建时间）。
///
/// 所有字段均为编译期常量，读取零开销；值为构建那一刻的快照。
class BuildInfo {
  const BuildInfo._();

  /// 应用版本名（来自 pubspec.yaml，例如 "2.3.0"）
  static const String version = '$version';

  /// 构建号 / versionCode（来自 pubspec.yaml 的 +n，例如 10）
  static const int buildNumber = $buildNumber;

  /// 版本名 + 构建号的人类可读组合（例如 "2.3.0 (build 10)"）
  static const String versionString = '$versionString';

  /// Git 完整提交哈希（40 位），非 git 仓库时为 "unknown"
  static const String gitHash = '${git['git_hash']}';

  /// Git 短提交哈希（7 位）
  static const String gitHashShort = '${git['git_short']}';

  /// 当前分支名
  static const String gitBranch = '${git['branch']}';

  /// git describe 结果（最近标签 + 偏移，无标签时为哈希）
  static const String gitTag = '${git['tag']}';

  /// 自首个提交至今的提交总数（可用于内部版本标识）
  static const String gitCommitCount = '${git['count']}';

  /// 构建时工作区是否存在未提交改动
  static const bool gitDirty = ${git['dirty']};

  /// UTC 构建时间戳（ISO 8601，例如 "2026-08-02T12:20:48Z"）
  static const String buildDate = '$buildDateUtc';

  /// 本地可读构建时间（例如 "2026-08-02 20:20:48"）
  static const String buildDateReadable = '$buildDateReadable';

  /// 单行版本详情，供启动日志直接打印
  static String get summary =>
      '\$versionString '
      '| git \$gitHashShort\${gitDirty ? " (dirty)" : ""} @ \$gitBranch '
      '| built \$buildDateReadable';

  /// 多行版本详情，供「关于 / 调试」面板展示
  static String get detail =>
      """
version      : \$versionString
git commit   : \$gitHash
git short    : \$gitHashShort
branch       : \$gitBranch
tag          : \${gitTag.isEmpty ? "(none)" : gitTag}
commit count : \$gitCommitCount
working tree : \${gitDirty ? "dirty" : "clean"}
build (UTC)  : \$buildDate
build (local): \$buildDateReadable
""";
}
''';
}

Future<int> main() async {
  final (version, buildNumber) = parseVersion();
  final git = collectGitInfo();

  final nowUtc = DateTime.now().toUtc();
  final buildDateUtc = '${nowUtc.toIso8601String().split('.').first}Z';
  final nowLocal = DateTime.now();
  final buildDateReadable =
      '${nowLocal.year.toString().padLeft(4, '0')}-'
      '${nowLocal.month.toString().padLeft(2, '0')}-'
      '${nowLocal.day.toString().padLeft(2, '0')} '
      '${nowLocal.hour.toString().padLeft(2, '0')}:'
      '${nowLocal.minute.toString().padLeft(2, '0')}:'
      '${nowLocal.second.toString().padLeft(2, '0')}';

  final source = buildDartSource(
    version,
    buildNumber,
    git,
    buildDateUtc,
    buildDateReadable,
  );

  if (await out.exists()) {
    final existing = await out.readAsString();
    if (existing == source) {
      stdout.writeln('[build_info] 内容未变化，跳过写入');
    } else {
      await out.writeAsString(source);
      stdout.writeln('[build_info] 已生成 ${out.path}');
    }
  } else {
    await out.writeAsString(source);
    stdout.writeln('[build_info] 已生成 ${out.path}');
  }

  stdout.writeln(
    '[build_info] version=$version build=$buildNumber '
    'git=${git['git_short']} dirty=${git['dirty']} '
    'branch=${git['branch']}',
  );
  return 0;
}
