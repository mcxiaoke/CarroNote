// 冒烟测试：Provider 装配 + AuthWall 路由决策 + 重构涉及的子页面构建
//
// 背景：P1–P4 重构把视图层迁移到注入的 Repository / Port / SessionProvider。
// 这类「Provider 缺失 / 顺序错误 / 路由决策错」光看代码看不出来，只有运行时
// 才炸。本文件在 CI 内以秒级成本把这些装配路径全部跑一遍：
//
//   1. AuthWall 路由决策（vaultInitialized 的纯逻辑，见 resolveVaultInitialized）；
//   2. 本次重构迁移过的子页面（生物识别 / 无操作锁定 / 笔记配色 / 语言 /
//      回收站）各自能完整构建且不抛异常。

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:safenotes/authwall.dart';
import 'package:safenotes/views/deleted_notes.dart';
import 'package:safenotes/views/settings/biometric_setting.dart';
import 'package:safenotes/views/settings/inactivity_setting.dart';
import 'package:safenotes/views/settings/language_setting.dart';
import 'package:safenotes/views/settings/notes_color_setting.dart';
import 'support/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 路由决策的静态兜底置空，确保仅由注入的 SessionProvider 决定。
    AppBootState.vaultInitialized = null;
  });

  testWidgets('harness 基线：withProviders 可正常 pump 空子树', (tester) async {
    await tester.pumpWidget(
      withProviders(const Material(child: SizedBox(width: 10, height: 10))),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  group('AuthWall 路由决策', () {
    // 注意：不在这里 pump 真实登录/设置密码页——这两页含 afterFirstLayout +
    // 生物识别异步 + 键盘动画，在 widget 测试 harness 下 pump 永不收敛
    // （旧 auth_flow_test 用真实 App 才得以绕过，重构时已删）。登录/设置
    // 密码页的端到端渲染由 integration_test/app_test.dart 覆盖，这里单测
    // 路由决策的纯逻辑（resolveVaultInitialized）。
    test('session 优先于 boot 缓存', () {
      expect(
        AuthWall.resolveVaultInitialized(true, false),
        isTrue,
        reason: '注入的 SessionProvider 为 true 时走登录页',
      );
      expect(
        AuthWall.resolveVaultInitialized(false, true),
        isTrue,
        reason: 'session=false 时回退到 boot 缓存（与重构前行为一致）',
      );
    });

    test('未注入 session 时回退 boot 缓存', () {
      expect(AuthWall.resolveVaultInitialized(null, true), isTrue);
      expect(AuthWall.resolveVaultInitialized(null, false), isFalse);
      expect(
        AuthWall.resolveVaultInitialized(null, null),
        isFalse,
        reason: '均未就绪时按未初始化处理（走设置密码页）',
      );
    });
  });

  group('重构涉及子页面冒烟（可构建、无异常）', () {
    // 排除 BackupSetting：其 didChangeDependencies 会调 path_provider，
    // widget 测试环境无平台通道（integration 已覆盖真实备份页）。
    final pages = <String, Widget>{
      'BiometricSetting': const BiometricSetting(),
      'InactivityTimerSetting': const InactivityTimerSetting(),
      'ColorPallet(笔记配色)': const ColorPallet(),
      'LanguageSetting': const LanguageSetting(),
      'DeletedNotesPage': const DeletedNotesPage(),
    };

    pages.forEach((name, page) {
      testWidgets('$name 构建成功', (tester) async {
        await tester.pumpWidget(withProviders(page));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull, reason: '$name 构建不应抛异常');
      });
    });
  });
}
