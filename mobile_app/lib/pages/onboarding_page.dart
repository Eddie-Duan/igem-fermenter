import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/onboarding_store.dart';
import '../services/simulated_sensor_source.dart';
import '../theme/app_theme.dart';
import '../widgets/feature_row.dart';

/// 新用户引导：首次启动时自动展示，之后可从首页右上角重播。
///
/// 三页 slide，底部操作条固定不动，所以无论左右滑动还是点按钮，
/// 圆点和按钮都不会跳位：
///   1. 这是什么 / 为什么需要它；
///   2. 它记录哪三个信号；
///   3. 收获信号是怎么被识别出来的（曲线动画演示）。
class OnboardingPage extends StatefulWidget {
  const OnboardingPage({
    super.key,
    required this.onDone,
    this.isReplay = false,
  });

  /// 结束引导：首次启动时切换到首页，重播时关闭本页。
  final VoidCallback onDone;

  /// 重播模式：显示返回键、不再写引导标记。
  final bool isReplay;

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  static const int _pageCount = 3;
  static const Duration _pageDuration = Duration(milliseconds: 360);

  final PageController _pageController = PageController();
  int _index = 0;

  bool get _isLast => _index == _pageCount - 1;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _finish() {
    if (!widget.isReplay) {
      // 标记写失败也无所谓：最多下次再看一遍引导。
      unawaited(OnboardingStore.markSeen());
    }
    widget.onDone();
  }

  void _next() {
    if (_isLast) {
      _finish();
      return;
    }
    _pageController.nextPage(duration: _pageDuration, curve: Curves.easeOutCubic);
  }

