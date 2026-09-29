import '../../../data/drift_database.dart' show AppDatabase;
import '../domain/models/food_alias.dart';
import '../domain/models/food_entry.dart';
import '../domain/models/food_item.dart';
import '../domain/models/meal_entry.dart';
import '../domain/use_cases/parse_local_food_log.dart';
import '../../../services/telemetry/telemetry_service.dart';
import 'sources/diary_local_data_source.dart';
import 'sources/food_alias_local_data_source.dart';
import 'sources/product_local_data_source.dart';

/// Local-only bridge between deterministic parsing and the established diary.
class LocalSmartFoodLog {
  final AppDatabase db;
  final ProductLocalDataSource products;
  final DiaryLocalDataSource diary;
  final ParseLocalFoodLog parser;

  LocalSmartFoodLog(this.db,
      {ProductLocalDataSource? products,
      DiaryLocalDataSource? diary,
      ParseLocalFoodLog? parser})
      : products = products ?? ProductLocalDataSource(db),
        diary = diary ?? DiaryLocalDataSource(db),
        parser = parser ?? ParseLocalFoodLog();

  Future<List<LocalFoodCandidate>> preview(String input) async {
    final parsed = parser.parse(input);
    final result = <LocalFoodCandidate>[];
    for (final candidate in parsed) {
      result
          .add(candidate.copyWith(matches: await resolve(candidate.foodQuery)));
    }
    return result;
  }

  Future<List<FoodItem>> resolve(String query) async {
    final key = normalizeFoodAlias(query);
    if (key.isEmpty) return [];
    final aliases = FoodAliasLocalDataSource(db);
    Future<List<FoodItem>> fromAlias(String value) async {
      final rows = await aliases.find(value);
      final foods = await Future.wait(rows
          .map((alias) => products.getProductByBarcode(alias.productBarcode)));
      return _unique(foods.whereType<FoodItem>());
    }

    // Exact alias always wins over a Saved Food's display name.
    final exactAlias = await fromAlias(key);
    if (exactAlias.isNotEmpty) return exactAlias;

    final exactName = await products.searchSavedFoods(key, exact: true);
    final namesOnly = exactName
        .where((food) =>
            normalizeFoodAlias(food.name) == key ||
            normalizeFoodAlias('${food.brand} ${food.name}') == key)
        .toList();
    if (namesOnly.isNotEmpty) return _unique(namesOnly);

    // Small orthographic equivalence, applied ONLY to assigned aliases.
    // It cannot create a product match where no alias was configured.
    if (key == 'ovyos' || key == 'ovyoos') {
      return fromAlias(key == 'ovyos' ? 'ovyoos' : 'ovyos');
    }
    return [];
  }

  List<FoodItem> _unique(Iterable<FoodItem> foods) => [
        ...{for (final food in foods) food.barcode: food}.values
      ];

  /// One transaction for all entries; the diary checks Day Lock and makes
  /// immutable historical nutrition snapshots for every inserted food.
  Future<List<int>> confirm(List<LocalFoodCandidate> candidates,
      {required DateTime date,
      required String mealType,
      MealEntry? mealEntry,
      String telemetrySource = FoodLogSource.manualSearch}) async {
    if (candidates.isEmpty) throw StateError('Nothing to log.');
    if (!const {
      'mealtypeBreakfast',
      'mealtypeLunch',
      'mealtypeDinner',
      'mealtypeSnack'
    }.contains(mealType)) {
      throw ArgumentError.value(mealType, 'mealType', 'Unknown diary meal');
    }
    if (mealEntry != null &&
        (mealEntry.mealType != mealType ||
            !mealEntry.consumedAt.isAtSameMomentAs(date))) {
      throw ArgumentError(
          'Meal metadata must match the reviewed date and type.');
    }
    final consumed = candidates
        .where((candidate) => candidate.action == LocalFoodAction.consumed)
        .toList();
    if (consumed.isEmpty) throw StateError('No consumed foods to log.');
    if (consumed.any((candidate) => !candidate.canLog)) {
      throw StateError('Resolve all consumed foods and quantities first.');
    }
    return db.transaction(() async {
      final ids = <int>[];
      if (mealEntry != null) await diary.insertMealEntry(mealEntry);
      for (final candidate in consumed) {
        final current =
            await products.getProductByBarcode(candidate.food!.barcode);
        if (current == null ||
            current.name != candidate.food!.name ||
            current.brand != candidate.food!.brand ||
            current.source != candidate.food!.source ||
            current.isLiquid != candidate.food!.isLiquid ||
            current.calories != candidate.food!.calories ||
            current.protein != candidate.food!.protein ||
            current.carbs != candidate.food!.carbs ||
            current.fat != candidate.food!.fat ||
            current.sugar != candidate.food!.sugar ||
            current.fiber != candidate.food!.fiber ||
            current.salt != candidate.food!.salt ||
            current.sodium != candidate.food!.sodium ||
            current.metadata.servingSize !=
                candidate.food!.metadata.servingSize ||
            current.metadata.servingUnit !=
                candidate.food!.metadata.servingUnit ||
            current.nutritionSource != candidate.food!.nutritionSource ||
            current.metadata.verified != candidate.food!.metadata.verified ||
            current.metadata.verifiedAt !=
                candidate.food!.metadata.verifiedAt ||
            current.metadata.notes != candidate.food!.metadata.notes ||
            current.metadata.productPhotoRef !=
                candidate.food!.metadata.productPhotoRef ||
            current.metadata.labelPhotoRef !=
                candidate.food!.metadata.labelPhotoRef) {
          throw StateError('Saved Food changed since preview. Preview again.');
        }
        ids.add(await diary.insertFoodEntry(
            FoodEntry(
              barcode: candidate.food!.barcode,
              timestamp: date,
              quantityInGrams: candidate.amountInFoodUnit!,
              mealType: mealType,
              mealEntryId: mealEntry?.id,
            ),
            telemetrySource: telemetrySource));
      }
      return ids;
    });
  }
}
