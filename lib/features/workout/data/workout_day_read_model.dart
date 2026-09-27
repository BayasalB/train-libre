import 'package:drift/drift.dart';

import '../../../data/drift_database.dart' as db;
import '../domain/classification/set_load.dart';
import '../domain/classification/workout_classification.dart';

/// A bounded, read-only projection of the existing workout and set logs.
class WorkoutDayReadModel {
  final Map<String, List<db.SetLog>> setsByWorkoutId;
  final Map<String, List<db.WorkoutExerciseLog>> exerciseNotesByWorkoutId;
  final Map<String, WorkoutDaySummary> summaries;

  const WorkoutDayReadModel(
      this.setsByWorkoutId, this.exerciseNotesByWorkoutId, this.summaries);

  static const empty = WorkoutDayReadModel({}, {}, {});

  static Future<WorkoutDayReadModel> load(
      db.AppDatabase database, List<db.WorkoutLog> workouts) async {
    if (workouts.isEmpty) return empty;
    final ids = workouts.map((workout) => workout.id).toList();
    final sets = await (database.select(database.setLogs)
          ..where((t) => t.workoutLogId.isIn(ids) & t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.logOrder)]))
        .get();
    final byWorkout = <String, List<db.SetLog>>{};
    for (final set in sets) {
      byWorkout.putIfAbsent(set.workoutLogId, () => []).add(set);
    }
    final noteRows = await (database.select(database.workoutExerciseLogs)
          ..where((t) => t.workoutLogId.isIn(ids) & t.deletedAt.isNull()))
        .get();
    final notesByWorkout = <String, List<db.WorkoutExerciseLog>>{};
    for (final note in noteRows) {
      notesByWorkout.putIfAbsent(note.workoutLogId, () => []).add(note);
    }
    final exerciseIds =
        sets.map((set) => set.exerciseId).whereType<String>().toSet();
    final exercises = exerciseIds.isEmpty
        ? <db.Exercise>[]
        : await (database.select(database.exercises)
              ..where((t) => t.id.isIn(exerciseIds)))
            .get();
    final byExercise = {
      for (final exercise in exercises) exercise.id: exercise
    };

    // Only the latest weight before this day and measurements within the day
    // are needed. Do not load a user's entire measurement history for Today.
    final first = workouts
        .map((w) => w.startTime)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    final dayStart = DateTime(first.year, first.month, first.day);
    final dayEnd = DateTime(dayStart.year, dayStart.month, dayStart.day + 1);
    final priorWeight = await (database.select(database.measurements)
          ..where((t) =>
              t.type.equals('weight') &
              t.deletedAt.isNull() &
              t.date.isSmallerThanValue(dayStart))
          ..orderBy([(t) => OrderingTerm.desc(t.date)])
          ..limit(1))
        .getSingleOrNull();
    final dayWeights = await (database.select(database.measurements)
          ..where((t) =>
              t.type.equals('weight') &
              t.deletedAt.isNull() &
              t.date.isBiggerOrEqualValue(dayStart) &
              t.date.isSmallerThanValue(dayEnd))
          ..orderBy([(t) => OrderingTerm.asc(t.date)]))
        .get();
    final weights = BodyweightHistory.fromRows([
      if (priorWeight != null) (date: priorWeight.date, kg: priorWeight.value),
      for (final row in dayWeights) (date: row.date, kg: row.value),
    ]);
    return WorkoutDayReadModel(byWorkout, notesByWorkout, {
      for (final workout in workouts)
        workout.id: WorkoutDaySummary.fromRows(
            workout, byWorkout[workout.id] ?? const [], byExercise, weights),
    });
  }
}

class WorkoutDaySummary {
  final int exerciseCount;
  final int workingSetCount;
  final double volumeKg;

  const WorkoutDaySummary(
      this.exerciseCount, this.workingSetCount, this.volumeKg);

  static WorkoutDaySummary fromRows(
    db.WorkoutLog workout,
    List<db.SetLog> sets,
    Map<String, db.Exercise> exercises,
    BodyweightHistory weights,
  ) {
    // An unfinished session's partial sets are never presented as final totals.
    if (workout.status != 'completed') return const WorkoutDaySummary(0, 0, 0);
    final exerciseBlocks = <String>{};
    var workingSets = 0;
    var volume = 0.0;
    for (final set in sets) {
      if (!set.isCompleted || set.setType.toLowerCase() == 'warmup') continue;
      workingSets++;
      exerciseBlocks.add(set.exerciseBlock == null
          ? (set.exerciseId ?? set.exerciseNameSnapshot ?? set.id)
          : '${set.exerciseBlock}');
      final exercise = exercises[set.exerciseId];
      if (!WorkoutClassification.countsTowardsMuscleLoad(
        modality: exercise?.modality,
        setType: set.setType,
        categoryName: exercise?.categoryName,
        exerciseNameSnapshot: set.exerciseNameSnapshot,
        reps: set.reps ?? 0,
        durationSeconds: set.durationSeconds ?? 0,
      )) {
        continue;
      }
      volume += setTonnageKg(
        trackingType: exercise?.trackingType,
        loadMode: exercise?.loadMode,
        loggedWeightKg: set.weight,
        reps: set.reps,
        bodyweightKg: weights.at(workout.startTime),
      );
    }
    return WorkoutDaySummary(exerciseBlocks.length, workingSets, volume);
  }
}
