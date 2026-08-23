/*
 * Copyright (C) mcxiaoke 2026 - All Rights Reserved.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 * You may use, distribute and modify this code under the
 * terms of the GPL-3.0+ license.
 */

import 'package:flutter_test/flutter_test.dart';

import 'package:core/core.dart';
import 'package:safenotes/utils/note_diff.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('note_diff computeDiff', () {
    test('相同文本返回单个 equal 片段', () {
      final segments = computeDiff('hello world', 'hello world');
      expect(segments.length, 1);
      expect(segments.first.type, DiffSegmentType.equal);
      expect(segments.first.text, 'hello world');
    });

    test('纯新增返回单个 insertion 片段', () {
      final segments = computeDiff('', 'new content');
      expect(segments.length, 1);
      expect(segments.first.type, DiffSegmentType.insertion);
      expect(segments.first.text, 'new content');
    });

    test('纯删除返回单个 deletion 片段', () {
      final segments = computeDiff('deleted content', '');
      expect(segments.length, 1);
      expect(segments.first.type, DiffSegmentType.deletion);
      expect(segments.first.text, 'deleted content');
    });

    test('两端均为空串返回空列表', () {
      final segments = computeDiff('', '');
      expect(segments, isEmpty);
    });

    test('中文与标点混合编辑计算正确', () {
      final segments = computeDiff('这是一个安全笔记', '这是一个极度安全的加密笔记！');
      expect(segments.any((s) => s.type == DiffSegmentType.equal), isTrue);
      expect(segments.any((s) => s.type == DiffSegmentType.insertion), isTrue);

      final reconstructedTarget = segments
          .where((s) => s.type != DiffSegmentType.deletion)
          .map((s) => s.text)
          .join();
      expect(reconstructedTarget, '这是一个极度安全的加密笔记！');

      final reconstructedBase = segments
          .where((s) => s.type != DiffSegmentType.insertion)
          .map((s) => s.text)
          .join();
      expect(reconstructedBase, '这是一个安全笔记');
    });
  });

  group('note_diff computeNoteDiff', () {
    final baseVersion = NoteVersion(
      id: 1,
      noteUuid: 'note-uuid-1',
      title: '旧标题',
      description: '旧正文',
      contentHash: 'hash1',
      savedAt: 1000,
    );

    test('标题与正文均未修改时 hasDifference 为 false', () {
      final current = SafeNote(
        uuid: 'note-uuid-1',
        title: '旧标题',
        description: '旧正文',
        contentHash: 'hash1',
        createdTime: DateTime.fromMillisecondsSinceEpoch(1000),
        updatedAt: 1000,
      );

      final result = computeNoteDiff(current, baseVersion);
      expect(result.hasDifference, isFalse);
      expect(
        result.titleDiff.every((s) => s.type == DiffSegmentType.equal),
        isTrue,
      );
      expect(
        result.descriptionDiff.every((s) => s.type == DiffSegmentType.equal),
        isTrue,
      );
    });

    test('仅修改标题时 hasDifference 为 true', () {
      final current = SafeNote(
        uuid: 'note-uuid-1',
        title: '新标题',
        description: '旧正文',
        contentHash: 'hash2',
        createdTime: DateTime.fromMillisecondsSinceEpoch(1000),
        updatedAt: 2000,
      );

      final result = computeNoteDiff(current, baseVersion);
      expect(result.hasDifference, isTrue);
      expect(
        result.titleDiff.any((s) => s.type != DiffSegmentType.equal),
        isTrue,
      );
      expect(
        result.descriptionDiff.every((s) => s.type == DiffSegmentType.equal),
        isTrue,
      );
    });

    test('仅修改正文时 hasDifference 为 true', () {
      final current = SafeNote(
        uuid: 'note-uuid-1',
        title: '旧标题',
        description: '新正文内容',
        contentHash: 'hash3',
        createdTime: DateTime.fromMillisecondsSinceEpoch(1000),
        updatedAt: 2000,
      );

      final result = computeNoteDiff(current, baseVersion);
      expect(result.hasDifference, isTrue);
      expect(
        result.titleDiff.every((s) => s.type == DiffSegmentType.equal),
        isTrue,
      );
      expect(
        result.descriptionDiff.any((s) => s.type != DiffSegmentType.equal),
        isTrue,
      );
    });
  });

  group('note_diff computeNoteDiffAsync', () {
    test('普通长度（<50000 字符）走同步路径且结果正确', () async {
      final version = NoteVersion(
        id: 1,
        noteUuid: 'note-1',
        title: '短标题',
        description: '短正文',
        contentHash: 'h1',
        savedAt: 100,
      );
      final current = SafeNote(
        uuid: 'note-1',
        title: '短标题-修改',
        description: '短正文',
        contentHash: 'h2',
        createdTime: DateTime.fromMillisecondsSinceEpoch(100),
        updatedAt: 200,
      );

      final result = await computeNoteDiffAsync(current, version);
      expect(result.hasDifference, isTrue);
      expect(
        result.titleDiff.any((s) => s.type == DiffSegmentType.insertion),
        isTrue,
      );
    });

    test('超大文本（>50000 字符）在 Isolate 中正确计算且结果与同步一致', () async {
      final bigOldText = '${'A' * 26000}OLD${'B' * 5000}';
      final bigNewText = '${'A' * 26000}NEW${'B' * 5000}';

      final version = NoteVersion(
        id: 1,
        noteUuid: 'big-note',
        title: '大标题',
        description: bigOldText,
        contentHash: 'h-old',
        savedAt: 100,
      );
      final current = SafeNote(
        uuid: 'big-note',
        title: '大标题',
        description: bigNewText,
        contentHash: 'h-new',
        createdTime: DateTime.fromMillisecondsSinceEpoch(100),
        updatedAt: 200,
      );

      final asyncResult = await computeNoteDiffAsync(current, version);
      final syncResult = computeNoteDiff(current, version);

      expect(asyncResult.hasDifference, isTrue);
      expect(asyncResult.titleDiff.length, syncResult.titleDiff.length);
      expect(
        asyncResult.descriptionDiff.length,
        syncResult.descriptionDiff.length,
      );
      expect(
        asyncResult.descriptionDiff.map((s) => s.text).join(),
        syncResult.descriptionDiff.map((s) => s.text).join(),
      );
    });
  });
}
