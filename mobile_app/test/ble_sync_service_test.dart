import 'dart:async';
import 'dart:typed_data';

import 'package:fermenter_app/ble/ble_client.dart';
import 'package:fermenter_app/ble/ble_protocol.dart';
import 'package:fermenter_app/ble/ble_sync_service.dart';
import 'package:fermenter_app/ble/fake_ble_client.dart';
import 'package:fermenter_app/models/sensor_reading.dart';
import 'package:flutter_test/flutter_test.dart';

/// 同步流程的测试：走的是 [BleSyncService] 的真实分帧/ACK/COMMIT 逻辑，
/// 只有传输层换成假设备。
void main() {
  group('FakeBleClient 全链路', () {
    test('imports every flash record once, then commits the last one', () async {
      final client = FakeBleClient(
        historyRecords: 8,
        scanRefreshInterval: Duration.zero,
      );
      final sink = _MemorySink();
      final sync = BleSyncService(
        client: client,
        sink: sink,
        syncTimeout: const Duration(seconds: 10),
      );
      addTearDown(() async {
        await sync.dispose();
        await client.dispose();
      });

      await client.connect(client.deviceId);
      await sync.attach(1);
      final result = await sync.syncLog();

      expect(result.stored, 8);
      expect(result.duplicates, 0);
      expect(result.nextSeq, 8);
      expect(sink.stored.map((r) => r.seq), [0, 1, 2, 3, 4, 5, 6, 7]);
      expect(sink.stored.every((r) => r.source == 'ble'), isTrue);
      expect(sink.stored.every((r) => r.projectId == 1), isTrue);
      // 落库确认过的部分才允许设备回收。
      expect(client.lastCommittedSeq, 7);
    });

    test('a second sync re-requests from the cursor and stores nothing new',
        () async {
      final client = FakeBleClient(
        historyRecords: 5,
        scanRefreshInterval: Duration.zero,
      );
      final sink = _MemorySink();
      final sync = BleSyncService(client: client, sink: sink);
      addTearDown(() async {
        await sync.dispose();
        await client.dispose();
      });

      await client.connect(client.deviceId);
      await sync.attach(1);
      await sync.syncLog();
      final again = await sync.syncLog();

      expect(again.stored, 0);
      expect(sink.stored.length, 5);
    });

    test('live samples arriving after the sync are stored too', () async {
      final client = FakeBleClient(
        historyRecords: 2,
        liveSamples: true,
        sampleInterval: const Duration(milliseconds: 20),
        scanRefreshInterval: Duration.zero,
      );
      final sink = _MemorySink();
      final sync = BleSyncService(client: client, sink: sink);
      addTearDown(() async {
        await sync.dispose();
        await client.dispose();
      });

      await client.connect(client.deviceId);
      await sync.attach(1);
      await sync.syncLog();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      // 实时采样不需要第二个流程：订阅还开着，新记录继续落库。
      expect(sink.stored.length, greaterThan(2));
      expect(sink.stored.map((r) => r.seq).toSet().length, sink.stored.length);
    });
  });

  group('边界情况', () {
    test('re-ACKs a duplicate frame without storing it twice', () async {
      final client = _ScriptedClient();
      final sink = _MemorySink();
      final sync = BleSyncService(client: client, sink: sink);
      addTearDown(sync.dispose);

      client.onSyncRequest = (_) {
        client.emitRecord(_record(0));
        client.emitRecord(_record(0)); // 设备重发（上次 ACK 丢了）
        client.emitStatus(BleStatus.syncEnd, 1);
      };

      await sync.attach(1);
      final result = await sync.syncLog();

      expect(result.stored, 1);
      expect(result.duplicates, 1);
      expect(sink.stored.length, 1);
      // 重发的那条要再确认一次，否则设备会一直重发。
      expect(client.ackCount(0), 2);
    });

    test('a corrupted record is neither stored nor acknowledged', () async {
      final client = _ScriptedClient();
      final sink = _MemorySink();
      final sync = BleSyncService(client: client, sink: sink);
      addTearDown(sync.dispose);

      final corrupted = Uint8List.fromList(_record(0).toBytes());
      corrupted[12] = corrupted[12] ^ 0xFF; // 改了数据位，CRC 就对不上了

      client.onSyncRequest = (_) {
        client.emitRaw(corrupted);
        client.emitStatus(BleStatus.syncEnd, 1);
      };

      await sync.attach(1);
      final result = await sync.syncLog();

      expect(result.stored, 0);
      expect(sink.stored, isEmpty);
      expect(client.ackCount(0), 0);
      // 什么都没确认落库，就不该让设备回收 —— 否则这条记录彻底丢了。
      expect(client.commands, isNot(contains(BleCommand.commit)));
    });

    test('a gap stops the commit cursor so the missing range is kept', () async {
      final client = _ScriptedClient();
      final sink = _MemorySink();
      final sync = BleSyncService(client: client, sink: sink);
      addTearDown(sync.dispose);

      client.onSyncRequest = (_) {
        client.emitRecord(_record(0));
        // seq 1 这一帧丢了，设备直接发 2。
        client.emitRecord(_record(2));
        client.emitStatus(BleStatus.syncEnd, 3);
      };

      await sync.attach(1);
      final result = await sync.syncLog();

      expect(result.stored, 2);
      // 游标停在缺口上：只回收 0，1 及以后仍留在设备里等下次重取。
      expect(result.nextSeq, 1);
      expect(client.lastCommitValue, 0);
    });

    test('a device error surfaces as a sync failure', () async {
      final client = _ScriptedClient();
      final sink = _MemorySink();
      final sync = BleSyncService(client: client, sink: sink);
      addTearDown(sync.dispose);

      client.onSyncRequest = (_) =>
          client.emitStatus(BleStatus.error, BleErrorCode.flashFailure.code);

      await sync.attach(1);
      await expectLater(
        sync.syncLog(),
        throwsA(isA<BleSyncException>()
            .having((e) => e.message, 'message', contains('flash'))),
      );
    });

    test('a device that never answers times out instead of hanging', () async {
      final client = _ScriptedClient();
      final sync = BleSyncService(
        client: client,
        sink: _MemorySink(),
        syncTimeout: const Duration(milliseconds: 30),
      );
      addTearDown(sync.dispose);

      client.onSyncRequest = (_) {}; // 只收 SYNC_REQ，什么都不回

      await sync.attach(1);
      await expectLater(sync.syncLog(), throwsA(isA<BleSyncException>()));
    });

    test('sync without a bound batch fails fast', () async {
      final sync = BleSyncService(client: _ScriptedClient(), sink: _MemorySink());
      addTearDown(sync.dispose);
      await expectLater(sync.syncLog(), throwsA(isA<BleSyncException>()));
    });
  });
}

