import '../models/food_alias.dart';
import '../models/food_item.dart';
import '../models/nutrition_values.dart';

enum LocalFoodAction { consumed, planned, cancelled }

enum LocalFoodUnit { grams, milliliters, serving, piece, unknown }

enum LocalFoodResolution { matched, unknown, ambiguous }

/// A review candidate. No candidate is written by the parser.
class LocalFoodCandidate {
  final String rawSpan;
  final String normalizedText;
  final String foodQuery;
  final double? quantity;
  final LocalFoodUnit unit;
  final LocalFoodAction action;
  final List<FoodItem> matches;
  final List<String> warnings;

  const LocalFoodCandidate({
    required this.rawSpan,
    required this.normalizedText,
    required this.foodQuery,
    required this.quantity,
    required this.unit,
    required this.action,
    this.matches = const [],
    this.warnings = const [],
  });

  LocalFoodResolution get resolution => matches.isEmpty
      ? LocalFoodResolution.unknown
      : matches.length == 1
          ? LocalFoodResolution.matched
          : LocalFoodResolution.ambiguous;

  FoodItem? get food =>
      resolution == LocalFoodResolution.matched ? matches.single : null;

  /// A serving is safe only when the user explicitly configured its g/ml size.
  /// A piece is never assumed equivalent to a serving or package.
  double? get amountInFoodUnit {
    final selected = food;
    if (selected == null || quantity == null || quantity! <= 0) return null;
    final expected = selected.isLiquid == true ? 'ml' : 'g';
    switch (unit) {
      case LocalFoodUnit.grams:
        return expected == 'g' ? quantity : null;
      case LocalFoodUnit.milliliters:
        return expected == 'ml' ? quantity : null;
      case LocalFoodUnit.serving:
        final size = selected.metadata.servingSize;
        return size != null &&
                size.isFinite &&
                size > 0 &&
                selected.metadata.servingUnit == expected
            ? quantity! * size
            : null;
      case LocalFoodUnit.piece:
      case LocalFoodUnit.unknown:
        return null;
    }
  }

  NutritionValues? get nutrition {
    final amount = amountInFoodUnit;
    return amount == null ? null : food!.nutritionFor(amount);
  }

  bool get canLog =>
      action == LocalFoodAction.consumed &&
      resolution == LocalFoodResolution.matched &&
      amountInFoodUnit != null &&
      warnings.isEmpty;

  LocalFoodCandidate copyWith({
    double? quantity,
    LocalFoodUnit? unit,
    LocalFoodAction? action,
    List<FoodItem>? matches,
    List<String>? warnings,
  }) =>
      LocalFoodCandidate(
        rawSpan: rawSpan,
        normalizedText: normalizedText,
        foodQuery: foodQuery,
        quantity: quantity ?? this.quantity,
        unit: unit ?? this.unit,
        action: action ?? this.action,
        matches: matches ?? this.matches,
        warnings: warnings ?? this.warnings,
      );
}

/// Deterministic, offline tokenization. Product identity is resolved separately
/// using the user's own Saved Foods and aliases.
class ParseLocalFoodLog {
  static final _split = RegExp(
      r'(?<!\d)[,;]|[,;](?!\d)|[\r\n]+|\s+(?:and|ба|бас)\s+',
      caseSensitive: false,
      unicode: true);
  static final _quantity = RegExp(
    r'(?<![\w\d])([0-9]+(?:[.,][0-9]+)?)\s*(грамм|grams?|гр|г|grams|g|milliliters?|ml|мл|servings?|shirheg|ширхэг|ш|sh)?(?![\w])',
    caseSensitive: false,
    unicode: true,
  );
  static final _cancelled = RegExp(
    r'\b(?:boliloo|ideegui|uugaagui|cancel)\b|болилоо|идээгүй|уугаагүй|don.t\s+add',
    caseSensitive: false,
    unicode: true,
  );
  static final _planned = RegExp(
    r'\b(?:beldsen|planned|prepared|ideh\s+gej\s+baina)\b|бэлдсэн|идэх\s+гэж\s+байна',
    caseSensitive: false,
    unicode: true,
  );
  static final _consumed = RegExp(
    r'\b(?:idsen|idlee|uusan|ate|drank|uudag)\b|идсэн|идлээ|уусан',
    caseSensitive: false,
    unicode: true,
  );

  List<LocalFoodCandidate> parse(String input) {
    return input
        .split(_split)
        .map((span) {
          final raw = span.trim();
          if (raw.isEmpty) return null;
          final action = _cancelled.hasMatch(raw)
              ? LocalFoodAction.cancelled
              : _planned.hasMatch(raw)
                  ? LocalFoodAction.planned
                  : LocalFoodAction.consumed;
          final amounts = _quantity.allMatches(raw).toList();
          final selected = amounts.length == 1 ? amounts.single : null;
          final quantityText = selected?.group(1);
          // 1,234 may mean 1.234 or 1234; do not guess intake.
          final ambiguousComma = quantityText != null &&
              RegExp(r'^[1-9][0-9]{0,2},[0-9]{3}$').hasMatch(quantityText);
          final value = quantityText == null || ambiguousComma
              ? null
              : parseNutritionNumber(quantityText);
          final unitText = selected?.group(2)?.toLowerCase();
          final unit = switch (unitText) {
            'g' ||
            'г' ||
            'гр' ||
            'грамм' ||
            'gram' ||
            'grams' =>
              LocalFoodUnit.grams,
            'ml' ||
            'мл' ||
            'milliliter' ||
            'milliliters' =>
              LocalFoodUnit.milliliters,
            'serving' || 'servings' => LocalFoodUnit.serving,
            'sh' ||
            'ш' ||
            'shirheg' ||
            'ширхэг' ||
            null when selected != null =>
              LocalFoodUnit.piece,
            _ => LocalFoodUnit.unknown,
          };
          final remaining = selected == null
              ? raw
              : raw.replaceRange(selected.start, selected.end, ' ');
          final name = normalizeFoodAlias(remaining
              .replaceAll(_cancelled, ' ')
              .replaceAll(_planned, ' ')
              .replaceAll(_consumed, ' '));
          final warnings = <String>[
            if (ambiguousComma) 'Ambiguous comma quantity: edit this item.',
            if (amounts.length > 1) 'Multiple quantities: edit this item.',
            if (selected == null) 'Quantity missing: enter g or ml.',
            if (value != null && (!value.isFinite || value <= 0))
              'Quantity must be positive.',
            if (name.isEmpty) 'Food name missing.',
          ];
          return LocalFoodCandidate(
            rawSpan: raw,
            normalizedText: normalizeFoodAlias(raw),
            foodQuery: name,
            quantity: value,
            unit: unit,
            action: action,
            warnings: warnings,
          );
        })
        .whereType<LocalFoodCandidate>()
        .toList(growable: false);
  }
}
