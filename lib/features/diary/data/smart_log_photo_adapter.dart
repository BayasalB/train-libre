import '../../../services/ai_meal_validation.dart';
import '../domain/models/food_alias.dart';
import '../domain/models/nutrition_values.dart';
import '../domain/models/smart_log_review.dart';
import '../domain/use_cases/parse_local_food_log.dart';
import 'local_smart_food_log.dart';

/// Converts the existing meal-image identity/portion output into the same
/// local review used by text and voice. The image model does not supply macros.
class SmartLogPhotoAdapter {
  final LocalSmartFoodLog local;
  const SmartLogPhotoAdapter(this.local);

  Future<List<SmartLogReviewItem>> review(AiMealCandidate result) async {
    if (result.items.isEmpty || result.items.length > 20) {
      throw const FormatException('No valid photo foods to review.');
    }
    final review = <SmartLogReviewItem>[];
    for (final item in result.items) {
      final name = item.name.trim();
      if (name.isEmpty ||
          name.length > 160 ||
          !item.grams.isFinite ||
          item.grams < 0 ||
          item.grams > 100000 ||
          (item.servedGrams != null &&
              (!item.servedGrams!.isFinite || item.servedGrams! < 0)) ||
          (item.confidence != null &&
              (!item.confidence!.isFinite ||
                  item.confidence! < 0 ||
                  item.confidence! > 1))) {
        throw const FormatException('Malformed photo analysis result.');
      }
      final quantity = item.grams > 0 ? item.grams : null;
      final matches = await local.resolve(name);
      final span =
          quantity == null ? name : '${formatFoodQuantity(quantity)}g $name';
      review.add(SmartLogReviewItem(
        candidate: LocalFoodCandidate(
          rawSpan: span,
          normalizedText: normalizeFoodAlias(span),
          foodQuery: name,
          quantity: quantity,
          unit: LocalFoodUnit.grams,
          action: LocalFoodAction.consumed,
          // Photo identity is a suggestion, never a silent Saved Food link.
          matches: matches.length > 1 ? matches : const [],
          warnings: [if (quantity == null) 'Quantity missing: enter grams.'],
        ),
        source: SmartLogInputSource.photo,
        sourceDescription: 'Meal photo: $name',
        confidence: item.confidence,
        suggestedFoods: matches,
        sourceWarnings: [
          'Photo portion is an estimate. Review grams before Confirm.',
          if (item.confidence != null && item.confidence! < 0.6)
            'Low recognition confidence: check this food identity.',
          if (item.servedGrams != null && item.servedGrams != item.grams)
            'Visible portion ${formatFoodQuantity(item.servedGrams!)} g; ${formatFoodQuantity(item.grams)} g is the suggested raw-equivalent.',
          if (matches.isEmpty)
            'Nutrition unknown until you link a Saved Food or explicitly use an estimate.',
        ],
      ));
    }
    return List.unmodifiable(review);
  }
}
