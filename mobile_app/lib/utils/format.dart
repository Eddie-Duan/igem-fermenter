/// 轻量格式化工具（避免引入 intl 依赖）。
library;

/// 仿真秒 → "12h 34m"。
String simDurationLabel(int totalSeconds) {
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  if (hours == 0) return '${minutes}m';
  return '${hours}h ${minutes}m';
}

/// 数值保留 [digits] 位。
String number(double value, [int digits = 2]) => value.toStringAsFixed(digits);