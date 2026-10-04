import 'package:fermenter_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('app theme is Material 3 light and derives from the brand seed', () {
    final theme = buildAppTheme();
    expect(theme.useMaterial3, isTrue);
    expect(theme.colorScheme.brightness, Brightness.light);
    // 品牌色应为 Teal-ish（seed 0xff147d79），且 AppBar 使用 surface 背景。
    expect(theme.appBarTheme.backgroundColor, theme.colorScheme.surface);
    expect(theme.scaffoldBackgroundColor, theme.colorScheme.surface);
  });
}