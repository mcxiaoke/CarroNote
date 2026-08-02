#
# Copyright (C) Keshav Priyadarshi and others - All Rights Reserved.
#
# SPDX-License-Identifier: GPL-3.0-or-later
# You may use, distribute and modify this code under the
# terms of the GPL-3.0+ license.
#
# See https://safenotes.dev for support or download.
#

"""
生成 lib/utils/build_info.dart —— 在构建期把 Git 提交信息与构建时间注入到应用。

产出内容包含：
  - 版本号与构建号（解析自 pubspec.yaml 的 version: x.y.z+n）
  - Git 完整/短提交哈希、分支名、describe 标签、提交总数、工作区是否脏
  - UTC 构建时间戳（ISO 8601）与本地可读时间

设计要点：
  - 仅使用 Python 标准库，跨平台（Windows / macOS / Linux）无需额外依赖。
  - 内容未变化时不写文件，避免无谓的重新编译。
  - git 不可用时（如非仓库 / CI 未拉取历史）优雅降级为 "unknown"，不阻断构建。
"""

import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path

# 脚本位于 <root>/scripts/，项目根目录为其父目录
ROOT = Path(__file__).resolve().parent.parent
PUBSPEC = ROOT / "pubspec.yaml"
OUT = ROOT / "lib" / "utils" / "build_info.dart"


def run_git(args: list[str]) -> str | None:
    """执行 git 子命令，成功返回 strip 后的 stdout，失败返回 None（不抛异常）。"""
    try:
        proc = subprocess.run(
            ["git", *args],
            cwd=str(ROOT),
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
        if proc.returncode == 0:
            return proc.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return None


def parse_version() -> tuple[str, int]:
    """从 pubspec.yaml 解析 version: x.y.z+n，返回 (版本名, 构建号)。"""
    text = PUBSPEC.read_text(encoding="utf-8")
    m = re.search(r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+(\d+)", text, re.M)
    if m:
        return m.group(1), int(m.group(2))
    # 兜底：只有版本名没有构建号
    m2 = re.search(r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+)", text, re.M)
    if m2:
        return m2.group(1), 0
    return "0.0.0", 0


def collect_git_info() -> dict:
    """收集 Git 仓库信息，不可用时给出安全的降级值。"""
    git_hash = run_git(["rev-parse", "HEAD"]) or "unknown"
    git_short = run_git(["rev-parse", "--short", "HEAD"])
    if not git_short:
        git_short = git_hash[:7] if git_hash != "unknown" else "unknown"
    branch = run_git(["rev-parse", "--abbrev-ref", "HEAD"]) or "unknown"
    # --always 保证在无 tag 时也返回 commit 哈希；不含 --dirty，脏标记单独计算
    tag = run_git(["describe", "--tags", "--always"]) or ""
    count = run_git(["rev-list", "--count", "HEAD"]) or "0"
    # 工作区是否有未提交改动（脏）
    status = run_git(["status", "--porcelain"])
    dirty = "true" if status else "false"
    return {
        "git_hash": git_hash,
        "git_short": git_short,
        "branch": branch,
        "tag": tag,
        "count": count,
        "dirty": dirty,
    }


def build_dart_source(
    version: str,
    build_number: int,
    git: dict,
    build_date_utc: str,
    build_date_readable: str,
) -> str:
    """拼装 build_info.dart 的源码文本。"""
    version_string = f"{version} (build {build_number})"
    return f"""// GENERATED FILE - DO NOT EDIT MANUALLY.
// 由 scripts/generate_build_info.py 在构建期生成：
// 注入 Git 提交信息与构建时间，供启动日志 / 关于页展示。
//
// 如需更新，请运行 `make gen-build-info` 或 `python scripts/generate_build_info.py`。

/// 构建期注入的版本与构建元数据（Git 提交 + 构建时间）。
///
/// 所有字段均为编译期常量，读取零开销；值为构建那一刻的快照。
class BuildInfo {{
  const BuildInfo._();

  /// 应用版本名（来自 pubspec.yaml，例如 "2.3.0"）
  static const String version = '{version}';

  /// 构建号 / versionCode（来自 pubspec.yaml 的 +n，例如 10）
  static const int buildNumber = {build_number};

  /// 版本名 + 构建号的人类可读组合（例如 "2.3.0 (build 10)"）
  static const String versionString = '{version_string}';

  /// Git 完整提交哈希（40 位），非 git 仓库时为 "unknown"
  static const String gitHash = '{git['git_hash']}';

  /// Git 短提交哈希（7 位）
  static const String gitHashShort = '{git['git_short']}';

  /// 当前分支名
  static const String gitBranch = '{git['branch']}';

  /// git describe 结果（最近标签 + 偏移，无标签时为哈希）
  static const String gitTag = '{git['tag']}';

  /// 自首个提交至今的提交总数（可用于内部版本标识）
  static const String gitCommitCount = '{git['count']}';

  /// 构建时工作区是否存在未提交改动
  static const bool gitDirty = {git['dirty']};

  /// UTC 构建时间戳（ISO 8601，例如 "2026-08-02T12:20:48Z"）
  static const String buildDate = '{build_date_utc}';

  /// 本地可读构建时间（例如 "2026-08-02 20:20:48"）
  static const String buildDateReadable = '{build_date_readable}';

  /// 单行版本详情，供启动日志直接打印
  static String get summary =>
      '$versionString '
      '| git $gitHashShort${{gitDirty ? " (dirty)" : ""}} @ $gitBranch '
      '| built $buildDateReadable';

  /// 多行版本详情，供「关于 / 调试」面板展示
  static String get detail =>
      '''
version      : $versionString
git commit   : $gitHash
git short    : $gitHashShort
branch       : $gitBranch
tag          : ${{gitTag.isEmpty ? "(none)" : gitTag}}
commit count : $gitCommitCount
working tree : ${{gitDirty ? "dirty" : "clean"}}
build (UTC)  : $buildDate
build (local): $buildDateReadable
''';
}}
"""


def main() -> int:
    version, build_number = parse_version()
    git = collect_git_info()

    now_utc = datetime.now(timezone.utc)
    build_date_utc = now_utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    build_date_readable = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    source = build_dart_source(
        version, build_number, git, build_date_utc, build_date_readable
    )

    if OUT.exists() and OUT.read_text(encoding="utf-8") == source:
        print("[build_info] 内容未变化，跳过写入")
    else:
        OUT.write_text(source, encoding="utf-8")
        print(f"[build_info] 已生成 {OUT.relative_to(ROOT)}")

    print(
        f"[build_info] version={version} build={build_number} "
        f"git={git['git_short']} dirty={git['dirty']} "
        f"branch={git['branch']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
