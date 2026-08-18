// 运行时环境变量支持（供主题/外观调试与对比截图使用）。
//
// 设计：
// - 直接变量：SN_THEME_DSV=tonalSpot|vibrant|...（最常用，单一覆盖）
// - 通用容器：SN_ENV_VARS="KEY=VALUE;KEY2=VALUE2"（未来扩展用，逗号或分号分隔）
//   两者并存时，SN_ENV_VARS 内的同名键优先。
//
// 读取发生在进程启动时（buildSeedColorScheme 首次调用），因此同一份构建产物
// 只需在启动时注入不同环境变量即可切换外观，无需重新打包。

// Dart imports:
import 'dart:io' show Platform;

// Flutter imports:
import 'package:flutter/material.dart';

/// 通用环境变量容器（SN_ENV_VARS）的解析结果，懒加载缓存，进程内只解析一次。
Map<String, String> _parseGenericEnvVars() {
  const String raw = String.fromEnvironment(
    'SN_ENV_VARS',
    defaultValue: '',
  );
  final String fromPlatform = Platform.environment['SN_ENV_VARS'] ?? '';
  final String source = fromPlatform.isNotEmpty ? fromPlatform : raw;
  if (source.isEmpty) return const <String, String>{};

  final Map<String, String> out = <String, String>{};
  for (final part in source.split(RegExp(r'[;,]'))) {
    final eq = part.indexOf('=');
    if (eq <= 0 || eq == part.length - 1) continue;
    final key = part.substring(0, eq).trim();
    final val = part.substring(eq + 1).trim();
    if (key.isNotEmpty) out[key] = val;
  }
  return out;
}

Map<String, String>? _genericCache;

Map<String, String> get _genericEnvVars =>
    _genericCache ??= _parseGenericEnvVars();

/// 读取一个命名环境变量：优先 SN_ENV_VARS 容器内同名键，其次同名平台环境变量，
/// 最后回退 [fallback]。
String? envVar(String name, [String? fallback]) {
  final fromGeneric = _genericEnvVars[name];
  if (fromGeneric != null && fromGeneric.isNotEmpty) return fromGeneric;
  final fromPlatform = Platform.environment[name];
  if (fromPlatform != null && fromPlatform.isNotEmpty) return fromPlatform;
  return fallback;
}

/// DynamicSchemeVariant 名称 → 枚举的合法映射（Flutter 3.x）。
const Map<String, DynamicSchemeVariant> _dsvByName = <String, DynamicSchemeVariant>{
  'tonalspot': DynamicSchemeVariant.tonalSpot,
  'monochrome': DynamicSchemeVariant.monochrome,
  'neutral': DynamicSchemeVariant.neutral,
  'vibrant': DynamicSchemeVariant.vibrant,
  'expressive': DynamicSchemeVariant.expressive,
  'fidelity': DynamicSchemeVariant.fidelity,
};

/// 由环境变量 SN_THEME_DSV（或 SN_ENV_VARS 内的 THEME_DSV）解析出的
/// DynamicSchemeVariant 覆盖。
///
/// 返回 null 表示未设置，调用方应回退到默认行为（中性 seed→monochrome，
/// 彩色 seed→tonalSpot）。名称大小写不敏感；非法值回退 null 并打印告警日志。
DynamicSchemeVariant? get themeDynamicSchemeVariantOverride {
  final raw = envVar('SN_THEME_DSV') ?? envVar('THEME_DSV');
  if (raw == null || raw.isEmpty) return null;
  final variant = _dsvByName[raw.toLowerCase()];
  if (variant == null) {
    // 非法值：不阻断启动，仅告警并回退默认。
    // ignore: avoid_print
    print('[env] 忽略非法 SN_THEME_DSV="$raw"，回退默认 DynamicSchemeVariant');
  }
  return variant;
}

/// 当前生效的 DynamicSchemeVariant 名称（用于日志/调试展示）。
String get themeDynamicSchemeVariantName =>
    themeDynamicSchemeVariantOverride?.name ?? 'default';
