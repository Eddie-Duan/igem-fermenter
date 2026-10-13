/// 与 ESP32-S3 之间的 BLE 协议：UUID、20 字节读数记录、控制帧、状态帧。
///
/// 本文件是纯 Dart（不依赖任何 BLE 库），可以直接单测。
/// 协议正文见 `docs/ble-gatt.md` 与 `docs/ble-data-format.md`，
/// 设备端实现在 `firmware/esp32-s3/`。三处必须保持一致。
library;

import 'dart:typed_data';

import '../models/control_state.dart';

/// 服务与特征 UUID。
class BleUuids {
  const BleUuids._();

  static const String service = '4fafc201-1fb5-459e-8fcc-c5c9c331914b';

  /// Read：固件版本、MAC、电池、日志容量。
  static const String deviceInfo = '0000a101-0000-1000-8000-00805f9b34fb';

  /// Notify：一条 20 字节读数记录。
  static const String sensorData = '0000a102-0000-1000-8000-00805f9b34fb';

  /// Write With Response：同步与控制指令。
  static const String syncControl = '0000a103-0000-1000-8000-00805f9b34fb';

  /// Notify：同步结束、存储状态、错误。
  static const String syncStatus = '0000a104-0000-1000-8000-00805f9b34fb';
}

/// 记录格式常量。
class BleRecordFormat {
  const BleRecordFormat._();

  /// 每条记录帧的固定长度（正好一次默认 MTU 的 Notify）。
  static const int length = 20;

  /// 帧头标识。
  static const int magic = 0xA5;

  /// 当前数据格式版本。
  static const int version = 0x01;
}

/// 手机 → 设备的控制指令（写入 SyncControl）。
class BleCommand {
  const BleCommand._();

  /// `0x01 + last_seq(u32)`：请求该序号之后的记录。
  static const int syncRequest = 0x01;

  /// `0x02 + seq(u32)`：该条已校验并落库。
  static const int ack = 0x02;

  /// `0x03 + timestamp(u32)`：校准设备时钟。
  static const int setTime = 0x03;

  /// `0x04 + last_seq(u32)`：允许回收该序号及以前的记录。
  static const int commit = 0x04;

  /// `0x10 + flags(u8) + rpm(u16) + target_c_x10(u16)`：搅拌/加热控制。
  static const int setControl = 0x10;
}

/// 设备 → 手机的状态通知（来自 SyncStatus）。
class BleStatus {
  const BleStatus._();

  /// `0x81 + next_seq(u32)`：flash 日志已发完。
  static const int syncEnd = 0x81;

  /// `0x82 + code(u8)`。
  static const int error = 0x82;

  /// `0x84 + oldest_seq(u32) + count(u32)`：flash 里现存记录的区间。
  static const int logStatus = 0x84;
}

/// 设备返回的错误码。
enum BleErrorCode {
  invalidArgument(0x01, '设备拒绝了该指令的参数'),
  badFrame(0x02, '设备收到长度或 CRC 不对的帧'),
  flashFailure(0x03, '设备写 flash 失败'),
  badSequence(0x04, '请求的序号超出范围'),
  unknown(0x00, '设备返回了未知错误');

  const BleErrorCode(this.code, this.message);

  final int code;
  final String message;

  static BleErrorCode fromCode(int code) => BleErrorCode.values.firstWhere(
        (value) => value.code == code,
        orElse: () => BleErrorCode.unknown,
      );
}

/// CRC-16/CCITT-FALSE：多项式 `0x1021`，初值 `0xFFFF`，不反转、不异或。
///
/// `"123456789"` 的结果是 `0x29B1`（单测里锁死这个参考值）。
int crc16Ccitt(List<int> bytes, [int start = 0, int? end]) {
  final last = end ?? bytes.length;
  var crc = 0xFFFF;
  for (var i = start; i < last; i++) {
    crc ^= (bytes[i] & 0xFF) << 8;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 0x8000) != 0
          ? ((crc << 1) ^ 0x1021) & 0xFFFF
          : (crc << 1) & 0xFFFF;
    }
  }
  return crc & 0xFFFF;
}

