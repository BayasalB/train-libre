import '../domain/daily_record_models.dart';

/// Validate the new datasets before a restore can replace local data.
/// Older backups legitimately omit both datasets.
void validateDailyBackup(Map<String, dynamic> payload) {
  List<Map<String, dynamic>> rows(String key) {
    final value = payload[key];
    if (value == null) return [];
    if (value is! List) throw FormatException('Invalid $key dataset');
    final ids = <String>{};
    final localIds = <int>{};
    return value.map((raw) {
      if (raw is! Map) throw FormatException('Invalid $key row');
      final row = Map<String, dynamic>.from(raw);
      if (row['id'] is! String ||
          (row['id'] as String).isEmpty ||
          !ids.add(row['id'] as String) ||
          row['local_id'] is! int ||
          !localIds.add(row['local_id'] as int)) {
        throw FormatException('Invalid or duplicate $key identity');
      }
      return row;
    }).toList();
  }

  final profiles = rows('nutrition_target_profiles');
  final byId = {for (final row in profiles) row['id']: row};
  for (final row in profiles) {
    if (!TargetKind.values.any((v) => v.name == row['kind'])) {
      throw const FormatException('Invalid target kind');
    }
    parseLocalDateKey(row['effective_from'] as String);
    for (final name in ['calories', 'protein', 'carbs', 'fat']) {
      final value = row[name];
      if (value is! num ||
          !value.isFinite ||
          value < 0 ||
          (name == 'calories' && value == 0)) {
        throw FormatException('Invalid target $name');
      }
    }
  }
  final dates = <String>{};
  for (final row in rows('daily_records')) {
    final date = row['date'] as String;
    parseLocalDateKey(date);
    if (!dates.add(date) ||
        !TrainingType.values.any((v) => v.name == row['training_type']) ||
        row['notes'] is! String ||
        row['timezone_name'] is! String ||
        row['utc_offset_minutes'] is! int) {
      throw const FormatException('Invalid daily record');
    }
    if (row['target_override_id'] != null) {
      final profile = byId[row['target_override_id']];
      if (profile == null ||
          profile['deleted_at'] != null ||
          (profile['effective_from'] as String).compareTo(date) > 0) {
        throw const FormatException('Invalid daily target override');
      }
    }
  }
  final lockedDates = <String>{};
  for (final row in rows('day_locks')) {
    const supportedColumns = {
      'local_id',
      'id',
      'created_at',
      'updated_at',
      'deleted_at',
      'local_date',
      'locked_at',
      'revision',
      'target_kind',
      'target_profile_id',
      'target_calories',
      'target_protein',
      'target_carbs',
      'target_fat'
    };
    if (row.keys.any((key) => !supportedColumns.contains(key)) ||
        row['created_at'] is! int ||
        row['updated_at'] is! int ||
        (row['deleted_at'] != null && row['deleted_at'] is! int)) {
      throw const FormatException('Invalid day lock columns');
    }
    final date = row['local_date'];
    if (date is! String ||
        !lockedDates.add(date) ||
        row['locked_at'] is! int ||
        row['revision'] is! int ||
        (row['revision'] as int) < 1) {
      throw const FormatException('Invalid day lock');
    }
    parseLocalDateKey(date);
    final kind = row['target_kind'];
    final profileId = row['target_profile_id'];
    if (kind != null &&
        kind != TargetKind.training.name &&
        kind != TargetKind.rest.name) {
      throw const FormatException('Invalid locked target kind');
    }
    if (profileId != null && !byId.containsKey(profileId)) {
      throw const FormatException('Locked target profile is missing');
    }
    for (final field in [
      'target_calories',
      'target_protein',
      'target_carbs',
      'target_fat'
    ]) {
      final value = row[field];
      if (value != null && (value is! num || !value.isFinite || value < 0)) {
        throw const FormatException('Invalid locked target context');
      }
    }
  }
}