  void _goTo(int index) {
    if (index == _index) return;
    _pageController.animateToPage(index,
        duration: _pageDuration, curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: widget.isReplay,
        actions: [
          if (!widget.isReplay)
            TextButton(onPressed: _finish, child: const Text('Skip')),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              children: [
                Expanded(
                  child: PageView(
                    controller: _pageController,
                    onPageChanged: (index) => setState(() => _index = index),
                    children: [
                      _slide(0, _welcomeSlide()),
                      _slide(1, _signalsSlide()),
                      _slide(2, _harvestSlide()),
                    ],
                  ),
                ),
                _dots(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 14, 24, 20),
                  child: FilledButton(
                    onPressed: _next,
                    style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(50)),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: Text(_isLast ? 'Get started' : 'Continue',
                          key: ValueKey<bool>(_isLast)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _slide(int index, Widget child) =>
      _SlideIn(index: index, controller: _pageController, child: child);

  // -- 三页内容 --

  Widget _welcomeSlide() {
    final scheme = Theme.of(context).colorScheme;
    return _pageShell([
      Center(child: _logoBadge(scheme)),
      const SizedBox(height: 26),
      const Text('iGEM Fermenter',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
      const SizedBox(height: 10),
      const Text('From inoculation to harvest, without the guesswork.',
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 15.5,
              height: 1.3,
              fontWeight: FontWeight.w600,
              color: accentGreen)),
      const SizedBox(height: 14),
      Text(
        'Temperature, pH and turbidity in one place — with a clear signal '
        'the moment the culture is ready to harvest.',
        textAlign: TextAlign.center,
        style: TextStyle(
            fontSize: 14, height: 1.4, color: scheme.onSurfaceVariant),
      ),
      const SizedBox(height: 18),
      Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: scheme.secondaryContainer,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            'No hardware needed — start with the built-in sample data.',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: scheme.onSecondaryContainer),
          ),
        ),
      ),
    ]);
  }

  Widget _signalsSlide() {
    final scheme = Theme.of(context).colorScheme;
    return _pageShell([
      _slideTitle('Three signals, one screen'),
      const SizedBox(height: 8),
      Text(
        'Every reading is stored and plotted on a live time course, so the '
        'trend is visible at a glance.',
        textAlign: TextAlign.center,
        style: TextStyle(
            fontSize: 13.5, height: 1.4, color: scheme.onSurfaceVariant),
      ),
      const SizedBox(height: 18),
      const FeatureRow(
        icon: Icons.bubble_chart_outlined,
        title: 'Turbidity (OD600)',
        body: 'The cloudiness of the culture — it climbs while the cells '
            'grow and falls once they lyse.',
        color: Colors.teal,
      ),
      const FeatureRow(
        icon: Icons.thermostat_outlined,
        title: 'Temperature',
        body: 'Ramped to your target and held there, with the heater and '
            'stirrer under your control.',
        color: Colors.deepOrange,
      ),
      const FeatureRow(
        icon: Icons.science_outlined,
        title: 'pH',
        body: 'The buffer drifts down during growth and recovers slightly '
            'during lysis.',
        color: Colors.indigo,
      ),
    ]);
  }

  Widget _harvestSlide() {
    final scheme = Theme.of(context).colorScheme;
    return _pageShell([
      const _HarvestCurvePreview(),
      const SizedBox(height: 22),
      _slideTitle('Harvest on signal'),
      const SizedBox(height: 8),
      Text(
        'Turbidity rises during growth, plateaus, then falls sharply as the '
        'cells lyse. The app watches for that sustained fall and alerts you — '
        'that is the harvest window.',
        textAlign: TextAlign.center,
        style: TextStyle(
            fontSize: 13.5, height: 1.4, color: scheme.onSurfaceVariant),
      ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.center,
        children: [
          _phasePill('Growth', Colors.teal.shade600),
          _phasePill('Plateau', Colors.orange.shade800),
          _phasePill('Lysis → harvest', Colors.red.shade700),
        ],
      ),
    ]);
  }

  // -- 组件 --

  /// 每页统一的可滚动外壳：内容少时垂直居中，内容多时（小屏/大字号）滚动，
  /// 不会出现溢出条。
  Widget _pageShell(List<Widget> children) => LayoutBuilder(
        builder: (context, constraints) {
          final minHeight =
              constraints.maxHeight.isFinite ? constraints.maxHeight - 16 : 0.0;
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 8, 28, 8),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: minHeight),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          );
        },
      );

  Widget _slideTitle(String text) => Text(text,
      textAlign: TextAlign.center,
      style: const TextStyle(fontSize: 21, fontWeight: FontWeight.bold));

  Widget _logoBadge(ColorScheme scheme) => Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              scheme.primary,
              Color.lerp(scheme.primary, scheme.tertiary, 0.55)!,
            ],
          ),
          boxShadow: [
            BoxShadow(
              color: scheme.primary.withValues(alpha: 0.3),
              blurRadius: 26,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Icon(Icons.biotech_rounded, size: 46, color: scheme.onPrimary),
      );

  Widget _phasePill(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600, color: color)),
      );

  /// 圆点指示器：可点击跳页。
  Widget _dots() {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < _pageCount; i++)
          GestureDetector(
            onTap: () => _goTo(i),
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                width: i == _index ? 24 : 8,
                height: 8,
                decoration: BoxDecoration(
                  color: i == _index ? scheme.primary : scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 翻页时的淡入 + 轻微上移，让滑动更有层次（跟手滑动本身仍由 PageView 负责）。
class _SlideIn extends StatelessWidget {
  const _SlideIn({
    required this.index,
    required this.controller,
    required this.child,
  });

  final int index;
  final PageController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final page = controller.hasClients &&
                  controller.position.haveDimensions
              ? controller.page ?? index.toDouble()
              : index.toDouble();
          final delta = (page - index).clamp(-1.0, 1.0);
          return Opacity(
            opacity: (1 - delta.abs() * 0.8).clamp(0.0, 1.0),
            child: Transform.translate(
              offset: Offset(0, delta * 32),
              child: child,
            ),
          );
        },
        child: child,
      );
}

/// 第三页的动画演示：用真实的仿真曲线画出一条 OD600 曲线，
/// 画完后在收获时刻亮起脉冲标记，对应 App 里的「Harvest time」告警。
class _HarvestCurvePreview extends StatefulWidget {
  const _HarvestCurvePreview();

  @override
  State<_HarvestCurvePreview> createState() => _HarvestCurvePreviewState();
}

