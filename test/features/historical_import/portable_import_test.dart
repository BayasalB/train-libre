import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:train_libre/features/historical_import/domain/portable_import.dart';

void main() {
  late Map<String, dynamic> example;
  setUp(() {
    example = jsonDecode(
        File('documentation/examples/portable-historical-import-v1.json')
            .readAsStringSync()) as Map<String, dynamic>;
  });

  PortableImportResult parse() =>
      PortableImportParser().parse(jsonEncode(example));
  void expectError(String code) {
    final result = parse();
    expect(result.isValid, isFalse);
    expect(result.document, isNull);
    expect(result.issues.map((issue) => issue.code), contains(code));
    expect(result.issues.first.path, startsWith(r'$'));
  }

  test('complete file and every collection validate without writes', () {
    final schema = jsonDecode(
        File('documentation/portable-historical-import-v1.schema.json')
            .readAsStringSync()) as Map<String, dynamic>;
    expect((schema['properties'] as Map)['formatVersion']['const'], 1);
    final result = parse();
    expect(result.issues, isEmpty);
    expect(result.isValid, isTrue);
    expect(result.document!.records('foodEntries'), hasLength(4));
    expect(result.document!.records('workoutSets'), hasLength(5));
  });

  test('total-only day remains separate from calculated food entries', () {
    final document = parse().document!;
    final day = document
        .records('dailyRecords')
        .singleWhere((record) => record.date == '2026-09-24');
    expect((day.fields['reportedTotal'] as Map)['protein'], '202.9');
    expect(
        document
            .records('foodEntries')
            .where((entry) => entry.date == '2026-09-24'),
        isEmpty);
  });

  test('partial historical targets preserve unknown nutrients', () {
    final target = (example['targetProfiles'] as List).first as Map;
    target.remove('carbs');
    target.remove('fat');
    final result = parse();
    expect(result.isValid, isTrue);
    expect(result.document!.records('targetProfiles').first.fields['protein'],
        '200');
    expect(
        result.document!
            .records('targetProfiles')
            .first
            .fields
            .containsKey('carbs'),
        isFalse);
    target.remove('calories');
    target.remove('protein');
    expectError('emptyTarget');
  });

  test('consumed, planned, cancelled remain distinct', () {
    final entries = parse().document!.records('foodEntries');
    expect(entries.map((entry) => entry.fields['status']),
        containsAll(['consumed', 'planned', 'cancelled']));
    expect(entries.where((entry) => entry.fields['status'] == 'consumed'),
        hasLength(2));
  });

  test('decimal lexical precision and provenance survive parsing', () {
    final document = parse().document!;
    expect(
        document
            .records('foodEntries')
            .singleWhere((entry) => entry.id == 'entry-planned')
            .fields['quantity'],
        '45.5');
    expect(
        document
            .records('measurements')
            .singleWhere((entry) => entry.id == 'measure-lower-belly')
            .fields['value'],
        '103.0');
    expect(
        document
            .records('nutritionSnapshots')
            .singleWhere((entry) => entry.id == 'snapshot-restaurant')
            .provenance,
        'restaurantEstimate');
    (example['foodEntries'] as List).add({
      'id': 'entry-decimal',
      'date': '2026-09-23',
      'name': 'Exact quantity',
      'status': 'consumed',
      'quantity': '293.8',
      'quantityUnit': 'g',
      'nutritionSnapshotId': 'snapshot-oats',
    });
    expect(parse().document!.records('foodEntries').last.fields['quantity'],
        '293.8');
  });

  test('duplicate IDs are rejected', () {
    (example['foodEntries'] as List).add(Map<String, dynamic>.from(
        (example['foodEntries'] as List).first as Map));
    expectError('duplicateId');
  });

  test('broken references and cross-day meals are rejected', () {
    ((example['foodEntries'] as List).first as Map)['savedFoodId'] = 'missing';
    expectError('brokenReference');
    ((example['foodEntries'] as List).first as Map)['savedFoodId'] =
        'food-oats';
    ((example['foodEntries'] as List).first as Map)['date'] = '2026-09-24';
    expectError('dateMismatch');
  });

  test('historical day cannot point to a future target revision', () {
    ((example['dailyRecords'] as List).first as Map)['targetProfileId'] =
        'target-training';
    expect(parse().isValid, isTrue);
    ((example['targetProfiles'] as List).first as Map)['effectiveFrom'] =
        '2026-09-24';
    expectError('futureTarget');
  });

  test('future version and unknown optional fields fail closed', () {
    example['formatVersion'] = 2;
    expectError('unsupportedVersion');
    example['formatVersion'] = 1;
    ((example['savedFoods'] as List).first as Map)['futureMeaning'] = true;
    expectError('unknownField');
  });

  test('NaN, Infinity, overflow and numeric JSON values reject', () {
    final snapshot = (example['nutritionSnapshots'] as List).first as Map;
    for (final value in ['NaN', 'Infinity', '1e999', 293.8, '-2']) {
      snapshot['calories'] = value;
      expectError('invalidDecimal');
    }
  });

  test('invalid dates and timestamps reject', () {
    ((example['dailyRecords'] as List).first as Map)['date'] = '2026-02-30';
    expectError('invalidDate');
    ((example['dailyRecords'] as List).first as Map)['date'] = '2026-09-23';
    ((example['lockedDays'] as List).first as Map)['lockedAt'] =
        '2026-09-24T23:12:00';
    expectError('invalidTimestamp');
  });

  test('workout sets reject malformed or empty data', () {
    final set = (example['workoutSets'] as List).first as Map;
    set['reps'] = -1;
    expectError('invalidInteger');
    set['reps'] = 8;
    set.remove('weightUnit');
    expectError('incompleteWeight');
    set.remove('weight');
    set.remove('reps');
    expectError('emptySet');
  });

  test('measurement types and units validate; abdomen != lower belly', () {
    final measurements = example['measurements'] as List;
    expect(measurements.map((m) => (m as Map)['type']),
        containsAll(['abdomen', 'lower_belly']));
    (measurements.first as Map)['type'] = 'unknown';
    expectError('invalidEnum');
    (measurements.first as Map)['type'] = 'weight';
    (measurements.first as Map)['unit'] = 'cm';
    expectError('measurementUnitMismatch');
  });

  test('unknown food reference is optional; unknown local hint is inert', () {
    final entry = (example['foodEntries'] as List).first as Map;
    entry.remove('savedFoodId');
    entry['localFoodRef'] = 'unresolved-local-food';
    final result = parse();
    expect(result.isValid, isTrue);
    expect(result.issues.map((issue) => issue.code),
        contains('unresolvedLocalFood'));
    expect(result.issues.single.severity, ImportSeverity.warning);
  });

  test('validated nested totals cannot mutate after parsing', () {
    final day = parse()
        .document!
        .records('dailyRecords')
        .singleWhere((record) => record.date == '2026-09-24');
    expect(() => (day.fields['reportedTotal'] as Map)['calories'] = '0',
        throwsUnsupportedError);
  });

  test('present but null reference is rejected, not silently ignored', () {
    ((example['foodEntries'] as List).first as Map)['savedFoodId'] = null;
    expectError('invalidText');
  });

  test('snapshot basis must agree with entry quantity unit', () {
    ((example['foodEntries'] as List).first as Map)['quantityUnit'] = 'ml';
    expectError('unitMismatch');
  });

  test('photo media reference warns that original bytes are absent', () {
    ((example['progressPhotos'] as List).first as Map)['mediaRef'] =
        'opaque-media-id';
    ((example['savedFoods'] as List).first as Map)['nutritionLabelPhotoRef'] =
        'opaque-label-id';
    final result = parse();
    expect(result.isValid, isTrue);
    expect(result.issues.where((issue) => issue.code == 'mediaNotBundled'),
        hasLength(2));
  });

  test('explicit finalization only; final total alone does not lock', () {
    example.remove('lockedDays');
    final result = parse();
    expect(result.isValid, isTrue);
    expect(result.document!.records('lockedDays'), isEmpty);
  });

  test('malformed JSON yields structured error', () {
    final result = PortableImportParser().parse('{"formatVersion":');
    expect(result.isValid, isFalse);
    expect(result.issues.single.code, 'malformedJson');
  });
}
