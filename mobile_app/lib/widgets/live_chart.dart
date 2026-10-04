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
    return SizedBox(
      height: 200,
      width: double.infinity,
      child: CustomPaint(
        painter: _ChartPainter(
          readings: readings,
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

    final points = <Offset>[];
    var minY = double.infinity, maxY = -double.infinity, maxX = 0.0;
    for (final reading in readings) {
      final value = switch (metric) {
        ChartMetric.turbidityOd => reading.od,
        ChartMetric.temperature => reading.temperatureC,
        ChartMetric.ph => reading.ph,
      };
      final x = reading.simHours;
      points.add(Offset(x, value));
      if (value < minY) minY = value;
      if (value > maxY) maxY = value;
      if (x > maxX) maxX = x;
    }
    if (points.isEmpty) return;

    // 归一化 y 轴，留出呼吸空间。
    var yMin = minY, yMax = maxY;
    if ((yMax - yMin).abs() < 1e-9) yMax = yMin + 1;
    yMax += (yMax - yMin) * 0.15;
    yMin -= (yMax - yMin) * 0.25;
    if (metric == ChartMetric.temperature) {
      yMin = math.min(yMin, 18);
      yMax = math.max(yMax, 45);
    }
    if (metric == ChartMetric.ph) {
      yMin = 6.0;
      yMax = 7.5;
    }
    if (metric == ChartMetric.turbidityOd) {
      yMin = math.max(0, yMin);
      yMax = math.max(0.2, yMax);
    }

    double px(double h) => plot.left + (h / (maxX == 0 ? 1 : maxX)) * plot.width;
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
      final x = px(hour);
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
    gridLabel.paint(canvas,
        Offset(lastP.dx.clamp(plot.left, plot.right - 80), lastP.dy - 18));
  }

  static List<int> _hourTicks(double maxHours) {
    final step = maxHours <= 6 ? 2 : (maxHours <= 14 ? 4 : 6);
    final ticks = <int>[];
    for (var h = 0; h <= maxHours + 0.01; h += step) {
      ticks.add(h);
    }
    return ticks;
  }

  static String _formatValue(double v, ChartMetric metric) =>
      metric == ChartMetric.ph ? v.toStringAsFixed(1) : v.toStringAsFixed(1);

  @override
  bool shouldRepaint(covariant _ChartPainter oldDelegate) =>
      oldDelegate.readings != readings ||
      oldDelegate.metric != metric ||
      oldDelegate.color != color ||
      oldDelegate.peakAtHours != peakAtHours ||
      oldDelegate.harvestAtHours != harvestAtHours;
}