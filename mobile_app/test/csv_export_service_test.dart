import 'package:fermenter_app/models/sensor_reading.dart';
import 'package:fermenter_app/services/csv_export_service.dart';
import 'package:flutter_test/flutter_test.dart';

SensorReading reading({
  int seq = 0,
  int simSeconds = 0,
  double temp = 30,
  double ph = 7,
  double od = 0.5,
  String source = 'sim',
  String? note,
}) =>
    SensorReading(
      id: 0,
      projectId: 1,
      seq: seq,
      simSeconds: simSeconds,
      recordedAt: DateTime.utc(2026, 1, 1, 8),
      temperatureC: temp,
      ph: ph,
      od: od,
      note: note,
      source: source,
    );

void main() {
  test('CSV keeps all columns, quotes text and BOM', () {
    final csv = CsvExportService.encode('Batch A', [
      reading(note: '=SUM(1,1)', source: 'manual'),
      reading(seq: 1, simSeconds: 120, od: 1.2345, temp: 31.55),
    ]);
    expect(csv.startsWith('\uFEFF'), isTrue);
    expect(csv, contains('"project","Batch A"'));
    expect(csv, contains('"0","0"'));
    expect(csv, contains('"30.00","7.00","0.500","manual","\'=SUM(1,1)"'));
    expect(csv, contains('"1","120"'));
    expect(csv, contains('"1.2345"'));
  });

  test('empty readings still export a header', () {
    final csv = CsvExportService.encode('Empty', const []);
    expect(csv, contains('"project","Empty"'));
    expect(csv, contains('"seq"'));
    expect(csv.split('\r\n').length, 3); // project 行 + header + 终止换行
  });
}