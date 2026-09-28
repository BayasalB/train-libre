import 'dart:convert';

/// Phase 3A's portable, read-only interchange format. No database dependency.
enum ImportSeverity { error, warning }

class ImportIssue {
  final ImportSeverity severity;
  final String code;
  final String path;
  final String message;
  const ImportIssue(this.severity, this.code, this.path, this.message);
}

/// A validated portable record. [fields] uses portable names, never SQLite IDs.
class PortableRecord {
  final String id;
  final Map<String, Object?> fields;
  PortableRecord(this.id, Map<String, Object?> fields)
      : fields = _freezeMap(fields);

  String? get date => fields['date'] as String?;
  String? get provenance => fields['provenance'] as String?;
}

Map<String, Object?> _freezeMap(Map<String, Object?> source) =>
    Map<String, Object?>.unmodifiable(source.map((key, value) => MapEntry(
        key,
        value is Map<String, Object?>
            ? _freezeMap(value)
            : value is List
                ? List<Object?>.unmodifiable(value.map((item) =>
                    item is Map<String, Object?> ? _freezeMap(item) : item))
                : value)));

class PortableImportDocument {
  static const formatVersion = 1;
  final Map<String, Object?> metadata;
  final Map<String, List<PortableRecord>> collections;
  PortableImportDocument(Map<String, Object?> metadata,
      Map<String, List<PortableRecord>> collections)
      : metadata = Map.unmodifiable(metadata),
        collections = Map<String, List<PortableRecord>>.unmodifiable(
            collections.map((key, records) =>
                MapEntry(key, List<PortableRecord>.unmodifiable(records))));

  List<PortableRecord> records(String collection) =>
      collections[collection] ?? const [];
}

class PortableImportResult {
  final PortableImportDocument? document;
  final List<ImportIssue> issues;
  PortableImportResult(this.document, List<ImportIssue> issues)
      : issues = List.unmodifiable(issues);
  bool get isValid =>
      document != null &&
      !issues.any((issue) => issue.severity == ImportSeverity.error);
}

/// Strict v1 validator. Parsing never performs a write or resolves local foods.
class PortableImportParser {
  static const collections = <String>{
    'savedFoods',
    'foodAliases',
    'nutritionSnapshots',
    'foodEntries',
    'meals',
    'dailyRecords',
    'targetProfiles',
    'workouts',
    'exercises',
    'workoutSets',
    'measurements',
    'progressPhotos',
    'lockedDays',
  };
  static const _decimal = r'^(?:0|[1-9]\d*)(?:\.\d+)?$';
  static const _dates = r'^\d{4}-\d{2}-\d{2}$';
  static const _provenance = <String>{
    'exactLabel',
    'userConfirmed',
    'finalDailyTotal',
    'assistantEstimate',
    'restaurantEstimate',
    'inferredApproximate',
    'legacyObservation',
  };
  static const _training = <String>{
    'unset',
    'chest',
    'back',
    'shoulder',
    'legs',
    'arms',
    'fullBody',
    'rest',
  };
  static const _measurementTypes = <String>{
    'weight',
    'fat_percent',
    'waist',
    'abdomen',
    'lower_belly',
    'hips',
    'neck',
    'shoulder',
    'chest',
    'left_bicep',
    'right_bicep',
    'left_forearm',
    'right_forearm',
    'left_thigh',
    'right_thigh',
    'left_calf',
    'right_calf',
  };
  static const _nutritionKeys = <String>{
    'calories',
    'protein',
    'carbs',
    'fat',
    'fiber',
    'sugar',
    'sodium',
  };

  final List<ImportIssue> _issues = [];
  final Map<String, Set<String>> _ids = {};
  final Map<String, Map<String, Map<String, Object?>>> _rows = {};

  PortableImportResult parse(String source) {
    Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (e) {
      return PortableImportResult(null, [
        ImportIssue(ImportSeverity.error, 'malformedJson', r'$', e.message),
      ]);
    }
    return validate(decoded);
  }

