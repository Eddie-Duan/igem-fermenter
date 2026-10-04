import 'dart:math' as math;

import '../models/control_state.dart';
import '../models/sensor_reading.dart';
import 'sensor_source.dart';

/// 两阶段发酵仿真，模型依据 wiki 与发酵罐方案：
/// - OD600：增殖期上升（logistic）→ 平台 → 裂解期指数下降；
/// - 温度：加热开 → 逼近目标温度；关 → 回落室温；
/// - pH：增殖期缓慢降至 6.55 附近，裂解期略微回升；
/// - 读数带小幅噪声。
///
/// 无硬件阶段用于演示与联调；真实设备接入后替换为 [SensorSource] 实现。
class SimulatedSensorSource implements SensorSource {
  SimulatedSensorSource({
    math.Random? random,
    double? initialTemperatureC,
    double? initialPh,
    double? initialOd,
  })  : _random = random ?? math.Random(),
        _temperatureC = initialTemperatureC ?? _ambient,
        _ph = initialPh ?? _initialPh,
        _od = initialOd ?? _initialOd;

  static const double _ambient = 24.0;
  static const double _initialPh = 7.0;
  static const double _initialOd = 0.08;

  // -- 曲线参数（hours）--
  static const double _growthEndHour = 9.0;
  static const double _plateauEndHour = 11.0;
  static const double _peakOd = 1.25;
  static const double _floorOd = 0.05;
  static const double _heatingRatePerHour = 3.0;
  static const double _coolingRatePerHour = 1.5;

  final math.Random _random;
  double _temperatureC;
  double _ph;
  double _od;

  @override
  bool get isSimulated => true;

  @override
  String get source => 'sim';

  @override
  void reset() {
    _temperatureC = _ambient;
    _ph = _initialPh;
    _od = _initialOd;
  }

  double _noise() => (_random.nextDouble() * 2 - 1) * 0.005;

  /// 基础浓度曲线（无噪声），t 为仿真小时。
  static double odAt(double t) {
    if (t <= _growthEndHour) {
      // logistic 生长，中点在 3.5h
      const mid = 3.5, k = 0.75;
      return _peakOd / (1 + math.exp(-k * (t - mid)));
    }
    if (t <= _plateauEndHour) return _peakOd;
    final lysis = t - _plateauEndHour;
    return _peakOd * math.exp(-0.22 * lysis) + _floorOd;
  }

  /// 基础 pH 曲线：增殖期缓慢产酸下降；裂解期回升。
  static double phAt(double t) {
    final double drifted;
    if (t <= _growthEndHour) {
      drifted = _initialPh - 0.045 * t;
    } else if (t <= _plateauEndHour) {
      drifted = _initialPh - 0.045 * _growthEndHour;
    } else {
      final lysisHours = (t - _plateauEndHour).clamp(0.0, 7.0).toDouble();
      drifted = (_initialPh - 0.045 * _growthEndHour) + 0.03 * lysisHours;
    }
    return drifted.clamp(6.0, 7.4).toDouble();
  }

  /// 推进一次采样。
  ///
  /// [simSeconds] 是实验时间轴上的绝对时刻（决定 OD/pH 曲线），
  /// [dtSeconds] 是距上一次读数的步长（用于温度积分）。
  @override
  SensorReading poll({
    required int projectId,
    required int seq,
    required ControlState control,
    required int simSeconds,
    required int dtSeconds,
  }) {
    final dtHours = dtSeconds / 3600.0;
    final t = simSeconds / 3600.0;

    // 温度：受加热/冷却速率与目标控制
    if (control.heaterOn) {
      if (_temperatureC < control.targetTempC - 0.1) {
        _temperatureC = math.min(
            control.targetTempC, _temperatureC + _heatingRatePerHour * dtHours);
      }
    } else if (_temperatureC > _ambient) {
      _temperatureC =
          math.max(_ambient, _temperatureC - _coolingRatePerHour * dtHours);
    }
    _temperatureC += _noise();

    _od = odAt(t) + _noise();
    _ph = phAt(t) + _noise() * 0.6;

    return SensorReading(
      id: 0,
      projectId: projectId,
      seq: seq,
      simSeconds: simSeconds,
      recordedAt: DateTime.now(),
      temperatureC: _temperatureC,
      ph: _ph,
      od: math.max(0.0, _od),
      source: source,
    );
  }
}