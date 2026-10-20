import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../ble/ble_sync_service.dart';
import '../database/fermenter_repository.dart';
import '../models/control_state.dart';
import '../models/fermentation_project.dart';
import '../models/sensor_reading.dart';
import 'harvest_detector.dart';
import 'sensor_source.dart';
import 'simulated_sensor_source.dart';

/// 全局控制器：持有项目与读数、驱动仿真采样、维护收获检测结果。
///
/// 数据有两个来源，但落库、收获检测、统计和界面完全共用一条路径：
/// - 没有硬件（或批次未绑定设备）：[SimulatedSensorSource] 按本地时钟推进；
/// - 已绑定 ESP32-S3：读数由设备推送（[BleSyncService] 校验、
///   经 [storeDeviceReadings] 落库），本地仿真对该批次停止。
class FermenterController extends ChangeNotifier implements BleReadingSink {
  FermenterController({
    required this.repository,
    SensorSource Function(int projectId, SensorReading? last)? sourceBuilder,
    DateTime Function()? clock,
  })  : _sourceBuilder =
            sourceBuilder ?? _defaultSimSource,
        clock = clock ?? DateTime.now;

  /// 每两次仿真实采样之间间隔的仿真秒数（与硬件页的 5 s 采样一致）。
  static const int sampleIntervalSeconds = 5;

  /// 样例批次覆盖的仿真时长（20 小时 = 一个完整周期：增殖 → 峰值 → 裂解）。
  static const int sampleBatchSeconds = 20 * 3600;

  /// 设备时间轴：设备记录按 `seq × 采样周期` 换算成仿真秒。
  /// 与固件的采样周期（`firmware/esp32-s3` 的 `SAMPLE_INTERVAL_S`）必须一致。
  static const int deviceSampleIntervalSeconds = 120;

  /// 手动读数使用的序号起点。设备记录占 0…n，手动读数从这里往上走，
  /// 避免两条不同来源的读数撞号、被 BLE 同步的去重逻辑误判成重复包。
  static const int manualSeqBase = 1000000;

  final FermenterRepository repository;
  final DateTime Function() clock;
  final SensorSource Function(int projectId, SensorReading? last) _sourceBuilder;

  final Map<int, SensorSource> _sources = {};
  final Map<int, HarvestDetector> _detectors = {};
  final Map<int, int> _clockSeconds = {};
  final Map<int, int> _lastSampleSeconds = {};
  final Map<int, HarvestVerdict> _verdicts = {};
  final Map<int, List<SensorReading>> _readings = {};

  /// 已绑定 BLE 设备的批次 → 设备名。绑定期间该批次不再跑本地仿真。
  ///
  /// 只存在内存里：App 重启后需要重新连接设备（设备侧数据在 flash 上，
  /// 重新同步不会丢）。
  final Map<int, String> _deviceLabels = {};

  List<FermentationProject> projects = const [];
  int? _openProjectId;
  Timer? _timer;
  bool loading = false;
  String? error;
  var _disposed = false;
  var _revision = 0;

  static SimulatedSensorSource _defaultSimSource(
          int projectId, SensorReading? last) =>
      SimulatedSensorSource(
          initialTemperatureC: last?.temperatureC,
          initialPh: last?.ph,
          initialOd: last?.od);

  /// 当前打开查看的批次。
  FermentationProject? get openProject {
    final id = _openProjectId;
    if (id == null) return null;
    for (final project in projects) {
      if (project.id == id) return project;
    }
    return null;
  }

  List<SensorReading> get openReadings {
    final id = _openProjectId;
    if (id == null) return const [];
    return _readings[id] ?? const [];
  }

  HarvestVerdict? get openVerdict {
    final id = _openProjectId;
    return id == null ? null : _verdicts[id];
  }

  /// 该批次是否绑定到 ESP32-S3（绑定时不再由本地仿真产生读数）。
  bool isDeviceBound(int projectId) => _deviceLabels.containsKey(projectId);

  /// 绑定的设备名，未绑定时为 null。
  String? boundDeviceLabel(int projectId) => _deviceLabels[projectId];

  /// 把批次绑定到设备：停掉本地仿真，之后数据只从设备来。
  void bindDevice(int projectId, String deviceLabel) {
    if (_deviceLabels[projectId] == deviceLabel) return;
    _deviceLabels[projectId] = deviceLabel;
    // 丢掉仿真源：设备批次的时间轴不由本地时钟推进。
    _sources.remove(projectId);
    notifyListeners();
  }

