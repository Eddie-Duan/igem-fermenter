import 'dart:math' as math;

/// 依据 wiki 的两阶段发酵模型：
/// 增殖期浊度(OD)上升 → 裂解期浊度**快速下降** → 触发"收蛋白"信号。
///
/// 判据与硬件页（wiki/Fermenter_Hardware_Wiki_EN.md §4.3）逐项一致：
/// 1. 3 点滑动平均平滑；
/// 2. 对最近 [window] 个平滑值做线性拟合，斜率 ≤ [slopePerMinuteThreshold]
///    每分钟算一次越限；
/// 3. **连续** [sustain] 次越限才判定进入裂解。
///
/// 采样间隔只用于把"每读数间隔的斜率"换算成"每分钟"。
///
/// 纯 Dart，无 Flutter 依赖，便于单元测试。
class HarvestDetector {
  const HarvestDetector({
    this.smoothing = 3,
    this.window = 12,
    this.sustain = 36,
    this.slopePerMinuteThreshold = -0.010,
    this.sampleIntervalSeconds = 5,
  });

  /// 滑动平均点数（硬件页的 "three-sample moving average"）。
  final int smoothing;

  /// 回归窗口（点数；5 s 采样下 12 点约 1 min）。
  final int window;

  /// 连续多少次越限才报警（5 s 采样下 36 次约 3 min）。
  final int sustain;

  /// 斜率门限，单位 OD600（相对光衰减）/ 分钟。
  final double slopePerMinuteThreshold;

  /// 采样间隔（秒），用于斜率换算。
  final int sampleIntervalSeconds;

  HarvestVerdict evaluate(List<double> ods) {
    // 只看尾部：连续 [sustain] 个窗口最多只用到
    // [window] + [sustain] + [smoothing] 个原始点，避免每个新读数都
    // 平滑整条历史（5 s 采样下一个批次有上万个点）。
    final tailLength = window + sustain + smoothing;
    final tail = ods.length > tailLength
        ? ods.sublist(ods.length - tailLength)
        : ods;
    final smoothed = _movingAverage(tail, smoothing);
    if (smoothed.length < window) {
      return HarvestVerdict(
          triggered: false,
          peakOd: _max(ods),
          odNow: ods.isEmpty ? 0 : ods.last,
          slope: 0,
          slopePerMinute: 0,
          consecutiveDrop: 0);
    }
    final peak = _max(ods);
    var consecutive = 0;
    // 只需要最后 [sustain] 个窗口就能判定"连续越限"。
    final firstEnd = math.max(window - 1, smoothed.length - sustain);
    for (var end = firstEnd; end < smoothed.length; end++) {
      final slope = _slope(smoothed.sublist(end - window + 1, end + 1));
      final slopePerMinute = slope * 60 / sampleIntervalSeconds;
      consecutive =
          slopePerMinute <= slopePerMinuteThreshold ? consecutive + 1 : 0;
      if (consecutive >= sustain) {
        return HarvestVerdict(
            triggered: true,
            peakOd: peak,
            odNow: ods.last,
            slope: slope,
            slopePerMinute: slopePerMinute,
            consecutiveDrop: consecutive);
      }
    }
    return HarvestVerdict(
        triggered: false,
        peakOd: peak,
        odNow: ods.last,
        slope: 0,
        slopePerMinute: 0,
        consecutiveDrop: consecutive);
  }

  /// 尾部滑动平均，长度比输入短 `smoothing - 1`。
  static List<double> _movingAverage(List<double> values, int smoothing) {
    if (smoothing <= 1) return values;
    if (values.length < smoothing) return const [];
    final out = <double>[];
    var sum = 0.0;
    for (var i = 0; i < values.length; i++) {
      sum += values[i];
      if (i >= smoothing) sum -= values[i - smoothing];
      if (i >= smoothing - 1) out.add(sum / smoothing);
    }
    return out;
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
    required this.slopePerMinute,
    required this.consecutiveDrop,
  });

  final bool triggered;
  final double peakOd;
  final double odNow;

  /// 每读数间隔的斜率。
  final double slope;

  /// 折算到每分钟的斜率（判据用的就是这个）。
  final double slopePerMinute;

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
  int sampleIntervalSeconds = 5,
}) {
  if (finished) return FermentationPhase.finished;
  if (verdict.triggered) return FermentationPhase.lysis;
  if (ods.length < 2) return FermentationPhase.lagGrowth;
  final slopePerMinute = HarvestDetector._slope(ods.sublist(ods.length - 2)) *
      60 /
      sampleIntervalSeconds;
  if (verdict.peakOd < 0.3) return FermentationPhase.lagGrowth;
  if (slopePerMinute > 0.00025) return FermentationPhase.exponential;
  if (ods.last >= verdict.peakOd * 0.96) return FermentationPhase.stationary;
  return FermentationPhase.lysis;
}