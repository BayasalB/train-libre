import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../data/drift_database.dart' as db;
import '../../../diary/domain/models/nutrition_values.dart';
import '../../data/workout_day_read_model.dart';

/// Read-only day presentation; the workout detail remains the editing/PR view.
class WorkoutDayCard extends StatelessWidget {
  final db.WorkoutLog workout;
  final WorkoutDaySummary? summary;
  final List<db.SetLog> sets;
  final List<db.WorkoutExerciseLog> exerciseNotes;
  final bool compact;
  final bool timeKnown;
  final VoidCallback? onOpen;

  const WorkoutDayCard({
    super.key,
    required this.workout,
    required this.summary,
    this.sets = const [],
    this.exerciseNotes = const [],
    this.compact = false,
    this.timeKnown = true,
    this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final completed = workout.status == 'completed';
    final duration = workout.endTime?.difference(workout.startTime);
    final validDuration = duration != null && !duration.isNegative;
    final time = DateFormat.Hm().format(workout.startTime);
    final end = workout.endTime == null
        ? null
        : DateFormat.Hm().format(workout.endTime!);
    final count = summary;
    final subtitle = completed
        ? [
            timeKnown
                ? '$time${end == null ? '' : ' - $end'}'
                : 'Time unknown (historical date only)',
            if (validDuration) '${duration.inMinutes} min',
            if (count != null) '${count.exerciseCount} exercises',
            if (count != null) '${count.workingSetCount} working sets',
            if (count != null && count.volumeKg > 0)
              '${formatFoodQuantity(count.volumeKg)} kg volume',
          ].join(' · ')
        : '$time · In progress';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(workout.routineNameSnapshot ?? 'Workout'),
        subtitle: Text(subtitle),
        trailing: onOpen == null ? null : const Icon(Icons.chevron_right),
        onTap: onOpen,
      ),
      if (!compact) ...[
        if (workout.notes?.trim().isNotEmpty == true)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('Workout notes: ${workout.notes!.trim()}'),
          ),
        for (final note in exerciseNotes)
          if (note.notes?.trim().isNotEmpty == true)
            Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 6),
              child: Text(
                '${note.exerciseNameSnapshot ?? 'Exercise'} notes: ${note.notes!.trim()}',
              ),
            ),
        for (final set in sets)
          Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 5),
            child: Text(_setDescription(set)),
          ),
        if (completed && onOpen != null)
          TextButton(
            onPressed: onOpen,
            child: const Text('View workout details and records'),
          ),
      ],
    ]);
  }

  String _setDescription(db.SetLog set) {
    final parts = <String>[
      set.exerciseNameSnapshot ?? 'Exercise',
      if (set.setType != 'normal') set.setType,
      if (set.weight != null) '${formatFoodQuantity(set.weight!)} kg',
      if (set.reps != null) '${set.reps} reps',
      if (set.durationSeconds != null) '${set.durationSeconds} sec',
      if (set.distance != null) '${formatFoodQuantity(set.distance!)} km',
      if (set.rpe != null) 'RPE ${set.rpe}',
      if (set.rir != null) 'RIR ${set.rir}',
      if (!set.isCompleted) 'not completed',
    ];
    final note = set.notes?.trim();
    return '${parts.join(' · ')}${note == null || note.isEmpty ? '' : '\n$note'}';
  }
}
