import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'database/sqlite_fermenter_repository.dart';
import 'pages/home_page.dart';
import 'pages/onboarding_page.dart';
import 'services/fermenter_controller.dart';
import 'services/onboarding_store.dart';
import 'theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FermenterApp());
}

class FermenterApp extends StatelessWidget {
  const FermenterApp({super.key, this.controller});

  /// 测试注入用；正式入口为 null，由 [_DatabaseLoader] 打开本地库。
  final FermenterController? controller;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'iGEM Fermenter',
    debugShowCheckedModeBanner: false,
    locale: const Locale('en'),
    supportedLocales: const [Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    // 只有一套主题（浅色），见 theme/app_theme.dart。
    theme: buildAppTheme(),
    home: controller == null ? const _DatabaseLoader() : HomePage(controller: controller!),
  );
}

class _DatabaseLoader extends StatefulWidget {
  const _DatabaseLoader();
  @override
  State<_DatabaseLoader> createState() => _DatabaseLoaderState();
}

class _DatabaseLoaderState extends State<_DatabaseLoader> {
  FermenterController? _controller;
  bool _showOnboarding = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    setState(() => _failed = false);
    // 读引导标记与打开本地库并行，不让它拖慢启动。
    final onboardingSeen = OnboardingStore.hasSeen();
    SqliteFermenterRepository? repo;
    try {
      repo = await SqliteFermenterRepository.open();
      if (!mounted) {
        await repo.close();
        return;
      }
      final controller = FermenterController(repository: repo);
      controller.start();
      await controller.refresh();
      final seen = await onboardingSeen;
      if (!mounted) {
        controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _showOnboarding = !seen;
      });
    } catch (_) {
      await repo?.close();
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller != null) {
      // 首次启动先看引导，看完淡入首页。
      return AnimatedSwitcher(
        duration: const Duration(milliseconds: 350),
        child: _showOnboarding
            ? OnboardingPage(
                key: const ValueKey('onboarding'),
                onDone: () => setState(() => _showOnboarding = false),
              )
            : HomePage(key: const ValueKey('home'), controller: controller),
      );
    }
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _failed
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.storage_outlined, size: 40),
                    const SizedBox(height: 16),
                    const Text('Local storage could not be opened. '
                        'Free up some space and try again.'),
                    const SizedBox(height: 16),
                    FilledButton(onPressed: _open, child: const Text('Retry')),
                  ],
                )
              : const CircularProgressIndicator(),
        ),
      ),
    );
  }
}