  PortableImportResult validate(Object? value) {
    _issues.clear();
    _ids.clear();
    _rows.clear();
    final root = _object(value, r'$');
    if (root == null) return PortableImportResult(null, _issues);
    _shape(root, r'$', {'formatVersion', 'metadata', ...collections},
        {'formatVersion', 'metadata'});
    if (root['formatVersion'] != PortableImportDocument.formatVersion ||
        root['formatVersion'] is! int) {
      _error('unsupportedVersion', r'$.formatVersion',
          'Only formatVersion 1 is supported.');
    }
    final metadata = _object(root['metadata'], r'$.metadata');
    if (metadata != null) {
      _shape(metadata, r'$.metadata',
          {'source', 'sourceId', 'exportedAt', 'notes'}, {'source'});
      _text(metadata, 'source', r'$.metadata');
      _optionalText(metadata, 'sourceId', r'$.metadata');
      _optionalText(metadata, 'notes', r'$.metadata');
      _optionalTimestamp(metadata, 'exportedAt', r'$.metadata');
    }
    final records = <String, List<PortableRecord>>{};
    for (final collection in collections) {
      final raw = root[collection];
      if (raw == null && !root.containsKey(collection)) continue;
      if (raw is! List) {
        _error('invalidType', '\$.$collection', 'Expected an array.');
        continue;
      }
      final parsed = <PortableRecord>[];
      final ids = _ids.putIfAbsent(collection, () => {});
      final rows = _rows.putIfAbsent(collection, () => {});
      for (var index = 0; index < raw.length; index++) {
        final path = '\$.$collection[$index]';
        final row = _object(raw[index], path);
        if (row == null) continue;
        _validateRow(collection, row, path);
        final id = row['id'];
        if (id is! String || id.trim().isEmpty) continue;
        if (!ids.add(id)) {
          _error('duplicateId', '$path.id', 'ID is duplicated in $collection.');
        } else {
          rows[id] = row;
          parsed.add(PortableRecord(id, row));
        }
      }
      records[collection] = parsed;
    }
    _references();
    if (_issues.any((issue) => issue.severity == ImportSeverity.error)) {
      return PortableImportResult(null, _issues);
    }
    return PortableImportResult(
        PortableImportDocument(metadata!, records), _issues);
  }

