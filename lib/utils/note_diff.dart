/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*/

library;

/// 笔记历史版本 Diff 工具
///
/// 设计文档：docs/feature-note-version-history-design.md §4
///
/// 使用 diff_match_patch（Google Myers 算法 Dart 移植）计算
/// 当前笔记内容与历史版本之间的字符级 diff。
///
/// Diff 方向：diff(version, current)
/// - insertion（绿色）：当前有、历史版本没有 → 此版本之后新增的内容
/// - deletion（红色）：历史版本有、当前没有 → 此版本之后被删除的内容
/// - equal：两者相同

import 'package:diff_match_patch/diff_match_patch.dart';
import 'package:flutter/foundation.dart';
import 'package:core/core.dart';

/// Diff 片段类型
enum DiffSegmentType { equal, insertion, deletion }

/// Diff 片段
class DiffSegment {
  final DiffSegmentType type;
  final String text;

  const DiffSegment(this.type, this.text);
}

/// 标题与正文分别 diff 的结果
class NoteDiffResult {
  final List<DiffSegment> titleDiff;
  final List<DiffSegment> descriptionDiff;
  final bool hasDifference;

  NoteDiffResult({
    required this.titleDiff,
    required this.descriptionDiff,
    required this.hasDifference,
  });
}

/// 计算两段文本的 diff
///
/// [base] 基准文本（历史版本内容）
/// [target] 目标文本（当前内容）
///
/// 返回 diff 片段列表：
/// - insertion（绿色）：target 有但 base 没有的内容 → 此版本之后新增
/// - deletion（红色）：base 有但 target 没有的内容 → 此版本之后被删除
/// - equal：两者相同的内容
List<DiffSegment> computeDiff(String base, String target) {
  final dmp = DiffMatchPatch();
  final diffs = dmp.diff(base, target);
  dmp.diffCleanupSemantic(diffs); // 语义清理，使 diff 更人类友好

  return diffs.map((d) {
    switch (d.operation) {
      case DIFF_EQUAL:
        return DiffSegment(DiffSegmentType.equal, d.text);
      case DIFF_INSERT:
        return DiffSegment(DiffSegmentType.insertion, d.text);
      case DIFF_DELETE:
        return DiffSegment(DiffSegmentType.deletion, d.text);
      default:
        return DiffSegment(DiffSegmentType.equal, d.text);
    }
  }).toList();
}

/// 计算当前笔记与历史版本之间的完整 diff（标题 + 正文分别 diff）
///
/// Diff 方向：diff(version, current) — 以历史版本为 base、当前内容为 target。
NoteDiffResult computeNoteDiff(SafeNote current, NoteVersion version) {
  final titleDiff = computeDiff(version.title, current.title);
  final descDiff = computeDiff(version.description, current.description);
  final hasDiff =
      titleDiff.any((s) => s.type != DiffSegmentType.equal) ||
      descDiff.any((s) => s.type != DiffSegmentType.equal);
  return NoteDiffResult(
    titleDiff: titleDiff,
    descriptionDiff: descDiff,
    hasDifference: hasDiff,
  );
}

/// Isolate 计算用的输入载体（compute 只支持顶层/静态函数）
class _DiffInput {
  final String currentTitle;
  final String currentDescription;
  final String versionTitle;
  final String versionDescription;

  const _DiffInput(
    this.currentTitle,
    this.currentDescription,
    this.versionTitle,
    this.versionDescription,
  );
}

/// Isolate 入口：在后台线程计算 diff
NoteDiffResult _computeNoteDiffIsolate(_DiffInput input) {
  final titleDiff = computeDiff(input.versionTitle, input.currentTitle);
  final descDiff = computeDiff(
    input.versionDescription,
    input.currentDescription,
  );
  final hasDiff =
      titleDiff.any((s) => s.type != DiffSegmentType.equal) ||
      descDiff.any((s) => s.type != DiffSegmentType.equal);
  return NoteDiffResult(
    titleDiff: titleDiff,
    descriptionDiff: descDiff,
    hasDifference: hasDiff,
  );
}

/// 异步计算 diff（大文本自动走 isolate）
///
/// 总字符数超过 50000 时在 isolate 中计算，避免阻塞 UI 线程。
/// 普通文本直接同步计算（< 10ms）。
Future<NoteDiffResult> computeNoteDiffAsync(
  SafeNote current,
  NoteVersion version,
) async {
  final totalSize =
      current.title.length +
      current.description.length +
      version.title.length +
      version.description.length;

  if (totalSize > 50000) {
    return compute(
      _computeNoteDiffIsolate,
      _DiffInput(
        current.title,
        current.description,
        version.title,
        version.description,
      ),
    );
  }
  return computeNoteDiff(current, version);
}
