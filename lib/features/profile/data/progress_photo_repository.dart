import 'dart:io';

import 'package:drift/drift.dart';

import '../../../core/media/app_media_store.dart';
import '../../../data/drift_database.dart' as db;
import '../../today/domain/daily_record_models.dart';
import '../../today/data/day_lock_repository.dart';

class ProgressPhotoRepository {
  final db.AppDatabase database;
  final AppMediaStore mediaStore;

  ProgressPhotoRepository(this.database, {AppMediaStore? mediaStore})
      : mediaStore = mediaStore ?? AppMediaStore.instance;

  Stream<List<db.ProgressPhoto>> watchDay(DateTime day) =>
      (database.select(database.progressPhotos)
            ..where((t) =>
                t.localDate.equals(localDateKey(day)) & t.deletedAt.isNull())
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .watch();

  Stream<List<db.ProgressPhoto>> watchAll() =>
      (database.select(database.progressPhotos)
            ..where((t) => t.deletedAt.isNull())
            ..orderBy([
              (t) => OrderingTerm.desc(t.localDate),
              (t) => OrderingTerm.desc(t.createdAt)
            ]))
          .watch();

  Future<db.ProgressPhoto> add(File source, DateTime day,
      {String? note}) async {
    await DayLockRepository(database).requireUnlocked(day);
    final stored = await mediaStore.save(source, domain: MediaDomain.progress);
    if (stored == null) throw StateError('Could not save progress photo');
    try {
      return await database.transaction(() async {
        await DayLockRepository(database).requireUnlocked(day);
        return database.into(database.progressPhotos).insertReturning(
              db.ProgressPhotosCompanion.insert(
                localDate: localDateKey(day),
                mediaPath: stored.path,
                note: Value(note?.trim().isEmpty == true ? null : note?.trim()),
              ),
            );
      });
    } catch (_) {
      await mediaStore.deleteAll([stored.path]);
      rethrow;
    }
  }

  Future<void> updateNote(String id, String? note) async {
    await database.transaction(() async {
      final row = await (database.select(database.progressPhotos)
            ..where((t) => t.id.equals(id) & t.deletedAt.isNull()))
          .getSingleOrNull();
      if (row == null) return;
      await DayLockRepository(database)
          .requireUnlocked(parseLocalDateKey(row.localDate));
      await (database.update(database.progressPhotos)
            ..where((t) => t.id.equals(id) & t.deletedAt.isNull()))
          .write(db.ProgressPhotosCompanion(
        note: Value(note?.trim().isEmpty == true ? null : note?.trim()),
        updatedAt: Value(DateTime.now()),
      ));
    });
  }

  Future<void> delete(String id) async {
    String? path;
    await database.transaction(() async {
      final row = await (database.select(database.progressPhotos)
            ..where((t) => t.id.equals(id)))
          .getSingleOrNull();
      if (row == null) return;
      await DayLockRepository(database)
          .requireUnlocked(parseLocalDateKey(row.localDate));
      path = row.mediaPath;
      await (database.delete(database.progressPhotos)
            ..where((t) => t.id.equals(id)))
          .go();
    });
    final deletedPath = path;
    if (deletedPath == null) return;
    // This domain owns only paths under media/progress. Never remove a path
    // supplied by a malformed import or one still referenced by another row.
    if (AppMediaStore.isProgressPhotoPath(deletedPath) &&
        !await _referencedElsewhere(deletedPath)) {
      await mediaStore.deleteAll([deletedPath]);
    }
  }

  Future<bool> _referencedElsewhere(String path) async {
    final other = await (database.select(database.progressPhotos)
          ..where((t) => t.mediaPath.equals(path) & t.deletedAt.isNull())
          ..limit(1))
        .getSingleOrNull();
    if (other != null) return true;
    if ((await AppMediaStore.referencedMealPaths(database)).contains(path) ||
        (await AppMediaStore.referencedWorkoutPaths(database)).contains(path)) {
      return true;
    }
    final product = await (database.select(database.products)
          ..where((t) =>
              t.productPhotoRef.equals(path) | t.labelPhotoRef.equals(path))
          ..limit(1))
        .getSingleOrNull();
    if (product != null) return true;
    final override = await (database.select(database.userFoodOverrides)
          ..where((t) =>
              t.productPhotoRef.equals(path) | t.labelPhotoRef.equals(path))
          ..limit(1))
        .getSingleOrNull();
    return override != null;
  }
}
