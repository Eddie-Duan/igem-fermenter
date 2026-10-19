import 'package:fermenter_app/database/fermenter_repository.dart';
import 'package:fermenter_app/database/sqlite_fermenter_repository.dart';
import 'package:fermenter_app/main.dart';
import 'package:fermenter_app/pages/onboarding_page.dart';
import 'package:fermenter_app/services/fermenter_controller.dart';
import 'package:fermenter_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  testWidgets('shows the welcome screen on first launch', (tester) async {
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

    // 欢迎页：品牌区 + 两个入口（新建 / 载入样例数据）。
    // AppBar 标题与品牌区同名，因此匹配到两个。
    expect(find.text('FeroEase'), findsNWidgets(2));
    expect(find.text('Create your first batch'), findsOneWidget);
    expect(find.text('Load sample data'), findsOneWidget);
    // 没有批次时不重复挂 FAB。
    expect(find.text('New batch'), findsNothing);
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
    // 有批次时 FAB 回到列表页。
    expect(find.text('New batch'), findsOneWidget);
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

  testWidgets('onboarding walks through its three slides', (tester) async {
    var done = false;
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: OnboardingPage(onDone: () => done = true),
    ));
    // 收获曲线会循环播放，全程使用显式 pump。
    await tester.pump();

    expect(find.text('From inoculation to harvest — made simple.'),
        findsOneWidget);
    expect(find.text('Skip'), findsOneWidget);
    expect(find.text('Get started'), findsNothing);
    expect(find.text('Preview a sample reading'), findsNothing);
    expect(find.byType(ChoiceChip), findsNothing);

    await tester.ensureVisible(find.text('Continue'));
    await tester.tap(find.text('Continue'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Three signals, one screen'), findsOneWidget);
    expect(find.text('Turbidity (OD600)'), findsOneWidget);
    expect(find.text('Temperature'), findsOneWidget);
    expect(find.text('pH'), findsOneWidget);

    await tester.ensureVisible(find.text('Continue'));
    await tester.tap(find.text('Continue'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Harvest on signal'), findsOneWidget);
    expect(find.text('Get started'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 3000));
    expect(find.text('Preview harvest signal'), findsNothing);

    await tester.ensureVisible(find.text('Get started'));
    await tester.tap(find.text('Get started'));
    await tester.pump();
    expect(done, isTrue);

    // 卸载页面，清理循环曲线动画。
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('replaying the onboarding shows no skip button', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: OnboardingPage(isReplay: true, onDone: () {}),
    ));
    await tester.pump();

    expect(find.text('Skip'), findsNothing);
    // 重播时用返回键代替 Skip（这里直接断言 AppBar 的配置，
    // 因为 home: 起的路由本身不可 pop，不会渲染出返回键）。
    expect(tester.widget<AppBar>(find.byType(AppBar)).automaticallyImplyLeading,
        isTrue);
  });

  testWidgets('first-run onboarding can be skipped', (tester) async {
    var done = false;
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: OnboardingPage(onDone: () => done = true),
    ));
    await tester.pump();

    await tester.tap(find.text('Skip'));
    expect(done, isTrue);
  });

  testWidgets('onboarding content scrolls on a compact screen', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: OnboardingPage(onDone: () {}),
    ));
    await tester.pump();

    expect(find.text('From inoculation to harvest — made simple.'),
        findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(find.text('Continue'));
    await tester.tap(find.text('Continue'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Three signals, one screen'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(find.text('Continue'));
    await tester.tap(find.text('Continue'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Harvest on signal'), findsOneWidget);
    await tester.ensureVisible(find.text('Lysis → harvest'));
    await tester.pump(const Duration(milliseconds: 3000));
    expect(find.text('Harvest on signal'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });
}