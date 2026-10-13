import 'dart:async';
import 'dart:typed_data';

import '../models/control_state.dart';
import '../models/sensor_reading.dart';
import 'ble_client.dart';
import 'ble_protocol.dart';

/// 同步服务把解码后的读数交给 App 侧落库。
///
/// 由 `FermenterController` 实现，这样 BLE 层不需要认识 Controller，
/// 单测里换个假实现就能把整条同步流程跑完。
abstract class BleReadingSink {
  /// 该批次本地已有的**下一条**序号（空批次为 0）。
  ///
  /// 设备按 `SYNC_REQ(next_seq)` 从该序号开始（含）回发记录。
  Future<int> nextExpectedSeq(int projectId);

  /// 落库。返回之后同步服务才会回 ACK —— 「Notify 送达 ≠ 已持久化」。
  Future<void> storeDeviceReadings(int projectId, List<SensorReading> readings);
}

/// 一次 flash 日志同步的结果。
class BleSyncResult {
  const BleSyncResult({
    required this.stored,
    required this.duplicates,
    required this.nextSeq,
  });

  /// 本次新落库的条数。
  final int stored;

  /// 设备重发的重复包条数（已回 ACK，未重复入库）。
  final int duplicates;

  /// 下一次同步该从哪个序号开始。
  final int nextSeq;

  @override
  String toString() =>
      'BleSyncResult(stored: $stored, duplicates: $duplicates, nextSeq: $nextSeq)';
}

/// 同步过程中设备报错，或超时。
class BleSyncException implements Exception {
  const BleSyncException(this.message);
  final String message;
  @override
  String toString() => 'BleSyncException: $message';
}

/// 把 flash 日志同步到本地库，并持续接收实时采样。
///
/// 生命周期：
/// ```text
/// attach(projectId)      订阅两条 Notify + 校时
///   └─ syncLog()         SYNC_REQ → 逐条落库+ACK → SYNC_END → COMMIT
/// detach()               只停订阅，不断开连接
/// ```
/// `syncLog()` 返回后订阅仍在，设备后续的采样会继续落库 —— 这就是"实时曲线"，
/// 不需要第二个流程。
class BleSyncService {
  BleSyncService({
    required FermenterBleClient client,
    required BleReadingSink sink,
    DateTime Function()? clock,
    this.syncTimeout = const Duration(seconds: 45),
  })  : _client = client,
        _sink = sink,
        _clock = clock ?? DateTime.now;

  final FermenterBleClient _client;
  final BleReadingSink _sink;
  final DateTime Function() _clock;

  /// 从 SYNC_REQ 发出到收到 SYNC_END 的最长等待时间。
  final Duration syncTimeout;

  /// 每落库一条就回调一次，供界面显示同步进度。
  void Function(int stored)? onProgress;

  int? _projectId;
  StreamSubscription<Uint8List>? _dataSub;
  StreamSubscription<Uint8List>? _statusSub;
  Completer<BleSyncResult>? _syncCompleter;

  /// 所有帧串行处理：落库是异步的，直接并发处理会打乱 ACK 顺序。
  Future<void> _queue = Future<void>.value();

  int _nextSeq = 0;
  int _stored = 0;
  int _duplicates = 0;

  BleDeviceInfo? deviceInfo;
  BleLogStatus? logStatus;

  /// 最近一次失败原因（设备错误码或本地异常），供界面提示。
  String? lastFailure;

  int? get boundProjectId => _projectId;
  int get nextSeq => _nextSeq;

  bool get _attached => _projectId != null;

  /// 订阅通知并校时。重复调用同一批次是幂等的。
  Future<void> attach(int projectId) async {
    _projectId = projectId;
    _nextSeq = await _sink.nextExpectedSeq(projectId);
    _dataSub ??= _client.sensorData.listen(_onDataFrame);
    _statusSub ??= _client.status.listen(_onStatusFrame);
    await setTime();
  }

  /// 停止接收（断开连接是 client 的事）。
  Future<void> detach() async {
    _projectId = null;
    await _dataSub?.cancel();
    await _statusSub?.cancel();
    _dataSub = null;
    _statusSub = null;
  }

  /// 校准设备时钟：设备侧时间戳用于 CSV 与「最后读数」时间。
  Future<void> setTime() =>
      _client.writeControl(BleFrames.setTime(_clock()));

  Future<void> readDeviceInfo() async {
    deviceInfo = await _client.readDeviceInfo();
  }

