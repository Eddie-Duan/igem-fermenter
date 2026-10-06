import 'package:fermenter_app/database/fermenter_repository.dart';
import 'package:fermenter_app/database/sqlite_fermenter_repository.dart';
import 'package:fermenter_app/main.dart';
import 'package:fermenter_app/services/fermenter_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  testWidgets('shows an empty home state on first launch', (tester) async {
    final repo = await SqliteFermenterRepository.open(
        factory: databaseFactoryFfiNoIsolate,
        path: inMemoryDatabasePath);
    final controller = FermenterController(
        repository: repo, clock: () => DateTime(2026, 1, 1));
    addTearDown(controller.dispose);
    addTearDown(repo.close);
    await controller.refresh();

    await tester.pumpWidget(FermenterApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.text('Fermenter'), findsOneWidget);
    expect(find.text('No fermentations yet'), findsOneWidget);
    expect(find.text('New Batch'), findsOneWidget);
  });

  testWidgets('home lists a created batch with its status', (tester) async {
    final repo = await SqliteFermenterRepository.open(
        factory: databaseFactoryFfiNoIsolate,
        path: inMemoryDatabasePath);
    final controller = FermenterController(
        repository: repo, clock: () => DateTime(2026, 1, 1));
    addTearDown(controller.dispose);
    addTearDown(repo.close);
    await controller.createProject(const ProjectDraft(
        name: 'Batch A', targetTempC: 30, timeScale: 60));

    await tester.pumpWidget(FermenterApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.text('Batch A'), findsOneWidget);
    expect(find.text('Active'), findsOneWidget);
  });

  testWidgets('empty home can load the demo sample batch', (tester) async {
    final repo = await SqliteFermenterRepository.open(
        factory: databaseFactoryFfiNoIsolate,
        path: inMemoryDatabasePath);
    final controller = FermenterController(
        repository: repo, clock: () => DateTime(2026, 1, 1));
    addTearDown(controller.dispose);
    addTearDown(repo.close);
    await controller.refresh();

    await tester.pumpWidget(FermenterApp(controller: controller));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Load sample data'));
    await tester.pumpAndSettle();

    // 样例批次跑完整周期，应该直接落到收获告警页。
    expect(find.text('Harvest time!'), findsOneWidget);
    expect(find.text('Time course'), findsOneWidget);
  });
}