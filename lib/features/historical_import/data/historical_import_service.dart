import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../../core/infrastructure/backup_manager.dart';
import '../../../data/drift_database.dart';
import '../../diary/domain/models/food_alias.dart';
import '../../today/domain/daily_record_models.dart';
import '../../today/data/day_lock_repository.dart';
import '../domain/portable_import.dart';

/// A single conversion boundary. The portable JSON and audit rows keep the
/// original text; SQLite REAL cannot preserve its lexical decimal identity.
class PortableDecimal {
  static final _syntax = RegExp(r'^(?:0|[1-9]\d*)(?:\.\d+)?$');

  static double required(Object? value, {bool positive = false}) {
    if (value is! String || !_syntax.hasMatch(value)) {
      throw const FormatException('Invalid portable decimal');
    }
    final parsed = double.tryParse(value);
    if (parsed == null || !parsed.isFinite || (positive && parsed <= 0)) {
      throw const FormatException('Non-finite or out-of-range decimal');
    }
    return parsed;
  }

  static double? optional(Object? value, {bool positive = false}) =>
      value == null ? null : required(value, positive: positive);

  static double scaled(Object? value, double factor) {
    final result = required(value) * factor;
    if (!result.isFinite) throw const FormatException('Decimal overflows REAL');
    return result;
  }
}

enum ImportChoice { create, link, unlinked }

enum DayConflictChoice { keepExisting, useImported, skipDate }

class FoodMapping {
  final ImportChoice choice;
  final String? localFoodId;
  const FoodMapping(this.choice, {this.localFoodId});
}

class ImportResolution {
  /// Suggestions never become mappings without this explicit choice.
  final Map<String, FoodMapping> foods;
  final Map<String, DayConflictChoice> days;
  final Set<String> createTargetProfiles;
  final Map<String, String> exerciseLinks;
  final Map<String, String> entryFoodLinks;
  final Set<String> keepExistingExternalIds;

  const ImportResolution({
    this.foods = const {},
    this.days = const {},
    this.createTargetProfiles = const {},
    this.exerciseLinks = const {},
    this.entryFoodLinks = const {},
    this.keepExistingExternalIds = const {},
  });
}

class ImportConflict {
  final String key;
  final String reason;
  final String kind;
  const ImportConflict(this.key, this.reason, {this.kind = 'externalId'});
}

class ImportPreview {
  final String sourceJson;
  final PortableImportDocument document;
  final String checksum;
  final String sourceKey;
  final Map<String, int> counts;
  final Map<String, List<String>> foodSuggestions;
  final Map<String, List<String>> entryFoodSuggestions;
  final Map<String, List<String>> exerciseSuggestions;
  final Set<String> targetConflicts;
  final List<ImportConflict> conflicts;
  final List<String> warnings;
  final int duplicateCount;
  final int newCount;
  final int reportedTotalOnlyDays;
  final int missingMedia;
  final int plannedOrCancelled;

  const ImportPreview({
    required this.sourceJson,
    required this.document,
    required this.checksum,
    required this.sourceKey,
    required this.counts,
    required this.foodSuggestions,
    required this.entryFoodSuggestions,
    required this.exerciseSuggestions,
    required this.targetConflicts,
    required this.conflicts,
    required this.warnings,
    required this.duplicateCount,
    required this.newCount,
    required this.reportedTotalOnlyDays,
    required this.missingMedia,
    required this.plannedOrCancelled,
  });
}

class ImportReport {
  final String batchId;
  final String recoveryBackupPath;
  final Map<String, int> counts;
  final List<String> warnings;
  const ImportReport(
      this.batchId, this.recoveryBackupPath, this.counts, this.warnings);
}

class ImportValidationException implements Exception {
  final List<ImportIssue> issues;
  const ImportValidationException(this.issues);
  @override
  String toString() => issues.map((e) => '${e.path}: ${e.message}').join('; ');
}

class ImportReviewRequired implements Exception {
  final String message;
  const ImportReviewRequired(this.message);
  @override
  String toString() => message;
}

typedef RecoveryBackupWriter = Future<String> Function();

/// Reads for preview; a backup followed by one Drift transaction for merge.
class HistoricalImportService {
  final AppDatabase db;
  final RecoveryBackupWriter recoveryBackup;
  final DateTime Function() clock;
  HistoricalImportService(this.db,
      {RecoveryBackupWriter? recoveryBackup, DateTime Function()? clock})
      : recoveryBackup = recoveryBackup ?? _createRecoveryBackup,
        clock = clock ?? DateTime.now;

  static Future<String> _createRecoveryBackup() async {
    final root = await getApplicationSupportDirectory();
    final directory =
        Directory(p.join(root.path, 'historical-import-recovery'));
    await directory.create(recursive: true);
    final path = p.join(directory.path,
        'before-import-${DateTime.now().toUtc().millisecondsSinceEpoch}-${const Uuid().v4()}.zip');
    final archive =
        await BackupManager.instance.buildBackupArchive(targetPath: path);
    if (!await archive.exists() || await archive.length() == 0) {
      throw StateError('Recovery backup was not created.');
    }
    return archive.path;
  }

  static String _digest(String value) =>
      sha256.convert(utf8.encode(value)).toString();
  static String _sourceKey(PortableImportDocument document) => _digest(
      '${document.metadata['source']}\u0000${document.metadata['sourceId'] ?? ''}');
  static String _recordHash(PortableRecord record) =>
      _digest(jsonEncode(record.fields));
  static String _key(String collection, String id) => '$collection/$id';
  static int _epoch(DateTime value) => value.millisecondsSinceEpoch ~/ 1000;
  static DateTime _atNoon(String date) {
    final day = parseLocalDateKey(date);
    return DateTime(day.year, day.month, day.day, 12);
  }

  static String? _effectiveDate(PortableImportDocument document,
      String collection, PortableRecord record) {
    if (record.date != null) return record.date;
    PortableRecord? find(String table, Object? id) {
      if (id is! String) return null;
      for (final item in document.records(table)) {
        if (item.id == id) return item;
      }
      return null;
    }

    if (collection == 'exercises') {
      return find('workouts', record.fields['workoutId'])?.date;
    }
    if (collection == 'workoutSets') {
      final exercise = find('exercises', record.fields['exerciseId']);
      return find('workouts', exercise?.fields['workoutId'])?.date;
    }
    if (collection == 'targetProfiles') {
      return record.fields['effectiveFrom'] as String?;
    }
    return null;
  }

