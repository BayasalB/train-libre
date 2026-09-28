import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:train_libre/data/database_helper.dart';
import 'package:train_libre/data/drift_database.dart';
import 'package:train_libre/features/diary/data/local_smart_food_log.dart';
import 'package:train_libre/features/diary/data/sources/food_alias_local_data_source.dart';
import 'package:train_libre/features/diary/data/sources/product_local_data_source.dart';
import 'package:train_libre/features/diary/domain/models/food_alias.dart';
import 'package:train_libre/features/diary/domain/models/food_item.dart';
import 'package:train_libre/features/diary/domain/models/saved_food_metadata.dart';
import 'package:train_libre/features/diary/domain/use_cases/parse_local_food_log.dart';
import 'package:train_libre/features/diary/presentation/local_smart_log_screen.dart';
import 'package:train_libre/features/today/data/day_lock_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late AppDatabase db;
  late ProductLocalDataSource products;
  late FoodAliasLocalDataSource aliases;
  late LocalSmartFoodLog log;

  void connect() {
    db = AppDatabase(NativeDatabase(File('${dir.path}/smart-log.sqlite')));
    DatabaseHelper.setDriftDb(db);
    products = ProductLocalDataSource.forTesting(db);
    aliases = FoodAliasLocalDataSource(db);
    log = LocalSmartFoodLog(db, products: products);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('local-smart-food-');
    connect();
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
    await products.insertProduct(FoodItem(
      barcode: 'oats',
      name: 'Hercules Oats',
      calories: 360,
      protein: 12,
      carbs: 60,
      fat: 7,
    ));
    await products.insertProduct(FoodItem(
      barcode: 'pb',
      name: 'Peanut Butter',
      calories: 600,
      protein: 25,
      carbs: 20,
      fat: 50,
    ));
    await products.insertProduct(FoodItem(
      barcode: 'yogurt',
      name: 'Probiotic Yogurt',
      calories: 90,
      protein: 4,
      carbs: 12,
      fat: 3,
    ));
    for (final value in ['uurag', 'уураг', 'whey']) {
      await aliases.save('whey', FoodAliasDraft(alias: value));
    }
    for (final value in ['ovyoos', 'овьёос', 'oats']) {
      await aliases.save('oats', FoodAliasDraft(alias: value));
    }
    for (final value in ['tarag', 'тараг']) {
      await aliases.save('yogurt', FoodAliasDraft(alias: value));
    }
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  test('Cyrillic, romanized, case and whitespace resolve only assigned foods',
      () async {
    for (final phrase in ['41g uurag', 'УУРАГ 41Г', '  41G   UURAG  ']) {
      final c = (await log.preview(phrase)).single;
      expect(c.resolution, LocalFoodResolution.matched);
      expect(c.food?.barcode, 'whey');
      expect(c.quantity, 41);
    }
    for (final phrase in ['80g ovyoos', '80г овьёос', '80g ovyos']) {
      expect((await log.preview(phrase)).single.food?.barcode, 'oats');
    }
    expect((await log.preview('тараг 200г')).single.food?.barcode, 'yogurt');
  });

  test(
      'multiple foods, decimal comma, mixed language and independent quantities',
      () async {
    final entries =
        await log.preview('41g uurag, 80g ovyos; peanut butter 18,8g');
    expect(entries, hasLength(3));
    expect(entries.map((e) => e.quantity).toList(), [41, 80, 18.8]);
    expect(
        entries.map((e) => e.food?.barcode).toList(), ['whey', 'oats', 'pb']);
    expect(entries.every((e) => e.canLog), isTrue);
    expect(entries.last.nutrition!.calories, closeTo(112.8, 1e-9));
  });

  test('decimal burger and Romanized action use only its saved label',
      () async {
    await products.insertProduct(FoodItem(
      barcode: 'burger',
      name: 'Donade triple burger',
      calories: 288.97,
      protein: 15.65,
      carbs: 11.85,
      fat: 19.89,
      metadata: const SavedFoodMetadata(source: NutritionSource.label),
    ));
    final c = (await log.preview('293.8g Donade triple burger idsen')).single;
    expect(c.food?.barcode, 'burger');
    expect(c.quantity, 293.8);
    expect(c.action, LocalFoodAction.consumed);
    expect(c.nutrition!.calories, closeTo(848.99386, 1e-9));
  });

  test('ambiguous thousands or decimal comma needs manual edit', () async {
    final c = (await log.preview('1,234g uurag')).single;
    expect(c.food?.barcode, 'whey');
    expect(c.quantity, isNull);
    expect(c.canLog, isFalse);
    expect(c.warnings.single, contains('Ambiguous comma'));
    expect((await log.preview('18,8g uurag')).single.quantity, 18.8);
  });

  test('planned and cancelled never count; no quantity is invented', () async {
    final planned = (await log.preview('40g uurag beldsen')).single;
    expect(planned.action, LocalFoodAction.planned);
    expect(planned.canLog, isFalse);
    expect((await log.preview('40г уураг болилоо')).single.action,
        LocalFoodAction.cancelled);
    final missing = (await log.preview('uurgaa uusan')).single;
    expect(missing.quantity, isNull);
    expect(missing.canLog, isFalse);
    expect((await log.preview('unknown snack 50g')).single.resolution,
        LocalFoodResolution.unknown);
  });

  test('piece count and serving size are never guessed', () async {
    await products.insertProduct(FoodItem(
        barcode: 'egg',
        name: 'Fried Egg',
        calories: 200,
        protein: 12,
        carbs: 1,
        fat: 16));
    await aliases.save('egg', const FoodAliasDraft(alias: 'sharsan undug'));
    final c = (await log.preview('3 sharsan undug')).single;
    expect(c.food?.barcode, 'egg');
    expect(c.unit, LocalFoodUnit.piece);
    expect(c.canLog, isFalse);
    expect((await log.preview('1 serving uurag')).single.canLog, isFalse);
  });

  test('ambiguous alias requires explicit selection', () async {
    await aliases.save('oats', const FoodAliasDraft(alias: 'uurag'));
    final c = (await log.preview('41g uurag')).single;
    expect(c.resolution, LocalFoodResolution.ambiguous);
    expect(c.food, isNull);
    expect(c.canLog, isFalse);
  });

  test('explicit English and Mongolian actions and units stay distinct',
      () async {
    await products.insertProduct(FoodItem(
      barcode: 'drink',
      name: 'Protein Drink',
      calories: 80,
      protein: 10,
      carbs: 5,
      fat: 1,
      isLiquid: true,
      metadata: const SavedFoodMetadata(servingSize: 200, servingUnit: 'ml'),
    ));
    await aliases.save('drink', const FoodAliasDraft(alias: 'undaa'));
    final ml = (await log.preview('undaa 200ml uusan')).single;
    expect(ml.action, LocalFoodAction.consumed);
    expect(ml.amountInFoodUnit, 200);
    expect(ml.nutrition!.calories, 160);
    final serving = (await log.preview('1 serving undaa')).single;
    expect(serving.amountInFoodUnit, 200);
    expect((await log.preview('40g uurag planned')).single.action,
        LocalFoodAction.planned);
    expect((await log.preview("40g uurag don't add")).single.action,
        LocalFoodAction.cancelled);
    expect((await log.preview('1 shirheg undaa')).single.canLog, isFalse);
  });

  test('unknown, ambiguous and stale preview cannot mutate diary', () async {
    final day = DateTime(2026, 9, 25, 12);
    final unknown = await log.preview('unknown snack 50g');
    await expectLater(
        log.confirm(unknown, date: day, mealType: 'mealtypeSnack'),
        throwsStateError);
    final stale = await log.preview('45.5g uurag');
    await products.insertProduct(FoodItem(
        barcode: 'whey',
        name: 'Kirkland Whey',
        calories: 300,
        protein: 15.65,
        carbs: 11.85,
        fat: 19.89));
    await expectLater(log.confirm(stale, date: day, mealType: 'mealtypeSnack'),
        throwsStateError);
    expect(
        await db.customSelect('SELECT * FROM nutrition_logs').get(), isEmpty);
  });

  test('preview and skipped planned item never write consumed food', () async {
    final day = DateTime(2026, 9, 25, 12);
    final candidates = await log.preview('40g uurag beldsen, 21.3g ovyoos');
    expect(
        await db.customSelect('SELECT * FROM nutrition_logs').get(), isEmpty);
    await log.confirm(candidates, date: day, mealType: 'mealtypeBreakfast');
    final rows = await db
        .customSelect('SELECT amount, legacy_barcode FROM nutrition_logs')
        .get();
    expect(rows, hasLength(1));
    expect(rows.single.read<double>('amount'), 21.3);
    expect(rows.single.read<String>('legacy_barcode'), 'oats');
  });

  test('consumed action and decimal quantities preserve label snapshot',
      () async {
    final day = DateTime(2026, 9, 25, 12);
    final c = (await log.preview('293.8g uurag idsen')).single;
    expect(c.action, LocalFoodAction.consumed);
    expect(c.nutrition!.calories, closeTo(848.99386, 1e-9));
    final ids = await log.confirm([c], date: day, mealType: 'mealtypeSnack');
    expect(ids, hasLength(1));
    final row = await db.customSelect(
        'SELECT amount, archive_local_id FROM nutrition_logs WHERE local_id = ?',
        variables: [Variable.withInt(ids.single)]).getSingle();
    expect(row.read<double>('amount'), 293.8);
    final archive = await db.customSelect(
        'SELECT calories, protein FROM off_products_archive WHERE local_id = ?',
        variables: [
          Variable.withInt(row.read<int>('archive_local_id'))
        ]).getSingle();
    expect(archive.read<double>('calories'), 288.97);
    await products.insertProduct(FoodItem(
        barcode: 'whey',
        name: 'Kirkland Whey',
        calories: 400,
        protein: 20,
        carbs: 12,
        fat: 20));
    final retained = await db.customSelect(
        'SELECT calories FROM off_products_archive WHERE local_id = ?',
        variables: [
          Variable.withInt(row.read<int>('archive_local_id'))
        ]).getSingle();
    expect(retained.read<double>('calories'), 288.97);
  });

  test('atomic confirm rejects locked date without partial food writes',
      () async {
    final day = DateTime(2026, 9, 25, 12);
    final candidates = await log.preview('45.5g uurag uusan, 21.3g ovyoos');
    await DayLockRepository(db).lock(day);
    await expectLater(
        log.confirm(candidates, date: day, mealType: 'mealtypeSnack'),
        throwsA(isA<DayLockedException>()));
    final rows = await db.customSelect('SELECT * FROM nutrition_logs').get();
    expect(rows, isEmpty);
  });

  test('restart and offline local lookup work without network', () async {
    await db.close();
    connect();
    final c = (await log.preview('45.5g УУРАГ')).single;
    expect(c.food?.barcode, 'whey');
    expect(c.quantity, 45.5);
    expect(c.canLog, isTrue);
  });

  testWidgets('review UI blocks unknown food and previews matched nutrition',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(MaterialApp(
        home: LocalSmartLogScreen(
            service: log, initialDate: DateTime(2026, 9, 25))));
    await tester.enterText(find.byType(TextField).first, 'unknown snack 50g');
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    expect(find.textContaining('unknown'), findsWidgets);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm'))
            .onPressed,
        isNull);
    await tester.enterText(find.byType(TextField).first, '41g uurag');
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    expect(find.text('Kirkland Whey'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm'))
            .onPressed,
        isNotNull);
    expect(
        await db.customSelect('SELECT * FROM nutrition_logs').get(), isEmpty);
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    final rows = await db
        .customSelect('SELECT amount, meal_type FROM nutrition_logs')
        .get();
    expect(rows, hasLength(1));
    expect(rows.single.read<double>('amount'), 41);
    expect(rows.single.read<String>('meal_type'), 'mealtypeSnack');
  });
}