/// 一条设备读数记录（20 字节）。
///
/// 定点整数存储：温度 ×100、pH ×100、OD ×1000。
class BleReadingRecord {
  const BleReadingRecord({
    required this.seq,
    required this.timestamp,
    required this.temperatureC,
    required this.ph,
    required this.od,
    this.batteryMv = 0,
  });

  final int seq;

  /// Unix 秒；设备未校时时为 0。
  final int timestamp;

  final double temperatureC;
  final double ph;
  final double od;
  final int batteryMv;

  /// 编码成 20 字节（含 CRC）。
  Uint8List toBytes() {
    final frame = Uint8List(BleRecordFormat.length);
    final data = ByteData.sublistView(frame);
    data.setUint8(0, BleRecordFormat.magic);
    data.setUint8(1, BleRecordFormat.version);
    data.setUint32(2, seq & 0xFFFFFFFF, Endian.little);
    data.setUint32(6, timestamp & 0xFFFFFFFF, Endian.little);
    data.setInt16(10, _fixed(temperatureC, 100), Endian.little);
    data.setInt16(12, _fixed(ph, 100), Endian.little);
    data.setInt16(14, _fixed(od, 1000), Endian.little);
    data.setUint16(16, batteryMv.clamp(0, 0xFFFF).toInt(), Endian.little);
    data.setUint16(18, crc16Ccitt(frame, 0, 18), Endian.little);
    return frame;
  }

  /// 解码并校验；长度、magic、版本或 CRC 任何一项不对就抛 [FormatException]。
  factory BleReadingRecord.fromBytes(List<int> bytes) {
    if (bytes.length != BleRecordFormat.length) {
      throw FormatException(
          'record must be ${BleRecordFormat.length} bytes, got ${bytes.length}');
    }
    final frame = Uint8List.fromList(bytes);
    final data = ByteData.sublistView(frame);
    if (data.getUint8(0) != BleRecordFormat.magic) {
      throw const FormatException('bad record magic');
    }
    if (data.getUint8(1) != BleRecordFormat.version) {
      throw FormatException('unsupported record version ${data.getUint8(1)}');
    }
    final expected = data.getUint16(18, Endian.little);
    final actual = crc16Ccitt(frame, 0, 18);
    if (expected != actual) {
      throw FormatException(
          'record CRC mismatch: got 0x${expected.toRadixString(16)}, '
          'computed 0x${actual.toRadixString(16)}');
    }
    return BleReadingRecord(
      seq: data.getUint32(2, Endian.little),
      timestamp: data.getUint32(6, Endian.little),
      temperatureC: data.getInt16(10, Endian.little) / 100,
      ph: data.getInt16(12, Endian.little) / 100,
      od: data.getInt16(14, Endian.little) / 1000,
      batteryMv: data.getUint16(16, Endian.little),
    );
  }

  /// 定点化并夹到 int16 范围内（超量程的数据宁可饱和也不要静默回绕）。
  static int _fixed(double value, int scale) =>
      (value * scale).round().clamp(-32768, 32767).toInt();

  @override
  String toString() => 'BleReadingRecord(seq: $seq, t: $temperatureC °C, '
      'pH: $ph, OD: $od, battery: $batteryMv mV)';
}

/// 控制帧编码。
class BleFrames {
  const BleFrames._();

  /// `0x01 + last_seq`：只要该序号之后的记录。
  static Uint8List syncRequest(int lastSeq) => _withUint32(BleCommand.syncRequest, lastSeq);

  /// `0x02 + seq`：确认某条记录已落库。
  static Uint8List ack(int seq) => _withUint32(BleCommand.ack, seq);

  /// `0x03 + timestamp`：校准设备时钟。
  static Uint8List setTime(DateTime now) =>
      _withUint32(BleCommand.setTime, now.toUtc().millisecondsSinceEpoch ~/ 1000);

  /// `0x04 + last_seq`：允许设备回收该序号及以前的记录。
  static Uint8List commit(int lastSeq) => _withUint32(BleCommand.commit, lastSeq);

