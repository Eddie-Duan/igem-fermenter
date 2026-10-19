import 'dart:async';
import 'dart:typed_data';

import '../models/control_state.dart';
import '../services/simulated_sensor_source.dart';
import 'ble_client.dart';
import 'ble_protocol.dart';

/// 一台"假设备"：没有硬件也能把连接 → 同步 → 实时曲线整条链路跑通，
/// 单测里也用它代替真实 BLE。
///
/// 它照着 [SimulatedSensorSource] 的两阶段曲线产生记录，行为与固件一致：
/// flash 里按 seq 存日志，收到 SYNC_REQ 才回发，收到 ACK 才发下一条，
/// 发完回 SYNC_END。
class FakeBleClient implements FermenterBleClient {
  FakeBleClient({
    this.deviceName = 'FeroEase (demo)',
    this.deviceId = 'FAKE-ESP32-S3-0001',
    int historyRecords = 8,
    this.liveSamples = false,
    this.sampleInterval = const Duration(seconds: 5),
    this.scanRefreshInterval = const Duration(seconds: 2),
    this.ackTimeout = const Duration(seconds: 5),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    _appendHistory(historyRecords);
  }

  /// 设备广播名 / 设备标识。
  final String deviceName;
  final String deviceId;

  /// 同步完成后是否继续按 [sampleInterval] 产生新采样（演示用）。
  final bool liveSamples;
  final Duration sampleInterval;

  /// 扫描结果重播周期；[Duration.zero] 表示只发一次（单测用）。
  final Duration scanRefreshInterval;

  /// 等 ACK 的时限：超时就当作手机丢了包，继续发下一条。
  final Duration ackTimeout;

  final DateTime Function() _clock;

  /// 设备每两条记录之间的仿真秒数（与固件 `SAMPLE_INTERVAL_S` 一致）。
  static const int sampleIntervalSeconds = 120;

  final _connection = StreamController<BleConnectionStatus>.broadcast();
  final _sensorData = StreamController<Uint8List>.broadcast();
  final _syncStatus = StreamController<Uint8List>.broadcast();

  final List<BleReadingRecord> _log = [];
  final Map<int, Completer<void>> _ackWaiters = {};

  StreamController<List<BleDevice>>? _scanController;
  Timer? _scanTimer;
  Timer? _liveTimer;
  bool _connected = false;
  bool _draining = false;
  int _lastCommittedSeq = -1;

  /// 最近一次收到的控制指令，测试里断言用。
  ControlState? lastControl;

  /// flash 记录总数（含已同步的）。
  int get flashRecordCount => _log.length;

  @override
  Stream<List<BleDevice>> scan({Duration timeout = const Duration(seconds: 15)}) {
    unawaited(stopScan());
    // 单订阅 controller 会缓冲事件，所以先 add 再 listen 也不会丢。
    final controller = StreamController<List<BleDevice>>();
    _scanController = controller;
    controller.add([_advertised]);
    if (scanRefreshInterval > Duration.zero) {
      _scanTimer = Timer.periodic(scanRefreshInterval, (_) {
        if (!controller.isClosed) controller.add([_advertised]);
      });
    }
    return controller.stream;
  }

  @override
  Future<void> stopScan() async {
    _scanTimer?.cancel();
    _scanTimer = null;
    final controller = _scanController;
    _scanController = null;
    if (controller != null && !controller.isClosed) await controller.close();
  }

  @override
  Stream<BleConnectionStatus> get connectionStatus => _connection.stream;

  @override
  Stream<Uint8List> get sensorData => _sensorData.stream;

  @override
  Stream<Uint8List> get status => _syncStatus.stream;

  @override
  Future<void> connect(String id) async {
    _connection.add(BleConnectionStatus.connecting);
    await Future<void>.delayed(Duration.zero);
    _connected = true;
    _connection.add(BleConnectionStatus.connected);
    if (liveSamples) {
      _liveTimer = Timer.periodic(sampleInterval, (_) => _emitLiveSample());
    }
  }

  @override
  Future<void> disconnect() async {
    _liveTimer?.cancel();
    _liveTimer = null;
    _connected = false;
    await stopScan();
    _connection.add(BleConnectionStatus.disconnected);
  }

  @override
  Future<BleDeviceInfo?> readDeviceInfo() async => BleDeviceInfo(
        firmwareVersion: 0x00010000,
        mac: 'AA:BB:CC:DD:EE:FF',
        batteryMv: 4020,
        logCapacity: 20000,
      );

  @override
  Future<void> writeControl(Uint8List frame) async {
    if (!_connected || frame.isEmpty) return;
    final data = ByteData.sublistView(frame);
    switch (frame[0]) {
      case BleCommand.setTime:
        // 假设备不需要真校时：记录已被接受即可。
        break;
      case BleCommand.syncRequest:
        unawaited(_drain(data.getUint32(1, Endian.little)));
      case BleCommand.ack:
        final seq = data.getUint32(1, Endian.little);
        final waiter = _ackWaiters.remove(seq);
        if (waiter != null && !waiter.isCompleted) waiter.complete();
      case BleCommand.commit:
        _lastCommittedSeq = data.getUint32(1, Endian.little);
      case BleCommand.setControl:
        lastControl = ControlState(
          stirrerOn: (data.getUint8(1) & 0x01) != 0,
          heaterOn: (data.getUint8(1) & 0x02) != 0,
          stirrerRpm: data.getUint16(2, Endian.little),
          targetTempC: data.getUint16(4, Endian.little) / 10,
        );
    }
  }

  /// 关掉所有流与定时器。
  Future<void> dispose() async {
    _liveTimer?.cancel();
    await stopScan();
    await _sensorData.close();
    await _syncStatus.close();
    await _connection.close();
  }

  /// 已回收到的序号（COMMIT 的结果）。
  int get lastCommittedSeq => _lastCommittedSeq;

  // -- 内部 --

  BleDevice get _advertised =>
      BleDevice(id: deviceId, name: deviceName, rssi: -58);

  /// 一次性把 flash 日志里 `seq >= fromSeq` 的记录逐条推出去。
  Future<void> _drain(int fromSeq) async {
    if (_draining) return;
    _draining = true;
    try {
      for (final record in [..._log]) {
        if (record.seq < fromSeq) continue;
        if (!_connected) return;
        final waiter = Completer<void>();
        _ackWaiters[record.seq] = waiter;
        _sensorData.add(record.toBytes());
        await waiter.future.timeout(ackTimeout, onTimeout: () {});
      }
      if (_connected) _syncStatus.add(_syncEndFrame(_log.length));
    } finally {
      _draining = false;
    }
  }

  void _emitLiveSample() {
    final record = _sample(seq: _log.length);
    _log.add(record);
    _sensorData.add(record.toBytes());
  }

  void _appendHistory(int count) {
    for (var i = 0; i < count; i++) {
      _log.add(_sample(seq: _log.length));
    }
  }

  /// 按下标生成一条记录：曲线取自仿真模型，温度按"4.5 h 升温到 37 °C"。
  BleReadingRecord _sample({required int seq}) {
    final simSeconds = (seq + 1) * sampleIntervalSeconds;
    final hours = simSeconds / 3600;
    final heating = (hours / 4.5).clamp(0.0, 1.0).toDouble();
    return BleReadingRecord(
      seq: seq,
      timestamp: _clock().millisecondsSinceEpoch ~/ 1000,
      temperatureC: 24 + 13 * heating,
      ph: SimulatedSensorSource.phAt(hours),
      od: SimulatedSensorSource.odAt(hours),
      batteryMv: 4020,
    );
  }

  static Uint8List _syncEndFrame(int nextSeq) {
    final frame = Uint8List(5);
    final data = ByteData.sublistView(frame);
    data.setUint8(0, BleStatus.syncEnd);
    data.setUint32(1, nextSeq, Endian.little);
    return frame;
  }
}
