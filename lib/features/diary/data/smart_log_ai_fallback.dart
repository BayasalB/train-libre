import 'package:uuid/uuid.dart';

import '../../../data/drift_database.dart';
import '../../today/data/day_lock_repository.dart';
import '../domain/models/food_item.dart';
import '../domain/models/saved_food_metadata.dart';
import '../domain/models/smart_log_ai_models.dart';
import '../domain/use_cases/parse_local_food_log.dart';
import 'local_smart_food_log.dart';
import 'smart_log_ai_provider.dart';
import 'sources/food_alias_local_data_source.dart';

class SmartLogAiSuggestion {
  final SmartLogAiItem interpretation;
  final FoodItem? suggestedFood;
  const SmartLogAiSuggestion(this.interpretation, this.suggestedFood);
}

class SmartLogAiFallbackResult {
  final List<SmartLogAiSuggestion> suggestions;
  const SmartLogAiFallbackResult(this.suggestions);
}

/// Runs only after an explicit request. It never writes the AI response to DB.
class SmartLogAiFallback {
  final LocalSmartFoodLog local;
  final SmartLogAiProvider provider;
  final Set<String> _confirmedReviews = {};
  final Set<String> _pendingReviews = {};

  SmartLogAiFallback(this.local, this.provider);

  AppDatabase get _db => local.db;

  bool canOffer(List<LocalFoodCandidate> candidates) => candidates.any((c) =>
      c.resolution != LocalFoodResolution.ambiguous &&
      c.action != LocalFoodAction.cancelled &&
      (c.resolution == LocalFoodResolution.unknown ||
          (c.action == LocalFoodAction.consumed && !c.canLog)));

  Future<SmartLogAiFallbackResult> interpret(
      List<LocalFoodCandidate> candidates,
      {required bool allowEstimate}) async {
    final unresolved = <SmartLogAiSpan>[];
    for (var i = 0; i < candidates.length; i++) {
      final c = candidates[i];
      if (c.resolution != LocalFoodResolution.ambiguous &&
          c.action != LocalFoodAction.cancelled &&
          (c.resolution == LocalFoodResolution.unknown ||
              (c.action == LocalFoodAction.consumed && !c.canLog))) {
        unresolved.add(SmartLogAiSpan('u$i', c.rawSpan));
      }
    }
    if (unresolved.isEmpty) return const SmartLogAiFallbackResult([]);
    final foods = <FoodItem>[];
    for (final span in unresolved) {
      final index = int.parse(span.id.substring(1));
      final c = candidates[index];
      if (c.food != null) foods.add(c.food!);
      var suggested = await local.products.searchSavedFoods(c.foodQuery);
      if (suggested.isEmpty && c.foodQuery.length >= 3) {
        final first = c.foodQuery.split(' ').first;
        if (first.length >= 3) {
          suggested =
              await local.products.searchSavedFoods(first.substring(0, 3));
        }
      }
      foods.addAll(suggested.take(8));
    }
    final unique =
        {for (final food in foods) food.barcode: food}.values.take(8).toList();
    final candidatesById = <String, FoodItem>{};
    final aliases = FoodAliasLocalDataSource(_db);
    final options = <SmartLogAiFoodOption>[];
    for (var i = 0; i < unique.length; i++) {
      final food = unique[i];
      final id = 'c$i';
      candidatesById[id] = food;
      options.add(SmartLogAiFoodOption(
          id,
          food.name,
          (await aliases.forFood(food.barcode))
              .take(6)
              .map((alias) => alias.alias)
              .toList()));
    }
    final request =
        SmartLogAiRequest(unresolved, options, allowEstimate: allowEstimate);
    final raw = await provider.interpret(request);
    final response = SmartLogAiResponse.parse(raw, request);
    return SmartLogAiFallbackResult([
      for (final item in response.items)
        SmartLogAiSuggestion(
          item,
          item.suggestedLocalFoodReference == null
              ? null
              : candidatesById[item.suggestedLocalFoodReference],
        ),
    ]);
  }

  /// Kept separate from local matches until the user taps "Use estimate".
  Future<FoodItem> estimateFood(SmartLogAiItem item) async {
    final estimate = item.nutritionEstimate;
    if (estimate == null ||
        ![LocalFoodUnit.grams, LocalFoodUnit.milliliters].contains(item.unit)) {
      throw StateError('A g/ml estimate is required.');
    }
    if ((await local.resolve(item.interpretedFoodName)).isNotEmpty) {
      throw StateError(
          'A local Saved Food matches this name. Link it instead of using an AI estimate.');
    }
    return FoodItem(
      barcode: 'smart-ai:${const Uuid().v4()}',
      name: item.interpretedFoodName,
      calories: estimate.caloriesPer100,
      protein: estimate.proteinPer100,
      carbs: estimate.carbsPer100,
      fat: estimate.fatPer100,
      source: FoodItemSource.user,
      isLiquid: item.unit == LocalFoodUnit.milliliters,
      metadata: const SavedFoodMetadata(
          source: NutritionSource.estimate,
          notes: 'AI_ESTIMATE — user reviewed in Smart Log'),
    );
  }

  /// Existing diary insert still creates the point-in-time nutrition snapshot
  /// and checks Day Lock inside the same transaction.
  Future<List<int>> confirm({
    required String reviewId,
    required List<LocalFoodCandidate> candidates,
    required Map<String, FoodItem> acceptedEstimates,
    required DateTime date,
    required String mealType,
  }) async {
    if (_confirmedReviews.contains(reviewId) ||
        !_pendingReviews.add(reviewId)) {
      throw StateError('This Smart Log preview was already confirmed.');
    }
    try {
      final result = await _db.transaction(() async {
        await DayLockRepository(_db).requireUnlocked(date);
        final used = candidates
            .where((c) => c.action == LocalFoodAction.consumed)
            .map((c) => c.food?.barcode)
            .whereType<String>()
            .toSet();
        for (final entry in acceptedEstimates.entries) {
          final food = entry.value;
          if (entry.key != food.barcode ||
              !used.contains(food.barcode) ||
              food.nutritionSource != NutritionSource.estimate ||
              food.metadata.verified ||
              !_validEstimate(food) ||
              !food.barcode.startsWith('smart-ai:') ||
              await local.products.getProductByBarcode(food.barcode) != null) {
            throw StateError('Invalid or already used AI estimate.');
          }
          if ((await local.resolve(food.name)).isNotEmpty) {
            throw StateError(
                'A local Saved Food now matches this name. Preview and link it.');
          }
          await local.products.insertProduct(food);
        }
        return local.confirm(candidates, date: date, mealType: mealType);
      });
      _confirmedReviews.add(reviewId);
      return result;
    } finally {
      _pendingReviews.remove(reviewId);
    }
  }

  bool _validEstimate(FoodItem food) =>
      food.calories.isFinite &&
      food.calories >= 0 &&
      food.calories <= 1000 &&
      food.protein.isFinite &&
      food.protein >= 0 &&
      food.protein <= 100 &&
      food.carbs.isFinite &&
      food.carbs >= 0 &&
      food.carbs <= 100 &&
      food.fat.isFinite &&
      food.fat >= 0 &&
      food.fat <= 100;
}
