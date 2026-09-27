import '../models/food_item.dart';

enum SavedFoodResolutionStatus { unknown, matched, ambiguous }

class SavedFoodResolution {
  final List<FoodItem> candidates;
  SavedFoodResolution(Iterable<FoodItem> foods)
      : candidates = List.unmodifiable(
            {for (final food in foods) food.barcode: food}.values);
  SavedFoodResolutionStatus get status => candidates.isEmpty
      ? SavedFoodResolutionStatus.unknown
      : candidates.length == 1
          ? SavedFoodResolutionStatus.matched
          : SavedFoodResolutionStatus.ambiguous;

  /// Never expose a selected food for an ambiguous result.
  FoodItem? get food =>
      status == SavedFoodResolutionStatus.matched ? candidates.single : null;
}

/// Pass a local exact-name/alias lookup. No NLP, estimates, or network calls.
class ResolveSavedFoodUseCase {
  final Future<List<FoodItem>> Function(String query) lookup;
  const ResolveSavedFoodUseCase(this.lookup);
  Future<SavedFoodResolution> execute(String query) async =>
      SavedFoodResolution(await lookup(query));
}
