import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/sensor_reading.dart';

class CsvExportService {
  /// 与历史列表一致地导出全部原始字段，便于后续直接进统计工具。
  static String encode(
      String projectName, Iterable<SensorReading> readings) {
    const header = [
      'seq',
      'sim_seconds',
      'recorded_at_utc',
      'recorded_at_local',
      'temperature_c',
      'ph',
      'od600',
      'source',
      'note',
    ];
    final rows = <List<Object?>>[
      ['project', _safeText(projectName)],
      header,
      for (final reading in readings)
        [
          reading.seq,
          reading.simSeconds,
          reading.recordedAt.toUtc().toIso8601String(),
          reading.recordedAt.toLocal().toIso8601String(),
          _fmt(reading.temperatureC, 2),
          _fmt(reading.ph, 2),
          _fmt(reading.od, 3),
          reading.source,
          _safeText(reading.note ?? ''),
        ],
    ];
    return '\uFEFF${rows.map((row) => row.map(_cell).join(',')).join('\r\n')}\r\n';
  }

  static String _fmt(double value, int digits) =>
      value.toStringAsFixed(digits);
  static String _cell(Object? value) =>
      '"${(value ?? '').toString().replaceAll('"', '""')}"';
  static String _safeText(String value) =>
      RegExp(r'^\s*[=+@\-\t\r\n]').hasMatch(value) ? "'$value" : value;

  Future<void> share({
    required String projectName,
    required List<SensorReading> readings,
    required Rect origin,
  }) async {
    if (readings.isEmpty) throw StateError('No readings to export');
    final directory = await getTemporaryDirectory();
    final name =
        '${_sanitize(projectName)}_${DateTime.now().microsecondsSinceEpoch}.csv';
    final file = File(p.join(directory.path, name));
    await file.writeAsBytes(utf8.encode(encode(projectName, readings)),
        flush: true);
    // 分享完成前保留临时文件（接收方可延迟读取）。
    await Share.shareXFiles([XFile(file.path, mimeType: 'text/csv')],
        subject: 'Fermentation: $projectName', sharePositionOrigin: origin);
  }

  static String _sanitize(String value) =>
      value.replaceAll(RegExp(r'[^\w\-]'), '_').isEmpty
          ? 'fermentation'
          : value.replaceAll(RegExp(r'[^\w\-]'), '_');
}