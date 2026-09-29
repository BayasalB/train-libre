import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:train_libre/data/database_helper.dart';
import 'package:train_libre/data/drift_database.dart';
import 'package:train_libre/features/diary/data/local_smart_food_log.dart';
import 'package:train_libre/features/diary/data/smart_log_ai_fallback.dart';
import 'package:train_libre/features/diary/data/smart_log_ai_provider.dart';
import 'package:train_libre/features/diary/data/sources/food_alias_local_data_source.dart';
import 'package:train_libre/features/diary/data/sources/product_local_data_source.dart';
import 'package:train_libre/features/diary/domain/models/food_alias.dart';
import 'package:train_libre/features/diary/domain/models/food_item.dart';
import 'package:train_libre/features/diary/domain/models/saved_food_metadata.dart';
import 'package:train_libre/features/diary/domain/models/smart_log_ai_models.dart';
import 'package:train_libre/features/diary/domain/use_cases/parse_local_food_log.dart';
import 'package:train_libre/features/diary/presentation/local_smart_log_screen.dart';
import 'package:train_libre/features/today/data/day_lock_repository.dart';
import 'package:train_libre/services/ai_service.dart';

class MemoryAiKeys extends FlutterSecureStorage {
  final Map<String, String> values = {};
  @override
  Future<String?> read(
          {required String key,
          AppleOptions? iOptions,
          AndroidOptions? aOptions,
          LinuxOptions? lOptions,
          WebOptions? webOptions,
          AppleOptions? mOptions,
          WindowsOptions? wOptions}) async =>
      values[key];
  @override
  Future<void> write(
      {required String key,
      required String? value,
      AppleOptions? iOptions,
      AndroidOptions? aOptions,
      LinuxOptions? lOptions,
      WebOptions? webOptions,
      AppleOptions? mOptions,
      WindowsOptions? wOptions}) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }
}

class FakeSmartLogProvider implements SmartLogAiProvider {
  int calls = 0;
  bool configured = true;
  Future<String> Function(SmartLogAiRequest)? answer;
  SmartLogAiRequest? lastRequest;
  @override
  Future<bool> isConfigured() async => configured;
  @override
  Future<String> interpret(SmartLogAiRequest request) async {
    calls++;
    lastRequest = request;
    if (answer != null) return answer!(request);
    return response(request);
  }
}

String response(
  SmartLogAiRequest request, {
  String name = 'Unknown snack',
  String? quantity = '50',
  String unit = 'g',
  String action = 'consumed',
  String? ref,
  Map<String, Object?>? estimate,
  double confidence = 0.7,
  List<String> warnings = const [],
}) =>
    jsonEncode({
      'formatVersion': 1,
      'items': [
        {
          'sourceCandidateId': request.spans.single.id,
          'sourceText': request.spans.single.text,
          'interpretedFoodName': name,
          'quantity': quantity,
          'unit': unit,
          'actionState': action,
          'suggestedLocalFoodReference': ref,
          'nutritionEstimate': estimate,
          'confidence': confidence,
          'warnings': warnings,
        }
      ],
    });

