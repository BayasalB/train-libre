import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:train_libre/data/database_helper.dart';
import 'package:train_libre/data/drift_database.dart' show AppDatabase;
import 'package:train_libre/features/diary/data/local_smart_food_log.dart';
import 'package:train_libre/features/diary/data/smart_log_ai_fallback.dart';
import 'package:train_libre/features/diary/data/smart_log_ai_provider.dart';
import 'package:train_libre/features/diary/data/smart_log_photo_adapter.dart';
import 'package:train_libre/features/diary/data/sources/food_alias_local_data_source.dart';
import 'package:train_libre/features/diary/data/sources/product_local_data_source.dart';
import 'package:train_libre/features/diary/domain/models/food_alias.dart';
import 'package:train_libre/features/diary/domain/models/food_item.dart';
import 'package:train_libre/features/diary/domain/models/meal_entry.dart';
import 'package:train_libre/features/diary/domain/models/saved_food_metadata.dart';
import 'package:train_libre/features/diary/domain/models/smart_log_ai_models.dart';
import 'package:train_libre/features/diary/domain/models/smart_log_review.dart';
import 'package:train_libre/features/diary/domain/use_cases/parse_local_food_log.dart';
import 'package:train_libre/features/diary/presentation/local_smart_log_screen.dart';
import 'package:train_libre/features/today/data/day_lock_repository.dart';
import 'package:train_libre/services/ai_meal_validation.dart';

class _NoNetworkAi implements SmartLogAiProvider {
  int calls = 0;
  @override
  Future<bool> isConfigured() async => true;
  @override
  Future<String> interpret(SmartLogAiRequest request) async {
    calls++;
    throw StateError('No network call expected');
  }
}