  /// 拉取 flash 里尚未同步的记录，返回后订阅仍保持（继续收实时采样）。
  ///
  /// 任何一条没落库成功就不会 COMMIT 越过它，设备也不会回收 —— 下次同步重发。
  Future<BleSyncResult> syncLog() async {
    if (!_attached) {
      throw const BleSyncException('请先连接设备并选择批次');
    }
    final projectId = _projectId!;
    _stored = 0;
    _duplicates = 0;
    _nextSeq = await _sink.nextExpectedSeq(projectId);

    final completer = Completer<BleSyncResult>();
    _syncCompleter = completer;
    try {
      await _client.writeControl(BleFrames.syncRequest(_nextSeq));
      final result = await completer.future.timeout(
        syncTimeout,
        onTimeout: () => throw const BleSyncException('设备没有在超时时间内回 SYNC_END'),
      );
      // 只回收已经确认落库的部分：_nextSeq 停在第一个缺口上。
      // 一条都没确认落库时不发 COMMIT —— 0-1 回绕成 0xFFFFFFFF，
      // 设备会误当成"整段日志都可以回收"。
      if (result.nextSeq > 0) {
        await _client.writeControl(BleFrames.commit(result.nextSeq - 1));
      }
      return result;
    } on BleDeviceError catch (error) {
      throw BleSyncException(error.message);
    } finally {
      if (identical(_syncCompleter, completer)) _syncCompleter = null;
    }
  }

  /// 下发搅拌/加热状态（复用批次自己的 [ControlState]）。
  Future<void> sendControl(ControlState control) =>
      _client.writeControl(BleFrames.setControl(control));

  Future<void> dispose() async {
    await detach();
  }

  // -- 内部 --

  void _onDataFrame(Uint8List frame) => _enqueue(() => _handleRecord(frame));

  void _onStatusFrame(Uint8List frame) {
    // Data and status use separate Notify streams. Let already-delivered data
    // events enqueue their work before a SYNC_END enters the serial queue.
    unawaited(_enqueueStatusFrame(frame));
  }

  Future<void> _enqueueStatusFrame(Uint8List frame) async {
    await Future<void>.delayed(Duration.zero);
    _enqueue(() => _handleStatus(frame));
  }

  /// 串行队列：一条出错不影响后面的帧。
  void _enqueue(Future<void> Function() task) {
    _queue = _queue.then((_) => task()).catchError((Object error) {
      lastFailure = '$error';
    });
  }

  Future<void> _handleRecord(Uint8List frame) async {
    final projectId = _projectId;
    if (projectId == null) return;

    final BleReadingRecord record;
    try {
      record = BleReadingRecord.fromBytes(frame);
    } on FormatException {
      // 坏包不回 ACK：设备会重发这一条。
      return;
    }

    if (record.seq < _nextSeq) {
      // 设备重发的旧记录：不重复入库，但要再回一次 ACK（上次可能丢了）。
      _duplicates++;
      await _client.writeControl(BleFrames.ack(record.seq));
      return;
    }

    await _sink.storeDeviceReadings(projectId, [_toReading(projectId, record)]);
    _stored++;
    // 只有紧邻的一条才推进游标；中间有缺口时游标停住，下次同步重取。
    // （缺口记录本身已经存下来了，重发时按重复包处理。）
    if (record.seq == _nextSeq) _nextSeq = record.seq + 1;
    // 落库成功之后才 ACK。
    await _client.writeControl(BleFrames.ack(record.seq));
    onProgress?.call(_stored);
  }

  Future<void> _handleStatus(Uint8List frame) async {
    final BleStatusMessage message;
    try {
      message = BleStatusMessage.fromBytes(frame);
    } on FormatException {
      return;
    }
    switch (message) {
      // 设备给的 next_seq 只作参考：真正的游标是本地那个（缺口不算已同步）。
      case BleSyncEnd():
        final completer = _syncCompleter;
        if (completer != null && !completer.isCompleted) {
          completer.complete(BleSyncResult(
            stored: _stored,
            duplicates: _duplicates,
            // 用本地游标而不是设备给的 next_seq：缺口不能算作已同步。
            nextSeq: _nextSeq,
          ));
        }
      case final BleDeviceError error:
        lastFailure = error.message;
        final completer = _syncCompleter;
        if (completer != null && !completer.isCompleted) {
          completer.completeError(error);
        }
      case final BleLogStatus status:
        logStatus = status;
    }
  }

  /// 设备记录 → 本地读数。
  ///
  /// `simSeconds` 先留 0：实验时间轴由 Controller 落库时按
  /// `seq × 采样周期` 补，时间轴的换算只留一个地方。
  SensorReading _toReading(int projectId, BleReadingRecord record) {
    final recordedAt = record.timestamp == 0
        // 设备还没校时（比如刚上电就连上）：先用手机时间占位。
        ? _clock()
        : DateTime.fromMillisecondsSinceEpoch(record.timestamp * 1000);
    return SensorReading(
      id: 0,
      projectId: projectId,
      seq: record.seq,
      simSeconds: 0,
      recordedAt: recordedAt,
      temperatureC: record.temperatureC,
      ph: record.ph,
      od: record.od < 0 ? 0 : record.od,
      source: 'ble',
    );
  }
}
