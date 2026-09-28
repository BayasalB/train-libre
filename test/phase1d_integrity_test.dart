import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:train_libre/data/drift_database.dart';
import 'package:train_libre/data/database_helper.dart';
import 'package:train_libre/core/infrastructure/backup_manager.dart';
import 'package:train_libre/features/diary/data/sources/diary_local_data_source.dart';
import 'package:train_libre/features/diary/data/sources/food_alias_local_data_source.dart';
import 'package:train_libre/features/diary/data/sources/product_local_data_source.dart';
import 'package:train_libre/features/diary/domain/models/food_alias.dart';
import 'package:train_libre/features/diary/domain/models/food_entry.dart';
import 'package:train_libre/features/diary/domain/models/food_item.dart';
import 'package:train_libre/features/diary/domain/models/fluid_entry.dart';
import 'package:train_libre/features/diary/domain/models/saved_food_metadata.dart';
import 'package:train_libre/features/profile/data/sources/profile_local_data_source.dart';
import 'package:train_libre/features/today/data/daily_record_repository.dart';
import 'package:train_libre/features/today/data/today_repository.dart';
import 'package:train_libre/features/today/domain/daily_record_models.dart';
import 'package:train_libre/features/workout/data/sources/workout_local_data_source.dart';

final sept1 = DateTime(2026, 9, 1);
final sept10 = DateTime(2026, 9, 10);
final sept20 = DateTime(2026, 9, 20);
final sept25 = DateTime(2026, 9, 25);
const beforeTraining =
    NutritionTargets(calories: 2800, protein: 200, carbs: 300, fat: 90);
const afterTraining =
    NutritionTargets(calories: 2700, protein: 205, carbs: 280, fat: 85);
const beforeRest =
    NutritionTargets(calories: 2300, protein: 180, carbs: 220, fat: 75);
const afterRest =
    NutritionTargets(calories: 2200, protein: 185, carbs: 200, fat: 70);
final label = SavedFoodMetadata(
    servingSize: 45.5,
    servingUnit: 'g',
    source: NutritionSource.label,
    verified: true,
    verifiedAt: DateTime(2026, 9, 1),
    notes: 'Exact label',
    productPhotoRef: 'food/whey.jpg',
    labelPhotoRef: 'food/label.jpg');
