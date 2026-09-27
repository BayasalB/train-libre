import 'package:drift/drift.dart';
import '../../../data/drift_database.dart' as db;
import '../../diary/data/sources/diary_local_data_source.dart';
import '../../diary/data/sources/product_local_data_source.dart';
import '../../diary/domain/calculate_daily_nutrition_use_case.dart';
import '../../diary/domain/models/tracked_food_item.dart';
import '../../diary/domain/models/fluid_entry.dart';
import '../../workout/data/sources/workout_local_data_source.dart';
import '../domain/daily_record_models.dart';
import 'daily_record_repository.dart';

class TodayData {
  final DateTime date;
  final db.DailyRecord? record;
  final ResolvedDailyTargets targets;
  final DailyNutritionState nutrition;
  final List<TrackedFoodItem> foods;
  final List<FluidEntry> fluids;
  final db.Measurement? weight;
  final List<db.WorkoutLog> workouts;
  final int missingFoods;
  const TodayData(
      {required this.date,
      required this.record,
      required this.targets,
      required this.nutrition,
      required this.foods,
      required this.fluids,
      required this.weight,
      required this.workouts,
      required this.missingFoods});
  TrainingType get trainingType =>
      TrainingType.values.byName(record?.trainingType ?? 'unset');
  double? get remainingCalories => targets.profile == null
      ? null
      : targets.profile!.calories - nutrition.summary.calories;
}

/// Read model over existing food, measurement and workout tables. No stored totals.
class TodayRepository {
  final db.AppDatabase database;
  late final DailyRecordRepository records = DailyRecordRepository(database);
  TodayRepository(this.database);

  Stream<TodayData> watch(DateTime date) => database
      .customSelect('SELECT 1', readsFrom: {
        database.dailyRecords,
        database.nutritionTargetProfiles,
        database.nutritionLogs,
        database.fluidLogs,
        database.offProductsArchive,
        database.products,
        database.userFoodOverrides,
        database.measurements,
        database.workoutLogs,
        database.setLogs,
      })
      .watch()
      .asyncMap((_) => load(date));

  Future<TodayData> load(DateTime date) => database.transaction(() async {
        final start = localDay(date);
        final end = DateTime(start.year, start.month, start.day + 1);
        final diary = DiaryLocalDataSource(database);
        final products = ProductLocalDataSource(database);
        final entries = await diary.getEntriesForDate(start);
        final fluids = await diary.getFluidEntriesForDate(start);
        final archives = await products.getProductsByArchiveIds(entries
            .map((e) => e.archiveLocalId)
            .whereType<int>()
            .toSet()
            .toList());
        final legacyFoods = await products.getProductsByBarcodes(entries
            .where((e) => e.archiveLocalId == null)
            .map((e) => e.barcode)
            .toSet()
            .toList());
        final byBarcode = {for (final food in legacyFoods) food.barcode: food};
        final completed = await WorkoutLocalDataSource(database)
            .getWorkoutLogsForDateRange(start, start);
        final nutrition = CalculateDailyNutritionUseCase().execute(
            goals: null,
            targetSugar: 0,
            targetFiber: 0,
            targetSalt: 0,
            targetCaffeine: 0,
            foodEntries: entries,
            fluidEntries: fluids,
            foodProductsByBarcode: byBarcode,
            foodProductsByArchiveLocalId: archives,
            workoutLogs: completed,
            supplementsForDate: [],
            allSupplements: [],
            todaysSupplementLogs: []);
        final foods = <TrackedFoodItem>[];
        for (final entry in entries) {
          final food = entry.archiveLocalId == null
              ? byBarcode[entry.barcode]
              : archives[entry.archiveLocalId];
          if (food != null) {
            foods.add(TrackedFoodItem(entry: entry, item: food));
          }
        }
        final weight = await (database.select(database.measurements)
              ..where((t) =>
                  t.type.equals('weight') &
                  t.deletedAt.isNull() &
                  t.date.isBiggerOrEqualValue(start) &
                  t.date.isSmallerThanValue(end))
              ..orderBy([
                (t) => OrderingTerm.desc(t.date),
                (t) => OrderingTerm.desc(t.localId)
              ])
              ..limit(1))
            .getSingleOrNull();
        final workouts = await (database.select(database.workoutLogs)
              ..where((t) =>
                  t.deletedAt.isNull() &
                  t.startTime.isBiggerOrEqualValue(start) &
                  t.startTime.isSmallerThanValue(end))
              ..orderBy([(t) => OrderingTerm.asc(t.startTime)]))
            .get();
        final record = await records.getDay(start);
        return TodayData(
            date: start,
            record: record,
            targets: await records.resolve(start, record: record),
            nutrition: nutrition,
            foods: foods,
            fluids: fluids,
            weight: weight,
            workouts: workouts,
            missingFoods: entries.length - foods.length);
      });
}