class _HarvestCurvePreviewState extends State<_HarvestCurvePreview>
    with SingleTickerProviderStateMixin {
  /// 4 秒一轮：前 2.8 秒画曲线，最后 1.2 秒亮起收获标记。
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 4000),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 168,
      width: double.infinity,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => CustomPaint(
          painter: _HarvestCurvePainter(
            progress: _controller.value,
            line: Colors.teal.shade600,
            fill: Colors.teal.shade600.withValues(alpha: 0.16),
            guide: scheme.outlineVariant,
            alert: scheme.tertiary,
            onAlert: scheme.onTertiary,
          ),
        ),
      ),
    );
  }
}

class _HarvestCurvePainter extends CustomPainter {
  _HarvestCurvePainter({
    required this.progress,
    required this.line,
    required this.fill,
    required this.guide,
    required this.alert,
    required this.onAlert,
  });

  final double progress;
  final Color line;
  final Color fill;
  final Color guide;
  final Color alert;
  final Color onAlert;

  /// 横轴：仿真 20 小时；纵轴：0–1.35 OD600。
  static const double _totalHours = 20;
  static const double _maxOd = 1.35;

  /// 收获信号出现的时刻（与仿真一致，裂解刚开始不久）。
  static const double _harvestHour = 11.4;

  @override
  void paint(Canvas canvas, Size size) {
    final chart = Rect.fromLTRB(6, 6, size.width - 6, size.height - 18);

    Offset point(double hours, double od) => Offset(
          chart.left + chart.width * (hours / _totalHours),
          chart.bottom - chart.height * (od / _maxOd).clamp(0.0, 1.0),
        );

    final grid = Paint()
      ..color = guide
      ..strokeWidth = 1;

    // 峰值参考虚线（与详情页图表里的 peak 线一致）。
    final peakY = point(0, SimulatedSensorSource.odAt(10)).dy;
    for (var x = chart.left; x < chart.right; x += 8) {
      canvas.drawLine(Offset(x, peakY), Offset(x + 4, peakY), grid);
    }
    canvas.drawLine(Offset(chart.left, chart.bottom),
        Offset(chart.right, chart.bottom), grid);

    // 曲线：progress 0 → 0.7 之间逐步画出来。
    final drawnHours = _totalHours * (progress / 0.7).clamp(0.0, 1.0);
    final path = Path();
    var started = false;
    for (var h = 0.0; h <= drawnHours + 1e-9; h += 0.1) {
      final p = point(h, SimulatedSensorSource.odAt(h));
      if (started) {
        path.lineTo(p.dx, p.dy);
      } else {
        path.moveTo(p.dx, p.dy);
        started = true;
      }
    }
    if (started) {
      canvas.drawPath(
        Path.from(path)
          ..lineTo(point(drawnHours, 0).dx, chart.bottom)
          ..lineTo(chart.left, chart.bottom)
          ..close(),
        Paint()..color = fill,
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = line
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.4
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }

    // 收获标记：曲线画完后亮起并脉冲两下。
    if (progress > 0.7) {
      final t = ((progress - 0.7) / 0.3).clamp(0.0, 1.0);
      final p = point(_harvestHour, SimulatedSensorSource.odAt(_harvestHour));
      final pulse = (t * 2) % 1.0;
      canvas.drawCircle(
        p,
        5 + 18 * pulse,
        Paint()..color = alert.withValues(alpha: 0.35 * (1 - pulse)),
      );
      canvas.drawCircle(p, 5, Paint()..color = alert);

      final text = TextPainter(
        text: TextSpan(
          text: 'Harvest window',
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w600, color: onAlert),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      const padH = 8.0, padV = 4.0;
      final width = text.width + padH * 2;
      final height = text.height + padV * 2;
      final left = (p.dx + 10)
          .clamp(chart.left, math.max(chart.left, chart.right - width));
      final top = (p.dy + 8)
          .clamp(chart.top, math.max(chart.top, chart.bottom - height));
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(left, top, width, height), const Radius.circular(9)),
        Paint()..color = alert,
      );
      text.paint(canvas, Offset(left + padH, top + padV));
    }
  }

  @override
  bool shouldRepaint(covariant _HarvestCurvePainter old) =>
      old.progress != progress || old.line != line || old.alert != alert;
}
