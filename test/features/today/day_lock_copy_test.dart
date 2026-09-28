import 'dart:io';

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:train_libre/core/infrastructure/backup_manager.dart';
import 'package:train_libre/data/database_helper.dart';
import 'package:train_libre/data/drift_database.dart';
import 'package:train_libre/features/diary/data/day_copy_service.dart';
import 'package:train_libre/features/diary/data/sources/diary_local_data_source.dart';
import 'package:train_libre/features/diary/data/sources/product_local_data_source.dart';
import 'package:train_libre/features/diary/domain/day_copy_request.dart';
import 'package:train_libre/features/diary/domain/models/food_entry.dart';
import 'package:train_libre/features/diary/domain/models/food_item.dart';
import 'package:train_libre/features/diary/domain/models/meal_entry.dart'
    as model;
import 'package:train_libre/features/profile/data/sources/profile_local_data_source.dart';
import 'package:train_libre/features/today/data/daily_record_repository.dart';
import 'package:train_libre/features/today/data/day_lock_repository.dart';
import 'package:train_libre/features/today/data/today_repository.dart';
import 'package:train_libre/features/today/domain/daily_record_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final first = DateTime(2026, 9, 23, 12);
  final second = DateTime(2026, 9, 24, 12);
  late Directory dir;
  late AppDatabase database;
  late DiaryLocalDataSource diary;
  late ProductLocalDataSource products;
  late DayLockRepository locks;
  late DayCopyService copy;

  void connect() {
    database = AppDatabase(NativeDatabase(File('${dir.path}/data.sqlite')));
    DatabaseHelper.setDriftDb(database);
    diary = DiaryLocalDataSource(database);
    products = ProductLocalDataSource.forTesting(database);
    locks = DayLockRepository(database);
    copy = DayCopyService(database);
  }

  Future<int> food(DateTime date,
          {String mealType = 'mealtypeBreakfast',
          String? mealEntryId,
          double grams = 293.8}) =>
      diary.insertFoodEntry(FoodEntry(
          barcode: 'oats',
          timestamp: date,
          quantityInGrams: grams,
          mealType: mealType,
          mealEntryId: mealEntryId));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('day-lock-copy-');
    connect();
    await products.insertProduct(FoodItem(
        barcode: 'oats',
        name: 'Hercules Oats',
        calories: 288.97,
        protein: 15.65,
        carbs: 11.85,
        fat: 19.89,
        source: FoodItemSource.user));
  });
  tearDown(() async {
    await database.close();
    await dir.delete(recursive: true);
  });

  test(
      'lock survives restart and blocks food, day metadata and measurement writes',
      () async {
    final id = await food(first);
    var records = DailyRecordRepository(database, clock: () => first);
    await records.saveDay(first,
        trainingType: TrainingType.shoulder, notes: 'good');
    final locked = await locks.lock(first);
    expect(locked.revision, 1);
    await database.close();
    connect();
    records = DailyRecordRepository(database, clock: () => first);
    expect(await locks.get(first), isNotNull);
    await expectLater(food(first), throwsA(isA<DayLockedException>()));
    await expectLater(
        diary.updateFoodEntry(FoodEntry(
            id: id,
            barcode: 'oats',
            timestamp: second,
            quantityInGrams: 45.5,
            mealType: 'mealtypeBreakfast')),
        throwsA(isA<DayLockedException>()));
    await expectLater(
        diary.deleteFoodEntry(id), throwsA(isA<DayLockedException>()));
    await expectLater(records.saveDay(first, notes: 'changed'),
        throwsA(isA<DayLockedException>()));
    await expectLater(
        ProfileLocalDataSource(database).saveWeightKg(99.5, date: first),
        throwsA(isA<DayLockedException>()));
    await expectLater(
        database.into(database.nutritionLogs).insert(
            NutritionLogsCompanion.insert(consumedAt: first, amount: 1)),
        throwsA(isA<Exception>()));
    expect(
        (await TodayRepository(database).load(first))
            .nutrition
            .summary
            .calories,
        closeTo(288.97 * 2.938, 1e-8));
    await locks.unlock(first);
    expect(await locks.get(first), isNull);
    await diary.deleteFoodEntry(id);
    expect((await diary.getEntriesForDate(first)), isEmpty);
    expect((await locks.lock(first)).revision, 2);
  });

  test(
      'copy food preserves snapshot, decimal quantity and new UUID; destination lock wins',
      () async {
    final id = await food(first);
    final original =
        (await database.select(database.nutritionLogs).get()).single;
    final request = DayCopyRequest(
        sourceDate: first, destinationDate: second, foodEntryId: id);
    final preview = await copy.preview(request);
    expect(preview.total.calories, closeTo(288.97 * 2.938, 1e-8));
    await locks.lock(first);
    expect(await copy.copy(request), 1);
    final rows = await database.select(database.nutritionLogs).get();
    final copied = rows.singleWhere((row) => row.id != original.id);
    expect(copied.id, isNot(original.id));
    expect(copied.archiveLocalId, original.archiveLocalId);
    expect(copied.amount, 293.8);
    expect(original.amount, 293.8);
    await locks.lock(second);
    await expectLater(copy.copy(request), throwsA(isA<DayLockedException>()));
    await locks.unlock(first);
    await expectLater(copy.copy(request), throwsA(isA<DayLockedException>()));
    expect((await database.select(database.nutritionLogs).get()).length, 2);
  });

  test('locked target context stays fixed when a newer profile starts that day',
      () async {
    final records = DailyRecordRepository(database, clock: () => first);
    await records.saveTargets(
        effectiveFrom: first,
        training: const NutritionTargets(
            calories: 2800, protein: 200, carbs: 300, fat: 80),
        rest: const NutritionTargets(
            calories: 2200, protein: 180, carbs: 200, fat: 70));
    await records.saveDay(first, trainingType: TrainingType.rest);
    await locks.lock(first);
    await records.saveTargets(
        effectiveFrom: first,
        training: const NutritionTargets(
            calories: 2700, protein: 195, carbs: 280, fat: 75),
        rest: const NutritionTargets(
            calories: 2100, protein: 170, carbs: 190, fat: 65));
    expect((await records.resolve(first)).profile!.calories, 2200);
    expect((await locks.get(first))!.targetKind, 'rest');
    await locks.unlock(first);
    expect((await records.resolve(first)).profile!.calories, 2100);
  });

  test('repeat breakfast and copy whole meal preserve grouping and snapshots',
      () async {
    final mealId = await diary.insertMealEntry(model.MealEntry(
        id: '',
        consumedAt: first,
        mealType: 'mealtypeBreakfast',
        title: 'Breakfast',
        source: 'manual'));
    await food(first, mealEntryId: mealId, grams: 80);
    await food(first.add(const Duration(minutes: 2)),
        mealEntryId: mealId, grams: 45.5);
    await food(first, mealType: 'mealtypeLunch', grams: 21.3);
    final breakfast = DayCopyRequest(
        sourceDate: first, destinationDate: second, mealType: 'breakfast');
    expect((await copy.preview(breakfast)).foods.length, 2);
    expect(await copy.copy(breakfast), 2);
    final copied = await diary.getEntriesForDate(second);
    expect(copied.map((row) => row.quantityInGrams), containsAll([80, 45.5]));
    expect(copied.map((row) => row.mealEntryId).toSet(), hasLength(1));
    expect(copied.first.mealEntryId, isNot(mealId));
    expect((await diary.getEntriesForDate(first)), hasLength(3));
    final mealRequest = DayCopyRequest(
        sourceDate: first, destinationDate: second, mealEntryId: mealId);
    expect(await copy.copy(mealRequest), 2);
    expect((await diary.getEntriesForDate(second)), hasLength(4));
  });

  test('copy previous day defaults to food, with optional notes and training',
      () async {
    await food(first);
    final records = DailyRecordRepository(database, clock: () => first);
    await records.saveDay(first,
        trainingType: TrainingType.back, notes: 'heavy');
    final basic = DayCopyRequest(sourceDate: first, destinationDate: second);
    expect(await copy.copy(basic), 1);
    expect(await records.getDay(second), isNull);
    final withMetadata = DayCopyRequest(
        sourceDate: first,
        destinationDate: second,
        includeTrainingType: true,
        includeNotes: true);
    expect(await copy.copy(withMetadata), 1);
    expect((await records.getDay(second))?.trainingType, 'back');
    expect((await records.getDay(second))?.notes, 'heavy');
  });

  test('empty previous day can copy explicitly selected metadata only',
      () async {
    final records = DailyRecordRepository(database, clock: () => first);
    await records.saveDay(first,
        trainingType: TrainingType.rest, notes: 'Travel');
    final request = DayCopyRequest(
        sourceDate: first,
        destinationDate: second,
        includeTrainingType: true,
        includeNotes: true);
    expect((await copy.preview(request)).isEmpty, isTrue);
    expect(await copy.copy(request), 0);
    expect((await records.getDay(second))?.trainingType, 'rest');
    expect((await records.getDay(second))?.notes, 'Travel');
  });

  test('backup restores locks and older payload without locks stays valid',
      () async {
    await food(first);
    await locks.lock(first);
    final backup = BackupManager(
        userDb: DatabaseHelper.forTesting(database), productDb: products);
    final payload = await backup.generateBackupPayloadForTesting();
    expect((payload['day_locks'] as List), hasLength(1));
    await locks.unlock(first);
    expect(await backup.importBackupPayloadForTesting(payload), isTrue);
    expect(await locks.get(first), isNotNull);
    final old = Map<String, dynamic>.from(payload)
      ..remove('day_locks')
      ..['schemaVersion'] = 9;
    expect(await backup.importBackupPayloadForTesting(old), isTrue);
    expect(await locks.get(first), isNull);
  });

  test('invalid lock backup is rejected before existing local data changes',
      () async {
    await food(first);
    await locks.lock(first);
    final backup = BackupManager(
        userDb: DatabaseHelper.forTesting(database), productDb: products);
    final payload = await backup.generateBackupPayloadForTesting();
    final bad = Map<String, dynamic>.from(payload)
      ..['day_locks'] = [
        {
          ...Map<String, dynamic>.from((payload['day_locks'] as List).single),
          'local_date': '2026-02-31'
        }
      ];
    expect(await backup.importBackupPayloadForTesting(bad), isFalse);
    expect(await locks.get(first), isNotNull);
    expect((await diary.getEntriesForDate(first)), hasLength(1));
  });

  test('meal move and delete cannot mutate a locked source or destination',
      () async {
    final mealId = await diary.insertMealEntry(model.MealEntry(
        id: '',
        consumedAt: first,
        mealType: 'mealtypeBreakfast',
        source: 'manual'));
    await food(first, mealEntryId: mealId);
    await locks.lock(second);
    await expectLater(diary.moveMealEntryTo(mealId, second),
        throwsA(isA<DayLockedException>()));
    expect((await diary.getEntriesForDate(first)), hasLength(1));
    await locks.unlock(second);
    await locks.lock(first);
    await expectLater(diary.deleteMealEntry(mealId, deleteFoodLogs: true),
        throwsA(isA<DayLockedException>()));
    await expectLater(diary.moveMealEntryTo(mealId, second),
        throwsA(isA<DayLockedException>()));
    expect((await diary.getEntriesForDate(first)), hasLength(1));
  });

  test('database guards workout, set and progress-photo writes', () async {
    final workout = await database
        .into(database.workoutLogs)
        .insertReturning(WorkoutLogsCompanion.insert(startTime: first));
    final photo = await database.into(database.progressPhotos).insertReturning(
        ProgressPhotosCompanion.insert(
            localDate: '2026-09-23', mediaPath: 'media/progress/example.jpg'));
    await locks.lock(first);
    await expectLater(
        (database.update(database.workoutLogs)
              ..where((t) => t.id.equals(workout.id)))
            .write(
                const WorkoutLogsCompanion(status: drift.Value('completed'))),
        throwsA(isA<Exception>()));
    await expectLater(
        database
            .into(database.setLogs)
            .insert(SetLogsCompanion.insert(workoutLogId: workout.id)),
        throwsA(isA<Exception>()));
    await expectLater(
        (database.update(database.progressPhotos)
              ..where((t) => t.id.equals(photo.id)))
            .write(const ProgressPhotosCompanion(note: drift.Value('changed'))),
        throwsA(isA<Exception>()));
    await expectLater(
        (database.delete(database.progressPhotos)
              ..where((t) => t.id.equals(photo.id)))
            .go(),
        throwsA(isA<Exception>()));
  });

  test('local midnight checks each actual calendar day independently',
      () async {
    final late = DateTime(2026, 9, 23, 23, 59);
    final early = DateTime(2026, 9, 24, 0, 1);
    final workout = await database.into(database.workoutLogs).insertReturning(
          WorkoutLogsCompanion.insert(
              startTime: late,
              endTime: drift.Value(early),
              status: const drift.Value('completed')),
        );
    await locks.lock(late);
    await expectLater(food(late), throwsA(isA<DayLockedException>()));
    await food(early);
    expect((await diary.getEntriesForDate(early)), hasLength(1));
    await expectLater(
        (database.update(database.workoutLogs)
              ..where((t) => t.id.equals(workout.id)))
            .write(const WorkoutLogsCompanion(notes: drift.Value('edited'))),
        throwsA(isA<Exception>()));
  });

  test('v35 to v36 migration keeps food IDs and installs lock guards',
      () async {
    final id = await food(first);
    await database.close();
    final raw = sqlite.sqlite3.open('${dir.path}/data.sqlite');
    raw.execute('DROP TABLE day_locks');
    raw.execute('PRAGMA user_version = 35');
    raw.close();
    connect();
    expect(database.schemaVersion, 36);
    expect((await diary.getEntriesForDate(first)).single.id, id);
    expect(
        await database.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
    await locks.lock(first);
    await expectLater(food(first), throwsA(isA<DayLockedException>()));
  });
}