  Future<ImportPreview> preview(String json) async {
    final parsed = PortableImportParser().parse(json);
    if (!parsed.isValid) throw ImportValidationException(parsed.issues);
    final document = parsed.document!;
    final compatibilityIssues = <ImportIssue>[];
    final dailyMetadata = <String, String>{};
    for (final day in document.records('dailyRecords')) {
      final metadata = jsonEncode([
        day.fields['trainingType'],
        day.fields['notes'],
        day.fields['targetProfileId'],
      ]);
      final prior = dailyMetadata[day.date!];
      if (prior != null && prior != metadata) {
        compatibilityIssues.add(ImportIssue(
            ImportSeverity.error,
            'conflictingDayMetadata',
            'dailyRecords/${day.id}',
            'Several records assign different metadata to ${day.date}; split or correct the file before merge.'));
      }
      dailyMetadata[day.date!] = metadata;
    }
    final lockDates = <String>{};
    for (final lock in document.records('lockedDays')) {
      if (!lockDates.add(lock.date!)) {
        compatibilityIssues.add(ImportIssue(
            ImportSeverity.error,
            'duplicateLockedDate',
            'lockedDays/${lock.id}',
            'A date may have only one imported lock record.'));
      }
    }
    for (final set in document.records('workoutSets')) {
      final count = set.fields['setCount'];
      if (count is int && count > 10000) {
        compatibilityIssues.add(ImportIssue(
            ImportSeverity.error,
            'setCountTooLarge',
            'workoutSets/${set.id}.setCount',
            'A single portable set may expand to at most 10000 local rows.'));
      }
    }
    if (compatibilityIssues.isNotEmpty) {
      throw ImportValidationException(
          [...parsed.issues, ...compatibilityIssues]);
    }
    final sourceKey = _sourceKey(document);
    final counts = {
      for (final collection in PortableImportParser.collections)
        collection: document.records(collection).length,
    };
    final warnings = parsed.issues
        .where((issue) => issue.severity == ImportSeverity.warning)
        .map((issue) => '${issue.path}: ${issue.message}')
        .toList();
    final conflicts = <ImportConflict>[];
    var duplicates = 0;
    final existing = await db.customSelect(
      'SELECT collection, external_id, payload_hash FROM historical_import_records WHERE source_key = ?',
      variables: [Variable.withString(sourceKey)],
    ).get();
    final existingHashes = {
      for (final row in existing)
        _key(row.read<String>('collection'), row.read<String>('external_id')):
            row.read<String>('payload_hash'),
    };
    for (final collection in PortableImportParser.collections) {
      for (final record in document.records(collection)) {
        final key = _key(collection, record.id);
        final old = existingHashes[key];
        if (old == null) continue;
        if (old == _recordHash(record)) {
          duplicates++;
        } else {
          conflicts.add(ImportConflict(key,
              'The same external ID was imported earlier with different data.'));
        }
      }
    }

    final foodSuggestions = <String, List<String>>{};
    final products = await (db.select(db.products)
          ..where((t) => t.deletedAt.isNull() & t.source.equals('user')))
        .get();
    final aliases = await (db.select(db.foodAliases)
          ..where((t) => t.deletedAt.isNull()))
        .get();
    final byBarcode = {
      for (final product in products) product.barcode: product
    };
    for (final food in document.records('savedFoods')) {
      if (existingHashes[_key('savedFoods', food.id)] == _recordHash(food)) {
        continue;
      }
      final matches = <String>{};
      final hint = food.fields['localFoodRef'];
      if (hint is String) {
        if (products.any((p) => p.id == hint) ||
            await _productBarcode(hint) != null) {
          matches.add(hint);
        }
      }
      final names = <String>{
        normalizeFoodAlias(food.fields['name'] as String),
        for (final importedAlias in document.records('foodAliases'))
          if (importedAlias.fields['foodId'] == food.id)
            normalizeFoodAlias(importedAlias.fields['alias'] as String),
      };
      for (final product in products) {
        if (names.contains(normalizeFoodAlias(product.name))) {
          matches.add(product.id);
        }
      }
      for (final alias in aliases) {
        if (names.contains(alias.normalizedAlias)) {
          final product = byBarcode[alias.productBarcode];
          if (product != null) matches.add(product.id);
        }
      }
      if (matches.isNotEmpty) {
        foodSuggestions[food.id] = matches.toList();
        conflicts.add(ImportConflict(_key('savedFoods', food.id),
            'Saved Food identity needs an explicit choice.',
            kind: 'foodMapping'));
      }
    }

    final entryFoodSuggestions = <String, List<String>>{};
    for (final entry in document.records('foodEntries')) {
      if (entry.fields['savedFoodId'] != null) continue;
      final matches = <String>{};
      final hint = entry.fields['localFoodRef'];
      if (hint is String && await _productBarcode(hint) != null) {
        matches.add(hint);
      }
      final name = normalizeFoodAlias(entry.fields['name'] as String);
      for (final product in products) {
        if (normalizeFoodAlias(product.name) == name) matches.add(product.id);
      }
      for (final alias in aliases) {
        if (alias.normalizedAlias == name) {
          final product = byBarcode[alias.productBarcode];
          if (product != null) matches.add(product.id);
        }
      }
      if (matches.isNotEmpty) entryFoodSuggestions[entry.id] = matches.toList();
    }

    final exerciseSuggestions = <String, List<String>>{};
    final names = document
        .records('exercises')
        .map((e) => (e.fields['name'] as String).trim().toLowerCase())
        .toSet();
    if (names.isNotEmpty) {
      final exercises = <QueryRow>[];
      final nameList = names.toList();
      for (var offset = 0; offset < nameList.length; offset += 400) {
        final part = nameList.skip(offset).take(400).toList();
        exercises.addAll(await db.customSelect('''
        SELECT e.id,t.name FROM exercises e
        JOIN exercise_translations t ON t.exercise_id=e.id
        WHERE e.deleted_at IS NULL AND t.deleted_at IS NULL
          AND lower(trim(t.name)) IN (${List.filled(part.length, '?').join(',')})
      ''', variables: part.map(Variable.withString).toList()).get());
      }
      for (final record in document.records('exercises')) {
        final normalized =
            (record.fields['name'] as String).trim().toLowerCase();
        final matches = exercises
            .where((e) =>
                e.read<String>('name').trim().toLowerCase() == normalized)
            .map((e) => e.read<String>('id'))
            .toSet()
            .toList();
        if (matches.isNotEmpty) exerciseSuggestions[record.id] = matches;
      }
    }

    final importedDates = <String>{};
    for (final collection in PortableImportParser.collections) {
      for (final record in document.records(collection)) {
        if (existingHashes[_key(collection, record.id)] ==
            _recordHash(record)) {
          continue;
        }
        if (collection != 'targetProfiles') {
          final date = _effectiveDate(document, collection, record);
          if (date != null) importedDates.add(date);
        }
      }
    }
    for (final date in importedDates) {
      final lock = await (db.select(db.dayLocks)
            ..where((t) => t.localDate.equals(date) & t.deletedAt.isNull()))
          .getSingleOrNull();
      if (lock != null) {
        conflicts.add(ImportConflict('date/$date',
            'This local day is locked. Unlock it first or explicitly skip it.',
            kind: 'date'));
      }
    }
    for (final day in document.records('dailyRecords')) {
      if (existingHashes[_key('dailyRecords', day.id)] == _recordHash(day)) {
        continue;
      }
      final existingDay = await (db.select(db.dailyRecords)
            ..where((t) => t.date.equals(day.date!) & t.deletedAt.isNull()))
          .getSingleOrNull();
      if (existingDay != null &&
          (day.fields.containsKey('trainingType') ||
              day.fields.containsKey('notes')) &&
          !conflicts
              .any((c) => c.kind == 'date' && c.key == 'date/${day.date}')) {
        conflicts.add(ImportConflict('date/${day.date}',
            'Existing daily training type or notes require a merge choice.',
            kind: 'date'));
      }
    }
    final entryDates = document
        .records('foodEntries')
        .where((e) => e.fields['status'] == 'consumed')
        .map((e) => e.date)
        .toSet();
    final totalOnly = document
        .records('dailyRecords')
        .where((d) =>
            d.fields['reportedTotal'] != null && !entryDates.contains(d.date))
        .length;
    final planned = document
        .records('foodEntries')
        .where((e) => e.fields['status'] != 'consumed')
        .length;
    final media = document.records('progressPhotos').length +
        document
            .records('savedFoods')
            .where((f) => f.fields['productPhotoRef'] != null)
            .length +
        document
            .records('savedFoods')
            .where((f) => f.fields['nutritionLabelPhotoRef'] != null)
            .length;
    if (media > 0) {
      warnings
          .add('$media photo metadata item(s) have no bundled original image.');
    }
    if (planned > 0) {
      warnings.add(
          '$planned planned/cancelled food entries will not count toward totals.');
    }
    for (final target in document.records('targetProfiles')) {
      if (!['calories', 'protein', 'carbs', 'fat']
          .every(target.fields.containsKey)) {
        warnings.add(
            'Partial target ${target.id} remains an observation; missing values are not invented.');
      }
    }
    final targetConflicts = <String>{};
    final targetKeys = <String, List<String>>{};
    for (final target in document.records('targetProfiles')) {
      final targetKey =
          '${target.fields['kind']}/${target.fields['effectiveFrom']}';
      targetKeys.putIfAbsent(targetKey, () => []).add(target.id);
      if (existingHashes[_key('targetProfiles', target.id)] ==
          _recordHash(target)) {
        continue;
      }
      final sameDate = await db.customSelect('''
        SELECT id FROM nutrition_target_profiles
        WHERE kind=? AND effective_from=? AND deleted_at IS NULL LIMIT 1
      ''', variables: [
        Variable.withString(target.fields['kind'] as String),
        Variable.withString(target.fields['effectiveFrom'] as String),
      ]).getSingleOrNull();
      if (sameDate != null) {
        targetConflicts.add(target.id);
        warnings.add(
            'Target ${target.id} already has a local profile at this effective date; keep as an observation.');
      }
    }
    for (final group in targetKeys.entries) {
      if (group.value.length > 1) {
        warnings.add(
            'Several target observations share ${group.key}; create at most one local profile.');
      }
    }
    return ImportPreview(
      sourceJson: json,
      document: document,
      checksum: _digest(json),
      sourceKey: sourceKey,
      counts: Map.unmodifiable(counts),
      foodSuggestions: Map.unmodifiable(foodSuggestions),
      entryFoodSuggestions: Map.unmodifiable(entryFoodSuggestions),
      exerciseSuggestions: Map.unmodifiable(exerciseSuggestions),
      targetConflicts: Set.unmodifiable(targetConflicts),
      conflicts: List.unmodifiable(conflicts),
      warnings: List.unmodifiable(warnings),
      duplicateCount: duplicates,
      newCount: counts.values.fold(0, (sum, count) => sum + count) - duplicates,
      reportedTotalOnlyDays: totalOnly,
      missingMedia: media,
      plannedOrCancelled: planned,
    );
  }

