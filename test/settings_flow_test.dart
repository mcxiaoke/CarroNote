// 设置 / 笔记配色 / 主题切换 集成测试
//
// 直接挂载真实屏幕（与 App 完全一致的 Provider / ShadTheme 结构），
// 重点验证本轮 shadcn 迁移中用户反馈的三处回归是否已修复：
//   1. 设置 tile 的 value 文本应靠右（TextAlign.end + Align.centerRight），而非停留在行中
//   2. 笔记配色页色条应有颜色且实际高度 > 0（迁移前 ColoredBox 在 Row 中高度为 0 → 空白）
//   3. 明暗弹层根 Material 背景应跟随主题变化（修复前固定为打开时的旧主题色）
//   附：笔记配色开关、明暗开关能正确驱动对应 Provider。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_session_timeout/local_session_timeout.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/shad_theme.dart';
import 'package:safenotes/sync/sync_config.dart';
import 'package:safenotes/views/settings/notes_color_setting.dart';
import 'package:safenotes/views/settings/settings.dart';
import 'package:safenotes/views/settings/theme_setting.dart';

import 'test_helpers.dart';

/// 打开主题弹层（以 ColorPallet 为宿主屏幕）。
Future<void> _openSheet(WidgetTester tester) async {
  await tester.pumpWidget(wrapScreen(const ColorPallet()));
  await tester.pumpAndSettle();
  final ctx = tester.element(find.byType(ColorPallet));
  showThemeBottomSheet(ctx);
  await tester.pumpAndSettle();
}

/// 取主题弹层树中最外层的 Material（即根容器）。
Material _rootMaterial(WidgetTester tester) {
  return tester.widget<Material>(
    find
        .descendant(
          of: find.byType(ThemeBottomSheet),
          matching: find.byType(Material),
        )
        .first,
  );
}

/// 弹层内「Dark mode」开关（ThemeBottomSheet 的第一个 ShadSwitch）。
Finder get _sheetDarkModeSwitch => find.descendant(
      of: find.byType(ThemeBottomSheet),
      matching: find.byType(ShadSwitch),
    ).first;

