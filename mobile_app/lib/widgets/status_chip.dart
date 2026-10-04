import 'package:flutter/material.dart';

import '../models/fermentation_project.dart';
import '../services/harvest_detector.dart';

/// 项目状态徽章：Active / Paused / Harvest time / Finished。
class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.status});

  final FermenterStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground) = switch (status) {
      FermenterStatus.active => (scheme.primaryContainer, scheme.onPrimaryContainer),
      FermenterStatus.paused => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
      FermenterStatus.harvest => (scheme.tertiaryContainer, scheme.onTertiaryContainer),
      FermenterStatus.finished => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
    };
    final icon = switch (status) {
      FermenterStatus.active => Icons.play_arrow_rounded,
      FermenterStatus.paused => Icons.pause_rounded,
      FermenterStatus.harvest => Icons.notifications_active_rounded,
      FermenterStatus.finished => Icons.check_rounded,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: foreground),
          const SizedBox(width: 4),
          Text(
            status.label,
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600, color: foreground),
          ),
        ],
      ),
    );
  }
}

/// 阶段徽章（增殖/平台/裂解等）。
class PhaseChip extends StatelessWidget {
  const PhaseChip({super.key, required this.phase});

  final FermentationPhase phase;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (phase) {
      FermentationPhase.lagGrowth => scheme.secondary,
      FermentationPhase.exponential => scheme.primary,
      FermentationPhase.stationary => Colors.orange.shade800,
      FermentationPhase.lysis => Colors.red.shade700,
      FermentationPhase.finished => scheme.onSurfaceVariant,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.gradient_rounded, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            phaseLabel(phase),
            style:
                TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color),
          ),
        ],
      ),
    );
  }
}