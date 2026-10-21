import 'package:flutter_test/flutter_test.dart';

import 'package:fermenter_app/device/device_client.dart';

void main() {
  group('DeviceStatus', () {
    test('parses the firmware status payload', () {
      const status = DeviceStatus({
        'apiVersion': 1,
        'firmware': '1.2.3',
        'deviceId': 'AABBCCDDEEFF',
        'logCapacity': 2000,
        'logReady': true,
        'oldestSeq': 12,
        'nextSeq': 30,
        'recordCount': 18,
        'sampleIntervalS': 120,
        'stirrerSupported': true,
        'stirrerOn': false,
        'stirrerRpm': 0,
        'heaterEnabled': true,
        'heaterOn': false,
        'targetTempC': 31.5,
        'tempC': 30.4,
        'ph': 7.1,
        'odProxy': 0.123,
        'alarm': false,
        'staIp': '192.168.1.42',
        'apIp': '192.168.4.1',
      });

      expect(status.supportsSync, isTrue);
      expect(status.firmwareLabel, '1.2.3');
      expect(status.firmwareVersion, 0x00010203);
      expect(status.deviceId, 'AABBCCDDEEFF');
      expect(status.oldestSeq, 12);
      expect(status.nextSeq, 30);
      expect(status.recordCount, 18);
      expect(status.sampleIntervalS, 120);
      expect(status.stirrerSupported, isTrue);
      expect(status.heaterEnabled, isTrue);
      expect(status.targetTempC, closeTo(31.5, 0.001));
      expect(status.temperatureC, closeTo(30.4, 0.001));
      expect(status.stationIp, '192.168.1.42');
    });

    test('an old firmware without apiVersion cannot sync', () {
      const status = DeviceStatus({'firmware': '1.0.0'});
      expect(status.apiVersion, 0);
      expect(status.supportsSync, isFalse);
    });

    test('missing numeric fields fall back to zero instead of throwing', () {
      const status = DeviceStatus({});
      expect(status.oldestSeq, 0);
      expect(status.recordCount, 0);
      expect(status.firmwareLabel, '—');
      expect(status.targetTempC, 0);
    });
  });

  group('DeviceReadingsPage', () {
    test('decodes records and keeps pagination metadata', () {
      final page = DeviceReadingsPage.fromJson({
        'oldest': 4,
        'next': 6,
        'count': 2,
        'since': 4,
        'returned': 2,
        'hasMore': false,
        'records': [
          {
            'seq': 4,
            'timestamp': 1700000000,
            'tempC': 30.25,
            'ph': 7.05,
            'od': 0.456,
            'batteryMv': 0,
          },
          {
            'seq': 5,
            'timestamp': 0,
            'tempC': 30.5,
            'ph': 7.1,
            'od': 0.5,
          },
        ],
      });

      expect(page.oldest, 4);
      expect(page.next, 6);
      expect(page.since, 4);
      expect(page.records.map((r) => r.seq), [4, 5]);
      expect(page.records.first.timestamp, 1700000000);
      expect(page.records.first.temperatureC, closeTo(30.25, 0.001));
      expect(page.records.last.timestamp, 0);
    });

    test('rejects a response without a records array', () {
      expect(
        () => DeviceReadingsPage.fromJson({'next': 3}),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects a record without a seq', () {
      expect(
        () => DeviceReadingsPage.fromJson({
          'records': [
            {'tempC': 30}
          ],
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
