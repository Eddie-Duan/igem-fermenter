import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/sensor_reading.dart';

/// 图表可选择展示的指标。
enum ChartMetric {
  turbidityOd('Turbidity (OD600)', Icons.bubble_chart_outlined),
  temperature('Temperature (°C)', Icons.thermostat_outlined),
  ph('pH', Icons.science_outlined);

  const ChartMetric(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// 轻量时间曲线图（CustomPainter，无第三方图表依赖）。
class LiveChart extends StatelessWidget {
  const LiveChart({
    super.key,
    required this.readings,
    required this.metric,
    this.peakAtHours,
    this.harvestAtHours,
    this.emphasizedColor,
  });

  /// 升序排列的读数。
  final List<SensorReading> readings;
  final ChartMetric metric;

  /// OD 峰值出现的时间（小时）——画一条参考虚线。
  final double? peakAtHours;
  final double? harvestAtHours;
  final Color? emphasizedColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (readings.length < 2) {
      return SizedBox(
        height: 180,
        child: Center(
          child: Text('Collecting data…',
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ),
      );
    }
    final color = emphasizedColor ?? _defaultColor(metric);
    // 必须先复制一份：Controller 是原地 append 到同一个 List 上的，
    // 直接把 readings 交给 painter 会让新旧 painter 指向同一对象，
    // shouldRepaint 的引用比较永远相等 —— 曲线便不再随采样刷新。
    final snapshot = List<SensorReading>.of(readings);
    return SizedBox(
      height: 200,
      width: double.infinity,
      child: CustomPaint(
        painter: _ChartPainter(
          readings: snapshot,
          metric: metric,
          color: color,
          peakAtHours: peakAtHours,
          harvestAtHours: harvestAtHours,
          labelStyle:
              TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }

  static Color _defaultColor(ChartMetric metric) =>
      switch (metric) {
        ChartMetric.turbidityOd => Colors.teal.shade600,
        ChartMetric.temperature => Colors.deepOrange.shade400,
        ChartMetric.ph => Colors.indigo.shade400,
      };
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({
    required this.readings,
    required this.metric,
    required this.color,
    required this.peakAtHours,
    required this.harvestAtHours,
    required this.labelStyle,
  });

  final List<SensorReading> readings;
  final ChartMetric metric;
  final Color color;
  final double? peakAtHours;
  final double? harvestAtHours;
  final TextStyle labelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 40.0, bottom = 24.0, top = 8.0, right = 8.0;
    final plot = Rect.fromLTRB(left, top, size.width - right, size.height - bottom);
    // 极窄的图上可用绘图区可能反向（宽度 < 40 + 8），直接不画，避免断言崩溃。
    if (plot.width <= 0 || plot.height <= 0) return;

    final points = <Offset>[];
    var maxX = 0.0;
    for (final reading in readings) {
      final value = switch (metric) {
        ChartMetric.turbidityOd => reading.od,
        ChartMetric.temperature => reading.temperatureC,
        ChartMetric.ph => reading.ph,
      };
      final x = reading.simHours;
      points.add(Offset(x, value));
      if (x > maxX) maxX = x;
    }
    if (points.isEmpty) return;

    final (yMin, yMax) = _yRange(points);
    final spanX = maxX == 0 ? 1.0 : maxX;

    double px(double h) => plot.left + (h / spanX) * plot.width;
    double py(double v) => plot.bottom - (v - yMin) / (yMax - yMin) * plot.height;

    final gridPaint = Paint()
      ..color = labelStyle.color!.withValues(alpha: 0.18)
      ..strokeWidth = 1;
    final gridLabel = TextPainter(
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.right,
    );

    // 横向网格 + Y 轴刻度（4 段）。
    const gridCount = 4;
    for (var i = 0; i <= gridCount; i++) {
      final v = yMin + (yMax - yMin) * i / gridCount;
      final y = py(v);
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), gridPaint);
      gridLabel
        ..text = TextSpan(
            text: _formatValue(v, metric), style: labelStyle)
        ..layout(maxWidth: left - 6);
      gridLabel.paint(canvas, Offset(left - gridLabel.width - 4, y - 6));
    }

    // 时间轴刻度：按小时取整。
    final hourTicks = _hourTicks(maxX);
    final tickPaint = Paint()
      ..color = labelStyle.color!.withValues(alpha: 0.25)
      ..strokeWidth = 1;
    for (final hour in hourTicks) {
      final x = px(hour.toDouble());
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), tickPaint);
      gridLabel
        ..text = TextSpan(text: '${hour.round()}h', style: labelStyle)
        ..layout(maxWidth: 40);
      gridLabel.paint(canvas, Offset(x - gridLabel.width / 2, plot.bottom + 6));
    }

    // 峰值参考虚线。
    if (peakAtHours != null && peakAtHours! > 0) {
      final x = px(peakAtHours!);
      canvas.drawLine(
        Offset(x, plot.top),
        Offset(x, plot.bottom),
        Paint()
          ..color = Colors.orange.shade700.withValues(alpha: 0.5)
          ..strokeWidth = 1.2
          ..style = PaintingStyle.stroke,
      );
      gridLabel
        ..text = TextSpan(
            text: 'peak', style: TextStyle(fontSize: 9, color: Colors.orange.shade800))
        ..layout(maxWidth: 40);
      gridLabel.paint(canvas, Offset(x + 3, plot.top + 2));
    }
    // 收获触发参考线。
    if (harvestAtHours != null && harvestAtHours! > 0) {
      final x = px(harvestAtHours!);
      canvas.drawLine(
        Offset(x, plot.top),
        Offset(x, plot.bottom),
        Paint()
          ..color = Colors.red.shade600.withValues(alpha: 0.5)
          ..strokeWidth = 1.2
          ..style = PaintingStyle.stroke,
      );
      gridLabel
        ..text = TextSpan(
            text: 'harvest',
            style: TextStyle(fontSize: 9, color: Colors.red.shade700))
        ..layout(maxWidth: 50);
      gridLabel.paint(canvas, Offset(x + 3, plot.top + 2));
    }

    // 折线 + 渐变面积。
    final linePath = Path();
    final areaPath = Path();
    for (var i = 0; i < points.length; i++) {
      final p = Offset(px(points[i].dx), py(points[i].dy));
      if (i == 0) {
        linePath.moveTo(p.dx, p.dy);
        areaPath.moveTo(p.dx, p.dy);
      } else {
        linePath.lineTo(p.dx, p.dy);
        areaPath.lineTo(p.dx, p.dy);
      }
    }
    areaPath
      ..lineTo(px(points.last.dx), plot.bottom)
      ..lineTo(px(points.first.dx), plot.bottom)
      ..close();
    canvas.drawPath(
      areaPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            color.withValues(alpha: 0.30),
            color.withValues(alpha: 0.02),
          ],
        ).createShader(plot),
    );
    canvas.drawPath(
      linePath,
      Paint()
        ..color = color
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round,
    );

    // 最新点 + 数值。
    final last = points.last;
    final lastP = Offset(px(last.dx), py(last.dy));
    canvas.drawCircle(lastP, 4, Paint()..color = color);
    canvas.drawCircle(lastP, 4, Paint()..color = Colors.white.withValues(alpha: 0.9));
    gridLabel
      ..text = TextSpan(
          text: _formatValue(last.dy, metric),
          style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: color))
      ..layout(maxWidth: 80);
    // 上限不能小于下限，否则 clamp 直接抛 ArgumentError。
    final labelX =
        lastP.dx.clamp(plot.left, math.max(plot.left, plot.right - 80)).toDouble();
    gridLabel.paint(canvas, Offset(labelX, lastP.dy - 18));
  }

  /// Y 轴范围：以数据范围为准，再保证一个最小可见跨度。
  ///
  /// 三种指标的量程差了一个数量级（OD 约 0–1.3、温度约 20–40、pH 约 6.5–7.1），
  /// 用固定量程会让曲线挤成一条直线；用纯数据范围又会让微小噪声被放大成
  /// 剧烈波动，所以取「数据范围」与「最小跨度」的较大者。
  /// 返回的范围始终完整包住所有数据点，读数不会被画到绘图区之外。
  (double, double) _yRange(List<Offset> points) {
    var minValue = double.infinity;
    var maxValue = -double.infinity;
    for (final p in points) {
      if (p.dy < minValue) minValue = p.dy;
      if (p.dy > maxValue) maxValue = p.dy;
    }

    final minSpan = switch (metric) {
      ChartMetric.turbidityOd => 0.2,
      ChartMetric.temperature => 4.0,
      ChartMetric.ph => 0.5,
    };

    var span = maxValue - minValue;
    if (span < minSpan) {
      final pad = (minSpan - span) / 2;
      minValue -= pad;
      maxValue += pad;
      span = minSpan;
    }

    // 上下各留 12% 呼吸空间，曲线不会贴着上下边框。
    final margin = span * 0.12;
    var yMin = minValue - margin;
    var yMax = maxValue + margin;

    if (metric == ChartMetric.turbidityOd && minValue >= 0) {
      // OD 是非负量：下边界收到 0。数据最小值本身 ≥ 0，收边不会裁掉任何点。
      yMin = math.max(0.0, yMin);
    }
    return (yMin, yMax);
  }

  static List<int> _hourTicks(double maxHours) {
    final step = maxHours <= 6 ? 2 : (maxHours <= 14 ? 4 : 6);
    final ticks = <int>[];
    for (var h = 0; h <= maxHours + 0.01; h += step) {
      ticks.add(h);
    }
    return ticks;
  }

  /// 刻度与数值标签：OD 保留 3 位（与列表/CSV 一致），pH 2 位，温度 1 位。
  static String _formatValue(double v, ChartMetric metric) => switch (metric) {
        ChartMetric.turbidityOd => v.toStringAsFixed(3),
        ChartMetric.temperature => v.toStringAsFixed(1),
        ChartMetric.ph => v.toStringAsFixed(2),
      };

  @override
  bool shouldRepaint(covariant _ChartPainter oldDelegate) =>
      oldDelegate.readings != readings ||
      oldDelegate.metric != metric ||
      oldDelegate.color != color ||
      oldDelegate.peakAtHours != peakAtHours ||
      oldDelegate.harvestAtHours != harvestAtHours;
}
