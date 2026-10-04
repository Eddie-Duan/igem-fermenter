import 'package:flutter/material.dart';

/// 三个核心指标的实时卡片：温度 / pH / 浊度(OD)。
class SensorCard extends StatelessWidget {
  const SensorCard({
    super.key,
    required this.title,
    required this.unit,
    required this.value,
    required this.subtitle,
    required this.icon,
    required this.color,
    this.width,
  });

  final String title;
  final String unit;
  final String value;
  final String subtitle;
  final IconData icon;
  final Color color;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final card = Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: color),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(title,
                      style: Theme.of(context)
                          .textTheme
                          .labelMedium
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text.rich(
              TextSpan(
                text: value,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold, color: scheme.onSurface),
                children: [
                  TextSpan(
                    text: ' $unit',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Text(subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
    return width == null ? card : SizedBox(width: width, child: card);
  }
}