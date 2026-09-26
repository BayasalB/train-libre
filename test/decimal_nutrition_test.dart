import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:train_libre/core/infrastructure/backup_manager.dart';
import 'package:train_libre/data/database_helper.dart';
import 'package:train_libre/data/drift_database.dart' show AppDatabase;
import 'package:train_libre/features/diary/data/sources/product_local_data_source.dart';
import 'package:train_libre/features/diary/domain/calculate_daily_nutrition_use_case.dart';
import 'package:train_libre/features/diary/domain/models/food_entry.dart';
import 'package:train_libre/features/diary/domain/models/food_item.dart';
import 'package:train_libre/features/diary/domain/models/fluid_entry.dart';
import 'package:train_libre/features/diary/domain/models/nutrition_values.dart';
import 'package:train_libre/features/diary/presentation/add_food_screen.dart';
import 'package:train_libre/features/health_export/data/health_export_data_source.dart';
import 'package:train_libre/features/workout/data/sources/workout_local_data_source.dart';
import 'package:train_libre/services/ai_service.dart';
import 'package:train_libre/services/ai_meal_validation.dart';
import 'package:train_libre/features/home_widgets/domain/build_home_widget_snapshot.dart';
import 'package:train_libre/features/home_widgets/domain/models/home_widget_snapshot.dart';
import 'package:train_libre/generated/app_localizations_en.dart';
import 'package:train_libre/services/unit_service.dart';
import 'package:train_libre/features/statistics/data/body_nutrition_analytics_data_adapter.dart';
import 'package:train_libre/features/statistics/domain/timeframe_block.dart';

