import 'dart:math' as math;

import 'package:fermenter_app/services/harvest_detector.dart';
import 'package:flutter_test/flutter_test.dart';

/// 增殖 → 峰值 → 裂解下落的两阶段曲线。
List<double> growthThenFall({
  int growthPoints = 40,
  double growthStep = 0.03,
  int fallPoints = 60,
  double fallStep = 0.02,
}) {
  final ods = <double>[
    for (var i = 0; i < growthPoints; i++) 0.1 + i * growthStep,
  ];
  final peak = ods.last;
  for (var i = 1; i <= fallPoints; i++) {
    final value = peak - i * fallStep;
    ods.add(value < 0.02 ? 0.02 : value);
  }
  return ods;
}

void main() {
  const detector = HarvestDetector();

  test('growth-only OD never triggers harvest', () {
    final growth = <double>[for (var i = 0; i < 200; i++) 0.1 + i * 0.01];
    final verdict = detector.evaluate(growth);
    expect(verdict.triggered, isFalse);
    expect(verdict.peakOd, greaterThan(2.0));
  });

  test('sustained fall after a peak triggers harvest', () {
    final ods = growthThenFall();
    final verdict = detector.evaluate(ods);
    expect(verdict.triggered, isTrue);
    expect(verdict.peakOd, closeTo(1.27, 0.01));
    expect(verdict.slopePerMinute, lessThanOrEqualTo(-0.01));
    expect(verdict.consecutiveDrop, greaterThanOrEqualTo(36));
  });

  test('plateau without a real drop does not trigger', () {
    final flat = <double>[
      for (var i = 0; i < 40; i++) 0.1 + i * 0.03,
      for (var i = 0; i < 200; i++) 1.27,
    ];
    expect(detector.evaluate(flat).triggered, isFalse);
  });

  test('sensor noise alone never triggers', () {
    final random = math.Random(7);
    final noisy = <double>[
      for (var i = 0; i < 400; i++) 0.8 + (random.nextDouble() - 0.5) * 0.01,
    ];
    expect(detector.evaluate(noisy).triggered, isFalse);
  });

  test('a short dip is not enough (36 consecutive updates)', () {
    final short = growthThenFall(fallPoints: 30);
    expect(detector.evaluate(short).triggered, isFalse);
  });

  test('classifyPhase labels the states', () {
    final growth = <double>[for (var i = 0; i < 40; i++) 0.1 + i * 0.03];
    expect(
        classifyPhase(
            ods: growth, verdict: detector.evaluate(growth), finished: false),
        FermentationPhase.exponential);

    // 只落了一小段：检测器未触发，但后段斜率为负、已明显低于峰值，仍判裂解。
    final falling = growthThenFall(fallPoints: 30);
    expect(
        classifyPhase(
            ods: falling, verdict: detector.evaluate(falling), finished: false),
        FermentationPhase.lysis);

    expect(
        classifyPhase(
            ods: const [0.1, 0.2],
            verdict: const HarvestVerdict(
                triggered: false,
                peakOd: 0.2,
                odNow: 0.2,
                slope: 0,
                slopePerMinute: 0,
                consecutiveDrop: 0),
            finished: false),
        FermentationPhase.lagGrowth);

    expect(
        classifyPhase(
            ods: growthThenFall(),
            verdict: detector.evaluate(growthThenFall()),
            finished: true),
        FermentationPhase.finished);
  });
}