const estimate = <String, Object?>{
  'caloriesPer100': '288.97',
  'proteinPer100': '15.65',
  'carbsPer100': '11.85',
  'fatPer100': '19.89',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late LocalSmartFoodLog local;
  late ProductLocalDataSource products;
  late FoodAliasLocalDataSource aliases;
  late FakeSmartLogProvider fake;
  late SmartLogAiFallback fallback;
  final day = DateTime(2026, 9, 25, 12);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    DatabaseHelper.setDriftDb(db);
    products = ProductLocalDataSource.forTesting(db);
    aliases = FoodAliasLocalDataSource(db);
    local = LocalSmartFoodLog(db, products: products);
    fake = FakeSmartLogProvider();
    fallback = SmartLogAiFallback(local, fake);
    await products.insertProduct(FoodItem(
      barcode: 'whey',
      name: 'Kirkland Whey',
      calories: 288.97,
      protein: 15.65,
      carbs: 11.85,
      fat: 19.89,
      metadata: SavedFoodMetadata(
          source: NutritionSource.label,
          verified: true,
          verifiedAt: DateTime.utc(2026, 9, 1)),
    ));
    await aliases.save('whey', const FoodAliasDraft(alias: 'uurag'));
    await aliases.save('whey', const FoodAliasDraft(alias: 'уураг'));
  });
  tearDown(() async => db.close());

  test('existing provider configuration gates fallback without an API call',
      () async {
    final keys = MemoryAiKeys();
    final service = AiService.forTesting(secureStorage: keys);
    final provider = ConfiguredSmartLogAiProvider(ai: service);
    expect(await provider.isConfigured(), isFalse);
    await service.setApiKey(AiProvider.openai, 'test-only-key');
    expect(await provider.isConfigured(), isTrue);
    await service.setSelectedProvider(AiProvider.custom);
    await service.setCustomBaseUrl('http://insecure.example');
    expect(await provider.isConfigured(), isFalse);
    await service.setCustomBaseUrl('https://secure.example');
    expect(await provider.isConfigured(), isTrue);
    expect(fake.calls, 0);
  });

  test('resolved aliases do not call AI even when fallback is invoked',
      () async {
    final c = await local.preview('41g uurag, 80g уураг');
    expect(c.every((item) => item.canLog), isTrue);
    expect(fallback.canOffer(c), isFalse);
    expect((await fallback.interpret(c, allowEstimate: false)).suggestions,
        isEmpty);
    expect(fake.calls, 0);
  });

  test('unknown text invokes AI with minimal unresolved context', () async {
    final c = await local.preview('unknown snack 50g');
    final result = await fallback.interpret(c, allowEstimate: false);
    expect(fake.calls, 1);
    expect(result.suggestions.single.interpretation.quantity, 50);
    expect(fake.lastRequest!.spans.single.text, 'unknown snack 50g');
    expect(fake.lastRequest!.foods.length, lessThanOrEqualTo(8));
    expect(jsonEncode(fake.lastRequest!.toJson()), isNot(contains('288.97')));
    expect(
        await db.customSelect('SELECT * FROM nutrition_logs').get(), isEmpty);
  });

  test('ambiguous local alias stays ambiguous and cannot invoke AI alone',
      () async {
    await products.insertProduct(FoodItem(
        barcode: 'other',
        name: 'Other Whey',
        calories: 100,
        protein: 10,
        carbs: 10,
        fat: 1));
    await aliases.save('other', const FoodAliasDraft(alias: 'uurag'));
    final c = await local.preview('41g uurag');
    expect(c.single.resolution, LocalFoodResolution.ambiguous);
    expect(fallback.canOffer(c), isFalse);
    await fallback.interpret(c, allowEstimate: true);
    expect(fake.calls, 0);
  });

  test('returned candidate ID must be one of request-scoped options', () async {
    final c = await local.preview('uura 41g');
    fake.answer =
        (req) async => response(req, ref: 'invented-id', quantity: '41');
    await expectLater(fallback.interpret(c, allowEstimate: false),
        throwsA(isA<SmartLogAiValidationException>()));
    expect(
        await db.customSelect('SELECT * FROM nutrition_logs').get(), isEmpty);
  });

  test('valid local suggestion does not select or replace verified nutrition',
      () async {
    final c = await local.preview('uura 41g');
    fake.answer = (req) async => response(req,
        name: 'Kirkland Whey', quantity: '41', ref: req.foods.first.id);
    final result = await fallback.interpret(c, allowEstimate: false);
    final suggestion = result.suggestions.single;
    expect(suggestion.suggestedFood?.barcode, 'whey');
    expect(suggestion.suggestedFood?.calories, 288.97);
    expect(c.single.food, isNull);
    final linked = c.single.copyWith(matches: [suggestion.suggestedFood!]);
    expect(linked.nutrition!.calories, closeTo(118.4777, 1e-8));
    final ids = await fallback.confirm(
        reviewId: 'local1',
        candidates: [linked],
        acceptedEstimates: {},
        date: day,
        mealType: 'mealtypeSnack');
    expect(ids, hasLength(1));
    final archive = await db
        .customSelect(
            'SELECT nutrition_source, calories FROM off_products_archive')
        .getSingle();
    expect(archive.read<String>('nutrition_source'), 'label');
    expect(archive.read<double>('calories'), 288.97);
  });

  test('estimate cannot accompany a Saved Food reference', () async {
    final c = await local.preview('uura 41g');
    fake.answer = (req) async => response(req,
        name: 'Kirkland Whey',
        quantity: '41',
        ref: req.foods.first.id,
        estimate: estimate);
    await expectLater(fallback.interpret(c, allowEstimate: true),
        throwsA(isA<SmartLogAiValidationException>()));
  });

  test('AI estimate cannot replace an exact local Saved Food by name',
      () async {
    final c = await local.preview('unknown snack 50g');
    final req = SmartLogAiRequest(
        [SmartLogAiSpan('u0', c.single.rawSpan)], const [],
        allowEstimate: true);
    final item = SmartLogAiResponse.parse(
            response(req, name: 'Kirkland Whey', estimate: estimate), req)
        .items
        .single;
    await expectLater(fallback.estimateFood(item), throwsStateError);
    expect(
        await db.customSelect('SELECT * FROM nutrition_logs').get(), isEmpty);
  });

  test('strict schema rejects malformed, extra fields and invented quantity',
      () async {
    final c = await local.preview('uurgaa say uuchlaa');
    final req = SmartLogAiRequest(
        [SmartLogAiSpan('u0', c.single.rawSpan)], const [],
        allowEstimate: false);
    for (final raw in [
      'not json',
      '{"formatVersion":2,"items":[]}',
      jsonEncode({
        ...jsonDecode(response(req)) as Map<String, dynamic>,
        'extra': true
      }),
      response(req, quantity: '41'),
      response(req, estimate: estimate),
      response(req, confidence: 1.2),
      response(req, quantity: 'NaN'),
    ]) {
      expect(() => SmartLogAiResponse.parse(raw, req),
          throwsA(isA<SmartLogAiValidationException>()));
    }
    expect(
        SmartLogAiResponse.parse(
                response(req, quantity: null, unit: 'unknown'), req)
            .items
            .single
            .quantity,
        isNull);
  });

  test('Cyrillic, Romanized and mixed text retain source and uncertainty',
      () async {
    for (final text in [
      'тараг 200g uusan',
      'uurgaa say uuchlaa',
      '3 shirheg undug sharaad idsen'
    ]) {
      final c = await local.preview(text);
      fake.answer = (req) async => response(req,
          name: 'Food interpretation',
          quantity: text.startsWith('3')
              ? '3'
              : text.contains('200')
                  ? '200'
                  : null,
          unit: text.startsWith('3')
              ? 'piece'
              : text.contains('200')
                  ? 'g'
                  : 'unknown',
          confidence: 0.4,
          warnings: const ['Review quantity']);
      final result = await fallback.interpret(c, allowEstimate: false);
      expect(result.suggestions.single.interpretation.sourceText, text);
      expect(result.suggestions.single.interpretation.warnings,
          contains('Review quantity'));
    }
    expect(fake.calls, 3);
  });

  test('failure and explicit retry do not mutate DB', () async {
    final c = await local.preview('unknown snack 50g');
    var attempt = 0;
    fake.answer = (req) async {
      attempt++;
      if (attempt == 1) throw const SmartLogAiUnavailable('offline');
      return response(req);
    };
    await expectLater(fallback.interpret(c, allowEstimate: false),
        throwsA(isA<SmartLogAiUnavailable>()));
    expect(fake.calls, 1);
    final result = await fallback.interpret(c, allowEstimate: false);
    expect(result.suggestions, hasLength(1));
    expect(fake.calls, 2);
    expect(
        await db.customSelect('SELECT * FROM nutrition_logs').get(), isEmpty);
  });

  test('timeout, offline, auth and quota errors leave local logging usable',
      () async {
    final c = await local.preview('unknown snack 50g');
    for (final error in [
      TimeoutException('timeout'),
      const SmartLogAiUnavailable('offline'),
      const SmartLogAiUnavailable('authentication failed'),
      const SmartLogAiUnavailable('rate limit'),
    ]) {
      fake.answer = (_) => Future.error(error);
      await expectLater(
          fallback.interpret(c, allowEstimate: false), throwsA(anything));
    }
    final matched = await local.preview('41g uurag');
    final ids = await fallback.confirm(
        reviewId: 'offline-local',
        candidates: matched,
        acceptedEstimates: {},
        date: day,
        mealType: 'mealtypeSnack');
    expect(ids, hasLength(1));
    expect(fake.calls, 4);
  });

  test(
      'estimate is created only on Confirm, records provenance, and cannot duplicate',
      () async {
    final c = await local.preview('unknown snack 50g');
    fake.answer =
        (req) async => response(req, quantity: '50', estimate: estimate);
    final result = await fallback.interpret(c, allowEstimate: true);
    final ai = result.suggestions.single.interpretation;
    final food = await fallback.estimateFood(ai);
    expect(food.nutritionSource, NutritionSource.estimate);
    expect(food.metadata.verified, isFalse);
    expect(await products.getProductByBarcode(food.barcode), isNull);
    final selected = c.single.copyWith(matches: [food]);
    final ids = await fallback.confirm(
        reviewId: 'estimate-review',
        candidates: [selected],
        acceptedEstimates: {food.barcode: food},
        date: day,
        mealType: 'mealtypeSnack');
    expect(ids, hasLength(1));
    final archive = await db
        .customSelect(
            'SELECT nutrition_source, calories FROM off_products_archive')
        .getSingle();
    expect(archive.read<String>('nutrition_source'), 'estimate');
    expect(archive.read<double>('calories'), 288.97);
    await products.updateProduct(FoodItem(
      barcode: food.barcode,
      name: food.name,
      calories: 400,
      protein: 20,
      carbs: 20,
      fat: 20,
      metadata: const SavedFoodMetadata(source: NutritionSource.manual),
    ));
    final historical = await db
        .customSelect(
            'SELECT nutrition_source, calories FROM off_products_archive')
        .getSingle();
    expect(historical.read<String>('nutrition_source'), 'estimate');
    expect(historical.read<double>('calories'), 288.97);
    await expectLater(
        fallback.confirm(
            reviewId: 'estimate-review',
            candidates: [selected],
            acceptedEstimates: {food.barcode: food},
            date: day,
            mealType: 'mealtypeSnack'),
        throwsStateError);
    expect(await db.customSelect('SELECT * FROM nutrition_logs').get(),
        hasLength(1));
  });

  test('locked day rejects estimated write and rolls back new Saved Food',
      () async {
    final c = await local.preview('unknown snack 50g');
    final req = SmartLogAiRequest(
        [SmartLogAiSpan('u0', c.single.rawSpan)], const [],
        allowEstimate: true);
    final item =
        SmartLogAiResponse.parse(response(req, estimate: estimate), req)
            .items
            .single;
    final food = await fallback.estimateFood(item);
    await DayLockRepository(db).lock(day);
    await expectLater(
        fallback.confirm(
            reviewId: 'locked',
            candidates: [
              c.single.copyWith(matches: [food])
            ],
            acceptedEstimates: {food.barcode: food},
            date: day,
            mealType: 'mealtypeSnack'),
        throwsA(isA<DayLockedException>()));
    expect(await products.getProductByBarcode(food.barcode), isNull);
    expect(
        await db.customSelect('SELECT * FROM nutrition_logs').get(), isEmpty);
  });

  testWidgets('cancel network disclosure sends nothing and preserves text',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(MaterialApp(
        home: LocalSmartLogScreen(service: local, aiFallback: fallback)));
    await tester.enterText(find.byType(TextField).first, 'unknown snack 50g');
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Try AI for unresolved items'));
    await tester.pumpAndSettle();
    expect(find.text('Use optional AI?'), findsOneWidget);
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(fake.calls, 0);
    expect(find.text('unknown snack 50g'), findsWidgets);
    expect(
        await db.customSelect('SELECT * FROM nutrition_logs').get(), isEmpty);
  });

  testWidgets('AI failure retains typed input and local preview',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    fake.answer = (_) async => throw const SmartLogAiUnavailable('offline');
    await tester.pumpWidget(MaterialApp(
        home: LocalSmartLogScreen(service: local, aiFallback: fallback)));
    await tester.enterText(find.byType(TextField).first, 'unknown snack 50g');
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Try AI for unresolved items'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Try AI').last);
    await tester.pumpAndSettle();
    expect(fake.calls, 1);
    expect(find.textContaining('offline'), findsOneWidget);
    expect(find.text('unknown snack 50g'), findsWidgets);
    expect(
        await db.customSelect('SELECT * FROM nutrition_logs').get(), isEmpty);
  });

  testWidgets('splitting an AI span does not copy one quantity to all foods',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    fake.answer = (req) async => jsonEncode({
          'formatVersion': 1,
          'items': [
            for (final (name, amount) in [
              ('First snack', '50'),
              ('Second snack', null)
            ])
              {
                'sourceCandidateId': req.spans.single.id,
                'sourceText': req.spans.single.text,
                'interpretedFoodName': name,
                'quantity': amount,
                'unit': 'g',
                'actionState': 'consumed',
                'suggestedLocalFoodReference': null,
                'nutritionEstimate': null,
                'confidence': 0.5,
                'warnings': [],
              },
          ],
        });
    await tester.pumpWidget(MaterialApp(
        home: LocalSmartLogScreen(service: local, aiFallback: fallback)));
    await tester.enterText(find.byType(TextField).first, '50g unknown snack');
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Try AI for unresolved items'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Try AI').last);
    await tester.pumpAndSettle();
    expect(find.text('First snack'), findsOneWidget);
    expect(find.text('Second snack'), findsOneWidget);
    expect(find.textContaining('Quantity missing'), findsWidgets);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm'))
            .onPressed,
        isNull);
  });

  testWidgets('AI cannot silently convert locally planned food to consumed',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    fake.answer = (req) async => response(req,
        quantity: '40', action: 'consumed', name: 'Unknown snack');
    await tester.pumpWidget(MaterialApp(
        home: LocalSmartLogScreen(service: local, aiFallback: fallback)));
    await tester.enterText(
        find.byType(TextField).first, '40g unknown snack beldsen');
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Try AI for unresolved items'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Try AI').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('planned'), findsWidgets);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm'))
            .onPressed,
        isNull);
    expect(
        await db.customSelect('SELECT * FROM nutrition_logs').get(), isEmpty);
  });

  testWidgets('explicit estimate choice and Confirm write an estimate snapshot',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    fake.answer = (req) async {
      expect(req.allowEstimate, isTrue);
      return response(req, quantity: '50', estimate: estimate);
    };
    await tester.pumpWidget(MaterialApp(
        home: LocalSmartLogScreen(
            service: local, aiFallback: fallback, initialDate: day)));
    await tester.enterText(find.byType(TextField).first, 'unknown snack 50g');
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Try AI for unresolved items'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Try AI').last);
    await tester.pumpAndSettle();
    expect(
        await db.customSelect('SELECT * FROM nutrition_logs').get(), isEmpty);
    await tester.tap(find.text('Use AI_ESTIMATE (approximate)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('AI_ESTIMATE · approximate'), findsOneWidget);
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(await db.customSelect('SELECT * FROM nutrition_logs').get(),
        hasLength(1));
    final archive = await db
        .customSelect('SELECT nutrition_source FROM off_products_archive')
        .getSingle();
    expect(archive.read<String>('nutrition_source'), 'estimate');
  });
}
