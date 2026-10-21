import 'dart:async';

import '../models/sensor_reading.dart';
import 'device_client.dart';

/// 同步服务把设备读数交给 App 侧落库。
///
/// 由 `FermenterController` 实现，这样设备层不需要认识 Controller，
/// 单测里换个假实现就能把整条同步流程跑完。
abstract class DeviceReadingSink {
  /// 该批次本地第一条**缺失**的设备序号（空批次为 0）。
  ///
  /// 不能简单取「最大序号 + 1」：中间丢过一条时，从缺口重取才不会永久跳过。
  Future<int> nextExpectedSeq(int projectId);

  /// 落库。返回之后同步服务才会让设备回收这段日志。
  Future<void> storeDeviceReadings(int projectId, List<SensorReading> readings);
}

/// 一次 flash 日志同步的结果。
class DeviceSyncResult {
  const DeviceSyncResult({
    required this.stored,
    required this.nextSeq,
    required this.committedThrough,
  });

  /// 本次新落库的条数。
  final int stored;

  /// 下一次同步该从哪个序号开始。
  final int nextSeq;

  /// 已通知设备回收到的序号；-1 表示本次没有回收。
  final int committedThrough;

  @override
  String toString() => 'DeviceSyncResult(stored: $stored, nextSeq: $nextSeq, '
      'committedThrough: $committedThrough)';
}

/// 同步过程中设备报错，或超时。
class DeviceSyncException implements Exception {
  const DeviceSyncException(this.message);
  final String message;
  @override
  String toString() => 'DeviceSyncException: $message';
}

/// 把设备 flash 日志同步到本地库。
///
/// 流程：`/api/readings?since=cursor` 分页拉取 → 逐页落库 → 全部落库后
/// `/api/readings/commit` 通知设备回收。任意一页失败都不回收，
/// 设备上的数据还在，下次同步重来。
class DeviceSyncService {
  // ignore_for_file: prefer_initializing_formals -- 保留 client/sink 作为命名参数
  DeviceSyncService({
    required DeviceClient client,
    required DeviceReadingSink sink,
    DateTime Function()? clock,
    this.pageSize = 60,
    this.syncTimeout = const Duration(minutes: 3),
  })  : _client = client,
        _sink = sink,
        _clock = clock ?? DateTime.now;

  final DeviceClient _client;
  final DeviceReadingSink _sink;
  final DateTime Function() _clock;

  /// 每页条数。固件端上限 200；60 条约 6 KB JSON，够稳也够快。
  final int pageSize;

  /// 整轮同步的最长等待时间。
  final Duration syncTimeout;

  int? _projectId;

  /// 每落库一条就回调一次，供界面显示同步进度。
  void Function(int stored)? onProgress;

  DeviceStatus? status;

  /// 最近一次失败原因，供界面提示。
  String? lastFailure;

  int? get boundProjectId => _projectId;

  /// 绑定批次并校时。重复调用同一批次是幂等的。
  Future<void> attach(int projectId) async {
    _projectId = projectId;
    await setTime();
  }

  /// 只解绑批次，不断开连接。
  Future<void> detach() async {
    _projectId = null;
  }

  /// 校准设备时钟：记录里的绝对时间戳依赖它。
  Future<void> setTime() => _client.setTime(_clock());

  Future<void> refreshStatus() async {
    status = await _client.refreshStatus();
  }

  /// 拉取尚未同步的记录。
  ///
  /// 只有全部落库成功才会 COMMIT；中途失败时设备保留数据，下次重发。
  Future<DeviceSyncResult> sync() async {
    final projectId = _projectId;
    if (projectId == null) {
      throw const DeviceSyncException(
          'Connect a device and pick a batch before syncing.');
    }

    try {
      return await _sync(projectId).timeout(syncTimeout);
    } on TimeoutException {
      throw const DeviceSyncException(
          'The device did not finish sending its log in time. '
          'It keeps the unsynced records for the next attempt.');
    } on DeviceSyncException {
      rethrow;
    } catch (error) {
      throw DeviceSyncException('Could not read the device log: $error');
    }
  }

  Future<DeviceSyncResult> _sync(int projectId) async {
    var cursor = await _sink.nextExpectedSeq(projectId);
    var stored = 0;
    var committedThrough = -1;

    var page = await _client.readings(since: cursor, limit: pageSize);
    // 设备可能已经回收了本地游标之前的记录（比如换了板子或格式化过），
    // 这时从设备现存的第一条开始，否则会一直请求一个不存在的序号。
    if (cursor < page.oldest) cursor = page.oldest;
    // 同步开始时的上界：这之后写入的记录留给下一次，避免和实时数据乱序。
    final boundary = page.next;

    while (cursor < boundary) {
      final batch = [
        for (final reading in page.records)
          if (reading.seq >= cursor && reading.seq < boundary) reading,
      ];
      if (batch.isEmpty) break; // 设备端出现空洞/被清空，先停手

      await _sink.storeDeviceReadings(
        projectId,
        [for (final reading in batch) _toReading(projectId, reading)],
      );
      stored += batch.length;
      onProgress?.call(stored);
      cursor = batch.last.seq + 1;

      if (cursor >= boundary) break;
      page = await _client.readings(since: cursor, limit: pageSize);
      if (page.records.isEmpty) break;
    }

    if (stored > 0) {
      // 只回收真的落了库的那一段；设备上没确认的部分继续留着。
      committedThrough = cursor - 1;
      await _client.commit(committedThrough);
    }
    return DeviceSyncResult(
      stored: stored,
      nextSeq: cursor,
      committedThrough: committedThrough,
    );
  }

  /// 下发搅拌/加热状态。
  Future<void> sendControl({
    required bool stirrerOn,
    required int stirrerRpm,
    required bool heaterOn,
    required double targetTempC,
  }) =>
      _client.setControl(
        stirrerOn: stirrerOn,
        stirrerRpm: stirrerRpm,
        heaterOn: heaterOn,
        targetTempC: targetTempC,
      );

  /// 设备记录 → 本地读数。
  ///
  /// `simSeconds` 先留 0：实验时间轴由 Controller 落库时按
  /// `seq × 采样周期` 补，换算只留一个地方。
  SensorReading _toReading(int projectId, DeviceReading reading) {
    final recordedAt = reading.timestamp == 0
        // 设备还没校时（比如刚上电就连上）：先用手机时间占位。
        ? _clock()
        : DateTime.fromMillisecondsSinceEpoch(reading.timestamp * 1000);
    return SensorReading(
      id: 0,
      projectId: projectId,
      seq: reading.seq,
      simSeconds: 0,
      recordedAt: recordedAt,
      temperatureC: reading.temperatureC,
      ph: reading.ph,
      od: reading.od < 0 ? 0 : reading.od,
      source: 'device',
    );
  }
}