  void _validateRow(String type, Map<String, Object?> row, String path) {
    final allowed = <String>{'id'};
    final required = <String>{'id'};
    void fields(Set<String> names, [Set<String> mandatory = const {}]) {
      allowed.addAll(names);
      required.addAll(mandatory);
    }

    switch (type) {
      case 'savedFoods':
        fields({
          'name',
          'brand',
          'servingSize',
          'servingUnit',
          'nutritionSnapshotId',
          'localFoodRef',
          'notes',
          'provenance',
          'verified',
          'verifiedAt',
          'productPhotoRef',
          'nutritionLabelPhotoRef'
        }, {
          'name'
        });
        _text(row, 'name', path);
        for (final key in ['brand', 'notes']) {
          _optionalText(row, key, path);
        }
        _optionalDecimal(row, 'servingSize', path, positive: true);
        _choice(row, 'servingUnit', path, {'g', 'ml', 'serving'});
        if (row.containsKey('servingSize') != row.containsKey('servingUnit')) {
          _error('incompleteServing', path,
              'Serving size and unit must appear together.');
        }
        _optionalText(row, 'localFoodRef', path);
        if (row.containsKey('localFoodRef')) {
          _warning('unresolvedLocalFood', '$path.localFoodRef',
              'Local food hint must be resolved explicitly during import.');
        }
        _optionalBool(row, 'verified', path);
        _optionalTimestamp(row, 'verifiedAt', path);
        for (final key in ['productPhotoRef', 'nutritionLabelPhotoRef']) {
          _optionalText(row, key, path);
          if (row.containsKey(key)) {
            _warning('mediaNotBundled', '$path.$key',
                'This JSON does not contain the original image bytes.');
          }
        }
        _optionalText(row, 'nutritionSnapshotId', path);
        break;
      case 'foodAliases':
        fields({'foodId', 'alias', 'language'}, {'foodId', 'alias'});
        _text(row, 'foodId', path);
        _text(row, 'alias', path);
        _optionalText(row, 'language', path);
        break;
      case 'nutritionSnapshots':
        fields({'basis', ..._nutritionKeys, 'provenance'},
            {'basis', 'provenance'});
        _choice(row, 'basis', path, {'per100g', 'per100ml', 'perServing'},
            required: true);
        _nutrition(row, path, requireAny: true);
        break;
      case 'foodEntries':
        fields({
          'date',
          'name',
          'status',
          'quantity',
          'quantityUnit',
          'savedFoodId',
          'localFoodRef',
          'nutritionSnapshotId',
          'mealId',
          'notes',
          'provenance'
        }, {
          'date',
          'name',
          'status'
        });
        _date(row, 'date', path);
        _text(row, 'name', path);
        _choice(row, 'status', path, {'consumed', 'planned', 'cancelled'},
            required: true);
        _optionalDecimal(row, 'quantity', path, positive: true);
        _choice(row, 'quantityUnit', path, {'g', 'ml', 'serving'});
        if (row.containsKey('quantity') != row.containsKey('quantityUnit')) {
          _error('incompleteQuantity', path,
              'Quantity and quantityUnit must appear together.');
        }
        _optionalText(row, 'notes', path);
        _optionalText(row, 'localFoodRef', path);
        if (row.containsKey('localFoodRef')) {
          _warning('unresolvedLocalFood', '$path.localFoodRef',
              'Local food hint must be resolved explicitly during import.');
        }
        for (final key in ['savedFoodId', 'nutritionSnapshotId', 'mealId']) {
          _optionalText(row, key, path);
        }
        break;
      case 'meals':
        fields({'date', 'name', 'notes'}, {'date', 'name'});
        _date(row, 'date', path);
        _text(row, 'name', path);
        _optionalText(row, 'notes', path);
        break;
      case 'dailyRecords':
        fields({
          'date',
          'trainingType',
          'notes',
          'reportedTotal',
          'targetProfileId'
        }, {
          'date'
        });
        _date(row, 'date', path);
        _choice(row, 'trainingType', path, _training);
        _optionalText(row, 'notes', path);
        _optionalText(row, 'targetProfileId', path);
        if (row.containsKey('reportedTotal')) {
          final total = _object(row['reportedTotal'], '$path.reportedTotal');
          if (total != null) {
            _shape(total, '$path.reportedTotal',
                {..._nutritionKeys, 'provenance'}, {'provenance'});
            _nutrition(total, '$path.reportedTotal', requireAny: true);
            _choice(total, 'provenance', '$path.reportedTotal', _provenance,
                required: true);
          }
        }
        break;
      case 'targetProfiles':
        fields({
          'kind',
          'effectiveFrom',
          'calories',
          'protein',
          'carbs',
          'fat',
          'provenance'
        }, {
          'kind',
          'effectiveFrom'
        });
        _choice(row, 'kind', path, {'training', 'rest'}, required: true);
        _date(row, 'effectiveFrom', path);
        if (!['calories', 'protein', 'carbs', 'fat'].any(row.containsKey)) {
          _error('emptyTarget', path, 'At least one target value is required.');
        }
        for (final key in ['calories', 'protein', 'carbs', 'fat']) {
          _optionalDecimal(row, key, path, positive: key == 'calories');
        }
        break;
      case 'workouts':
        fields({
          'date',
          'name',
          'trainingType',
          'startedAt',
          'endedAt',
          'durationSeconds',
          'notes',
          'provenance'
        }, {
          'date'
        });
        _date(row, 'date', path);
        _choice(row, 'trainingType', path, _training);
        _optionalText(row, 'name', path);
        _optionalText(row, 'notes', path);
        _optionalTimestamp(row, 'startedAt', path);
        _optionalTimestamp(row, 'endedAt', path);
        _optionalDecimal(row, 'durationSeconds', path, positive: true);
        if (row['startedAt'] is String && row['endedAt'] is String) {
          final start = DateTime.tryParse(row['startedAt'] as String);
          final end = DateTime.tryParse(row['endedAt'] as String);
          if (start != null && end != null && end.isBefore(start)) {
            _error('invalidTimeRange', path, 'endedAt precedes startedAt.');
          }
        }
        break;
      case 'exercises':
        fields({'workoutId', 'name', 'notes'}, {'workoutId', 'name'});
        _text(row, 'workoutId', path);
        _text(row, 'name', path);
        _optionalText(row, 'notes', path);
        break;
      case 'workoutSets':
        fields({
          'exerciseId',
          'weight',
          'weightUnit',
          'reps',
          'durationSeconds',
          'setCount',
          'notes',
          'provenance'
        }, {
          'exerciseId'
        });
        _text(row, 'exerciseId', path);
        _optionalDecimal(row, 'weight', path);
        _choice(row, 'weightUnit', path, {'kg', 'lb'});
        if (row.containsKey('weight') != row.containsKey('weightUnit')) {
          _error('incompleteWeight', path,
              'Weight and weightUnit must appear together.');
        }
        _optionalInteger(row, 'reps', path);
        _optionalInteger(row, 'setCount', path, positive: true);
        _optionalDecimal(row, 'durationSeconds', path, positive: true);
        _optionalText(row, 'notes', path);
        if (!['weight', 'reps', 'durationSeconds'].any(row.containsKey)) {
          _error('emptySet', path,
              'A set needs weight, reps, or durationSeconds.');
        }
        break;
      case 'measurements':
        fields({'date', 'type', 'value', 'unit', 'notes', 'provenance'},
            {'date', 'type', 'value', 'unit'});
        _date(row, 'date', path);
        _choice(row, 'type', path, _measurementTypes, required: true);
        _decimalField(row, 'value', path, positive: true);
        _choice(row, 'unit', path, {'kg', 'lb', 'cm', 'in', '%'},
            required: true);
        final kind = row['type'];
        final unit = row['unit'];
        if (kind == 'weight' && unit != 'kg' && unit != 'lb' ||
            kind == 'fat_percent' && unit != '%' ||
            kind is String &&
                _measurementTypes.contains(kind) &&
                kind != 'weight' &&
                kind != 'fat_percent' &&
                unit != 'cm' &&
                unit != 'in') {
          _error('measurementUnitMismatch', '$path.unit',
              'Unit is incompatible with measurement type.');
        }
        _optionalText(row, 'notes', path);
        break;
      case 'progressPhotos':
        fields({'date', 'mediaRef', 'notes', 'provenance'}, {'date'});
        _date(row, 'date', path);
        _optionalText(row, 'mediaRef', path);
        if (row.containsKey('mediaRef')) {
          _warning('mediaNotBundled', '$path.mediaRef',
              'This JSON does not contain the original image bytes.');
        }
        _optionalText(row, 'notes', path);
        break;
      case 'lockedDays':
        fields({'date', 'lockedAt', 'provenance'}, {'date', 'lockedAt'});
        _date(row, 'date', path);
        _timestamp(row, 'lockedAt', path);
        break;
    }
    _shape(row, path, allowed, required);
    _text(row, 'id', path);
    if (row.containsKey('provenance')) {
      _choice(row, 'provenance', path, _provenance);
    }
  }

