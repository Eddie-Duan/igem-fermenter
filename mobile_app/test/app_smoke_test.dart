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
    expect(find.text('Fermenter'), findsOneWidget); // AppBar 标题
    expect(find.text('iGEM Fermenter'), findsOneWidget);
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
    // 引导页包含按需播放的动画，全程使用显式 pump。
    await tester.pump();

    expect(find.text('From inoculation to harvest — made simple.'),
        findsOneWidget);
    expect(find.text('Tap the illustration'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('Skip'), findsOneWidget);
    expect(find.text('Get started'), findsNothing);

    await tester.tap(find.text('Tap the illustration'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Welcome to the lab!'), findsOneWidget);

    await tester.ensureVisible(find.text('Preview a sample reading'));
    await tester.tap(find.text('Preview a sample reading'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Sample culture is growing'), findsOneWidget);

    await tester.ensureVisible(find.text('Continue'));
    await tester.tap(find.text('Continue'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Three signals, one screen'), findsOneWidget);
    expect(find.text('Tap the illustration'), findsOneWidget);

    await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'Temperature'));
    await tester.tap(find.widgetWithText(ChoiceChip, 'Temperature'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('The culture is at its target.'), findsOneWidget);
    expect(find.text('37.0 °C'), findsOneWidget);

    await tester.ensureVisible(find.text('Continue'));
    await tester.tap(find.text('Continue'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Harvest on signal'), findsOneWidget);
    expect(find.text('Get started'), findsOneWidget);

    await tester.ensureVisible(find.text('Preview harvest signal'));
    await tester.tap(find.text('Preview harvest signal'));
    await tester.pump(const Duration(milliseconds: 3000));

    await tester.ensureVisible(find.text('Get started'));
    await tester.tap(find.text('Get started'));
    await tester.pump();
    expect(done, isTrue);

    // 卸载页面，清理按需播放的动画。
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
}