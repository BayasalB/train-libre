import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:train_libre/data/drift_database.dart';
import 'package:train_libre/data/database_helper.dart';
import 'package:train_libre/core/infrastructure/backup_manager.dart';
import 'package:train_libre/features/today/data/daily_record_repository.dart';
import 'package:train_libre/features/today/data/today_repository.dart';
import 'package:train_libre/features/today/domain/daily_record_models.dart';
import 'package:train_libre/features/diary/data/sources/product_local_data_source.dart';
import 'package:train_libre/features/diary/data/sources/diary_local_data_source.dart';
import 'package:train_libre/features/diary/domain/models/food_item.dart';
import 'package:train_libre/features/diary/domain/models/food_entry.dart';
import 'package:train_libre/features/profile/data/sources/profile_local_data_source.dart';
import 'package:train_libre/features/workout/data/sources/workout_local_data_source.dart';
import 'package:train_libre/features/app/presentation/main_tab_navigation.dart';

const training = NutritionTargets(
    calories: 2750.25, protein: 200.5, carbs: 300.25, fat: 80.75);
const rest =
    NutritionTargets(calories: 2300, protein: 200, carbs: 200, fat: 75);
final day = DateTime(2026, 9, 24);
FoodItem sample({double calories = 288.97}) => FoodItem(
    barcode: 'burger',
    name: 'Label burger',
    calories: calories,
    protein: 15.65,
    carbs: 11.85,
    fat: 19.89,
    source: FoodItemSource.user);