  void _references() {
    void ref(String source, String field, String destination) {
      for (final entry in (_rows[source] ?? {}).entries) {
        final id = entry.value[field];
        if (id == null) continue;
        if (id is! String ||
            id.isEmpty ||
            !(_ids[destination] ?? {}).contains(id)) {
          _error('brokenReference', '\$.$source[id=${entry.key}].$field',
              'Reference must point to a $destination record in this file.');
        }
      }
    }

    ref('savedFoods', 'nutritionSnapshotId', 'nutritionSnapshots');
    ref('foodAliases', 'foodId', 'savedFoods');
    ref('foodEntries', 'savedFoodId', 'savedFoods');
    ref('foodEntries', 'nutritionSnapshotId', 'nutritionSnapshots');
    ref('foodEntries', 'mealId', 'meals');
    ref('dailyRecords', 'targetProfileId', 'targetProfiles');
    ref('exercises', 'workoutId', 'workouts');
    ref('workoutSets', 'exerciseId', 'exercises');
    for (final entry in (_rows['dailyRecords'] ?? {}).entries) {
      final row = entry.value;
      final profile = _rows['targetProfiles']?[row['targetProfileId']];
      if (profile != null &&
          row['date'] is String &&
          profile['effectiveFrom'] is String &&
          (profile['effectiveFrom'] as String)
                  .compareTo(row['date'] as String) >
              0) {
        _error(
            'futureTarget',
            '\$.dailyRecords[id=${entry.key}].targetProfileId',
            'The referenced target becomes effective after this day.');
      }
    }
    for (final entry in (_rows['foodEntries'] ?? {}).entries) {
      final row = entry.value;
      final base = '\$.foodEntries[id=${entry.key}]';
      final meal = _rows['meals']?[row['mealId']];
      if (meal != null && meal['date'] != row['date']) {
        _error('dateMismatch', '$base.mealId', 'Meal and entry dates differ.');
      }
      final snapshot = _rows['nutritionSnapshots']?[row['nutritionSnapshotId']];
      if (snapshot != null && row['quantityUnit'] != null) {
        final expected = {
          'per100g': 'g',
          'per100ml': 'ml',
          'perServing': 'serving'
        }[snapshot['basis']];
        if (expected != row['quantityUnit']) {
          _error('unitMismatch', '$base.quantityUnit',
              'Quantity unit differs from snapshot basis.');
        }
      }
      if (snapshot != null && row['quantity'] == null) {
        _error('missingQuantity', '$base.quantity',
            'A snapshot requires a quantity.');
      }
    }
    for (final collection in ['dailyRecords', 'lockedDays']) {
      final dates = <String>{};
      for (final entry in (_rows[collection] ?? {}).entries) {
        final date = entry.value['date'];
        if (date is String && !dates.add(date)) {
          _error('duplicateDate', '\$.$collection[id=${entry.key}].date',
              'Only one $collection record is allowed per date.');
        }
      }
    }
    final profiles = <String>{};
    for (final entry in (_rows['targetProfiles'] ?? {}).entries) {
      final row = entry.value;
      final key = '${row['kind']}/${row['effectiveFrom']}';
      if (!profiles.add(key)) {
        _error('duplicateTargetDate', '\$.targetProfiles[id=${entry.key}]',
            'Target kind and effective date must be unique.');
      }
    }
  }

