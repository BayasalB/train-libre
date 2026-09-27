import 'package:drift/drift.dart';

import '../../../data/drift_database.dart' as db;
import '../../diary/data/sources/diary_local_data_source.dart';
import '../../diary/data/sources/product_local_data_source.dart';
import '../../diary/domain/calculate_daily_nutrition_use_case.dart';
import '../../diary/domain/models/fluid_entry.dart';
import '../../diary/domain/models/food_entry.dart';
import '../../diary/domain/models/food_item.dart';
import '../../today/data/today_repository.dart';
import '../../today/domain/daily_record_models.dart';

class HistoryDaySummary {
  final DateTime date;
  final TrainingType trainingType;
  final double calories;
  final double protein;
  final double carbs;
  final double fat;
  final int foodCount;
  final int missingFoods;
  final int workoutCount;
  final int measurementCount;
  final bool hasRecord;

  const HistoryDaySummary({
    required this.date,
    required this.trainingType,
    required this.calories,
    required this.protein,
    required this.carbs,
    required this.fat,
    required this.foodCount,
    required this.missingFoods,
    required this.workoutCount,
    required this.measurementCount,
    required this.hasRecord,
  });

  bool get hasActivity =>
      hasRecord ||
      foodCount > 0 ||
      workoutCount > 0 ||
      measurementCount > 0 ||
      calories != 0;
}

class HistoryDayDetail {
  final TodayData today;
  final List<db.Measurement> measurements;
  final Map<String, List<db.SetLog>> setsByWorkoutId;
  final Map<String, String> mealTitles;
  final List<FoodEntry> unavailableFoods;

  const HistoryDayDetail(this.today, this.measurements, this.setsByWorkoutId,
      this.mealTitles, this.unavailableFoods);
}

/// Month-bounded reads over the same rows used by Today. Nothing is persisted.
class HistoryRepository {
  final db.AppDatabase database;
  late final TodayRepository today = TodayRepository(database);

  HistoryRepository(this.database);

  Stream<List<HistoryDaySummary>> watchMonth(DateTime month) => database
      .customSelect('SELECT 1', readsFrom: {
        database.dailyRecords,
        database.nutritionLogs,
        database.fluidLogs,
        database.offProductsArchive,
        database.products,
        database.userFoodOverrides,
        database.workoutLogs,
        database.measurements,
      })
      .watch()
      .asyncMap((_) => loadMonth(month));

  Stream<HistoryDayDetail> watchDay(DateTime date) => database
      .customSelect('SELECT 1', readsFrom: {
        database.dailyRecords,
        database.nutritionTargetProfiles,
        database.nutritionLogs,
        database.fluidLogs,
        database.mealEntries,
        database.offProductsArchive,
        database.products,
        database.userFoodOverrides,
        database.workoutLogs,
        database.setLogs,
        database.workoutExerciseLogs,
        database.exercises,
        database.measurements,
      })
      .watch()
      .asyncMap((_) => loadDay(date));

  Future<HistoryDayDetail> loadDay(DateTime date) =>
      database.transaction(() async {
        final day = localDay(date);
        final end = DateTime(day.year, day.month, day.day + 1);
        final data = await today.load(day);
        final allFoodEntries =
            await DiaryLocalDataSource(database).getEntriesForDate(day);
        final visibleIds = data.foods.map((food) => food.entry.id).toSet();
        final unavailableFoods = allFoodEntries
            .where((entry) => !visibleIds.contains(entry.id))
            .toList();
        final measurements = await (database.select(database.measurements)
              ..where((t) =>
                  t.deletedAt.isNull() &
                  t.date.isBiggerOrEqualValue(day) &
                  t.date.isSmallerThanValue(end))
              ..orderBy([(t) => OrderingTerm.desc(t.date)]))
            .get();
        final mealIds = data.foods
            .map((food) => food.entry.mealEntryId)
            .whereType<String>()
            .toSet()
            .toList();
        final meals = mealIds.isEmpty
            ? <db.MealEntry>[]
            : await (database.select(database.mealEntries)
                  ..where((t) => t.id.isIn(mealIds) & t.deletedAt.isNull()))
                .get();
        final mealTitles = {
          for (final meal in meals)
            meal.id: meal.title?.trim().isNotEmpty == true
                ? meal.title!.trim()
                : meal.mealType
        };
        return HistoryDayDetail(data, measurements,
            data.workoutDetails.setsByWorkoutId, mealTitles, unavailableFoods);
      });

