/// 执行器控制状态（不可变）。未来接真实硬件时，
/// 用同一对象下发到设备端。
class ControlState {
  const ControlState({
    required this.stirrerOn,
    required this.stirrerRpm,
    required this.heaterOn,
    required this.targetTempC,
  });

  const ControlState.idle({double targetTempC = 30})
      : stirrerOn = false,
        stirrerRpm = 200,
        heaterOn = false,
        targetTempC = targetTempC;

  final bool stirrerOn;
  final int stirrerRpm; // 100–300 rpm
  final bool heaterOn;
  final double targetTempC;

  static const int minRpm = 100;
  static const int maxRpm = 300;

  ControlState copyWith({
    bool? stirrerOn,
    int? stirrerRpm,
    bool? heaterOn,
    double? targetTempC,
  }) =>
      ControlState(
        stirrerOn: stirrerOn ?? this.stirrerOn,
        stirrerRpm: stirrerRpm ?? this.stirrerRpm,
        heaterOn: heaterOn ?? this.heaterOn,
        targetTempC: targetTempC ?? this.targetTempC,
      );
}