  Map<String, Object?>? _object(Object? value, String path) {
    if (value is! Map || value.keys.any((key) => key is! String)) {
      _error('invalidType', path, 'Expected an object with string keys.');
      return null;
    }
    return Map<String, Object?>.from(value);
  }

  void _shape(Map<String, Object?> row, String path, Set<String> allowed,
      Set<String> required) {
    for (final key in required) {
      if (!row.containsKey(key)) {
        _error('required', '$path.$key', 'Required field is missing.');
      }
    }
    for (final key in row.keys) {
      if (!allowed.contains(key)) {
        _error('unknownField', '$path.$key',
            'Unknown field is not supported in v1.');
      }
    }
  }

  void _error(String code, String path, String message) =>
      _issues.add(ImportIssue(ImportSeverity.error, code, path, message));

  void _warning(String code, String path, String message) =>
      _issues.add(ImportIssue(ImportSeverity.warning, code, path, message));

  void _text(Map<String, Object?> row, String key, String path) {
    if (row[key] is! String || (row[key] as String).trim().isEmpty) {
      _error('invalidText', '$path.$key', 'Expected non-empty text.');
    }
  }

  void _optionalText(Map<String, Object?> row, String key, String path) {
    if (row.containsKey(key)) _text(row, key, path);
  }

  void _optionalBool(Map<String, Object?> row, String key, String path) {
    if (row.containsKey(key) && row[key] is! bool) {
      _error('invalidType', '$path.$key', 'Expected boolean.');
    }
  }

  void _choice(
      Map<String, Object?> row, String key, String path, Set<String> values,
      {bool required = false}) {
    if (!row.containsKey(key) && !required) return;
    if (!values.contains(row[key])) {
      _error('invalidEnum', '$path.$key',
          'Expected one of: ${values.join(', ')}.');
    }
  }

  void _decimalField(Map<String, Object?> row, String key, String path,
      {bool positive = false}) {
    final value = row[key];
    if (value is! String ||
        !RegExp(_decimal).hasMatch(value) ||
        double.tryParse(value) == null ||
        !double.parse(value).isFinite ||
        (positive && double.parse(value) <= 0)) {
      _error('invalidDecimal', '$path.$key',
          'Expected a finite ${positive ? 'positive' : 'nonnegative'} decimal string.');
    }
  }

  void _optionalDecimal(Map<String, Object?> row, String key, String path,
      {bool positive = false}) {
    if (row.containsKey(key)) _decimalField(row, key, path, positive: positive);
  }

  void _optionalInteger(Map<String, Object?> row, String key, String path,
      {bool positive = false}) {
    if (!row.containsKey(key)) return;
    final value = row[key];
    if (value is! int || value < (positive ? 1 : 0)) {
      _error('invalidInteger', '$path.$key',
          'Expected a ${positive ? 'positive' : 'nonnegative'} integer.');
    }
  }

  void _nutrition(Map<String, Object?> row, String path,
      {bool requireAny = false}) {
    if (requireAny && !_nutritionKeys.any(row.containsKey)) {
      _error(
          'emptyNutrition', path, 'At least one nutrition value is required.');
    }
    for (final key in _nutritionKeys) {
      _optionalDecimal(row, key, path);
    }
  }

  void _date(Map<String, Object?> row, String key, String path) {
    final value = row[key];
    if (value is! String || !RegExp(_dates).hasMatch(value)) {
      _error('invalidDate', '$path.$key', 'Expected YYYY-MM-DD.');
      return;
    }
    final parsed = DateTime.tryParse(value);
    if (parsed == null ||
        '${parsed.year.toString().padLeft(4, '0')}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')}' !=
            value) {
      _error('invalidDate', '$path.$key', 'Invalid calendar date.');
    }
  }

  void _timestamp(Map<String, Object?> row, String key, String path) {
    final value = row[key];
    if (value is! String ||
        !RegExp(r'T.*(?:Z|[+-]\d{2}:\d{2})$').hasMatch(value) ||
        DateTime.tryParse(value) == null) {
      _error('invalidTimestamp', '$path.$key',
          'Expected ISO 8601 timestamp with offset.');
    }
  }

  void _optionalTimestamp(Map<String, Object?> row, String key, String path) {
    if (row.containsKey(key)) _timestamp(row, key, path);
  }
}
