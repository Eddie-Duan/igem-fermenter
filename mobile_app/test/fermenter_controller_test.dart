import 'dart:io';

import 'package:fermenter_app/database/fermenter_repository.dart';
import 'package:fermenter_app/database/sqlite_fermenter_repository.dart';
import 'package:fermenter_app/models/control_state.dart';
import 'package:fermenter_app/models/fermentation_project.dart';
import 'package:fermenter_app/services/fermenter_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  Future<SqliteFermenterRepository> open([String? path]) =>
      SqliteFermenterRepository.open(
          factory: databaseFactoryFfiNoIsolate,
          path: path ?? inMemoryDatabasePath);

  FermenterController make(FermenterRepository repo) =>
      FermenterController(repository: repo, clock: () => DateTime(2026, 1, 1));

  test('projects and readings persist across reopen', () async {
    final dir = await Directory.systemTemp.createTemp('fermenter-reopen-');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/fermenter.db';

    var repo = await open(path);
    var controller = make(repo);
    await controller.createProject(
        const ProjectDraft(name: 'Batch X', targetTempC: 30, timeScale: 60));
    expect(controller.projects.single.name, 'Batch X');
    expect(controller.projects.single.status, FermenterStatus.active);
    await controller.addManualReading(
        controller.projects.single.id,
        temperatureC: 30,
        ph: 7.0,
        od: 0.5);
    controller.dispose();
    await repo.close();

    repo = await open(path);
    controller = make(repo);
    addTearDown(controller.dispose);
    addTearDown(repo.close);
    await controller.refresh();
    expect(controller.projects, hasLength(1));
    expect(await repo.countReadings(controller.projects.single.id), 1);
  });

  test('simulation advances and stores readings on active projects', () async {
    final repo = await open();
    final controller = make(repo);
    addTearDown(controller.dispose);
    addTearDown(repo.close);
    await controller.createProject(const ProjectDraft(
        name: 'Batch A',
        targetTempC: 30,
        timeScale: 120)); // 每 tick 120 仿真秒 → 每次正好采样

    for (var i = 0; i < 5; i++) {
      await controller.advanceSimulation();
    }
    expect(controller.openReadings, hasLength(5));
    expect(controller.openProject!.simSeconds, 120 * 5);
    // 落库检查
    expect(await repo.countReadings(controller.openProject!.id), 5);
  });

  test('paused projects do not record new readings', () async {
    final repo = await open();
    final controller = make(repo);
    addTearDown(controller.dispose);
    addTearDown(repo.close);
    await controller.createProject(const ProjectDraft(
        name: 'Pause me', targetTempC: 30, timeScale: 120));
    await controller.advanceSimulation();
    await controller.pause(controller.projects.single.id);
    expect(controller.projects.single.status, FermenterStatus.paused);
    await controller.advanceSimulation();
    expect(controller.openReadings, hasLength(1));
    await controller.resume(controller.projects.single.id);
    await controller.advanceSimulation();
    expect(controller.openReadings, hasLength(2));
  });

  test('manual readings that mimic lysis trigger the harvest signal',
      () async {
    final repo = await open();
    final controller = make(repo);
    addTearDown(controller.dispose);
    addTearDown(repo.close);
    await controller.createProject(const ProjectDraft(
        name: 'Lysis batch', targetTempC: 30, timeScale: 60));

    final ods = <double>[
      0.1, 0.3, 0.6, 1.0, 1.2, 1.25, 1.2, 1.05, 0.9, 0.75, 0.6,
    ];
    final id = controller.projects.single.id;
    for (final od in ods) {
      await controller.addManualReading(id,
          temperatureC: 30, ph: 7.0, od: od);
    }
    expect(controller.projects.single.status, FermenterStatus.harvest);
    expect(controller.projects.single.peakOd, closeTo(1.25, 0.01));
  });

  test('createProject requires a name', () async {
    final repo = await open();
    final controller = make(repo);
    addTearDown(controller.dispose);
    addTearDown(repo.close);
    await expectLater(
        controller.createProject(
            const ProjectDraft(name: '  ', targetTempC: 30, timeScale: 60)),
        throwsArgumentError);
  });

  test('control updates persist', () async {
    final repo = await open();
    final controller = make(repo);
    addTearDown(controller.dispose);
    addTearDown(repo.close);
    await controller.createProject(const ProjectDraft(
        name: 'Ctrl', targetTempC: 30, timeScale: 60));
    final id = controller.projects.single.id;
    await controller.setControl(id, const ControlState(
        stirrerOn: true, stirrerRpm: 240, heaterOn: true, targetTempC: 37));
    expect(controller.projects.single.stirrerOn, isTrue);
    expect(controller.projects.single.stirrerRpm, 240);
    expect(controller.projects.single.heaterOn, isTrue);
    expect(controller.projects.single.targetTempC, 37);
  });
}