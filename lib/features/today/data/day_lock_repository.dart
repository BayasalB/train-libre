import 'package:drift/drift.dart';

import '../../../data/drift_database.dart';
import '../domain/daily_record_models.dart';
import 'daily_record_repository.dart';

class DayLockedException implements Exception {
  final String date;
  const DayLockedException(this.date);

  @override
  String toString() => 'Day $date is locked. Unlock it before editing.';
}

/// One durable lock per explicit local date. Calls from write repositories
/// should run inside the same database transaction as the protected mutation.
class DayLockRepository {
  final AppDatabase db;
  final DateTime Function() clock;
  DayLockRepository(this.db, {DateTime Function()? clock})
      : clock = clock ?? DateTime.now;

  Future<DayLock?> get(DateTime date) => (db.select(db.dayLocks)
        ..where((t) =>
            t.localDate.equals(localDateKey(date)) & t.deletedAt.isNull()))
      .getSingleOrNull();

  Future<void> requireUnlocked(DateTime date) async {
    if (await get(date) != null) throw DayLockedException(localDateKey(date));
  }

  Future<DayLock> lock(DateTime date) => db.transaction(() async {
        final key = localDateKey(date);
        final current = await (db.select(db.dayLocks)
              ..where((t) => t.localDate.equals(key)))
            .getSingleOrNull();
        if (current != null && current.deletedAt == null) return current;
        final day = await DailyRecordRepository(db).getDay(date);
        final target =
            await DailyRecordRepository(db).resolve(date, record: day);
        final kind = day?.trainingType == TrainingType.rest.name
            ? TargetKind.rest.name
            : TargetKind.training.name;
        final now = clock();
        final values = DayLocksCompanion(
          localDate: Value(key),
          lockedAt: Value(now),
          revision: Value((current?.revision ?? 0) + 1),
          targetKind: Value(target.profile == null ? null : kind),
          targetProfileId: Value(target.profile?.id),
          targetCalories: Value(target.profile?.calories),
          targetProtein: Value(target.profile?.protein),
          targetCarbs: Value(target.profile?.carbs),
          targetFat: Value(target.profile?.fat),
          deletedAt: const Value(null),
          updatedAt: Value(now),
        );
        if (current == null) {
          return db.into(db.dayLocks).insertReturning(values);
        }
        await (db.update(db.dayLocks)..where((t) => t.id.equals(current.id)))
            .write(values);
        return (await get(date))!;
      });

  Future<void> unlock(DateTime date) => db.transaction(() async {
        final current = await get(date);
        if (current == null) return;
        await (db.update(db.dayLocks)..where((t) => t.id.equals(current.id)))
            .write(DayLocksCompanion(
                deletedAt: Value(clock()), updatedAt: Value(clock())));
      });
}
