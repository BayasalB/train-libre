import 'dart:convert';

import '../models/nutrition_values.dart';
import '../use_cases/parse_local_food_log.dart';

class SmartLogAiValidationException implements Exception {
  final String message;
  const SmartLogAiValidationException(this.message);
  @override
  String toString() => message;
}

class SmartLogAiSpan {
  final String id;
  final String text;
  const SmartLogAiSpan(this.id, this.text);
  Map<String, Object> toJson() => {'id': id, 'text': text};
}

class SmartLogAiFoodOption {
  /// Opaque request-scoped ID, never a barcode or database ID.
  final String id;
  final String name;
  final List<String> aliases;
  const SmartLogAiFoodOption(this.id, this.name, this.aliases);
  Map<String, Object> toJson() => {'id': id, 'name': name, 'aliases': aliases};
}

class SmartLogAiRequest {
  final List<SmartLogAiSpan> spans;
  final List<SmartLogAiFoodOption> foods;
  final bool allowEstimate;
  const SmartLogAiRequest(this.spans, this.foods,
      {required this.allowEstimate});
  Map<String, Object> toJson() => {
        'formatVersion': 1,
        'unresolved': spans.map((span) => span.toJson()).toList(),
        'candidateFoods': foods.map((food) => food.toJson()).toList(),
        'allowEstimate': allowEstimate,
      };
}

class SmartLogAiNutritionEstimate {
  final double caloriesPer100;
  final double proteinPer100;
  final double carbsPer100;
  final double fatPer100;
  const SmartLogAiNutritionEstimate({
    required this.caloriesPer100,
    required this.proteinPer100,
    required this.carbsPer100,
    required this.fatPer100,
  });
}

class SmartLogAiItem {
  final String sourceCandidateId;
  final String sourceText;
  final String interpretedFoodName;
  final double? quantity;
  final LocalFoodUnit unit;
  final LocalFoodAction? action;
  final String? suggestedLocalFoodReference;
  final SmartLogAiNutritionEstimate? nutritionEstimate;
  final double confidence;
  final List<String> warnings;
  const SmartLogAiItem({
    required this.sourceCandidateId,
    required this.sourceText,
    required this.interpretedFoodName,
    required this.quantity,
    required this.unit,
    required this.action,
    required this.suggestedLocalFoodReference,
    required this.nutritionEstimate,
    required this.confidence,
    required this.warnings,
  });
}

/// Strict v1 JSON contract. Any malformed or unrecognized field rejects the
/// entire response; nothing from a partial response reaches review or SQLite.
class SmartLogAiResponse {
  final List<SmartLogAiItem> items;
  const SmartLogAiResponse(this.items);

