import 'dart:typed_data';

import 'package:fermenter_app/ble/ble_protocol.dart';
import 'package:fermenter_app/models/control_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// 协议编解码的"锁死"测试。
///
/// 这些字节固件端必须能原样解出来（`firmware/esp32-s3/components/ble`），
/// 所以这里断言的常量不是实现细节，而是**接口**：
/// 改动它们就等于改了协议，`docs/ble-gatt.md` 与固件要同步改。
void main() {
  group('CRC-16/CCITT-FALSE', () {
    test('matches the reference check value 0x29B1 for "123456789"', () {
      final ascii = '123456789'.codeUnits;
      expect(crc16Ccitt(ascii), 0x29B1);
    });

    test('honours start/end so it can cover a frame prefix', () {
      final bytes = Uint8List.fromList([0xFF, ...'123456789'.codeUnits, 0x00]);
      expect(crc16Ccitt(bytes, 1, 10), 0x29B1);
    });
  });

  group('BleReadingRecord', () {
    const record = BleReadingRecord(
      seq: 0x0000A1B2,
      timestamp: 0x65000000,
      temperatureC: 36.85,
      ph: 6.94,
      od: 1.234,
      batteryMv: 4020,
    );

    test('encodes the frozen 20-byte little-endian layout', () {
      final bytes = record.toBytes();
      expect(bytes.length, BleRecordFormat.length);
      expect(bytes[0], 0xA5);
      expect(bytes[1], 0x01);
      // seq / timestamp 小端。
      expect(bytes.sublist(2, 6), [0xB2, 0xA1, 0x00, 0x00]);
      expect(bytes.sublist(6, 10), [0x00, 0x00, 0x00, 0x65]);
      // 定点：温度 ×100、pH ×100、OD ×1000（int16 小端）。
      expect(bytes.sublist(10, 12), _int16(3685));
      expect(bytes.sublist(12, 14), _int16(694));
      expect(bytes.sublist(14, 16), _int16(1234));
      expect(bytes.sublist(16, 18), [0xB4, 0x0F]);
      // CRC 覆盖前 18 字节。
      expect(_uint16(bytes, 18), crc16Ccitt(bytes, 0, 18));
    });

    test('round-trips through decode', () {
      final decoded = BleReadingRecord.fromBytes(record.toBytes());
      expect(decoded.seq, record.seq);
      expect(decoded.timestamp, record.timestamp);
      expect(decoded.temperatureC, closeTo(record.temperatureC, 0.01));
      expect(decoded.ph, closeTo(record.ph, 0.01));
      expect(decoded.od, closeTo(record.od, 0.001));
      expect(decoded.batteryMv, record.batteryMv);
    });

    test('saturates instead of wrapping when a value is out of range', () {
      // 传感器抽风时宁可饱和，也不能让温度回绕成 -300 °C。
      final decoded = BleReadingRecord.fromBytes(
        const BleReadingRecord(
          seq: 1,
          timestamp: 0,
          temperatureC: 400,
          ph: 6.9,
          od: 1.0,
        ).toBytes(),
      );
      expect(decoded.temperatureC, 327.67);
    });

    test('rejects a wrong length, magic, version or CRC', () {
      final good = record.toBytes();

      expect(() => BleReadingRecord.fromBytes(good.sublist(0, 19)),
          throwsFormatException);

      final badMagic = Uint8List.fromList(good)..[0] = 0x5A;
      expect(() => BleReadingRecord.fromBytes(badMagic), throwsFormatException);

      final badVersion = Uint8List.fromList(good)..[1] = 0x02;
      expect(
          () => BleReadingRecord.fromBytes(badVersion), throwsFormatException);

      // 改一个数据位但不改 CRC：必须被校验挡住。
      final badCrc = Uint8List.fromList(good)..[12] = good[12] + 1;
      expect(() => BleReadingRecord.fromBytes(badCrc), throwsFormatException);
    });
  });

  group('BleFrames', () {
    test('sync request / ack / commit are command + little-endian u32', () {
      expect(BleFrames.syncRequest(7), [0x01, 7, 0, 0, 0]);
      expect(BleFrames.ack(300), [0x02, 0x2C, 0x01, 0, 0]);
      expect(BleFrames.commit(9), [0x04, 9, 0, 0, 0]);
    });

    test('set time carries the unix second count', () {
      final frame = BleFrames.setTime(DateTime.utc(2026, 1, 1));
      expect(frame.length, 5);
      expect(frame[0], 0x03);
      expect(ByteData.sublistView(frame).getUint32(1, Endian.little),
          DateTime.utc(2026, 1, 1).millisecondsSinceEpoch ~/ 1000);
    });

    test('set control packs flags, rpm and target temperature', () {
      final frame = BleFrames.setControl(const ControlState(
        stirrerOn: true,
        stirrerRpm: 240,
        heaterOn: true,
        targetTempC: 36.5,
      ));
      expect(frame, [0x10, 0x03, 0xF0, 0x00, 0x6D, 0x01]);

      // 只开搅拌：bit0 置位、bit1 清零。
      final stirOnly = BleFrames.setControl(const ControlState(
        stirrerOn: true,
        stirrerRpm: 200,
        heaterOn: false,
        targetTempC: 30,
      ));
      expect(stirOnly[1], 0x01);
      expect(ByteData.sublistView(stirOnly).getUint16(2, Endian.little), 200);
      expect(ByteData.sublistView(stirOnly).getUint16(4, Endian.little), 300);
    });
  });

  group('BleStatusMessage', () {
    test('decodes sync end', () {
      final frame = Uint8List.fromList([0x81, 0x2A, 0, 0, 0]);
      final message = BleStatusMessage.fromBytes(frame);
      expect(message, isA<BleSyncEnd>());
      expect((message as BleSyncEnd).nextSeq, 42);
    });

    test('decodes a device error into a known code', () {
      final message = BleStatusMessage.fromBytes([0x82, 0x03]);
      expect(message, isA<BleDeviceError>());
      expect((message as BleDeviceError).code, BleErrorCode.flashFailure);
      expect(message.message, isNotEmpty);
    });

    test('an unknown error code degrades instead of throwing', () {
      final message =
          BleStatusMessage.fromBytes([0x82, 0x7F]) as BleDeviceError;
      expect(message.code, BleErrorCode.unknown);
    });

    test('decodes the flash log window', () {
      final frame = Uint8List.fromList(
          [0x84, 0x0A, 0, 0, 0, 0x64, 0, 0, 0]);
      final message = BleStatusMessage.fromBytes(frame) as BleLogStatus;
      expect(message.oldestSeq, 10);
      expect(message.count, 100);
    });

    test('rejects empty, unknown and truncated frames', () {
      expect(() => BleStatusMessage.fromBytes(const []),
          throwsFormatException);
      expect(() => BleStatusMessage.fromBytes([0x99, 0, 0, 0, 0]),
          throwsFormatException);
      expect(() => BleStatusMessage.fromBytes([0x81, 0, 0]), throwsFormatException);
    });
  });

  group('BleDeviceInfo', () {
    test('decodes firmware version, mac and battery', () {
      final frame = Uint8List(16);
      final data = ByteData.sublistView(frame);
      data.setUint32(0, 0x00010203, Endian.little);
      for (var i = 0; i < 6; i++) {
        data.setUint8(4 + i, 0x11 * (i + 1));
      }
      data.setUint16(10, 4020, Endian.little);
      data.setUint32(12, 20000, Endian.little);

      final info = BleDeviceInfo.fromBytes(frame)!;
      expect(info.firmwareLabel, '1.2.3');
      expect(info.mac, '11:22:33:44:55:66');
      expect(info.batteryMv, 4020);
      expect(info.logCapacity, 20000);
    });

    test('short reads return null rather than garbage', () {
      expect(BleDeviceInfo.fromBytes(Uint8List(4)), isNull);
    });
  });
}

List<int> _int16(int value) {
  final bytes = Uint8List(2);
  ByteData.sublistView(bytes).setInt16(0, value, Endian.little);
  return bytes;
}

int _uint16(List<int> bytes, int offset) =>
    ByteData.sublistView(Uint8List.fromList(bytes)).getUint16(offset, Endian.little);
