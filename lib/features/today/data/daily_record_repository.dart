import 'package:drift/drift.dart';
import '../../../data/drift_database.dart';
import '../domain/daily_record_models.dart';
import 'day_lock_repository.dart';

class ResolvedDailyTargets {
  final NutritionTargetProfile? profile;
  final bool unsetFallback;
  final bool overridden;
  final bool locked;
  const ResolvedDailyTargets(this.profile,
      {this.unsetFallback = false,
      this.overridden = false,
      this.locked = false});
  String get explanation => profile == null
      ? locked
          ? 'No manual target was set when this day was locked.'
          : 'No manual targets for this date. Set training and rest targets.'
      : locked
          ? 'Target context preserved when this day was locked'
          : overridden
              ? 'Manual target override for this day'
              : unsetFallback
                  ? 'Training type is unset. Using training-day targets; this is not a Rest day.'
                  : 'Manual ${profile!.kind}-day targets · effective ${profile!.effectiveFrom}';
}

class DailyRecordRepository {
  final AppDatabase db;
  final DateTime Function() clock;
  DailyRecordRepository(this.db, {DateTime Function()? clock})
      : clock = clock ?? DateTime.now;

  Future<DailyRecord?> getDay(DateTime date) => (db.select(db.dailyRecords)
        ..where(
            (t) => t.date.equals(localDateKey(date)) & t.deletedAt.isNull()))
      .getSingleOrNull();

  Future<void> saveDay(DateTime date,
      {TrainingType? trainingType,
      String? notes,
      String? targetOverrideId,
      bool clearTargetOverride = false}) async {
    await db.transaction(() async {
      await DayLockRepository(db).requireUnlocked(date);
      final current = await getDay(date);
      final now = clock();
      if (targetOverrideId != null) {
        final profile = await (db.select(db.nutritionTargetProfiles)
              ..where(
                  (t) => t.id.equals(targetOverrideId) & t.deletedAt.isNull()))
            .getSingleOrNull();
        if (profile == null ||
            profile.effectiveFrom.compareTo(localDateKey(date)) > 0) {
          throw ArgumentError(
              'The target override must exist and be effective on this date.');
        }
      }
      final values = DailyRecordsCompanion(
          date: Value(localDateKey(date)),
          timezoneName: Value(current?.timezoneName ?? date.timeZoneName),
          utcOffsetMinutes:
              Value(current?.utcOffsetMinutes ?? date.timeZoneOffset.inMinutes),
          trainingType: Value((trainingType ??
                  TrainingType.values.byName(current?.trainingType ?? 'unset'))
              .name),
          notes: Value(notes ?? current?.notes ?? ''),
          updatedAt: Value(now),
          targetOverrideId: Value(clearTargetOverride
              ? null
              : targetOverrideId ?? current?.targetOverrideId));
      if (current == null) {
        await db.into(db.dailyRecords).insert(values);
      } else {
        await (db.update(db.dailyRecords)
              ..where((t) => t.id.equals(current.id)))
            .write(values);
      }
    });
  }

  Future<NutritionTargetProfile?> profileFor(TargetKind kind, DateTime date) =>
      (db.select(db.nutritionTargetProfiles)
            ..where((t) =>
                t.kind.equals(kind.name) &
                t.effectiveFrom.isSmallerOrEqualValue(localDateKey(date)) &
                t.deletedAt.isNull())
            ..orderBy([
              (t) => OrderingTerm.desc(t.effectiveFrom),
              (t) => OrderingTerm.desc(t.localId)
            ])
            ..limit(1))
          .getSingleOrNull();

  Future<ResolvedDailyTargets> resolve(DateTime date,
      {DailyRecord? record}) async {
    final day = record ?? await getDay(date);
    final lock = await DayLockRepository(db).get(date);
    if (lock != null) {
      final id = lock.targetProfileId;
      if (id == null) return const ResolvedDailyTargets(null, locked: true);
      final profile = await (db.select(db.nutritionTargetProfiles)
            ..where((t) => t.id.equals(id)))
          .getSingleOrNull();
      if (profile == null) {
        throw StateError('Locked target profile unavailable');
      }
      return ResolvedDailyTargets(
          profile.copyWith(
            calories: lock.targetCalories,
            protein: lock.targetProtein,
            carbs: lock.targetCarbs,
            fat: lock.targetFat,
          ),
          locked: true,
          unsetFallback: day?.trainingType == null ||
              day?.trainingType == TrainingType.unset.name);
    }
    if (day?.targetOverrideId != null) {
      final override = await (db.select(db.nutritionTargetProfiles)
            ..where((t) =>
                t.id.equals(day!.targetOverrideId!) & t.deletedAt.isNull()))
          .getSingleOrNull();
      if (override == null ||
          override.effectiveFrom.compareTo(localDateKey(date)) > 0) {
        throw StateError('Invalid target override for ${localDateKey(date)}');
      }
      return ResolvedDailyTargets(override, overridden: true);
    }
    final type = TrainingType.values.byName(day?.trainingType ?? 'unset');
    return ResolvedDailyTargets(
        await profileFor(
            type == TrainingType.rest ? TargetKind.rest : TargetKind.training,
            date),
        unsetFallback: type == TrainingType.unset);
  }

  /// Append-only revisions. A correction today cannot replace yesterday's row.
  Future<void> saveTargets(
      {required DateTime effectiveFrom,
      required NutritionTargets training,
      required NutritionTargets rest}) async {
    training.validate();
    rest.validate();
    if (localDay(effectiveFrom).isBefore(localDay(clock()))) {
      throw ArgumentError(
          'Manual target changes can start today or later, not in the past.');
    }
    await db.transaction(() async {
      for (final entry
          in {TargetKind.training: training, TargetKind.rest: rest}.entries) {
        await db.into(db.nutritionTargetProfiles).insert(
            NutritionTargetProfilesCompanion.insert(
                kind: entry.key.name,
                effectiveFrom: localDateKey(effectiveFrom),
                calories: entry.value.calories,
                protein: entry.value.protein,
                carbs: entry.value.carbs,
                fat: entry.value.fat,
                createdAt: Value(clock()),
                updatedAt: Value(clock())));
      }
    });
  }
}
