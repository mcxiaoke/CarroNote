// 将 shadcn_ui 的 ShadTheme 对接到当前 Safenotes 的品牌色（Nord 蓝 0xFF5E81AC）。
//
// 只作用于 ShadXxx 组件；旧 Material 页面仍由 FlexColorScheme 生成的 ThemeData 主题化。
// 两套设计系统通过 ShadApp.custom 并存，互不干扰。
import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class ShadThemes {
  static const Color _brand = Color(0xFF5E81AC); // Nord frost / 品牌主色
  static const Color _brandHi = Color(0xFF81A1C1); // Nord frost 浅色（focus ring）
  static const Color _brandDestructive = Color(0xFFBF616A); // Nord aurora red

  static ShadThemeData get light => ShadThemeData(
        brightness: Brightness.light,
        colorScheme: const ShadSlateColorScheme.light(
          primary: _brand,
          ring: _brandHi,
          selection: Color(0x335E81AC),
          destructive: _brandDestructive,
        ),
      );

  static ShadThemeData get dark => ShadThemeData(
        brightness: Brightness.dark,
        colorScheme: const ShadSlateColorScheme.dark(
          primary: _brand,
          ring: _brandHi,
          selection: Color(0x335E81AC),
          destructive: _brandDestructive,
        ),
      );
}
