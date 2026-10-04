/// 依据 wiki 的两阶段发酵模型：
/// 增殖期浊度(OD)上升 → 裂解期浊度**快速下降** → 触发"收蛋白"信号。
///
/// 判据（参考发酵罐方案.md 的防误触发要求）：
/// 1. 出现过足够高的峰值（[positiveThreshold]，排除生长初期的噪声）；
/// 2. 最近 [window] 个点的线性回归斜率为明显负值且**连续** [sustain] 轮；
/// 3. 当前 OD 已从峰值明显回落（[dropFraction]）。
///
/// 纯 Dart，无 Flutter 依赖，便于单元测试。
class HarvestDetector {
  const HarvestDetector({
    this.window = 5,
    this.sustain = 3,
    this.positiveThreshold = 0.4,
    this.slopeThreshold = -0.0015,
    this.dropFraction = 0.04,
  });

  /// 回归窗口（点数）。
  final int window;

  /// 需要连续多少轮斜率为负才认定"持续下降"。
  final int sustain;

  final double positiveThreshold;
  final double slopeThreshold;

  /// 当前 OD 至少从峰值回落多少比例。
  final double dropFraction;

  HarvestVerdict evaluate(List<double> ods) {
    if (ods.length < window) {
      return HarvestVerdict(
          triggered: false,
          peakOd: _max(ods),
          odNow: ods.isEmpty ? 0 : ods.last,
          slope: 0,
          consecutiveDrop: 0);
    }
    final peak = _max(ods);
    var consecutive = 0;
    for (var end = window - 1; end < ods.length; end++) {
      final slope = _slope(ods.sublist(end - window + 1, end + 1));
      consecutive = slope < slopeThreshold ? consecutive + 1 : 0;
      if (consecutive >= sustain &&
          peak >= positiveThreshold &&
          ods[end] <= peak * (1 - dropFraction)) {
        return HarvestVerdict(
            triggered: true,
            peakOd: peak,
            odNow: ods[end],
            slope: slope,
            consecutiveDrop: consecutive);
      }
    }
    return HarvestVerdict(
        triggered: false,
        peakOd: peak,
        odNow: ods.last,
        slope: 0,
        consecutiveDrop: consecutive);
  }

  static double _max(List<double> values) =>
      values.fold<double>(0, (m, v) => v > m ? v : m);

  /// 最小二乘斜率（单位：OD / 读数间隔）。
  static double _slope(List<double> ys) {
    final n = ys.length;
    double sx = 0, sy = 0, sxy = 0, sxx = 0;
    for (var i = 0; i < n; i++) {
      sx += i;
      sy += ys[i];
      sxy += i * ys[i];
      sxx += i * i;
    }
    final denom = n * sxx - sx * sx;
    if (denom == 0) return 0;
    return (n * sxy - sx * sy) / denom;
  }
}

class HarvestVerdict {
  const HarvestVerdict({
    required this.triggered,
    required this.peakOd,
    required this.odNow,
    required this.slope,
    required this.consecutiveDrop,
  });

  final bool triggered;
  final double peakOd;
  final double odNow;
  final double slope;
  final int consecutiveDrop;
}

/// 当前阶段（UI 徽章用），与检测器共用同一套曲线理解。
enum FermentationPhase { lagGrowth, exponential, stationary, lysis, finished }

const _phaseLabels = {
  FermentationPhase.lagGrowth: 'Lag / early growth',
  FermentationPhase.exponential: 'Exponential growth',
  FermentationPhase.stationary: 'Stationary / peak',
  FermentationPhase.lysis: 'Lysis (OD falling)',
  FermentationPhase.finished: 'Batch finished',
};

String phaseLabel(FermentationPhase phase) => _phaseLabels[phase]!;

/// 结合最近斜率与峰值判断当前处于哪个阶段。
FermentationPhase classifyPhase({
  required List<double> ods,
  required HarvestVerdict verdict,
  required bool finished,
}) {
  if (finished) return FermentationPhase.finished;
  if (verdict.triggered) return FermentationPhase.lysis;
  if (ods.length < 2) return FermentationPhase.lagGrowth;
  final slope = HarvestDetector._slope(ods.sublist(ods.length - 2));
  if (verdict.peakOd < 0.3) return FermentationPhase.lagGrowth;
  if (slope > 0.0005) return FermentationPhase.exponential;
  if (ods.last >= verdict.peakOd * 0.96) return FermentationPhase.stationary;
  return FermentationPhase.lysis;
}