  Future<List<HistoryDaySummary>> loadMonth(DateTime month) =>
      database.transaction(() async {
        final start = DateTime(month.year, month.month);
        final end = DateTime(month.year, month.month + 1);
        final startKey = localDateKey(start);
        final endKey = localDateKey(end);

        // Each query is bounded to this month; no per-day database round trips.
        final records = await (database.select(database.dailyRecords)
              ..where((t) =>
                  t.date.isBiggerOrEqualValue(startKey) &
                  t.date.isSmallerThanValue(endKey) &
                  t.deletedAt.isNull()))
            .get();
        final logs = await (database.select(database.nutritionLogs)
              ..where((t) =>
                  t.consumedAt.isBiggerOrEqualValue(start) &
                  t.consumedAt.isSmallerThanValue(end)))
            .get();
        final fluids = await (database.select(database.fluidLogs)
              ..where((t) =>
                  t.consumedAt.isBiggerOrEqualValue(start) &
                  t.consumedAt.isSmallerThanValue(end)))
            .get();
        final workouts = await (database.select(database.workoutLogs)
              ..where((t) =>
                  t.deletedAt.isNull() &
                  t.startTime.isBiggerOrEqualValue(start) &
                  t.startTime.isSmallerThanValue(end)))
            .get();
        final measurements = await (database.select(database.measurements)
              ..where((t) =>
                  t.deletedAt.isNull() &
                  t.date.isBiggerOrEqualValue(start) &
                  t.date.isSmallerThanValue(end)))
            .get();

        final products = ProductLocalDataSource(database);
        final archiveIds =
            logs.map((e) => e.archiveLocalId).whereType<int>().toSet().toList();
        final archives = <int, FoodItem>{};
        for (var i = 0; i < archiveIds.length; i += 400) {
          archives.addAll(await products
              .getProductsByArchiveIds(archiveIds.skip(i).take(400).toList()));
        }
        final barcodes = logs
            .where((e) => e.archiveLocalId == null)
            .map((e) => e.legacyBarcode)
            .whereType<String>()
            .toSet()
            .toList();
        final byBarcode = <String, FoodItem>{};
        for (var i = 0; i < barcodes.length; i += 400) {
          for (final food in await products
              .getProductsByBarcodes(barcodes.skip(i).take(400).toList())) {
            byBarcode[food.barcode] = food;
          }
        }

        final logsByDay = <String, List<FoodEntry>>{};
        for (final row in logs) {
          final entry = FoodEntry(
              id: row.localId,
              barcode: row.legacyBarcode ?? 'UNKNOWN',
              timestamp: row.consumedAt,
              quantityInGrams: row.amount,
              mealType: row.mealType,
              archiveLocalId: row.archiveLocalId);
          logsByDay
              .putIfAbsent(localDateKey(row.consumedAt), () => [])
              .add(entry);
        }
        final fluidsByDay = <String, List<FluidEntry>>{};
        for (final row in fluids) {
          final entry = FluidEntry(
              id: row.localId,
              name: row.name,
              quantityInMl: row.amountMl,
              timestamp: row.consumedAt,
              kcal: row.kcal,
              sugarPer100ml: row.sugarPer100ml,
              carbsPer100ml: row.carbsPer100ml,
              caffeinePer100ml: row.caffeinePer100ml,
              linkedFoodEntryId: row.linkedNutritionLogId == null ? null : -1);
          fluidsByDay
              .putIfAbsent(localDateKey(row.consumedAt), () => [])
              .add(entry);
        }
        final recordsByDay = {for (final row in records) row.date: row};
        final workoutCount = <String, int>{};
        for (final row in workouts) {
          workoutCount.update(localDateKey(row.startTime), (n) => n + 1,
              ifAbsent: () => 1);
        }
        final measurementCount = <String, int>{};
        for (final row in measurements) {
          measurementCount.update(localDateKey(row.date), (n) => n + 1,
              ifAbsent: () => 1);
        }

        final calculator = CalculateDailyNutritionUseCase();
        // Calendar-day count, independent of a daylight-saving hour change.
        return List.generate(DateTime(start.year, start.month + 1, 0).day,
            (offset) {
          final date = DateTime(start.year, start.month, offset + 1);
          final key = localDateKey(date);
          final foodEntries = logsByDay[key] ?? const <FoodEntry>[];
          final fluidEntries = fluidsByDay[key] ?? const <FluidEntry>[];
          final nutrition = calculator.execute(
              goals: null,
              targetSugar: 0,
              targetFiber: 0,
              targetSalt: 0,
              targetCaffeine: 0,
              foodEntries: foodEntries,
              fluidEntries: fluidEntries,
              foodProductsByBarcode: byBarcode,
              foodProductsByArchiveLocalId: archives,
              workoutLogs: const [],
              supplementsForDate: const [],
              allSupplements: const [],
              todaysSupplementLogs: const []).summary;
          final missing = foodEntries
              .where((entry) => entry.archiveLocalId == null
                  ? !byBarcode.containsKey(entry.barcode)
                  : !archives.containsKey(entry.archiveLocalId))
              .length;
          final record = recordsByDay[key];
          return HistoryDaySummary(
              date: date,
              trainingType:
                  TrainingType.values.byName(record?.trainingType ?? 'unset'),
              calories: nutrition.calories,
              protein: nutrition.protein,
              carbs: nutrition.carbs,
              fat: nutrition.fat,
              foodCount: foodEntries.length +
                  fluidEntries.where((f) => f.linkedFoodEntryId == null).length,
              missingFoods: missing,
              workoutCount: workoutCount[key] ?? 0,
              measurementCount: measurementCount[key] ?? 0,
              hasRecord: record != null);
        });
      });
}