  /// `0x10 + flags + rpm + target_c_x10`。
  static Uint8List setControl(ControlState control) {
    final frame = Uint8List(6);
    final data = ByteData.sublistView(frame);
    data.setUint8(0, BleCommand.setControl);
    data.setUint8(1, (control.stirrerOn ? 1 : 0) | (control.heaterOn ? 2 : 0));
    data.setUint16(2, control.stirrerRpm.clamp(0, 0xFFFF).toInt(), Endian.little);
    data.setUint16(4, (control.targetTempC * 10).round().clamp(0, 0xFFFF).toInt(),
        Endian.little);
    return frame;
  }

  static Uint8List _withUint32(int command, int value) {
    final frame = Uint8List(5);
    final data = ByteData.sublistView(frame);
    data.setUint8(0, command);
    data.setUint32(1, value & 0xFFFFFFFF, Endian.little);
    return frame;
  }
}

/// 设备状态通知。
sealed class BleStatusMessage {
  const BleStatusMessage();

  static BleStatusMessage fromBytes(List<int> bytes) {
    if (bytes.isEmpty) throw const FormatException('empty status frame');
    final frame = Uint8List.fromList(bytes);
    final data = ByteData.sublistView(frame);
    switch (data.getUint8(0)) {
      case BleStatus.syncEnd:
        _require(frame, 5);
        return BleSyncEnd(data.getUint32(1, Endian.little));
      case BleStatus.error:
        _require(frame, 2);
        return BleDeviceError(BleErrorCode.fromCode(data.getUint8(1)));
      case BleStatus.logStatus:
        _require(frame, 9);
        return BleLogStatus(
          oldestSeq: data.getUint32(1, Endian.little),
          count: data.getUint32(5, Endian.little),
        );
      default:
        throw FormatException(
            'unknown status frame 0x${data.getUint8(0).toRadixString(16)}');
    }
  }

  static void _require(Uint8List frame, int length) {
    if (frame.length < length) {
      throw FormatException(
          'status frame too short: ${frame.length} < $length');
    }
  }
}

/// flash 日志发完了，`nextSeq` 是设备下一条待发的序号。
final class BleSyncEnd extends BleStatusMessage {
  const BleSyncEnd(this.nextSeq);
  final int nextSeq;
}

/// 设备上报了错误。
final class BleDeviceError extends BleStatusMessage {
  const BleDeviceError(this.code);
  final BleErrorCode code;
  String get message => code.message;
}

/// 设备 flash 里的记录区间。
final class BleLogStatus extends BleStatusMessage {
  const BleLogStatus({required this.oldestSeq, required this.count});
  final int oldestSeq;
  final int count;
}

/// DeviceInfo 特征（16 字节）。
class BleDeviceInfo {
  const BleDeviceInfo({
    required this.firmwareVersion,
    required this.mac,
    required this.batteryMv,
    required this.logCapacity,
  });

  static const int length = 16;

  /// 形如 `0x00010000` 表示 1.0.0。
  final int firmwareVersion;
  final String mac;
  final int batteryMv;

  /// flash 日志最多能存多少条记录。
  final int logCapacity;

  String get firmwareLabel {
    final major = (firmwareVersion >> 16) & 0xFF;
    final minor = (firmwareVersion >> 8) & 0xFF;
    final patch = firmwareVersion & 0xFF;
    return '$major.$minor.$patch';
  }

  static BleDeviceInfo? fromBytes(List<int> bytes) {
    if (bytes.length < length) return null;
    final frame = Uint8List.fromList(bytes);
    final data = ByteData.sublistView(frame);
    final mac = [
      for (var i = 4; i < 10; i++) data.getUint8(i).toRadixString(16).padLeft(2, '0'),
    ].join(':').toUpperCase();
    return BleDeviceInfo(
      firmwareVersion: data.getUint32(0, Endian.little),
      mac: mac,
      batteryMv: data.getUint16(10, Endian.little),
      logCapacity: data.getUint32(12, Endian.little),
    );
  }

  @override
  String toString() =>
      'BleDeviceInfo(fw: $firmwareLabel, mac: $mac, battery: $batteryMv mV, '
      'capacity: $logCapacity)';
}
