import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:train_libre/data/drift_database.dart';
import 'package:train_libre/data/database_helper.dart';
import 'package:train_libre/features/diary/data/sources/product_local_data_source.dart';
import 'package:train_libre/features/diary/domain/models/food_item.dart';
import 'package:train_libre/features/diary/domain/models/food_entry.dart';

const metadataColumns = [
  'serving_size',
  'serving_unit',
  'sodium',
  'nutrition_source',
  'nutrition_verified',
  'nutrition_verified_at',
  'food_notes',
  'product_photo_ref',
  'label_photo_ref'
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'real v32 schema upgrades additively, preserving all old values and snapshot hashes',
      () async {
    final directory = await Directory.systemTemp.createTemp('saved-foods-v32-');
    final file = File('${directory.path}/legacy.sqlite');
    final seed = AppDatabase(NativeDatabase(file));
    final products = ProductLocalDataSource.forTesting(seed);
    final helper = DatabaseHelper.forTesting(seed);
    final food = FoodItem(
        barcode: 'legacy',
        name: 'Legacy food',
        calories: 288.97,
        protein: 15.65,
        carbs: 11.85,
        fat: 19.89);
    await products.insertProduct(food);
    await products.updateProduct(food);
    await helper.insertFoodEntry(FoodEntry(
        barcode: 'legacy',
        timestamp: DateTime(2026, 9, 24),
        quantityInGrams: 293.8,
        mealType: 'mealtypeLunch'));
    await seed.close();
    final raw = sqlite.sqlite3.open(file.path);
    raw.execute('PRAGMA foreign_keys = OFF');
    raw.execute('DROP TABLE food_aliases');
    for (final table in [
      'products',
      'user_food_overrides',
      'off_products_archive'
    ]) {
      for (final column in metadataColumns) {
        raw.execute('ALTER TABLE $table DROP COLUMN $column');
      }
    }
    raw.execute('PRAGMA user_version = 32');
    final before = {
      for (final table in [
        'products',
        'user_food_overrides',
        'off_products_archive',
        'nutrition_logs'
      ])
        table: raw
            .select('SELECT * FROM $table')
            .map((r) => Map<String, Object?>.from(r))
            .toList()
    };
    raw.close();
    final migrated = AppDatabase(NativeDatabase(file));
    try {
      for (final entry in before.entries) {
        final after =
            await migrated.customSelect('SELECT * FROM ${entry.key}').get();
        expect(after.length, entry.value.length);
        for (var i = 0; i < after.length; i++) {
          expect(
              {for (final key in entry.value[i].keys) key: after[i].data[key]},
              entry.value[i]);
        }
      }
      expect(
          (await migrated.customSelect('PRAGMA user_version').getSingle())
              .read<int>('user_version'),
          35);
      expect(await migrated.select(migrated.foodAliases).get(), isEmpty);
      expect(
          (await migrated.select(migrated.offProductsArchive).get())
              .single
              .sodium,
          isNull);
      expect(
          (await migrated.select(migrated.offProductsArchive).get())
              .single
              .nutritionVerified,
          isFalse);
      expect(await migrated.customSelect('PRAGMA foreign_key_check').get(),
          isEmpty);
      expect(await migrated.reconcileSchema(), isEmpty);
      expect(
          await migrated
              .customSelect(
                  "SELECT name FROM sqlite_master WHERE name = 'idx_food_alias_lookup'")
              .get(),
          hasLength(1));
    } finally {
      await migrated.close();
      await directory.delete(recursive: true);
    }
  });
}
