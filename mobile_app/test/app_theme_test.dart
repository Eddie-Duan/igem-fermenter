import 'package:fermenter_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('app theme uses the lavender and orange brand palette', () {
    final theme = buildAppTheme();
    expect(theme.useMaterial3, isTrue);
    expect(theme.colorScheme.brightness, Brightness.light);
    expect(theme.colorScheme.primary, const Color(0xff765185));
    expect(theme.colorScheme.secondary, const Color(0xfff4a900));
    expect(theme.colorScheme.tertiary, const Color(0xff9333ea));
    expect(theme.appBarTheme.backgroundColor, theme.colorScheme.surface);
    expect(theme.scaffoldBackgroundColor, theme.colorScheme.surface);
  });
}