void main() {
  setUpAll(() async {
    await initTestEnv();
  });

  setUp(() async {
    await PreferencesStorage.init();
    await SyncConfig.init();
    // 用例间 SharedPreferences 残留会互相影响，统一重置为确定性状态。
    // 必须在 prepareProviders() 之前重置，否则 ThemeProvider 在构造时读到的
    // isThemeDark 仍是上一个用例留下的值，导致 isDarkMode 初始状态不确定。
    await PreferencesStorage.setIsColorful(false);
    await PreferencesStorage.setLocalDarkSwitchEnabled(false);
    await PreferencesStorage.setSystemDarkLightSwitchEnabled(false);
    await PreferencesStorage.setIsThemeDark(false);
    prepareProviders();
  });

  group('设置页', () {
    testWidgets('主分区关键 tile 均渲染，且 value 文本靠右（TextAlign.end）',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        wrapScreen(SettingsScreen(
          sessionStateStream: StreamController<SessionState>(),
        )),
      );
      await tester.pumpAndSettle();

      // 加高测试视口，使整个设置页（含 Security/Sync/Misc 分区）无需滚动即可见，
      // 避免 find 默认跳过 offstage 屏外控件导致断言失败。
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1;

      await tester.pumpWidget(
        wrapScreen(SettingsScreen(
          sessionStateStream: StreamController<SessionState>(),
        )),
      );
      await tester.pumpAndSettle();

      // 关键 tile 标题存在（覆盖各分区的代表性 tile）
      for (final t in const [
        'Backup',
        'Language',
        'Dark Mode',
        'Notes Color',
        'Change Passphrase',
        'Logout',
      ]) {
        expect(find.text(t), findsWidgets, reason: '设置 tile 缺失: $t');
      }

      // 至少一个 value 文本右对齐（迁移修复的核心：行尾对齐）。
      // shadNavigationTile 用 Align(centerRight) 包 Text(textAlign: TextAlign.end)。
      expect(
        find.byWidgetPredicate(
          (w) => w is Text && w.textAlign == TextAlign.end,
        ),
        findsWidgets,
        reason: '未见任何行尾右对齐(value textAlign=end)的文本（行尾对齐修复可能失效）',
      );
    });

    testWidgets('Dark Mode tile 默认显示 Off', (WidgetTester tester) async {
      await tester.pumpWidget(
        wrapScreen(SettingsScreen(
          sessionStateStream: StreamController<SessionState>(),
        )),
      );
      await tester.pumpAndSettle();
      expect(testThemeProvider.isDarkMode, isFalse);
      expect(find.text('Off'), findsWidgets);
    });
  });

  group('笔记配色页', () {
    testWidgets('色条有真实颜色且高度 > 0（修复前为空白）',
        (WidgetTester tester) async {
      await tester.pumpWidget(wrapScreen(const ColorPallet()));
      await tester.pumpAndSettle();

      // 页面标题与预览文本存在（注意 "Notes Color" 在 appBar 与分区标题各出现一次）
      expect(find.text('Notes Color'), findsWidgets);
      expect(find.textContaining('Selected'), findsWidgets);

      // 找到带 color 的 Container（即色条色块）
      final coloredContainers = find.byWidgetPredicate(
        (w) => w is Container && w.color != null,
      );
      expect(coloredContainers, findsWidgets,
          reason: '未找到任何带颜色的色块');

      // 至少一个色块在屏幕上实际有高度（修复前高度为 0 → 空白）
      var anyWithHeight = false;
      final count = tester.widgetList(coloredContainers).length;
      for (var i = 0; i < count; i++) {
        final size = tester.getSize(coloredContainers.at(i));
        if (size.height > 5) {
          anyWithHeight = true;
          break;
        }
      }
      expect(anyWithHeight, isTrue,
          reason: '所有色块高度为 0，色条空白（迁移回归未修复）');
    });

    testWidgets('Colorful Notes 开关能驱动 PreferencesStorage.isColorful',
        (WidgetTester tester) async {
      await tester.pumpWidget(wrapScreen(const ColorPallet()));
      await tester.pumpAndSettle();

      expect(PreferencesStorage.isColorful, isFalse);
      // 该页仅有一个开关（Colorful Notes），限定到 ColorPallet 子树
      final colorfulSwitch = find.descendant(
        of: find.byType(ColorPallet),
        matching: find.byType(ShadSwitch),
      );
      await tester.tap(colorfulSwitch.first);
      await tester.pumpAndSettle();
      expect(PreferencesStorage.isColorful, isTrue);
    });
  });

  group('明暗主题弹层', () {
    testWidgets('弹层背景跟随主题：明亮=亮色背景，暗黑=暗色背景',
        (WidgetTester tester) async {
      // 默认明亮
      await _openSheet(tester);
      expect(_rootMaterial(tester).color,
          equals(ShadThemes.light.colorScheme.background));

      // 关闭弹层 → 切到暗黑 → 重新打开，背景应变成暗色
      Navigator.of(tester.element(find.byType(ColorPallet))).pop();
      await tester.pumpAndSettle();
      testThemeProvider.setIsDarkMode(true);
      await tester.pumpAndSettle();
      await _openSheet(tester);
      expect(_rootMaterial(tester).color,
          equals(ShadThemes.dark.colorScheme.background));
    });

    testWidgets('明暗开关能更新 ThemeProvider（isDarkMode 翻转）',
        (WidgetTester tester) async {
      await _openSheet(tester);
      expect(testThemeProvider.isDarkMode, isFalse);
      // 第一个开关即弹层内的 “Dark mode”（已限定到 ThemeBottomSheet 子树，
      // 避免误点到宿主 ColorPallet 被 ModalBarrier 遮挡的开关而 tap 失效）
      await tester.tap(_sheetDarkModeSwitch, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(testThemeProvider.isDarkMode, isTrue);
    });
  });
}
