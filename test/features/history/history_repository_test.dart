import 'dart:async';
import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:train_libre/data/drift_database.dart';
import 'package:train_libre/features/diary/data/sources/diary_local_data_source.dart';
import 'package:train_libre/features/diary/data/sources/product_local_data_source.dart';
import 'package:train_libre/features/diary/domain/models/food_entry.dart';
import 'package:train_libre/features/diary/domain/models/food_item.dart';
import 'package:train_libre/features/diary/domain/models/fluid_entry.dart';
import 'package:train_libre/features/history/data/history_repository.dart';
import 'package:train_libre/features/today/data/daily_record_repository.dart';
import 'package:train_libre/features/today/domain/daily_record_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late HistoryRepository history;
  late DiaryLocalDataSource diary;
  late ProductLocalDataSource products;
  final sept10 = DateTime(2026, 9, 10);
  final sept25 = DateTime(2026, 9, 25);

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    history = HistoryRepository(db);
    diary = DiaryLocalDataSource(db);
    products = ProductLocalDataSource.forTesting(db);
    await products.insertProduct(FoodItem(
        barcode: 'burger',
        name: 'Label burger',
        calories: 288.97,
        protein: 15.65,
        carbs: 11.85,
        fat: 19.89,
        source: FoodItemSource.user));
  });
  tearDown(() => db.close());

  Future<int> logFood(DateTime date, double grams) =>
      diary.insertFoodEntry(FoodEntry(
          barcode: 'burger',
          timestamp: date,
          quantityInGrams: grams,
          mealType: 'mealtypeLunch'));

  test(
      'month summaries use point-in-time nutrition, fractional grams and no cached totals',
      () async {
    await logFood(sept10, 293.8);
    await products.updateProduct(FoodItem(
        barcode: 'burger',
        name: 'New label',
        calories: 999,
        protein: 99,
        carbs: 99,
        fat: 99,
        source: FoodItemSource.user));
    final day = (await history.loadMonth(sept10))[9];
    expect(day.calories, closeTo(848.99386, 1e-9));
    expect(day.protein, closeTo(45.9797, 1e-9));
    expect(day.carbs, closeTo(34.8153, 1e-9));
    expect(day.fat, closeTo(58.43682, 1e-9));
    expect((await history.loadDay(sept10)).today.nutrition.summary.calories,
        closeTo(day.calories, 1e-9));
  });

  test('standalone fluid counts, but fluid linked to food is not counted twice',
      () async {
    final id = await logFood(sept10, 21.3);
    await diary.insertFluidEntry(FluidEntry(
        timestamp: sept10,
        quantityInMl: 21.3,
        name: 'Drink with food',
        kcal: 100,
        carbsPer100ml: 10,
        linkedFoodEntryId: id));
    await diary.insertFluidEntry(FluidEntry(
        timestamp: DateTime(2026, 9, 11),
        quantityInMl: 45.5,
        name: 'Standalone drink',
        kcal: 20.25,
        carbsPer100ml: 10));
    final summaries = await history.loadMonth(sept10);
    expect(summaries[9].calories, closeTo(288.97 * .213, 1e-9));
    expect(summaries[10].calories, 20.25);
    expect(summaries[10].carbs, closeTo(4.55, 1e-9));
    expect(summaries[10].hasActivity, isTrue);
  });

  test('historical target revisions keep Rest independent from Unset',
      () async {
    const earlier =
        NutritionTargets(calories: 2800, protein: 200, carbs: 300, fat: 90);
    const later =
        NutritionTargets(calories: 2700, protein: 205, carbs: 280, fat: 85);
    const earlierRest =
        NutritionTargets(calories: 2300, protein: 180, carbs: 220, fat: 75);
    const laterRest =
        NutritionTargets(calories: 2200, protein: 185, carbs: 200, fat: 70);
    await DailyRecordRepository(db, clock: () => DateTime(2026, 9, 1))
        .saveTargets(
            effectiveFrom: DateTime(2026, 9, 1),
            training: earlier,
            rest: earlierRest);
    await DailyRecordRepository(db, clock: () => DateTime(2026, 9, 20))
        .saveTargets(
            effectiveFrom: DateTime(2026, 9, 20),
            training: later,
            rest: laterRest);
    final records = DailyRecordRepository(db);
    expect(
        (await history.loadDay(sept10)).today.targets.profile!.calories, 2800);
    expect(
        (await history.loadDay(sept25)).today.targets.profile!.calories, 2700);
    expect((await history.loadDay(sept25)).today.targets.unsetFallback, isTrue);
    await records.saveDay(sept10, trainingType: TrainingType.rest);
    await records.saveDay(sept25, trainingType: TrainingType.rest);
    expect(
        (await history.loadDay(sept10)).today.targets.profile!.calories, 2300);
    expect(
        (await history.loadDay(sept25)).today.targets.profile!.calories, 2200);
    expect(
        (await history.loadMonth(sept10))[24].trainingType, TrainingType.rest);
  });

  test('day detail aggregates food, workout sets, measurements and notes',
      () async {
    await db.into(db.mealEntries).insert(MealEntriesCompanion.insert(
        id: const drift.Value('meal-1'),
        consumedAt: sept10,
        mealType: 'mealtypeLunch',
        source: 'manual',
        title: const drift.Value('Post-workout meal')));
    await diary.insertFoodEntry(FoodEntry(
        barcode: 'burger',
        timestamp: sept10,
        quantityInGrams: 45.5,
        mealType: 'mealtypeLunch',
        mealEntryId: 'meal-1'));
    await DailyRecordRepository(db).saveDay(sept10,
        trainingType: TrainingType.shoulder, notes: 'Strong session');
    await db.into(db.workoutLogs).insert(WorkoutLogsCompanion.insert(
        id: const drift.Value('workout-1'),
        startTime: sept10,
        status: const drift.Value('completed'),
        routineNameSnapshot: const drift.Value('Shoulder')));
    await db.into(db.setLogs).insert(SetLogsCompanion.insert(
        workoutLogId: 'workout-1',
        exerciseNameSnapshot: const drift.Value('Seated OHP'),
        weight: const drift.Value(60),
        reps: const drift.Value(12)));
    await db.into(db.measurements).insert(MeasurementsCompanion.insert(
        type: 'weight', value: 88.35, unit: 'kg', date: sept10));
    await db.into(db.measurements).insert(MeasurementsCompanion.insert(
        type: 'waist', value: 82.5, unit: 'cm', date: sept10));
    final detail = await history.loadDay(sept10);
    expect(detail.today.trainingType, TrainingType.shoulder);
    expect(detail.today.record!.notes, 'Strong session');
    expect(detail.today.foods.single.entry.quantityInGrams, 45.5);
    expect(detail.today.foods.single.entry.mealEntryId, 'meal-1');
    expect(detail.mealTitles['meal-1'], 'Post-workout meal');
    expect(detail.today.workouts.single.id, 'workout-1');
    expect(detail.setsByWorkoutId['workout-1']!.single.exerciseNameSnapshot,
        'Seated OHP');
    expect(detail.today.weight!.value, 88.35);
    expect(detail.measurements.map((m) => m.type),
        containsAll(['weight', 'waist']));
  });

  test('food-only, workout-only, measurement-only and legacy days appear',
      () async {
    await logFood(DateTime(2026, 9, 5), 21.3);
    await db.into(db.workoutLogs).insert(WorkoutLogsCompanion.insert(
        id: const drift.Value('workout-only'),
        startTime: DateTime(2026, 9, 6),
        status: const drift.Value('completed')));
    await db.into(db.measurements).insert(MeasurementsCompanion.insert(
        type: 'chest', value: 100.5, unit: 'cm', date: DateTime(2026, 9, 7)));
    final days = await history.loadMonth(sept10);
    expect(days[4].hasActivity, isTrue);
    expect(days[4].trainingType, TrainingType.unset);
    expect(days[4].foodCount, 1);
    expect(days[5].workoutCount, 1);
    expect(days[5].calories, 0);
    expect(days[6].measurementCount, 1);
    final foodOnly = await history.loadDay(DateTime(2026, 9, 5));
    expect(foodOnly.today.record, isNull);
    expect(foodOnly.today.foods, hasLength(1));
    final workoutOnly = await history.loadDay(DateTime(2026, 9, 6));
    expect(workoutOnly.today.record, isNull);
    expect(workoutOnly.today.workouts, hasLength(1));
    expect(workoutOnly.today.foods, isEmpty);
    expect(
        (await history.loadDay(DateTime(2026, 9, 7))).measurements.single.type,
        'chest');
    expect(days[7].hasActivity, isFalse);
  });

  test(
      'day detail keeps an unavailable legacy food visible without invented macros',
      () async {
    await db.into(db.nutritionLogs).insert(NutritionLogsCompanion.insert(
        legacyBarcode: const drift.Value('removed-food'),
        consumedAt: sept10,
        amount: 45.5));
    final detail = await history.loadDay(sept10);
    expect(detail.today.missingFoods, 1);
    expect(detail.unavailableFoods.single.barcode, 'removed-food');
    expect(detail.unavailableFoods.single.quantityInGrams, 45.5);
    expect(detail.today.nutrition.summary.calories, 0);
  });

  test('month stream updates after food edit, move and delete', () async {
    final events = StreamIterator(history.watchMonth(sept10));
    addTearDown(events.cancel);
    Future<HistoryDaySummary> nextDay(int index) async {
      expect(
          await events.moveNext().timeout(const Duration(seconds: 10)), isTrue);
      return events.current[index];
    }

    expect((await nextDay(9)).calories, 0);
    final id = await logFood(sept10, 293.8);
    HistoryDaySummary value = await nextDay(9);
    while (value.foodCount == 0) {
      value = await nextDay(9);
    }
    expect(value.calories, closeTo(848.99386, 1e-9));
    final entry = (await diary.getEntriesForDate(sept10)).single;
    await diary.updateFoodEntry(entry.copyWith(quantityInGrams: 45.5));
    value = await nextDay(9);
    while (value.calories > 200) {
      value = await nextDay(9);
    }
    expect(value.calories, closeTo(288.97 * .455, 1e-9));
    await diary.updateFoodEntry(
        entry.copyWith(quantityInGrams: 21.3, timestamp: sept25));
    value = await nextDay(9);
    while (value.foodCount != 0) {
      value = await nextDay(9);
    }
    expect((await history.loadMonth(sept10))[24].calories,
        closeTo(288.97 * .213, 1e-9));
    await diary.deleteFoodEntry(id);
    value = await nextDay(24);
    while (value.foodCount != 0) {
      value = await nextDay(24);
    }
    expect(value.calories, 0);
  });

  test('local midnight and month boundary do not leak adjacent entries',
      () async {
    await logFood(DateTime(2026, 9, 30, 23, 59, 59, 999), 21.3);
    await logFood(DateTime(2026, 10, 1), 45.5);
    final september = await history.loadMonth(sept10);
    final october = await history.loadMonth(DateTime(2026, 10));
    expect(september, hasLength(30));
    expect(september.last.calories, closeTo(288.97 * .213, 1e-9));
    expect(october.first.calories, closeTo(288.97 * .455, 1e-9));
    expect(await history.loadMonth(DateTime(2028, 2)), hasLength(29));
  });

  test('month read stays bounded when years of other entries exist', () async {
    for (var year = 2018; year < 2030; year++) {
      for (var month = 1; month <= 12; month++) {
        await db.into(db.nutritionLogs).insert(NutritionLogsCompanion.insert(
            legacyBarcode: const drift.Value('burger'),
            consumedAt: DateTime(year, month, 15),
            amount: 100));
      }
    }
    final days = await history.loadMonth(sept10);
    expect(days, hasLength(30));
    expect(days.where((d) => d.foodCount > 0), hasLength(1));
    expect(days[14].calories, 288.97);
  });
}
