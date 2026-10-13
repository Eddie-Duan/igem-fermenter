import 'package:flutter/material.dart';

/// 品牌主色为淡紫，黄橙色用于次要强调。
const _brandPurple = Color(0xff765185);
const _accentOrange = Color(0xffe9a23b);

/// App 主题。只在 `main.dart` 里装配，页面不要再写死颜色。
///
/// **只有这一套（浅色）。** 外观切换已按需求移除，不再收 [Brightness]。
ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: _brandPurple,
    primary: _brandPurple,
    secondary: _accentOrange,
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