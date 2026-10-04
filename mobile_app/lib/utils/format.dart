/// 轻量格式化工具（避免引入 intl 依赖）。
library;

/// 仿真秒 → "12h 34m"。
String simDurationLabel(int totalSeconds) {
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  if (hours == 0) return '${minutes}m';
  return '${hours}h ${minutes}m';
}

/// 仿真实时 → "12.5h"。
String simHoursLabel(int totalSeconds) =>
    '${(totalSeconds / 3600).toStringAsFixed(1)}h';

/// 数值保留 [digits] 位。
String number(double value, [int digits = 2]) => value.toStringAsFixed(digits);

/// 采收预测：距当前仿真时刻的剩余时长提示文案。
String harvestCountdownLabel(int simSeconds, double totalPerHour) {
  final remaining =
      ((totalPerHour * 3600) - simSeconds).ceil().clamp(0, 1 << 62).toInt();
  return '~${simDurationLabel(remaining)} to detected harvest curve (est.)';
}