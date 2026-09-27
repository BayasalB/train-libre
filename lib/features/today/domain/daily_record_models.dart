enum TrainingType {
  unset('Unset / Unknown'),
  chest('Chest'),
  back('Back'),
  shoulder('Shoulder'),
  legs('Legs'),
  arms('Arms'),
  fullBody('Full Body'),
  rest('Rest');

  final String label;
  const TrainingType(this.label);
}

enum TargetKind { training, rest }

/// Calendar keys are deliberately independent of UTC instant conversion.
String localDateKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
DateTime localDay(DateTime date) => DateTime(date.year, date.month, date.day);

DateTime parseLocalDateKey(String key) {
  final parsed = DateTime.tryParse(key);
  if (parsed == null ||
      !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(key) ||
      localDateKey(parsed) != key) {
    throw FormatException('Invalid calendar date', key);
  }
  return localDay(parsed);
}

class NutritionTargets {
  final double calories, protein, carbs, fat;
  const NutritionTargets(
      {required this.calories,
      required this.protein,
      required this.carbs,
      required this.fat});
  void validate() {
    if (![calories, protein, carbs, fat].every((n) => n.isFinite && n >= 0) ||
        calories <= 0) {
      throw ArgumentError(
          'Targets must be finite and nonnegative; calories must be positive.');
    }
  }
}
