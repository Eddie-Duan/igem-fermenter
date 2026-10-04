import 'package:flutter/material.dart';

/// 品牌种子色，与 esp32-medication-device 保持一致。
/// 全 App 的配色都从它派生。
const _seedColor = Color(0xff147d79);

/// App 主题。只在 `main.dart` 里装配，页面不要再写死颜色。
///
/// **只有这一套（浅色）。** 外观切换已按需求移除，不再收 [Brightness]。
ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: _seedColor,
    brightness: Brightness.light,
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      centerTitle: false,
    ),
  );
}