// Kept separate from the actual provider: the photo pipeline is already
// represented by an AiMealCandidate and never needs a paid request in tests.
AiMealCandidate _photo(String name, double grams, {double? confidence}) =>
    AiMealCandidate(items: [
      AiMealCandidateItem(name: name, grams: grams, confidence: confidence),
    ]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late ProductLocalDataSource products;
  late LocalSmartFoodLog local;
  late _NoNetworkAi ai;
  late SmartLogAiFallback fallback;
  final day = DateTime(2026, 9, 25, 12);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    DatabaseHelper.setDriftDb(db);
    products = ProductLocalDataSource.forTesting(db);
    local = LocalSmartFoodLog(db, products: products);
    ai = _NoNetworkAi();
    fallback = SmartLogAiFallback(local, ai);
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
        verifiedAt: DateTime.utc(2026, 9, 1),
      ),
    ));
    await FoodAliasLocalDataSource(db)
        .save('whey', const FoodAliasDraft(alias: 'uurag'));
  });
  tearDown(() async => db.close());

  test('text and voice share local candidate and consumed-only totals',
      () async {
    final candidate = (await local.preview('41g uurag')).single;
    final voice = SmartLogReviewItem(
      candidate: candidate,
      source: SmartLogInputSource.voice,
      sourceDescription: '41g uurag',
    );
    final planned = (await local.preview('40g uurag beldsen')).single;
    final cancelled = (await local.preview('40g uurag boliloo')).single;
    final unknown = (await local.preview('unknown snack 50g')).single;
    final summary = SmartLogReviewSummary([
      voice,
      SmartLogReviewItem(
          candidate: planned,
          source: SmartLogInputSource.text,
          sourceDescription: planned.rawSpan),
      SmartLogReviewItem(
          candidate: cancelled,
          source: SmartLogInputSource.text,
          sourceDescription: cancelled.rawSpan),
      SmartLogReviewItem(
          candidate: unknown,
          source: SmartLogInputSource.text,
          sourceDescription: unknown.rawSpan,
          included: false),
    ]);
    expect(summary.canConfirm, isTrue);
    expect(summary.consumed, hasLength(1));
    expect(summary.totals.calories, closeTo(118.4777, 0.00001));
    expect(ai.calls, 0);
    final blocked = SmartLogReviewSummary([
      voice,
      SmartLogReviewItem(
          candidate: unknown,
          source: SmartLogInputSource.text,
          sourceDescription: unknown.rawSpan),
    ]);
    expect(blocked.canConfirm, isFalse);
    expect(blocked.totals.calories, summary.totals.calories);
  });

  test('photo suggestion waits for explicit local link and uses exact label',
      () async {
    final review = await SmartLogPhotoAdapter(local)
        .review(_photo('Kirkland Whey', 41, confidence: 0.6));
    expect(review.single.source, SmartLogInputSource.photo);
    expect(review.single.candidate.food, isNull);
    expect(review.single.suggestedFoods.single.barcode, 'whey');
    expect(review.single.sourceWarnings.join(), contains('estimate'));
    expect(SmartLogReviewSummary(review).canConfirm, isFalse);
    expect(
        await db.customSelect('SELECT * FROM nutrition_logs').get(), isEmpty);

    final linked = review.single.copyWith(
        candidate: review.single.candidate
            .copyWith(matches: review.single.suggestedFoods));
    expect(linked.candidate.nutrition!.calories, closeTo(118.4777, 0.00001));
    await fallback.confirm(
      reviewId: 'photo-review',
      candidates: [linked.candidate],
      acceptedEstimates: {},
      date: day,
      mealType: 'mealtypeSnack',
    );
    expect(ai.calls, 0);
    final archive = await db
        .customSelect(
            'SELECT nutrition_source, calories FROM off_products_archive')
        .getSingle();
    expect(archive.read<String>('nutrition_source'), 'label');
    expect(archive.read<double>('calories'), 288.97);
  });

  test('photo unknown, ambiguous and malformed results remain safe', () async {
    final adapter = SmartLogPhotoAdapter(local);
    final unknown = await adapter.review(_photo('Unknown burger', 293.8));
    expect(unknown.single.candidate.food, isNull);
    expect(unknown.single.candidate.quantity, 293.8);
    expect(fallback.canOffer([unknown.single.candidate]), isTrue);
    expect(SmartLogReviewSummary(unknown).canConfirm, isFalse);
    await products.insertProduct(FoodItem(
        barcode: 'second',
        name: 'Second Whey',
        calories: 300,
        protein: 70,
        carbs: 8,
        fat: 3));
    await FoodAliasLocalDataSource(db)
        .save('second', const FoodAliasDraft(alias: 'uurag'));
    final ambiguous = await adapter.review(_photo('uurag', 45.5));
    expect(
        ambiguous.single.candidate.resolution, LocalFoodResolution.ambiguous);
    expect(fallback.canOffer([ambiguous.single.candidate]), isFalse);
    await expectLater(
        adapter.review(_photo('Bad', double.nan)), throwsFormatException);
    await expectLater(adapter.review(_photo('Bad', 30, confidence: 1.5)),
        throwsFormatException);
    expect(
        await db.customSelect('SELECT * FROM nutrition_logs').get(), isEmpty);
  });

  test('photo link respects stale preview and Day Lock', () async {
    final item = (await SmartLogPhotoAdapter(local)
            .review(_photo('Kirkland Whey', 45.5)))
        .single;
    final linked = item.candidate.copyWith(matches: item.suggestedFoods);
    await products.updateProduct(FoodItem(
      barcode: 'whey',
      name: 'Kirkland Whey',
      calories: 400,
      protein: 20,
      carbs: 20,
      fat: 20,
      metadata: const SavedFoodMetadata(source: NutritionSource.manual),
    ));
    await expectLater(
        fallback.confirm(
            reviewId: 'stale-photo',
            candidates: [linked],
            acceptedEstimates: {},
            date: day,
            mealType: 'mealtypeSnack'),
        throwsStateError);
    await DayLockRepository(db).lock(day);
    await expectLater(
        fallback.confirm(
            reviewId: 'locked-photo',
            candidates: [linked],
            acceptedEstimates: {},
            date: day,
            mealType: 'mealtypeSnack'),
        throwsA(isA<DayLockedException>()));
    expect(
        await db.customSelect('SELECT * FROM nutrition_logs').get(), isEmpty);
  });

  test(
      'rich meal metadata and reviewed foods save in one protected transaction',
      () async {
    final candidate = (await local.preview('41g uurag')).single;
    final meal = MealEntry(
      id: 'meal-photo-1',
      consumedAt: day,
      mealType: 'mealtypeSnack',
      source: 'aiPhoto',
      title: 'Whey drink',
    );
    await local.confirm([candidate],
        date: day, mealType: 'mealtypeSnack', mealEntry: meal);
    final logs =
        await db.customSelect('SELECT meal_entry_id FROM nutrition_logs').get();
    expect(logs.single.read<String>('meal_entry_id'), meal.id);
    expect(await db.customSelect('SELECT * FROM meal_entries').get(),
        hasLength(1));
  });

  test('stale rich meal review rolls back its meal row too', () async {
    final candidate = (await local.preview('41g uurag')).single;
    await products.updateProduct(FoodItem(
      barcode: 'whey',
      name: 'Kirkland Whey',
      calories: 400,
      protein: 20,
      carbs: 20,
      fat: 20,
    ));
    await expectLater(
        local.confirm([candidate],
            date: day,
            mealType: 'mealtypeSnack',
            mealEntry: MealEntry(
              id: 'stale-rich-meal',
              consumedAt: day,
              mealType: 'mealtypeSnack',
              source: 'aiPhoto',
            )),
        throwsStateError);
    expect(await db.customSelect('SELECT * FROM meal_entries').get(), isEmpty);
    expect(
        await db.customSelect('SELECT * FROM nutrition_logs').get(), isEmpty);
  });

  test('name-only Saved Food edit also invalidates unified preview', () async {
    final candidate = (await local.preview('41g uurag')).single;
    await products.updateProduct(FoodItem(
      barcode: 'whey',
      name: 'Renamed Kirkland Whey',
      calories: 288.97,
      protein: 15.65,
      carbs: 11.85,
      fat: 19.89,
      metadata: SavedFoodMetadata(
        source: NutritionSource.label,
        verified: true,
        verifiedAt: DateTime.utc(2026, 9, 1),
      ),
    ));
    await expectLater(
        local.confirm([candidate], date: day, mealType: 'mealtypeSnack'),
        throwsStateError);
    expect(
        await db.customSelect('SELECT * FROM nutrition_logs').get(), isEmpty);
  });

  testWidgets('voice transcript is editable before any Confirm',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home: LocalSmartLogScreen(
      service: local,
      aiFallback: fallback,
      voiceTranscriptForTesting: (_) async => '41g uurag',
    )));
    await tester.tap(find.text('Voice'));
    await tester.pumpAndSettle();
    expect(find.text('Kirkland Whey'), findsOneWidget);
    expect(find.text('VOICE'), findsOneWidget);
    expect(
        await db.customSelect('SELECT * FROM nutrition_logs').get(), isEmpty);
    await tester.enterText(find.byType(TextField).first, '45.5g uurag');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    expect(find.textContaining('45.5'), findsWidgets);
    expect(
        await db.customSelect('SELECT * FROM nutrition_logs').get(), isEmpty);
    await tester.ensureVisible(find.text('Cancel'));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(
        await db.customSelect('SELECT * FROM nutrition_logs').get(), isEmpty);
  });

  testWidgets('photo capture returns to unified review without a diary write',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home: LocalSmartLogScreen(
      service: local,
      aiFallback: fallback,
      photoCaptureForTesting: (_) async => _photo('Kirkland Whey', 41),
    )));
    await tester.tap(find.text('Photo'));
    await tester.pumpAndSettle();
    expect(find.text('Analyze a meal photo?'), findsOneWidget);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('PHOTO'), findsOneWidget);
    expect(find.textContaining('Photo portion is an estimate'), findsOneWidget);
    expect(
        await db.customSelect('SELECT * FROM nutrition_logs').get(), isEmpty);
    await tester.ensureVisible(find.textContaining('Link local Saved Food'));
    await tester.tap(find.textContaining('Link local Saved Food'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Verified local Saved Food nutrition'),
        findsOneWidget);
    await tester.ensureVisible(find.text('Confirm'));
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(await db.customSelect('SELECT * FROM nutrition_logs').get(),
        hasLength(1));
    expect(ai.calls, 0);
  });

  testWidgets('cancel photo disclosure keeps local logging intact',
      (tester) async {
    var captureCalls = 0;
    await tester.pumpWidget(MaterialApp(
        home: LocalSmartLogScreen(
      service: local,
      aiFallback: fallback,
      photoCaptureForTesting: (_) async {
        captureCalls++;
        return _photo('Kirkland Whey', 41);
      },
    )));
    await tester.enterText(find.byType(TextField).first, '41g uurag');
    await tester.tap(find.text('Photo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(captureCalls, 0);
    expect(find.text('41g uurag'), findsOneWidget);
    expect(
        await db.customSelect('SELECT * FROM nutrition_logs').get(), isEmpty);
  });

  testWidgets('photo analysis failure preserves typed text and writes nothing',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: LocalSmartLogScreen(
      service: local,
      aiFallback: fallback,
      photoCaptureForTesting: (_) async => throw StateError('offline'),
    )));
    await tester.enterText(find.byType(TextField).first, '41g uurag');
    await tester.tap(find.text('Photo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('41g uurag'), findsOneWidget);
    expect(find.textContaining('Photo analysis unavailable'), findsOneWidget);
    expect(
        await db.customSelect('SELECT * FROM nutrition_logs').get(), isEmpty);
  });

  testWidgets('transcription failure preserves editable typed text',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: LocalSmartLogScreen(
      service: local,
      aiFallback: fallback,
      voiceTranscriptForTesting: (_) async => throw StateError('denied'),
    )));
    await tester.enterText(find.byType(TextField).first, '40g uurag');
    await tester.tap(find.text('Voice'));
    await tester.pumpAndSettle();
    expect(find.text('40g uurag'), findsOneWidget);
    expect(find.textContaining('Voice unavailable'), findsOneWidget);
    expect(
        await db.customSelect('SELECT * FROM nutrition_logs').get(), isEmpty);
  });
}
