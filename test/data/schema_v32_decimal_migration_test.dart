import 'dart:io';

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:train_libre/data/drift_database.dart';

const decimalColumns = {
  'products': ['calories'],
  'user_food_overrides': ['calories'],
  'off_products_archive': ['calories'],
  'meal_items': ['quantity_in_grams'],
  'fluid_logs': ['amount_ml', 'kcal'],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'v31 INTEGER columns upgrade without changing rows, keys, indexes or sequences',
      () async {
    final directory = await Directory.systemTemp.createTemp('train-libre-v31-');
    final file = File('${directory.path}/legacy.sqlite');
    final seed = AppDatabase(NativeDatabase(file));
    await seed.into(seed.products).insert(const ProductsCompanion(
          localId: drift.Value(42),
          id: drift.Value('stable-product-uuid'),
          barcode: drift.Value('legacy'),
          name: drift.Value('Legacy label'),
          calories: drift.Value(289),
          protein: drift.Value(15.65),
          carbs: drift.Value(11.85),
          fat: drift.Value(19.89),
          source: drift.Value('user'),
        ));
    final hash = calculateProductContentHash(
        barcode: 'legacy',
        name: 'Legacy label',
        brand: null,
        calories: 289,
        protein: 15.65,
        carbs: 11.85,
        fat: 19.89,
        sugar: null,
        fiber: null,
        salt: null,
        caffeine: null,
        caffeineMgPer100g: null,
        productQuantity: null,
        productQuantityUnit: null,
        isFluid: false,
        isLiquid: false,
        hadUserOverride: false);
    final archiveId = await seed.into(seed.offProductsArchive).insert(
        OffProductsArchiveCompanion.insert(
            id: const drift.Value('stable-archive'),
            barcode: 'legacy',
            productName: 'Legacy label',
            calories: 289,
            protein: 15.65,
            carbs: 11.85,
            fat: 19.89,
            contentHash: hash,
            source: 'user'));
    await seed.into(seed.nutritionLogs).insert(NutritionLogsCompanion(
          id: const drift.Value('stable-log'),
          amount: const drift.Value(293),
          consumedAt: drift.Value(DateTime(2026, 9, 23)),
          mealType: const drift.Value('mealtypeLunch'),
          legacyBarcode: const drift.Value('legacy'),
          archiveLocalId: drift.Value(archiveId),
        ));
    await seed.into(seed.fluidLogs).insert(FluidLogsCompanion(
          consumedAt: drift.Value(DateTime(2026, 9, 23)),
          amountMl: const drift.Value(250),
          name: const drift.Value('Legacy drink'),
          kcal: const drift.Value(30),
        ));
    await seed.close();

    // Build genuine v31 INTEGER-affinity columns, retaining its data/defaults
    // and all the additive v31 fields. Merely changing user_version would not
    // exercise SQLite's table reconstruction.
    final legacy = sqlite.sqlite3.open(file.path);
    legacy.execute('PRAGMA foreign_keys = OFF');
    for (final entry in decimalColumns.entries) {
      final name = entry.key;
      var ddl = legacy.select(
          'SELECT sql FROM sqlite_master WHERE type = ? AND name = ?',
          ['table', name]).single['sql'] as String;
      final indexes = legacy
          .select(
              'SELECT sql FROM sqlite_master WHERE type = ? AND tbl_name = ? AND sql IS NOT NULL',
              ['index', name])
          .map((r) => r['sql'] as String)
          .toList();
      for (final column in entry.value) {
        ddl = ddl.replaceAll('"$column" REAL', '"$column" INTEGER');
      }
      ddl = ddl.replaceFirst('"$name"', '"legacy_$name"');
      legacy.execute(ddl);
      legacy.execute('INSERT INTO "legacy_$name" SELECT * FROM "$name"');
      legacy.execute('DROP TABLE "$name"');
      legacy.execute('ALTER TABLE "legacy_$name" RENAME TO "$name"');
      for (final index in indexes) {
        legacy.execute(index);
      }
    }
    // Deleted highest IDs, including an empty table, must never be reused.
    legacy.execute(
        "UPDATE sqlite_sequence SET seq = 900 WHERE name = 'products'");
    legacy.execute("DELETE FROM sqlite_sequence WHERE name = 'meal_items'");
    legacy.execute(
        "INSERT INTO sqlite_sequence(name, seq) VALUES ('meal_items', 700)");
    legacy.execute('PRAGMA user_version = 31');
    final beforeRows = <String, List<Map<String, Object?>>>{};
    for (final name in [...decimalColumns.keys, 'nutrition_logs']) {
      beforeRows[name] = legacy
          .select('SELECT * FROM "$name" ORDER BY local_id')
          .map((row) => Map<String, Object?>.from(row))
          .toList();
    }
    final beforeIndexes = legacy
        .select(
            "SELECT name FROM sqlite_master WHERE type = 'index' ORDER BY name")
        .map((r) => r['name'])
        .toList();
    for (final entry in decimalColumns.entries) {
      final info = legacy.select('PRAGMA table_info("${entry.key}")');
      for (final column in entry.value) {
        expect(info.singleWhere((r) => r['name'] == column)['type'], 'INTEGER');
      }
    }
    legacy.close();

    final migrated = AppDatabase(NativeDatabase(file));
    try {
      for (final entry in beforeRows.entries) {
        final rows = await migrated
            .customSelect('SELECT * FROM "${entry.key}" ORDER BY local_id')
            .get();
        expect(rows.map((r) => r.data).toList(), entry.value);
      }
      for (final entry in decimalColumns.entries) {
        final info = await migrated
            .customSelect('PRAGMA table_info("${entry.key}")')
            .get();
        for (final column in entry.value) {
          expect(info.singleWhere((r) => r.data['name'] == column).data['type'],
              'REAL');
        }
      }
      expect((await migrated.customSelect('PRAGMA foreign_key_check').get()),
          isEmpty);
      final indexes = await migrated
          .customSelect(
              "SELECT name FROM sqlite_master WHERE type = 'index' ORDER BY name")
          .get();
      expect(indexes.map((r) => r.data['name']).toList(), beforeIndexes);
      expect(
          (await migrated
                  .customSelect(
                      "SELECT seq FROM sqlite_sequence WHERE name = 'products'")
                  .getSingle())
              .data['seq'],
          900);
      expect(
          (await migrated
                  .customSelect(
                      "SELECT seq FROM sqlite_sequence WHERE name = 'meal_items'")
                  .getSingle())
              .data['seq'],
          700);
      expect(
          (await migrated.select(migrated.offProductsArchive).get())
              .single
              .contentHash,
          hash);
      expect(
          (await migrated.select(migrated.nutritionLogs).get()).single.amount,
          293);
      await migrated.into(migrated.products).insert(const ProductsCompanion(
            barcode: drift.Value('new'),
            name: drift.Value('Decimal'),
            calories: drift.Value(288.97),
            protein: drift.Value(15.65),
            carbs: drift.Value(11.85),
            fat: drift.Value(19.89),
            source: drift.Value('user'),
          ));
      final added = await (migrated.select(migrated.products)
            ..where((p) => p.barcode.equals('new')))
          .getSingle();
      expect(added.localId, greaterThan(900));
      expect(added.calories, 288.97);
    } finally {
      await migrated.close();
      await directory.delete(recursive: true);
    }
  });
}
