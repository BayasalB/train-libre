import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:train_libre/core/infrastructure/backup_manager.dart';
import 'package:train_libre/data/database_helper.dart';
import 'package:train_libre/data/drift_database.dart';
import 'package:train_libre/features/historical_import/data/historical_import_service.dart';
import 'package:train_libre/features/history/data/history_repository.dart';
import 'package:train_libre/features/diary/domain/models/saved_food_metadata.dart';
import 'package:train_libre/features/today/data/day_lock_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppDatabase db;
  late HistoricalImportService service;
  late Map<String, dynamic> sample;
  var backups = 0;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('historical-import-');
    db = AppDatabase(NativeDatabase(File('${directory.path}/test.sqlite')));
    DatabaseHelper.setDriftDb(db);
    sample = jsonDecode(
        File('documentation/examples/portable-historical-import-v1.json')
            .readAsStringSync()) as Map<String, dynamic>;
    backups = 0;
    service = HistoricalImportService(db, recoveryBackup: () async {
      backups++;
      final path = '${directory.path}/recovery-$backups.zip';
      await File(path).writeAsBytes([1, 2, 3]);
      return path;
    });
  });
  tearDown(() async {
    if (identical(DatabaseHelper.driftDb, db)) {
      await DatabaseHelper.closeAndResetDriftDb();
    } else {
      await db.close();
    }
    await directory.delete(recursive: true);
  });

  ImportResolution resolution({Set<String> targets = const {}}) =>
      ImportResolution(createTargetProfiles: targets);
  Future<int> count(String table) async =>
      (await db.customSelect('SELECT COUNT(*) AS n FROM $table').getSingle())
          .read<int>('n');
  Future<ImportPreview> preview() => service.preview(jsonEncode(sample));

  test('preview and validation never write; confirmation is mandatory',
      () async {
    final reviewed = await preview();
    expect(reviewed.counts['foodEntries'], 4);
    expect(reviewed.reportedTotalOnlyDays, 1);
    expect(reviewed.plannedOrCancelled, 2);
    expect(await count('historical_import_records'), 0);
    expect(backups, 0);
    await expectLater(
        service.importReviewed(reviewed, resolution(), confirmed: false),
        throwsA(isA<ImportReviewRequired>()));
    expect(backups, 0);
    sample['formatVersion'] = 2;
    await expectLater(preview(), throwsA(isA<ImportValidationException>()));
    expect(await count('historical_import_batches'), 0);
  });

  test('complete sample imports native rows, observations and final lock',
      () async {
    final report = await service.importReviewed(await preview(),
        resolution(targets: {'target-training', 'target-rest'}),
        confirmed: true);
    expect(report.counts['created'], greaterThan(0));
    expect(backups, 1);
    expect(await count('historical_import_batches'), 1);
    expect(await count('nutrition_logs'), 2);
    expect(await count('workout_logs'), 1);
    expect(await count('set_logs'), 6);
    expect(await count('measurements'), 4);
    expect(await count('day_locks'), 1);
    expect(await count('progress_photos'), 0);
    expect(await count('nutrition_target_profiles'), 2);
    expect((await db.customSelect('PRAGMA foreign_key_check').get()), isEmpty);
    final plans = await db.customSelect('''
      SELECT state FROM historical_import_records WHERE collection='foodEntries'
        AND external_id IN ('entry-planned','entry-cancelled')
    ''').get();
    expect(
        plans.map((e) => e.read<String>('state')), everyElement('observation'));
    final reported = await db.customSelect('''
      SELECT payload_json FROM historical_import_records
      WHERE collection='dailyRecords' AND external_id='day-total-only'
    ''').getSingle();
    expect(
        jsonDecode(reported.read<String>('payload_json'))['reportedTotal']
            ['protein'],
        '202.9');
  });

  test('same file reimport is idempotent after restart', () async {
    await service.importReviewed(await preview(), resolution(),
        confirmed: true);
    final before = await count('nutrition_logs');
    await db.close();
    db = AppDatabase(NativeDatabase(File('${directory.path}/test.sqlite')));
    DatabaseHelper.setDriftDb(db);
    service = HistoricalImportService(db, recoveryBackup: () async {
      backups++;
      final path = '${directory.path}/recovery-$backups.zip';
      await File(path).writeAsBytes([1]);
      return path;
    });
    final reviewed = await preview();
    expect(reviewed.duplicateCount, greaterThan(0));
    final report =
        await service.importReviewed(reviewed, resolution(), confirmed: true);
    expect(report.counts['created'], 0);
    expect(await count('nutrition_logs'), before);
  });

  test(
      'local data reset removes import identity so the file can be imported again',
      () async {
    await service.importReviewed(await preview(), resolution(),
        confirmed: true);
    await DatabaseHelper.forTesting(db).clearAllUserData();
    expect(await count('historical_import_records'), 0);
    expect(await count('historical_import_batches'), 0);
    expect(await count('day_locks'), 0);
    final reviewed = await preview();
    expect(reviewed.duplicateCount, 0);
    await service.importReviewed(reviewed, resolution(), confirmed: true);
    expect(await count('nutrition_logs'), 2);
  });

  test('fractional nutrition uses historical snapshot and retains decimal text',
      () async {
    sample['savedFoods'] = [];
    sample['foodAliases'] = [];
    sample['meals'] = [];
    sample['dailyRecords'] = [];
    sample['workouts'] = [];
    sample['exercises'] = [];
    sample['workoutSets'] = [];
    sample['measurements'] = [];
    sample['progressPhotos'] = [];
    sample['lockedDays'] = [];
    sample['targetProfiles'] = [];
    sample['nutritionSnapshots'] = [
      {
        'id': 'snap',
        'basis': 'per100g',
        'calories': '288.97',
        'protein': '15.65',
        'carbs': '11.85',
        'fat': '19.89',
        'provenance': 'exactLabel'
      }
    ];
    sample['foodEntries'] = [
      {
        'id': 'entry',
        'date': '2026-09-23',
        'name': 'Food',
        'status': 'consumed',
        'quantity': '293.8',
        'quantityUnit': 'g',
        'nutritionSnapshotId': 'snap'
      }
    ];
    await service.importReviewed(await preview(), resolution(),
        confirmed: true);
    final row = await db.customSelect('''
      SELECT n.amount, a.calories, a.protein FROM nutrition_logs n
      JOIN off_products_archive a ON a.local_id=n.archive_local_id
    ''').getSingle();
    expect(row.read<double>('amount'), 293.8);
    expect(row.read<double>('calories') * row.read<double>('amount') / 100,
        closeTo(848.99386, 0.00001));
    final audit = await db.customSelect('''
      SELECT payload_json FROM historical_import_records
      WHERE collection='foodEntries'
    ''').getSingle();
    expect(jsonDecode(audit.read<String>('payload_json'))['quantity'], '293.8');
  });

  test('reported total stays distinct from calculated entries in History',
      () async {
    await service.importReviewed(await preview(), resolution(),
        confirmed: true);
    final history = HistoryRepository(db);
    final totalOnly = await history.loadDay(DateTime(2026, 9, 24));
    expect(totalOnly.today.nutrition.summary.calories, 0);
    expect(totalOnly.reportedTotals.single['calories'], '2588');
    expect(totalOnly.reportedTotals.single['protein'], '202.9');
    final month = await history.loadMonth(DateTime(2026, 9));
    expect(month[23].reportedTotals.single['calories'], '2588');
    expect(month[23].calories, 0);
  });

  test('calculated and reported totals coexist without overwriting', () async {
    final days = sample['dailyRecords'] as List;
    final restaurant = days
        .cast<Map<String, dynamic>>()
        .singleWhere((day) => day['id'] == 'day-restaurant');
    restaurant['reportedTotal'] = {
      'calories': '700',
      'protein': '30',
      'provenance': 'restaurantEstimate',
    };
    await service.importReviewed(await preview(), resolution(),
        confirmed: true);
    final day = await HistoryRepository(db).loadDay(DateTime(2026, 9, 27));
    expect(day.today.nutrition.summary.calories, closeTo(720.5, 0.00001));
    expect(day.reportedTotals.single['calories'], '700');
  });

  test('partial targets remain observations without fabricated macros',
      () async {
    final target =
        (sample['targetProfiles'] as List).first as Map<String, dynamic>;
    target.remove('carbs');
    target.remove('fat');
    await service.importReviewed(
        await preview(), resolution(targets: {'target-training'}),
        confirmed: true);
    expect(await count('nutrition_target_profiles'), 0);
    final day = await HistoryRepository(db).loadDay(DateTime(2026, 9, 23));
    final imported = day.importedTargetObservations
        .singleWhere((t) => t['kind'] == 'training');
    expect(imported.containsKey('carbs'), isFalse);
    expect(imported['calories'], '2750');
  });

  test(
      'saved food suggestion requires explicit mapping and never uses name alone',
      () async {
    await db.customStatement('''
      INSERT INTO products(id,barcode,name,calories,protein,carbs,fat,source)
      VALUES ('local-oats','oats','Hercules Oats',100,1,1,1,'user')
    ''');
    final reviewed = await preview();
    expect(reviewed.foodSuggestions['food-oats'], contains('local-oats'));
    await expectLater(
        service.importReviewed(reviewed, resolution(), confirmed: true),
        throwsA(isA<ImportReviewRequired>()));
    expect(backups, 0);
    final report = await service.importReviewed(
        reviewed,
        const ImportResolution(foods: {
          'food-oats':
              FoodMapping(ImportChoice.link, localFoodId: 'local-oats'),
        }),
        confirmed: true);
    expect(report.counts['linked'], greaterThan(0));
    expect(await count('products'), 1);
    final archived = await db.customSelect('''
      SELECT a.calories FROM nutrition_logs n JOIN off_products_archive a
      ON n.archive_local_id=a.local_id WHERE n.product_id='local-oats'
    ''').getSingle();
    expect(archived.read<double>('calories'), 360);
  });

  test(
      'editing imported Saved Food leaves historical nutrition snapshot stable',
      () async {
    await service.importReviewed(await preview(), resolution(),
        confirmed: true);
    final before = await HistoryRepository(db).loadDay(DateTime(2026, 9, 23));
    expect(before.today.nutrition.summary.calories, closeTo(288, 0.00001));
    await db.customStatement('''
      UPDATE products SET calories=999, protein=99 WHERE name='Hercules Oats'
    ''');
    final after = await HistoryRepository(db).loadDay(DateTime(2026, 9, 23));
    expect(after.today.nutrition.summary.calories,
        closeTo(before.today.nutrition.summary.calories, 0.00001));
    expect(after.today.nutrition.summary.protein,
        closeTo(before.today.nutrition.summary.protein, 0.00001));
  });

  test('portable alias suggests local food even when primary names differ',
      () async {
    await db.customStatement('''
      INSERT INTO products(id,barcode,name,calories,protein,carbs,fat,source)
      VALUES ('local-oats','local-oats','My Breakfast Oats',100,1,1,1,'user')
    ''');
    await db.customStatement('''
      INSERT INTO food_aliases(id,product_barcode,alias,normalized_alias)
      VALUES ('local-alias','local-oats','ovyoos','ovyoos')
    ''');
    final reviewed = await preview();
    expect(reviewed.foodSuggestions['food-oats'], contains('local-oats'));
    expect(await count('historical_import_records'), 0);
  });

  test('ambiguous food names are suggestions only; unlinked is valid',
      () async {
    for (final id in ['a', 'b']) {
      await db.customStatement('''
        INSERT INTO products(id,barcode,name,calories,protein,carbs,fat,source)
        VALUES (?,?,?,100,1,1,1,'user')
      ''', [id, 'oats-$id', 'Hercules Oats']);
    }
    final reviewed = await preview();
    expect(reviewed.foodSuggestions['food-oats'], hasLength(2));
    await expectLater(
        service.importReviewed(reviewed, resolution(), confirmed: true),
        throwsA(isA<ImportReviewRequired>()));
    await service.importReviewed(
        reviewed,
        const ImportResolution(foods: {
          'food-oats': FoodMapping(ImportChoice.unlinked),
        }),
        confirmed: true);
    final log = await db
        .customSelect('SELECT product_id FROM nutrition_logs LIMIT 1')
        .getSingle();
    expect(log.read<String?>('product_id'), isNull);
  });

  test('existing normalized alias links once and preserves Cyrillic alias',
      () async {
    await db.customStatement('''
      INSERT INTO products(id,barcode,name,calories,protein,carbs,fat,source)
      VALUES ('local-oats','oats','Hercules Oats',100,1,1,1,'user')
    ''');
    await db.customStatement('''
      INSERT INTO food_aliases(id,product_barcode,alias,normalized_alias)
      VALUES ('existing-alias','oats','Ovyoos','ovyoos')
    ''');
    await service.importReviewed(
        await preview(),
        const ImportResolution(foods: {
          'food-oats':
              FoodMapping(ImportChoice.link, localFoodId: 'local-oats'),
        }),
        confirmed: true);
    expect(await count('food_aliases'), 2);
    final aliases =
        await db.customSelect('SELECT alias FROM food_aliases').get();
    expect(aliases.map((r) => r.read<String>('alias')),
        containsAll(['Ovyoos', 'овьёос']));
  });

  test('exercise name suggests a local exercise but only explicit link uses it',
      () async {
    await db.customStatement('''
      INSERT INTO exercises(id,is_custom,source) VALUES ('local-squat',1,'user')
    ''');
    await db.customStatement('''
      INSERT INTO exercise_translations(id,exercise_id,language_code,name)
      VALUES ('squat-en','local-squat','en','Squat')
    ''');
    final reviewed = await preview();
    expect(reviewed.exerciseSuggestions['exercise-squat'],
        contains('local-squat'));
    await service.importReviewed(
        reviewed,
        const ImportResolution(exerciseLinks: {
          'exercise-squat': 'local-squat',
        }),
        confirmed: true);
    final set = await db
        .customSelect('SELECT exercise_id FROM set_logs LIMIT 1')
        .getSingle();
    expect(set.read<String>('exercise_id'), 'local-squat');
  });

  test('locked destination cannot be bypassed; skip is explicit', () async {
    await DayLockRepository(db).lock(DateTime(2026, 9, 23));
    final reviewed = await preview();
    expect(reviewed.conflicts.any((c) => c.key == 'date/2026-09-23'), isTrue);
    await expectLater(
        service.importReviewed(reviewed, resolution(), confirmed: true),
        throwsA(isA<ImportReviewRequired>()));
    await expectLater(
        service.importReviewed(
            reviewed,
            const ImportResolution(
                days: {'2026-09-23': DayConflictChoice.keepExisting}),
            confirmed: true),
        throwsA(isA<DayLockedException>()));
    expect(await count('nutrition_logs'), 0);
    final report = await service.importReviewed(
        reviewed,
        const ImportResolution(
            days: {'2026-09-23': DayConflictChoice.skipDate}),
        confirmed: true);
    expect(report.counts['skippedDates'], greaterThan(0));
    expect(await count('nutrition_logs'), 1);
  });

  test('fatal mapping error rolls back data, preserves backup and failed batch',
      () async {
    final reviewed = await preview();
    await expectLater(
        service.importReviewed(
            reviewed,
            const ImportResolution(
                exerciseLinks: {'exercise-squat': 'no-such-exercise'}),
            confirmed: true),
        throwsA(isA<ImportReviewRequired>()));
    expect(backups, 1);
    expect(await File('${directory.path}/recovery-1.zip').exists(), isTrue);
    expect(await count('nutrition_logs'), 0);
    expect(await count('workout_logs'), 0);
    expect(await count('day_locks'), 0);
    expect(await count('historical_import_records'), 0);
    final failed = await db
        .customSelect('SELECT status FROM historical_import_batches')
        .getSingle();
    expect(failed.read<String>('status'), 'failed');
  });

  test(
      'portable per-serving restaurant values calculate without changing provenance',
      () async {
    await service.importReviewed(await preview(), resolution(),
        confirmed: true);
    final day = await HistoryRepository(db).loadDay(DateTime(2026, 9, 27));
    expect(day.today.nutrition.summary.calories, closeTo(720.5, 0.00001));
    expect(day.today.foods.single.displayQuantity, '1 serving');
    expect(
        day.today.foods.single.item.nutritionSource, NutritionSource.estimate);
    final row = await db.customSelect('''
      SELECT payload_json FROM historical_import_records
      WHERE collection='nutritionSnapshots' AND external_id='snapshot-restaurant'
    ''').getSingle();
    expect(jsonDecode(row.read<String>('payload_json'))['provenance'],
        'restaurantEstimate');
  });

  test('imported target uses effective date; unknown workout time is labeled',
      () async {
    await service.importReviewed(await preview(),
        resolution(targets: {'target-training', 'target-rest'}),
        confirmed: true);
    final day = await HistoryRepository(db).loadDay(DateTime(2026, 9, 25));
    expect(day.today.targets.profile?.calories, 2750);
    expect(
        day.today.unknownWorkoutTimes, contains(day.today.workouts.single.id));
    expect(day.today.record?.trainingType, 'legs');
    expect(day.today.workouts.single.status, 'completed');
    expect(day.today.workouts.single.endTime, isNull);
  });

  test('workout-only and measurement-only dates do not need DailyRecords',
      () async {
    sample['dailyRecords'] = [];
    sample['lockedDays'] = [];
    await service.importReviewed(await preview(), resolution(),
        confirmed: true);
    final history = HistoryRepository(db);
    final workoutDay = await history.loadDay(DateTime(2026, 9, 25));
    expect(workoutDay.today.record, isNull);
    expect(workoutDay.today.workouts, hasLength(1));
    expect(workoutDay.today.foods, isEmpty);
    expect(workoutDay.today.trainingType.name, 'unset');
    final measurementDay = await history.loadDay(DateTime(2026, 9, 26));
    expect(measurementDay.today.record, isNull);
    expect(measurementDay.measurements, hasLength(4));
    expect(measurementDay.today.workouts, isEmpty);
  });

  test('partial workout imports without invented sets or duration', () async {
    sample['workoutSets'] = [];
    await service.importReviewed(await preview(), resolution(),
        confirmed: true);
    final workout = (await db.select(db.workoutLogs).get()).single;
    expect(workout.endTime, isNull);
    expect(await count('set_logs'), 0);
    expect(await count('workout_exercise_logs'), 1);
  });

  test('import audit records survive current backup restore', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => directory.path);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'), null);
    });
    await service.importReviewed(await preview(), resolution(),
        confirmed: true);
    final backup = BackupManager(userDb: DatabaseHelper.forTesting(db));
    final payload = await backup.generateBackupPayloadForTesting();
    expect(payload['schemaVersion'], 11);
    expect((payload['historical_import_records'] as List), isNotEmpty);
    expect(await backup.importBackupPayloadForTesting(payload), isTrue);
    expect(await count('historical_import_records'), greaterThan(0));
    expect(await count('nutrition_logs'), 2);
    expect(await count('day_locks'), 1);
  });

  test('v36 to v37 migration adds audit tables without changing existing data',
      () async {
    await db.customStatement('''
      INSERT INTO products(id,barcode,name,calories,protein,carbs,fat,source)
      VALUES ('stable-id','stable','Original',288.97,15.65,11.85,19.89,'user')
    ''');
    await db.customStatement('DROP TABLE historical_import_records');
    await db.customStatement('DROP TABLE historical_import_batches');
    await db.customStatement('PRAGMA user_version=36');
    await db.close();
    db = AppDatabase(NativeDatabase(File('${directory.path}/test.sqlite')));
    DatabaseHelper.setDriftDb(db);
    service = HistoricalImportService(db, recoveryBackup: () async {
      final path = '${directory.path}/recovery-migration.zip';
      await File(path).writeAsBytes([1]);
      return path;
    });
    expect(db.schemaVersion, 37);
    expect(await count('historical_import_batches'), 0);
    final product = await db.customSelect('''
      SELECT id,calories FROM products WHERE barcode='stable'
    ''').getSingle();
    expect(product.read<String>('id'), 'stable-id');
    expect(product.read<double>('calories'), 288.97);
    expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
  });

  test(
      'changed external ID requires explicit keep-existing and never mutates log',
      () async {
    await service.importReviewed(await preview(), resolution(),
        confirmed: true);
    final entries = sample['foodEntries'] as List;
    final oats = entries.first as Map<String, dynamic>;
    oats['quantity'] = '21.3';
    final changed = await preview();
    expect(changed.conflicts.any((c) => c.key == 'foodEntries/entry-oats'),
        isTrue);
    await expectLater(
        service.importReviewed(changed, resolution(), confirmed: true),
        throwsA(isA<ImportReviewRequired>()));
    final report = await service.importReviewed(
        changed,
        const ImportResolution(
            keepExistingExternalIds: {'foodEntries/entry-oats'}),
        confirmed: true);
    expect(report.counts['skippedDuplicates'], greaterThan(0));
    expect(report.counts['skippedChangedIds'], 1);
    final oatsLog = await db.customSelect('''
      SELECT n.amount FROM nutrition_logs n
      JOIN historical_import_records r ON r.local_uuid=n.id
      WHERE r.external_id='entry-oats'
    ''').getSingle();
    expect(oatsLog.read<double>('amount'), 80);
  });

  test('missing recovery backup stops import before any write', () async {
    service = HistoricalImportService(db,
        recoveryBackup: () async => '${directory.path}/missing.zip');
    await expectLater(
        service.importReviewed(await preview(), resolution(), confirmed: true),
        throwsStateError);
    expect(await count('historical_import_batches'), 0);
    expect(await count('nutrition_logs'), 0);
  });

  test('real recovery archive is created before historical records are written',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => directory.path);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'), null);
    });
    final backup = BackupManager(userDb: DatabaseHelper.forTesting(db));
    service = HistoricalImportService(db, recoveryBackup: () async {
      expect(await count('nutrition_logs'), 0);
      final file = await backup.buildBackupArchive(
          targetPath: '${directory.path}/real-recovery.zip');
      return file.path;
    });
    final report = await service.importReviewed(await preview(), resolution(),
        confirmed: true);
    final file = File(report.recoveryBackupPath);
    expect(await file.exists(), isTrue);
    final bytes = await file.readAsBytes();
    expect(bytes.take(2), [0x50, 0x4b]);
    expect(await count('nutrition_logs'), 2);
  });

  test('measurement units and lower belly remain distinct from abdomen',
      () async {
    await service.importReviewed(await preview(), resolution(),
        confirmed: true);
    final rows = await db.customSelect('''
      SELECT type,value,unit FROM measurements
      WHERE type IN ('lower_belly','abdomen') ORDER BY type
    ''').get();
    expect(rows, hasLength(2));
    expect(rows.map((r) => r.read<String>('type')),
        containsAll(['abdomen', 'lower_belly']));
    expect(
        rows
            .singleWhere((r) => r.read<String>('type') == 'lower_belly')
            .read<double>('value'),
        103.0);
  });

  test('exact measurement on same local date links without duplicate',
      () async {
    final morning = DateTime(2026, 9, 26, 8).millisecondsSinceEpoch ~/ 1000;
    await db.customStatement('''
      INSERT INTO measurements(id,type,value,unit,date) VALUES (?,?,?,?,?)
    ''', ['existing-weight', 'weight', 99.5, 'kg', morning]);
    final report = await service.importReviewed(await preview(), resolution(),
        confirmed: true);
    expect(report.counts['linked'], greaterThan(0));
    final weights = await db
        .customSelect("SELECT id FROM measurements WHERE type='weight'")
        .get();
    expect(weights, hasLength(1));
    expect(weights.single.read<String>('id'), 'existing-weight');
  });

  test('new set on an already imported workout respects its locked date',
      () async {
    await service.importReviewed(await preview(), resolution(),
        confirmed: true);
    await DayLockRepository(db).lock(DateTime(2026, 9, 25));
    (sample['workoutSets'] as List).add({
      'id': 'set-new',
      'exerciseId': 'exercise-squat',
      'weight': '21.3',
      'weightUnit': 'kg',
      'reps': 7,
    });
    final reviewed = await preview();
    expect(reviewed.conflicts.any((c) => c.key == 'date/2026-09-25'), isTrue);
    await expectLater(
        service.importReviewed(
            reviewed,
            const ImportResolution(
                days: {'2026-09-25': DayConflictChoice.keepExisting}),
            confirmed: true),
        throwsA(isA<DayLockedException>()));
    expect(await count('set_logs'), 6);
    final skipped = await service.importReviewed(
        reviewed,
        const ImportResolution(
            days: {'2026-09-25': DayConflictChoice.skipDate}),
        confirmed: true);
    expect(skipped.counts['skippedDates'], greaterThan(0));
    expect(await count('set_logs'), 6);
  });

  test('same source can add a new set without duplicating old workout',
      () async {
    await service.importReviewed(await preview(), resolution(),
        confirmed: true);
    (sample['workoutSets'] as List).add({
      'id': 'set-new',
      'exerciseId': 'exercise-squat',
      'weight': '21.3',
      'weightUnit': 'kg',
      'reps': 7,
    });
    final reviewed = await preview();
    expect(reviewed.newCount, 1);
    await service.importReviewed(reviewed, resolution(), confirmed: true);
    expect(await count('workout_logs'), 1);
    expect(await count('set_logs'), 7);
    final newSet = await db.customSelect('''
      SELECT weight,exercise_name_snapshot FROM set_logs
      WHERE id=(SELECT local_uuid FROM historical_import_records
        WHERE collection='workoutSets' AND external_id='set-new')
    ''').getSingle();
    expect(newSet.read<double>('weight'), 21.3);
    expect(newSet.read<String>('exercise_name_snapshot'), 'Squat');
  });

  test('merge preview rejects conflicting metadata and duplicate lock dates',
      () async {
    (sample['dailyRecords'] as List).add({
      'id': 'different-day-metadata',
      'date': '2026-09-23',
      'trainingType': 'rest',
    });
    await expectLater(preview(), throwsA(isA<ImportValidationException>()));
    (sample['dailyRecords'] as List).removeLast();
    (sample['lockedDays'] as List).add({
      'id': 'second-lock',
      'date': '2026-09-24',
      'lockedAt': '2026-09-24T22:00:00+08:00',
    });
    await expectLater(preview(), throwsA(isA<ImportValidationException>()));
    expect(await count('historical_import_batches'), 0);
  });

  test('two sources can retain separate reported totals on one date', () async {
    await service.importReviewed(await preview(), resolution(),
        confirmed: true);
    final other = jsonEncode({
      'formatVersion': 1,
      'metadata': {'source': 'Other diary', 'sourceId': 'second'},
      'dailyRecords': [
        {
          'id': 'other-total',
          'date': '2026-09-24',
          'reportedTotal': {
            'calories': '2600',
            'protein': '201.5',
            'provenance': 'legacyObservation'
          },
        }
      ],
    });
    final reviewed = await service.preview(other);
    await expectLater(
        service.importReviewed(reviewed, resolution(), confirmed: true),
        throwsA(isA<ImportReviewRequired>()));
    await service.importReviewed(
        reviewed,
        const ImportResolution(
            days: {'2026-09-24': DayConflictChoice.skipDate}),
        confirmed: true);
    final skipped = await HistoryRepository(db).loadDay(DateTime(2026, 9, 24));
    expect(skipped.reportedTotals, hasLength(1));
    await DayLockRepository(db).unlock(DateTime(2026, 9, 24));
    await service.importReviewed(await service.preview(other), resolution(),
        confirmed: true);
    final day = await HistoryRepository(db).loadDay(DateTime(2026, 9, 24));
    expect(day.reportedTotals.map((r) => r['calories']),
        containsAll(['2588', '2600']));
    expect(day.today.nutrition.summary.calories, 0);
  });
}
