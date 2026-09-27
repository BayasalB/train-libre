import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:train_libre/data/drift_database.dart';
import 'package:train_libre/data/database_helper.dart';
import 'package:train_libre/core/infrastructure/backup_manager.dart';
import 'package:train_libre/features/workout/data/sources/workout_local_data_source.dart';
import 'package:train_libre/features/diary/data/sources/product_local_data_source.dart';
import 'package:train_libre/features/diary/data/sources/food_alias_local_data_source.dart';
import 'package:train_libre/features/diary/domain/models/food_alias.dart';
import 'package:train_libre/features/diary/domain/models/food_item.dart';
import 'package:train_libre/features/diary/domain/models/food_entry.dart';
import 'package:train_libre/features/diary/domain/models/saved_food_metadata.dart';
import 'package:train_libre/features/diary/domain/use_cases/resolve_saved_food_use_case.dart';
import 'package:train_libre/features/diary/domain/use_cases/retain_historical_off_products_use_case.dart';

FoodItem food(String barcode, String name,
        {double kcal = 288.97,
        FoodItemSource source = FoodItemSource.user,
        SavedFoodMetadata metadata = const SavedFoodMetadata(),
        double? sodium}) =>
    FoodItem(
        barcode: barcode,
        name: name,
        calories: kcal,
        protein: 15.65,
        carbs: 11.85,
        fat: 19.89,
        salt: 0.5,
        sodium: sodium,
        source: source,
        metadata: metadata,
        productQuantity: 1000,
        productQuantityUnit: 'g');