/// 落库的假实现，语义与 `FermenterController` 一致：
/// 下一条待同步的序号 = 已存最大序号 + 1。
class _MemorySink implements BleReadingSink {
  final List<SensorReading> stored = [];
  int next = 0;

  @override
  Future<int> nextExpectedSeq(int projectId) async => next;

  @override
  Future<void> storeDeviceReadings(
      int projectId, List<SensorReading> readings) async {
    stored.addAll(readings);
    for (final reading in readings) {
      if (reading.seq >= next) next = reading.seq + 1;
    }
  }
}

/// 完全由测试脚本驱动的假设备：只记录收到的指令，按 `onSyncRequest` 回帧。
class _ScriptedClient implements FermenterBleClient {
  final _sensor = StreamController<Uint8List>.broadcast();
  final _status = StreamController<Uint8List>.broadcast();
  final _connection = StreamController<BleConnectionStatus>.broadcast();

  /// 收到 SYNC_REQ 时怎么回（参数是请求的起始序号）。
  void Function(int fromSeq)? onSyncRequest;

  final List<Uint8List> writes = [];

  List<int> get commands => [for (final frame in writes) frame[0]];

  int get lastCommitValue =>
      ByteData.sublistView(writes.lastWhere((f) => f[0] == BleCommand.commit))
          .getUint32(1, Endian.little);

  int ackCount(int seq) => writes
      .where((frame) =>
          frame[0] == BleCommand.ack &&
          ByteData.sublistView(frame).getUint32(1, Endian.little) == seq)
      .length;

  void emitRecord(BleReadingRecord record) => _sensor.add(record.toBytes());

  void emitRaw(Uint8List frame) => _sensor.add(frame);

  void emitStatus(int command, int payload) {
    final frame = Uint8List(5);
    final data = ByteData.sublistView(frame);
    data.setUint8(0, command);
    data.setUint32(1, payload, Endian.little);
    _status.add(frame);
  }

  @override
  Stream<List<BleDevice>> scan({Duration timeout = const Duration(seconds: 15)}) =>
      Stream<List<BleDevice>>.empty();

  @override
  Future<void> stopScan() async {}

  @override
  Stream<BleConnectionStatus> get connectionStatus => _connection.stream;

  @override
  Future<void> connect(String deviceId) async {
    _connection.add(BleConnectionStatus.connected);
  }

  @override
  Future<void> disconnect() async {
    _connection.add(BleConnectionStatus.disconnected);
  }

  @override
  Future<BleDeviceInfo?> readDeviceInfo() async => null;

  @override
  Stream<Uint8List> get sensorData => _sensor.stream;

  @override
  Stream<Uint8List> get status => _status.stream;

  @override
  Future<void> writeControl(Uint8List frame) async {
    writes.add(frame);
    if (frame[0] == BleCommand.syncRequest) {
      onSyncRequest?.call(ByteData.sublistView(frame).getUint32(1, Endian.little));
    }
  }

  @override
  Future<void> dispose() async {
    await _sensor.close();
    await _status.close();
    await _connection.close();
  }
}

BleReadingRecord _record(int seq) => BleReadingRecord(
      seq: seq,
      timestamp: 1700000000,
      temperatureC: 36.5,
      ph: 6.9,
      od: 1.2,
      batteryMv: 4000,
    );
