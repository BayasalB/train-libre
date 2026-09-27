enum NutritionSource { label, manual, catalog, estimate }

/// Label metadata belongs to the food version, not to package quantity.
class SavedFoodMetadata {
  final double? servingSize;
  final String? servingUnit;
  final NutritionSource? source;
  final bool verified;
  final DateTime? verifiedAt;
  final String? notes;
  final String? productPhotoRef;
  final String? labelPhotoRef;

  const SavedFoodMetadata(
      {this.servingSize,
      this.servingUnit,
      this.source,
      this.verified = false,
      this.verifiedAt,
      this.notes,
      this.productPhotoRef,
      this.labelPhotoRef});

  Map<String, Object?> toJson() => {
        if (servingSize != null) 'servingSize': servingSize,
        if (servingUnit != null) 'servingUnit': servingUnit,
        if (source != null) 'nutritionSource': source!.name,
        if (verified) 'nutritionVerified': true,
        if (verifiedAt != null)
          'nutritionVerifiedAt': verifiedAt!.toIso8601String(),
        if (notes != null) 'foodNotes': notes,
        if (productPhotoRef != null) 'productPhotoRef': productPhotoRef,
        if (labelPhotoRef != null) 'labelPhotoRef': labelPhotoRef,
      };

  factory SavedFoodMetadata.fromJson(Map<String, dynamic> json) {
    final date = json['nutritionVerifiedAt'];
    final source = json['nutritionSource'];
    return SavedFoodMetadata(
      servingSize: (json['servingSize'] as num?)?.toDouble(),
      servingUnit: json['servingUnit'] as String?,
      source: source == null
          ? null
          : NutritionSource.values.byName(source as String),
      verified:
          json['nutritionVerified'] == true || json['nutritionVerified'] == 1,
      verifiedAt: date == null
          ? null
          : date is int
              ? DateTime.fromMillisecondsSinceEpoch(date)
              : DateTime.parse(date as String),
      notes: json['foodNotes'] as String?,
      productPhotoRef: json['productPhotoRef'] as String?,
      labelPhotoRef: json['labelPhotoRef'] as String?,
    );
  }

  void validate() {
    if (servingSize != null && (!servingSize!.isFinite || servingSize! <= 0)) {
      throw ArgumentError('Serving size must be positive and finite.');
    }
    if ((servingSize == null) != (servingUnit == null) ||
        (servingUnit != null && !['g', 'ml'].contains(servingUnit))) {
      throw ArgumentError('Serving size requires an explicit g or ml unit.');
    }
    if (verified != (verifiedAt != null)) {
      throw ArgumentError('Verified nutrition requires a verification date.');
    }
  }
}
