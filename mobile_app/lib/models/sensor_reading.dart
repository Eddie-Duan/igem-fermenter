/// 单条读数：温度、pH、浊度(OD)。
class SensorReading {
  const SensorReading({
    required this.id,
    required this.projectId,
    required this.seq,
    required this.simSeconds,
    required this.recordedAt,
    required this.temperatureC,
    required this.ph,
    required this.od,
    this.note,
    this.source = 'sim',
  });

  final int id;
  final int projectId;
  final int seq; // 批次的顺序号，保证绘制时按序
  final int simSeconds; // 仿真时间轴
  final DateTime recordedAt; // 本地时间
  final double temperatureC;
  final double ph;
  final double od; // OD600 / 浊度
  final String? note;

  /// 'sim' = 仿真设备产生；'manual' = 手动录入。
  final String source;

  double get simHours => simSeconds / 3600;

  bool samePayload(SensorReading other) =>
      projectId == other.projectId &&
      seq == other.seq &&
      simSeconds == other.simSeconds &&
      temperatureC == other.temperatureC &&
      ph == other.ph &&
      od == other.od &&
      note == other.note &&
      source == other.source;

  Map<String, Object?> toMap() => {
        'id': id,
        'project_id': projectId,
        'seq': seq,
        'sim_seconds': simSeconds,
        'recorded_at': recordedAt.millisecondsSinceEpoch,
        'temperature_c': temperatureC,
        'ph': ph,
        'od': od,
        'note': note,
        'source': source,
      };

  factory SensorReading.fromMap(Map<String, Object?> row) => SensorReading(
        id: row['id'] as int,
        projectId: row['project_id'] as int,
        seq: row['seq'] as int,
        simSeconds: row['sim_seconds'] as int,
        recordedAt:
            DateTime.fromMillisecondsSinceEpoch(row['recorded_at'] as int),
        temperatureC: (row['temperature_c'] as num).toDouble(),
        ph: (row['ph'] as num).toDouble(),
        od: (row['od'] as num).toDouble(),
        note: row['note'] as String?,
        source: row['source'] as String? ?? 'sim',
      );
}