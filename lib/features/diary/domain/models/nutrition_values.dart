/// Unrounded nutrient values. Quantities use the food's existing g/ml basis.
/// Rounding belongs only at the presentation boundary, never in aggregation.
class NutritionValues {
  final double calories;
  final double protein;
  final double carbs;
  final double fat;
  final double sugar;
  final double fiber;
  final double salt;

  const NutritionValues({
    this.calories = 0,
    this.protein = 0,
    this.carbs = 0,
    this.fat = 0,
    this.sugar = 0,
    this.fiber = 0,
    this.salt = 0,
  });

  /// Scale per-100 g/ml data without changing the quantity's unit or rounding.
  NutritionValues forAmount(num amount) {
    return NutritionValues(
      calories: scaleNutritionValue(calories, amount),
      protein: scaleNutritionValue(protein, amount),
      carbs: scaleNutritionValue(carbs, amount),
      fat: scaleNutritionValue(fat, amount),
      sugar: scaleNutritionValue(sugar, amount),
      fiber: scaleNutritionValue(fiber, amount),
      salt: scaleNutritionValue(salt, amount),
    );
  }

  NutritionValues operator +(NutritionValues other) => NutritionValues(
        calories: calories + other.calories,
        protein: protein + other.protein,
        carbs: carbs + other.carbs,
        fat: fat + other.fat,
        sugar: sugar + other.sugar,
        fiber: fiber + other.fiber,
        salt: salt + other.salt,
      );
}

/// Shared scaling for individual nutrients, including optional label fields.
double scaleNutritionValue(num per100, num amount) {
  if (!amount.isFinite || amount < 0) {
    throw ArgumentError.value(
        amount, 'amount', 'Must be finite and nonnegative');
  }
  return per100 * (amount / 100);
}

/// Accept decimal points or decimal commas, but reject NaN and infinity.
double? parseNutritionNumber(String input) {
  final value = double.tryParse(input.trim().replaceAll(',', '.'));
  return value != null && value.isFinite ? value : null;
}

/// Lossless editable quantity text, without an unnecessary trailing '.0'.
String formatFoodQuantity(num value) => value == value.roundToDouble()
    ? value.toInt().toString()
    : value.toString();
