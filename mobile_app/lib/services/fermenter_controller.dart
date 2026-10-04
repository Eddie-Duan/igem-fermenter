import 'dart:async';

import 'package:flutter/foundation.dart';

import '../database/fermenter_repository.dart';
import '../models/control_state.dart';
import '../models/fermentation_project.dart';
import '../models/sensor_reading.dart';
import 'harvest_detector.dart';
import 'sensor_source.dart';
import 'simulated_sensor_source.dart';

/// 全局控制器：持有项目与读数、驱动仿真采样、维护收获检测结果。
///
/// 未来接真实硬件时，只需要把 [SimulatedSensorSource] 换成硬件实现，
/// 其余（存储、检测、UI）全部复用。
class FermenterController extends ChangeNotifier {
  FermenterController({
    required this.repository,
    SensorSource Function(int projectId, SensorReading? last)? sourceBuilder,
    DateTime Function()? clock,
  })  : _sourceBuilder =
            sourceBuilder ?? _defaultSimSource,
        clock = clock ?? DateTime.now;

  /// 每两次仿真实采样之间间隔的仿真秒数。
  static const int sampleIntervalSeconds = 120;

  final FermenterRepository repository;
  final DateTime Function() clock;
  final SensorSource Function(int projectId, SensorReading? last) _sourceBuilder;

  final Map<int, SensorSource> _sources = {};
  final Map<int, HarvestDetector> _detectors = {};
  final Map<int, int> _clockSeconds = {};
  final Map<int, int> _lastSampleSeconds = {};
  final Map<int, HarvestVerdict> _verdicts = {};
  final Map<int, List<SensorReading>> _readings = {};

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

    final verdict = const HarvestDetector()
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
      error = '暂时无法读取本地数据，请重试。';
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
      seq: current.length,
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

  Future<void> _setStatus(int id, FermenterStatus status) async {
    final project = _projectById(id);
    if (project == null || project.status == status) return;
    final updated = project.copyWith(status: status, updatedAt: clock());
    _replaceProject(updated);
    await repository.updateProject(updated);
    notifyListeners();
  }

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