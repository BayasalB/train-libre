import 'food_entry.dart';
import 'food_item.dart';
import 'nutrition_values.dart';

// DOC: This class is a pure display model. It combines data
// from two different sources (the diary entry and the product catalog),
// so the UI can read everything from one place.
class TrackedFoodItem {
  final FoodEntry entry; // The actual diary entry (with ID, amount, and time)
  final FoodItem item; // Food details (with name, calories, etc.)

  TrackedFoodItem({required this.entry, required this.item});

  // Small helper property for the calculated calories of this entry.
  double get calculatedCalories =>
      item.nutritionFor(entry.quantityInGrams).calories;

  /// Historical per-serving imports retain the numeric serving count. Their
  /// immutable archive uses a per-100 equivalent for the existing calculator.
  String get displayQuantity => item.metadata.servingUnit == 'serving'
      ? '${formatFoodQuantity(entry.quantityInGrams)} serving'
      : '${formatFoodQuantity(entry.quantityInGrams)} g';
}