class NoNetwork extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      throw StateError('Network prohibited in offline test');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late Directory dir;
  late DailyRecordRepository records;
  late TodayRepository today;
  late DiaryLocalDataSource diary;
  late ProductLocalDataSource products;
  void connect() {
    db = AppDatabase(NativeDatabase(File('${dir.path}/today.sqlite')));
    DatabaseHelper.setDriftDb(db);
    records = DailyRecordRepository(db, clock: () => day);
    today = TodayRepository(db);
    diary = DiaryLocalDataSource(db);
    products = ProductLocalDataSource.forTesting(db);
  }

  BackupManager backup() => BackupManager(
      userDb: DatabaseHelper.forTesting(db),
      productDb: products,
      workoutDb: WorkoutLocalDataSource.forTesting(db));
  Future<int> addFood({double grams = 293.8, DateTime? date}) async {
    await products.insertProduct(sample());
    return diary.insertFoodEntry(FoodEntry(
        barcode: 'burger',
        timestamp: date ?? day,
        quantityInGrams: grams,
        mealType: 'mealtypeLunch'));
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('phase1c-');
    connect();
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  test('all training types persist; Unset and explicit Rest are different',
      () async {
    expect((await today.load(day)).trainingType, TrainingType.unset);
    for (final type in TrainingType.values) {
      await records.saveDay(day, trainingType: type);
      expect((await records.getDay(day))!.trainingType, type.name);
    }
    expect(await db.select(db.dailyRecords).get(), hasLength(1));
    await records.saveDay(day, notes: 'Rest is intentional');
    expect((await records.getDay(day))!.trainingType, 'rest');
    await records.saveDay(day, trainingType: TrainingType.unset);
    expect((await records.getDay(day))!.notes, 'Rest is intentional');
  });

  test('manual target selection: training, rest, unset fallback and no profile',
      () async {
    expect((await records.resolve(day)).profile, isNull);
    await records.saveTargets(
        effectiveFrom: day, training: training, rest: rest);
    for (final type in TrainingType.values) {
      await records.saveDay(day, trainingType: type);
      final selected = await records.resolve(day);
      expect(selected.profile!.calories,
          type == TrainingType.rest ? rest.calories : training.calories);
      expect(selected.unsetFallback, type == TrainingType.unset);
    }
    expect((await records.resolve(DateTime(2026, 9, 23))).profile, isNull);
  });

  test(
      'effective-date versions preserve history, same-day revisions and future targets',
      () async {
    await records.saveTargets(
        effectiveFrom: day, training: training, rest: rest);
    final original = (await records.resolve(day)).profile!;
    final tomorrow = DateTime(2026, 9, 25);
    final editor = DailyRecordRepository(db, clock: () => tomorrow);
    await editor.saveTargets(
        effectiveFrom: tomorrow, training: rest, rest: training);
    expect((await records.resolve(day)).profile!.id, original.id);
    expect((await records.resolve(tomorrow)).profile!.calories, rest.calories);
    await editor.saveTargets(
        effectiveFrom: tomorrow, training: training, rest: rest);
    expect(
        (await records.resolve(tomorrow)).profile!.calories, training.calories);
    expect((await records.resolve(day)).profile!.id, original.id);
    await editor.saveTargets(
        effectiveFrom: DateTime(2026, 10, 1), training: rest, rest: training);
    expect(
        (await records.resolve(tomorrow)).profile!.calories, training.calories);
    expect((await records.resolve(DateTime(2026, 10, 1))).profile!.calories,
        rest.calories);
    expect(
        () =>
            editor.saveTargets(effectiveFrom: day, training: rest, rest: rest),
        throwsArgumentError);
    expect(await db.select(db.nutritionTargetProfiles).get(), hasLength(8));
  });

  test('legacy adaptive goal changes do not overwrite manual Today targets',
      () async {
    await records.saveTargets(
        effectiveFrom: day, training: training, rest: rest);
    final original = (await records.resolve(day)).profile!;
    await ProfileLocalDataSource(db).saveUserGoals(
        calories: 9999, protein: 5, carbs: 5, fat: 5, water: 2500, steps: 8000);
    final selected = (await today.load(day)).targets.profile!;
    expect(selected.id, original.id);
    expect(selected.calories, 2750.25);
    expect(selected.protein, 200.5);
    expect(await db.select(db.nutritionTargetProfiles).get(), hasLength(2));
  });

  test(
      'food at 23:59:59.999 belongs to the local day and next day stays separate',
      () async {
    await addFood(date: DateTime(2026, 9, 24, 23, 59, 59, 999));
    expect((await today.load(day)).nutrition.summary.calories,
        closeTo(848.99386, 1e-9));
    expect((await today.load(DateTime(2026, 9, 25))).nutrition.summary.calories,
        0);
  });

  test('manual override pins immutable version and validates reference/date',
      () async {
    await records.saveTargets(
        effectiveFrom: day, training: training, rest: rest);
    final original = (await records.resolve(day)).profile!;
    await records.saveDay(day,
        trainingType: TrainingType.rest, targetOverrideId: original.id);
    await records.saveTargets(effectiveFrom: day, training: rest, rest: rest);
    expect((await records.resolve(day)).profile!.id, original.id);
    expect((await records.resolve(day)).overridden, isTrue);
    await records.saveDay(day, clearTargetOverride: true);
    expect((await records.resolve(day)).profile!.kind, 'rest');
    expect(() => records.saveDay(day, targetOverrideId: 'missing'),
        throwsArgumentError);
    expect(
        () => records.saveDay(DateTime(2026, 9, 23),
            targetOverrideId: original.id),
        throwsArgumentError);
  });

  test('notes, local date and timezone context persist across restart',
      () async {
    await records.saveDay(day,
        notes: 'Өнөөдөр Shoulder', trainingType: TrainingType.shoulder);
    final before = (await records.getDay(day))!;
    await db.close();
    connect();
    final after = (await records.getDay(day))!;
    expect(after.id, before.id);
    expect(after.createdAt, before.createdAt);
    expect(after.notes, 'Өнөөдөр Shoulder');
    expect(after.date, '2026-09-24');
    expect(after.timezoneName, day.timeZoneName);
    expect(after.utcOffsetMinutes, day.timeZoneOffset.inMinutes);
    expect((await today.load(day)).trainingType, TrainingType.shoulder);
  });

  test('Today totals preserve all decimal macros and archived food after edit',
      () async {
    await addFood();
    await products.updateProduct(sample(calories: 999));
    final value = await today.load(day);
    expect(value.nutrition.summary.calories, closeTo(848.99386, 1e-9));
    expect(value.nutrition.summary.protein, closeTo(45.9797, 1e-9));
    expect(value.nutrition.summary.carbs, closeTo(34.8153, 1e-9));
    expect(value.nutrition.summary.fat, closeTo(58.43682, 1e-9));
    expect(value.foods.single.item.calories, 288.97);
    expect((await today.load(DateTime(2026, 9, 25))).nutrition.summary.calories,
        0);
  });

  test(
      'reactive insert, quantity edit, date move and delete recalculate totals',
      () async {
    final queue = StreamIterator(today.watch(day));
    addTearDown(queue.cancel);
    Future<TodayData> next() async {
      expect(
          await queue.moveNext().timeout(const Duration(seconds: 10)), isTrue);
      return queue.current;
    }

    expect((await next()).nutrition.summary.calories, 0);
    final id = await addFood();
    TodayData state = await next();
    while (state.foods.isEmpty) {
      state = await next();
    }
    expect(state.nutrition.summary.calories, closeTo(848.99386, 1e-9));
    final entry = (await diary.getEntriesForDate(day)).single;
    await diary.updateFoodEntry(entry.copyWith(quantityInGrams: 45.5));
    state = await next();
    while (state.foods.single.entry.quantityInGrams != 45.5) {
      state = await next();
    }
    expect(state.nutrition.summary.calories, closeTo(131.48135, 1e-9));
    await diary
        .updateFoodEntry(entry.copyWith(timestamp: DateTime(2026, 9, 25)));
    state = await next();
    while (state.foods.isNotEmpty) {
      state = await next();
    }
    expect(state.nutrition.summary.calories, 0);
    expect((await today.load(DateTime(2026, 9, 25))).nutrition.summary.protein,
        closeTo(45.9797, 1e-9));
    await diary.updateFoodEntry(entry);
    state = await next();
    while (state.foods.isEmpty) {
      state = await next();
    }
    await diary.deleteFoodEntry(id);
    state = await next();
    while (state.foods.isNotEmpty) {
      state = await next();
    }
    expect(state.nutrition.summary.calories, 0);
    expect(state.nutrition.summary.protein, 0);
  });

  test(
      'existing measurements and workout tables feed Today without setting training type',
      () async {
    final measurements = ProfileLocalDataSource(db);
    await measurements.saveWeightKg(90, date: DateTime(2026, 9, 23));
    expect((await today.load(day)).weight, isNull);
    await measurements.saveWeightKg(89.35, date: day);
    await db.into(db.workoutLogs).insert(WorkoutLogsCompanion.insert(
        startTime: day, routineNameSnapshot: const Value('Shoulder session')));
    var value = await today.load(day);
    expect(value.weight!.value, 89.35);
    expect(value.workouts.single.routineNameSnapshot, 'Shoulder session');
    expect(value.trainingType, TrainingType.unset);
    await measurements.saveWeightKg(89.15, date: day);
    value = await today.load(day);
    expect(value.weight!.value, 89.15);
    expect(await db.select(db.measurements).get(), hasLength(2));
  });

  test('offline restart reloads foods, notes, targets and existing bodyweight',
      () async {
    await HttpOverrides.runZoned(() async {
      await addFood();
      await records.saveTargets(
          effectiveFrom: day, training: training, rest: rest);
      await records.saveDay(day,
          notes: 'Airplane mode', trainingType: TrainingType.chest);
      await ProfileLocalDataSource(db).saveWeightKg(88.4, date: day);
      await db.close();
      connect();
      final value = await today.watch(day).first;
      expect(value.nutrition.summary.calories, closeTo(848.99386, 1e-9));
      expect(value.record!.notes, 'Airplane mode');
      expect(value.targets.profile!.protein, 200.5);
      expect(value.weight!.value, 88.4);
    }, createHttpClient: (_) => throw StateError('Network prohibited'));
  });

  test(
      'current backup restores records, target revisions and stable override references',
      () async {
    await records.saveTargets(
        effectiveFrom: day, training: training, rest: rest);
    final profile = (await records.resolve(day)).profile!;
    await records.saveDay(day,
        notes: 'backup note',
        trainingType: TrainingType.back,
        targetOverrideId: profile.id);
    await records.saveTargets(
        effectiveFrom: DateTime(2026, 9, 25), training: rest, rest: training);
    final payload =
        jsonDecode(jsonEncode(await backup().generateBackupPayloadForTesting()))
            as Map<String, dynamic>;
    expect(payload['schemaVersion'], 11);
    await DatabaseHelper.forTesting(db).clearAllUserData();
    expect(await db.select(db.dailyRecords).get(), isEmpty);
    expect(await backup().importBackupPayloadForTesting(payload), isTrue);
    expect((await records.getDay(day))!.notes, 'backup note');
    expect((await records.resolve(day)).profile!.id, profile.id);
    expect((await records.resolve(DateTime(2026, 9, 25))).profile!.calories,
        rest.calories);
    expect(await db.select(db.nutritionTargetProfiles).get(), hasLength(4));
    final old = Map<String, dynamic>.from(payload)
      ..remove('daily_records')
      ..remove('nutrition_target_profiles')
      ..['schemaVersion'] = 7;
    expect(await backup().importBackupPayloadForTesting(old), isTrue);
    expect(await db.select(db.dailyRecords).get(), isEmpty);
    expect(await db.select(db.nutritionTargetProfiles).get(), isEmpty);
  });

  test('malformed new backup data is rejected without deleting current records',
      () async {
    await records.saveDay(day, notes: 'Keep me');
    final payload = await backup().generateBackupPayloadForTesting();
    (payload['daily_records'] as List).first['training_type'] = 'invalid';
    expect(await backup().importBackupPayloadForTesting(payload), isFalse);
    expect((await records.getDay(day))!.notes, 'Keep me');
  });

  test('v33 migration is additive and preserves existing food snapshots',
      () async {
    await addFood();
    final before =
        (await db.customSelect('SELECT * FROM off_products_archive').get())
            .map((r) => r.data)
            .toList();
    await db.close();
    final raw = sqlite.sqlite3.open('${dir.path}/today.sqlite');
    raw.execute('DROP TABLE daily_records');
    raw.execute('DROP TABLE nutrition_target_profiles');
    raw.execute('PRAGMA user_version = 33');
    raw.close();
    connect();
    expect(
        (await db.customSelect('PRAGMA user_version').getSingle())
            .data
            .values
            .single,
        37);
    expect(
        (await db.customSelect('SELECT * FROM off_products_archive').get())
            .map((r) => r.data)
            .toList(),
        before);
    expect(await db.select(db.dailyRecords).get(), isEmpty);
    expect(await db.select(db.nutritionTargetProfiles).get(), isEmpty);
    expect((await today.load(day)).nutrition.summary.calories,
        closeTo(848.99386, 1e-9));
  });

  test('navigation preserves old route IDs in approved visual order', () {
    expect(mainTabOrder, [0, 3, 1, 2, 4]);
    for (var id = 0; id < 5; id++) {
      expect(mainTabRoute(mainTabPosition(id)), id);
    }
    expect(mainTabPosition(1), 2); // Workout deep links still use route ID 1.
  });

  test('date keys and target validation reject invalid data', () {
    expect(localDateKey(DateTime(2026, 9, 24, 23, 59)), '2026-09-24');
    expect(() => parseLocalDateKey('2026-02-30'), throwsFormatException);
    expect(
        () => const NutritionTargets(calories: 0, protein: 1, carbs: 1, fat: 1)
            .validate(),
        throwsArgumentError);
  });
}
