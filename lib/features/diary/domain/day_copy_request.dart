import '../../today/domain/daily_record_models.dart';
import 'models/nutrition_values.dart';

class DayCopyRequest {
  final DateTime sourceDate;
  final DateTime destinationDate;
  final int? foodEntryId;
  final String? mealEntryId;
  final String? mealType;
  final bool includeTrainingType;
  final bool includeNotes;

  const DayCopyRequest({
    required this.sourceDate,
    required this.destinationDate,
    this.foodEntryId,
    this.mealEntryId,
    this.mealType,
    this.includeTrainingType = false,
    this.includeNotes = false,
  });

  String get destinationKey => localDateKey(destinationDate);
}

class CopyFoodPreview {
  final String name;
  final double quantity;
  final NutritionValues nutrition;
  const CopyFoodPreview(this.name, this.quantity, this.nutrition);
}

class DayCopyPreview {
  final DayCopyRequest request;
  final List<CopyFoodPreview> foods;
  final NutritionValues total;
  const DayCopyPreview(this.request, this.foods, this.total);
  bool get isEmpty => foods.isEmpty;
}
