import 'dart:typed_data';

import 'ble_protocol.dart';

/// 扫描到的一台设备。
class BleDevice {
  const BleDevice({required this.id, required this.name, required this.rssi});

  /// 平台相关的设备标识：Android 是 MAC 地址，iOS 是系统分配的 UUID。
  final String id;

  /// 广播名（可能为空字符串）。
  final String name;

  final int rssi;

  /// 界面上没名字的设备显示成"未知设备"。
  String get displayName => name.isEmpty ? 'Unknown device' : name;

  @override
  String toString() => 'BleDevice($name, $id, ${rssi}dBm)';
}

/// 连接状态。
enum BleConnectionStatus {
  disconnected,
  connecting,
  connected,

  /// 连接失败或中途断开，[ble_client.dart] 的使用方负责提示重试。
  failed,
}

/// BLE 传输层抽象。
///
/// 上层（[BleSyncService]、设备页）只依赖这个接口，
/// 所以整块逻辑可以在没有硬件的环境里用 [FakeBleClient] 跑通，
/// 也可以在换 BLE 库时只替换一个实现类。
abstract class FermenterBleClient {
  /// 扫描设备，按 id 去重后持续推送。
  ///
  /// 只扫广播里带 [BleUuids.service] 的设备，避免列表被无关设备淹没。
  /// 默认值写在接口上：调用方按 [FermenterBleClient] 这个静态类型调
  /// `scan()` 时，用的是这里的默认值。
  Stream<List<BleDevice>> scan({
    Duration timeout = const Duration(seconds: 15),
  });

  Future<void> stopScan();

  /// 连接状态变化。
  Stream<BleConnectionStatus> get connectionStatus;

  /// 连接设备并完成服务发现；失败抛异常。
  Future<void> connect(String deviceId);

  Future<void> disconnect();

  /// 读取 DeviceInfo（固件版本 / MAC / 电池 / 日志容量）；解不出来时返回 null。
  Future<BleDeviceInfo?> readDeviceInfo();

  /// SensorData 特征的 Notify 帧（每帧一条 20 字节记录）。
  Stream<Uint8List> get sensorData;

  /// SyncStatus 特征的 Notify 帧。
  Stream<Uint8List> get status;

  /// 写 SyncControl 特征（Write With Response）。
  Future<void> writeControl(Uint8List frame);

  /// 断开并释放资源（定时器、stream controller 等）。
  Future<void> dispose();
}
