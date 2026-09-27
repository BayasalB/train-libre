import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:train_libre/data/drift_database.dart';
import 'package:train_libre/features/history/data/history_repository.dart';
import 'package:train_libre/features/history/presentation/day_detail_screen.dart';
import 'package:train_libre/features/today/data/daily_record_repository.dart';
import 'package:train_libre/features/today/data/today_repository.dart';
import 'package:train_libre/features/today/domain/daily_record_models.dart';
import 'package:train_libre/features/today/presentation/today_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  final day = DateTime(2026, 9, 24);

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> workout(String id, DateTime start,
      {String status = 'completed', String? notes}) async {
    await db.into(db.workoutLogs).insert(WorkoutLogsCompanion.insert(
          id: drift.Value(id),
          startTime: start,
          endTime: drift.Value(status == 'completed'
              ? start.add(const Duration(minutes: 35))
              : null),
          status: drift.Value(status),
          routineNameSnapshot: drift.Value('Routine $id'),
          notes: drift.Value(notes),
        ));
  }

  Future<void> set(String workoutId,
      {String? exerciseId,
      String name = 'OHP',
      int? block,
      double? weight = 60.5,
      int? reps = 12,
      String type = 'normal',
      bool completed = true,
      int? rpe,
      int? rir,
      String? notes}) async {
    await db.into(db.setLogs).insert(SetLogsCompanion.insert(
          workoutLogId: workoutId,
          exerciseId: drift.Value(exerciseId),
          exerciseNameSnapshot: drift.Value(name),
          exerciseBlock: drift.Value(block),
          weight: drift.Value(weight),
          reps: drift.Value(reps),
          setType: drift.Value(type),
          isCompleted: drift.Value(completed),
          rpe: drift.Value(rpe),
          rir: drift.Value(rir),
          notes: drift.Value(notes),
        ));
  }

  test(
      'completed working sets use existing tonnage semantics; live is separate',
      () async {
    await db.into(db.exercises).insert(ExercisesCompanion.insert(
          id: const drift.Value('ohp'),
          modality: const drift.Value('strength'),
          trackingType: const drift.Value('weight_reps'),
          loadMode: const drift.Value('external'),
        ));
    await db.into(db.exercises).insert(ExercisesCompanion.insert(
          id: const drift.Value('run'),
          modality: const drift.Value('cardio'),
          trackingType: const drift.Value('distance_time'),
        ));
    await workout('first', DateTime(2026, 9, 24, 23, 50), notes: 'Strong');
    await workout('second', DateTime(2026, 9, 24, 18));
    await workout('live', DateTime(2026, 9, 24, 20), status: 'ongoing');
    await set('first',
        exerciseId: 'ohp', block: 0, rpe: 8, rir: 2, notes: 'controlled');
    await set('first', exerciseId: 'ohp', block: 0, weight: 80.25, reps: 3);
    await set('first', exerciseId: 'ohp', block: 0, type: 'warmup');
    await set('first', exerciseId: 'ohp', block: 0, completed: false);
    await set('first',
        exerciseId: 'run', name: 'Run', block: 1, weight: null, reps: null);
    await set('second', exerciseId: 'ohp', block: 0, weight: 50, reps: 10);
    await set('live', exerciseId: 'ohp', block: 0, weight: 100, reps: 10);

    final today = await TodayRepository(db).load(day);
    expect(today.workouts, hasLength(3));
    final first = today.workoutDetails.summaries['first']!;
    expect(first.exerciseCount, 2);
    expect(first.workingSetCount, 3);
    expect(first.volumeKg, closeTo(60.5 * 12 + 80.25 * 3, 1e-9));
    expect(today.workoutDetails.summaries['second']!.volumeKg, 500);
    expect(today.workoutDetails.summaries['live']!.workingSetCount, 0);
    expect(today.trainingType, TrainingType.unset);
    final nextDay = await TodayRepository(db).load(DateTime(2026, 9, 25));
    expect(nextDay.workouts, isEmpty); // Cross-midnight uses start date.
  });

  test('workouts never infer or overwrite manual training type', () async {
    await workout('shoulder', day);
    final records = DailyRecordRepository(db);
    expect(
        (await TodayRepository(db).load(day)).trainingType, TrainingType.unset);
    await records.saveDay(day, trainingType: TrainingType.rest, notes: 'Rest');
    final detail = await HistoryRepository(db).loadDay(day);
    expect(detail.today.trainingType, TrainingType.rest);
    expect(detail.today.workouts, hasLength(1));
  });

  test('Today reacts when an in-progress workout is finished', () async {
    await workout('live', day, status: 'ongoing');
    await set('live', weight: 45.5, reps: 8);
    final today = TodayRepository(db);
    final before = await today.load(day);
    expect(before.workoutDetails.summaries['live']!.workingSetCount, 0);
    final changed = today.watch(day).firstWhere((state) =>
        state.workoutDetails.summaries['live']?.workingSetCount == 1);
    await (db.update(db.workoutLogs)..where((row) => row.id.equals('live')))
        .write(WorkoutLogsCompanion(
      status: const drift.Value('completed'),
      endTime: drift.Value(day.add(const Duration(minutes: 20))),
    ));
    final after = await changed;
    expect(after.workouts, hasLength(1));
    expect(after.workoutDetails.summaries['live']!.volumeKg, 45.5 * 8);
    expect(after.trainingType, TrainingType.unset);
  });

  testWidgets('Today and Day Detail render multiple sessions and set details',
      (tester) async {
    await workout('a', DateTime(2026, 9, 24, 9), notes: 'Felt good');
    await workout('b', DateTime(2026, 9, 24, 17), status: 'ongoing');
    await set('a', weight: 60.5, reps: 12, rpe: 8, rir: 2, notes: 'controlled');
    await db.into(db.workoutExerciseLogs).insert(
        WorkoutExerciseLogsCompanion.insert(
            workoutLogId: 'a',
            exerciseNameSnapshot: const drift.Value('OHP'),
            notes: const drift.Value('Keep elbows forward')));
    await set('b', weight: 80.25, reps: 3);
    await tester.pumpWidget(MaterialApp(
        home: TodayScreen(repository: TodayRepository(db), initialDate: day)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Routine a'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.textContaining('1 working sets'), findsOneWidget);
    expect(find.textContaining('726 kg volume'), findsOneWidget);
    expect(find.text('Routine b'), findsOneWidget);
    expect(find.textContaining('In progress'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(MaterialApp(
        home: DayDetailScreen(date: day, repository: HistoryRepository(db))));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Routine a'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Routine a'), findsOneWidget);
    expect(find.text('Routine b'), findsOneWidget);
    expect(find.text('Workout notes: Felt good'), findsOneWidget);
    expect(find.text('OHP notes: Keep elbows forward'), findsOneWidget);
    expect(find.textContaining('RPE 8 · RIR 2'), findsOneWidget);
    expect(find.textContaining('controlled'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
