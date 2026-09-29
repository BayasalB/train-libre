import '../models/food_item.dart';
import '../models/nutrition_values.dart';
import '../use_cases/parse_local_food_log.dart';

enum SmartLogInputSource { text, voice, photo, aiAssisted }

/// One review contract for every Smart Log input. Source warnings are
/// informational; [LocalFoodCandidate.warnings] still block an unsafe write.
class SmartLogReviewItem {
  final LocalFoodCandidate candidate;
  final SmartLogInputSource source;
  final String sourceDescription;
  final double? confidence;
  final List<String> sourceWarnings;
  final List<FoodItem> suggestedFoods;
  final bool included;

  const SmartLogReviewItem({
    required this.candidate,
    required this.source,
    required this.sourceDescription,
    this.confidence,
    this.sourceWarnings = const [],
    this.suggestedFoods = const [],
    this.included = true,
  });

  SmartLogReviewItem copyWith({
    LocalFoodCandidate? candidate,
    SmartLogInputSource? source,
    List<String>? sourceWarnings,
    List<FoodItem>? suggestedFoods,
    bool? included,
  }) =>
      SmartLogReviewItem(
        candidate: candidate ?? this.candidate,
        source: source ?? this.source,
        sourceDescription: sourceDescription,
        confidence: confidence,
        sourceWarnings: sourceWarnings ?? this.sourceWarnings,
        suggestedFoods: suggestedFoods ?? this.suggestedFoods,
        included: included ?? this.included,
      );
}

class SmartLogReviewSummary {
  final List<LocalFoodCandidate> consumed;
  final NutritionValues totals;
  final bool canConfirm;

  SmartLogReviewSummary(List<SmartLogReviewItem> items)
      : consumed = List.unmodifiable(items
            .where((item) =>
                item.included &&
                item.candidate.action == LocalFoodAction.consumed)
            .map((item) => item.candidate)),
        totals = items
            .where((item) => item.included && item.candidate.canLog)
            .fold(const NutritionValues(),
                (NutritionValues sum, item) => sum + item.candidate.nutrition!),
        canConfirm =
            items.any((item) => item.included && item.candidate.canLog) &&
                items.every((item) =>
                    !item.included ||
                    item.candidate.action != LocalFoodAction.consumed ||
                    item.candidate.canLog);
}
