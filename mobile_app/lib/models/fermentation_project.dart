/// 批次状态机。
/// active: 仿真/运行中（可产生数据）
/// paused: 暂停（不再产生数据，控制保留）
/// harvest: 浊度已快速下降，检测到"收蛋白"信号
/// finished: 已人工结束，只读
enum FermenterStatus {
  active('Active'),
  paused('Paused'),
  harvest('Harvest time'),
  finished('Finished');

  const FermenterStatus(this.label);
  final String label;

  int get dbValue => index;

  static FermenterStatus fromDb(int value) =>
      FermenterStatus.values[value.clamp(0, FermenterStatus.values.length - 1)];
}

/// 一个发酵批次项目。控制状态（搅拌/加热）作为列直接存在项目表里，
/// 这样即使 App 被杀死，设备侧状态也能恢复。
class FermentationProject {
  const FermentationProject({
    required this.id,
    required this.name,
    required this.targetTempC,
    required this.status,
    required this.timeScale,
    required this.simSeconds,
    required this.createdAt,
    required this.updatedAt,
    this.strain,
    this.note,
    this.stirrerOn = false,
    this.stirrerRpm = 200,
    this.heaterOn = false,
    this.peakOd,
    this.harvestAtSeconds,
    this.lastTemperatureC,
    this.lastPh,
    this.lastOd,
  });

  final int id;
  final String name;
  final String? strain;
  final String? note;
  final double targetTempC;
  final FermenterStatus status;

  /// 每 1 个真实秒 = [timeScale] 个仿真秒（默认 60）。
  final int timeScale;

  /// 仿真经过的总秒数（实验时间轴）。
  final int simSeconds;

  final DateTime createdAt;
  final DateTime updatedAt;

  // -- 控制状态 --
  final bool stirrerOn;
  final int stirrerRpm; // 100–300 rpm
  final bool heaterOn;

  // -- 收获检测记录 --
  final double? peakOd;
  final int? harvestAtSeconds; // simSeconds 时刻触发收获

  // -- 最近一次读数（首页卡片展示用，避免为每个批次整体加载读数） --
  final double? lastTemperatureC;
  final double? lastPh;
  final double? lastOd;

  bool get isRunning =>
      status == FermenterStatus.active || status == FermenterStatus.harvest;

  /// 仿真经过的小时数（图表 X 轴用）。
  double get simHours => simSeconds / 3600;

  FermentationProject copyWith({
    String? name,
    String? strain,
    String? note,
    double? targetTempC,
    FermenterStatus? status,
    int? timeScale,
    int? simSeconds,
    DateTime? updatedAt,
    bool? stirrerOn,
    int? stirrerRpm,
    bool? heaterOn,
    double? Function()? peakOd,
    int? Function()? harvestAtSeconds,
    double? lastTemperatureC,
    double? lastPh,
    double? lastOd,
  }) =>
      FermentationProject(
        id: id,
        name: name ?? this.name,
        strain: strain ?? this.strain,
        note: note ?? this.note,
        targetTempC: targetTempC ?? this.targetTempC,
        status: status ?? this.status,
        timeScale: timeScale ?? this.timeScale,
        simSeconds: simSeconds ?? this.simSeconds,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        stirrerOn: stirrerOn ?? this.stirrerOn,
        stirrerRpm: stirrerRpm ?? this.stirrerRpm,
        heaterOn: heaterOn ?? this.heaterOn,
        peakOd: peakOd != null ? peakOd() : this.peakOd,
        harvestAtSeconds:
            harvestAtSeconds != null ? harvestAtSeconds() : this.harvestAtSeconds,
        lastTemperatureC: lastTemperatureC ?? this.lastTemperatureC,
        lastPh: lastPh ?? this.lastPh,
        lastOd: lastOd ?? this.lastOd,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'strain': strain,
        'note': note,
        'target_temp_c': targetTempC,
        'status': status.dbValue,
        'time_scale': timeScale,
        'sim_seconds': simSeconds,
        'stirrer_on': stirrerOn ? 1 : 0,
        'stirrer_rpm': stirrerRpm,
        'heater_on': heaterOn ? 1 : 0,
        'peak_od': peakOd,
        'harvest_at_seconds': harvestAtSeconds,
        'last_temp_c': lastTemperatureC,
        'last_ph': lastPh,
        'last_od': lastOd,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  factory FermentationProject.fromMap(Map<String, Object?> row) =>
      FermentationProject(
        id: row['id'] as int,
        name: row['name'] as String,
        strain: row['strain'] as String?,
        note: row['note'] as String?,
        targetTempC: (row['target_temp_c'] as num).toDouble(),
        status: FermenterStatus.fromDb(row['status'] as int),
        timeScale: row['time_scale'] as int,
        simSeconds: row['sim_seconds'] as int,
        stirrerOn: (row['stirrer_on'] as int) != 0,
        stirrerRpm: row['stirrer_rpm'] as int,
        heaterOn: (row['heater_on'] as int) != 0,
        peakOd: (row['peak_od'] as num?)?.toDouble(),
        harvestAtSeconds: row['harvest_at_seconds'] as int?,
        lastTemperatureC: (row['last_temp_c'] as num?)?.toDouble(),
        lastPh: (row['last_ph'] as num?)?.toDouble(),
        lastOd: (row['last_od'] as num?)?.toDouble(),
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
        updatedAt:
            DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
      );
}