  /// No call path can write without both a validated preview and confirmation.
  Future<ImportReport> importReviewed(
      ImportPreview reviewed, ImportResolution resolution,
      {required bool confirmed}) async {
    if (!confirmed) {
      throw const ImportReviewRequired('Confirm the preview first.');
    }
    if (_digest(reviewed.sourceJson) != reviewed.checksum) {
      throw const ImportReviewRequired(
          'The selected JSON changed; preview again.');
    }
    final fresh = await preview(reviewed.sourceJson);
    _requireResolution(fresh, resolution);
    final backupPath = await recoveryBackup();
    final backup = File(backupPath);
    if (!await backup.exists() || await backup.length() == 0) {
      throw StateError(
          'Recovery backup is missing or empty. Nothing was imported.');
    }

    final batchId = const Uuid().v4();
    final counts = <String, int>{
      'created': 0,
      'linked': 0,
      'observations': 0,
      'skippedDuplicates': 0,
      'skippedChangedIds': 0,
      'skippedDates': 0,
      'skippedDateRecords': 0,
      'conflictsResolved': fresh.conflicts.length,
      'missingMedia': 0,
      'missingMediaRefs': fresh.missingMedia,
      'reportedTotalOnlyDays': fresh.reportedTotalOnlyDays,
      'plannedOrCancelled': fresh.plannedOrCancelled,
      'unresolvedSavedFoods': 0,
    };
    final warnings = [...fresh.warnings];
    final skippedDateKeys = <String>{};
    final localFoods = <String, String?>{};
    final localMeals = <String, String>{};
    final localTargets = <String, String>{};
    final localWorkouts = <String, String>{};
    final workoutDates = <String, String>{};
    final exerciseNames = <String, String>{};
    final exerciseWorkouts = <String, String>{};
    final order = <String>[
      'nutritionSnapshots',
      'savedFoods',
      'foodAliases',
      'meals',
      'targetProfiles',
      'dailyRecords',
      'foodEntries',
      'workouts',
      'exercises',
      'workoutSets',
      'measurements',
      'progressPhotos',
      'lockedDays',
    ];
    try {
      await db.transaction(() async {
        await db.customStatement('''
        INSERT INTO historical_import_batches
        (id,source_key,source,format_version,checksum,imported_at,status,
         counts_json,report_json,recovery_backup_path)
        VALUES (?,?,?,?,?,?,?,?,?,?)
      ''', [
          batchId,
          fresh.sourceKey,
          fresh.document.metadata['source'],
          PortableImportDocument.formatVersion,
          fresh.checksum,
          _epoch(clock()),
          'running',
          '{}',
          '{}',
          backupPath,
        ]);
        for (final collection in order) {
          for (final record in fresh.document.records(collection)) {
            final old = await db.customSelect('''
            SELECT payload_hash, local_uuid FROM historical_import_records
            WHERE source_key=? AND collection=? AND external_id=?
          ''', variables: [
              Variable.withString(fresh.sourceKey),
              Variable.withString(collection),
              Variable.withString(record.id),
            ]).getSingleOrNull();
            if (old != null) {
              final changed =
                  old.read<String>('payload_hash') != _recordHash(record);
              if (changed &&
                  !resolution.keepExistingExternalIds
                      .contains(_key(collection, record.id))) {
                throw ImportReviewRequired(
                    'Changed external ID ${_key(collection, record.id)} requires review.');
              }
              final countKey =
                  changed ? 'skippedChangedIds' : 'skippedDuplicates';
              counts[countKey] = counts[countKey]! + 1;
              final localId = old.read<String?>('local_uuid');
              if (collection == 'savedFoods') {
                localFoods[record.id] = localId;
              }
              if (collection == 'meals' && localId != null) {
                localMeals[record.id] = localId;
              }
              if (collection == 'targetProfiles' && localId != null) {
                localTargets[record.id] = localId;
              }
              if (collection == 'workouts' && localId != null) {
                localWorkouts[record.id] = localId;
              }
              if (collection == 'exercises') {
                final workoutId = record.fields['workoutId'] as String;
                exerciseNames[record.id] = record.fields['name'] as String;
                exerciseWorkouts[record.id] = workoutId;
              }
              continue;
            }

            final date = collection == 'targetProfiles'
                ? null
                : _effectiveDate(fresh.document, collection, record);
            if (date != null) {
              final lock = await (db.select(db.dayLocks)
                    ..where(
                        (t) => t.localDate.equals(date) & t.deletedAt.isNull()))
                  .getSingleOrNull();
              if (lock != null) {
                if (resolution.days[date] == DayConflictChoice.skipDate) {
                  skippedDateKeys.add(date);
                  counts['skippedDateRecords'] =
                      counts['skippedDateRecords']! + 1;
                  continue; // Not recorded: a later unlocked retry can import it.
                }
                throw DayLockedException(date);
              }
              if (resolution.days[date] == DayConflictChoice.skipDate) {
                skippedDateKeys.add(date);
                counts['skippedDateRecords'] =
                    counts['skippedDateRecords']! + 1;
                continue;
              }
            }

            final outcome = await _writeRecord(
                collection,
                record,
                fresh,
                resolution,
                localFoods,
                localMeals,
                localTargets,
                localWorkouts,
                workoutDates,
                exerciseNames,
                exerciseWorkouts,
                warnings);
            if (outcome.state == 'created') {
              counts['created'] = counts['created']! + 1;
            } else if (outcome.state == 'linked') {
              counts['linked'] = counts['linked']! + 1;
            } else if (outcome.state == 'missingMedia') {
              counts['missingMedia'] = counts['missingMedia']! + 1;
            } else {
              counts['observations'] = counts['observations']! + 1;
            }
            if (collection == 'savedFoods' && outcome.state == 'observation') {
              counts['unresolvedSavedFoods'] =
                  counts['unresolvedSavedFoods']! + 1;
            }
            await db.customStatement('''
            INSERT INTO historical_import_records
            (source_key,collection,external_id,import_batch_id,payload_json,
             payload_hash,local_date,local_table,local_uuid,state)
            VALUES (?,?,?,?,?,?,?,?,?,?)
          ''', [
              fresh.sourceKey,
              collection,
              record.id,
              batchId,
              jsonEncode(record.fields),
              _recordHash(record),
              _effectiveDate(fresh.document, collection, record),
              outcome.localTable,
              outcome.localUuid,
              outcome.state,
            ]);
          }
        }
        final violations =
            await db.customSelect('PRAGMA foreign_key_check').get();
        if (violations.isNotEmpty) {
          throw StateError(
              'Foreign-key verification failed; import rolled back.');
        }
        final references = await db.customSelect('''
        SELECT local_table,local_uuid,state FROM historical_import_records
        WHERE import_batch_id=? AND local_uuid IS NOT NULL
      ''', variables: [Variable.withString(batchId)]).get();
        for (final reference in references) {
          final table = reference.read<String>('local_table');
          if (!const {
            'products',
            'food_aliases',
            'meal_entries',
            'nutrition_target_profiles',
            'daily_records',
            'nutrition_logs',
            'workout_logs',
            'workout_exercise_logs',
            'set_logs',
            'measurements',
            'day_locks'
          }.contains(table)) {
            throw StateError('Unexpected imported reference table $table');
          }
          final found = await db
              .customSelect('SELECT id FROM $table WHERE id=?', variables: [
            Variable.withString(reference.read<String>('local_uuid'))
          ]).getSingleOrNull();
          if (found == null) {
            throw StateError('Imported reference is missing in $table');
          }
        }
        final stored = await db.customSelect('''
        SELECT COUNT(*) AS n FROM historical_import_records WHERE import_batch_id=?
      ''', variables: [Variable.withString(batchId)]).getSingle();
        final expected = counts['created']! +
            counts['linked']! +
            counts['observations']! +
            counts['missingMedia']!;
        if (stored.read<int>('n') != expected) {
          throw StateError(
              'Imported record count mismatch; import rolled back.');
        }
        counts['skippedDates'] = skippedDateKeys.length;
        await db.customStatement('''
        UPDATE historical_import_batches SET status='completed',
          counts_json=?, report_json=? WHERE id=?
      ''', [jsonEncode(counts), jsonEncode(warnings), batchId]);
      });
    } catch (error) {
      // The merge itself rolled back. Keep an audit of the attempted batch
      // and the recovery file so the user can diagnose and retry safely.
      try {
        await db.customStatement('''
          INSERT INTO historical_import_batches
          (id,source_key,source,format_version,checksum,imported_at,status,
           counts_json,report_json,recovery_backup_path)
          VALUES (?,?,?,?,?,?,?,?,?,?)
        ''', [
          batchId,
          fresh.sourceKey,
          fresh.document.metadata['source'],
          PortableImportDocument.formatVersion,
          fresh.checksum,
          _epoch(clock()),
          'failed',
          '{}',
          jsonEncode({'error': '$error'}),
          backupPath
        ]);
      } catch (_) {
        // Original import failure has priority; the backup still exists.
      }
      rethrow;
    }
    db.notifyUpdates({
      const TableUpdate('historical_import_records'),
      const TableUpdate('daily_records'),
      const TableUpdate('nutrition_target_profiles'),
    });
    return ImportReport(batchId, backupPath, Map.unmodifiable(counts),
        List.unmodifiable(warnings));
  }