  /// 解除绑定，回到本地仿真。设备侧未同步的数据仍在 flash 上，不会丢。
  void unbindDevice(int projectId) {
    if (_deviceLabels.remove(projectId) == null) return;
    _sources.remove(projectId);
    _clockSeconds.remove(projectId);
    _lastSampleSeconds.remove(projectId);
    notifyListeners();
  }

  // -- 生命周期 --

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      // 每秒 advance 一次；内部按 timeScale 决定是否产生新读数。
      unawaited(advanceSimulation());
    });
  }

  Future<void> advanceSimulation() async {
    for (final project in List<FermentationProject>.of(projects)) {
      if (!project.isRunning) continue;
      await _advanceProject(project);
    }
  }

  Future<void> _advanceProject(FermentationProject project) async {
    final id = project.id;
    // 设备批次：读数由设备推送，本地仿真不参与，否则会造出设备上并不存在的点。
    if (_deviceLabels.containsKey(id)) return;
    final readings = _readings[id] ??= <SensorReading>[];
    final nextSim =
        (_clockSeconds[id] ?? project.simSeconds) + project.timeScale;
    _clockSeconds[id] = nextSim;

    final lastSample = _lastSampleSeconds[id] ?? project.simSeconds;
    if (nextSim - lastSample < sampleIntervalSeconds) return;

    final source =
        _sources[id] ??= _sourceBuilder(id, readings.isEmpty ? null : readings.last);
    _lastSampleSeconds[id] = nextSim;
    final reading = source.poll(
      projectId: id,
      seq: readings.length,
      control: ControlState(
        stirrerOn: project.stirrerOn,
        stirrerRpm: project.stirrerRpm,
        heaterOn: project.heaterOn,
        targetTempC: project.targetTempC,
      ),
      simSeconds: nextSim,
      dtSeconds: nextSim - lastSample,
    );

    await repository.addReading(reading);
    readings.add(reading);

    final verdict = const HarvestDetector(
            sampleIntervalSeconds: sampleIntervalSeconds)
        .evaluate(readings.map((r) => r.od).toList(growable: false));
    _verdicts[id] = verdict;

    var updated = project.copyWith(
      simSeconds: nextSim,
      updatedAt: clock(),
      lastTemperatureC: reading.temperatureC,
      lastPh: reading.ph,
      lastOd: reading.od,
    );
    if (verdict.peakOd > (updated.peakOd ?? 0)) {
      updated = updated.copyWith(peakOd: () => verdict.peakOd);
    }
    if (verdict.triggered && updated.status == FermenterStatus.active) {
      updated = updated.copyWith(
        status: FermenterStatus.harvest,
        harvestAtSeconds: () => nextSim,
      );
    }

    _replaceProject(updated);
    await repository.updateProject(updated);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  // -- 数据加载 --

  Future<void> refresh() {
    if (_disposed) return Future.value();
    final revision = ++_revision;
    return _load(revision);
  }

  Future<void> _load(int revision) async {
    loading = true;
    notifyListeners();
    try {
      final list = await repository.listProjects();
      if (_disposed || revision != _revision) return;
      projects = list;
      final openId = _openProjectId;
      if (openId != null && list.any((p) => p.id == openId)) {
        await _loadReadings(openId, revision);
      } else {
        _openProjectId = null;
      }
      error = null;
    } catch (_) {
      if (_disposed || revision != _revision) return;
      error = 'Local data could not be read. Please try again.';
    } finally {
      if (!_disposed && revision == _revision) {
        loading = false;
        notifyListeners();
      }
    }
  }

  /// 选择要查看的批次（与只读 getter [openProject] 区分开）。
  Future<void> selectProject(int id) async {
    final revision = ++_revision;
    _openProjectId = id;
    await _load(revision);
  }

  Future<void> _loadReadings(int id, int revision) async {
    final rows = await repository.readings(id, ascending: true);
    if (_disposed || revision != _revision) return;
    _readings[id] = rows;
    _lastSampleSeconds[id] ??= rows.isEmpty ? 0 : rows.last.simSeconds;
    _clockSeconds[id] ??= rows.isEmpty ? 0 : rows.last.simSeconds;
    _sources[id] ??= _sourceBuilder(id, rows.isEmpty ? null : rows.last);
    _detectors.remove(id);
    _verdicts[id] = const HarvestDetector()
        .evaluate(rows.map((r) => r.od).toList(growable: false));
  }

  // -- 操作 --

  Future<void> createProject(ProjectDraft draft) async {
    if (draft.name.trim().isEmpty) {
      throw ArgumentError('Batch name is required');
    }
    final now = clock();
    final project = FermentationProject(
      id: 0,
      name: draft.name.trim(),
      strain: draft.strain,
      note: draft.note,
      targetTempC: draft.targetTempC,
      status: FermenterStatus.active,
      timeScale: draft.timeScale,
      simSeconds: 0,
      createdAt: now,
      updatedAt: now,
    );
    final id = await repository.createProject(project);
    _lastSampleSeconds[id] = 0;
    _clockSeconds[id] = 0;
    _readings[id] = [];
    _sources[id] = _sourceBuilder(id, null);
    _verdicts[id] = const HarvestDetector().evaluate(const []);
    await _load(++_revision);
    _openProjectId = id;
    notifyListeners();
  }

  /// 无硬件阶段的演示入口：直接生成一个已经跑完整个发酵周期的批次
  /// （600 条读数，增殖 → 峰值 → 裂解），让曲线、峰值/收获参考线、
  /// 收获告警、统计与 CSV 导出在没接设备时也能被检查。
  ///
  /// 历史结束在裂解期，状态落到 [FermenterStatus.harvest]；该状态仍在运行，
  /// 所以之后会按 timeScale 继续实时追加采样点。
  Future<int> loadSampleBatch() async {
    const targetTempC = 37.0;
    const control = ControlState(
      stirrerOn: true,
      stirrerRpm: 220,
      heaterOn: true,
      targetTempC: targetTempC,
    );
    final now = clock();

    final base = FermentationProject(
      id: 0,
      name: 'Sample batch (demo)',
      strain: 'E. coli BL21 — simulated run',
      note: 'Demo run created by "Load sample data": one complete fermentation '
          'cycle (growth → plateau → lysis) with no hardware connected.',
      targetTempC: targetTempC,
      status: FermenterStatus.active,
      // 每 1 个真实秒推进一个采样点，方便观察曲线实时延长。
      timeScale: sampleIntervalSeconds,
      simSeconds: 0,
      createdAt: now,
      updatedAt: now,
      stirrerOn: control.stirrerOn,
      stirrerRpm: control.stirrerRpm,
      heaterOn: control.heaterOn,
    );
    final id = await repository.createProject(base);

    final source = _sourceBuilder(id, null);
    final readings = <SensorReading>[];
    final ods = <double>[];
    var verdict = const HarvestDetector().evaluate(const []);
    int? harvestAtSeconds;
    for (var sim = sampleIntervalSeconds;
        sim <= sampleBatchSeconds;
        sim += sampleIntervalSeconds) {
      final reading = source.poll(
        projectId: id,
        seq: readings.length,
        control: control,
        simSeconds: sim,
        dtSeconds: sampleIntervalSeconds,
      );
      readings.add(reading);
      ods.add(reading.od);
      verdict = const HarvestDetector().evaluate(ods);
      if (harvestAtSeconds == null && verdict.triggered) {
        harvestAtSeconds = sim;
      }
    }
    await repository.addReadings(readings);

    final last = readings.last;
    final project = FermentationProject(
      id: id,
      name: base.name,
      strain: base.strain,
      note: base.note,
      targetTempC: base.targetTempC,
      status: harvestAtSeconds == null
          ? FermenterStatus.active
          : FermenterStatus.harvest,
      timeScale: base.timeScale,
      simSeconds: sampleBatchSeconds,
      createdAt: base.createdAt,
      updatedAt: clock(),
      stirrerOn: base.stirrerOn,
      stirrerRpm: base.stirrerRpm,
      heaterOn: base.heaterOn,
      peakOd: verdict.peakOd,
      harvestAtSeconds: harvestAtSeconds,
      lastTemperatureC: last.temperatureC,
      lastPh: last.ph,
      lastOd: last.od,
    );
    await repository.updateProject(project);

    _readings[id] = readings;
    _sources[id] = source;
    _clockSeconds[id] = sampleBatchSeconds;
    _lastSampleSeconds[id] = sampleBatchSeconds;
    _verdicts[id] = verdict;
    await _load(++_revision);
    _openProjectId = id;
    notifyListeners();
    return id;
  }

  Future<void> setControl(int id, ControlState control) async {
    final project = _projectById(id);
    if (project == null) return;
    final updated = project.copyWith(
      stirrerOn: control.stirrerOn,
      stirrerRpm: control.stirrerRpm,
      heaterOn: control.heaterOn,
      targetTempC: control.targetTempC,
      updatedAt: clock(),
    );
    _replaceProject(updated);
    await repository.updateProject(updated);
    notifyListeners();
  }

  Future<void> pause(int id) => _setStatus(id, FermenterStatus.paused);

  Future<void> resume(int id) async {
    final project = _projectById(id);
    if (project == null) return;
    _lastSampleSeconds[id] ??= project.simSeconds;
    _clockSeconds[id] ??= project.simSeconds;
    await _setStatus(id, FermenterStatus.active);
  }

  Future<void> finish(int id) => _setStatus(id, FermenterStatus.finished);

  Future<void> restart(int id) async {
    final project = _projectById(id);
    if (project == null) return;
    await repository.deleteReadings(id);
    _readings.remove(id);
    _clockSeconds.remove(id);
    _lastSampleSeconds.remove(id);
    _sources.remove(id);
    _detectors.remove(id);
    _verdicts.remove(id);
    final updated = project.copyWith(
      status: FermenterStatus.active,
      simSeconds: 0,
      updatedAt: clock(),
      peakOd: () => null,
      harvestAtSeconds: () => null,
    );
    _replaceProject(updated);
    await repository.updateProject(updated);
    _verdicts[id] = const HarvestDetector().evaluate(const []);
    notifyListeners();
  }

  Future<void> delete(int id) async {
    await repository.deleteProject(id);
    _readings.remove(id);
    _clockSeconds.remove(id);
    _lastSampleSeconds.remove(id);
    _sources.remove(id);
    _detectors.remove(id);
    _verdicts.remove(id);
    _deviceLabels.remove(id);
    if (_openProjectId == id) _openProjectId = null;
    await _load(++_revision);
  }

  Future<void> addManualReading(
    int id, {
    required double temperatureC,
    required double ph,
    required double od,
    String? note,
  }) async {
    final project = _projectById(id);
    if (project == null) return;
    final current = _readings[id] ?? <SensorReading>[];
    final reading = SensorReading(
      id: 0,
      projectId: id,
      seq: _manualSeq(id, current),
      simSeconds: project.simSeconds,
      recordedAt: clock(),
      temperatureC: temperatureC,
      ph: ph,
      od: od,
      note: note,
      source: 'manual',
    );
    await repository.addReading(reading);
    final updatedReadings = [...current, reading];
    _readings[id] = updatedReadings;

    final verdict = (_detectors[id] ??= const HarvestDetector())
        .evaluate(updatedReadings.map((r) => r.od).toList(growable: false));
    _verdicts[id] = verdict;

    var updated = project.copyWith(
      updatedAt: clock(),
      peakOd: () => verdict.peakOd,
      lastTemperatureC: reading.temperatureC,
      lastPh: reading.ph,
      lastOd: reading.od,
    );
    if (verdict.triggered && updated.status == FermenterStatus.active) {
      updated = updated.copyWith(
        status: FermenterStatus.harvest,
        harvestAtSeconds: () => project.simSeconds,
      );
    }
    _replaceProject(updated);
    await repository.updateProject(updated);
    notifyListeners();
  }

  // -- 设备读数（BleReadingSink）--

  /// 设备同步的起点：本地已有的下一条设备序号（空批次为 0）。
  @override
  Future<int> nextExpectedSeq(int projectId) async {
    final cached = _readings[projectId];
    if (cached != null && cached.isNotEmpty) return _deviceCursor(cached);
    return _deviceCursor(await repository.readings(projectId));
  }

  /// 落库设备推送/同步的读数。返回后 [BleSyncService] 才会回 ACK。
  ///
  /// 与仿真路径分开：这里不推进本地时钟，时间轴直接取设备序号。
  @override
  Future<void> storeDeviceReadings(
      int projectId, List<SensorReading> readings) async {
    if (readings.isEmpty) return;
    final project = _projectById(projectId);
    if (project == null) return;

    final existing = _readings[projectId] ?? const <SensorReading>[];
    final known = <int>{
      for (final reading in existing)
        if (reading.source == 'ble') reading.seq,
    };
    final fresh = <SensorReading>[];
    for (final reading in readings) {
      if (known.add(reading.seq)) fresh.add(_withDeviceTimeline(reading));
    }
    if (fresh.isEmpty) return;
    fresh.sort((a, b) => a.seq.compareTo(b.seq));

    await repository.addReadings(fresh);
    // 与 readings(ascending: true) 的排序保持一致：手动读数的序号在
    // 另一个区段，仍然排在设备记录之后。
    final updated = [...existing, ...fresh]
      ..sort((a, b) => a.seq.compareTo(b.seq));
    _readings[projectId] = updated;

    final last = updated.last;
    final latestSeconds =
        math.max(_clockSeconds[projectId] ?? 0, last.simSeconds);
    _clockSeconds[projectId] = latestSeconds;
    _lastSampleSeconds[projectId] = latestSeconds;

    final verdict = (_detectors[projectId] ??=
            const HarvestDetector(
                sampleIntervalSeconds: deviceSampleIntervalSeconds))
        .evaluate(updated.map((r) => r.od).toList(growable: false));
    _verdicts[projectId] = verdict;

    var next = project.copyWith(
      simSeconds: math.max(project.simSeconds, last.simSeconds),
      updatedAt: clock(),
      lastTemperatureC: last.temperatureC,
      lastPh: last.ph,
      lastOd: last.od,
    );
    if (verdict.peakOd > (next.peakOd ?? 0)) {
      next = next.copyWith(peakOd: () => verdict.peakOd);
    }
    if (verdict.triggered && next.status == FermenterStatus.active) {
      next = next.copyWith(
        status: FermenterStatus.harvest,
        harvestAtSeconds: () => last.simSeconds,
      );
    }
    _replaceProject(next);
    await repository.updateProject(next);
    notifyListeners();
  }

  /// 手动读数的序号：仿真批次沿用「按条数递增」，设备批次换到独立区段。
  int _manualSeq(int projectId, List<SensorReading> existing) {
    if (!_deviceLabels.containsKey(projectId)) return existing.length;
    return manualSeqBase + existing.where((r) => r.source == 'manual').length;
  }

  /// 设备同步的起点：本地第一条**缺失**的设备序号。
  ///
  /// 不能简单返回「最大序号 + 1」：设备某条记录若在传输中丢了，App 会把后面的
  /// 记录照常落库，用最大序号当游标就等于永久跳过中间那段（下次同步从更大的
  /// 序号开始）。这里从最小的已存序号往后找第一个空档，重连时会重取缺口。
  static int _deviceCursor(List<SensorReading> readings) {
    final seqs = <int>{
      for (final reading in readings)
        if (reading.source == 'ble') reading.seq,
    };
    if (seqs.isEmpty) return 0;
    var cursor = seqs.reduce(math.min);
    while (seqs.contains(cursor)) {
      cursor++;
    }
    return cursor;
  }

  /// 设备只给绝对时间戳；实验时间轴按「序号 × 采样周期」换算，
  /// 这样即使设备没校时也能画出正确的时间轴。
  static SensorReading _withDeviceTimeline(SensorReading reading) =>
      SensorReading(
        id: 0,
        projectId: reading.projectId,
        seq: reading.seq,
        simSeconds: reading.seq * deviceSampleIntervalSeconds,
        recordedAt: reading.recordedAt,
        temperatureC: reading.temperatureC,
        ph: reading.ph,
        od: reading.od,
        note: reading.note,
        source: reading.source,
      );

  Future<void> _setStatus(int id, FermenterStatus status) async {
    final project = _projectById(id);
    if (project == null || project.status == status) return;
    final updated = project.copyWith(status: status, updatedAt: clock());
    _replaceProject(updated);
    await repository.updateProject(updated);
    notifyListeners();
  }

  /// 按 id 取批次（设备同步、界面下拉选择用）。
  FermentationProject? projectById(int id) => _projectById(id);

  FermentationProject? _projectById(int id) {
    for (final project in projects) {
      if (project.id == id) return project;
    }
    return null;
  }

  void _replaceProject(FermentationProject updated) {
    projects = [
      for (final project in projects)
        if (project.id == updated.id) updated else project,
    ];
  }
}