FoodItem food(String name, {double calories = 288.97}) => FoodItem(
    barcode: 'whey',
    name: name,
    calories: calories,
    protein: 15.65,
    carbs: 11.85,
    fat: 19.89,
    sodium: .123,
    source: FoodItemSource.user,
    metadata: label);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late Directory dir;
  late DiaryLocalDataSource diary;
  late ProductLocalDataSource products;
  late FoodAliasLocalDataSource aliases;
  late DailyRecordRepository days;
  late TodayRepository today;
  void connect() {
    db = AppDatabase(NativeDatabase(File('${dir.path}/data.sqlite')));
    DatabaseHelper.setDriftDb(db);
    diary = DiaryLocalDataSource(db);
    products = ProductLocalDataSource.forTesting(db);
    aliases = FoodAliasLocalDataSource(db);
    days = DailyRecordRepository(db, clock: () => sept1);
    today = TodayRepository(db);
  }

  BackupManager backup() => BackupManager(
      userDb: DatabaseHelper.forTesting(db),
      productDb: products,
      workoutDb: WorkoutLocalDataSource.forTesting(db));
  Future<void> seedFood() async {
    await products.insertProduct(food('Kirkland Whey'));
    await aliases.save(
        'whey', const FoodAliasDraft(alias: 'uurag', language: 'mn'));
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('phase1d-integrity-');
    connect();
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  test(
      'snapshot survives saved-food and alias edits, gram edits, copies and day moves',
      () async {
    await seedFood();
    final id = await diary.insertFoodEntry(FoodEntry(
        barcode: 'whey',
        timestamp: sept10,
        quantityInGrams: 293.8,
        mealType: 'mealtypeLunch'));
    final old = (await db.select(db.nutritionLogs).get()).single;
    final archived = (await db.select(db.offProductsArchive).get()).single;
    await products.updateProduct(food('New label', calories: 400.25));
    final alias = (await aliases.forFood('whey')).single;
    await aliases.delete(alias.id);
    await aliases.save('whey', const FoodAliasDraft(alias: 'whey powder'));
    await diary.updateFoodEntry(FoodEntry(
        id: id,
        barcode: 'whey',
        timestamp: sept10,
        quantityInGrams: 45.5,
        mealType: 'mealtypeLunch'));
    final edited = (await db.select(db.nutritionLogs).get()).single;
    expect(edited.archiveLocalId, old.archiveLocalId);
    expect(edited.amount, 45.5);
    expect((await today.load(sept10)).nutrition.summary.calories,
        closeTo(288.97 * .455, 1e-9));
    final copyId = await diary.insertFoodEntry(FoodEntry(
        barcode: 'whey',
        timestamp: sept10,
        quantityInGrams: 21.3,
        mealType: 'mealtypeSnack',
        archiveLocalId: old.archiveLocalId));
    expect((await diary.getFoodEntryByLinkedFoodId(copyId))!.archiveLocalId,
        old.archiveLocalId);
    expect((await today.load(sept10)).nutrition.summary.calories,
        closeTo(288.97 * (.455 + .213), 1e-9));
    await diary.updateFoodEntry(FoodEntry(
        id: id,
        barcode: 'whey',
        timestamp: sept25,
        quantityInGrams: 293.8,
        mealType: 'mealtypeLunch'));
    expect((await today.load(sept10)).nutrition.summary.calories,
        closeTo(288.97 * .213, 1e-9));
    expect((await today.load(sept25)).nutrition.summary.calories,
        closeTo(288.97 * 2.938, 1e-9));
    expect((await db.select(db.offProductsArchive).get()).first.toJson(),
        archived.toJson());
    expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
  });

  test(
      'failed food insert, edit and delete roll back linked archive and fluid writes',
      () async {
    await seedFood();
    await db.customStatement(
        "CREATE TRIGGER fail_insert BEFORE INSERT ON nutrition_logs BEGIN SELECT RAISE(ABORT, 'test log failure'); END");
    await expectLater(
        diary.insertFoodEntry(FoodEntry(
            barcode: 'whey',
            timestamp: sept10,
            quantityInGrams: 21.3,
            mealType: 'mealtypeLunch')),
        throwsA(isA<Exception>()));
    expect(await db.select(db.offProductsArchive).get(), isEmpty);
    expect(await db.select(db.nutritionLogs).get(), isEmpty);
    await db.customStatement('DROP TRIGGER fail_insert');
    final id = await diary.insertFoodEntry(FoodEntry(
        barcode: 'whey',
        timestamp: sept10,
        quantityInGrams: 293.8,
        mealType: 'mealtypeLunch'));
    final original = (await db.select(db.nutritionLogs).get()).single;
    await products.insertProduct(FoodItem(
        barcode: 'oats',
        name: 'Oats',
        calories: 150.5,
        protein: 5,
        carbs: 25,
        fat: 3,
        source: FoodItemSource.user));
    await db.customStatement(
        "CREATE TRIGGER fail_update BEFORE UPDATE ON nutrition_logs BEGIN SELECT RAISE(ABORT, 'test edit failure'); END");
    await expectLater(
        diary.updateFoodEntry(FoodEntry(
            id: id,
            barcode: 'oats',
            timestamp: sept10,
            quantityInGrams: 45.5,
            mealType: 'mealtypeLunch')),
        throwsA(isA<Exception>()));
    expect((await db.select(db.offProductsArchive).get()), hasLength(1));
    expect((await db.select(db.nutritionLogs).get()).single.toJson(),
        original.toJson());
    await db.customStatement('DROP TRIGGER fail_update');
    await diary.insertFluidEntry(FluidEntry(
        timestamp: sept10,
        quantityInMl: 293.8,
        name: 'Whey drink',
        kcal: 100,
        linkedFoodEntryId: id));
    await db.customStatement(
        "CREATE TRIGGER fail_delete BEFORE DELETE ON nutrition_logs BEGIN SELECT RAISE(ABORT, 'test delete failure'); END");
    await expectLater(diary.deleteFoodEntry(id), throwsA(isA<Exception>()));
    expect((await db.select(db.nutritionLogs).get()), hasLength(1));
    expect((await db.select(db.fluidLogs).get()), hasLength(1));
    await db.customStatement('DROP TRIGGER fail_delete');
    expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
  });

  test(
      'target revisions respect effective dates, independent Rest and explicit Unset',
      () async {
    await days.saveTargets(
        effectiveFrom: sept1, training: beforeTraining, rest: beforeRest);
    final later = DailyRecordRepository(db, clock: () => sept20);
    await later.saveTargets(
        effectiveFrom: sept20, training: afterTraining, rest: afterRest);
    expect((await days.resolve(sept10)).profile!.calories, 2800);
    expect((await days.resolve(sept25)).profile!.calories, 2700);
    await days.saveDay(sept10, trainingType: TrainingType.rest);
    await days.saveDay(sept25, trainingType: TrainingType.rest);
    expect((await days.resolve(sept10)).profile!.calories, 2300);
    expect((await days.resolve(sept25)).profile!.calories, 2200);
    await days.saveDay(sept25, trainingType: TrainingType.unset);
    expect((await days.resolve(sept25)).profile!.calories, 2700);
    expect((await days.resolve(sept25)).unsetFallback, isTrue);
    expect((await days.getDay(sept25))!.date, '2026-09-25');
  });

  test('current backup restores all Phase 1 data and rejects unknown fields',
      () async {
    await seedFood();
    await products.addFavorite('whey');
    await diary.insertFoodEntry(FoodEntry(
        barcode: 'whey',
        timestamp: sept10,
        quantityInGrams: 293.8,
        mealType: 'mealtypeLunch'));
    await days.saveTargets(
        effectiveFrom: sept1, training: beforeTraining, rest: beforeRest);
    await days.saveDay(sept10,
        trainingType: TrainingType.shoulder, notes: 'Great session');
    await ProfileLocalDataSource(db).saveWeightKg(88.35, date: sept10);
    await db.into(db.workoutLogs).insert(WorkoutLogsCompanion.insert(
        id: const drift.Value('workout-backup'),
        startTime: sept10,
        routineNameSnapshot: const drift.Value('Shoulder'),
        status: const drift.Value('completed')));
    final mealId = await DatabaseHelper.forTesting(db)
        .insertMeal(name: 'Routine snack', notes: 'Template');
    await DatabaseHelper.forTesting(db)
        .addMealItem(mealId: mealId, barcode: 'whey', amount: 45.5);
    final archive = (await db.select(db.offProductsArchive).get()).single;
    final originalFood = (await products.getProductByBarcode('whey'))!;
    final alias = (await aliases.forFood('whey')).single;
    final payload =
        jsonDecode(jsonEncode(await backup().generateBackupPayloadForTesting()))
            as Map<String, dynamic>;
    expect(payload['schemaVersion'], 10);
    expect(await backup().importBackupPayloadForTesting(payload), isTrue);
    final restored = (await products.getProductByBarcode('whey'))!;
    expect(restored.id, originalFood.id);
    expect(restored.metadata.toJson(), originalFood.metadata.toJson());
    expect(restored.sodium, .123);
    expect((await aliases.forFood('whey')).single.id, alias.id);
    expect(await products.getFavoriteProducts(), hasLength(1));
    expect(
        (await diary.getEntriesForDate(sept10)).single.quantityInGrams, 293.8);
    expect((await db.select(db.offProductsArchive).get()).single.contentHash,
        archive.contentHash);
    expect((await days.getDay(sept10))!.notes, 'Great session');
    expect((await days.resolve(sept10)).profile!.calories, 2800);
    expect((await db.select(db.workoutLogs).get()).single.routineNameSnapshot,
        'Shoulder');
    expect((await db.select(db.measurements).get()).single.value, 88.35);
    expect(await DatabaseHelper.forTesting(db).getMeals(), hasLength(1));
    expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
    final unknown = Map<String, dynamic>.from(payload)
      ..['future_dataset'] = [
        {'hello': 'world'}
      ];
    expect(await backup().importBackupPayloadForTesting(unknown), isFalse);
    expect((await days.getDay(sept10))!.notes, 'Great session');
    final unknownFoodField =
        jsonDecode(jsonEncode(payload)) as Map<String, dynamic>;
    (unknownFoodField['foodEntries'] as List).single['future_nutrition'] = 99;
    expect(await backup().importBackupPayloadForTesting(unknownFoodField),
        isFalse);
    expect(
        (await diary.getEntriesForDate(sept10)).single.quantityInGrams, 293.8);
    final future = Map<String, dynamic>.from(payload)..['schemaVersion'] = 11;
    expect(await backup().importBackupPayloadForTesting(future), isFalse);
    expect((await db.select(db.nutritionLogs).get()), hasLength(1));
    final unknownAliasColumn =
        jsonDecode(jsonEncode(payload)) as Map<String, dynamic>;
    (unknownAliasColumn['food_aliases'] as List).single['future_field'] =
        'keep me';
    await expectLater(
        backup().importBackupPayloadForTesting(unknownAliasColumn),
        throwsA(isA<FormatException>()));
    expect((await aliases.forFood('whey')).single.id, alias.id);
    final unknownDailyColumn =
        jsonDecode(jsonEncode(payload)) as Map<String, dynamic>;
    (unknownDailyColumn['daily_records'] as List).single['future_field'] =
        'keep me';
    await expectLater(
        backup().importBackupPayloadForTesting(unknownDailyColumn),
        throwsA(isA<Exception>()));
    expect((await days.getDay(sept10))!.notes, 'Great session');
  });

  test('old format 7 restores old data while leaving Phase 1C tables empty',
      () async {
    await seedFood();
    await diary.insertFoodEntry(FoodEntry(
        barcode: 'whey',
        timestamp: sept10,
        quantityInGrams: 45.5,
        mealType: 'mealtypeBreakfast'));
    await days.saveTargets(
        effectiveFrom: sept1, training: beforeTraining, rest: beforeRest);
    await days.saveDay(sept10, notes: 'replace me');
    final payload =
        jsonDecode(jsonEncode(await backup().generateBackupPayloadForTesting()))
            as Map<String, dynamic>;
    payload['schemaVersion'] = 7;
    payload.remove('daily_records');
    payload.remove('nutrition_target_profiles');
    expect(await backup().importBackupPayloadForTesting(payload), isTrue);
    expect(await db.select(db.dailyRecords).get(), isEmpty);
    expect(await db.select(db.nutritionTargetProfiles).get(), isEmpty);
    expect(
        (await diary.getEntriesForDate(sept10)).single.quantityInGrams, 45.5);
    expect((await products.getProductByBarcode('whey'))!.calories, 288.97);
    expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
  });

  test(
      'old format 6 restores manual food and historical nutrition without newer tables',
      () async {
    await seedFood();
    await diary.insertFoodEntry(FoodEntry(
        barcode: 'whey',
        timestamp: sept10,
        quantityInGrams: 21.3,
        mealType: 'mealtypeBreakfast'));
    final originalArchive =
        (await db.select(db.offProductsArchive).get()).single;
    final payload =
        jsonDecode(jsonEncode(await backup().generateBackupPayloadForTesting()))
            as Map<String, dynamic>;
    payload['schemaVersion'] = 6;
    payload.remove('saved_food_products');
    payload.remove('food_aliases');
    payload.remove('daily_records');
    payload.remove('nutrition_target_profiles');
    expect(await backup().importBackupPayloadForTesting(payload), isTrue);
    expect(
        (await diary.getEntriesForDate(sept10)).single.quantityInGrams, 21.3);
    expect((await db.select(db.offProductsArchive).get()).single.contentHash,
        originalArchive.contentHash);
    expect((await products.getProductByBarcode('whey'))!.calories, 288.97);
    expect(await db.select(db.foodAliases).get(), isEmpty);
    expect(await db.select(db.dailyRecords).get(), isEmpty);
    expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
  });

  test('Today stream recalculates after restore without restarting', () async {
    await seedFood();
    await diary.insertFoodEntry(FoodEntry(
        barcode: 'whey',
        timestamp: sept10,
        quantityInGrams: 45.5,
        mealType: 'mealtypeLunch'));
    final saved = await backup().generateBackupPayloadForTesting();
    final changes = StreamIterator(today.watch(sept10));
    addTearDown(changes.cancel);
    Future<double> nextCalories() async {
      expect(await changes.moveNext().timeout(const Duration(seconds: 10)),
          isTrue);
      return changes.current.nutrition.summary.calories;
    }

    expect(await nextCalories(), closeTo(288.97 * .455, 1e-9));
    await diary
        .deleteFoodEntry((await diary.getEntriesForDate(sept10)).single.id!);
    expect(await nextCalories(), 0);
    expect(await backup().importBackupPayloadForTesting(saved), isTrue);
    expect(await nextCalories(), closeTo(288.97 * .455, 1e-9));
    expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
  });

  test(
      'manual tracking, alias and Today survive network loss and process restart',
      () async {
    await HttpOverrides.runZoned(() async {
      await seedFood();
      await diary.insertFoodEntry(FoodEntry(
          barcode: 'whey',
          timestamp: sept10,
          quantityInGrams: 21.3,
          mealType: 'mealtypeBreakfast'));
      await days.saveDay(sept10,
          trainingType: TrainingType.chest, notes: 'Offline');
      await days.saveTargets(
          effectiveFrom: sept1, training: beforeTraining, rest: beforeRest);
      await db.close();
      connect();
      expect((await aliases.find('UURAG')).single.alias, 'uurag');
      final value = await today.load(sept10);
      expect(value.nutrition.summary.calories, closeTo(288.97 * .213, 1e-9));
      expect(value.foods.single.entry.quantityInGrams, 21.3);
      expect(value.trainingType, TrainingType.chest);
      expect(value.record!.notes, 'Offline');
      expect(value.targets.profile!.calories, 2800);
    }, createHttpClient: (_) => throw StateError('Network unavailable'));
  });
}