final label = SavedFoodMetadata(
    servingSize: 45.5,
    servingUnit: 'g',
    source: NutritionSource.label,
    verified: true,
    verifiedAt: DateTime(2026, 9, 24),
    notes: 'Exact label',
    productPhotoRef: 'foods/whey.jpg',
    labelPhotoRef: 'foods/whey-label.jpg');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late ProductLocalDataSource products;
  late FoodAliasLocalDataSource aliases;
  late DatabaseHelper helper;
  late ResolveSavedFoodUseCase resolve;
  late Directory directory;
  void connect() {
    db = AppDatabase(NativeDatabase(File('${directory.path}/foods.sqlite')));
    DatabaseHelper.setDriftDb(db);
    helper = DatabaseHelper.forTesting(db);
    products = ProductLocalDataSource.forTesting(db);
    aliases = FoodAliasLocalDataSource(db);
    resolve = ResolveSavedFoodUseCase(
        (query) => products.searchSavedFoods(query, exact: true));
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('saved-foods-');
    connect();
    await products.insertProduct(
        food('whey', 'Kirkland Whey', metadata: label, sodium: 0.123));
    await products.insertProduct(food('oats', 'Hercules Oats'));
    await products.insertProduct(food('yogurt', 'Probiotic Yogurt'));
  });
  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
      'Latin, Cyrillic, romanized Mongolian and whitespace resolve only assigned aliases',
      () async {
    for (final value in ['uurag', 'уураг', 'whey']) {
      await aliases.save('whey', FoodAliasDraft(alias: value, language: 'mn'));
    }
    for (final value in ['ovyoos', 'овьёос', 'oats']) {
      await aliases.save('oats', FoodAliasDraft(alias: value));
    }
    for (final value in ['tarag', 'тараг']) {
      await aliases.save('yogurt', FoodAliasDraft(alias: value));
    }
    for (final entry in {
      'uurag': 'whey',
      'УУРАГ': 'whey',
      '  ovyoos  ': 'oats',
      'тараг': 'yogurt',
      'ОВЬЁОС': 'oats'
    }.entries) {
      final result = await resolve.execute(entry.key);
      expect(result.status, SavedFoodResolutionStatus.matched);
      expect(result.food!.barcode, entry.value);
    }
    expect((await resolve.execute('unknown')).status,
        SavedFoodResolutionStatus.unknown);
    expect((await resolve.execute('80g uurag')).status,
        SavedFoodResolutionStatus.unknown);
    expect(normalizeFoodAlias('  WHEY\t protein\n\u00a0Powder '),
        'whey protein powder');
    await products.insertProduct(food('other', 'Other Whey'));
    expect((await resolve.execute('uurag')).food!.barcode, 'whey');
  });

  test(
      'duplicate prevention preserves original spelling, UUID, creation date and language',
      () async {
    await aliases.save('whey',
        const FoodAliasDraft(alias: '  Whey\tPowder  ', language: 'en'));
    final before = (await aliases.forFood('whey')).single;
    expect(before.alias, '  Whey\tPowder  ');
    await expectLater(
        aliases.save('whey', const FoodAliasDraft(alias: 'whey powder')),
        throwsA(isA<DuplicateFoodAlias>()));
    await aliases.save(
        'whey', FoodAliasDraft(id: before.id, alias: 'уураг', language: 'mn'));
    final after = (await aliases.forFood('whey')).single;
    expect(after.id, before.id);
    expect(after.createdAt, before.createdAt);
    expect(after.language, 'mn');
    expect((await resolve.execute('WHEY POWDER')).status,
        SavedFoodResolutionStatus.unknown);
    expect((await resolve.execute('УУРАГ')).food!.barcode, 'whey');
    await aliases.delete(before.id);
    expect((await resolve.execute('УУРАГ')).status,
        SavedFoodResolutionStatus.unknown);
    expect((await db.select(db.foodAliases).get()).single.deletedAt, isNotNull);
    await aliases.save('whey', const FoodAliasDraft(alias: 'уураг'));
    expect((await aliases.forFood('whey')).single.id, before.id);
  });

  test('ambiguous alias returns every candidate without selecting a food',
      () async {
    await aliases.save('whey', const FoodAliasDraft(alias: 'uurag'));
    await aliases.save('oats', const FoodAliasDraft(alias: 'UURAG'));
    final result = await resolve.execute('uurag');
    expect(result.status, SavedFoodResolutionStatus.ambiguous);
    expect(result.food, isNull);
    expect(result.candidates.map((f) => f.barcode),
        unorderedEquals(['whey', 'oats']));
    expect((await products.searchProducts('UURAG')).map((f) => f.barcode),
        containsAll(['whey', 'oats']));
  });

  test(
      'primary name and Cyrillic name search is local and alias drafts save atomically',
      () async {
    await products.insertProduct(food('mn', 'Монгол Тараг'));
    expect((await products.searchProducts('МОНГОЛ')).single.barcode, 'mn');
    expect((await resolve.execute('kirkland whey')).food!.barcode, 'whey');
    await aliases.replaceForFood('oats', const [
      FoodAliasDraft(alias: 'ovyoos'),
      FoodAliasDraft(alias: 'овьёос')
    ]);
    final rows = await aliases.forFood('oats');
    await expectLater(
        aliases.replaceForFood('oats',
            const [FoodAliasDraft(alias: 'new'), FoodAliasDraft(alias: 'NEW')]),
        throwsA(isA<DuplicateFoodAlias>()));
    expect((await aliases.forFood('oats')).map((r) => r.id),
        rows.map((r) => r.id));
    await aliases.replaceForFood(
        'oats', [FoodAliasDraft(id: rows.first.id, alias: 'oatmeal')]);
    expect((await aliases.forFood('oats')).single.alias, 'oatmeal');
  });

  test(
      'explicit label overrides catalog refresh; old snapshots stay immutable and new logs use new data',
      () async {
    final now = DateTime.now();
    await products.insertProduct(
        food('catalog', 'Catalog Whey', kcal: 999, source: FoodItemSource.off));
    await products.updateProduct(food('catalog', 'My label',
        metadata: label, sodium: .123, source: FoodItemSource.off));
    await aliases.save('catalog', const FoodAliasDraft(alias: 'my whey'));
    final original = (await products.getProductByBarcode('catalog'))!;
    final oldId = await helper.insertFoodEntry(FoodEntry(
        barcode: 'catalog',
        timestamp: now,
        quantityInGrams: 293.8,
        mealType: 'mealtypeLunch'));
    final oldArchive = (await db.select(db.offProductsArchive).get()).single;
    expect(oldArchive.sodium, .123);
    expect(oldArchive.servingSize, 45.5);
    expect(oldArchive.nutritionSource, 'label');
    await products.insertProduct(food('catalog', 'Fresh estimate',
        kcal: 1,
        source: FoodItemSource.off,
        metadata: const SavedFoodMetadata(source: NutritionSource.estimate)));
    final resolved = (await resolve.execute('my whey')).food!;
    expect(resolved.id, original.id);
    expect(resolved.calories, 288.97);
    expect(resolved.metadata.toJson(), label.toJson());
    expect(resolved.sodium, .123);
    await products.updateProduct(food('catalog', 'New label',
        kcal: 400.25,
        sodium: .234,
        metadata: label,
        source: FoodItemSource.off));
    await helper.updateFoodEntry(FoodEntry(
        id: oldId,
        barcode: 'catalog',
        timestamp: now,
        quantityInGrams: 45.5,
        mealType: 'mealtypeLunch'));
    await helper.insertFoodEntry(FoodEntry(
        barcode: 'catalog',
        timestamp: now,
        quantityInGrams: 100,
        mealType: 'mealtypeLunch'));
    final archives = await db.select(db.offProductsArchive).get();
    expect(archives.first.toJson(), oldArchive.toJson());
    expect(archives.last.calories, 400.25);
    expect(archives.last.sodium, .234);
    expect(archives.last.contentHash, isNot(oldArchive.contentHash));
    expect(
        (await products.getProductsByArchiveIds(
                [oldArchive.localId]))[oldArchive.localId]!
            .metadata
            .toJson(),
        label.toJson());
  });

  test(
      'backup restores aliases, deleted aliases and all metadata offline on an empty database',
      () async {
    await aliases.save(
        'whey', const FoodAliasDraft(alias: 'uurag', language: 'mn'));
    await aliases.save('whey', const FoodAliasDraft(alias: 'old alias'));
    await aliases.delete((await aliases.forFood('whey')).last.id);
    await products.insertProduct(
        food('off', 'Catalog yogurt', source: FoodItemSource.off));
    await aliases.save('off', const FoodAliasDraft(alias: 'тараг'));
    final expectedAliases = (await db.select(db.foodAliases).get())
        .map((a) => a.toJson()..remove('localId'))
        .toList();
    final id = (await products.getProductByBarcode('whey'))!.id;
    final manager = BackupManager(
        userDb: helper,
        productDb: products,
        workoutDb: WorkoutLocalDataSource.forTesting(db));
    final payload =
        jsonDecode(jsonEncode(await manager.generateBackupPayloadForTesting()))
            as Map<String, dynamic>;
    await db.close();
    await File('${directory.path}/foods.sqlite').delete();
    connect();
    final restore = BackupManager(
        userDb: helper,
        productDb: products,
        workoutDb: WorkoutLocalDataSource.forTesting(db));
    expect(await restore.importBackupPayloadForTesting(payload), isTrue);
    final restored = (await resolve.execute('UURAG')).food!;
    expect(restored.id, id);
    expect(restored.metadata.toJson(), label.toJson());
    expect(restored.sodium, .123);
    expect(restored.productQuantity, 1000);
    expect(restored.metadata.servingSize, 45.5);
    expect((await resolve.execute('тараг')).food!.barcode, 'off');
    expect((await resolve.execute('old alias')).status,
        SavedFoodResolutionStatus.unknown);
    expect(
        (await db.select(db.foodAliases).get())
            .map((a) => a.toJson()..remove('localId'))
            .toList(),
        expectedAliases);
    await db.close();
    connect();
    expect((await resolve.execute('uurag')).food!.sodium, .123);
    expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
  });

  test(
      'invalid alias backup rolls back instead of silently dropping duplicate mappings',
      () async {
    await aliases.save('whey', const FoodAliasDraft(alias: 'uurag'));
    final manager = BackupManager(
        userDb: helper,
        productDb: products,
        workoutDb: WorkoutLocalDataSource.forTesting(db));
    final payload = await manager.generateBackupPayloadForTesting();
    final rows = payload['food_aliases'] as List;
    rows.add({
      ...Map<String, dynamic>.from(rows.first as Map),
      'id': 'duplicate-id',
      'normalized_alias': 'bad-key'
    });
    await expectLater(
        manager.importBackupPayloadForTesting(payload), throwsA(anything));
    expect((await resolve.execute('uurag')).food!.barcode, 'whey');
    expect((await aliases.forFood('whey')).length, 1);
  });

  test(
      'personalized catalog food is retained when removed from the downloaded catalog',
      () async {
    await products.insertProduct(
        food('off', 'Offline catalog food', source: FoodItemSource.off));
    await aliases.save('off', const FoodAliasDraft(alias: 'offline'));
    await const RetainHistoricalOffProductsUseCase()
        .execute(database: db, importedOffBarcodes: {'new-catalog-item'});
    expect((await resolve.execute('offline')).food!.barcode, 'off');
  });

  test('metadata validates serving basis and verified date without guessing',
      () {
    expect(() => const SavedFoodMetadata(servingSize: 30).validate(),
        throwsArgumentError);
    expect(
        () => const SavedFoodMetadata(servingSize: -1, servingUnit: 'g')
            .validate(),
        throwsArgumentError);
    expect(() => const SavedFoodMetadata(verified: true).validate(),
        throwsArgumentError);
    expect(() => label.validate(), returnsNormally);
    expect(
        FoodItem.fromMap(food('x', 'x', metadata: label, sodium: .123).toMap(),
                source: FoodItemSource.user)
            .metadata
            .toJson(),
        label.toJson());
  });

  test(
      'manual logging, aliases, recent foods and favorites work with HTTP disabled',
      () async {
    await HttpOverrides.runZoned(() async {
      await aliases.save('whey', const FoodAliasDraft(alias: 'uurag'));
      await products.addFavorite('whey');
      await helper.insertFoodEntry(FoodEntry(
          barcode: 'whey',
          timestamp: DateTime.now(),
          quantityInGrams: 45.5,
          mealType: 'mealtypeBreakfast'));
      expect((await products.getRecentProducts()).first.barcode, 'whey');
      expect((await products.getFavoriteProducts()).single.metadata.servingSize,
          45.5);
      expect((await resolve.execute('УУРаг')).status,
          SavedFoodResolutionStatus.unknown);
      expect((await resolve.execute('UURAG')).food!.calories, 288.97);
    },
        createHttpClient: (_) =>
            throw StateError('Network is disabled for this test'));
  });

  test(
      'catalog or estimated ingestion cannot overwrite a user-created exact label',
      () async {
    final id = (await products.getProductByBarcode('whey'))!.id;
    await products.insertProduct(
        food('whey', 'Generic catalog', kcal: 1, source: FoodItemSource.off));
    await products.insertProduct(food('whey', 'Estimate',
        kcal: 2,
        metadata: const SavedFoodMetadata(source: NutritionSource.estimate)));
    final saved = (await products.getProductByBarcode('whey'))!;
    expect(saved.id, id);
    expect(saved.calories, 288.97);
    expect(saved.metadata.toJson(), label.toJson());
  });

  test(
      'renaming aliases together preserves UUIDs; clearing user data clears aliases',
      () async {
    await aliases.replaceForFood('whey',
        const [FoodAliasDraft(alias: 'one'), FoodAliasDraft(alias: 'two')]);
    final rows = await aliases.forFood('whey');
    await aliases.replaceForFood('whey', [
      FoodAliasDraft(id: rows[0].id, alias: 'two'),
      FoodAliasDraft(id: rows[1].id, alias: 'one')
    ]);
    final renamed = await aliases.forFood('whey');
    expect(renamed.map((r) => r.id), rows.map((r) => r.id));
    expect(renamed.map((r) => r.alias), ['two', 'one']);
    await helper.clearAllUserData();
    expect(await aliases.find('two'), isEmpty);
    expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
  });
}
