import 'dart:io';
import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:train_libre/data/drift_database.dart';
import 'package:train_libre/data/database_helper.dart';
import 'package:train_libre/features/diary/data/sources/food_alias_local_data_source.dart';
import 'package:train_libre/features/diary/data/sources/product_local_data_source.dart';
import 'package:train_libre/features/diary/domain/models/food_alias.dart';
import 'package:train_libre/features/diary/domain/models/food_entry.dart';
import 'package:train_libre/features/diary/domain/models/food_item.dart';
import 'package:train_libre/features/diary/domain/models/saved_food_metadata.dart';
import 'package:train_libre/features/profile/data/sources/profile_local_data_source.dart';

const migratedTables = [
  'products',
  'off_products_archive',
  'nutrition_logs',
  'food_aliases',
  'meals',
  'meal_items',
  'workout_logs',
  'measurements',
  'favorites',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('v33 to v34 preserves every existing Phase 1 row, key and sequence',
      () async {
    final dir = await Directory.systemTemp.createTemp('phase1d-migrate-');
    final file = File('${dir.path}/legacy.sqlite');
    final seed = AppDatabase(NativeDatabase(file));
    final helper = DatabaseHelper.forTesting(seed);
    final products = ProductLocalDataSource.forTesting(seed);
    final date = DateTime(2026, 9, 24, 12, 34);
    try {
      await products.insertProduct(FoodItem(
          barcode: 'whey',
          name: 'Kirkland Whey',
          calories: 288.97,
          protein: 15.65,
          carbs: 11.85,
          fat: 19.89,
          source: FoodItemSource.user,
          sodium: .123,
          metadata: SavedFoodMetadata(
              servingSize: 45.5,
              servingUnit: 'g',
              source: NutritionSource.label,
              verified: true,
              verifiedAt: date,
              notes: 'Exact label',
              productPhotoRef: 'food/whey.jpg',
              labelPhotoRef: 'food/whey-label.jpg')));
      await FoodAliasLocalDataSource(seed)
          .save('whey', const FoodAliasDraft(alias: 'uurag', language: 'mn'));
      await helper.insertFoodEntry(FoodEntry(
          barcode: 'whey',
          timestamp: date,
          quantityInGrams: 293.8,
          mealType: 'mealtypeLunch'));
      await products.addFavorite('whey');
      final mealId =
          await helper.insertMeal(name: 'After gym', notes: 'Template');
      await helper.addMealItem(mealId: mealId, barcode: 'whey', amount: 45.5);
      await seed.into(seed.workoutLogs).insert(WorkoutLogsCompanion.insert(
          id: const drift.Value('workout-stable-id'),
          startTime: date,
          routineNameSnapshot: const drift.Value('Shoulder')));
      await ProfileLocalDataSource(seed).saveWeightKg(88.35, date: date);
      await seed.close();
      final raw = sqlite.sqlite3.open(file.path);
      raw.execute('PRAGMA foreign_keys = OFF');
      raw.execute('DROP TABLE daily_records');
      raw.execute('DROP TABLE nutrition_target_profiles');
      raw.execute(
          "UPDATE sqlite_sequence SET seq = 700 WHERE name = 'nutrition_logs'");
      raw.execute('PRAGMA user_version = 33');
      final before = <String, List<Map<String, Object?>>>{
        for (final table in migratedTables)
          table: raw
              .select('SELECT * FROM $table ORDER BY rowid')
              .map((r) => Map<String, Object?>.from(r))
              .toList(),
      };
      final hash = before['off_products_archive']!.single['content_hash'];
      final aliasId = before['food_aliases']!.single['id'];
      raw.close();
      final db = AppDatabase(NativeDatabase(file));
      try {
        for (final entry in before.entries) {
          final after = (await db
                  .customSelect('SELECT * FROM ${entry.key} ORDER BY rowid')
                  .get())
              .map((r) => r.data)
              .toList();
          expect(after, entry.value,
              reason: '${entry.key} changed during additive migration');
        }
        expect(
            (await db.select(db.offProductsArchive).get()).single.contentHash,
            hash);
        expect((await db.select(db.foodAliases).get()).single.id, aliasId);
        expect((await db.select(db.nutritionLogs).get()).single.amount, 293.8);
        expect(
            (await db.select(db.mealItems).get()).single.quantityInGrams, 45.5);
        expect(await db.select(db.dailyRecords).get(), isEmpty);
        expect(await db.select(db.nutritionTargetProfiles).get(), isEmpty);
        expect(
            (await db.customSelect('PRAGMA user_version').getSingle())
                .read<int>('user_version'),
            35);
        expect(
            (await db
                    .customSelect(
                        "SELECT seq FROM sqlite_sequence WHERE name = 'nutrition_logs'")
                    .getSingle())
                .read<int>('seq'),
            700);
        expect(
            await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
        expect(await db.reconcileSchema(), isEmpty);
        expect(
            (await db
                .customSelect(
                    "SELECT name FROM sqlite_master WHERE name = 'idx_target_effective_date'")
                .get()),
            hasLength(1));
        final inserted = await db.into(db.nutritionLogs).insert(
            NutritionLogsCompanion.insert(
                amount: 21.3,
                consumedAt: date,
                mealType: const drift.Value('mealtypeSnack'),
                legacyBarcode: const drift.Value('whey')));
        expect(inserted, greaterThan(700));
      } finally {
        await db.close();
      }
    } finally {
      if (await file.exists()) await file.delete();
      await dir.delete(recursive: true);
    }
  });
}
