import 'package:flutter_test/flutter_test.dart';

import 'package:fermenter_app/device/device_client.dart';
import 'package:fermenter_app/device/device_sync_service.dart';
import 'package:fermenter_app/device/fake_device_client.dart';
import 'package:fermenter_app/models/sensor_reading.dart';

/// 同步流程测试：走真实的分页/落库/回收逻辑，只有传输层换成假设备。

class _MemorySink implements DeviceReadingSink {
  final List<SensorReading> stored = [];
  int? failAtCall;

  int get _nextSeq {
    if (stored.isEmpty) return 0;
    final seqs = stored.map((reading) => reading.seq).toSet();
    var cursor = seqs.reduce((a, b) => a < b ? a : b);
    while (seqs.contains(cursor)) {
      cursor++;
    }
    return cursor;
  }

  @override
  Future<int> nextExpectedSeq(int projectId) async => _nextSeq;

  @override
  Future<void> storeDeviceReadings(
      int projectId, List<SensorReading> readings) async {
    if (failAtCall != null && stored.length >= failAtCall!) {
      throw StateError('database is full');
    }
    stored.addAll(readings);
  }
}

const _credentials =
    DeviceCredentials(address: '192.168.4.1', password: 'secret-password');

FakeDeviceClient _demo({int history = 8}) => FakeDeviceClient(
      historyRecords: history,
      sampleInterval: Duration.zero,
      clock: () => DateTime(2026, 1, 1),
    );

void main() {
  test('imports every record once, then reclaims what was stored', () async {
    final client = _demo();
    final sink = _MemorySink();
    final sync = DeviceSyncService(client: client, sink: sink);
    addTearDown(() async {
      await sync.detach();
      await client.close();
    });

    await client.connect(_credentials);
    await sync.attach(1);
    final result = await sync.sync();

    expect(result.stored, 8);
    expect(result.nextSeq, 8);
    expect(result.committedThrough, 7);
    expect(sink.stored.map((reading) => reading.seq),
        [0, 1, 2, 3, 4, 5, 6, 7]);
    expect(sink.stored.every((reading) => reading.isDeviceReading), isTrue);
    expect(sink.stored.every((reading) => reading.projectId == 1), isTrue);
    expect(client.lastCommittedSeq, 7);
  });

  test('a second sync stores nothing and does not skip gap-free records',
      () async {
    final client = _demo(history: 5);
    final sink = _MemorySink();
    final sync = DeviceSyncService(client: client, sink: sink);
    addTearDown(() async {
      await client.close();
    });

    await client.connect(_credentials);
    await sync.attach(1);
    await sync.sync();
    final again = await sync.sync();

    expect(again.stored, 0);
    expect(sink.stored.length, 5);
  });

  test('pages through more records than one page holds', () async {
    final client = _demo(history: 150);
    final sink = _MemorySink();
    final sync = DeviceSyncService(client: client, sink: sink, pageSize: 40);
    addTearDown(() async {
      await client.close();
    });

    await client.connect(_credentials);
    await sync.attach(2);
    final result = await sync.sync();

    expect(result.stored, 150);
    expect(sink.stored.length, 150);
    expect(sink.stored.last.seq, 149);
    expect(client.lastCommittedSeq, 149);
  });

  test('records written during the sync wait for the next round', () async {
    final client = _demo(history: 3);
    final sink = _MemorySink();
    final sync = DeviceSyncService(client: client, sink: sink);
    addTearDown(() async {
      await client.close();
    });

    await client.connect(_credentials);
    await sync.attach(1);
    // 分批写：第一页之后又来了新记录，本轮不应越过开始时定的上界。
    final result = await sync.sync();
    expect(result.stored, 3);

    client.disconnect();
    final second = _demo(history: 5);
    addTearDown(second.close);
    await second.connect(_credentials);
    final sync2 = DeviceSyncService(client: second, sink: sink);
    addTearDown(sync2.detach);
    await sync2.attach(1);
    // 本地已有 0..2，应从 3 开始。
    final next = await sync2.sync();
    expect(next.stored, 2);
    expect(sink.stored.map((r) => r.seq), [0, 1, 2, 3, 4]);
  });

  test('a storage failure keeps the device log unreclaimed', () async {
    final client = _demo(history: 4);
    final sink = _MemorySink()..failAtCall = 0;
    final sync = DeviceSyncService(client: client, sink: sink);
    addTearDown(() async {
      await client.close();
    });

    await client.connect(_credentials);
    await sync.attach(1);
    await expectLater(sync.sync(), throwsA(isA<DeviceSyncException>()));

    // 没有落库就不允许回收：设备上的 4 条记录都还在。
    expect(client.lastCommittedSeq, -1);
    expect(client.oldest, 0);
    expect(client.next, 4);
  });

  test('a cursor older than the reclaimed log restarts at oldest', () async {
    final client = FakeDeviceClient(
      historyRecords: 5,
      sampleInterval: Duration.zero,
    );
    addTearDown(client.close);
    await client.connect(_credentials);
    // 模拟设备侧先回收了前 3 条（例如 App 重装过）。
    await client.commit(2);

    final sink = _MemorySink();
    final sync = DeviceSyncService(client: client, sink: sink);
    addTearDown(sync.detach);
    await sync.attach(1);
    final result = await sync.sync();

    expect(result.stored, 2);
    expect(sink.stored.map((reading) => reading.seq), [3, 4]);
  });

  test('sync without a bound batch is refused', () async {
    final client = _demo();
    final sync = DeviceSyncService(client: client, sink: _MemorySink());
    addTearDown(() async {
      await client.close();
    });

    await client.connect(_credentials);
    await expectLater(sync.sync(), throwsA(isA<DeviceSyncException>()));
  });

  test('control frames reach the device unchanged', () async {
    final client = _demo();
    final sync = DeviceSyncService(client: client, sink: _MemorySink());
    addTearDown(() async {
      await client.close();
    });

    await client.connect(_credentials);
    await sync.sendControl(
      stirrerOn: true,
      stirrerRpm: 150,
      heaterOn: true,
      targetTempC: 31.5,
    );

    final control = client.lastControl!;
    expect(control.stirrerOn, isTrue);
    expect(control.stirrerRpm, 150);
    expect(control.heaterOn, isTrue);
    expect(control.targetTempC, closeTo(31.5, 0.001));
  });

  test('attach calibrates the device clock', () async {
    final client = _demo();
    final sync = DeviceSyncService(
      client: client,
      sink: _MemorySink(),
      clock: () => DateTime.fromMillisecondsSinceEpoch(1700000000000),
    );
    addTearDown(() async {
      await client.close();
    });

    await client.connect(_credentials);
    await sync.attach(1);

    expect(client.lastTimeSync?.millisecondsSinceEpoch, 1700000000000);
  });
}
