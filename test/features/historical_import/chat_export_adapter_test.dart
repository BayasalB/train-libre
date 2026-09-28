import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:train_libre/data/drift_database.dart';
import 'package:train_libre/features/historical_import/data/historical_import_service.dart';
import 'package:train_libre/features/historical_import/domain/chat_export_reader.dart';
import 'package:train_libre/features/historical_import/domain/chat_fitness_adapter.dart';
import 'package:train_libre/features/historical_import/domain/portable_import.dart';
import 'package:train_libre/features/historical_import/presentation/chatgpt_export_adapter_screen.dart';
import 'package:train_libre/features/historical_import/presentation/historical_import_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final reader = ChatExportReader();
  ChatExportCatalog linear() => reader.read('conversations.json',
      File('test/fixtures/chatgpt_export/linear.json').readAsBytesSync());
  ChatFitnessExtraction extract(ChatExportCatalog catalog,
          [Map<String, String?>? selected]) =>
      ChatFitnessAdapter()
          .extract(catalog, selected ?? {'synthetic-fitness-a': null});

  test('discovers conversations and searches titles and content', () {
    final catalog = linear();
    expect(catalog.conversations, hasLength(3));
    expect(catalog.search('Muscle Cut'), hasLength(2));
    expect(catalog.search('Garden'), hasLength(1));
    expect(catalog.search('Squat').single.id, 'synthetic-fitness-a');
    expect(catalog.conversations.first.approximateMessageCount, 16);
    expect(catalog.conversations.first.firstMessageAt!.day, 24);
  });

  test('selection excludes unrelated conversation and supports multiple chats',
      () {
    final catalog = linear();
    final single = extract(catalog);
    expect(
        single.candidates
            .expand((c) => c.sourceRefs)
            .any((ref) => ref.contains('synthetic-unrelated')),
        isFalse);
    final multi = extract(catalog, {
      'synthetic-fitness-a': null,
      'synthetic-fitness-b': null,
    });
    expect(
        multi.candidates.where((c) =>
            c.collection == 'measurements' &&
            c.fields['type'] == 'lower_belly'),
        hasLength(1));
  });

  test('tree follows current branch without duplicate messages', () {
    final catalog = reader.read('conversations.json',
        File('test/fixtures/chatgpt_export/tree.json').readAsBytesSync());
    final conversation = catalog.conversations.single;
    expect(conversation.branches, hasLength(2));
    expect(conversation.activeBranch, 'active');
    expect(conversation.messagesForBranch(null).map((m) => m.id),
        ['tree-user', 'tree-active']);
    expect(conversation.messagesForBranch('discarded').map((m) => m.id),
        ['tree-user', 'tree-discarded']);
  });

  test('ambiguous branch without current_node requires explicit selection', () {
    final root = jsonDecode(
            File('test/fixtures/chatgpt_export/tree.json').readAsStringSync())
        as List;
    (root.single as Map).remove('current_node');
    final catalog =
        reader.read('conversations.json', utf8.encode(jsonEncode(root)));
    expect(catalog.conversations.single.activeBranch, isNull);
    expect(() => extract(catalog, {'synthetic-tree': null}),
        throwsA(isA<ChatExportException>()));
    expect(
        extract(catalog, {'synthetic-tree': 'active'}).candidates, isNotEmpty);
  });

  test('broken mapping parent cannot fall back to all branch messages', () {
    final root = jsonDecode(
            File('test/fixtures/chatgpt_export/tree.json').readAsStringSync())
        as List;
    ((root.single as Map)['mapping'] as Map).remove('root');
    final catalog =
        reader.read('conversations.json', utf8.encode(jsonEncode(root)));
    expect(
        catalog.conversations.single.warnings
            .any((w) => w.contains('Missing parent')),
        isTrue);
    expect(() => extract(catalog, {'synthetic-tree': null}),
        throwsA(isA<ChatExportException>()));
  });

  test(
      'ZIP and split conversation files are discovered without file order assumptions',
      () {
    final archive = Archive();
    final fixture =
        File('test/fixtures/chatgpt_export/tree.json').readAsBytesSync();
    archive.addFile(
        ArchiveFile.bytes('unrelated/account.json', utf8.encode('{}')));
    archive
        .addFile(ArchiveFile.bytes('nested/conversations-0002.json', fixture));
    final catalog =
        reader.read('export.zip', ZipEncoder().encodeBytes(archive));
    expect(catalog.conversations.single.id, 'synthetic-tree');
    expect(catalog.detectedFiles, contains('unrelated/account.json'));
  });

  test('multiple selected unzipped conversation chunks are combined', () {
    final rows = jsonDecode(
            File('test/fixtures/chatgpt_export/linear.json').readAsStringSync())
        as List;
    final catalog = reader.readMany({
      'conversations-0002.json': utf8.encode(jsonEncode([rows[2]])),
      'conversations-0001.json': utf8.encode(jsonEncode([rows[0]])),
    });
    expect(catalog.conversations.map((c) => c.id),
        containsAll(['synthetic-fitness-a', 'synthetic-fitness-b']));
    expect(catalog.detectedFiles, hasLength(2));
    expect(() => reader.readMany({'other.json': utf8.encode('[]')}),
        throwsA(isA<ChatExportException>()));
  });

  test('malformed or unrecognized export stops with structure explanation', () {
    expect(() => reader.read('conversations.json', utf8.encode('{')),
        throwsA(isA<ChatExportException>()));
    expect(() => reader.read('conversations.json', utf8.encode('{"foo":1}')),
        throwsA(predicate((error) => '$error'.contains('unrecognized'))));
    final archive = Archive()
      ..addFile(ArchiveFile.bytes('profile.json', utf8.encode('{}')));
    expect(() => reader.read('export.zip', ZipEncoder().encodeBytes(archive)),
        throwsA(predicate((error) => '$error'.contains('profile.json'))));
  });

  test(
      'planned food later consumed, cancellation, and food identity stay distinct',
      () {
    final result = extract(linear());
    final entries =
        result.candidates.where((c) => c.collection == 'foodEntries').toList();
    final whey =
        entries.singleWhere((c) => '${c.fields['name']}'.contains('uurag'));
    expect(whey.fields['status'], 'consumed');
    expect(whey.sourceRefs.any((ref) => ref.contains('/m05@')), isTrue);
    final burger = entries.singleWhere((c) => c.fields['name'] == 'Burger');
    expect(burger.fields['status'], 'cancelled');
    final oats =
        entries.where((c) => c.fields['name'] == 'Hercules Oats').toList();
    expect(oats, hasLength(2));
    expect(oats.every((c) => c.fields['nutritionSnapshotId'] != null), isTrue);
    expect(
        result.candidates.where((c) =>
            c.collection == 'foodAliases' && c.fields['alias'] == 'ovyoos'),
        hasLength(1));
  });

  test('later grams correction changes one food without double count', () {
    final catalog = reader.read(
        'conversations.json',
        utf8.encode(jsonEncode([
          {
            'id': 'food-correction',
            'title': 'Synthetic',
            'messages': [
              {
                'id': 'c1',
                'role': 'user',
                'create_time': '2026-09-24T08:00:00+08:00',
                'content': '80g oats idsen'
              },
              {
                'id': 'c2',
                'role': 'user',
                'create_time': '2026-09-24T08:01:00+08:00',
                'content': '80g bish 60g oats'
              }
            ]
          }
        ])));
    final result = extract(catalog, {'food-correction': null});
    final entries =
        result.candidates.where((c) => c.collection == 'foodEntries').toList();
    expect(entries, hasLength(1));
    expect(entries.single.fields['quantity'], '60');
    expect(entries.single.sourceRefs.length, 2);
  });

  test('raw-weight correction removes uncertain food from default output', () {
    final catalog = reader.read(
        'conversations.json',
        utf8.encode(jsonEncode([
          {
            'id': 'raw-weight',
            'title': 'Synthetic',
            'messages': [
              {
                'id': 'r1',
                'role': 'user',
                'create_time': '2026-09-24T08:00:00+08:00',
                'content': '800g beef idsen'
              },
              {
                'id': 'r2',
                'role': 'user',
                'create_time': '2026-09-24T08:01:00+08:00',
                'content': '800g ni tuuhii jin'
              }
            ]
          }
        ])));
    final result = extract(catalog, {'raw-weight': null});
    final entry =
        result.candidates.singleWhere((c) => c.collection == 'foodEntries');
    expect(entry.included, isFalse);
    expect(entry.confidence, ExtractionConfidence.low);
    expect(entry.sourceRefs.length, 2);
  });

  test('explicit and relative dates use message context, never current date',
      () {
    final result = extract(linear());
    final yesterday = result.candidates.singleWhere((c) =>
        c.collection == 'foodEntries' &&
        c.sourceRefs.any((r) => r.contains('/m14@')));
    expect(yesterday.date, '2026-09-24');
    expect(
        yesterday.sourceRefs.single, contains('relative to message timestamp'));
    final locked =
        result.candidates.singleWhere((c) => c.collection == 'lockedDays');
    expect(locked.date, '2026-09-24');
    expect('${locked.fields['lockedAt']}', endsWith('Z'));
  });

  test('ISO offset without seconds preserves original wall date', () {
    final catalog = reader.read(
        'conversations.json',
        utf8.encode(jsonEncode([
          {
            'id': 'offset-test',
            'title': 'Synthetic',
            'messages': [
              {
                'id': 'o1',
                'role': 'user',
                'create_time': '2026-09-24T00:10+08:00',
                'content': 'Weight 99.5 kg'
              }
            ]
          }
        ])));
    final result = extract(catalog, {'offset-test': null});
    expect(result.candidates.single.date, '2026-09-24');
  });

  test(
      'later same-day measurement correction wins and withdrawn chest stays out',
      () {
    final result = extract(linear());
    final weight = result.candidates
        .where((c) =>
            c.collection == 'measurements' && c.fields['type'] == 'weight')
        .toList();
    expect(weight, hasLength(2));
    expect(weight.singleWhere((c) => c.included).fields['value'], '99.0');
    expect(weight.singleWhere((c) => !c.included).sourceRefs.length, 2);
    final chest = result.candidates
        .where((c) =>
            c.collection == 'measurements' && c.fields['type'] == 'chest')
        .toList();
    expect(chest, hasLength(1));
    expect(chest.single.included, isFalse);
  });

  test(
      'final total and calculated food remain distinct with discrepancy warning',
      () {
    final result = extract(linear());
    final day =
        result.candidates.singleWhere((c) => c.collection == 'dailyRecords');
    expect((day.fields['reportedTotal'] as Map)['calories'], '1703');
    expect(day.fields['trainingType'], 'legs');
    expect(result.candidates.where((c) => c.collection == 'lockedDays'),
        hasLength(1));
    expect(result.warnings.any((w) => w.contains('differs from reported')),
        isTrue);
  });

  test('explicit workout sets and repeated set count are not fabricated', () {
    final result = extract(linear());
    final sets =
        result.candidates.where((c) => c.collection == 'workoutSets').toList();
    expect(sets, hasLength(5));
    expect(sets.last.fields['weight'], '100');
    expect(sets.last.fields['reps'], 10);
    expect(sets.last.fields['setCount'], 2);
    expect(
        result.candidates.where(
            (c) => c.collection == 'exercises' && c.fields['name'] == 'Squat'),
        hasLength(1));
  });

  test('restaurant estimate is low confidence and excluded until review', () {
    final result = extract(linear());
    final estimate = result.candidates.singleWhere((c) =>
        c.collection == 'nutritionSnapshots' &&
        c.fields['provenance'] == 'restaurantEstimate');
    expect(estimate.confidence, ExtractionConfidence.low);
    expect(estimate.included, isFalse);
    expect(estimate.fields['calories'], '720');
    final entry = result.candidates.singleWhere((c) =>
        c.collection == 'foodEntries' &&
        c.fields['name'] == 'Restaurant Burger');
    expect(entry.fields['provenance'], 'restaurantEstimate');
  });

  test('review edits generate valid portable v1 and invalid edits are rejected',
      () {
    final result = extract(linear());
    final json = result.toPortableJson();
    final parsed = PortableImportParser().parse(json);
    expect(parsed.isValid, isTrue,
        reason: parsed.issues.map((i) => i.message).join('; '));
    expect(
        parsed.document!
            .records('foodEntries')
            .where((entry) => entry.fields['status'] == 'cancelled'),
        hasLength(1));
    final food =
        result.candidates.firstWhere((c) => c.collection == 'foodEntries');
    food.fields['quantity'] = 'NaN';
    expect(() => result.toPortableJson(),
        throwsA(isA<ChatPortableValidationException>()));
  });

  test(
      'assistant total requires user acceptance; unsupported guess is not exact',
      () {
    final catalog = reader.read(
        'conversations.json',
        utf8.encode(jsonEncode([
          {
            'id': 'synthetic-assistant',
            'title': 'Synthetic',
            'messages': [
              {
                'id': 'a1',
                'role': 'assistant',
                'create_time': '2026-09-24T20:00:00+08:00',
                'content': 'Daily total 2588 kcal P 202.9'
              },
              {
                'id': 'u1',
                'role': 'user',
                'create_time': '2026-09-24T20:01:00+08:00',
                'content': 'Yes, lock it'
              }
            ]
          }
        ])));
    final result = extract(catalog, {'synthetic-assistant': null});
    final day =
        result.candidates.singleWhere((c) => c.collection == 'dailyRecords');
    expect(
        (day.fields['reportedTotal'] as Map)['provenance'], 'finalDailyTotal');
    expect(day.sourceRefs.length, 2);
    expect(result.candidates.where((c) => c.collection == 'lockedDays'),
        hasLength(1));
  });

  test('Cyrillic and romanized aliases require explicit product identity', () {
    final catalog = reader.read(
        'conversations.json',
        utf8.encode(jsonEncode([
          {
            'id': 'alias-test',
            'title': 'Synthetic alias',
            'messages': [
              {
                'id': 'a1',
                'role': 'user',
                'create_time': '2026-09-24T08:00:00+08:00',
                'content':
                    'Nutrition label: Kirkland Whey 100g = 370 kcal P 71 C 11 F 4'
              },
              {
                'id': 'a2',
                'role': 'user',
                'create_time': '2026-09-24T08:01:00+08:00',
                'content': 'uurag / уураг → Kirkland Whey'
              },
              {
                'id': 'a3',
                'role': 'user',
                'create_time': '2026-09-24T08:02:00+08:00',
                'content': '40гр УУРАГ уусан'
              }
            ]
          }
        ])));
    final result = extract(catalog, {'alias-test': null});
    final aliases =
        result.candidates.where((c) => c.collection == 'foodAliases').toList();
    expect(
        aliases.map((c) => c.fields['alias']), containsAll(['uurag', 'уураг']));
    final entry =
        result.candidates.singleWhere((c) => c.collection == 'foodEntries');
    expect(entry.fields['savedFoodId'],
        result.candidates.singleWhere((c) => c.collection == 'savedFoods').id);
    expect(entry.fields['nutritionSnapshotId'], isNotNull);
    expect(entry.fields['quantity'], '40');
  });

  test(
      'conflicting explicit alias becomes unresolved instead of choosing a food',
      () {
    final catalog = reader.read(
        'conversations.json',
        utf8.encode(jsonEncode([
          {
            'id': 'ambiguous-alias',
            'title': 'Synthetic',
            'messages': [
              {
                'id': 'a1',
                'role': 'user',
                'create_time': '2026-09-24T08:00:00+08:00',
                'content':
                    'Nutrition label: Whey One 100g = 370 kcal P 71 C 11 F 4'
              },
              {
                'id': 'a2',
                'role': 'user',
                'create_time': '2026-09-24T08:01:00+08:00',
                'content':
                    'Nutrition label: Whey Two 100g = 360 kcal P 70 C 10 F 5'
              },
              {
                'id': 'a3',
                'role': 'user',
                'create_time': '2026-09-24T08:02:00+08:00',
                'content': 'uurag = Whey One'
              },
              {
                'id': 'a4',
                'role': 'user',
                'create_time': '2026-09-24T08:03:00+08:00',
                'content': 'uurag = Whey Two'
              },
              {
                'id': 'a5',
                'role': 'user',
                'create_time': '2026-09-24T08:04:00+08:00',
                'content': '40g uurag uusan'
              }
            ]
          }
        ])));
    final result = extract(catalog, {'ambiguous-alias': null});
    final entry =
        result.candidates.singleWhere((c) => c.collection == 'foodEntries');
    expect(entry.fields.containsKey('savedFoodId'), isFalse);
    expect(
        result.candidates
            .where((c) => c.collection == 'foodAliases' && c.included),
        isEmpty);
    expect(result.warnings.any((w) => w.contains('multiple foods')), isTrue);
  });

  test('suffix grams keep consumed fact without inventing macros', () {
    final catalog = reader.read(
        'conversations.json',
        utf8.encode(jsonEncode([
          {
            'id': 'suffix-test',
            'title': 'Synthetic',
            'messages': [
              {
                'id': 's1',
                'role': 'user',
                'create_time': '2026-09-24T08:00:00+08:00',
                'content': 'тараг 200г идлээ'
              }
            ]
          }
        ])));
    final result = extract(catalog, {'suffix-test': null});
    final entry =
        result.candidates.singleWhere((c) => c.collection == 'foodEntries');
    expect(entry.fields['status'], 'consumed');
    expect(entry.fields['quantity'], '200');
    expect(entry.fields.containsKey('nutritionSnapshotId'), isFalse);
    expect(
        PortableImportParser().parse(result.toPortableJson()).isValid, isTrue);
  });

  test('cardio retains explicit wearable metrics and warns about media', () {
    final catalog = reader.read(
        'conversations.json',
        utf8.encode(jsonEncode([
          {
            'id': 'wearable-test',
            'title': 'Synthetic',
            'messages': [
              {
                'id': 'w1',
                'role': 'user',
                'create_time': '2026-09-24T18:00:00+08:00',
                'content': {
                  'parts': [
                    'Cardio duration 30 min; active calories: 245; average heart rate: 128',
                    {'asset_pointer': 'synthetic-image-pointer'}
                  ]
                }
              }
            ]
          }
        ])));
    final result = extract(catalog, {'wearable-test': null});
    final workout =
        result.candidates.singleWhere((c) => c.collection == 'workouts');
    expect(workout.fields['durationSeconds'], '1800.0');
    expect('${workout.fields['notes']}', contains('active calories: 245'));
    expect(result.warnings.any((w) => w.contains('no OCR')), isTrue);
  });

  test('measurements on different dates stay separate and missing date skips',
      () {
    final catalog = reader.read(
        'conversations.json',
        utf8.encode(jsonEncode([
          {
            'id': 'dates-test',
            'title': 'Synthetic',
            'messages': [
              {
                'id': 'd1',
                'role': 'user',
                'create_time': '2026-09-24T08:00:00+08:00',
                'content': 'Weight 99.5 kg'
              },
              {
                'id': 'd2',
                'role': 'user',
                'create_time': '2026-09-25T08:00:00+08:00',
                'content': 'Weight 99.0 kg'
              },
              {'id': 'd3', 'role': 'user', 'content': 'Weight 98.0 kg'}
            ]
          }
        ])));
    final result = extract(catalog, {'dates-test': null});
    final weights =
        result.candidates.where((c) => c.collection == 'measurements').toList();
    expect(
        weights.map((c) => c.date), containsAll(['2026-09-24', '2026-09-25']));
    expect(weights.where((c) => c.included), hasLength(2));
    expect(result.warnings.any((w) => w.contains('no explicit date')), isTrue);
  });

  test('body fat and limb measurements keep their supported types and units',
      () {
    final catalog = reader.read(
        'conversations.json',
        utf8.encode(jsonEncode([
          {
            'id': 'measure-types',
            'title': 'Synthetic',
            'messages': [
              {
                'id': 'm1',
                'role': 'user',
                'create_time': '2026-09-24T08:00:00+08:00',
                'content':
                    'Body fat 21.3%, Neck 42 cm, Left bicep 38.5 cm, Abdomen 101 cm, Lower Belly 103 cm'
              }
            ]
          }
        ])));
    final result = extract(catalog, {'measure-types': null});
    final measures =
        result.candidates.where((c) => c.collection == 'measurements').toList();
    expect(
        measures.map((m) => m.fields['type']),
        containsAll(
            ['fat_percent', 'neck', 'left_bicep', 'abdomen', 'lower_belly']));
    expect(
        measures
            .singleWhere((m) => m.fields['type'] == 'fat_percent')
            .fields['unit'],
        '%');
    expect(
        PortableImportParser().parse(result.toPortableJson()).isValid, isTrue);
  });

  test('unsupported assistant guess alone creates no confirmed record', () {
    final catalog = reader.read(
        'conversations.json',
        utf8.encode(jsonEncode([
          {
            'id': 'guess-test',
            'title': 'Synthetic',
            'messages': [
              {
                'id': 'g1',
                'role': 'assistant',
                'create_time': '2026-09-24T12:00:00+08:00',
                'content': 'You probably ate around 900 kcal.'
              }
            ]
          }
        ])));
    expect(extract(catalog, {'guess-test': null}).candidates, isEmpty);
  });

  test('assistant total is not accepted by an unrelated later yes', () {
    final catalog = reader.read(
        'conversations.json',
        utf8.encode(jsonEncode([
          {
            'id': 'stale-assistant',
            'title': 'Synthetic',
            'messages': [
              {
                'id': 'a1',
                'role': 'assistant',
                'create_time': '2026-09-24T12:00:00+08:00',
                'content': 'Daily total 900 kcal P 50'
              },
              {
                'id': 'u1',
                'role': 'user',
                'create_time': '2026-09-24T12:01:00+08:00',
                'content': 'Weight 99.5 kg'
              },
              {
                'id': 'u2',
                'role': 'user',
                'create_time': '2026-09-24T12:02:00+08:00',
                'content': 'Yes'
              }
            ]
          }
        ])));
    final result = extract(catalog, {'stale-assistant': null});
    expect(result.candidates.where((c) => c.collection == 'dailyRecords'),
        isEmpty);
    expect(
        result.candidates.where((c) => c.collection == 'lockedDays'), isEmpty);
  });

  test('adapter and portable generation never mutate the live database',
      () async {
    final db = AppDatabase(NativeDatabase.memory());
    try {
      final before = await db
          .customSelect('SELECT COUNT(*) AS n FROM nutrition_logs')
          .getSingle();
      final result = extract(linear());
      expect(PortableImportParser().parse(result.toPortableJson()).isValid,
          isTrue);
      final after = await db
          .customSelect('SELECT COUNT(*) AS n FROM nutrition_logs')
          .getSingle();
      expect(after.read<int>('n'), before.read<int>('n'));
      final batches = await db
          .customSelect('SELECT COUNT(*) AS n FROM historical_import_batches')
          .getSingle();
      expect(batches.read<int>('n'), 0);
    } finally {
      await db.close();
    }
  });

  testWidgets('adapter starts with explicit file and conversation selection',
      (tester) async {
    await tester
        .pumpWidget(const MaterialApp(home: ChatGptExportAdapterScreen()));
    expect(find.textContaining('Select ChatGPT ZIP'), findsOneWidget);
    expect(find.text('Generate and validate portable JSON v1'), findsNothing);
  });

  testWidgets('portable generation requires explicit extraction review',
      (tester) async {
    final catalog = reader.read(
        'conversations.json',
        utf8.encode(jsonEncode([
          {
            'id': 'review-chat',
            'title': 'Synthetic review chat',
            'messages': [
              {
                'id': 'weight-message',
                'role': 'user',
                'create_time': '2026-09-24T08:00:00+08:00',
                'content': 'Weight 99.5 kg'
              }
            ]
          }
        ])));
    final extraction =
        ChatFitnessAdapter().extract(catalog, {'review-chat': null});
    await tester.pumpWidget(MaterialApp(
        home: ChatGptExportAdapterScreen(
            initialCatalog: catalog, initialExtraction: extraction)));
    final generate = find.widgetWithText(
        FilledButton, 'Generate and validate portable JSON v1');
    await tester.scrollUntilVisible(generate, 300,
        scrollable: find.byType(Scrollable).first);
    expect(tester.widget<FilledButton>(generate).onPressed, isNull);
    final acknowledgement =
        find.text('I reviewed the extracted records and warnings');
    await tester.scrollUntilVisible(acknowledgement, -200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(acknowledgement);
    await tester.pump();
    expect(tester.widget<FilledButton>(generate).onPressed, isNotNull);
    final day = find.text('2026-09-24 (1)');
    await tester.scrollUntilVisible(day, -200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(day);
    await tester.pumpAndSettle();
    final measurement = extraction.candidates.single;
    final valueField = find.byKey(ValueKey('${measurement.id}-value'));
    await tester.ensureVisible(valueField);
    await tester.enterText(valueField, '99.0');
    await tester.pump();
    expect(tester.widget<FilledButton>(generate).onPressed, isNull);
  });

  testWidgets(
      'validated adapter output enters Phase 3B preview without a write',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    try {
      final json = extract(linear()).toPortableJson();
      await tester.pumpWidget(MaterialApp(
          home: HistoricalImportScreen(
        service: HistoricalImportService(db),
        initialJson: json,
      )));
      await tester.pumpAndSettle();
      expect(find.textContaining('Preview ·'), findsOneWidget);
      final row = await db
          .customSelect('SELECT COUNT(*) AS n FROM historical_import_batches')
          .getSingle();
      expect(row.read<int>('n'), 0);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await db.close();
    }
  });
}
