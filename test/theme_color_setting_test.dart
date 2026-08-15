// 主题颜色选择器（ThemeColorPicker）测试
//
// 设计原则：不硬编码具体的颜色名 / 色值（数据会变）。
// 目标色全部从 AppThemeSeeds 动态获取，断言聚焦行为：
//   - 进入页面选中当前已应用主题色（默认 0/0）
//   - 点击色块只是本地预览，不更新全局/持久化
//   - Apply 后才更新 ThemeProvider 并持久化（写入 FakePreferencesRepository）
//   - Apply 后重进页面，对应 item 保持选中态
//   - 切分组显示新组颜色
//
// 已迁移到 withProviders + FakePreferencesRepository：不再依赖
// SharedPreferences.setMockInitialValues / initTestEnv / wrapScreen。

// Flutter imports:
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Package imports:
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

// Project imports:
import 'package:safenotes/models/theme_seeds.g.dart';
import 'package:safenotes/views/settings/theme_color_setting.dart';

import 'support/fakes.dart';
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

  /// 主题色页内容较长（分组 tab + 网格 + Apply 按钮），测试视口调高，
  /// 保证底部 Apply 按钮可见并被构建。
  void useTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// 统计当前渲染的「选中勾」数量（LucideIcons.check）。
  int countSelected(WidgetTester tester) => find
      .byType(Icon)
      .evaluate()
      .where((e) => (e.widget as Icon).icon == LucideIcons.check)
      .length;

  /// 取某组的第 [i] 个颜色的英文显示名（用于点击色块；locale 为 en）。
  String colorNameEn(int g, int i) => AppThemeSeeds.itemByIndex(g, i).nameEn;

  testWidgets('窄屏（360x640）网格无 RenderFlex 溢出', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(withProviders(const ThemeColorPicker()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '3 列网格 + 固定高度在窄屏下不应溢出');
  });

  testWidgets('渲染全部分组 tab，进入页面选中当前已应用主题色', (WidgetTester tester) async {
    useTallViewport(tester);
    final fakePrefs = FakePreferencesRepository(
      themeGroupIndex: 0,
      themeColorIndex: 0,
    );
    await tester.pumpWidget(
      withProviders(
        const ThemeColorPicker(),
        preferences: fakePrefs,
      ),
    );
    await tester.pumpAndSettle();

    // 全部分组 tab 的名称（英文 locale 下用英文名）
    for (final group in AppThemeSeeds.groups) {
      expect(
        find.text(group.nameEn),
        findsWidgets,
        reason: '分组 ${group.nameEn} 的 tab 应存在',
      );
    }

    // 默认 0/0：持久化与当前主题色 == 数据第一项
    expect(fakePrefs.themeGroupIndex, 0);
    expect(fakePrefs.themeColorIndex, 0);

    // 进入页面应选中当前主题色（恰好 1 个选中勾）
    expect(countSelected(tester), 1, reason: '进入页面应选中当前已应用的主题色（0/0）');

    // 无改动时 Apply 应为禁用态（本地选中 == 全局已应用）
    final applyFinder = find.widgetWithText(ShadButton, 'Apply theme');
    expect(applyFinder, findsOneWidget, reason: '底部应有 Apply theme 按钮');
    final applyBtn = tester.widget<ShadButton>(applyFinder);
    expect(applyBtn.onPressed, isNull, reason: '未改动时 Apply 按钮应禁用');
  });

  testWidgets('点击色块仅预览，不更新持久化；点 Apply 才生效', (
    WidgetTester tester,
  ) async {
    useTallViewport(tester);
    final fakePrefs = FakePreferencesRepository(
      themeGroupIndex: 0,
      themeColorIndex: 0,
    );
    await tester.pumpWidget(
      withProviders(
        const ThemeColorPicker(),
        preferences: fakePrefs,
      ),
    );
    await tester.pumpAndSettle();

    // 组 0 的第 2 个颜色（i=1；不硬编码名字/色值，动态取）
    const targetIndex = 1;
    final targetColor = AppThemeSeeds.colorByIndex(0, targetIndex);

    await tester.tap(find.text(colorNameEn(0, targetIndex)));
    await tester.pumpAndSettle();

    // 点击色块：持久化不变（仅本地预览）
    expect(fakePrefs.themeColorIndex, 0, reason: '点击色块只是预览，不应立即持久化');

    // 改动后 Apply 变为可用
    final applyFinder = find.widgetWithText(ShadButton, 'Apply theme');
    final applyBtn = tester.widget<ShadButton>(applyFinder);
    expect(applyBtn.onPressed, isNotNull, reason: '选择颜色后 Apply 按钮应可用');

    // 点 Apply → 持久化到 FakePreferencesRepository
    await tester.tap(find.text('Apply theme'));
    await tester.pumpAndSettle();

    expect(
      fakePrefs.themeColorIndex,
      targetIndex,
      reason: 'Apply 后选择应持久化到偏好存储',
    );
    expect(
      AppThemeSeeds.colorByIndex(0, fakePrefs.themeColorIndex),
      targetColor,
      reason: 'Apply 后当前主题色应等于所选颜色',
    );
  });

  testWidgets('Apply 后重进页面，对应 item 保持选中态且主题色不变', (WidgetTester tester) async {
    useTallViewport(tester);
    // 预置持久化：组 1 的第 1 个颜色（动态取色，不依赖数据内容）
    const g = 1, c = 0;
    final fakePrefs = FakePreferencesRepository(
      themeGroupIndex: g,
      themeColorIndex: c,
    );

    await tester.pumpWidget(
      withProviders(
        const ThemeColorPicker(),
        preferences: fakePrefs,
      ),
    );
    await tester.pumpAndSettle();

    // 进入即选中已应用主题色
    expect(fakePrefs.themeGroupIndex, g);
    expect(fakePrefs.themeColorIndex, c);
    expect(countSelected(tester), 1, reason: '重进页面应选中已应用的主题色');

    // 无改动时 Apply 禁用
    final applyFinder = find.widgetWithText(ShadButton, 'Apply theme');
    final applyBtn = tester.widget<ShadButton>(applyFinder);
    expect(applyBtn.onPressed, isNull, reason: '重进且未改动时 Apply 按钮应禁用');
  });

  testWidgets('切换分组显示新组颜色，不自动选中同位置颜色', (WidgetTester tester) async {
    useTallViewport(tester);
    // 预置：当前已应用主题色在组 0 的第 2 个颜色（i=1），进入后应选中它
    const currentG = 0, currentC = 1;
    final fakePrefs = FakePreferencesRepository(
      themeGroupIndex: currentG,
      themeColorIndex: currentC,
    );

    await tester.pumpWidget(
      withProviders(
        const ThemeColorPicker(),
        preferences: fakePrefs,
      ),
    );
    await tester.pumpAndSettle();
    expect(countSelected(tester), 1, reason: '进入页面应选中当前已应用主题色（组 0 / i=1）');

    // 切到第 2 组（g=1）：同位置（i=1）颜色不应被自动选中
    await tester.tap(find.text(AppThemeSeeds.groups[1].nameEn));
    await tester.pumpAndSettle();
    expect(find.text(colorNameEn(1, 0)), findsWidgets, reason: '切组后网格应展示新组颜色');
    expect(countSelected(tester), 0, reason: '切到非当前组时不应自动选中任何颜色（避免同位置误导）');
    // 未选中时 Apply 应禁用
    final applyFinder = find.widgetWithText(ShadButton, 'Apply theme');
    final applyBtn = tester.widget<ShadButton>(applyFinder);
    expect(applyBtn.onPressed, isNull, reason: '切组未选色时 Apply 按钮应禁用');

    // 点击新组内的色块（仅预览）→ Apply → 持久化
    await tester.tap(find.text(colorNameEn(1, 0)));
    await tester.pumpAndSettle();
    expect(
      fakePrefs.themeGroupIndex,
      currentG,
      reason: '点击色块只是预览，groupIndex 不应提前变化',
    );

    await tester.tap(find.text('Apply theme'));
    await tester.pumpAndSettle();
    expect(fakePrefs.themeGroupIndex, 1, reason: 'Apply 后选择应持久化到偏好存储');
    expect(fakePrefs.themeColorIndex, 0, reason: 'Apply 后颜色索引应为新组第一个');
  });
}