  void _requireResolution(ImportPreview preview, ImportResolution resolution) {
    final selectedTargetKeys = <String>{};
    for (final target in preview.document.records('targetProfiles')) {
      if (!resolution.createTargetProfiles.contains(target.id)) continue;
      final key = '${target.fields['kind']}/${target.fields['effectiveFrom']}';
      if (!selectedTargetKeys.add(key)) {
        throw ImportReviewRequired('Choose only one profile for $key.');
      }
    }
    for (final id in preview.targetConflicts) {
      if (resolution.createTargetProfiles.contains(id)) {
        throw ImportReviewRequired(
            'Target $id already has a local profile; leave it as an observation.');
      }
    }
    for (final conflict in preview.conflicts) {
      if (conflict.kind == 'foodMapping') {
        final id = conflict.key.substring('savedFoods/'.length);
        if (!resolution.foods.containsKey(id)) {
          throw ImportReviewRequired('Choose a Saved Food mapping for $id.');
        }
      } else if (conflict.kind == 'date') {
        final date = conflict.key.substring('date/'.length);
        if (!resolution.days.containsKey(date)) {
          throw ImportReviewRequired(
              'Resolve the existing or locked day $date.');
        }
      } else if (!resolution.keepExistingExternalIds.contains(conflict.key)) {
        throw ImportReviewRequired('Resolve ${conflict.key} before importing.');
      }
    }
    for (final food in preview.document.records('savedFoods')) {
      final choice = resolution.foods[food.id];
      if (choice?.choice == ImportChoice.link && choice?.localFoodId == null) {
        throw ImportReviewRequired(
            'A linked Saved Food needs a local food ID.');
      }
    }
  }