FoodItem sampleFood({double calories = 288.97}) => FoodItem(
      barcode: 'decimal-burger',
      name: 'Label burger',
      calories: calories,
      protein: 15.65,
      carbs: 11.85,
      fat: 19.89,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('exact label scaling retains precision and rounds only for display', () {
    final values = sampleFood().nutritionFor(293.8);
    expect(values.calories, closeTo(848.99386, 1e-9));
    expect(values.protein, closeTo(45.9797, 1e-9));
    expect(values.carbs, closeTo(34.8153, 1e-9));
    expect(values.fat, closeTo(58.43682, 1e-9));
    expect(values.calories.round(), 849);
    expect(values.protein.toStringAsFixed(1), '46.0');
    expect(values.carbs.toStringAsFixed(1), '34.8');
    expect(values.fat.toStringAsFixed(1), '58.4');
    expect(() => sampleFood().nutritionFor(double.nan), throwsArgumentError);
    expect(() => sampleFood().nutritionFor(-1), throwsArgumentError);
  });

  test(
      'decimal dot/comma inputs are accepted without accepting nonfinite values',
      () {
    expect(parseNutritionNumber('293.8'), 293.8);
    expect(parseNutritionNumber(' 45,5 '), 45.5);
    expect(parseNutritionNumber('21.3'), 21.3);
    for (final invalid in ['NaN', 'Infinity', '', 'a', '1,2.3']) {
      expect(parseNutritionNumber(invalid), isNull);
    }
  });

  test('daily and meal totals sum unrounded entries', () {
    final food = sampleFood();
    final entries = [293.8, 45.5, 21.3]
        .map((amount) => FoodEntry(
              barcode: food.barcode,
              timestamp: DateTime(2026, 9, 25, 12),
              quantityInGrams: amount,
              mealType: 'mealtypeLunch',
            ))
        .toList();
    final state = CalculateDailyNutritionUseCase().execute(
      goals: null,
      targetSugar: 50,
      targetFiber: 30,
      targetSalt: 6,
      targetCaffeine: 400,
      foodEntries: entries,
      fluidEntries: [],
      foodProductsByBarcode: {food.barcode: food},
      foodProductsByArchiveLocalId: {},
      workoutLogs: [],
      supplementsForDate: [],
      allSupplements: [],
      todaysSupplementLogs: [],
    );
    final expected = food.nutritionFor(360.6);
    expect(state.summary.calories, closeTo(expected.calories, 1e-9));
    expect(state.summary.protein, closeTo(expected.protein, 1e-9));
    final meal = calculateMealCardNutritionTotals(
      items: entries.map((entry) => entry.toMap()).toList(),
      productsByBarcode: {food.barcode: food},
    );
    expect(meal.kcal, closeTo(expected.calories, 1e-9));
    expect(meal.protein, closeTo(expected.protein, 1e-9));
    SharedPreferences.setMockInitialValues({});
    final widget = buildHomeWidgetSnapshot(
        nutrition: state.summary,
        extraNutrient: 'fiber',
        l10n: AppLocalizationsEn(),
        unitService: UnitService(),
        isAiEnabled: false,
        now: DateTime(2026, 9, 25, 12));
    expect(
        widget.tiles
            .singleWhere((t) => t.slot == HomeWidgetSlot.calories)
            .value,
        closeTo(expected.calories, 1e-9));
    expect(
        widget.tiles.singleWhere((t) => t.slot == HomeWidgetSlot.protein).value,
        closeTo(expected.protein, 1e-9));
  });

  test('existing AI review round trips decimal quantities', () {
    final suggestion = AiSuggestedItem.fromJson({
      'name': 'burger',
      'estimatedGrams': 293.8,
      'servedGrams': 300.5,
      'confidence': 1.0,
    });
    final restored =
        AiSuggestedItem.fromJson(jsonDecode(jsonEncode(suggestion.toJson())));
    expect(restored.estimatedGrams, 293.8);
    expect(restored.servedGrams, 300.5);
    final values =
        AiNutritionTotals.fromFood(sampleFood(), restored.estimatedGrams);
    expect(values.kcal, closeTo(848.99386, 1e-9));
    expect(values.protein, closeTo(45.9797, 1e-9));
  });

  group('local persistence', () {
    late Directory directory;
    late AppDatabase db;
    late DatabaseHelper helper;
    late ProductLocalDataSource products;
    final now = DateTime.now();

    void connect() {
      db = AppDatabase(
          NativeDatabase(File('${directory.path}/nutrition.sqlite')));
      DatabaseHelper.setDriftDb(db);
      helper = DatabaseHelper.forTesting(db);
      products = ProductLocalDataSource.forTesting(db);
    }

    Future<DailyNutritionState> persistedSummary() async {
      final entries = await helper.getEntriesForDate(now);
      final archives = await products.getProductsByArchiveIds(
        entries.map((entry) => entry.archiveLocalId).whereType<int>().toList(),
      );
      return CalculateDailyNutritionUseCase().execute(
        goals: null,
        targetSugar: 50,
        targetFiber: 30,
        targetSalt: 6,
        targetCaffeine: 400,
        foodEntries: entries,
        fluidEntries: await helper.getAllFluidEntries(),
        foodProductsByBarcode: {},
        foodProductsByArchiveLocalId: archives,
        workoutLogs: [],
        supplementsForDate: [],
        allSupplements: [],
        todaysSupplementLogs: [],
      );
    }

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      directory = await Directory.systemTemp.createTemp('train-libre-decimal-');
      connect();
      await products.insertProduct(sampleFood());
    });
    tearDown(() async {
      await db.close();
      await directory.delete(recursive: true);
    });

    test(
        'restart, snapshot edits, quantity edits, templates, fluids and backup',
        () async {
      final entryId = await helper.insertFoodEntry(FoodEntry(
        barcode: 'decimal-burger',
        timestamp: now,
        quantityInGrams: 293.8,
        mealType: 'mealtypeLunch',
      ));
      final mealId = await helper.insertMeal(name: 'Decimal meal');
      await helper.addMealItem(
          mealId: mealId, barcode: 'decimal-burger', amount: 45.5);
      await helper.insertFluidEntry(FluidEntry(
          timestamp: now, quantityInMl: 21.3, name: 'Drink', kcal: 12.75));
      final before = (await helper.getEntriesForDate(now)).single;
      final archive = (await db.select(db.offProductsArchive).get()).single;
      expect(archive.calories, 288.97);

      await db.close();
      connect();
      final reloaded = (await helper.getEntriesForDate(now)).single;
      expect(reloaded.id, entryId);
      expect(reloaded.quantityInGrams, 293.8);
      expect(reloaded.archiveLocalId, before.archiveLocalId);
      expect((await helper.getMealItems(mealId)).single['quantity_in_grams'],
          45.5);
      expect((await helper.getAllFluidEntries()).single.quantityInMl, 21.3);

      await products.updateProduct(sampleFood(calories: 400.25));
      // A caller that omits archiveLocalId must still preserve the old snapshot.
      await helper.updateFoodEntry(FoodEntry(
        id: entryId,
        barcode: 'decimal-burger',
        timestamp: now,
        quantityInGrams: 45.5,
        mealType: 'mealtypeLunch',
      ));
      final edited = (await helper.getEntriesForDate(now)).single;
      expect(edited.quantityInGrams, 45.5);
      expect(edited.archiveLocalId, before.archiveLocalId);
      final unchangedArchive =
          (await db.select(db.offProductsArchive).get()).single;
      expect(unchangedArchive.toJson(), archive.toJson());
      expect((await persistedSummary()).summary.calories,
          closeTo(288.97 * .455 + 12.75, 1e-9));

      final health = await HealthExportDataSource(databaseHelper: helper)
          .loadPayload(lookbackDays: 10);
      expect(
          health.nutrition.single.caloriesKcal, closeTo(288.97 * .455, 1e-9));
      expect(health.hydration.single.volumeLiters, closeTo(.0213, 1e-9));
      final analytics = await BodyNutritionAnalyticsDataAdapter(
        databaseHelper: helper,
        productDatabaseHelper: products,
      ).fetch(selectedBlockType: TimeframeBlock.day, anchorDate: now);
      expect(analytics.caloriesByDay.values.single,
          closeTo(288.97 * .455 + 12.75, 1e-9));

      final backups = BackupManager(
          userDb: helper,
          productDb: products,
          workoutDb: WorkoutLocalDataSource.forTesting(db));
      final csv = await backups.buildNutritionCsv();
      expect(csv, contains('45.5'));
      expect(csv, contains((288.97 * .455).toString()));
      expect(csv, contains('12.75'));
      final payload = jsonDecode(
              jsonEncode(await backups.generateBackupPayloadForTesting()))
          as Map<String, dynamic>;
      expect(await backups.importBackupPayloadForTesting(payload), isTrue);
      expect(
          (await helper.getEntriesForDate(now)).single.quantityInGrams, 45.5);
      expect((await helper.getAllFluidEntries()).single.kcal, 12.75);
      expect((await db.select(db.offProductsArchive).get()).single.calories,
          288.97);
      expect(
          (await helper
                  .getMealItems((await helper.getMeals()).single['id'] as int))
              .single['quantity_in_grams'],
          45.5);

      await helper
          .deleteFoodEntry((await helper.getEntriesForDate(now)).single.id!);
      expect(await helper.getEntriesForDate(now), isEmpty);
      final afterDelete = (await persistedSummary()).summary;
      expect(afterDelete.calories, 12.75);
      expect(afterDelete.protein, 0);
    });
  });
}
