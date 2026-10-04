import '../models/control_state.dart';
import '../models/sensor_reading.dart';

/// 数据源抽象：当前只有仿真实现，未来接硬件时新增一个实现即可，
/// Controller 与页面不感知差异。
abstract class SensorSource {
  /// 仿真设备恒为 true；真实设备为 false（UI 用）。
  bool get isSimulated;

  /// 来源标记，写入 readings.source（'sim' / 将来 'ble'/'wifi'）。
  String get source;

  /// 前进一次采样。
  ///
  /// [simSeconds] 是实验时间轴上的绝对时刻（决定曲线取值），
  /// [dtSeconds] 是距上一次读数的步长（用于温度等状态积分）。
  /// [seq] 由调用方给定（批内顺序号）。
  SensorReading poll({
    required int projectId,
    required int seq,
    required ControlState control,
    required int simSeconds,
    required int dtSeconds,
  });

  /// 丢弃内部状态（如暂停后重启可回退到最近读数）。
  void reset();
}