  PortableRecord? _record(
      ImportPreview preview, String collection, Object? id) {
    if (id is! String) return null;
    for (final record in preview.document.records(collection)) {
      if (record.id == id) return record;
    }
    return null;
  }

  Future<String?> _productBarcode(String? id) async {
    if (id == null) return null;
    final row = await db.customSelect(
      'SELECT barcode FROM products WHERE id=? AND deleted_at IS NULL',
      variables: [Variable.withString(id)],
    ).getSingleOrNull();
    return row?.read<String>('barcode');
  }

  Future<_WriteOutcome> _writeRecord(
      String collection,
      PortableRecord record,
      ImportPreview preview,
      ImportResolution resolution,
      Map<String, String?> localFoods,
      Map<String, String> localMeals,
      Map<String, String> localTargets,
      Map<String, String> localWorkouts,
      Map<String, String> workoutDates,
      Map<String, String> exerciseNames,
      Map<String, String> exerciseWorkouts,
      List<String> warnings) async {
    final fields = record.fields;
    final id = const Uuid().v4();
    switch (collection) {
      case 'nutritionSnapshots':
        // Source decimals remain verbatim in the import audit row. A log gets
        // its own immutable archive below; a snapshot alone is not a log.
        return const _WriteOutcome('observation');
      case 'savedFoods':
        final mapping = resolution.foods[record.id] ??
            const FoodMapping(ImportChoice.create);
        if (mapping.choice == ImportChoice.unlinked) {
          localFoods[record.id] = null;
          return const _WriteOutcome('observation');
        }
        if (mapping.choice == ImportChoice.link) {
          if (await _productBarcode(mapping.localFoodId) == null) {
            throw ImportReviewRequired(
                'Saved Food link ${record.id} no longer exists.');
          }
          localFoods[record.id] = mapping.localFoodId;
          return _WriteOutcome('linked', 'products', mapping.localFoodId);
        }
        final snapshot = _record(
            preview, 'nutritionSnapshots', fields['nutritionSnapshotId']);
        if (snapshot == null ||
            !_hasMacros(snapshot.fields) ||
            snapshot.fields['basis'] == 'perServing') {
          warnings.add(
              'Saved Food ${record.id}: no complete per-100 label; kept as unlinked observation.');
          localFoods[record.id] = null;
          return const _WriteOutcome('observation');
        }
        final barcode =
            'historical-import:${preview.sourceKey.substring(0, 16)}:${record.id}';
        final sf = snapshot.fields;
        final nutritionSource =
            _savedFoodNutritionSource(sf['provenance'], fields['provenance']);
        final verified = fields['verified'] == true &&
            fields['verifiedAt'] != null &&
            nutritionSource != 'estimate';
        if (fields['verified'] == true && !verified) {
          warnings.add(
              'Saved Food ${record.id}: verification cannot be asserted from this source/date; original flag remains in audit.');
        }
        final servingUnit = fields['servingUnit'];
        if (servingUnit == 'serving') {
          warnings.add(
              'Saved Food ${record.id}: local serving metadata needs g/ml; original serving text remains in audit.');
        }
        await db.customStatement('''
          INSERT INTO products (id,barcode,name,brand,calories,protein,carbs,fat,
            sugar,fiber,sodium,serving_size,serving_unit,nutrition_source,
            nutrition_verified,nutrition_verified_at,food_notes,source)
          VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ''', [
          id,
          barcode,
          fields['name'],
          fields['brand'],
          PortableDecimal.required(sf['calories']),
          PortableDecimal.required(sf['protein']),
          PortableDecimal.required(sf['carbs']),
          PortableDecimal.required(sf['fat']),
          PortableDecimal.optional(sf['sugar']),
          PortableDecimal.optional(sf['fiber']),
          PortableDecimal.optional(sf['sodium']),
          servingUnit == 'serving'
              ? null
              : PortableDecimal.optional(fields['servingSize']),
          servingUnit == 'serving' ? null : servingUnit,
          nutritionSource,
          verified ? 1 : 0,
          verified ? _timestamp(fields['verifiedAt']) : null,
          fields['notes'],
          'user',
        ]);
        localFoods[record.id] = id;
        return _WriteOutcome('created', 'products', id);
      case 'foodAliases':
        final barcode = await _productBarcode(localFoods[fields['foodId']]);
        if (barcode == null) {
          warnings.add(
              'Alias ${record.id} kept in audit: Saved Food was not linked.');
          return const _WriteOutcome('observation');
        }
        final normalized = normalizeFoodAlias(fields['alias'] as String);
        final existing = await db.customSelect('''
          SELECT id,deleted_at FROM food_aliases
          WHERE product_barcode=? AND normalized_alias=?
        ''', variables: [
          Variable.withString(barcode),
          Variable.withString(normalized)
        ]).getSingleOrNull();
        if (existing != null) {
          if (existing.read<int?>('deleted_at') != null) {
            warnings.add(
                'Alias ${record.id} was deleted locally; it was not restored automatically.');
            return const _WriteOutcome('observation');
          }
          return _WriteOutcome(
              'linked', 'food_aliases', existing.read<String>('id'));
        }
        await db.customStatement('''
          INSERT INTO food_aliases (id,product_barcode,alias,normalized_alias,language)
          VALUES (?,?,?,?,?)
        ''', [id, barcode, fields['alias'], normalized, fields['language']]);
        return _WriteOutcome('created', 'food_aliases', id);
      case 'meals':
        final date = record.date!;
        await db.customStatement('''
          INSERT INTO meal_entries (id,consumed_at,meal_type,title,source)
          VALUES (?,?,?,?,?)
        ''', [
          id,
          _epoch(_atNoon(date)),
          _mealType(fields['name'] as String),
          fields['name'],
          'historicalImport'
        ]);
        localMeals[record.id] = id;
        return _WriteOutcome('created', 'meal_entries', id);
      case 'targetProfiles':
        if (!_hasMacros(fields) ||
            !resolution.createTargetProfiles.contains(record.id)) {
          return const _WriteOutcome('observation');
        }
        final exists = await db.customSelect('''
          SELECT id FROM nutrition_target_profiles WHERE kind=? AND effective_from=?
            AND deleted_at IS NULL
        ''', variables: [
          Variable.withString(fields['kind'] as String),
          Variable.withString(fields['effectiveFrom'] as String)
        ]).getSingleOrNull();
        if (exists != null) {
          throw ImportReviewRequired(
              'Target ${record.id} conflicts with an existing profile.');
        }
        await db.customStatement('''
          INSERT INTO nutrition_target_profiles
          (id,kind,effective_from,calories,protein,carbs,fat)
          VALUES (?,?,?,?,?,?,?)
        ''', [
          id,
          fields['kind'],
          fields['effectiveFrom'],
          PortableDecimal.required(fields['calories']),
          PortableDecimal.required(fields['protein']),
          PortableDecimal.required(fields['carbs']),
          PortableDecimal.required(fields['fat'])
        ]);
        localTargets[record.id] = id;
        return _WriteOutcome('created', 'nutrition_target_profiles', id);
      case 'dailyRecords':
        final date = record.date!;
        final existing = await db.customSelect('''
          SELECT id, training_type, notes FROM daily_records
          WHERE date=? AND deleted_at IS NULL
        ''', variables: [Variable.withString(date)]).getSingleOrNull();
        final training = fields['trainingType'] as String?;
        final notes = fields['notes'] as String?;
        final targetId = localTargets[fields['targetProfileId']];
        if (existing != null) {
          if (resolution.days[date] == DayConflictChoice.useImported) {
            await db.customStatement('''
              UPDATE daily_records SET training_type=?,notes=?,
                target_override_id=COALESCE(?,target_override_id),updated_at=? WHERE id=?
            ''', [
              training ?? existing.read<String>('training_type'),
              notes ?? existing.read<String>('notes'),
              targetId,
              _epoch(clock()),
              existing.read<String>('id')
            ]);
            return _WriteOutcome(
                'linked', 'daily_records', existing.read<String>('id'));
          }
          return _WriteOutcome(
              'linked', 'daily_records', existing.read<String>('id'));
        }
        await db.customStatement('''
          INSERT INTO daily_records (id,date,timezone_name,utc_offset_minutes,
            training_type,notes,target_override_id)
          VALUES (?,?,?,?,?,?,?)
        ''', [
          id,
          date,
          'Imported local date',
          0,
          training ?? 'unset',
          notes ?? '',
          targetId
        ]);
        return _WriteOutcome('created', 'daily_records', id);
      case 'foodEntries':
        if (fields['status'] != 'consumed') {
          return const _WriteOutcome('observation');
        }
        final snapshot = _record(
            preview, 'nutritionSnapshots', fields['nutritionSnapshotId']);
        if (snapshot == null ||
            !_hasMacros(snapshot.fields) ||
            fields['quantity'] == null) {
          warnings.add(
              'Food ${record.id}: incomplete quantity/nutrition; no calculated log was created.');
          return const _WriteOutcome('observation');
        }
        final basis = snapshot.fields['basis'];
        final unit = fields['quantityUnit'];
        if (basis == 'perServing' && unit != 'serving' ||
            basis == 'per100g' && unit != 'g' ||
            basis == 'per100ml' && unit != 'ml') {
          warnings.add(
              'Food ${record.id}: snapshot basis and quantity unit differ; no calculated log was created.');
          return const _WriteOutcome('observation');
        }
        final quantity =
            PortableDecimal.required(fields['quantity'], positive: true);
        final amount = quantity;
        final foodId = fields['savedFoodId'] == null
            ? resolution.entryFoodLinks[record.id]
            : localFoods[fields['savedFoodId']];
        final barcode = await _productBarcode(foodId);
        if (foodId != null && barcode == null) {
          throw ImportReviewRequired(
              'Food link for ${record.id} no longer exists.');
        }
        final sf = snapshot.fields;
        final scale = basis == 'perServing' ? 100.0 : 1.0;
        final archiveHash = _digest(
            '${preview.sourceKey}/${record.id}/${_recordHash(snapshot)}');
        final archiveId = const Uuid().v4();
        await db.customStatement('''
          INSERT INTO off_products_archive
          (id,barcode,product_name,calories,protein,carbs,fat,sugar,fiber,sodium,
            content_hash,source,serving_unit,nutrition_source)
          VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ''', [
          archiveId,
          barcode ?? 'import:${record.id}',
          fields['name'],
          PortableDecimal.scaled(sf['calories'], scale),
          PortableDecimal.scaled(sf['protein'], scale),
          PortableDecimal.scaled(sf['carbs'], scale),
          PortableDecimal.scaled(sf['fat'], scale),
          sf['sugar'] == null
              ? null
              : PortableDecimal.scaled(sf['sugar'], scale),
          sf['fiber'] == null
              ? null
              : PortableDecimal.scaled(sf['fiber'], scale),
          sf['sodium'] == null
              ? null
              : PortableDecimal.scaled(sf['sodium'], scale),
          archiveHash,
          'historicalImport',
          basis == 'perServing' ? 'serving' : unit,
          _nutritionSource(sf['provenance']),
        ]);
        final archive = await db.customSelect(
          'SELECT local_id FROM off_products_archive WHERE id=?',
          variables: [Variable.withString(archiveId)],
        ).getSingle();
        final mealId = localMeals[fields['mealId']];
        final meal = _record(preview, 'meals', fields['mealId']);
        final mealType =
            meal == null ? 'Snack' : _mealType(meal.fields['name'] as String);
        await db.customStatement('''
          INSERT INTO nutrition_logs
          (id,product_id,legacy_barcode,consumed_at,amount,meal_type,
            archive_local_id,meal_entry_id)
          VALUES (?,?,?,?,?,?,?,?)
        ''', [
          id,
          foodId,
          barcode,
          _epoch(_atNoon(record.date!)),
          amount,
          mealType,
          archive.read<int>('local_id'),
          mealId
        ]);
        return _WriteOutcome('created', 'nutrition_logs', id);
      case 'workouts':
        final date = record.date!;
        final started =
            _workoutTime(fields['startedAt'], date, warnings, record.id);
        int? ended = _timestamp(fields['endedAt']);
        if (fields['startedAt'] == null && ended != null) {
          warnings.add(
              'Workout ${record.id}: end time without start time kept only in audit.');
          ended = null;
        }
        if (ended == null &&
            fields['startedAt'] != null &&
            fields['durationSeconds'] != null) {
          final duration = PortableDecimal.required(fields['durationSeconds'],
              positive: true);
          if (duration <= 2147483647 && duration == duration.roundToDouble()) {
            ended = started + duration.toInt();
          } else {
            warnings.add(
                'Workout ${record.id}: unsupported precise duration kept in audit only.');
          }
        }
        await db.customStatement('''
          INSERT INTO workout_logs
          (id,start_time,end_time,status,routine_name_snapshot,notes)
          VALUES (?,?,?,?,?,?)
        ''',
            [id, started, ended, 'completed', fields['name'], fields['notes']]);
        localWorkouts[record.id] = id;
        workoutDates[record.id] = date;
        return _WriteOutcome('created', 'workout_logs', id);
      case 'exercises':
        final workoutId = fields['workoutId'] as String;
        final localWorkout = localWorkouts[workoutId];
        if (localWorkout == null) {
          warnings.add(
              'Exercise ${record.id} has no imported workout; kept as observation.');
          return const _WriteOutcome('observation');
        }
        final name = fields['name'] as String;
        final linked = resolution.exerciseLinks[record.id];
        if (linked != null) {
          final exists = await db.customSelect(
            'SELECT id FROM exercises WHERE id=? AND deleted_at IS NULL',
            variables: [Variable.withString(linked)],
          ).getSingleOrNull();
          if (exists == null) {
            throw ImportReviewRequired(
                'Exercise mapping ${record.id} no longer exists.');
          }
        }
        await db.customStatement('''
          INSERT INTO workout_exercise_logs
          (id,workout_log_id,exercise_id,exercise_name_snapshot,notes)
          VALUES (?,?,?,?,?)
        ''', [id, localWorkout, linked, name, fields['notes']]);
        exerciseNames[record.id] = name;
        exerciseWorkouts[record.id] = workoutId;
        return _WriteOutcome('created', 'workout_exercise_logs', id);
      case 'workoutSets':
        final externalExercise = fields['exerciseId'] as String;
        final workoutId = exerciseWorkouts[externalExercise];
        final localWorkout = localWorkouts[workoutId];
        if (localWorkout == null) {
          warnings.add(
              'Set ${record.id} has no imported workout; kept as observation.');
          return const _WriteOutcome('observation');
        }
        final exercise = _record(preview, 'exercises', externalExercise);
        final name = exerciseNames[externalExercise] ??
            exercise?.fields['name'] as String?;
        final linked = resolution.exerciseLinks[externalExercise];
        final setCount = (fields['setCount'] as int?) ?? 1;
        final seconds = PortableDecimal.optional(fields['durationSeconds']);
        final nativeSeconds = seconds != null &&
                seconds <= 2147483647 &&
                seconds == seconds.roundToDouble()
            ? seconds.toInt()
            : null;
        if (seconds != null && seconds != seconds.roundToDouble()) {
          warnings.add(
              'Set ${record.id}: fractional seconds kept in audit; native set duration is whole seconds.');
        }
        final previousOrder = await db.customSelect('''
          SELECT COALESCE(MAX(log_order),-1) AS n FROM set_logs
          WHERE workout_log_id=?
        ''', variables: [Variable.withString(localWorkout)]).getSingle();
        final startOrder = previousOrder.read<int>('n') + 1;
        for (var index = 0; index < setCount; index++) {
          await db.customStatement('''
            INSERT INTO set_logs (id,workout_log_id,exercise_id,
              exercise_name_snapshot,weight,reps,duration_seconds,
              notes,is_completed,log_order)
            VALUES (?,?,?,?,?,?,?,?,?,?)
          ''', [
            index == 0 ? id : const Uuid().v4(),
            localWorkout,
            linked,
            name,
            _weightInKg(fields),
            fields['reps'],
            nativeSeconds,
            fields['notes'],
            1,
            startOrder + index
          ]);
        }
        return _WriteOutcome('created', 'set_logs', id);
      case 'measurements':
        final date = record.date!;
        final type = fields['type'] as String;
        final value = PortableDecimal.required(fields['value'], positive: true);
        final unit = fields['unit'] as String;
        final day = parseLocalDateKey(date);
        final start = DateTime(day.year, day.month, day.day);
        final end = DateTime(day.year, day.month, day.day + 1);
        final duplicate = await db.customSelect('''
          SELECT id FROM measurements WHERE type=? AND unit=? AND value=?
            AND date>=? AND date<? AND deleted_at IS NULL
        ''', variables: [
          Variable.withString(type),
          Variable.withString(unit),
          Variable.withReal(value),
          Variable.withInt(_epoch(start)),
          Variable.withInt(_epoch(end)),
        ]).getSingleOrNull();
        if (duplicate != null) {
          return _WriteOutcome(
              'linked', 'measurements', duplicate.read<String>('id'));
        }
        await db.customStatement('''
          INSERT INTO measurements (id,type,value,unit,date) VALUES (?,?,?,?,?)
        ''', [id, type, value, unit, _epoch(_atNoon(date))]);
        return _WriteOutcome('created', 'measurements', id);
      case 'progressPhotos':
        warnings.add(
            'Progress photo ${record.id}: original image is absent; metadata kept without a broken photo row.');
        return const _WriteOutcome('missingMedia');
      case 'lockedDays':
        final date = record.date!;
        // Lock after all other writes on the date. Existing locks are never bypassed.
        await DayLockRepository(db).lock(parseLocalDateKey(date));
        await db.customStatement('''
          UPDATE day_locks SET locked_at=? WHERE local_date=? AND deleted_at IS NULL
        ''', [_timestamp(fields['lockedAt']), date]);
        final lock = await db.customSelect('''
          SELECT id FROM day_locks WHERE local_date=? AND deleted_at IS NULL
        ''', variables: [Variable.withString(date)]).getSingle();
        return _WriteOutcome('created', 'day_locks', lock.read<String>('id'));
    }
    throw StateError('Unsupported collection $collection');
  }

