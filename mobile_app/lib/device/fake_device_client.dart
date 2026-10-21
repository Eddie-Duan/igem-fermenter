import 'dart:async';

import 'device_client.dart';

/// 一台"假设备"：没有硬件也能把连接 → 同步 → 实时曲线整条链路跑通，
/// 单测里也用它代替真实网络。
///
/// 它照着 App 的仿真曲线产生记录，行为与固件一致：flash 里按 seq 存日志，
/// 按 `since` 分页回发，收到 commit 才回收。
class FakeDeviceClient implements DeviceClient {
  FakeDeviceClient({
    this.deviceName = 'FeroEase (demo)',
    this.deviceId = 'FAKE-DEMO-0001',
    int historyRecords = 8,
    this.sampleInterval = const Duration(seconds: 5),
    this.recordIntervalSeconds = 120,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    _appendHistory(historyRecords);
  }

  final String deviceName;
  final String deviceId;
  final Duration sampleInterval;

  /// 每条记录代表的实验秒数（与固件 `RECORD_PERIOD_MS` 一致）。
  final int recordIntervalSeconds;

  final DateTime Function() _clock;

  final _connection = StreamController<DeviceConnectionStatus>.broadcast();

  final List<DeviceReading> _log = [];

  Timer? _liveTimer;
  bool _connected = false;

  DeviceCredentials? credentials;
  int _oldest = 0;
  int _committedThrough = -1;

  /// 最近一次收到的控制指令，测试里断言用。
  ({bool stirrerOn, int stirrerRpm, bool heaterOn, double targetTempC})?
      lastControl;

  /// 最近一次校时请求。
  DateTime? lastTimeSync;

  int get flashRecordCount => _log.length;
  int get oldest => _oldest;
  int get next => _log.isEmpty ? _oldest : _log.last.seq + 1;
  int get lastCommittedSeq => _committedThrough;

  @override
  Stream<DeviceConnectionStatus> get connectionStatus => _connection.stream;

  @override
  Future<void> connect(DeviceCredentials credentials) async {
    this.credentials = credentials;
    _connection.add(DeviceConnectionStatus.connecting);
    await Future<void>.delayed(Duration.zero);
    _connected = true;
    _connection.add(DeviceConnectionStatus.connected);
    if (sampleInterval > Duration.zero) {
      _liveTimer = Timer.periodic(sampleInterval, (_) => _emitLiveSample());
    }
  }

  @override
  Future<void> disconnect() async {
    _liveTimer?.cancel();
    _liveTimer = null;
    _connected = false;
    if (!_connection.isClosed) {
      _connection.add(DeviceConnectionStatus.disconnected);
    }
  }

  @override
  Future<DeviceStatus> refreshStatus() async => DeviceStatus({
        'apiVersion': 1,
        'firmware': '1.1.0',
        'deviceId': deviceId,
        'logCapacity': 2000,
        'logReady': true,
        'oldestSeq': oldest,
        'nextSeq': next,
        'recordCount': _log.length,
        'sampleIntervalS': recordIntervalSeconds,
        'stirrerSupported': false,
        'stirrerOn': false,
        'stirrerRpm': 0,
        'heaterEnabled': lastControl?.heaterOn ?? false,
        'heaterOn': lastControl?.heaterOn ?? false,
        'targetTempC': lastControl?.targetTempC ?? 30.0,
        'tempC': _log.isEmpty ? 30.0 : _log.last.temperatureC,
        'ph': _log.isEmpty ? 7.0 : _log.last.ph,
        'odProxy': _log.isEmpty ? 0.0 : _log.last.od,
        'alarm': false,
        'staIp': '192.168.4.1',
        'apIp': '192.168.4.1',
      });

  @override
  Future<DeviceReadingsPage> readings({
    required int since,
    int limit = 60,
  }) async {
    if (!_connected) throw StateError('Demo device is not connected.');
    var start = since < _oldest ? _oldest : since;
    if (start > next) start = next;
    final page = [
      for (final record in _log)
        if (record.seq >= start) record,
    ].take(limit).toList(growable: false);
    return DeviceReadingsPage(
      oldest: _oldest,
      next: next,
      count: _log.length,
      since: start,
      records: page,
    );
  }

  @override
  Future<void> commit(int lastSeq) async {
    _committedThrough = lastSeq;
    // 与固件一致：回收后 oldest 推进，但 next 不回退。
    if (lastSeq + 1 > _oldest) _oldest = lastSeq + 1;
  }

  @override
  Future<void> setControl({
    required bool stirrerOn,
    required int stirrerRpm,
    required bool heaterOn,
    required double targetTempC,
  }) async {
    lastControl = (
      stirrerOn: stirrerOn,
      stirrerRpm: stirrerRpm,
      heaterOn: heaterOn,
      targetTempC: targetTempC,
    );
  }

  @override
  Future<void> setTime(DateTime now) async {
    lastTimeSync = now;
  }

  @override
  Future<void> close() async {
    await disconnect();
    await _connection.close();
  }

  // -- 内部 --

  void _emitLiveSample() {
    if (!_connected) return;
    _log.add(_sample(seq: next));
  }

  void _appendHistory(int count) {
    for (var i = 0; i < count; i++) {
      _log.add(_sample(seq: _log.length));
    }
  }

  DeviceReading _sample({required int seq}) {
    final phase = (seq * recordIntervalSeconds) % 7200;
    final od = phase < 3600
        ? 0.05 + phase / 3600 * 0.55
        : 0.60 - (phase - 3600) / 3600 * 0.45;
    return DeviceReading(
      seq: seq,
      timestamp: _clock().millisecondsSinceEpoch ~/ 1000,
      temperatureC: 30 + (seq % 5) * 0.1,
      ph: 7.0 - (seq % 7) * 0.01,
      od: od,
    );
  }
}
