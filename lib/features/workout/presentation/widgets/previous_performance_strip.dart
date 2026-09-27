import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../services/unit_service.dart';
import '../../domain/models/set_log.dart';

/// A short glance at the last completed session; the existing set cells remain
/// tappable for copying its values into the current workout.
class PreviousPerformanceStrip extends StatelessWidget {
  final List<SetLog> sets;

  const PreviousPerformanceStrip({super.key, required this.sets});

  @override
  Widget build(BuildContext context) {
    final completed = sets.where((set) => set.isCompleted == true).take(4);
    if (completed.isEmpty) return const SizedBox.shrink();
    final units = context.watch<UnitService>();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Text(
        'Previous: ${completed.map((set) => _label(set, units)).join('  ·  ')}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }

  String _label(SetLog set, UnitService units) {
    if (set.distanceKm != null || set.durationSeconds != null) {
      return [
        if (set.distanceKm != null)
          '${units.convertDisplayValue(set.distanceKm!, UnitDimension.distance).toStringAsFixed(2)} ${units.suffixFor(UnitDimension.distance)}',
        if (set.durationSeconds != null) '${set.durationSeconds} sec',
      ].join(' / ');
    }
    return '${set.weightKg == null ? 'BW' : '${units.formatDisplayWeight(set.weightKg!)} ${units.suffixFor(UnitDimension.weight)}'} × ${set.reps ?? 0}';
  }
}