  static SmartLogAiResponse parse(String raw, SmartLogAiRequest request) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      throw const SmartLogAiValidationException('Malformed AI JSON.');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const SmartLogAiValidationException(
          'AI response must be an object.');
    }
    _keys(decoded, {'formatVersion', 'items'}, {'formatVersion', 'items'});
    if (decoded['formatVersion'] != 1 || decoded['items'] is! List) {
      throw const SmartLogAiValidationException(
          'Unsupported AI response format.');
    }
    final rawItems = decoded['items'] as List;
    if (rawItems.isEmpty || rawItems.length > 20) {
      throw const SmartLogAiValidationException('Invalid AI item count.');
    }
    final spans = {for (final span in request.spans) span.id: span.text};
    final options = request.foods.map((food) => food.id).toSet();
    final result = <SmartLogAiItem>[];
    for (final rawItem in rawItems) {
      if (rawItem is! Map<String, dynamic>) {
        throw const SmartLogAiValidationException('Invalid AI item.');
      }
      _keys(rawItem, {
        'sourceCandidateId',
        'sourceText',
        'interpretedFoodName',
        'quantity',
        'unit',
        'actionState',
        'suggestedLocalFoodReference',
        'nutritionEstimate',
        'confidence',
        'warnings',
      }, {
        'sourceCandidateId',
        'sourceText',
        'interpretedFoodName',
        'quantity',
        'unit',
        'actionState',
        'suggestedLocalFoodReference',
        'nutritionEstimate',
        'confidence',
        'warnings',
      });
      final id = rawItem['sourceCandidateId'];
      final text = rawItem['sourceText'];
      final name = rawItem['interpretedFoodName'];
      if (id is! String ||
          text is! String ||
          spans[id] != text ||
          name is! String ||
          name.trim().isEmpty ||
          name.length > 160) {
        throw const SmartLogAiValidationException(
            'Invalid AI source or food name.');
      }
      final rawQuantity = rawItem['quantity'];
      if (rawQuantity != null && rawQuantity is! String) {
        throw const SmartLogAiValidationException(
            'Quantity must be decimal text.');
      }
      final quantity = rawQuantity == null ? null : _decimal(rawQuantity);
      if (quantity != null &&
          (quantity <= 0 || !_hasQuantityEvidence(text, quantity))) {
        throw const SmartLogAiValidationException(
            'AI quantity is not supported by source text.');
      }
      final unit = switch (rawItem['unit']) {
        'g' => LocalFoodUnit.grams,
        'ml' => LocalFoodUnit.milliliters,
        'serving' => LocalFoodUnit.serving,
        'piece' => LocalFoodUnit.piece,
        'unknown' => LocalFoodUnit.unknown,
        _ => throw const SmartLogAiValidationException('Invalid AI unit.'),
      };
      final action = switch (rawItem['actionState']) {
        'consumed' => LocalFoodAction.consumed,
        'planned' => LocalFoodAction.planned,
        'cancelled' => LocalFoodAction.cancelled,
        'unknown' => null,
        _ => throw const SmartLogAiValidationException('Invalid AI action.'),
      };
      final ref = rawItem['suggestedLocalFoodReference'];
      if (ref != null && (ref is! String || !options.contains(ref))) {
        throw const SmartLogAiValidationException(
            'AI referenced an unknown local candidate.');
      }
      final rawEstimate = rawItem['nutritionEstimate'];
      SmartLogAiNutritionEstimate? estimate;
      if (rawEstimate != null) {
        if (ref != null) {
          throw const SmartLogAiValidationException(
              'AI estimate cannot replace a suggested Saved Food.');
        }
        if (!request.allowEstimate || rawEstimate is! Map<String, dynamic>) {
          throw const SmartLogAiValidationException(
              'Unrequested AI nutrition estimate.');
        }
        _keys(
            rawEstimate,
            {'caloriesPer100', 'proteinPer100', 'carbsPer100', 'fatPer100'},
            {'caloriesPer100', 'proteinPer100', 'carbsPer100', 'fatPer100'});
        final calories = _boundedDecimal(rawEstimate['caloriesPer100'], 1000);
        final protein = _boundedDecimal(rawEstimate['proteinPer100'], 100);
        final carbs = _boundedDecimal(rawEstimate['carbsPer100'], 100);
        final fat = _boundedDecimal(rawEstimate['fatPer100'], 100);
        estimate = SmartLogAiNutritionEstimate(
            caloriesPer100: calories,
            proteinPer100: protein,
            carbsPer100: carbs,
            fatPer100: fat);
      }
      final rawConfidence = rawItem['confidence'];
      if (rawConfidence is! num ||
          !rawConfidence.isFinite ||
          rawConfidence < 0 ||
          rawConfidence > 1) {
        throw const SmartLogAiValidationException('Invalid AI confidence.');
      }
      final rawWarnings = rawItem['warnings'];
      if (rawWarnings is! List ||
          rawWarnings.length > 10 ||
          rawWarnings.any((value) => value is! String || value.length > 200)) {
        throw const SmartLogAiValidationException('Invalid AI warnings.');
      }
      result.add(SmartLogAiItem(
        sourceCandidateId: id,
        sourceText: text,
        interpretedFoodName: name.trim(),
        quantity: quantity,
        unit: unit,
        action: action,
        suggestedLocalFoodReference: ref,
        nutritionEstimate: estimate,
        confidence: rawConfidence.toDouble(),
        warnings: List<String>.unmodifiable(rawWarnings),
      ));
    }
    return SmartLogAiResponse(List.unmodifiable(result));
  }

  static void _keys(
      Map<String, dynamic> value, Set<String> allowed, Set<String> required) {
    if (!value.keys.toSet().containsAll(required) ||
        value.keys.any((key) => !allowed.contains(key))) {
      throw const SmartLogAiValidationException(
          'Unexpected or missing AI field.');
    }
  }

  static double _decimal(String raw) {
    if (!RegExp(r'^[0-9]+(?:\.[0-9]+)?$').hasMatch(raw)) {
      throw const SmartLogAiValidationException('Invalid AI decimal.');
    }
    final value = parseNutritionNumber(raw);
    if (value == null) {
      throw const SmartLogAiValidationException('Nonfinite AI decimal.');
    }
    return value;
  }

  static double _boundedDecimal(Object? raw, double max) {
    if (raw is! String) {
      throw const SmartLogAiValidationException('Invalid AI nutrition value.');
    }
    final value = _decimal(raw);
    if (value < 0 || value > max) {
      throw const SmartLogAiValidationException(
          'AI nutrition value out of range.');
    }
    return value;
  }

  static bool _hasQuantityEvidence(String text, double value) {
    final tokens =
        RegExp(r'(?<![0-9])[0-9]+(?:[.,][0-9]+)?(?![0-9])').allMatches(text);
    return tokens
        .any((match) => parseNutritionNumber(match.group(0)!) == value);
  }
}
