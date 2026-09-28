import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:train_libre/core/infrastructure/backup_manager.dart';
import 'package:train_libre/data/database_helper.dart';
import 'package:train_libre/data/drift_database.dart';
import 'package:train_libre/features/historical_import/data/historical_import_service.dart';
import 'package:train_libre/features/historical_import/domain/chat_export_reader.dart';
import 'package:train_libre/features/historical_import/domain/chat_fitness_adapter.dart';
import 'package:train_libre/features/historical_import/domain/portable_import.dart';
import 'package:train_libre/features/history/data/history_repository.dart';
import 'package:train_libre/features/today/data/day_lock_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppDatabase db;
  late HistoricalImportService service;
  late BackupManager backup;
  var backupCalls = 0;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('phase3d-pipeline-');
    db = AppDatabase(NativeDatabase(File('${directory.path}/test.sqlite')));
    DatabaseHelper.setDriftDb(db);
    backup = BackupManager(userDb: DatabaseHelper.forTesting(db));
    backupCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => directory.path);
    service = HistoricalImportService(db, recoveryBackup: () async {
      backupCalls++;
      final archive = await backup.buildBackupArchive(
          targetPath: '${directory.path}/recovery-$backupCalls.zip');
      return archive.path;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'), null);
    if (identical(DatabaseHelper.driftDb, db)) {
      await DatabaseHelper.closeAndResetDriftDb();
    } else {
      await db.close();
    }
    await directory.delete(recursive: true);
  });

  Future<int> count(String table) async =>
      (await db.customSelect('SELECT COUNT(*) AS n FROM $table').getSingle())
          .read<int>('n');

  ChatFitnessExtraction extraction() {
    final catalog = ChatExportReader().read(
        'conversations.json',
        File('test/fixtures/chatgpt_export/phase3d_long_running.json')
            .readAsBytesSync());
    expect(catalog.conversations, hasLength(3));
    return ChatFitnessAdapter().extract(catalog, {
      'synthetic-cut-2026-a': null,
      'synthetic-cut-2026-b': null,
    });
  }

  test(
      'selected chat → reviewed v1 → preview → merge → semantic state → reimport',
      () async {
    final selected = extraction();
    final entries = selected.candidates
        .where((c) => c.collection == 'foodEntries')
        .toList();
    final whey = entries.firstWhere(
        (c) => c.fields['name'] == 'Kirkland Whey' && c.date == '2026-09-24');
    expect(whey.fields['status'], 'consumed');
    expect(whey.sourceRefs.any((s) => s.contains('/a06@')), isTrue);
    expect(whey.sourceRefs.any((s) => s.contains('/a07@')), isTrue);
    expect(
        entries
            .singleWhere((c) => c.fields['name'] == 'Tsingtao zero')
            .fields['status'],
        'cancelled');
    expect(entries.where((c) => c.fields['name'] == 'Pearl River'), isEmpty);
    expect(selected.warnings.any((w) => w.contains('product count')), isTrue);
    expect(
        entries
            .singleWhere((c) => c.fields['name'] == 'Burger')
            .fields['quantity'],
        '293.8');
    final beef = entries.singleWhere((c) => c.fields['name'] == 'beef');
    expect(beef.included, isFalse);
    expect(beef.fields['quantity'], '520.0');
    expect(beef.sourceRefs.any((s) => s.contains('/a12@')), isTrue);
    expect(beef.sourceRefs.any((s) => s.contains('/a13@')), isTrue);
    expect(beef.sourceRefs.any((s) => s.contains('/a14@')), isTrue);
    expect(selected.warnings.any((w) => w.contains('differs')), isTrue);
    expect(selected.candidates.where((c) => c.collection == 'lockedDays'),
        hasLength(2));

    final json = selected.toPortableJson();
    final document = PortableImportParser().parse(json);
    expect(document.isValid, isTrue);
    expect(json, isNot(contains('Private unrelated text')));
    expect(json, isNot(contains('synthetic-unrelated-private')));
    expect(await count('historical_import_batches'), 0);
    final preview = await service.preview(json);
    expect(preview.conflicts, isEmpty);
    expect(preview.counts['savedFoods'], 2);
    expect(preview.reportedTotalOnlyDays, 1);
    expect(await count('historical_import_batches'), 0);

    final report = await service
        .importReviewed(preview, const ImportResolution(), confirmed: true);
    expect(report.counts['created'], greaterThan(0));
    expect(backupCalls, 1);
    expect(await File(report.recoveryBackupPath).exists(), isTrue);
    expect(await count('products'), 2);
    expect(await count('food_aliases'), 2);
    expect(await count('nutrition_logs'), 4);
    expect(await count('workout_logs'), 1);
    expect(await count('set_logs'), 6);
    expect(await count('measurements'), 4);
    expect(await count('day_locks'), 2);
    expect((await db.customSelect('PRAGMA foreign_key_check').get()), isEmpty);
    expect(db.schemaVersion, 37);

    final day = await HistoryRepository(db).loadDay(DateTime(2026, 9, 24));
    expect(day.today.record?.trainingType, 'legs');
    expect(day.today.record?.notes, contains('Solid session'));
    expect(day.today.nutrition.summary.calories,
        closeTo(293.8 * 288.97 / 100 + 45.5 * 370 / 100, 0.00001));
    expect(day.reportedTotals.single['calories'], '2588');
    expect(day.today.workouts, hasLength(1));
    expect(day.measurements.map((m) => m.type),
        containsAll(['weight', 'waist', 'lower_belly', 'chest']));
    final snapshot = await db.customSelect('''
      SELECT n.amount,a.calories,a.protein,a.nutrition_source
      FROM nutrition_logs n JOIN off_products_archive a
      ON a.local_id=n.archive_local_id WHERE n.amount=293.8
    ''').getSingle();
    expect(snapshot.read<double>('calories'), 288.97);
    expect(snapshot.read<double>('protein'), 15.65);
    expect(snapshot.read<String>('nutrition_source'), 'label');
    final audit = await db.customSelect('''
      SELECT payload_json FROM historical_import_records
      WHERE collection='foodEntries' AND payload_json LIKE '%293.8%'
    ''').get();
    expect(
        audit.any((row) =>
            jsonDecode(row.read<String>('payload_json'))['quantity'] ==
            '293.8'),
        isTrue);
    final totalsOnly =
        await HistoryRepository(db).loadDay(DateTime(2026, 11, 2));
    expect(totalsOnly.today.nutrition.summary.calories, 0);
    expect(totalsOnly.reportedTotals.single['calories'], '2100');

    final before = {
      for (final table in [
        'products',
        'food_aliases',
        'nutrition_logs',
        'workout_logs',
        'set_logs',
        'measurements',
        'daily_records',
        'day_locks',
        'historical_import_records'
      ])
        table: await count(table)
    };
    final repeated = await service.preview(json);
    expect(repeated.duplicateCount, greaterThan(0));
    final second = await service
        .importReviewed(repeated, const ImportResolution(), confirmed: true);
    expect(second.counts['created'], 0);
    expect(second.counts['skippedDuplicates'],
        before['historical_import_records']);
    for (final entry in before.entries) {
      expect(await count(entry.key), entry.value, reason: entry.key);
    }
    expect(await count('historical_import_batches'), 2);
    expect((await db.customSelect('PRAGMA foreign_key_check').get()), isEmpty);

    final changed = jsonDecode(json) as Map<String, dynamic>;
    final foods = changed['foodEntries'] as List;
    (foods.first as Map<String, dynamic>)['quantity'] = '21.3';
    final conflicting = await service.preview(jsonEncode(changed));
    expect(conflicting.conflicts.any((c) => c.kind == 'externalId'), isTrue);
    await expectLater(
        service.importReviewed(conflicting, const ImportResolution(),
            confirmed: true),
        throwsA(isA<ImportReviewRequired>()));
    expect(await count('historical_import_batches'), 2);
  });

  test('existing locked destination and failed backup never partially import',
      () async {
    final json = extraction().toPortableJson();
    await DayLockRepository(db).lock(DateTime(2026, 9, 24));
    final preview = await service.preview(json);
    expect(preview.conflicts.any((c) => c.key == 'date/2026-09-24'), isTrue);
    await expectLater(
        service.importReviewed(preview, const ImportResolution(),
            confirmed: true),
        throwsA(isA<ImportReviewRequired>()));
    expect(backupCalls, 0);
    expect(await count('nutrition_logs'), 0);
    await expectLater(
        service.importReviewed(
            preview,
            const ImportResolution(
                days: {'2026-09-24': DayConflictChoice.keepExisting}),
            confirmed: true),
        throwsA(isA<DayLockedException>()));
    expect(await count('nutrition_logs'), 0);
    expect(await count('historical_import_records'), 0);
    expect(await count('day_locks'), 1);
    expect((await db.customSelect('PRAGMA foreign_key_check').get()), isEmpty);

    service = HistoricalImportService(db,
        recoveryBackup: () async => '${directory.path}/missing.zip');
    await expectLater(
        service.importReviewed(
            await service.preview(json),
            const ImportResolution(
                days: {'2026-09-24': DayConflictChoice.skipDate}),
            confirmed: true),
        throwsStateError);
    expect(await count('historical_import_batches'), 1);
    expect(await count('nutrition_logs'), 0);
  });

  test(
      'late mapping failure rolls back staged rows and recovery restores state',
      () async {
    final original = await backup.generateBackupPayloadForTesting();
    expect(original['schemaVersion'], 11);
    final extracted = extraction();
    final exercise =
        extracted.candidates.singleWhere((c) => c.collection == 'exercises');
    final preview = await service.preview(extracted.toPortableJson());
    await expectLater(
        service.importReviewed(preview,
            ImportResolution(exerciseLinks: {exercise.id: 'missing-exercise'}),
            confirmed: true),
        throwsA(isA<ImportReviewRequired>()));
    expect(backupCalls, 1);
    expect(await count('products'), 0);
    expect(await count('nutrition_logs'), 0);
    expect(await count('workout_logs'), 0);
    expect(await count('measurements'), 0);
    expect(await count('day_locks'), 0);
    expect(await count('historical_import_records'), 0);
    final failed = await db.customSelect('''
      SELECT status,recovery_backup_path FROM historical_import_batches
    ''').getSingle();
    expect(failed.read<String>('status'), 'failed');
    final archive = File(failed.read<String>('recovery_backup_path'));
    expect(await archive.exists(), isTrue);
    expect((await archive.readAsBytes()).take(2), [0x50, 0x4b]);
    expect(await backup.importBackupPayloadForTesting(original), isTrue);
    expect(await count('nutrition_logs'), 0);
    expect((await db.customSelect('PRAGMA foreign_key_check').get()), isEmpty);
  });

  test('explicit and relative local dates survive a midnight boundary', () {
    final unix = DateTime.utc(2026, 9, 25, 0, 5).millisecondsSinceEpoch ~/ 1000;
    final rows = [
      ['m1', '2026-09-24T23:59:00+08:00', 'today 21.3g oats idsen'],
      ['m2', '2026-09-25T00:01:00+08:00', 'today 45.5g oats idsen'],
      ['m3', '2026-09-25T00:02:00+08:00', 'yesterday 21.3g oats idsen'],
      [
        'm4',
        '2026-09-25T00:03:00+08:00',
        'urchigdur\nDaily note: Two days before this message.'
      ],
      ['m5', '2026-09-25T00:04:00+08:00', '2026-09-20 21.3g oats idsen'],
      ['m6', unix, 'today 21.3g oats idsen'],
    ];
    final catalog = ChatExportReader().read(
        'conversations.json',
        utf8.encode(jsonEncode([
          {
            'id': 'midnight',
            'title': 'Synthetic midnight',
            'messages': [
              for (final row in rows)
                {
                  'id': row[0],
                  'role': 'user',
                  'create_time': row[1],
                  'content': row[2]
                }
            ]
          }
        ])));
    final extracted = ChatFitnessAdapter().extract(catalog, {'midnight': null});
    final entries = extracted.candidates
        .where((c) => c.collection == 'foodEntries')
        .toList();
    expect(
        entries
            .singleWhere((c) => c.sourceRefs.any((s) => s.contains('/m1@')))
            .date,
        '2026-09-24');
    expect(
        entries
            .singleWhere((c) => c.sourceRefs.any((s) => s.contains('/m2@')))
            .date,
        '2026-09-25');
    expect(
        entries
            .singleWhere((c) => c.sourceRefs.any((s) => s.contains('/m3@')))
            .date,
        '2026-09-24');
    expect(
        entries
            .singleWhere((c) => c.sourceRefs.any((s) => s.contains('/m5@')))
            .date,
        '2026-09-20');
    expect(
        extracted.candidates
            .singleWhere((c) =>
                c.collection == 'dailyRecords' &&
                c.fields['notes'] == 'Two days before this message.')
            .date,
        '2026-09-23');
    expect(
        extracted.warnings.any((w) => w.contains('Unix timestamps')), isTrue);
    final unixEntry =
        entries.singleWhere((c) => c.sourceRefs.any((s) => s.contains('/m6@')));
    final local = DateTime.fromMillisecondsSinceEpoch(unix * 1000);
    expect(unixEntry.date,
        '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}');
  });

  test('bare quantity correction applies only with one possible same-day food',
      () {
    ChatFitnessExtraction fromMessages(List<String> texts) {
      final catalog = ChatExportReader().read(
          'conversations.json',
          utf8.encode(jsonEncode([
            {
              'id': 'bare-correction',
              'title': 'Synthetic correction',
              'messages': [
                for (var i = 0; i < texts.length; i++)
                  {
                    'id': 'm$i',
                    'role': 'user',
                    'create_time': '2026-09-24T12:0$i:00+08:00',
                    'content': texts[i]
                  }
              ]
            }
          ])));
      return ChatFitnessAdapter().extract(catalog, {'bare-correction': null});
    }

    final one = fromMessages(['300g Burger idsen', '293.8g bsn']);
    final burger =
        one.candidates.singleWhere((c) => c.collection == 'foodEntries');
    expect(burger.fields['quantity'], '293.8');
    expect(burger.sourceRefs, hasLength(2));
    final ambiguous =
        fromMessages(['300g Burger idsen', '45.5g oats idsen', '293.8g bsn']);
    expect(
        ambiguous.warnings.any((w) => w.contains('bare quantity correction')),
        isTrue);
    expect(
        ambiguous.candidates
            .where((c) => c.collection == 'foodEntries')
            .map((c) => c.fields['quantity']),
        containsAll(['300', '45.5']));
  });

  test('large portable preview and merge retain references', () async {
    final root = <String, Object?>{
      'formatVersion': 1,
      'metadata': {'source': 'Synthetic load test', 'sourceId': 'phase3d-load'},
      'nutritionSnapshots': [
        {
          'id': 'oats-snapshot',
          'basis': 'per100g',
          'calories': '288.97',
          'protein': '15.65',
          'carbs': '11.85',
          'fat': '19.89',
          'provenance': 'exactLabel'
        }
      ],
      'savedFoods': [
        {
          'id': 'oats',
          'name': 'Synthetic Oats',
          'nutritionSnapshotId': 'oats-snapshot',
          'servingSize': '100',
          'servingUnit': 'g',
          'provenance': 'exactLabel'
        }
      ],
      'foodAliases': [
        {'id': 'oats-alias', 'foodId': 'oats', 'alias': 'ovyoos'}
      ],
      'foodEntries': <Map<String, Object?>>[],
      'dailyRecords': <Map<String, Object?>>[],
      'workouts': <Map<String, Object?>>[],
      'exercises': <Map<String, Object?>>[],
      'workoutSets': <Map<String, Object?>>[],
      'measurements': <Map<String, Object?>>[],
    };
    for (var day = 0; day < 180; day++) {
      final date = DateTime.utc(2025, 1, 1).add(Duration(days: day));
      final key =
          '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      (root['dailyRecords'] as List).add({
        'id': 'day-$day',
        'date': key,
        'trainingType': 'unset',
        'reportedTotal': {'calories': '2588', 'provenance': 'legacyObservation'}
      });
      for (var meal = 0; meal < 6; meal++) {
        (root['foodEntries'] as List).add({
          'id': 'entry-$day-$meal',
          'date': key,
          'name': 'Synthetic Oats',
          'status': 'consumed',
          'quantity': meal.isEven ? '293.8' : '21.3',
          'quantityUnit': 'g',
          'savedFoodId': 'oats',
          'nutritionSnapshotId': 'oats-snapshot'
        });
      }
      (root['measurements'] as List).add({
        'id': 'weight-$day',
        'date': key,
        'type': 'weight',
        'value': '99.5',
        'unit': 'kg'
      });
      if (day.isEven) {
        (root['workouts'] as List)
            .add({'id': 'workout-$day', 'date': key, 'name': 'Synthetic Legs'});
        (root['exercises'] as List).add({
          'id': 'exercise-$day',
          'workoutId': 'workout-$day',
          'name': 'Squat'
        });
        (root['workoutSets'] as List).add({
          'id': 'set-$day',
          'exerciseId': 'exercise-$day',
          'weight': '45.5',
          'weightUnit': 'kg',
          'reps': 8
        });
      }
    }
    final json = jsonEncode(root);
    final watch = Stopwatch()..start();
    final preview = await service.preview(json);
    final previewMs = watch.elapsedMilliseconds;
    expect(preview.counts['foodEntries'], 1080);
    expect(await count('historical_import_records'), 0);
    final report = await service
        .importReviewed(preview, const ImportResolution(), confirmed: true);
    final mergeMs = watch.elapsedMilliseconds - previewMs;
    // Measurements are recorded rather than used as a fragile timing gate.
    debugPrint('Phase 3D load: preview ${previewMs}ms, merge ${mergeMs}ms; '
        '180 days, 1080 foods, 90 workouts, 180 measurements');
    expect(report.counts['created'], greaterThan(1000));
    expect(await count('nutrition_logs'), 1080);
    expect(await count('workout_logs'), 90);
    expect(await count('measurements'), 180);
    expect((await db.customSelect('PRAGMA foreign_key_check').get()), isEmpty);
  });
}