  static bool _hasMacros(Map<String, Object?> fields) =>
      ['calories', 'protein', 'carbs', 'fat'].every(fields.containsKey);

  static String _nutritionSource(Object? source) => switch (source) {
        'exactLabel' => 'label',
        'userConfirmed' => 'manual',
        'restaurantEstimate' ||
        'assistantEstimate' ||
        'inferredApproximate' =>
          'estimate',
        _ => 'estimate',
      };

  static String _savedFoodNutritionSource(Object? snapshot, Object? food) {
    final fromSnapshot = _nutritionSource(snapshot);
    final fromFood = food == null ? fromSnapshot : _nutritionSource(food);
    if (fromSnapshot == 'estimate' || fromFood == 'estimate') {
      return 'estimate';
    }
    if (fromSnapshot == 'label' && fromFood == 'label') return 'label';
    return 'manual';
  }

  static String _mealType(String name) => switch (name.trim().toLowerCase()) {
        'breakfast' => 'Breakfast',
        'lunch' => 'Lunch',
        'dinner' => 'Dinner',
        _ => 'Snack',
      };

  static int? _timestamp(Object? value) =>
      value is String ? _epoch(DateTime.parse(value)) : null;

  static int _workoutTime(
      Object? value, String date, List<String> warnings, String id) {
    if (value == null) {
      warnings.add(
          'Workout $id has no start time; local noon is only a date anchor.');
      return _epoch(_atNoon(date));
    }
    final parsed = DateTime.parse(value as String);
    if (localDateKey(parsed.toLocal()) != date) {
      warnings.add(
          'Workout $id timestamp maps to a different current-zone day; explicit date wins.');
      return _epoch(_atNoon(date));
    }
    return _epoch(parsed);
  }

  static double? _weightInKg(Map<String, Object?> fields) {
    final weight = PortableDecimal.optional(fields['weight']);
    if (weight == null) return null;
    return fields['weightUnit'] == 'lb' ? weight * 0.45359237 : weight;
  }
}

class _WriteOutcome {
  final String state;
  final String? localTable;
  final String? localUuid;
  const _WriteOutcome(this.state, [this.localTable, this.localUuid]);
}
