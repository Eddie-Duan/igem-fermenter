import 'package:fermenter_app/services/harvest_detector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const detector = HarvestDetector();

  test('growth-only OD never triggers harvest', () {
    final growth = <double>[];
    for (var i = 0; i < 60; i++) {
      growth.add(0.1 + i * 0.02);
    }
    final verdict = detector.evaluate(growth);
    expect(verdict.triggered, isFalse);
    expect(verdict.peakOd, greaterThan(1.2));
  });

  test('peak followed by sustained drop triggers harvest', () {
    // 增殖 → 平台 → 裂解下落的典型两阶段曲线
    final ods = <double>[
      0.1, 0.3, 0.6, 1.0, 1.2, 1.25, // 上升
      1.25, 1.2, 1.05, 0.9, 0.75, 0.6, // 裂解下落
    ];
    final verdict = detector.evaluate(ods);
    expect(verdict.triggered, isTrue);
    expect(verdict.peakOd, closeTo(1.25, 0.01));
    expect(verdict.odNow, lessThanOrEqualTo(verdict.peakOd * 0.96));
  });

  test('plateau without a real drop does not trigger', () {
    final flat = <double>[
      0.1, 0.3, 0.6, 1.0, 1.2, 1.25, 1.24, 1.25, 1.23, 1.25, 1.24, 1.25,
    ];
    expect(detector.evaluate(flat).triggered, isFalse);
  });

  test('tiny noise alone never triggers', () {
    final noisy = <double>[];
    var v = 0.12;
    for (var i = 0; i < 80; i++) {
      v += (i % 3 == 0 ? 0.01 : -0.008);
      v = v.clamp(0.05, 0.3).toDouble();
      noisy.add(v);
    }
    expect(detector.evaluate(noisy).triggered, isFalse);
  });

  test('classifyPhase labels the states', () {
    final growth = <double>[for (var i = 0; i < 20; i++) 0.1 + i * 0.05];
    expect(
        classifyPhase(
            ods: growth,
            verdict: detector.evaluate(growth),
            finished: false),
        FermentationPhase.exponential);

    final falling = <double>[...growth, 1.1, 1.0, 0.8];
    var verdict = detector.evaluate(falling);
    // 若未触发，后段斜率转负也应判为裂解
    expect(
        classifyPhase(ods: falling, verdict: verdict, finished: false),
        FermentationPhase.lysis);

    expect(
        classifyPhase(
            ods: const [0.1, 0.2],
            verdict: const HarvestVerdict(
                triggered: false, peakOd: 0.2, odNow: 0.2, slope: 0, consecutiveDrop: 0),
            finished: false),
        FermentationPhase.lagGrowth);

    verdict = detector.evaluate(falling);
    expect(
        classifyPhase(ods: falling, verdict: verdict, finished: true),
        FermentationPhase.finished);
  });

  test('sustained count requires several consecutive negative windows', () {
    // 只落下 2 个点：连续轮数不足 sustain=3，不应触发
    final short = <double>[0.1, 0.3, 0.6, 1.0, 1.2, 1.2, 1.05];
    expect(detector.evaluate(short).triggered, isFalse);
  });
}