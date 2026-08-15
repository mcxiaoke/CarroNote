// 回收站页面（DeletedNotesPage）测试
//
// 验证 widget 测试可测性改造的成果：通过 withProviders + FakeNotesRepository
// 注入内存 fake，无需真实 SQLite / Keyring / 加密 / 平台通道。
// 这是文档 §8 的验收场景之一——「一个 widget 的测试只提供它真正用到的 fake」。

// Flutter imports:
import 'package:flutter/services.dart';

// Package imports:
import 'package:core/core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

// Project imports:
import 'package:safenotes/data/note_repository.dart';
import 'package:safenotes/views/deleted_notes.dart';

import 'support/fake_repositories.dart';
import 'support/harness.dart';

const _titleBarChannel = MethodChannel('safenotes/window_title_bar');

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    // ThemeProvider 构造时会同步 Windows 标题栏主题（fire-and-forget），
    // 未 mock 该通道会抛 MissingPluginException。
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_titleBarChannel, (call) async => null);
  });

  testWidgets('回收站空态：无已删除笔记', (WidgetTester tester) async {
    await tester.pumpWidget(withProviders(const DeletedNotesPage()));
    await tester.pumpAndSettle();

    expect(find.text('No deleted notes'), findsOneWidget);
  });

  testWidgets('回收站渲染已删除笔记（Fake 注入）', (WidgetTester tester) async {
    final repo = FakeNotesRepository(
      seedNotes: [
        SafeNote.create(title: 'note A', description: 'desc A')
            .copyWith(deleted: true),
      ],
    );

    await tester.pumpWidget(
      withProviders(
        const DeletedNotesPage(),
        overrides: [
          ChangeNotifierProvider<NotesRepository>.value(value: repo),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('note A'), findsOneWidget);
    expect(find.text('No deleted notes'), findsNothing);
  });
}
