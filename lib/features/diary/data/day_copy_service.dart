import 'package:drift/drift.dart';

import '../../../data/drift_database.dart' as db;
import '../../today/data/daily_record_repository.dart';
import '../../today/data/day_lock_repository.dart';
import '../../today/domain/daily_record_models.dart';
import '../domain/day_copy_request.dart';
import '../domain/models/food_entry.dart';
import '../domain/models/meal_entry.dart';
import '../domain/models/nutrition_values.dart';
import 'sources/diary_local_data_source.dart';

/// Reuses the existing archive snapshots; never copies a completed workout or
/// body record. Preview is advisory, while save reloads inside one transaction.
class DayCopyService {
  final db.AppDatabase database;
  DayCopyService(this.database);

  Future<List<db.NutritionLog>> _sourceRows(DayCopyRequest request) async {
    final start = localDay(request.sourceDate);
    final end = DateTime(start.year, start.month, start.day + 1);
    final query = database.select(database.nutritionLogs)
      ..where((t) =>
          t.consumedAt.isBiggerOrEqualValue(start) &
          t.consumedAt.isSmallerThanValue(end));
    final rows = await query.get();
    return rows.where((row) {
      if (request.foodEntryId != null) {
        return row.localId == request.foodEntryId;
      }
      if (request.mealEntryId != null) {
        return row.mealEntryId == request.mealEntryId;
      }
      if (request.mealType != null) {
        return row.mealType
            .toLowerCase()
            .contains(request.mealType!.toLowerCase());
      }
      return true;
    }).toList();
  }

  Future<DayCopyPreview> preview(DayCopyRequest request) async {
    final rows = await _sourceRows(request);
    final ids = rows.map((row) => row.archiveLocalId).whereType<int>().toSet();
    final archives = ids.isEmpty
        ? <db.OffProductsArchiveData>[]
        : await (database.select(database.offProductsArchive)
              ..where((t) => t.localId.isIn(ids)))
            .get();
    final byId = {for (final archive in archives) archive.localId: archive};
    final barcodes = rows
        .where((row) => row.archiveLocalId == null)
        .map((row) => row.legacyBarcode)
        .whereType<String>()
        .toSet();
    final products = barcodes.isEmpty
        ? <db.Product>[]
        : await (database.select(database.products)
              ..where((t) => t.barcode.isIn(barcodes)))
            .get();
    final byBarcode = {
      for (final product in products) product.barcode: product
    };
    final foods = <CopyFoodPreview>[];
    var total = const NutritionValues();
    for (final row in rows) {
      final archive = byId[row.archiveLocalId];
      final product = byBarcode[row.legacyBarcode];
      if (archive == null && product == null) {
        throw StateError('Nutrition snapshot unavailable for a source food');
      }
      final nutrition = NutritionValues(
        calories: archive?.calories ?? product!.calories,
        protein: archive?.protein ?? product!.protein,
        carbs: archive?.carbs ?? product!.carbs,
        fat: archive?.fat ?? product!.fat,
      ).forAmount(row.amount);
      foods.add(CopyFoodPreview(
          archive?.productName ?? product!.name, row.amount, nutrition));
      total = total + nutrition;
    }
    return DayCopyPreview(request, foods, total);
  }

  Future<int> copy(DayCopyRequest request) => database.transaction(() async {
        await DayLockRepository(database)
            .requireUnlocked(request.destinationDate);
        final rows = await _sourceRows(request);
        if (rows.isEmpty &&
            !request.includeTrainingType &&
            !request.includeNotes) {
          return 0;
        }
        final ids =
            rows.map((row) => row.mealEntryId).whereType<String>().toSet();
        final sourceMeals = ids.isEmpty
            ? <db.MealEntry>[]
            : await (database.select(database.mealEntries)
                  ..where((t) => t.id.isIn(ids)))
                .get();
        final sourceById = {for (final meal in sourceMeals) meal.id: meal};
        final copiedGroups = <String, String>{};
        final diary = DiaryLocalDataSource(database);
        final dest = localDay(request.destinationDate);
        DateTime shifted(DateTime time) => DateTime(dest.year, dest.month,
            dest.day, time.hour, time.minute, time.second, time.millisecond);
        for (final row in rows) {
          String? newMealId;
          final oldMealId = row.mealEntryId;
          if (oldMealId != null && sourceById.containsKey(oldMealId)) {
            newMealId = copiedGroups[oldMealId];
            if (newMealId == null) {
              final meal = sourceById[oldMealId]!;
              newMealId = await diary.insertMealEntry(MealEntry(
                id: '',
                consumedAt: shifted(meal.consumedAt),
                mealType: meal.mealType,
                title: meal.title,
                source: 'manual',
              ));
              copiedGroups[oldMealId] = newMealId;
            }
          }
          await diary.insertFoodEntry(FoodEntry(
            barcode: row.legacyBarcode ?? 'UNKNOWN',
            timestamp: shifted(row.consumedAt),
            quantityInGrams: row.amount,
            mealType: row.mealType,
            archiveLocalId: row.archiveLocalId,
            mealEntryId: newMealId,
          ));
        }
        if (request.includeTrainingType || request.includeNotes) {
          final records = DailyRecordRepository(database);
          final source = await records.getDay(request.sourceDate);
          if (source != null) {
            await records.saveDay(
              request.destinationDate,
              trainingType: request.includeTrainingType
                  ? TrainingType.values.byName(source.trainingType)
                  : null,
              notes: request.includeNotes ? source.notes : null,
            );
          }
        }
        return rows.length;
      });
}
